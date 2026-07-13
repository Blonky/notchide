# notchide — Supervision & process lifecycle

> **Status:** normative. The process-ownership and lifecycle rules the app and its children obey.
> If the code and this document disagree, that is a bug — file it.
> The product *why* is [DESIGN.md](DESIGN.md); the wire is [PROTOCOL.md](PROTOCOL.md); the
> engineering view is [ARCHITECTURE.md](ARCHITECTURE.md).

notchide is not one process — it is a small constellation that outlives any single agent session:
a menu-bar-less hub, an embedded host sidecar it spawns, the agents themselves, and the short-lived
hook processes an agent runs. This document is the contract for **who owns what**, **who supervises
whom**, and **how every long-lived resource is reclaimed** after a crash, a disconnect, or a
relaunch. It is the app-side complement to the wire's fail-open guarantee
([PROTOCOL.md §9](PROTOCOL.md#9-correlation--fail-open-normative)): the protocol promises an agent
is never bricked; this document promises notchide never leaks a socket, a thread, a child process,
or a parked gate.

---

## 1. The ownership tree

There is exactly one hub, and everything long-lived hangs off it:

```
launchd / SMAppService (login item)
└─ notchide.app  (LSUIElement — the hub)
   │  owns, and is the sole owner of:
   │    • agent.sock (the AAP Unix socket listener)
   │    • SessionStore + WorkspaceStore (actors)
   │    • the OTLP :4318 loopback receiver (observe-only)
   │    • the CGEventTap (push-to-talk) + SpeechAnalyzer (on-device STT)
   │    • the NSPanel (pill/console) + the WKWebView (live preview)
   └─ Node host sidecar  (sh.claude.host)   ← the hub's CHILD process

   (separate, NOT owned by notchide:)
   • agent CLIs (Claude Code, Codex, …)     ← the user's / a terminal's processes
     └─ PreToolUse hook processes           ← children of the AGENT, never of notchide
```

Read the tree by two rules:

- **The hub owns every durable resource.** The `notchide.app` process (an `LSUIElement`, no Dock
  icon) is the single owner of the AAP socket, the two stores, the OTLP receiver, the event tap,
  the speech recognizer, and the on-screen `NSPanel`/`WKWebView`. Nothing else creates or binds any
  of these.
- **The hook is the agent's child, not notchide's.** A `PreToolUse` hook process is spawned by
  **Claude Code** and connects *inward* to `agent.sock` as an AAP adapter. notchide never spawns,
  parents, or supervises a hook — it only accepts its connection. Losing the hub therefore cannot
  strand a hook: the hook fails open on its own deadline
  ([PROTOCOL.md §9](PROTOCOL.md#9-correlation--fail-open-normative)).

The **Node host sidecar** (`sh.claude.host`, [DESIGN.md §12.3](DESIGN.md#123-host-vs-attach)) is the
one process notchide **does** spawn and parent. Agent CLIs are the user's processes; notchide
observes them over the wire but does not own their lifetime.

---

## 2. Exactly one supervisor per process

Every process in the tree has **one** supervisor, and no process is double-managed:

| Process | Its one supervisor | Mechanism |
| ------- | ------------------ | --------- |
| `notchide.app` (hub) | the OS login item | **`SMAppService`** registers the hub as a login item; launchd relaunches it. |
| Node host sidecar | the hub | the hub spawns it, tracks its pgid, and is the only thing that starts/stops it (§3.2). |
| agent CLI | the user / terminal | not notchide's to supervise. |
| `PreToolUse` hook | its agent CLI | a child of Claude Code; fails open independently (§1). |

The rule is **no double-management**: the sidecar is supervised by the hub and by nothing else (not
launchd, not a second watcher); the hub is supervised by the login item and by nothing else. Two
supervisors racing to restart one process is a class of bug this structure forecloses.

---

## 3. The lifecycle rails

Six rails make the tree self-healing. Each is about reclaiming a specific resource when a peer
vanishes.

### 3.1 Gate-continuation teardown (the app-side dual of fail-open)

A blocking gate is held app-side as a parked `CheckedContinuation` (ARCHITECTURE §6). If the
adapter's connection **closes while a gate is still parked** — the hook timed out and hung up, the
agent was killed, the socket dropped — the app MUST resume that continuation as **abandoned** and
**clear the lane's pending decision**, rather than leave a phantom `needsYou` lane and a leaked
thread. This is the exact mirror of the wire's fail-open: the adapter stops waiting on *its*
deadline; the app stops waiting the instant the connection ends. Neither side can strand the other.

### 3.2 Sidecar reclaim

The hub is the sidecar's only supervisor (§2), so a hub crash must not orphan a Node process:

- On spawn, the hub persists the sidecar's **process-group id (`pgid`)** to a file in the support
  directory.
- The sidecar **self-exits on `agent.sock` EOF** — if the hub dies, the sidecar's connection to the
  hub drops and it shuts itself down.
- On the **next hub launch**, the persisted pgid is **reclaimed or killed** before a fresh sidecar
  is spawned, so at most one host sidecar is ever live.

Belt (self-exit on EOF) and suspenders (pgid reclaim on relaunch): a crashed hub leaves no orphaned
Node process behind.

### 3.3 Bounded connection threads + NDJSON line cap

The socket server runs a dedicated `Thread` per connection (ARCHITECTURE §6). Two bounds keep an
adversarial or buggy peer from exhausting the hub:

- **Bounded threads.** A **semaphore** caps concurrent connection threads; **beyond the cap the app
  accepts-then-closes** (a connection is never left half-open on the backlog, and the thread pool
  can't grow without limit).
- **1 MiB NDJSON line cap.** Each NDJSON line ([PROTOCOL.md §3](PROTOCOL.md#3-transport--framing))
  is read up to **1 MiB**; a line that never terminates is not buffered unboundedly — the
  connection is dropped. A hostile peer cannot OOM the hub with one giant "line".

### 3.4 Store durability — snapshot + event log, reconciled by liveness TTL

`SessionStore` and `WorkspaceStore` persist as a **snapshot + append-only event log** in the
`0700` support directory. On relaunch the hub replays them, then **reconciles by a liveness TTL**:
a lane whose owning connection is gone and whose last event is older than the TTL is treated as
stale and retired, rather than resurrected as a live-looking session. So a relaunch restores
genuine in-flight context without reviving dead lanes.

### 3.5 CGEventTap health monitor

A `CGEventTap` is not fire-and-forget — the OS disables it under load or on user input, and it is
bound to the app's code identity. A **health monitor** re-arms it:

- on **`kCGEventTapDisabledByTimeout`** and **`kCGEventTapDisabledByUserInput`** (the OS's two
  disable reasons), the tap is **re-enabled**; and
- on a **code-identity change** (a re-sign / update that invalidates the TCC grant, see
  [DESIGN.md §10.3](DESIGN.md#103-packaging--code-signing-hardened-runtime-developer-id-notarize--staple)),
  the tap is re-created against the new identity.

Without this, push-to-talk ([DESIGN.md §12.7](DESIGN.md#127-hotkeys--the-permissions-they-need))
would silently die the first time the OS timed the tap out.

### 3.6 Stale-socket handling

A crashed hub can leave a stale `agent.sock` on disk, which would make a fresh bind fail. Before
binding, the hub:

1. takes an **`flock`** on a lock file (so two hubs never race to own the socket),
2. **connect-probes** the existing socket path — if something answers, another live hub owns it and
   this one defers, and
3. **unlinks the socket iff it is stale** (no live peer) and only then binds.

The bind still follows the `0600`-before-`listen()` order of
[PROTOCOL.md §3.1](PROTOCOL.md#31-local-first-security-requirements-normative); this rail only
governs *reclaiming a dead predecessor's* socket file, never relaxing its permissions.

---

## 4. Invariants (the one-line summary)

- **One hub owns every durable resource; the hook is the agent's child, never notchide's** (§1).
- **One supervisor per process; nothing is double-managed** (§2).
- **A dropped connection never strands its peer** — the gate resumes abandoned app-side (§3.1),
  the sidecar self-exits and is reclaimed (§3.2), and stale sockets are unlinked before bind (§3.6).
- **A hostile peer cannot exhaust the hub** — bounded threads and a 1 MiB line cap (§3.3).
- **A relaunch restores real context, not dead lanes** — snapshot + log reconciled by liveness TTL
  (§3.4).
- **The event tap re-arms itself** across OS disables and re-signs (§3.5).
