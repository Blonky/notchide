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

  const client = new AapClient({ socketPath, log });
  const bridge = new Bridge({ client, queryFn: query, cwd, sdkOptions, log });

  let shuttingDown = false;
  const shutdown = (code) => {
    if (shuttingDown) return;
    shuttingDown = true;
    log('shutting down');
    try {
      bridge.stop();
    } catch { /* ignore */ }
    try {
      client.close();
    } catch { /* ignore */ }
    // Give sockets a tick to flush, then exit.
    setTimeout(() => process.exit(code), 50).unref?.();
  };

  process.on('SIGINT', () => shutdown(0));
  process.on('SIGTERM', () => shutdown(0));

  client.connect();

  try {
    // Resolves when the SDK stream ends; rejects on a spawn/stream failure.
    await bridge.start();
    log('session stream ended');
    shutdown(0);
  } catch (err) {
    if (looksLikeMissingBinary(err)) {
      log('FATAL: could not spawn the Claude Code binary.');
      log('The @anthropic-ai/claude-agent-sdk ships a bundled `claude`; if it did');
      log('not install for this platform, reinstall deps or set');
      log('NOTCHIDE_CLAUDE_EXECUTABLE to a valid `claude` path.');
    } else {
      log(`FATAL: session failed: ${err?.message ?? err}`);
    }
    shutdown(1);
  }
}

main().catch((err) => {
  log(`FATAL: ${err?.stack ?? err}`);
  process.exit(1);
});
