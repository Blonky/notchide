# AAP — the Agent Adapter Protocol, v1

> **Status:** normative specification for wire version `aap/1`.
> This document describes the protocol as implemented in `NotchideKit`. If the
> code and this document disagree, that is a bug — file it.

AAP is a small, local, vendor-neutral protocol for **routing an agent's attention
events to a human and carrying a decision back**. It is to coding agents roughly
what LSP is to editors and DAP is to debuggers: one wire format that any number of
agents ("adapters") speak, and any number of consoles ("apps") consume.

notchide is one such app — it renders those events in the MacBook notch and lets
you approve, deny, or redirect a blocked agent. But nothing in the protocol is
notchide-specific, and nothing in it is Claude-specific. An adapter emits
`AgentEvent`s tagged with a `providerID`; the app fans them into a lane/glyph
model and, for adapters that ask, hands a decision back.

---

## 1. Goals — why a protocol, not an SDK

- **Agent-agnostic by construction.** The core value types (`AgentEvent`,
  `Capability`, `AgentDecision`) know nothing about any vendor. Claude Code is a
  *reference adapter*, not a special case: its snake_case field names and event
  vocabulary live entirely in one translation unit and never leak past the wire.
- **A wire, not a library.** An adapter is any process that can open a Unix
  socket and write two kinds of JSON line. It does not link notchide, is not
  written in Swift, and ships and versions independently. That is the whole point
  of specifying a protocol instead of publishing an SDK.
- **Local-first and fail-open.** The transport is an owner-only Unix socket on the
  same machine; there is no network surface. And an adapter is **never** made
  load-bearing in front of its agent — if the app is slow, absent, or wedged, the
  adapter proceeds with the agent's own default (§8).
- **Lenient and forward-compatible.** Decoders never throw on unknown or missing
  fields, so a newer adapter and an older app (or vice versa) degrade gracefully
  instead of hard-failing (§7).

---

## 2. Capability model

Every adapter announces, in its handshake, what it is able to do. Capabilities are
additive and independent:

| Capability | Meaning                                                        | Unlocks |
| ---------- | ------------------------------------------------------------- | ------- |
| `observe`  | Report status/progress (read-only).                          | Lanes, glyphs, the ambient cockpit. |
| `gate`     | Block the agent while awaiting a permission decision.        | The `needsYou` lane state, decision buttons, and a decision frame written back. |
| `actuate`  | Accept actions back (resume / answer). *(App-side, reserved.)* | Push actions to the agent. `actuate` has a no-op default; observe/gate adapters need not implement it. |

The capability that matters most on the wire is `gate`, because it is the one that
can seize the user. From the announced capability set the app derives a
**decision capability**:

- an adapter that advertises **`gate`** is **blocking** — its `needsDecision`
  events can escalate to `needsYou` and show allow/deny/ask buttons;
- an adapter that does **not** advertise `gate` is **notify-only** — it is
  **structurally unable** to reach `needsYou`. This is not a policy the app chooses
  to honor; it is enforced in the classifier (`SessionStore.laneState`) and in the
  escalation policy (`Suppressor.isHardBlock`). A notify-only adapter's
  `needsDecision`/`notified` kinds are clamped to `flowing`, and the app never
  writes a decision frame back to it.

This is the security spine of the platform. A contributed adapter — a third-party
manifest, an untrusted process — can *observe* freely, but it can only ever *gate*
(and thus approve a command like `rm -rf`) if it advertised `gate` on a socket that
is, by construction, owner-only and same-machine (§4). Absent `gate`, escalation is
impossible, not merely discouraged.

---

## 3. Transport & framing

- **Transport.** A **Unix-domain stream socket** (`AF_UNIX`, `SOCK_STREAM`) at:

  ```
  ~/Library/Application Support/notchide/agent.sock
  ```

  The environment variable `NOTCHIDE_SOCKET_PATH`, when set and non-empty,
  overrides this path (used for tests, dev, and multiple instances). A legacy
  alias `hook.sock` exists for adapters written before the AAP generalization; new
  adapters MUST target `agent.sock` (or the `NOTCHIDE_SOCKET_PATH` override).

- **Framing.** **NDJSON** — newline-delimited JSON. Each frame is exactly one JSON
  object on one line, terminated by `\n`. Every line is independently parseable,
  which keeps readers trivial and the stream inspectable with `nc`/`jq`.

- **Direction.** Frames flow both ways on the *same* connection: the adapter writes
  a handshake then one or more envelopes; for a blocking gate the app writes one
  decision back on that same open connection.

### 3.1 Local-first security requirements (normative)

The socket is a channel through which a decision can **approve arbitrary
commands**, so its reachability is a security property, not a convenience:

- The app MUST bind on the local filesystem only and MUST NOT bind anything
  routable. There is no TCP, no port, no network listener of any kind.
- The socket file MUST be `0600` (owner read/write only). The reference
  implementation `chmod`s to `0600` **before** `listen()`, so the socket is never
  reachable while world-accessible.
- The containing directory
  (`~/Library/Application Support/notchide`) is created `0700`.
- Peers MUST be the same machine and, by the `0600`/`0700` perms, the same user.

An app MUST NOT accept AAP frames over any transport that relaxes these
guarantees.

---

## 4. The handshake frame

The **first** NDJSON line on every connection, written by the adapter:

```json
{"aap":"1","providerID":"sh.claude","capabilities":["gate","observe"]}
```

| Field          | Type       | Required | Notes |
| -------------- | ---------- | -------- | ----- |
| `aap`          | string     | yes      | Wire version. MUST be `"1"`. Any other value (or a missing/malformed handshake) causes the app to **close the connection** — the adapter then sees EOF and falls open (§8). |
| `providerID`   | string     | yes      | Stable, reverse-DNS provider identity, e.g. `"sh.claude"`. Encodes as a bare JSON string. |
| `capabilities` | string[]   | yes      | Subset of `observe` / `gate` / `actuate`. Unknown capability strings are dropped, not rejected. Encoded sorted; order is not significant. |

The app validates `aap == "1"`, records the advertised capabilities for the
connection, and derives the decision capability (§2). An `AgentEnvelope` has no
`aap` field, so an envelope can never be mistaken for a valid handshake.

Capabilities are **per connection**. Everything the adapter sends on that
connection is bounded by what it announced here: escalation from an adapter that
did not advertise `gate` is ignored for the life of the connection.

---

## 5. The envelope frame

Every subsequent line from the adapter is an **envelope** carrying one event:

```json
{
  "id": "550e8400-e29b-41d4-a716-446655440000",
  "event": { "...": "AgentEvent, see 5.1" },
  "wantsDecision": true
}
```

| Field          | Type          | Required | Notes |
| -------------- | ------------- | -------- | ----- |
| `id`           | string (UUID) | yes      | Correlation id. The eventual decision frame echoes it. Shared with the event's `decision.id` for a gate. |
| `event`        | object        | yes      | The `AgentEvent` (§5.1). |
| `wantsDecision`| boolean       | yes      | `true` **only** when a `gate` adapter is blocking on a decision for this frame (i.e. a `needsDecision` event). `false` for all fire-and-forget frames. |

> **Strictness note.** The envelope's three top-level fields are all required —
> the envelope decoder is *not* lenient about them. (The `event` object *is*
> decoded leniently; see §5.1.) An adapter MUST send all three.

The app writes a decision back **iff** `wantsDecision == true` **and** the
connection's capabilities include `gate`. A `wantsDecision` from a non-gate adapter
is ignored (no frame is written), and the adapter's wait simply times out into
fail-open (§8).

### 5.1 The `AgentEvent` object

The vendor-neutral event. Its decoder is deliberately lenient (it mirrors the
Claude hook decoder): it never throws on unknown or missing fields, so an odd frame
degrades gracefully rather than breaking the fan-in.

| Field            | Type          | Required                         | Notes |
| ---------------- | ------------- | -------------------------------- | ----- |
| `providerID`     | string        | yes*                             | Originating provider, e.g. `"sh.claude"`. Defaults to `""` if absent. |
| `agentSessionID` | string        | yes*                             | The vendor's session id. Defaults to `""`. The app forms the lane key from `(providerID, agentSessionID, cwd)` — see §9. |
| `cwd`            | string        | yes*                             | Working directory. Defaults to `""`. Always encoded by the reference adapter. |
| `kind`           | string        | yes*                             | One of `started`, `progress`, `needsDecision`, `notified`, `finished`, `errored`. An unknown or absent kind **degrades to `errored`** (an unclassifiable event). |
| `title`          | string        | no                               | Short human label. **Omitted when absent** (not sent as `null`). |
| `command`        | string        | no                               | Human-readable command for the lane. **Omitted when absent.** |
| `decision`       | object        | present **iff** `kind == needsDecision` | `{ "id": "<uuid>", "prompt": "<string>" }`. **Omitted otherwise.** `id` MUST be a valid UUID (typically equal to the envelope `id`); if it is not parseable the event decodes with no decision. |
| `payload`        | object        | yes*                             | The full original vendor payload, preserved losslessly. Defaults to `{}`. |
| `at`             | number        | yes*                             | Event time as **epoch seconds** (may be fractional). Defaults to `0` if absent. |

<sub>`*` The lenient decoder supplies the noted default when the field is absent, so
a partial event will still decode. A *conformant* adapter SHOULD nonetheless send
`providerID`, `agentSessionID`, `cwd`, `kind`, `payload`, and `at`.</sub>

**Event kinds map onto four fixed lane states** (the whole glyph vocabulary):

| Kind            | Lane state (blocking adapter) | Lane state (notify-only adapter) |
| --------------- | ----------------------------- | -------------------------------- |
| `started`       | `flowing`                     | `flowing` |
| `progress`      | `flowing`                     | `flowing` |
| `needsDecision` | `needsYou`                    | `flowing` (clamped — §2) |
| `notified`      | `needsYou`                    | `flowing` (clamped — §2) |
| `finished`      | `done`                        | `done` |
| `errored`       | `error`                       | `error` |

### 5.2 Encoding note: optionals are omitted, not null

The reference encoders **omit** absent optional fields rather than emitting
explicit `null`. On an `AgentEvent`, `title` / `command` / `decision` appear only
when present; on a decision frame (§6), `reason` / `redirect` appear only when
present. Decoders accept **either** form (absent or `null`), so an adapter that
prefers to emit explicit `null`s is still conformant — but it should not *expect*
`null`s from notchide.

---

## 6. The decision frame

Written by the app back to a **blocking (`gate`)** adapter, on the same connection,
correlated by the shared `id`:

```json
{"id":"550e8400-e29b-41d4-a716-446655440000","verdict":"deny","reason":"destructive command"}
```

| Field      | Type          | Required | Notes |
| ---------- | ------------- | -------- | ----- |
| `id`       | string (UUID) | yes      | Echoes the originating envelope `id` / `decision.id`. |
| `verdict`  | string        | yes      | `allow` (approve), `deny` (block), or `ask` (defer to the agent's own permission prompt). There is no `defer` verdict — deferring is expressed by sending **no frame at all** (§8). |
| `reason`   | string        | no       | Human-readable rationale. **Omitted when absent.** |
| `redirect` | string        | no       | App-level steer (send the agent elsewhere). **Omitted when absent.** This is an app concept and is **never** forwarded into a vendor's own decision output. |

An adapter maps the verdict onto its agent's native permission mechanism. The
Claude Code reference adapter maps `allow`/`deny`/`ask` onto the
`hookSpecificOutput.permissionDecision` schema and drops `redirect` (which is not
part of Claude's schema).

---

## 7. Versioning, negotiation & forward-compatibility

- **Version tag.** The wire version is the handshake `aap` field. This document
  specifies `"1"`. The app accepts a connection **iff** `aap == "1"`; any other
  value closes the connection (which the adapter treats as fail-open).
- **Negotiation** is intentionally minimal: the adapter states a version and a
  capability set; the app accepts or closes. There is no multi-round negotiation to
  get wrong. Future revisions that must break the wire will bump `aap` to a new
  value and the app will accept the set of versions it understands.
- **Lenient decode / ignore unknown fields.** All frame decoders ignore unknown
  keys and tolerate missing ones:
  - unknown **capability** strings are dropped;
  - an unknown/absent event **kind** degrades to `errored`;
  - unknown **event** and **payload** fields are preserved (`payload`) or ignored,
    never fatal.
  This is what lets `aap/1` add optional fields later without a version bump: an
  older app ignores what it does not know, a newer app supplies defaults for what an
  older adapter omits.
- **Do not depend on field order or on `null` vs. omitted** (§5.2).

---

## 8. Correlation & fail-open (normative)

**Correlation.** Every gate carries a `UUID` in three places that MUST agree: the
envelope `id`, the event's `decision.id`, and the decision frame's `id`. The app
replies with the same UUID, so a connection may have more than one gate in flight
and each decision still pairs unambiguously with its request.

**Fail-open.** This is the load-bearing safety invariant of the whole protocol:

> If no decision arrives before the adapter's deadline — because the app is absent,
> slow, wedged, declined to decide, or the socket is missing — the adapter **MUST**
> proceed with the agent's **own default**. For a permission gate, that means
> emitting no decision so the agent's normal permission prompt runs.

An adapter **MUST NOT** block or error its agent because notchide is unavailable.
Being unable to reach notchide MUST be indistinguishable, to the agent, from
notchide not being installed at all. Concretely, in the reference adapter:

- Any connect/write failure, timeout, malformed reply, or unparseable input →
  print nothing, exit `0` (Claude Code then shows its own prompt).
- The gate wait is bounded by a hard timeout. Default **600 000 ms (10 minutes)**
  — a human may take a while — overridable via `NOTCHIDE_HOOK_TIMEOUT_MS` and
  clamped to `[0, 3 600 000]` ms so a hostile value can neither hang unbounded nor
  crash.
- Fire-and-forget (non-gate) frames use a short connect timeout and never wait.

Symmetrically, an app MUST NOT hold a `gate` connection open indefinitely without
a path to resolution, and MUST NOT write a decision to an adapter that did not
advertise `gate`.

---

## 9. Session identity & namespacing

The app keys each lane by a **`SessionKey`** = `(providerID, agentSessionID,
cwd)`, reconstructed from the flat event fields (`providerID`, `agentSessionID`,
`cwd`). Two adapters that happen to reuse the same `agentSessionID` therefore never
cross-wire into one lane, because the `providerID` differs. Enrichment providers
that legitimately describe the *same* session merge on the full tuple. Adapters
SHOULD keep `agentSessionID` stable across the events of one logical session and
SHOULD send a consistent `cwd`.

---

## 10. Conformance

An implementation is a conformant **`aap/1` adapter** if:

**MUST**

1. Connect to the socket at `agent.sock` (or `NOTCHIDE_SOCKET_PATH`) over
   `AF_UNIX`/`SOCK_STREAM`.
2. Send, as the **first** line, a handshake with `aap == "1"`, a stable
   `providerID`, and a `capabilities` array.
3. Frame every message as one JSON object per line, `\n`-terminated (NDJSON).
4. Send envelopes with all three of `id`, `event`, and `wantsDecision`.
5. Set `wantsDecision: true` **only** when it advertised `gate` and is genuinely
   blocking on a decision, and carry a `decision` object **iff**
   `kind == needsDecision`.
6. **Fail open.** On any failure to obtain a decision before its deadline, proceed
   with the agent's own default and never block or error the agent (§8). This is
   the single non-negotiable conformance requirement.
7. Never require the app to be present, and never treat the app's absence as an
   error.

**SHOULD**

8. Emit `providerID`, `agentSessionID`, `cwd`, `kind`, `payload`, and `at` on every
   event, and keep `agentSessionID` stable per logical session.
9. Tolerate the app writing no decision (fail-open path) and a decision frame with
   omitted optional fields.
10. Not advertise `gate` unless it can actually block its agent on the verdict.

A conformant **app** MUST enforce the `0600`/local-only transport (§3.1), MUST
ignore escalation from non-`gate` connections (§2, §5), MUST correlate decisions by
UUID (§8), and MUST decode leniently (§7).

---

## 11. Worked example: a blocked permission, denied

A single connection carrying the Claude Code reference adapter's handshake, one
blocking `needsDecision` envelope, and the app's `deny` reply.

```jsonc
// 1. adapter → app   handshake (first line)
{"aap":"1","providerID":"sh.claude","capabilities":["gate","observe"]}

// 2. adapter → app   envelope: a PreToolUse gate on `rm -rf build/`
{
  "id": "550e8400-e29b-41d4-a716-446655440000",
  "wantsDecision": true,
  "event": {
    "providerID": "sh.claude",
    "agentSessionID": "abc123",
    "cwd": "/Users/dev/project",
    "kind": "needsDecision",
    "command": "rm -rf build/",
    "decision": {
      "id": "550e8400-e29b-41d4-a716-446655440000",
      "prompt": "rm -rf build/"
    },
    "payload": {
      "session_id": "abc123",
      "cwd": "/Users/dev/project",
      "hook_event_name": "PreToolUse",
      "tool_name": "Bash",
      "tool_input": { "command": "rm -rf build/" }
    },
    "at": 1752350400
  }
}

//    ( adapter blocks, up to its hard timeout; app shows the notch console )

// 3. app → adapter   decision: deny (same UUID)
{"id":"550e8400-e29b-41d4-a716-446655440000","verdict":"deny","reason":"not this build path"}
```

The adapter maps the `deny` onto Claude Code's `PreToolUse` output and exits `0`.
Had the app instead sent nothing before the adapter's deadline, the adapter would
have printed nothing and exited `0` — deferring to Claude Code's own permission
prompt (§8).

---

## 12. Reference

- The vendor-neutral core types: `Sources/NotchideKit/AAPCore.swift`,
  `AgentEvent.swift`.
- The handshake/envelope/NDJSON wire types:
  `Sources/NotchideKit/IPCProtocol.swift`.
- The app-side ingress and transport: `SocketAAPProvider.swift`,
  `UnixSocketServer.swift`; the adapter-side client: `UnixSocketClient.swift`.
- The classifier and escalation policy (capability enforcement):
  `SessionStore.swift`, `Suppressor.swift`.
- The reference adapter: `Sources/notchide-hook/main.swift` and the Claude Code
  translation in `ClaudeCodeProvider.swift`.
- The machine-readable schema: [`schema/aap-1.schema.json`](../schema/aap-1.schema.json).
- A runnable minimal adapter: [`examples/adapters/`](../examples/adapters/).
