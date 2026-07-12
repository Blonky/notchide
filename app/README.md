# notchide.app — the GUI

The SwiftUI/AppKit notch app: an ambient orchestration **cockpit** (one glyph per
running Claude Code session) that morphs down into a read-only **review console**
where you approve / deny / redirect a blocked agent — over your fullscreen work,
without stealing focus.

This package owns only the GUI. The dependency-free core (IPC, `SessionStore`,
`Suppressor`, the hook decision types) lives in the root package as
[`NotchideKit`](../Sources/NotchideKit), which this app links by local path.

## Layout

```
app/
├─ Package.swift                 # depends on DynamicNotchKit (1.1.0) + local NotchideKit
├─ project.yml                   # XcodeGen spec → notchide.xcodeproj (the notarizable .app)
├─ Info.plist                    # LSUIElement, bundle id, version, usage strings
├─ Makefile                      # build / run / generate / app conveniences
└─ Sources/
   ├─ NotchideApp/               # LIBRARY — every view, controller, design token, wiring
   │  ├─ AppBootstrap.swift          # NSApplicationDelegate: wires socket ↔ broker ↔ UI
   │  ├─ NotchController.swift        # owns the DynamicNotch panel + all interaction timers
   │  ├─ DecisionBroker.swift         # actor: the async decision round-trip (continuations)
   │  ├─ NotchViewModel.swift         # @MainActor source of truth the views observe
   │  ├─ GitDiffProvider.swift        # `git diff` via Process + unified-diff parser/model
   │  ├─ SwiftSyntaxHighlighter.swift # built-in Swift keyword highlighter (no deps)
   │  ├─ DestructiveScanner.swift     # flags `rm -rf` & friends on the write path
   │  ├─ AppKitSupport.swift          # FrontmostContextProviding + jump-to-terminal
   │  ├─ HotkeyMonitor.swift          # global summon hotkey (⌘⌥N) + ESC via NSEvent
   │  ├─ DesignSystem/                # colors, typography, NSVisualEffectView wrapper
   │  └─ Views/                       # CockpitView · ReviewConsoleView · DiffView
   └─ notchide/                   # EXECUTABLE — thin entry point that boots the library
      └─ main.swift
```

## Build (dev)

> **Requires full Xcode**, not just the Command Line Tools. DynamicNotchKit uses
> the SwiftUI `@Entry` and `#Preview` macros, whose macro plugins
> (`SwiftUIMacros`, `PreviewsMacros`) ship **only inside Xcode.app**. On a
> CLT-only machine `swift build` fails *inside the dependency* — notchide's own
> code compiles cleanly (the offline core in `../` still builds with CLT alone).

```sh
cd app
swift build                    # library + executable
swift run notchide             # run the agent app (no Dock icon; it's LSUIElement)
```

The app is an accessory app: on launch it calls
`NSApp.setActivationPolicy(.accessory)`, starts the Unix-domain socket server at
`~/Library/Application Support/notchide/hook.sock`, and shows the cockpit as
sessions appear. On non-notch Macs / external displays it uses DynamicNotchKit's
first-class **floating** pill automatically (`.auto` style).

## Build the real, notarizable .app (release)

```sh
brew install xcodegen
cd app
xcodegen generate                                    # → notchide.xcodeproj
xcodebuild -project notchide.xcodeproj \
           -scheme notchide -configuration Release build
# then codesign + notarize + staple into a direct-download .dmg
```

Notarization and the private-framework (SkyLight / `CGSSpace`) work needed to
draw above *every* fullscreen Space are a later milestone — see
[docs/DESIGN.md §10](../docs/DESIGN.md) and [docs/ARCHITECTURE.md](../docs/ARCHITECTURE.md).

## Hooks — the app installs nothing on its own

notchide surfaces Claude Code hook events; you wire those up separately with the
sidecar CLI from the root package:

```sh
notchide-hook install       # merges into ~/.claude/settings.json (diff + confirm)
```

See [docs/HOOKS.md](../docs/HOOKS.md) for the exact `settings.json` snippet and
the fail-open contract.

## How the decision round-trip is wired

```
notchide-hook ──HookEnvelope──▶ UnixSocketServer.handler        (AppBootstrap)
                                  │ await SessionStore.ingest      → lanes/glyphs (cockpit)
                                  │ await Suppressor.shouldTap      → frontmost check (AppKitFrontmostContext)
                                  │ await NotchController.present   → morph down the console
                                  │ await DecisionBroker.awaitDecision(id:)   ← suspends here
                                  ▼
Approve / Deny / redirect ──▶ NotchViewModel.onDecide ──▶ DecisionBroker.resolve(id:)
                                  ▼
notchide-hook ◀──DecisionMessage── written back down the still-open socket
```

Non-decision events only update lanes/glyphs. A `wantsDecision` gate suspends in
the broker until you act; if you never do, a timeout resolves to `nil` and the
sidecar's own hard timeout **fails open** — the agent is never bricked.

## Deps

Intentionally minimal — only **DynamicNotchKit** (the notch shell) and the local
**NotchideKit** core. The planned syntax-highlighting stack (Neon +
SwiftTreeSitter + CodeEditLanguages) is **not** added yet so the app resolves and
compiles reliably; `SwiftSyntaxHighlighter.swift` is the built-in stand-in.
