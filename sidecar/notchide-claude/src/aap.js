// aap.js — the AAP (Agent Adapter Protocol) socket client for the notchide
// HOST-mode Claude sidecar.
//
// This module owns the wire: it connects to notchide's owner-only Unix socket,
// speaks the `aap/1` handshake, frames every message as NDJSON (one JSON object
// per line, `\n`-terminated), and classifies inbound lines by their top-level
// key exactly the way `AAPFrame.classify` does in Swift:
//
//   { "aap": ... }      -> handshake   (server never sends us one; ignored)
//   { "actuate": ... }  -> ActuateFrame (server -> us: prompt / interrupt)
//   { "verdict": ... }  -> AgentDecision (server -> us: gate reply)
//   { "event": ... }    -> AgentEnvelope (us -> server; never inbound)
//
// The frame *builders* and *parsers* here are pure and exported so they can be
// unit-tested without a socket. `AapClient` layers connect/reconnect/backoff on
// top. See /Users/zacsong/notchide/docs/PROTOCOL.md and
// Sources/NotchideKit/IPCProtocol.swift for the normative wire shapes.

import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import { EventEmitter } from 'node:events';

/** This provider's stable, reverse-DNS identity. Distinct from the hook
 *  adapter's `sh.claude`; the notch routes actuate frames to us by this id. */
export const PROVIDER_ID = 'sh.claude.host';

/** Capabilities we advertise. `actuate` is what makes the notch push voice
 *  prompts/interrupts to our live connection; `gate` lets us block on a
 *  permission decision; `observe` streams progress. Order is not significant
 *  (the app records them in a Set). */
export const CAPABILITIES = ['observe', 'gate', 'actuate'];

export const AAP_VERSION = '1';

/**
 * The canonical socket path, honoring `NOTCHIDE_SOCKET_PATH` (when set and
 * non-empty) and otherwise defaulting to
 * `~/Library/Application Support/notchide/agent.sock`.
 */
export function defaultSocketPath(env = process.env) {
  const override = env.NOTCHIDE_SOCKET_PATH;
  if (override && override.length > 0) return override;
  return path.join(
    os.homedir(),
    'Library',
    'Application Support',
    'notchide',
    'agent.sock',
  );
}

// ── Pure framing helpers ──────────────────────────────────────────────────

/**
 * The AAP handshake object — the FIRST line on every connection.
 * `{"aap":"1","providerID":"sh.claude.host","capabilities":[...]}`.
 */
export function buildHandshake(
  providerID = PROVIDER_ID,
  capabilities = CAPABILITIES,
) {
  return { aap: AAP_VERSION, providerID, capabilities };
}

/**
 * Build a flat `AgentEvent` matching the Swift `AgentEvent` wire encoding:
 * top-level `providerID` / `agentSessionID` / `cwd` (NOT a nested sessionKey),
 * `kind`, optional `title` / `command` / `decision`, `payload` (object), and
 * `at` (epoch seconds, a JSON number). Absent optionals are OMITTED, never
 * emitted as `null` (§5.2 of PROTOCOL.md).
 */
export function buildAgentEvent({
  providerID = PROVIDER_ID,
  agentSessionID,
  cwd = '',
  kind,
  title,
  command,
  decision,
  payload = {},
  at = Date.now() / 1000,
}) {
  const event = {
    providerID,
    agentSessionID: agentSessionID ?? '',
    cwd: cwd ?? '',
    kind,
  };
  if (title != null) event.title = title;
  if (command != null) event.command = command;
  // `decision` present iff kind === 'needsDecision' (invariant enforced here).
  if (decision != null && kind === 'needsDecision') {
    event.decision = { id: decision.id, prompt: decision.prompt ?? '' };
  }
  event.payload = payload ?? {};
  event.at = at;
  return event;
}

/**
 * Wrap an event in an `AgentEnvelope`. All three fields (`id`, `event`,
 * `wantsDecision`) are required by the Swift decoder — none are optional.
 */
export function buildEnvelope({ id, event, wantsDecision }) {
  return { id, event, wantsDecision: Boolean(wantsDecision) };
}

/**
 * Classify one already-parsed JSON object by its top-level key, mirroring
 * `AAPFrame.classify`. Returns one of the tag strings; `unknown` degrades
 * gracefully (a newer/odd frame is skipped, never fatal).
 */
export function classifyFrame(obj) {
  if (obj == null || typeof obj !== 'object') return 'unknown';
  if (obj.aap != null) return 'handshake';
  if (obj.actuate != null) return 'actuate';
  if (obj.verdict != null) return 'decision';
  if (obj.event != null) return 'envelope';
  return 'unknown';
}

/**
 * Parse an inbound `ActuateFrame`:
 * `{"actuate":{"sessionKey":{...},"kind":"prompt"|"interrupt","text":?}}`.
 * `text` is only meaningful for `kind === 'prompt'`. Returns null if malformed.
 */
export function parseActuate(obj) {
  const body = obj?.actuate;
  if (!body || typeof body !== 'object') return null;
  const kind = body.kind;
  if (kind !== 'prompt' && kind !== 'interrupt') return null;
  return {
    sessionKey: body.sessionKey ?? null,
    kind,
    text: kind === 'prompt' ? (typeof body.text === 'string' ? body.text : '') : null,
  };
}

/**
 * Parse an inbound `AgentDecision`:
 * `{"id":"<uuid>","verdict":"allow"|"deny"|"ask","reason":?,"redirect":?}`.
 * Returns null if it lacks the two required fields.
 */
export function parseDecision(obj) {
  if (typeof obj?.id !== 'string' || typeof obj?.verdict !== 'string') return null;
  return {
    id: obj.id,
    verdict: obj.verdict,
    reason: typeof obj.reason === 'string' ? obj.reason : null,
    redirect: typeof obj.redirect === 'string' ? obj.redirect : null,
  };
}

/** Serialize any frame as one NDJSON line (`JSON\n`). */
export function encodeLine(obj) {
  return JSON.stringify(obj) + '\n';
}

// ── The socket client ─────────────────────────────────────────────────────

/**
 * Duplex NDJSON client over notchide's Unix socket. Emits:
 *   'connect'            once the handshake line has been written
 *   'actuate'  (frame)   an inbound ActuateFrame {sessionKey, kind, text}
 *   'decision' (frame)   an inbound AgentDecision {id, verdict, reason, redirect}
 *   'disconnect'         the underlying socket closed
 *   'error'    (err)     a transport error (also logged)
 *
 * Reconnect with capped exponential backoff is handled internally so the bridge
 * can hold a single stable client across socket drops; the handshake is
 * re-sent on every new connection, re-registering our actuate connection with
 * the app.
 */
export class AapClient extends EventEmitter {
  constructor({
    socketPath = defaultSocketPath(),
    providerID = PROVIDER_ID,
    capabilities = CAPABILITIES,
    reconnect = true,
    minBackoffMs = 250,
    maxBackoffMs = 10_000,
    log = () => {},
  } = {}) {
    super();
    this.socketPath = socketPath;
    this.providerID = providerID;
    this.capabilities = capabilities;
    this.reconnect = reconnect;
    this.minBackoffMs = minBackoffMs;
    this.maxBackoffMs = maxBackoffMs;
    this.log = log;

    this.socket = null;
    this.connected = false;
    this._buf = '';
    this._backoff = minBackoffMs;
    this._closed = false;
    this._reconnectTimer = null;
  }

  /** Open the connection (idempotent). Subsequent drops auto-reconnect. */
  connect() {
    if (this._closed) return;
    if (this.socket) return;

    const socket = net.createConnection({ path: this.socketPath });
    this.socket = socket;
    socket.setEncoding('utf8');

    socket.on('connect', () => {
      this.connected = true;
      this._backoff = this.minBackoffMs;
      // The handshake MUST be the first line on the connection.
      socket.write(encodeLine(buildHandshake(this.providerID, this.capabilities)));
      this.log(`aap: connected to ${this.socketPath}, handshake sent`);
      this.emit('connect');
    });

    socket.on('data', (chunk) => this._onData(chunk));
    socket.on('error', (err) => {
      this.log(`aap: socket error: ${err.message}`);
      this.emit('error', err);
    });
    socket.on('close', () => {
      this.connected = false;
      this.socket = null;
      this._buf = '';
      this.emit('disconnect');
      this._scheduleReconnect();
    });
  }

  _onData(chunk) {
    this._buf += chunk;
    let nl;
    while ((nl = this._buf.indexOf('\n')) >= 0) {
      const line = this._buf.slice(0, nl);
      this._buf = this._buf.slice(nl + 1);
      if (line.length === 0) continue;
      this._handleLine(line);
    }
  }

  _handleLine(line) {
    let obj;
    try {
      obj = JSON.parse(line);
    } catch {
      this.log('aap: skipping unparseable inbound line');
      return; // lenient: never throw on odd input
    }
    switch (classifyFrame(obj)) {
      case 'actuate': {
        const frame = parseActuate(obj);
        if (frame) this.emit('actuate', frame);
        break;
      }
      case 'decision': {
        const frame = parseDecision(obj);
        if (frame) this.emit('decision', frame);
        break;
      }
      default:
        // handshake/envelope/unknown are never expected inbound; ignore.
        break;
    }
  }

  /**
   * Write one frame as an NDJSON line. Returns true if it was handed to the
   * socket, false if we are not connected (best-effort / local-first: an
   * observe event lost while the app is down is not an error).
   */
  send(obj) {
    if (!this.connected || !this.socket) return false;
    try {
      return this.socket.write(encodeLine(obj));
    } catch (err) {
      this.log(`aap: write failed: ${err.message}`);
      return false;
    }
  }

  _scheduleReconnect() {
    if (this._closed || !this.reconnect) return;
    const delay = this._backoff;
    this._backoff = Math.min(this._backoff * 2, this.maxBackoffMs);
    this.log(`aap: reconnecting in ${delay}ms`);
    this._reconnectTimer = setTimeout(() => {
      this._reconnectTimer = null;
      this.connect();
    }, delay);
    if (this._reconnectTimer.unref) this._reconnectTimer.unref();
  }

  /** Permanently close; disables reconnect. */
  close() {
    this._closed = true;
    this.reconnect = false;
    if (this._reconnectTimer) {
      clearTimeout(this._reconnectTimer);
      this._reconnectTimer = null;
    }
    if (this.socket) {
      try {
        this.socket.destroy();
      } catch {
        /* ignore */
      }
      this.socket = null;
    }
    this.connected = false;
  }
}
