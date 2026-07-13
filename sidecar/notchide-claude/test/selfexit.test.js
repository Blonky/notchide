// selfexit.test.js — the HOST sidecar must never orphan a PAID query.
//
// The sidecar's only lifeline is the AAP socket to the notchide hub. When that
// socket drops (the hub died) — or a termination signal arrives — the sidecar
// must abort its live streaming query and exit. These tests drive a REAL Bridge
// with a MOCK "live" query (one that never finishes on its own, like a paid
// session awaiting input) and assert that a fake socket 'close'/'end'/'error',
// and a fake SIGTERM/SIGINT, each:
//   1. fire the injected exit callback (WITHOUT killing the test runner), and
//   2. abort + return the query (tear the paid session down).

import test from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';

import { Bridge, MessageQueue } from '../src/bridge.js';
import { SelfExit } from '../src/lifecycle.js';

/** A mock injected `query` that stays live until explicitly returned — it never
 *  yields a terminal message on its own, mirroring a paid session that is idle
 *  awaiting the next turn. `return()` records the teardown and ends the stream. */
function makeLiveQuery() {
  const outbound = new MessageQueue();
  const state = { returned: 0, interrupted: 0 };
  const queryFn = () => ({
    [Symbol.asyncIterator]() {
      return outbound[Symbol.asyncIterator]();
    },
    interrupt: async () => {
      state.interrupted += 1;
    },
    return: async () => {
      state.returned += 1;
      outbound.end();
      return { value: undefined, done: true };
    },
  });
  return { queryFn, outbound, state };
}

/** Wire a real Bridge + live mock query to a fresh SelfExit whose exit is a spy. */
function makeRig() {
  const mock = makeLiveQuery();
  const client = new EventEmitter();
  client.send = () => true;
  const bridge = new Bridge({ client, queryFn: mock.queryFn, cwd: '/tmp/project' });
  const run = bridge.start();
  run.catch(() => {}); // resolves once teardown returns the query

  const exit = { code: undefined, count: 0 };
  const selfExit = new SelfExit({
    teardown: () => bridge.teardown(),
    onExit: (code) => {
      exit.code = code;
      exit.count += 1;
    },
  });
  return { mock, bridge, run, exit, selfExit };
}

test("socket 'close' tears down the live query and exits", async () => {
  const { mock, bridge, run, exit, selfExit } = makeRig();
  const socket = new EventEmitter();
  selfExit.watchSocket(socket);

  socket.emit('close'); // the hub died -> lifeline lost

  assert.equal(exit.count, 1, 'exit callback fired once');
  assert.equal(exit.code, 0, 'exited cleanly (code 0)');
  assert.equal(bridge.aborted, true, 'the live query was aborted');
  assert.equal(mock.state.returned, 1, 'the query generator was returned');
  await run; // the consume loop unwinds cleanly
});

test("socket 'end' (peer EOF) also tears down and exits", async () => {
  const { bridge, run, exit, selfExit } = makeRig();
  const socket = new EventEmitter();
  selfExit.watchSocket(socket);

  socket.emit('end');

  assert.equal(exit.count, 1);
  assert.equal(bridge.aborted, true);
  await run;
});

test("socket 'error' (transport fault) also tears down and exits", async () => {
  const { bridge, run, exit, selfExit } = makeRig();
  const socket = new EventEmitter();
  selfExit.watchSocket(socket);

  socket.emit('error', new Error('ECONNRESET'));

  assert.equal(exit.count, 1);
  assert.equal(bridge.aborted, true);
  await run;
});

test('SIGTERM tears down the live query and exits', async () => {
  const { bridge, run, exit, selfExit } = makeRig();
  const proc = new EventEmitter(); // stand-in for `process`
  selfExit.watchSignals(proc);

  proc.emit('SIGTERM');

  assert.equal(exit.count, 1);
  assert.equal(bridge.aborted, true);
  await run;
});

test('teardown + exit fire exactly once across redundant lifeline events', async () => {
  const { mock, run, exit, selfExit } = makeRig();
  const socket = new EventEmitter();
  selfExit.watchSocket(socket);

  // 'end' immediately followed by 'close' is the normal EOF sequence; it must
  // collapse to a single clean shutdown, not a double teardown/exit.
  socket.emit('end');
  socket.emit('close');
  socket.emit('error', new Error('late'));

  assert.equal(exit.count, 1, 'exit fired exactly once');
  assert.equal(mock.state.returned, 1, 'the query was torn down exactly once');
  await run;
});
