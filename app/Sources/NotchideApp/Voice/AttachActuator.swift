import Foundation
import NotchideKit

/// A basic ATTACH fallback for delivering a voice `.prompt` / `.interrupt` to a
/// session whose provider cannot receive server-pushed actuate frames — i.e. a
/// non-HOST, hook-adapter session (the `notchide-hook` PreToolUse adapter is a
/// transient per-event process with no live channel to inject into).
///
/// v1 strategy (best-effort, non-fatal):
///   1. if a cmux control socket is present, hand the text to it;
///   2. otherwise fall back to `tmux send-keys` against a target pane.
///
/// SECURITY: the prompt text and the target are agent/user-derived, so they are
/// ONLY ever passed as discrete `Process` argv elements — never interpolated into
/// a shell string — so a crafted transcript cannot inject a command.
///
/// TODO: This is a deliberately coarse v1. A real implementation needs a
/// session→pane registry (mapping a `SessionKey` to the exact tmux/cmux target
/// the agent runs in) instead of the env/`agentSessionID` heuristic below, plus a
/// defined cmux control-socket wire format.
public struct AttachActuator: Sendable {
    public init() {}

    /// Deliver a fresh instruction to the session's terminal.
    public func prompt(_ key: SessionKey, text: String) async {
        let target = Self.target(for: key)
        if await sendViaCmux(target: target, text: text) { return }
        // tmux: type the text literally, then submit with Enter.
        _ = await Self.runTmux(["send-keys", "-t", target, "-l", "--", text])
        _ = await Self.runTmux(["send-keys", "-t", target, "Enter"])
    }

    /// Barge-in: interrupt whatever the session is running (Ctrl-C).
    public func interrupt(_ key: SessionKey) async {
        let target = Self.target(for: key)
        if await sendViaCmux(target: target, text: "\u{03}") { return }
        _ = await Self.runTmux(["send-keys", "-t", target, "C-c"])
    }

    // MARK: - cmux

    /// Writes to a cmux control socket if one is configured/present. Returns
    /// whether it handled the delivery.
    private func sendViaCmux(target: String, text: String) async -> Bool {
        let fm = FileManager.default
        guard let socket = ProcessInfo.processInfo.environment["NOTCHIDE_CMUX_SOCKET"],
              !socket.isEmpty,
              fm.fileExists(atPath: socket) else {
            return false
        }
        // TODO: implement the cmux control-socket wire format (write a framed
        // {target,text} command). Until that is defined we do not claim delivery.
        NSLog("notchide: cmux socket present at \(socket) but the control protocol is not yet implemented; falling back to tmux")
        return false
    }

    // MARK: - tmux

    private static func target(for key: SessionKey) -> String {
        // TODO: replace with a real SessionKey→pane lookup. For now allow an
        // explicit override, else use the agent session id as the tmux target.
        if let override = ProcessInfo.processInfo.environment["NOTCHIDE_TMUX_TARGET"], !override.isEmpty {
            return override
        }
        return key.agentSessionID
    }

    /// Runs `tmux` with the given arguments (no shell). Returns success; a missing
    /// tmux or a non-existent target is a logged no-op, never a throw.
    @discardableResult
    private static func runTmux(_ arguments: [String]) async -> Bool {
        guard let tmux = resolveTool("tmux") else {
            NSLog("notchide: attach fallback unavailable — `tmux` not found")
            return false
        }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let process = Process()
            process.executableURL = tmux
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { proc in
                continuation.resume(returning: proc.terminationStatus == 0)
            }
            do {
                try process.run()
            } catch {
                NSLog("notchide: attach fallback failed to run tmux: \(error.localizedDescription)")
                continuation.resume(returning: false)
            }
        }
    }

    private static func resolveTool(_ name: String) -> URL? {
        let fm = FileManager.default
        var candidates = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)",
        ]
        if let envPath = ProcessInfo.processInfo.environment["PATH"] {
            candidates += envPath.split(separator: ":").map { "\($0)/\(name)" }
        }
        return candidates.map { URL(fileURLWithPath: $0) }.first { fm.isExecutableFile(atPath: $0.path) }
    }
}
