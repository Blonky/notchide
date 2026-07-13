// bridge.js — the core HOST-mode bridge.
//
// It runs ONE long-lived Claude Agent SDK `query(...)` in streaming-input mode
// and wires it to notchide's AAP socket:
//
//   ACTUATE (notch -> agent):
//     * inbound actuate `prompt`    -> push an SDKUserMessage (a user turn) into
//                                       the query's input async-iterable.
//     * inbound actuate `interrupt` -> query.interrupt() (barge-in).
//
//   GATE (agent -> notch -> agent):
//     * canUseTool(name, input)     -> emit a `needsDecision` envelope with
//                                       wantsDecision:true, await the matching
//                                       AgentDecision frame, and resolve to
//                                       {behavior:'allow'} / {behavior:'deny'}.
//
//   OBSERVE (agent -> notch):
//     * SDK stream messages         -> observe envelopes (wantsDecision:false):
//         system/init  -> 'started'
//         assistant    -> 'progress' (text -> title, tool_use -> command)
//         user w/ tool_result -> 'progress'
//         result       -> 'finished' (success) or 'errored'
//
// The SDK `query` function is INJECTABLE (constructor `queryFn`) so the whole
// protocol path is testable with a mock query and a mock socket — no real
// `claude` binary or network required.

import { randomUUID } from 'node:crypto';
import {
  PROVIDER_ID,
  buildAgentEvent,
  buildEnvelope,
} from './aap.js';

/** Blocking-gate timeout, mirroring Swift `HookTimeout`: default 10 min,
 *  clamped to [0, 1 h]. A malformed value can neither hang unbounded nor
 *  crash. On timeout we fail open (defer) rather than block the agent. */
export function gateTimeoutMs(raw) {
  const DEFAULT = 600_000;
  const MAX = 3_600_000;
  if (raw == null) return DEFAULT;
  const trimmed = String(raw).trim();
  if (trimmed.length === 0) return DEFAULT;
  if (!/^\d+$/.test(trimmed)) return DEFAULT;
  const n = Number(trimmed);
  if (!Number.isFinite(n) || n < 0) return DEFAULT;
  return Math.min(n, MAX);
}

/** Render a tool invocation as a human-readable command string, mirroring
 *  Swift `JSONValue.humanReadableCommand`. */
export function renderCommand(toolName, input) {
  if (!input || typeof input !== 'object') return toolName;
  if (toolName === 'Bash') {
    return typeof input.command === 'string' ? input.command : toolName;
  }
  if (['Read', 'Write', 'Edit', 'MultiEdit', 'NotebookEdit'].includes(toolName)) {
    const p = input.file_path ?? input.notebook_path;
    return typeof p === 'string' ? `${toolName} ${p}` : toolName;
  }
  const parts = Object.keys(input)
    .sort()
    .map((k) => {
      const v = input[k];
      if (v === null || typeof v === 'object') return null;
      return `${k}=${v}`;
    })
    .filter((x) => x != null);
  return parts.length ? `${toolName}(${parts.join(', ')})` : toolName;
}

function truncate(s, n = 240) {
  if (typeof s !== 'string') return s;
  const oneLine = s.replace(/\s+/g, ' ').trim();
  return oneLine.length > n ? oneLine.slice(0, n - 1) + '…' : oneLine;
}

/**
 * A minimal push-driven async iterable used as the query's streaming input.
 * `push(msg)` enqueues an SDKUserMessage; `end()` completes the stream.
 */
export class MessageQueue {
  constructor() {
    this._queue = [];
    this._resolvers = [];
    this._done = false;
  }

  push(item) {
    if (this._done) return;
    const r = this._resolvers.shift();
    if (r) r({ value: item, done: false });
    else this._queue.push(item);
  }

  end() {
    if (this._done) return;
    this._done = true;
    let r;
    while ((r = this._resolvers.shift())) r({ value: undefined, done: true });
  }

  [Symbol.asyncIterator]() {
    return {
      next: () => {
        if (this._queue.length) {
          return Promise.resolve({ value: this._queue.shift(), done: false });
        }
        if (this._done) return Promise.resolve({ value: undefined, done: true });
        return new Promise((resolve) => this._resolvers.push(resolve));
      },
      return: () => {
        this.end();
        return Promise.resolve({ value: undefined, done: true });
      },
    };
  }
}

export class Bridge {
  /**
   * @param {object} opts
   * @param {import('./aap.js').AapClient} opts.client  connected AAP client
   * @param {Function} opts.queryFn  the SDK `query` (injectable for tests)
   * @param {string}   [opts.cwd]    working directory for the session
   * @param {string}   [opts.providerID]
   * @param {object}   [opts.sdkOptions]  extra Options merged into query()
   * @param {number}   [opts.gateTimeoutMs]
   * @param {Function} [opts.log]
   */
  constructor({
    client,
    queryFn,
    cwd = process.cwd(),
    providerID = PROVIDER_ID,
    sdkOptions = {},
    gateTimeoutMs: gateMs = gateTimeoutMs(process.env.NOTCHIDE_HOOK_TIMEOUT_MS),
    log = () => {},
  }) {
    this.client = client;
    this.queryFn = queryFn;
    this.cwd = cwd;
    this.providerID = providerID;
    this.sdkOptions = sdkOptions;
    this.gateMs = gateMs;
    this.log = log;

    this.input = new MessageQueue();
    this.query = null;
    this._sdkSessionId = null; // adopted from the first message that carries one
    this._fallbackId = randomUUID(); // stable id until the SDK reports its own
    this._pendingDecisions = new Map(); // envelope id -> {resolve, timer}
    this._started = false;
    this._stopped = false;
  }

  /** One stable agentSessionID per session: the SDK session id when known,
   *  otherwise a stable local fallback so events always carry a non-empty id. */
  sessionId() {
    return this._sdkSessionId ?? this._fallbackId;
  }

  _adoptSessionId(id) {
    if (typeof id === 'string' && id.length > 0 && this._sdkSessionId == null) {
      this._sdkSessionId = id;
      this.log(`bridge: adopted SDK session id ${id}`);
    }
  }

  // ── outbound observe / gate envelopes ──────────────────────────────────

  _emitEvent({ kind, title, command, decision, payload, wantsDecision, id }) {
    const envelopeId = id ?? randomUUID();
    const event = buildAgentEvent({
      providerID: this.providerID,
      agentSessionID: this.sessionId(),
      cwd: this.cwd,
      kind,
      title,
      command,
      decision,
      payload,
      at: Date.now() / 1000,
    });
    this.client.send(buildEnvelope({ id: envelopeId, event, wantsDecision }));
    return envelopeId;
  }

  // ── canUseTool  <->  AAP gate ──────────────────────────────────────────

  /**
   * The SDK permission callback. Emits a blocking `needsDecision` envelope and
   * awaits the correlated AgentDecision frame.
   *   verdict 'allow' -> { behavior:'allow' }
   *   verdict 'deny'  -> { behavior:'deny', message }
   *   verdict 'ask' / timeout / socket drop -> null  (fail-open: the SDK's
   *     `suppressControlResponse` — emit no decision, defer to its own default,
   *     never block the agent because notchide is unavailable).
   */
  async canUseTool(toolName, input, opts = {}) {
    const id = randomUUID();
    const command = renderCommand(toolName, input);
    // Prefer the bridge-rendered prompt sentence when the SDK supplies it.
    const prompt = opts.title || command || toolName;

    const decision = await new Promise((resolve) => {
      const timer = setTimeout(() => {
        if (this._pendingDecisions.delete(id)) {
          this.log(`bridge: gate ${id} timed out; failing open (defer)`);
          resolve(null);
        }
      }, this.gateMs);
      if (timer.unref) timer.unref();
      this._pendingDecisions.set(id, { resolve, timer });

      this._emitEvent({
        id,
        kind: 'needsDecision',
        title: `Permission: ${toolName}`,
        command,
        decision: { id, prompt },
        payload: {
          type: 'permission_request',
          tool_name: toolName,
          tool_input: input,
          tool_use_id: opts.toolUseID ?? null,
        },
        wantsDecision: true,
      });
    });

    if (!decision) return null; // ask / timeout / disconnect -> defer (fail-open)
    if (decision.verdict === 'allow') return { behavior: 'allow' };
    if (decision.verdict === 'deny') {
      return {
        behavior: 'deny',
        message: decision.reason || 'Denied via notchide.',
      };
    }
    // 'ask' (escalate to the agent's own prompt) and any unknown verdict:
    // abstain so the SDK falls back to its configured permission behavior.
    return null;
  }

  _onDecision(frame) {
    const pending = this._pendingDecisions.get(frame.id);
    if (!pending) return; // unknown/stale id — ignore
    this._pendingDecisions.delete(frame.id);
    clearTimeout(pending.timer);
    pending.resolve(frame);
  }

  // ── actuate  <->  input turn / interrupt ───────────────────────────────

  _onActuate(frame) {
    if (frame.kind === 'prompt') {
      const text = frame.text ?? '';
      this.log(`bridge: actuate prompt (${truncate(text, 60)})`);
      this.input.push({
        type: 'user',
        message: { role: 'user', content: text },
        parent_tool_use_id: null,
      });
    } else if (frame.kind === 'interrupt') {
      this.log('bridge: actuate interrupt -> query.interrupt()');
      if (this.query && typeof this.query.interrupt === 'function') {
        Promise.resolve(this.query.interrupt()).catch((err) =>
          this.log(`bridge: interrupt failed: ${err?.message ?? err}`),
        );
      }
    }
  }

  // ── SDK stream messages -> observe envelopes ───────────────────────────

  _handleMessage(msg) {
    if (!msg || typeof msg !== 'object') return;
    if (typeof msg.session_id === 'string') this._adoptSessionId(msg.session_id);

    switch (msg.type) {
      case 'system':
        if (msg.subtype === 'init') {
          if (typeof msg.cwd === 'string' && msg.cwd.length) this.cwd = msg.cwd;
          this._emitEvent({
            kind: 'started',
            title: 'Claude Code session started',
            command: msg.model ? `model: ${msg.model}` : undefined,
            payload: { type: 'init', session_id: this.sessionId(), model: msg.model },
            wantsDecision: false,
          });
        }
        break;

      case 'assistant':
        this._handleAssistant(msg);
        break;

      case 'user':
        this._handleUser(msg);
        break;

      case 'result':
        this._emitEvent({
          kind: msg.subtype === 'success' && !msg.is_error ? 'finished' : 'errored',
          title: msg.subtype === 'success' && !msg.is_error ? 'Turn complete' : 'Turn errored',
          command: truncate(typeof msg.result === 'string' ? msg.result : msg.subtype),
          payload: {
            type: 'result',
            subtype: msg.subtype,
            is_error: Boolean(msg.is_error),
            num_turns: msg.num_turns,
          },
          wantsDecision: false,
        });
        break;

      default:
        break; // status/partial/etc — not surfaced as lane events
    }
  }

  _handleAssistant(msg) {
    const content = msg?.message?.content;
    const blocks = Array.isArray(content)
      ? content
      : typeof content === 'string'
        ? [{ type: 'text', text: content }]
        : [];
    for (const block of blocks) {
      if (block.type === 'text' && block.text) {
        this._emitEvent({
          kind: 'progress',
          title: truncate(block.text),
          payload: { type: 'assistant_text', text: block.text },
          wantsDecision: false,
        });
      } else if (block.type === 'tool_use') {
        this._emitEvent({
          kind: 'progress',
          title: `Tool: ${block.name}`,
          command: renderCommand(block.name, block.input),
          payload: {
            type: 'tool_use',
            id: block.id,
            name: block.name,
            input: block.input,
          },
          wantsDecision: false,
        });
      }
    }
  }

  _handleUser(msg) {
    // The stream echoes user turns (including the prompts we injected). Only
    // surface tool_result blocks as progress; skip our own plain-text prompts.
    const content = msg?.message?.content;
    if (!Array.isArray(content)) return;
    for (const block of content) {
      if (block.type !== 'tool_result') continue;
      this._emitEvent({
        kind: 'progress',
        title: block.is_error ? 'Tool failed' : 'Tool result',
        command: truncate(
          typeof block.content === 'string'
            ? block.content
            : JSON.stringify(block.content),
        ),
        payload: {
          type: 'tool_result',
          tool_use_id: block.tool_use_id,
          is_error: Boolean(block.is_error),
        },
        wantsDecision: false,
      });
    }
  }

  // ── lifecycle ──────────────────────────────────────────────────────────

  /**
   * Wire the client, start the long-lived query, and consume its message
   * stream until it ends or `stop()` is called. Returns the stream promise so
   * the caller can await terminal errors (e.g. a missing `claude` binary).
   */
  async start() {
    if (this._started) return this._runPromise;
    this._started = true;

    this._actuateHandler = (f) => this._onActuate(f);
    this._decisionHandler = (f) => this._onDecision(f);
    this.client.on('actuate', this._actuateHandler);
    this.client.on('decision', this._decisionHandler);

    const options = {
      cwd: this.cwd,
      canUseTool: (name, input, o) => this.canUseTool(name, input, o),
      ...this.sdkOptions,
    };

    this.query = this.queryFn({ prompt: this.input, options });
    this._runPromise = this._consume();
    return this._runPromise;
  }

  async _consume() {
    try {
      for await (const msg of this.query) {
        if (this._stopped) break;
        this._handleMessage(msg);
      }
    } catch (err) {
      if (!this._stopped) {
        this.log(`bridge: query stream error: ${err?.message ?? err}`);
        this._emitEvent({
          kind: 'errored',
          title: 'Session error',
          command: truncate(String(err?.message ?? err)),
          payload: { type: 'error', message: String(err?.message ?? err) },
          wantsDecision: false,
        });
      }
      throw err;
    }
  }

  /** Stop the bridge: end the input stream and detach client listeners. */
  stop() {
    if (this._stopped) return;
    this._stopped = true;
    this.input.end();
    if (this._actuateHandler) this.client.off('actuate', this._actuateHandler);
    if (this._decisionHandler) this.client.off('decision', this._decisionHandler);
    for (const [, p] of this._pendingDecisions) {
      clearTimeout(p.timer);
      p.resolve(null); // release any awaiting canUseTool (fail-open)
    }
    this._pendingDecisions.clear();
  }
}

/** Convenience factory. */
export function createBridge(opts) {
  return new Bridge(opts);
}
