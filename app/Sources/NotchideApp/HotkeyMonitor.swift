import AppKit

/// The global summon hotkey + ESC handling.
///
/// Uses `NSEvent` monitors (no Carbon `RegisterEventHotKey` needed) so it is a
/// real, working implementation rather than a stub:
///   • a GLOBAL monitor fires when the app is in the background — this is the
///     "summon the most-urgent session from anywhere, over fullscreen" hotkey
///     (⌘⌥N by default),
///   • a LOCAL monitor handles ESC to furl the console when notchide is frontmost.
///
/// NOTE: `NSEvent` global monitors require the app to be trusted for Accessibility
/// on some macOS versions; the app requests that at runtime. If not yet granted,
/// the summon hotkey is simply inert until the user approves it (the rest of the
/// UI — hover-intent, tap-to-expand — still works).
@MainActor
public final class HotkeyMonitor {
    /// keyCode 45 == "n".
    public var summonKeyCode: UInt16 = 45
    public var summonModifiers: NSEvent.ModifierFlags = [.command, .option]

    public var onSummon: (() -> Void)?
    public var onEscape: (() -> Void)?

    private var globalMonitor: Any?
    private var localMonitor: Any?

    public init() {}

    public func start() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { event in
            MainActor.assumeIsolated {
                // Global monitor: only the summon combo is relevant.
                self.handleKeyDown(event, allowEscape: false)
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event -> NSEvent? in
            MainActor.assumeIsolated {
                self.handleKeyDown(event, allowEscape: true)
            }
            return event
        }
    }

    public func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
    }

    private func handleKeyDown(_ event: NSEvent, allowEscape: Bool) {
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if event.keyCode == summonKeyCode, mods == summonModifiers {
            onSummon?()
        } else if allowEscape, event.keyCode == 53 { // ESC
            onEscape?()
        }
    }
}
