# notchide — Design

> The product + system design of record. If the code and this document disagree, one of them
> is a bug. Keep them in sync.

**Status:** v0.1 design, locked defaults noted inline.
**Author:** Zac Song ([@Blonky](https://github.com/Blonky)), 2026.

---

## 1. Problem & thesis

Developers now run several AI coding agents at once — a Claude Code session per worktree, a
Codex run here, a Cursor agent there, one per feature, per Space. The agents are mostly
autonomous, but they are not fully autonomous: they stop at permission gates ("may I run `rm`?",
"may I edit this file?"). Each gate is a small, blocking, human-in-the-loop decision.

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

It does three verbs — **NOTIFY**, **DECIDE**, and — hands-free — **STEER** by voice — and
deliberately never the one that would make it an IDE, **CREATE**. STEER routes a *spoken
instruction* to a running session (§12); it never types code for you. The principle is
**NOTIFY + DECIDE + STEER, never CREATE.**

### 1.1 An open platform, not a single-agent tool

notchide is **the open notch platform for coding agents**. Two commitments follow from that:

- **Agent-agnostic by construction.** The cockpit consumes one vendor-neutral currency — an
  `AgentEvent` tagged with a `providerID` — over a small, documented wire protocol: **AAP, the
  Agent Adapter Protocol** ([PROTOCOL.md](PROTOCOL.md)). Claude Code is the *reference adapter*
  that ships in v0.1, not a special case baked into the core. Connect Codex, Cursor, Aider, or
  your own agent by speaking AAP; nothing in the lane/glyph/decision model is Claude-specific.
- **Standalone _and_ build-on.** notchide works out of the box as a finished product for Claude
  Code today, and it is a substrate others extend: drop a provider manifest, or write an adapter
  in any language. See [ARCHITECTURE.md](ARCHITECTURE.md) for the two planes (AAP wire protocol +
  provider/contribution surface) and the provider tiers.
- **Local-first.** The whole platform is a same-machine, owner-only Unix socket (`0600`); notchide
  binds nothing routable. A contributed decision can approve `rm -rf`, so the channel that
  carries it is, by construction, unreachable off the machine (see §6.2, [PROTOCOL.md §3.1](PROTOCOL.md#31-local-first-security-requirements-normative)).

The visual language for all of this — the four-state glyphs, the console, the diff and tail — is
captured in the display-system reference at
[`docs/media/gallery.html`](media/gallery.html).

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
  and **non-focus-stealing** — and both properties come from **public AppKit** (a
  non-activating `NSPanel` at the screen-saver window level with a full-screen-auxiliary
  collection behavior), **not** from a private framework. The recipe is in §10.1 and
  [ARCHITECTURE §3.6](ARCHITECTURE.md#36-gui-types-in-app).
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
- **A Mac App Store app.** notchide must be **non-sandboxed** — for the push-to-talk
  `CGEventTap`, the shared `agent.sock` path the hook process must reach, and private SkyLight
  suppression — which the App Store forbids (see §10.2). It ships as a notarized direct-download
  `.dmg`. (The overlay itself is public API, §10.1 — it is not what bars the App Store.)
- **A Quake-style terminal / a terminal emulator.** notchide is not where you type at your
  agent. It provides a **jump-to-terminal** escape hatch and (v0.2, behind a flag) an optional
  read-only terminal *peek*, but the terminal remains the terminal.
- **A general notification center.** notchide surfaces exactly one class of event — an agent
  blocked on a permission it can't resolve alone. It is not a home for arbitrary alerts.
- **A polling monitor.** notchide is event-driven end to end; if it ever polls, that's a bug.
- **A surface above the lock screen.** notchide deliberately renders **nothing** over
  `loginwindow`. It is infeasible for a notarized app (the lock screen is a separate secure
  session) and, more to the point, a **security anti-goal**: approving an agent's `rm -rf` on an
  unattended, *locked* Mac is exactly what must never be possible. When the screen locks,
  notchide surfaces nothing and decides nothing (§10.2).
- **Hidden from screen capture.** notchide makes **no** promise to hide its surface from screen
  recording — `NSWindow.sharingType = .none` is ignored by ScreenCaptureKit on macOS 15+, so
  the guarantee would be false. It instead never renders a secret in the notch and relies on the
  OS's mandatory recording indicator (§10.4).

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

### 4.3 Capability-aware console — GATE vs OBSERVE-only

Because notchide is a platform, not every connected agent can be gated. The console adapts to
each provider's advertised **capabilities** (see [PROTOCOL.md §2](PROTOCOL.md#2-capability-model)):

- A **`gate`** provider (like Claude Code) is *blocking*: its sessions can reach `needs-you`, the
  console shows **Approve / Deny / Approve-and-remember / redirect**, and a decision is written
  back over the socket.
- An **observe-only** provider is *notify-only* and **degraded** in the console: it appears as a
  lane and glyphs `flowing`/`done`/`error`, but it can **never** reach `needs-you` and shows **no
  decision buttons**. This is a type-level guarantee, not a UI preference — a notify-only provider
  is structurally unable to seize the user (`SessionStore` clamps its state; `Suppressor` never
  taps for it; `Lane.showsDecisionButtons` requires a blocking provider). The v0.2 OTLP listener
  (§13) is exactly such a provider: it proves the abstraction by observing without ever gating.

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

- **Responsibility:** get **any** agent's events into the app reliably and cheaply over AAP, and
  carry a decision back to a blocked gate.
- **Key types:** `SocketAAPProvider` (the app-side ingress, wrapping `UnixSocketServer`);
  `ProviderRegistry`, which fans every provider's events into the one `SessionStore` (`actor`,
  one lane per `SessionKey`); `ClaudeCodeProvider`, the **reference provider** that translates
  Claude hook events into vendor-neutral `AgentEvent`s. The `notchide-hook` CLI is the reference
  *adapter* on the wire.
- **Transport:** a Unix-domain socket at `~/Library/Application Support/notchide/agent.sock`,
  mode `0600`, NDJSON framing — the normative [AAP protocol](PROTOCOL.md).
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
- **v0.1 highlighting is Swift-only.** Until the Neon milestone lands, the diff uses a small,
  dependency-free Swift keyword highlighter. Its rules are Swift-specific, so a **non-Swift file
  falls back to plain monospace** rather than being mis-highlighted; multi-language tree-sitter
  highlighting arrives with the stack above.

---

## 6. The hook contract

The contract between Claude Code and notchide is a single sidecar invocation per hook event.

### 6.1 `PreToolUse` — the synchronous block

When Claude Code hits a permission gate, its `PreToolUse` hook runs `notchide-hook`. That
process:

1. Reads the hook payload (`session_id`, `tool_name`, `tool_input`, `cwd`, …) from stdin.
2. Connects to `agent.sock` and sends an **envelope** carrying that payload plus a fresh request
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
  identical calls auto-resolve (see §15).

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

> **v0.1 scope — coarse suppression.** The shipped check is deliberately coarse: it treats a
> session as "visible" when **any known terminal emulator is the frontmost application**, not
> per-window or per-Space. It does not yet match the *specific* session's window (by title /
> cwd) or confirm it is on the active Space — that needs the Accessibility API and private
> SkyLight (`CGSGetActiveSpace` / `CGSCopyManagedDisplaySpaces`) and is a later milestone
> (§10.2). Consequently, if you have any terminal
> frontmost, notchide stays silent even about a *different* hidden session; the precise
> per-window/per-Space policy above is the v1.0 target.

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
2. The sidecar sends an envelope over `agent.sock` and blocks awaiting a decision.
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
  explicit, per-exact-command Approve-and-remember, §15).
- **Fail-open hook** — an unavailable notchide never bricks an agent (§6.2).
- **First-class floating-pill fallback** — non-notch Macs and external displays are not
  second-class.
- **~0% idle CPU** — fully event-driven, zero polling.

---

## 10. Distribution, packaging & the security model

notchide ships as a **notarized, direct-download `.dmg`** — deliberately **not** via the Mac
App Store.

### 10.1 The overlay is public API

Rendering the notch panel — the pill and the console — **above another app's native
full-screen space**, across every Space, without stealing focus, is **public AppKit**, not a
private framework. The recipe is a single non-activating `NSPanel`:

- `styleMask` = `[.borderless, .nonactivatingPanel]`;
- `collectionBehavior` = `[.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]` — the
  `.fullScreenAuxiliary` flag is precisely what lets the panel sit over another app's
  full-screen;
- `level` = `.screenSaver` (above ordinary and full-screen windows);
- shown with `orderFrontRegardless()`, and `becomesKeyOnlyIfNeeded = true` so a peek never
  activates notchide.

The ambient pill is **click-through and never key** (`ignoresMouseEvents = true`; it never
becomes key); only the expanded console takes clicks, and even then focus is preserved (§9).
The one place notchide must **correct** its `NSPanel` substrate — DynamicNotchKit omits
`.fullScreenAuxiliary` (notchide adds it) and hardcodes `canBecomeKey = true` (notchide gates it
per state so the pill is click-through and never key, toggling `ignoresMouseEvents`) — is
detailed in [ARCHITECTURE §3.6](ARCHITECTURE.md#36-gui-types-in-app).

### 10.2 Why not the App Store — non-sandbox, not private frameworks

The blocker is the **sandbox**, which is App-Store-only. notchide ships **non-sandboxed**
because it needs, all of which the sandbox forbids:

- a **`CGEventTap`** for press-and-hold push-to-talk (§12.7);
- the real `~/Library/Application Support/notchide/agent.sock` path, which a **separate** hook
  process (a child of Claude Code, **not** of notchide — see
  [SUPERVISION.md §1](SUPERVISION.md#1-the-ownership-tree)) must be able to reach;
- private **SkyLight** (`CGSGetActiveSpace` / `CGSCopyManagedDisplaySpaces`) — used **only** to
  sharpen *per-Space suppression* (§7), never to draw. It is feature-detected and degrades to
  the coarse `NSWorkspace.frontmostApplication` check when a symbol is unavailable.

So the incompatibility is the sandbox, not the overlay: the surface-above-everything is public
API (§10.1); the sandbox-forbidden pieces are the event tap, the shared socket path the hook
must reach, and the optional SkyLight suppression refinement. The lock screen is out of scope by
construction (§3): `loginwindow` is a separate secure session a notarized app cannot draw over,
and doing so would be a security anti-goal.

### 10.3 Packaging & code-signing (Hardened Runtime, Developer ID, notarize + staple)

notchide is distributed **non-sandboxed + Hardened Runtime + Developer ID + notarized +
stapled**. Concretely:

- The app is signed with a **Developer ID Application** certificate and the **Hardened
  Runtime** enabled, then **notarized and stapled** so it launches without a Gatekeeper prompt.
- The **embedded Node sidecar** (the `sh.claude.host` host, §12.3) is a *distinct* executable
  that needs its **own** Developer ID signature plus the entitlements
  `com.apple.security.cs.allow-jit` and
  `com.apple.security.cs.allow-unsigned-executable-memory` — without them, V8's JIT crashes
  under the Hardened Runtime.
- **TCC grants are keyed to code identity.** Rotating or re-signing with a *different*
  certificate **resets every grant** (Accessibility, Input Monitoring, Screen Recording,
  Microphone), so **certificate continuity** is a release requirement, planned from t=0 — not
  discovered on a rotation.
- **Screen Recording** (needed only for the capture-backed paths) requires an app **relaunch
  after the grant** — the process must restart before the new grant takes effect.

**The plan, de-risked first:** the **first engineering milestone** is a **notarization smoke
test** — prove that a non-sandboxed, Hardened-Runtime `.dmg` (with the JIT-entitled Node sidecar
and a weak-linked SkyLight symbol) actually passes Apple notarization, before any product code
is built on that assumption. Notarization (unlike App Store review) is an automated
malware/hardened-runtime check, not an API-usage audit, so this is expected to pass — but it is
a hard dependency and gets proven at t=0, not discovered at ship.

Private-symbol use (SkyLight) is paired with **feature-detection and graceful degradation**
(§11): if a Space symbol is missing on a given macOS point release, notchide degrades to the
coarse frontmost-app suppression check (§7) rather than crashing. **The overlay itself never
degrades** — it is public API on every supported release.

### 10.4 Screen capture — no hiding guarantee

notchide does **not** promise to hide its surface from screen recording. `NSWindow.sharingType
= .none` is **ignored by ScreenCaptureKit on macOS 15+**, so a "the notch is invisible to
capture" guarantee would be false. Instead:

- notchide **never renders a secret** in the notch surface — no tokens, no key material, no full
  credential strings; the write path shows commands and diffs, not secrets; and
- it relies on the OS's **mandatory recording indicator** (the menu-bar capture dot) to tell the
  user when a capture is live.

Hiding-from-capture is therefore an explicit **non-goal** (§3), not a broken promise.

---

## 11. Risks & mitigations

| Risk                                                                                 | Mitigation |
| ------------------------------------------------------------------------------------ | ---------- |
| **Annoyance is the product-killer.** An over-eager notch trains users to ignore or uninstall it. | Smart suppression is the core bet (§7): silence by default, never tap about a visible session, mute, and a legible "why did this tap?". If notchide is annoying, it has failed regardless of features. |
| **Synchronous-hook coupling.** Blocking `PreToolUse` on notchide could hang the agent. | **Fail-open** (§6.2): hard timeout, exit `0`, defer to Claude Code's normal prompt. notchide is never load-bearing. |
| **Security-sensitive write path.** Approving a command the user didn't fully read is dangerous. | Conservative write path (§9): full command always shown, explicit click required, **default-to-Deny** on ambiguity, **never auto-approve** except explicit per-exact-command remembering (§15). |
| **Private-symbol fragility.** SkyLight (`CGSGetActiveSpace` / `CGSCopyManagedDisplaySpaces`) is undocumented and can change across macOS releases. | It is used **only** to sharpen per-Space suppression (§7, §10.2), **never to draw** — the overlay is public API (§10.1). Feature-detect at runtime and **degrade to the coarse frontmost-app check** rather than crash; prove notarization at t=0 (§10.3); harden feature-detection across point releases by v1.0. |
| **Single-vendor coupling.** v0.1 *ships* Claude-Code-only. | The core is already agent-agnostic: it is built around **AAP** ([PROTOCOL.md](PROTOCOL.md)) and a generic `AgentEvent`/`AgentProvider` model, with Claude Code as the reference adapter. v0.2 adds a passive OTLP listener (a second built-in provider, notify-only) proving the abstraction; v1.0 freezes `aap/1` and publishes the adapter SDK + community adapters. |
| **Scope gravity toward an editor.** "Just let me edit the diff" is a constant pull. | The **NOTIFY + DECIDE, never CREATE** rule is a hard product boundary (§3). Read-only is the whole point: it keeps notchide small, safe, and shippable. Editing is reconsidered no earlier than v0.3 and only against a genuinely stable editor component. |
| **Notch-only exclusion.** Many Macs (and all external displays) have no notch. | The **floating-pill fallback is first-class** (§4, §9), shipped in v0.1, not bolted on later. |
| **Empty-demo risk.** An orchestration cockpit is unimpressive with nothing to orchestrate. | Ship with a compelling **demo GIF** and a Show HN that leads with the write action over a fullscreen app — the thing no competitor does. |

---

## 12. Voice-drive: steer by voice

The read-only console (§4.2) closes the **decision** loop. Voice-drive closes the
**direction** loop: it lets you **steer a running agent by talking to it**, hands-free —
without cmd-tabbing to its terminal or typing a word. This is the platform's third verb,
**STEER**, and it is deliberately narrow. The full interaction mockup is
[`docs/media/voice.html`](media/voice.html).

### 12.1 The principle — route an intent, never keystrokes

STEER-by-voice **routes an intent to a session**. When you speak, notchide commits the
final transcript to a single `VoiceIntent` and hands it to the agent as an
`AgentAction.prompt(SessionKey, String)` — a *fresh natural-language instruction* to that
session. It is emphatically:

- **not keystrokes** — notchide never synthesizes keypresses into the focused editor or
  terminal. The intent travels the AAP wire as an actuate `prompt`
  ([PROTOCOL.md §7](PROTOCOL.md#7-the-actuate-frame)), not through the keyboard.
- **not authoring** — a spoken instruction is a *prompt to the agent*, which then does the
  work under its own permissions. notchide still never **CREATE**s code itself; STEER is
  NOTIFY + DECIDE's peer, not a smuggled-in editor.

The pure state machine that produces the intent — `VoiceController` — contains no audio and
no AppKit: it consumes `Transcript`s and emits a `VoiceIntent`; *delivering* that intent is
the app's job. That keeps the whole voice pipeline headless-testable on an injectable clock
(the silence cap, the total cap, and the review-grace window all advance deterministically —
no microphone, no wall clock).

### 12.2 The route-by-session inversion

Typing is *focus-bound*: characters go to whatever window holds the keyboard. That is exactly
the model notchide exists to escape — a window steals focus (§2). Voice-drive **inverts** it:
an utterance is bound to a **target session**, not to the frontmost app. You summon the session
you mean — the most-urgent one, or one you pick — and your words are routed to *that* agent's
`SessionKey`, wherever its terminal is (another Space, hidden, fullscreen behind you). The app
you are looking at is never focused and never receives a keystroke. **Route-by-session, not
route-by-focus**, is what makes hands-free steering compatible with the "never steal focus"
thesis.

### 12.3 HOST vs ATTACH

A session can be steered two ways, and the console shows which:

- **HOST (first-class).** A **host adapter owns a live, streaming agent session** and
  advertises `actuate` on its AAP handshake. The prompt is **pushed** to it as an
  `ActuateFrame` over the kept-alive duplex connection
  ([PROTOCOL.md §7](PROTOCOL.md#7-the-actuate-frame)), and that same connection streams the
  session's progress and gates back. The reference host is the **Node Agent-SDK sidecar**
  (`sh.claude.host`), which keeps a Claude session open and injects the prompt directly. This
  is the clean path: structured, bidirectional, observable.
- **ATTACH (degraded).** Where no host owns the session — a plain agent already running in a
  terminal — notchide can **attach** to it (via `cmux`/`tmux`) and inject the instruction into
  the running session. This is best-effort: there is no structured event stream back, so the
  loop degrades to whatever the terminal exposes. ATTACH is the fallback for sessions that
  predate or lack a host adapter.

If neither a live host connection nor an attachable session exists for the target, the prompt
is a **safe no-op** — the same fail-safe the wire guarantees
([PROTOCOL.md §7.2](PROTOCOL.md#72-routing--the-missing-target-no-op-normative)): steering a
session that isn't live simply does nothing.

### 12.4 The loop — summon → speak → prompt → observe → decide

1. **Summon.** A global hotkey (the same summon affordance as §4.2) brings up the target
   session — the most-urgent one, or one you select — without leaving your app.
2. **Speak.** Hold push-to-talk and talk. The live (volatile) transcript surfaces in the HUD
   for feedback; only a **final** transcript is ever committed. Release drops into a short,
   **editable** review-grace window before the intent auto-sends — or send at once, or cancel.
3. **Prompt.** The committed `VoiceIntent` is routed to the session as an `AgentAction.prompt`
   — a HOST push or an ATTACH inject (§12.3).
4. **Observe.** The agent runs. Its progress streams back into the same lane/glyph model as
   every other session (§4.1) — you *watch* it work, ambiently.
5. **Decide.** If the agent hits a permission gate, it escalates to `needs-you` and you
   **decide in the console** exactly as always (§4.2). Voice got the work started; the gate is
   still a deliberate human decision (§12.6).

### 12.5 On-device voice — local-first, no cloud

Speech recognition is **on-device**, matching the platform's local-first stance (§1.1): no
utterance leaves the machine.

- **Primary — SpeechAnalyzer.** The modern on-device recognizer, used where the OS provides
  it. It produces the volatile/final `Transcript` stream the `VoiceController` consumes.
- **Fallback — WhisperKit.** A bundled on-device model for machines/OS versions where
  SpeechAnalyzer is unavailable, so voice-drive still works fully offline.

The core ships only the `VoiceProvider` protocol (plus a scripted `StubVoiceProvider` for
tests); the mic-bound SpeechAnalyzer/WhisperKit implementations live in the app target, so the
pipeline stays dependency-free and testable.

### 12.6 Destructive gates are never voice-approved (the safety rule)

The single hard rule: **voice can start work, but voice can never approve a destructive
action.** Voice reaches a session only through `actuate` (`prompt` / `interrupt`) and **never**
through `gate` — they are orthogonal write paths
([PROTOCOL.md §7.3](PROTOCOL.md#73-voice-reaches-actuate-never-gate)). So a spoken instruction
that leads the agent toward, say, `rm -rf` still stops at that command's normal permission
gate, which escalates to `needs-you` and requires the deliberate, conservative **click** of
§4.2 — full command shown, default-to-Deny on ambiguity, never auto-approved. There is no
"yes"-word that one-shot-approves a dangerous command. STEER therefore lives inside the same
conservative write path as DECIDE (§9): easy to *start* an agent by voice, impossible to
*approve danger* by voice.

### 12.7 Hotkeys & the permissions they need

Two affordances, two very different permission costs — and notchide keeps them apart on purpose:

- **Summon is permission-free.** The global summon hotkey (§4.2, §12.4) is registered with
  **Carbon `RegisterEventHotKey`**, which needs **no** TCC grant. Summoning a session — with or
  without voice — never prompts for anything.
- **Push-to-talk defaults to `Control+Option`.** The press-and-**hold** PTT chord is
  **`Control+Option`**, deliberately **not** double-tap-Fn — double-tap-Fn *is* the macOS
  Dictation trigger and would collide with the OS. Observing a *held* modifier chord, and (when
  needed) **swallowing** it so it doesn't leak to the focused app, requires a **`CGEventTap`**: a
  passive `.listenOnly` tap can watch but **cannot suppress** the event; swallowing needs
  **Accessibility** plus a `.defaultTap`. **Input Monitoring** is required to read the key stream
  at all.

**Granted at onboarding, not just-in-time.** Accessibility and Input Monitoring are requested
**once, at voice-enable onboarding** — never lazily on the first PTT press, because a held-key
gesture cannot wait on a permission dialog. Neither permission exposes an `NSUsageDescription`
Info.plist key, so notchide shows its **own custom pre-prompt** explaining why, then deep-links
straight to the correct System Settings pane with an `x-apple.systempreferences` URL. If the
user declines, **summon-only** operation still works (summon needs no grant); PTT stays disabled
until the grants are given.

---

## 13. The OTLP enrichment plane (observe-only)

A second, **zero-config** way in — beside the AAP socket — arrives in v0.2: an **OpenTelemetry
(OTLP) receiver on `:4318`**. Coding agents already emit OTLP when
`OTEL_EXPORTER_OTLP_ENDPOINT` points at it, so this lane costs the user nothing to wire up. It is
strictly an **observe-only enrichment** plane, and understanding *why it can only enrich* is the
point.

### 13.1 Enrich a lane, never own it

OTLP does not open lanes and does not reliably close them. Claude Code emits **no**
session-start/session-end over OTLP, so an OTLP stream cannot be trusted to bound a session's
lifecycle. Instead, OTLP records are **merged onto the lane the hook/sidecar already owns**, by
**shared session id**: Claude's OTLP `session.id` equals the `PreToolUse` hook's `session_id`;
Codex's `conversation.id` plays the same role. The merged data is pure enrichment — **tokens,
cost, model** — layered onto a lane whose *lifecycle and gates* come from the blocking
hook/sidecar. Hard rule: **an OTLP "done" must never close a lane the hook still shows
blocking.** Lifecycle belongs to `gate`/`observe` adapters on the AAP socket; OTLP only colors
them in.

### 13.2 Not a gate, and it cannot carry one

OTLP is a one-way, agent-as-client push. Two consequences:

- Its `*.tool_decision` records are **post-hoc** — they report a decision *already made*, they
  are **not** a gate notchide can block on.
- The PROOF path — a real `gate`/`actuate` — **cannot ride OTLP** at all: gating is
  request/response with the *agent* as client, and there is **no server→client frame** in OTLP to
  carry a verdict back or push a prompt. Gates stay on the duplex AAP socket
  ([PROTOCOL.md §6–§7](PROTOCOL.md#6-the-decision-frame)); OTLP stays observe-only.

This makes the OTLP listener the textbook **notify-only provider** of §4.3 — it proves the
capability model by observing without ever gating. Transport, security, and the "binds nothing
routable" exception it forces are normative in
[PROTOCOL.md §3.3](PROTOCOL.md#33-the-otlp-enrichment-transport-loopback-exception). Prior art:
the shipped competitor **agentnotch** ([github.com/AppGram/agentnotch](https://github.com/AppGram/agentnotch))
also listens on `:4318` — observe-only, exactly this lane.

---

## 14. The Build stage

Beyond NOTIFY / DECIDE / STEER, the console can show **what the agent built** — a **Build
stage** that renders the current turn's tangible output inline, still read-only. Because a
build artifact only exists where notchide can *see* the agent's output stream, the Build stage
is **HOST-mode only** (§12.3): the `{observe, gate}` `PreToolUse` hook has no output stream to
classify, so it never produces one; only a streaming HOST adapter does.

### 14.1 The artifact ladder

A HOST adapter classifies the turn's output into a **`BuildArtifact`** — a type that **already
exists in `NotchideKit`** — with a fallback ladder from richest to plainest:

```
livePreview(url) → diff → tests → logs → document → screens → error
```

The provider picks the richest form it can prove, and the console degrades down the ladder when
it can't. The artifact travels the wire as an **additive** `AgentEvent.artifact` field
([PROTOCOL.md §5.1](PROTOCOL.md#51-the-agentevent-object),
[§8](PROTOCOL.md#8-versioning-negotiation--forward-compatibility)) — invisible to any adapter
that never sets it.

### 14.2 `livePreview` renders untrusted content — egress-locked by construction

A `livePreview(url)` points a **`WKWebView`** at a dev server the agent just started, i.e. at
**untrusted, agent-authored content**. It is therefore **egress-locked by construction**, not by
policy:

- a **`WKContentRuleList`** blocks **all** network except `http://127.0.0.1:PORT`;
- navigation is **pinned to that single loopback origin** via `decidePolicyFor` (any other
  navigation is refused);
- **no page-reachable `WKScriptMessageHandler`** is installed — the page cannot call back into
  the app;
- a **`.nonPersistent()`** data store (nothing survives the preview) with
  **`NSAllowsLocalNetworking = YES`** for the loopback origin only.

**Dev-server URL discovery** is never a blind port scan. It is, in order: **scrape the child's
stdout `Local:` line** (primary); **`libproc` listening-socket enumeration of the agent
process *subtree*** (fallback); and a **`GET /` readiness probe** before the `WKWebView` loads.

### 14.3 Diffs at a gate are synthetic; real git diff is post-turn

At a **`PreToolUse` gate** the change **has not happened yet** — so the console shows the pending
`tool_input` as a **synthetic diff** (what the tool *would* do). A **real `git diff`** is
reserved for the **post-turn** `Stop`/review console, where the change is on disk and can be
diffed for real. The two are never conflated: gate-time shows intent, post-turn shows fact.

---

## 15. Open decisions & locked defaults

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
