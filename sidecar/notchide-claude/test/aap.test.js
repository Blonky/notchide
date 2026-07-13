// aap.test.js — pure framing/wire-shape tests (no socket).
// These pin the JSON shapes to the Swift IPCProtocol.swift encoders/decoders.

import test from 'node:test';
import assert from 'node:assert/strict';

import {
  buildHandshake,
  buildAgentEvent,
  buildEnvelope,
  classifyFrame,
  parseActuate,
  parseDecision,
  defaultSocketPath,
  PROVIDER_ID,
} from '../src/aap.js';

test('handshake shape matches aap/1', () => {
  const h = buildHandshake();
  assert.equal(h.aap, '1');
  assert.equal(h.providerID, 'sh.claude.host');
  assert.deepEqual([...h.capabilities].sort(), ['actuate', 'gate', 'observe']);
});

test('classifyFrame dispatches by top-level key', () => {
  assert.equal(classifyFrame({ aap: '1' }), 'handshake');
  assert.equal(classifyFrame({ actuate: {} }), 'actuate');
  assert.equal(classifyFrame({ verdict: 'allow' }), 'decision');
  assert.equal(classifyFrame({ event: {} }), 'envelope');
  assert.equal(classifyFrame({ nope: 1 }), 'unknown');
  assert.equal(classifyFrame(null), 'unknown');
});

test('parseActuate normalizes prompt/interrupt', () => {
  const prompt = parseActuate({
    actuate: {
      sessionKey: { provider: 'sh.claude.host', agentSessionID: 's', cwd: '/w' },
      kind: 'prompt',
      text: 'go',
    },
  });
  assert.equal(prompt.kind, 'prompt');
  assert.equal(prompt.text, 'go');

  const interrupt = parseActuate({ actuate: { kind: 'interrupt' } });
  assert.equal(interrupt.kind, 'interrupt');
  assert.equal(interrupt.text, null);

  assert.equal(parseActuate({ actuate: { kind: 'bogus' } }), null);
});

test('parseDecision requires id + verdict', () => {
  const d = parseDecision({ id: 'abc', verdict: 'deny', reason: 'no' });
  assert.deepEqual(d, { id: 'abc', verdict: 'deny', reason: 'no', redirect: null });
  assert.equal(parseDecision({ verdict: 'allow' }), null);
  assert.equal(parseDecision({ id: 'x' }), null);
});

test('buildAgentEvent uses flat fields and omits absent optionals', () => {
  const ev = buildAgentEvent({
    agentSessionID: 'sid',
    cwd: '/w',
    kind: 'progress',
    payload: { a: 1 },
    at: 1752350400,
  });
  assert.equal(ev.providerID, PROVIDER_ID);
  assert.equal(ev.agentSessionID, 'sid'); // flat, not nested sessionKey
  assert.equal(ev.cwd, '/w');
  assert.equal(ev.kind, 'progress');
  assert.equal(ev.at, 1752350400);
  assert.ok(!('title' in ev), 'absent title omitted');
  assert.ok(!('command' in ev), 'absent command omitted');
  assert.ok(!('decision' in ev), 'absent decision omitted');
});

test('buildAgentEvent carries decision only for needsDecision', () => {
  const gated = buildAgentEvent({
    agentSessionID: 'sid',
    kind: 'needsDecision',
    decision: { id: 'u1', prompt: 'rm -rf build/' },
  });
  assert.deepEqual(gated.decision, { id: 'u1', prompt: 'rm -rf build/' });

  const notGated = buildAgentEvent({
    agentSessionID: 'sid',
    kind: 'progress',
    decision: { id: 'u1', prompt: 'x' },
  });
  assert.ok(!('decision' in notGated), 'decision dropped when kind !== needsDecision');
});

test('buildEnvelope requires all three fields', () => {
  const env = buildEnvelope({ id: 'e1', event: { kind: 'progress' }, wantsDecision: true });
  assert.deepEqual(Object.keys(env).sort(), ['event', 'id', 'wantsDecision']);
  assert.equal(env.wantsDecision, true);
});

test('defaultSocketPath honors NOTCHIDE_SOCKET_PATH override', () => {
  assert.equal(defaultSocketPath({ NOTCHIDE_SOCKET_PATH: '/tmp/x.sock' }), '/tmp/x.sock');
  const fallback = defaultSocketPath({});
  assert.ok(fallback.endsWith('/notchide/agent.sock'));
});
