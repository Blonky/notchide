# notchide — Design

> The product + system design of record. If the code and this document disagree, one of them
> is a bug. Keep them in sync.

**Status:** v0.1 design, locked defaults noted inline.
**Author:** Zac Song ([@Blonky](https://github.com/Blonky)), 2026.

---

## 1. Problem & thesis

Developers now run several AI coding agents at once — a Claude Code session per worktree, per
feature, per Space. The agents are mostly autonomous, but they are not fully autonomous: they
stop at permission gates ("may I run `rm`?", "may I edit this file?"). Each gate is a small,
blocking, human-in-the-loop decision.

The problem is **attention routing**, not code. When you are heads-down in a fullscreen app on
one Space, an agent blocked on a permission three Spaces away is invisible. You either:

- **poll** — cmd-tab around every few minutes to check whether anything is stuck (breaks flow,
  wastes time), or
- **over-notify** — let every agent fire OS notifications (noise, notification fatigue, and you
  still have to switch away to actually decide).

**Thesis:** the right surface for this is the **notch**, and the right interaction is a single
object in two states — an ambient cockpit that is silent by default, and a read-only review
console that lets you **decide in place** without ever leaving the app you are in.

notchide is **one object in two states**:

- **Collapsed** = an ambient orchestration cockpit. One pre-attentive glyph per running agent
  (color + motion, no text), four states.
- **Expanded** = a read-only review console that drops down out of the notch for the single
  most-urgent session.

It does exactly two verbs — **NOTIFY** and **DECIDE** — and deliberately never the third,
**CREATE**.

---

## 2. Market gap

There are 15+ tools that put an AI agent's status into the notch or menu bar. Every one of
them is, functionally, a **read-only status or approval pill**: it *shows* you that an agent is
working, waiting, or done. Some show a notification you can dismiss.

None of them close the loop. The one move the whole category is missing is the **write
action** — **approve / deny / redirect the agent from the notch**, over your fullscreen work,
without stealing focus. That is notchide's unclaimed wedge.

Two questions that pin down the design:

- **"Why the notch and not the menu bar / a HUD / an OS notification?"** The notch is the only
  surface that floats above every fullscreen app across every Space. A menu-bar item is hidden
  behind a fullscreen app; an OS notification is transient and can't host a git diff and
  decision buttons; a HUD window steals focus. The notch is uniquely both **always-on-top**
  and **non-focus-stealing**.
- **"Why not just a window?"** A window steals keyboard focus the moment it appears. That is
  the exact anti-pattern the product exists to avoid — the whole value is deciding *without*
  leaving your current app.

---

## 3. Non-goals

Explicit non-goals keep the scope honest. notchide is deliberately **not**:

- **A code editor (in v0.1).** The review console is **read-only**. notchide shows the diff the
  agent already produced; it does not let you edit code. This is the load-bearing constraint —
  see §11 on scope gravity. (Inline editing is reconsidered no earlier than v0.3, and only if a
  stable editor component exists.)
- **A Mac App Store app.** notchide needs private frameworks the App Store forbids (see §10).
  It ships as a notarized direct-download `.dmg`.
- **A Quake-style terminal / a terminal emulator.** notchide is not where you type at your
  agent. It provides a **jump-to-terminal** escape hatch and (v0.2, behind a flag) an optional
  read-only terminal *peek*, but the terminal remains the terminal.
- **A general notification center.** notchide surfaces exactly one class of event — an agent
  blocked on a permission it can't resolve alone. It is not a home for arbitrary alerts.
- **A polling monitor.** notchide is event-driven end to end; if it ever polls, that's a bug.

---

## 4. The two states in detail

### 4.1 Collapsed — the ambient cockpit

The collapsed state lives in and around the notch. It renders **one glyph per active session**.
The glyph is **pre-attentive**: it communicates through **color and motion only**, no text, so
you can read it in peripheral vision without shifting focus.

Four states drive the glyph:

| State       | Meaning                                           | Encoding (color + motion)                  |
| ----------- | ------------------------------------------------- | ------------------------------------------ |
| `flowing`   | Agent is working, nothing needed from you         | calm hue, slow ambient motion              |
| `needs-you` | Blocked on a permission **and** not already visible | amber, a distinct pulse (+ opt-in sound)  |
| `done`      | Agent finished its turn                            | green, settle-and-hold                     |
| `error`     | Agent or hook errored                             | red, sharp attention motion                |

Only `needs-you` is an active interruption, and only after the Suppressor (§7) has confirmed you
can't already see that session.

### 4.2 Expanded — the read-only review console

When you peek (hover-intent) or summon (hotkey), the notch **morphs down** into a console for
the **single most-urgent session**. It is read-only and shows:

1. **The pending permission command** — the exact tool call the agent is blocked on, shown in
   full. Nothing is truncated or paraphrased on the write path.
2. **The decision controls** — `Approve`, `Deny`, `Approve-and-remember`, and a **one-line
   redirect** field (a short natural-language steer that is round-tripped back through the
   waiting hook).
3. **A live git diff** — a read-only, syntax-highlighted diff of what the agent just changed, so
   you approve with the change in front of you, not from memory.
4. **An output tail** — a lightweight tail of the agent's recent output for context.

Plus a **jump-to-terminal** escape hatch (AppleScript / Accessibility) for anything the hook
can't answer. Once you decide, the decision travels back down the still-open socket and the
console furls back up.

---

## 5. Architecture

Four layers. Data flows up (events) and the decision flows back down the same open socket.

### 5.1 Notch Shell

- **Responsibility:** own the on-screen object — the collapsed pill, the expanded console, the
  morph between them, and all interaction timers (hover-intent, ESC, click-to-pin,
  auto-collapse, the global summon hotkey).
- **Key types:** `NotchController` (the thin owner of pill ↔ console state and the hover-intent
  state machine).
- **Depends on:** SwiftUI/AppKit and **DynamicNotchKit** (MIT) for the `NSPanel` geometry, the
  animatable notch-shape morph, and the floating-pill fallback for external monitors and
  non-notch Macs.

### 5.2 Ingest

- **Responsibility:** get Claude Code hook events into the app reliably and cheaply, and carry a
  decision back to the blocked hook.
- **Key types:** the `notchide-hook` sidecar CLI (installed into Claude Code's hooks); a
  `UnixSocketServer` inside the app; the `SessionStore` actor with **one lane per session**.
- **Transport:** a Unix-domain socket at `~/Library/Application Support/notchide/hook.sock`,
  mode `0600`, NDJSON framing (see [ARCHITECTURE.md](ARCHITECTURE.md)).
- **Depends on:** nothing external — this whole path is in the dependency-free core so it builds
  and tests offline.

### 5.3 Attention Router

- **Responsibility:** decide *whether* a blocked lane should actually interrupt you, and drive
  the glyph.
- **Key types:** `Suppressor`, `FrontmostContextProviding` (an abstraction over "what is
  frontmost on the active Space", so the policy is testable without a live desktop), and the
  four-state glyph/`LaneState` machine.
- **Policy:** escalate a lane to `needs-you` **only** when its terminal is not the frontmost
  window on the active Space (§7).

### 5.4 Review Surface

- **Responsibility:** render the read-only decision UI and marshal the decision back to Ingest.
- **Key types:** the SwiftUI console views; the diff renderer; the output-tail view.
- **Depends on:** for the diff, the **planned** highlighting stack — **Neon** + **SwiftTreeSitter**
  (BSD-3) + **CodeEditLanguages** (MIT). These are stable, individually-versioned libraries —
  **not** a pre-1.0 editor. notchide uses them to *highlight* a diff, never to edit.

---

## 6. The hook contract

The contract between Claude Code and notchide is a single sidecar invocation per hook event.

### 6.1 `PreToolUse` — the synchronous block

When Claude Code hits a permission gate, its `PreToolUse` hook runs `notchide-hook`. That
process:

1. Reads the hook payload (`session_id`, `tool_name`, `tool_input`, `cwd`, …) from stdin.
2. Connects to `hook.sock` and sends an **envelope** carrying that payload plus a fresh request
   UUID.
3. **Blocks**, synchronously awaiting a **decision** for that UUID — this is what makes the
   agent actually wait for the human.
4. On decision, prints the corresponding Claude Code hook-decision JSON to stdout and exits `0`.

The decision maps directly onto Claude Code's `PreToolUse` output schema:

- **Approve** → `permissionDecision: "allow"`.
- **Deny** → `permissionDecision: "deny"` with a `permissionDecisionReason`.
- **Redirect** → `deny` + the one-line redirect surfaced back to the agent as the reason /
  additional context, so the agent gets a concrete steer instead of a bare refusal.
- **Approve-and-remember** → `allow` now, and the exact command string is cached so future
  identical calls auto-resolve (see §12).

```jsonc
// notchide-hook stdout on Approve — Claude Code proceeds:
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "allow"
  }
}
```

### 6.2 Fail-open — the safety guarantee

The synchronous block is a coupling risk: if notchide is down, slow, or the socket is missing,
a naive hook would **hang the agent**. notchide must never do that. `notchide-hook` therefore
enforces a **hard timeout** and **fails open**:

- Can't connect to the socket, or no decision arrives before the timeout → the sidecar exits
  **`0` with no decision**, which defers to Claude Code's **normal permission prompt**.

The agent is **never bricked** by notchide being unavailable. notchide is a convenience layer on
top of Claude Code's existing gate, never a load-bearing dependency in front of it. This is a
first-class guarantee, not an edge case — see the tests around the timeout path.

### 6.3 Which hooks

| Hook          | Why notchide registers it                                              |
| ------------- | ---------------------------------------------------------------------- |
| `PreToolUse`  | The write path — the synchronous block + decision round-trip.          |
| `Notification`| Surface Claude Code's own notifications into the cockpit.              |
| `Stop`        | Mark a lane `done` when the agent finishes its turn.                    |
| `SubagentStop`| Track subagent completion within a session.                            |

Wire-level detail and the exact `settings.json` snippet are in [HOOKS.md](HOOKS.md).

---

## 7. Smart suppression policy

The single biggest risk to this product is **annoyance** (§11). Smart suppression is the bet
against it.

**Rule:** a blocked lane escalates to `needs-you` **only if its terminal is not the frontmost
window on the active Space.** If the agent's terminal is already right in front of you, you can
see the permission prompt yourself — notchide stays silent and lets Claude Code's own prompt do
its job.

- The check runs through `FrontmostContextProviding`, so the "is this session visible?" question
  is a pure, testable predicate rather than desktop-coupled logic.
- Suppression is about **surfacing**, not **blocking**: a suppressed lane still holds its
  pending decision; you can still peek/summon it deliberately. notchide just won't *tap* you
  about something already on screen.
- Every escalation records a one-line **"why did this tap?"** reason, so the policy is always
  legible to the user.

Corollaries (usability guarantees, §9): silence by default, per-session + global mute, and a
conservative default of not interrupting when in doubt about visibility.

---

## 8. Data flow

The end-to-end path for one blocked permission:

1. Claude Code hits a permission gate and runs `notchide-hook`.
2. The sidecar sends an envelope over `hook.sock` and blocks awaiting a decision.
3. `SessionStore` routes it to that session's lane; the lane flips to `needs-you`.
4. `Suppressor` checks frontmost on the active Space. If the terminal is hidden, the pill
   **pulses amber** with a subtle tap (sound opt-in); if visible, notchide stays silent.
5. The user **hovers** (after the ~200 ms intent delay) or hits the **summon hotkey**.
6. The console **morphs down**, showing the pending command, the live git diff, and the output
   tail — **without stealing focus**.
7. The user clicks **Approve** (or Deny / Approve-and-remember / types a redirect).
8. The decision travels **back down the still-open socket**; `notchide-hook` prints the Claude
   Code hook-decision JSON and exits `0`.
9. Claude Code proceeds; the lane goes **green** (`done`/`flowing`); the console **furls up**.

The app you were working in was **never focused** at any point.

---

## 9. Usability guarantees

These are first-class product commitments, tested and defended, not nice-to-haves:

- **Silence by default** — notchide only escalates on **hard blocks**. No chatter.
- **Smart suppression** — never tap you about a session you can already see (§7).
- **Hover-intent delay (~200 ms)** — menu-bar mouse travel never mis-triggers the console.
- **ESC / click-to-pin / auto-collapse** — you control how long the console stays down.
- **Global summon hotkey** — opens the single most-urgent session from anywhere, over
  fullscreen.
- **Focus preservation** — pulling the console down never steals keyboard focus unless you
  click the reply field.
- **Per-session + global mute** — plus a one-line "why did this tap?" on every escalation.
- **Conservative write path** — the full command is always shown, an explicit click is always
  required, ambiguity **defaults to Deny**, and notchide **never auto-approves** (except the
  explicit, per-exact-command Approve-and-remember, §12).
- **Fail-open hook** — an unavailable notchide never bricks an agent (§6.2).
- **First-class floating-pill fallback** — non-notch Macs and external displays are not
  second-class.
- **~0% idle CPU** — fully event-driven, zero polling.

---

## 10. Distribution & the notarization / private-framework plan

notchide ships as a **notarized, direct-download `.dmg`** — deliberately **not** via the Mac
App Store.

**Why not the App Store:** drawing above fullscreen apps and the lock screen, and hiding
notchide from screen capture, requires **private frameworks** (SkyLight / `CGSSpace`). The App
Store sandbox forbids them. The value proposition — a surface above *everything* — is
incompatible with the App Store, so we don't pretend otherwise.

**The plan, de-risked first:** the **first engineering milestone** is a **notarization smoke
test** — prove that a `.dmg` that *links a private framework* actually passes Apple
notarization, before any product code is built on that assumption. Notarization (unlike App
Store review) is an automated malware/hardened-runtime check, not an API-usage audit, so this is
expected to pass — but it is a hard dependency and gets proven at t=0, not discovered at ship.

Private-framework use is paired with **feature-detection and graceful degradation** (§11): if a
symbol or Space API is missing on a given macOS point release, notchide degrades (e.g. to the
floating pill / a normal always-on-top panel) rather than crashing.

---

## 11. Risks & mitigations

| Risk                                                                                 | Mitigation |
| ------------------------------------------------------------------------------------ | ---------- |
| **Annoyance is the product-killer.** An over-eager notch trains users to ignore or uninstall it. | Smart suppression is the core bet (§7): silence by default, never tap about a visible session, mute, and a legible "why did this tap?". If notchide is annoying, it has failed regardless of features. |
| **Synchronous-hook coupling.** Blocking `PreToolUse` on notchide could hang the agent. | **Fail-open** (§6.2): hard timeout, exit `0`, defer to Claude Code's normal prompt. notchide is never load-bearing. |
| **Security-sensitive write path.** Approving a command the user didn't fully read is dangerous. | Conservative write path (§9): full command always shown, explicit click required, **default-to-Deny** on ambiguity, **never auto-approve** except explicit per-exact-command remembering (§12). |
| **Private-framework fragility.** SkyLight / `CGSSpace` are undocumented and can change across macOS releases. | Feature-detect at runtime and **degrade** (floating pill / plain always-on-top) rather than crash; prove notarization at t=0 (§10); harden feature-detection across point releases by v1.0. |
| **Single-vendor coupling.** v0.1 is Claude-Code-only. | Deliberate wedge. v0.2 adds a passive OTLP listener (multi-agent); v1.0 documents a local-socket plugin protocol + community adapters. The core is designed around a generic lane/decision model, not Claude-specific types. |
| **Scope gravity toward an editor.** "Just let me edit the diff" is a constant pull. | The **NOTIFY + DECIDE, never CREATE** rule is a hard product boundary (§3). Read-only is the whole point: it keeps notchide small, safe, and shippable. Editing is reconsidered no earlier than v0.3 and only against a genuinely stable editor component. |
| **Notch-only exclusion.** Many Macs (and all external displays) have no notch. | The **floating-pill fallback is first-class** (§4, §9), shipped in v0.1, not bolted on later. |
| **Empty-demo risk.** An orchestration cockpit is unimpressive with nothing to orchestrate. | Ship with a compelling **demo GIF** and a Show HN that leads with the write action over a fullscreen app — the thing no competitor does. |

---

## 12. Open decisions & locked defaults

Decisions that are **locked** for v0.1 (revisit only with cause):

- **Name — locked: `notchide`.** notch + IDE; also reads as "notch-hide". Lowercase.
- **Tap modality — locked: motion-only by default, sound opt-in.** The default escalation is a
  visual pulse; audible taps are opt-in per the silence-by-default guarantee.
- **Approve-and-remember granularity — locked: per-exact-command-string.** Remembering matches
  the **exact** command string only. No fuzzy/prefix matching in v0.1 — that would broaden the
  auto-approve surface and violate the conservative write path.
- **License — locked: MIT.** Maximally permissive, matches the substrate (DynamicNotchKit) and
  invites the future plugin ecosystem.
- **Distribution — locked: notarized direct-download `.dmg`, not App Store** (§10).
- **v0.1 scope — locked: Claude Code only, read-only console, NOTIFY + DECIDE.**

Deliberately **open** (deferred, not decided):

- Multi-agent ingest via OTLP and the exact glyph vocabulary for cost/usage (v0.2).
- Whether inline reply-inject / terminal peek ship on by default or behind a flag (v0.2, likely
  flagged).
- The plugin protocol's exact schema and versioning story (v1.0).
- If/when inline editing is ever added, and against which editor component (v0.3, contingent on a
  stable 1.0 editor).
