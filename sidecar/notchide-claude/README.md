# notchide-claude

HOST-mode sidecar that lets the MacBook notch drive a **Claude Code** session by
voice. It bridges the [Claude Agent SDK](https://www.npmjs.com/package/@anthropic-ai/claude-agent-sdk)
to notchide's **AAP** (Agent Adapter Protocol) Unix socket.

Where the reference `notchide-hook` adapter only *observes* and *gates* a Claude
Code session that a human started, this sidecar is the **host**: it *runs* the
session itself and accepts **actuate** frames (voice prompts / interrupts) pushed
from the notch. It advertises `observe`, `gate`, and `actuate` under the provider
id **`sh.claude.host`**.

## What it does

```
   notch (notchide app)                     this sidecar                 Claude Agent SDK
 ┌──────────────────────┐   AAP / NDJSON  ┌──────────────┐   query()   ┌───────────────┐
 │ voice: "run the tests"├───actuate──────▶│   bridge.js  ├────push─────▶│  user turn    │
 │ tap Allow / Deny      ├───decision─────▶│  (canUseTool)│             │  tool gate    │
 │ lane / glyph console  │◀──envelope──────┤              │◀───stream───┤  assistant... │
 └──────────────────────┘                 └──────────────┘             └───────────────┘
```

- **actuate `prompt`** → pushed as an `SDKUserMessage` (a user turn) into the
  long-lived streaming-input `query(...)`.
- **actuate `interrupt`** → `query.interrupt()` (barge-in).
- **`canUseTool(name, input)`** → a blocking `needsDecision` envelope
  (`wantsDecision:true`); the bridge awaits the correlated `AgentDecision`
  frame and resolves the SDK permission callback to allow/deny.
- **SDK stream messages** → observe envelopes: `system/init` → `started`,
  assistant text / tool_use → `progress`, `result` → `finished` / `errored`.

## How notchide launches it

Spawn `npm start` (or `node src/index.js`) with:

| Env var | Purpose |
| --- | --- |
| `NOTCHIDE_SOCKET_PATH` | AAP socket path. Defaults to `~/Library/Application Support/notchide/agent.sock`. |
| `ANTHROPIC_API_KEY` | Model credential. Optional if the user's existing `claude` login/auth is present — the bundled CLI uses it. |
| `NOTCHIDE_CLAUDE_EXECUTABLE` | Optional path to a `claude` binary, forwarded to the SDK as `pathToClaudeCodeExecutable`. The SDK ships a bundled `claude`, so this is only needed to override it. |
| `NOTCHIDE_CWD` | Working directory for the session (defaults to the process cwd). |
| `NOTCHIDE_HOOK_TIMEOUT_MS` | Blocking-gate timeout. Default `600000` (10 min), clamped to `[0, 3600000]`. On timeout the gate fails open (defers). |

The `claude` binary is spawned **by the SDK**. If it is absent/unspawnable the
sidecar logs a clear message and exits **non-zero** — unlike the fail-open hook
adapter, the sidecar is not in an agent's fail-open path, so a hard failure here
is correct and visible.

## Local-first

The only network egress is the model call made by the bundled Claude Code CLI.
The AAP transport is an owner-only (`0600`) Unix domain socket on the same
machine — there is no TCP, no port, no listener. See
`/Users/zacsong/notchide/docs/PROTOCOL.md`.

## Run it standalone (for testing)

```bash
npm install

# point at a scratch socket and start the host sidecar
NOTCHIDE_SOCKET_PATH=/tmp/agent.sock npm start
```

You need the notchide app (or a stand-in server) listening on that socket to see
envelopes and to push actuate frames back. The protocol path itself is covered
by the tests below, which need neither the app nor the real `claude` binary.

## Tests

```bash
npm test
```

`test/aap.test.js` pins the pure wire shapes to the Swift `IPCProtocol.swift`
encoders. `test/bridge.test.js` runs the real `AapClient` against an in-process
mock unix-socket server with a **mock injected `query`** (the SDK `query` is
dependency-injected into the bridge), verifying the handshake, actuate
prompt/interrupt, the canUseTool↔gate round-trip (allow/deny/fail-open), and
assistant/tool/result → observe envelope mapping.

## Layout

| File | Role |
| --- | --- |
| `src/aap.js` | AAP socket client: connect/reconnect, NDJSON framing, frame builders + classifier (pure, tested). |
| `src/bridge.js` | Core bridge: one long-lived `query`, actuate→turn/interrupt, canUseTool→gate, stream→observe envelopes. |
| `src/index.js` | Entrypoint: wire client + bridge, reconnect/backoff, clean shutdown, non-zero exit on missing `claude`. |
