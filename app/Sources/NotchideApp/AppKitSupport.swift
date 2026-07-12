import AppKit
import Foundation
import NotchideKit

/// Bundle identifiers notchide treats as "a terminal the agent could live in".
let knownTerminalBundleIDs: Set<String> = [
    "com.apple.Terminal",
    "com.googlecode.iterm2",
    "com.mitchellh.ghostty",
    "net.kovidgoyal.kitty",
    "io.alacritty",
    "com.github.wez.wezterm",
    "dev.warp.Warp-Stable",
    "com.microsoft.VSCode",
    "co.zeit.hyper",
]

/// A real `FrontmostContextProviding` backed by AppKit.
///
/// v0.1 heuristic: a session is considered "visible" when a known terminal
/// emulator is the frontmost application — if the user is already looking at a
/// terminal, notchide stays silent and lets Claude Code's own prompt do its job.
///
/// TODO: This is deliberately coarse. Precise per-window / per-Space detection
/// (matching the specific session's window title / cwd to the frontmost window,
/// and confirming it is on the active Space) needs the Accessibility API and
/// SkyLight/`CGSSpace` and is a later milestone (see docs/DESIGN.md §7, §10).
public struct AppKitFrontmostContext: FrontmostContextProviding {
    private let terminalBundleIDs: Set<String>

    public init(terminalBundleIDs: Set<String>? = nil) {
        self.terminalBundleIDs = terminalBundleIDs ?? knownTerminalBundleIDs
    }

    public func isSessionVisible(_ key: SessionKey) async -> Bool {
        let ids = terminalBundleIDs
        return await MainActor.run {
            guard let front = NSWorkspace.shared.frontmostApplication else { return false }
            return ids.contains(front.bundleIdentifier ?? "")
        }
    }
}

/// Best-effort "jump to terminal" escape hatch.
///
/// Activates a running terminal emulator if one exists, otherwise falls back to
/// launching Terminal.app at the lane's working directory.
///
/// SECURITY: `cwd` is agent/attacker-controlled, so it must never reach a shell.
/// The fallback launches `/usr/bin/open -a Terminal <cwd>` via `Process`, where
/// `cwd` is a separate argv element — no `osascript` / `do script` string
/// interpolation, so a crafted cwd cannot inject a command.
public struct TerminalJumper: Sendable {
    public init() {}

    /// Bring a terminal to the front. `cwd` is used only by the launch fallback.
    @MainActor
    public func jump(cwd: String) {
        let workspace = NSWorkspace.shared
        let running = workspace.runningApplications
        if let app = running.first(where: { knownTerminalBundleIDs.contains($0.bundleIdentifier ?? "") }) {
            app.activate(options: [.activateIgnoringOtherApps])
            return
        }
        // Fallback: open Terminal.app (at cwd if we have one) with no shell. `cwd`
        // is passed as its own argv element, so it is never interpreted.
        let arguments = cwd.isEmpty ? ["-a", "Terminal"] : ["-a", "Terminal", cwd]
        Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = arguments
            try? process.run()
        }
    }
}
