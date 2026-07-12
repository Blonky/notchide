# Example AAP adapters

Runnable, minimal adapters for the [Agent Adapter Protocol](../../docs/PROTOCOL.md)
(`aap/1`). An adapter is any process that opens the notchide agent socket, sends
an AAP handshake, and streams `AgentEvent`s. It does **not** link notchide and can
be written in any language.

## `minimal-observe.sh`

A ~40-line POSIX-sh, **observe-only** adapter. It connects to the socket, performs
the handshake with `capabilities: ["observe"]`, emits a `started` and a `finished`
event for a fake session, and exits. Because it only observes, it never gates and
never waits for a decision — it is pure fan-in.

### Run it

1. **Start notchide.** The app owns and creates the socket at
   `~/Library/Application Support/notchide/agent.sock`. Nothing to configure.
2. **Run the adapter:**

   ```sh
   sh examples/adapters/minimal-observe.sh
   ```

   To point it at a non-default socket (dev, tests, a second instance):

   ```sh
   NOTCHIDE_SOCKET_PATH=/tmp/notchide-dev.sock sh examples/adapters/minimal-observe.sh
   ```

Requirements: a POSIX shell, `nc` with Unix-socket support (`-U` — ships with
macOS), `uuidgen`, and `date`. If the socket is absent the script prints a hint and
exits non-zero (it is a demo, not an agent — a *real* adapter would fail open and
never surface an error to its agent; see [PROTOCOL.md §8](../../docs/PROTOCOL.md)).

### How it appears in the cockpit

- A new **lane** appears for the session, keyed by
  `(providerID, agentSessionID, cwd)` — here `com.example.observe` in your current
  directory.
- The `started` event glyphs the lane **`flowing`**; the `finished` event settles
  it to **`done`**. The lane label reflects the `cwd`.
- Because the adapter advertised only `observe`, it is **notify-only**: it can
  never reach the `needsYou` state and never shows allow/deny/ask buttons, even if
  it (incorrectly) sent a `needsDecision` event. Gating requires the `gate`
  capability. See the [capability model](../../docs/PROTOCOL.md#2-capability-model).

## Going further — a gating adapter

To *block* an agent on a human decision, advertise `gate` in the handshake, send an
envelope with `wantsDecision: true` and `kind: "needsDecision"` (carrying a
`decision` object), then read one line back — the [decision frame](../../docs/PROTOCOL.md#6-the-decision-frame) —
bounded by a **hard timeout**, and **fail open** if none arrives. The Claude Code
reference adapter (`Sources/notchide-hook/main.swift`) is the worked example; the
[protocol spec](../../docs/PROTOCOL.md) is normative.
