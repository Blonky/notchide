# notchide — Roadmap

Phased and deliberately narrow. v0.1 is a **wedge**, not a platform: one agent, two verbs, done
well. Everything downstream widens the wedge only after it lands.

Checked boxes are shipped; unchecked are planned. This document tracks intent, not a commitment
to dates.

---

## v0.1 — the wedge (Claude Code only)

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

## v0.2 — multi-agent & richer telemetry

Broaden ingest beyond Claude Code and add cost/usage awareness to the cockpit.

- [ ] OpenTelemetry **OTLP `:4318`** passive listener → multi-agent ingest (incl. Codex)
- [ ] Token / cost / tool-timeline surfaced in the cockpit
- [ ] Usage-% glyph
- [ ] Inline reply-inject (behind a flag)
- [ ] Optional SwiftTerm terminal **peek** (read-only)
- [ ] Multi-session stack view

## v0.3 — builds, CI & git

Tie sessions to the surrounding dev context.

- [ ] Build / CI / git surfacing: Xcode build status, `gh` PR + CI checks
- [ ] NotchFlow-style worktree browser tying sessions to branches
- [ ] Optional on-demand inline editing — **only** if a genuinely stable editor component
      exists (reassess CodeEditSourceEditor 1.0 status)

## v1.0 — an open cockpit

Turn the single-vendor wedge into a documented, extensible platform.

- [ ] Documented **local-socket plugin protocol**
- [ ] Community adapters: Cursor, Aider, custom agents
- [ ] Hardened private-framework **feature-detection** across macOS point releases

---

## Guardrails (every milestone respects these)

- **NOTIFY + DECIDE, never CREATE** — inline editing is a v0.3-at-earliest maybe, never a
  v0.1/v0.2 surprise.
- **Fail-open forever** — no roadmap item may make notchide load-bearing in front of an agent.
- **Silence by default** — new event sources must go through smart suppression, not around it.
