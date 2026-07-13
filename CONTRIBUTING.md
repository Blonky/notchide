# Contributing to notchide

Thanks for helping build notchide. It is a small, opinionated project — the constraints below
are what keep it small. Please read them before opening a PR.

---

## The one design principle: NOTIFY + DECIDE, never CREATE

notchide does exactly two verbs — it **notifies** you that an agent is blocked, and it lets you
**decide** (approve / deny / redirect). It deliberately never does the third verb, **create**:
there is **no code editor** in notchide. The review console is **read-only**.

Every contribution must respect this boundary. A change that starts letting the user *edit* the
diff, type freeform into the agent's buffer, or otherwise author code from the notch will be
declined on principle in v0.1 — not because it's badly built, but because read-only is the
product. (Inline editing is a v0.3-at-earliest question, gated on a genuinely stable editor
component — see [docs/ROADMAP.md](docs/ROADMAP.md).) If you're unsure whether an idea crosses the
line, open an issue first.

Two more invariants that are not up for negotiation in a PR:

- **Fail-open.** The `PreToolUse` hook must never be able to hang an agent. Any change on the
  hook path keeps the hard-timeout → exit-`0` → defer behavior and its test.
- **Silence by default.** New event sources escalate **through** the `Suppressor`, never around
  it. notchide never taps the user about a session they can already see.

---

## Build & test

The repository is two SwiftPM packages (see [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)).

### The offline core (`NotchideKit` + `notchide-hook`)

Zero external dependencies — builds and tests with just the Swift 6 toolchain, no network:

```sh
swift build      # NotchideKit + notchide-hook
swift test       # the full offline suite, including the fail-open path
```

This is exactly what CI runs (`.github/workflows/ci.yml` on `macos-latest`). **A PR must keep
`swift build` and `swift test` green for the root package.** Because the core has no external
deps, "works on my machine" and "works in CI" should not diverge.

### The GUI app (`app/`)

Built on your Mac with Xcode — it needs the full toolchain and pulls DynamicNotchKit over the
network, so it is not part of the offline CI job:

```sh
cd app
xcodegen generate          # project.yml → notchide.xcodeproj
open notchide.xcodeproj      # build & run the `notchide` scheme
```

The `app/` package depends on **DynamicNotchKit** (fetched over the network) and on
`NotchideKit` by local path.

### Running the hook path end-to-end

1. Build and run the GUI app (it creates the socket).
2. `notchide-hook install` (merges into `~/.claude/settings.json`, with a confirm — see
   [docs/HOOKS.md](docs/HOOKS.md)).
3. Trigger a permission gate from a Claude Code session on a background Space; peek and decide.
4. `notchide-hook uninstall` to clean up.

---

## Module boundaries

Respect the split — it's what keeps the core testable and offline:

- **`NotchideKit` (core) has ZERO external dependencies.** IPC framing, `SessionStore`,
  `Suppressor`, the lane/glyph model, and the hook decision types go here. Do **not** import
  DynamicNotchKit, AppKit-heavy UI, or the diff-highlighting libraries into the core.
- **`notchide-hook`** is a thin CLI over `NotchideKit`. Keep logic in the library; keep the
  executable a small shell.
- **`app/`** is the only place DynamicNotchKit, SwiftUI/AppKit UI, the weak-linked SkyLight
  suppression symbols, and the planned diff-highlighting stack (Neon / SwiftTreeSitter /
  CodeEditLanguages) may appear.
- **Desktop-coupled logic hides behind a protocol.** "What is frontmost on the active Space" is
  `FrontmostContextProviding`, so the `Suppressor` policy stays a pure, offline-testable
  predicate. New OS-coupled behavior should follow the same pattern.

---

## Code style

- **Swift 6, strict concurrency.** The core targets the Swift 6 language mode with complete
  concurrency checking. New types that cross an isolation boundary are `Sendable`; shared mutable
  state lives inside an `actor` (as `SessionStore` does), not behind locks.
- **Small, focused files.** One primary type per file; prefer many small files over a few large
  ones. If a file is doing two jobs, split it.
- **No polling.** Everything is event-driven (socket readability, actor messages, SwiftUI
  observation). A `Timer` that wakes up "just to check" is a red flag.
- **Test the hard parts.** The IPC framing, UUID correlation, the suppression predicate, and
  **the fail-open timeout** all have unit tests. Add tests alongside behavior changes to those.
- **Match the surrounding code.** Follow the conventions already in the file you're editing;
  keep formatting consistent with the existing sources (`swift format` / the project's settings
  where configured).

---

## Pull requests

- Keep PRs focused — one concern per PR.
- Describe **what** changed and **why**, and note explicitly if you touched the hook path, the
  suppression policy, or the module boundaries above.
- Make sure `swift build` and `swift test` pass for the root package before requesting review.
- By contributing, you agree your contributions are licensed under the project's
  [MIT License](LICENSE).

Questions or a design-boundary check? Open an issue before writing the code — it's cheaper than a
declined PR.
