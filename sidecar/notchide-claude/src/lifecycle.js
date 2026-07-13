// lifecycle.js — HOST-sidecar self-termination.
//
// The HOST sidecar owns a live, PAID Claude query. Its only lifeline is the AAP
// socket to the notchide hub (its parent process). If the hub dies, that socket
// EOFs ('end') and then closes ('close'); a transport fault surfaces as
// 'error'. In ANY of those cases — or on a SIGTERM/SIGINT — the sidecar MUST
// tear down its streaming query and exit, so it never orphans a running paid
// session behind a dead hub.
//
// The teardown+exit is funnelled through `SelfExit.trigger`, which fires exactly
// once. The exit itself is INJECTABLE (`onExit`, defaulting to `process.exit`)
// so a test can assert the whole teardown path WITHOUT killing the test runner.

/**
 * One-shot self-termination coordinator.
 *
 * Wire it to the AAP socket (`watchSocket`) and the process signals
 * (`watchSignals`); the first lifeline-loss or signal calls `teardown()` (which
 * should abort the live query) and then `onExit(code)`.
 */
export class SelfExit {
  /**
   * @param {object}   opts
   * @param {Function} opts.teardown  tears down the live query (abort + stop).
   * @param {Function} [opts.onExit]  exit callback; defaults to `process.exit`.
   *                                  Injected in tests so the runner survives.
   * @param {Function} [opts.log]
   */
  constructor({ teardown, onExit = (code) => process.exit(code), log = () => {} }) {
    this.teardown = teardown;
    this.onExit = onExit;
    this.log = log;
    this._fired = false;
  }

  /**
   * Run teardown + exit exactly once. Subsequent calls are no-ops, so redundant
   * lifeline events (e.g. 'end' immediately followed by 'close') collapse to a
   * single clean shutdown. Teardown errors are swallowed — losing the lifeline
   * must still lead to exit.
   */
  trigger(reason, code = 0) {
    if (this._fired) return;
    this._fired = true;
    this.log(`self-exit: ${reason}; tearing down query and exiting (${code})`);
    try {
      this.teardown();
    } catch (err) {
      this.log(`self-exit: teardown error: ${err?.message ?? err}`);
    }
    this.onExit(code);
  }

  /**
   * Watch the AAP lifeline socket. Any of 'end' (peer EOF), 'close' (socket
   * gone), or 'error' (transport fault) means the hub is unreachable → exit.
   * Attaches to the raw socket so it observes an 'error' that arrives even
   * before a successful connect.
   */
  watchSocket(socket) {
    if (!socket || typeof socket.on !== 'function') return;
    socket.on('end', () => this.trigger("socket 'end' (hub EOF)"));
    socket.on('close', () => this.trigger("socket 'close' (hub gone)"));
    socket.on('error', (err) =>
      this.trigger(`socket 'error' (${err?.message ?? err})`),
    );
  }

  /**
   * Register SIGTERM/SIGINT handlers that tear down and exit cleanly, so a
   * `kill` of the sidecar also stops the paid query rather than dropping it.
   */
  watchSignals(proc = process) {
    proc.on('SIGTERM', () => this.trigger('SIGTERM'));
    proc.on('SIGINT', () => this.trigger('SIGINT'));
  }
}
