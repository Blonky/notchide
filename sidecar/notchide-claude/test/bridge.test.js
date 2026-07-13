// bridge.test.js — protocol-path tests for the notchide HOST sidecar.
//
// These exercise the REAL AapClient over a REAL in-process unix-socket server,
// with a MOCK injected `query` (no `claude` binary, no network). They verify:
//   1. the handshake line is sent with the right capabilities;
//   2. an inbound actuate PROMPT frame pushes a user turn to the generator;
//   3. an inbound actuate INTERRUPT calls query.interrupt();
//   4. canUseTool emits a wantsDecision envelope and resolves allow/deny from
//      the correlated decision frame;
//   5. an assistant message maps to an observe envelope of kind 'progress'.

import test from 'node:test';
import assert from 'node:assert/strict';
import net from 'node:net';
import path from 'node:path';
import { randomUUID } from 'node:crypto';

import { AapClient } from '../src/aap.js';
import { Bridge, MessageQueue } from '../src/bridge.js';

// ── a minimal in-process AAP server (stands in for the notchide app) ───────
class MockServer {
  constructor() {
    this.handshake = null;
    this.envelopes = [];
    this.sock = null;
    this._buf = '';
  }
  async listen(socketPath) {
    this.path = socketPath;
    this.server = net.createServer((sock) => {
      this.sock = sock;
      sock.setEncoding('utf8');
      sock.on('data', (c) => this._onData(c));
      sock.on('error', () => {});
    });
    await new Promise((resolve, reject) => {
      this.server.once('error', reject);
      this.server.listen(socketPath, resolve);
    });
  }
  _onData(chunk) {
    this._buf += chunk;
    let nl;
    while ((nl = this._buf.indexOf('\n')) >= 0) {
      const line = this._buf.slice(0, nl);
      this._buf = this._buf.slice(nl + 1);
      if (!line) continue;
      const obj = JSON.parse(line);
      if (this.handshake == null && obj.aap != null) this.handshake = obj;
      else if (obj.event != null) this.envelopes.push(obj);
    }
  }
  sendActuateBody(body) {
    this.sock.write(JSON.stringify({ actuate: body }) + '\n');
  }
  sendDecision(decision) {
    this.sock.write(JSON.stringify(decision) + '\n');
  }
  async close() {
    try { this.sock?.destroy(); } catch { /* ignore */ }
    await new Promise((r) => this.server.close(r));
  }
}

function makeMockQuery() {
  const outbound = new MessageQueue();
  const inbound = [];
  const state = { interruptCount: 0, canUseTool: null };
  const queryFn = (params) => {
    state.canUseTool = params.options.canUseTool;
    (async () => {
      for await (const m of params.prompt) inbound.push(m);
    })();
    return {
      [Symbol.asyncIterator]() {
        return outbound[Symbol.asyncIterator]();
      },
      interrupt: async () => {
        state.interruptCount += 1;
      },
    };
  };
  return { queryFn, outbound, inbound, state };
}

async function waitFor(pred, { timeout = 2000, interval = 5 } = {}) {
  const start = Date.now();
  while (Date.now() - start < timeout) {
    if (pred()) return;
    await new Promise((r) => setTimeout(r, interval));
  }
  throw new Error('waitFor timed out');
}

async function setup() {
  const socketPath = path.join('/tmp', `ncq-${randomUUID().slice(0, 8)}.sock`);
  const server = new MockServer();
  await server.listen(socketPath);

  const mock = makeMockQuery();
  const client = new AapClient({ socketPath, reconnect: false });
  const bridge = new Bridge({
    client,
    queryFn: mock.queryFn,
    cwd: '/tmp/project',
    gateTimeoutMs: 500, // keep tests fast
  });

  client.connect();
  bridge.start().catch(() => {});
  await waitFor(() => server.handshake != null); // handshake landed

  const cleanup = async () => {
    mock.outbound.end();
    bridge.stop();
    client.close();
    await server.close();
  };
  return { server, client, bridge, mock, cleanup };
}

test('1. handshake advertises provider + capabilities', async () => {
  const { server, cleanup } = await setup();
  try {
    assert.equal(server.handshake.aap, '1');
    assert.equal(server.handshake.providerID, 'sh.claude.host');
    assert.deepEqual(
      [...server.handshake.capabilities].sort(),
      ['actuate', 'gate', 'observe'],
    );
  } finally {
    await cleanup();
  }
});

test('2. inbound actuate prompt pushes a user turn to the generator', async () => {
  const { server, mock, cleanup } = await setup();
  try {
    server.sendActuateBody({
      sessionKey: { provider: 'sh.claude.host', agentSessionID: 's1', cwd: '/tmp/project' },
      kind: 'prompt',
      text: 'run the tests',
    });
    await waitFor(() => mock.inbound.length >= 1);
    const turn = mock.inbound[0];
    assert.equal(turn.type, 'user');
    assert.equal(turn.message.role, 'user');
    assert.equal(turn.message.content, 'run the tests');
    assert.equal(turn.parent_tool_use_id, null);
  } finally {
    await cleanup();
  }
});

test('3. inbound actuate interrupt calls query.interrupt()', async () => {
  const { server, mock, cleanup } = await setup();
  try {
    server.sendActuateBody({
      sessionKey: { provider: 'sh.claude.host', agentSessionID: 's1', cwd: '/tmp/project' },
      kind: 'interrupt',
    });
    await waitFor(() => mock.state.interruptCount >= 1);
    assert.equal(mock.state.interruptCount, 1);
  } finally {
    await cleanup();
  }
});

test('4a. canUseTool emits a wantsDecision envelope and resolves ALLOW', async () => {
  const { server, mock, cleanup } = await setup();
  try {
    const resultPromise = mock.state.canUseTool(
      'Bash',
      { command: 'ls -la' },
      { toolUseID: 'tu_1' },
    );
    await waitFor(() => server.envelopes.some((e) => e.wantsDecision === true));
    const gate = server.envelopes.find((e) => e.wantsDecision === true);

    assert.equal(gate.event.kind, 'needsDecision');
    assert.equal(gate.event.providerID, 'sh.claude.host');
    assert.equal(gate.event.command, 'ls -la');
    assert.ok(gate.event.decision, 'gate carries a decision request');
    assert.equal(gate.event.decision.id, gate.id, 'decision.id === envelope id');

    server.sendDecision({ id: gate.id, verdict: 'allow' });
    const result = await resultPromise;
    assert.deepEqual(result, { behavior: 'allow' });
  } finally {
    await cleanup();
  }
});

test('4b. canUseTool resolves DENY with the reason as message', async () => {
  const { server, mock, cleanup } = await setup();
  try {
    const resultPromise = mock.state.canUseTool('Bash', { command: 'rm -rf /' }, {});
    await waitFor(() => server.envelopes.some((e) => e.wantsDecision === true));
    const gate = server.envelopes.find((e) => e.wantsDecision === true);

    server.sendDecision({ id: gate.id, verdict: 'deny', reason: 'destructive' });
    const result = await resultPromise;
    assert.equal(result.behavior, 'deny');
    assert.equal(result.message, 'destructive');
  } finally {
    await cleanup();
  }
});

test('4c. an unanswered gate fails open (null) after the timeout', async () => {
  const { mock, cleanup } = await setup();
  try {
    const result = await mock.state.canUseTool('Bash', { command: 'ls' }, {});
    assert.equal(result, null); // no decision -> defer (suppressControlResponse)
  } finally {
    await cleanup();
  }
});

test('5. an assistant message maps to a progress observe envelope', async () => {
  const { server, mock, cleanup } = await setup();
  try {
    // system/init first, so the session id is adopted and 'started' emitted.
    mock.outbound.push({
      type: 'system',
      subtype: 'init',
      session_id: 'sdk-session-123',
      model: 'claude-opus-4-8',
      cwd: '/tmp/project',
    });
    mock.outbound.push({
      type: 'assistant',
      session_id: 'sdk-session-123',
      message: { role: 'assistant', content: [{ type: 'text', text: 'Hello there' }] },
      parent_tool_use_id: null,
    });

    await waitFor(() =>
      server.envelopes.some(
        (e) => e.event.kind === 'progress' && e.event.title === 'Hello there',
      ),
    );
    const progress = server.envelopes.find((e) => e.event.kind === 'progress');
    assert.equal(progress.wantsDecision, false);
    assert.equal(progress.event.agentSessionID, 'sdk-session-123');

    // and the init produced a 'started' with the adopted session id
    const started = server.envelopes.find((e) => e.event.kind === 'started');
    assert.ok(started, 'started envelope emitted from init');
    assert.equal(started.event.agentSessionID, 'sdk-session-123');
  } finally {
    await cleanup();
  }
});

test('6. tool_use assistant block renders a command', async () => {
  const { server, mock, cleanup } = await setup();
  try {
    mock.outbound.push({
      type: 'assistant',
      session_id: 's',
      message: {
        role: 'assistant',
        content: [
          { type: 'tool_use', id: 'tu_9', name: 'Read', input: { file_path: '/etc/hosts' } },
        ],
      },
      parent_tool_use_id: null,
    });
    await waitFor(() =>
      server.envelopes.some((e) => e.event.command === 'Read /etc/hosts'),
    );
    const ev = server.envelopes.find((e) => e.event.command === 'Read /etc/hosts');
    assert.equal(ev.event.kind, 'progress');
    assert.equal(ev.event.payload.type, 'tool_use');
    assert.equal(ev.event.payload.name, 'Read');
  } finally {
    await cleanup();
  }
});

test('7. result message maps to a finished envelope', async () => {
  const { server, mock, cleanup } = await setup();
  try {
    mock.outbound.push({
      type: 'result',
      subtype: 'success',
      is_error: false,
      result: 'done',
      num_turns: 1,
      session_id: 's',
    });
    await waitFor(() => server.envelopes.some((e) => e.event.kind === 'finished'));
    const fin = server.envelopes.find((e) => e.event.kind === 'finished');
    assert.equal(fin.wantsDecision, false);
    assert.equal(fin.event.command, 'done');
  } finally {
    await cleanup();
  }
});
