#!/usr/bin/env node
// index.js — notchide-claude HOST-mode sidecar entrypoint.
//
// Wires the AAP socket client to the Claude Agent SDK bridge, manages socket
// reconnect/backoff (handled inside AapClient), and shuts down cleanly. The
// `claude` binary is spawned by the SDK; if it is absent/unspawnable this
// process logs a clear message and exits non-zero — the sidecar is NOT in an
// agent's fail-open path, so a hard failure here is correct and visible.

import { query } from '@anthropic-ai/claude-agent-sdk';
import { AapClient, defaultSocketPath } from './aap.js';
import { Bridge } from './bridge.js';
import { SelfExit } from './lifecycle.js';

function log(msg) {
  process.stderr.write(`[notchide-claude] ${msg}\n`);
}

function looksLikeMissingBinary(err) {
  const m = String(err?.message ?? err);
  return (
    err?.code === 'ENOENT' ||
    /ENOENT|not found|no such file|spawn .* failed|executable/i.test(m)
  );
}

async function main() {
  const socketPath = defaultSocketPath();
  const cwd = process.env.NOTCHIDE_CWD || process.cwd();

  log(`starting HOST sidecar (provider sh.claude.host)`);
  log(`socket: ${socketPath}`);
  log(`cwd:    ${cwd}`);

  // Optional overrides passed straight through to the SDK.
  const sdkOptions = {};
  if (process.env.NOTCHIDE_CLAUDE_EXECUTABLE) {
    sdkOptions.pathToClaudeCodeExecutable = process.env.NOTCHIDE_CLAUDE_EXECUTABLE;
  }
  sdkOptions.stderr = (data) => process.stderr.write(data);

  // reconnect is disabled: the sidecar owns a single PAID query whose only
  // lifeline is this socket. A drop means the hub (our parent) is gone — we
  // tear the query down and exit (see SelfExit) rather than reconnect and
  // orphan the running session.
  const client = new AapClient({ socketPath, log, reconnect: false });
  const bridge = new Bridge({ client, queryFn: query, cwd, sdkOptions, log });

  // Single exit path. `teardown` aborts the live query and closes the socket;
  // `onExit` flushes for a tick, then exits. Fires exactly once, whether it is
  // reached via a lost lifeline, a signal, or the stream ending normally.
  const selfExit = new SelfExit({
    teardown: () => {
      try { bridge.teardown(); } catch { /* ignore */ }
      try { client.close(); } catch { /* ignore */ }
    },
    onExit: (code) => {
      setTimeout(() => process.exit(code), 50).unref?.();
    },
    log,
  });

  // Lifeline: any socket end/close/error means the hub is unreachable → exit.
  client.on('socket', (socket) => selfExit.watchSocket(socket));
  // AapClient re-emits socket errors as a client 'error'; absorb them so an
  // error event never crashes the process before SelfExit runs.
  client.on('error', (err) => log(`aap: client error: ${err?.message ?? err}`));
  // A `kill` of the sidecar tears down the paid query too.
  selfExit.watchSignals();

  client.connect();

  try {
    // Resolves when the SDK stream ends; rejects on a spawn/stream failure.
    await bridge.start();
    log('session stream ended');
    selfExit.trigger('session stream ended', 0);
  } catch (err) {
    if (looksLikeMissingBinary(err)) {
      log('FATAL: could not spawn the Claude Code binary.');
      log('The @anthropic-ai/claude-agent-sdk ships a bundled `claude`; if it did');
      log('not install for this platform, reinstall deps or set');
      log('NOTCHIDE_CLAUDE_EXECUTABLE to a valid `claude` path.');
    } else {
      log(`FATAL: session failed: ${err?.message ?? err}`);
    }
    selfExit.trigger('session failed', 1);
  }
}

main().catch((err) => {
  log(`FATAL: ${err?.stack ?? err}`);
  process.exit(1);
});
