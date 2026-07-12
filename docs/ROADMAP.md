# notchide — Roadmap

Phased and deliberately narrow. v0.1 *ships* one agent — Claude Code — done well, but the core is
already a platform: the vendor-neutral **AAP** substrate landed with the refactor below.
Everything downstream widens the surface only after it lands.

Checked boxes are shipped; unchecked are planned. This document tracks intent, not a commitment
to dates.

---

## Foundation — AAP (landed in the core)

The Agent Adapter Protocol ("LSP/DAP for agents") is refactored into `NotchideKit` and is the
substrate everything else builds on. Normative spec: [PROTOCOL.md](PROTOCOL.md).

- [x] Vendor-neutral core (`AgentEvent`, `Capability`, `AgentDecision`, `SessionKey`)
- [x] AAP `aap/1` wire protocol: handshake + envelope + decision over an owner-only Unix socket
      (`agent.sock`, `0600`), NDJSON framing, UUID correlation, **fail-open**
- [x] Capability model (`observe`/`gate`/`actuate`) enforced at the type level — a notify-only
      provider is *structurally* unable to reach `needs-you`
- [x] `SocketAAPProvider` + `ProviderRegistry`; on-disk provider manifests (Tier-0 descriptors)
- [x] `ClaudeCodeProvider` as the reference provider; `notchide-hook` as the reference adapter
- [x] Machine-readable [`schema/aap-1.schema.json`](../schema/aap-1.schema.json) + runnable
      [`examples/adapters`](../examples/adapters)

## v0.1 — the wedge (Claude Code ships)

The minimum lovable cockpit: watch Claude Code sessions, tap only on hard blocks, decide in
place.

- [ ] Notch shell + first-class floating-pill fallback (non-notch Macs / external displays)
- [ ] Four-state glyph cockpit (`flowing` / `needs-you` / `done` / `error`), color + motion, no text
- [ ] Claude Code hook → socket bridge + `notchide-hook` sidecar, **fail-open** (hard timeout)
- [ ] Smart suppression (escalate only when the session's terminal is not frontmost)
- [ ] Read-only review console: pending command + `Approve` / `Deny` / `Approve-and-remember` /
      one-line redirect + live syntax-highlighted git diff + output tail
- [ ] Jump-to-terminal escape hatch (AppleScript / Accessibility)
- [ ] One-command **reversible** installer (merges into `~/.claude/settings.json`, with consent)
- [ ] Notarized direct-download `.dmg` + demo GIF
- [ ] Notarization smoke test (prove a private-framework `.dmg` notarizes) — **first milestone**
- [ ] Show HN

## v0.2 — the second provider (prove the abstraction)

Add a second **built-in** provider that is *not* Claude Code, to prove AAP's vendor-neutrality in
anger, and grow the cockpit to many concurrent sessions.

- [ ] **OTLP `:4318`** passive listener as the second built-in provider — **notify-only**
      (`observe` only, no `gate`), exercising the capability model end to end (incl. Codex)
- [ ] Multi-session stack view (many providers' lanes at once)
- [ ] Token / cost / tool-timeline surfaced in the cockpit
- [ ] Usage-% glyph
- [ ] Inline reply-inject (behind a flag)
- [ ] Optional SwiftTerm terminal **peek** (read-only)

## v0.3 — builds, CI & git

Tie sessions to the surrounding dev context.

- [ ] Build / CI / git surfacing: Xcode build status, `gh` PR + CI checks
- [ ] NotchFlow-style worktree browser tying sessions to branches
- [ ] Optional on-demand inline editing — **only** if a genuinely stable editor component
      exists (reassess CodeEditSourceEditor 1.0 status)

## v1.0 — freeze the protocol, open the ecosystem

Turn the documented core into a stable, community-extensible platform.

- [ ] **Freeze `aap/1`** — a stability commitment on the wire format ([PROTOCOL.md](PROTOCOL.md))
- [ ] Publish the **adapter SDK** (thin client + conformance tests) so writing an adapter is a
      few lines in any language
- [ ] Community adapters: **Codex, Cursor, Aider, OpenClaw**, custom agents
- [ ] Hardened private-framework **feature-detection** across macOS point releases

---

## Guardrails (every milestone respects these)

- **NOTIFY + DECIDE, never CREATE** — inline editing is a v0.3-at-earliest maybe, never a
  v0.1/v0.2 surprise.
- **Fail-open forever** — no roadmap item may make notchide load-bearing in front of an agent.
- **Silence by default** — new event sources must go through smart suppression, not around it.
