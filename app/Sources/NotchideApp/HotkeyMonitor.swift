import AppKit
import ApplicationServices

/// The global summon hotkey + ESC handling.
///
/// Uses `NSEvent` monitors (no Carbon `RegisterEventHotKey` needed) so it is a
/// real, working implementation rather than a stub:
///   • a GLOBAL monitor fires when the app is in the background — this is the
///     "summon the most-urgent session from anywhere, over fullscreen" hotkey
///     (⌘⌥N by default),
///   • a LOCAL monitor handles ESC to furl the console when notchide is frontmost.
///
/// NOTE: `NSEvent` GLOBAL monitors require the app to be trusted for Accessibility.
/// The app never had a way to request this, so `start()` now actively checks
/// `AXIsProcessTrusted()` and, if untrusted, calls
/// `AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt: true])` to surface
/// the system prompt (this does not block). Until the user grants it, the global
/// summon hotkey is simply inert — the rest of the UI (hover-intent, ESC while
/// frontmost, tap-to-expand) still works, since the LOCAL monitor needs no trust.
@MainActor
public final class HotkeyMonitor {
    /// keyCode 45 == "n".
    public var summonKeyCode: UInt16 = 45
    public var summonModifiers: NSEvent.ModifierFlags = [.command, .option]

    public var onSummon: (() -> Void)?
    public var onEscape: (() -> Void)?
    /// Return / Enter while notchide is frontmost (drives "send now" for the voice
    /// review HUD). Local-only, so it never hijacks Return in other apps.
    public var onReturn: (() -> Void)?

    private var globalMonitor: Any?
    private var localMonitor: Any?

    public init() {}

    public func start() {
        // Global NSEvent monitors need Accessibility trust; surface the system
        // prompt once if we don't have it yet (non-blocking).
        requestAccessibilityTrustIfNeeded()

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            MainActor.assumeIsolated {
                // Global monitor: only the summon combo is relevant.
                self?.handleKeyDown(event, allowEscape: false)
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event -> NSEvent? in
            MainActor.assumeIsolated {
                self?.handleKeyDown(event, allowEscape: true)
            }
            return event
        }
    }

    /// Prompts for Accessibility trust the first time if it is not yet granted.
    /// No-op once trusted; never blocks (the OS shows its own settings prompt).
    private func requestAccessibilityTrustIfNeeded() {
        guard !AXIsProcessTrusted() else { return }
        // Use the documented key's string value directly; referencing the global
        // `kAXTrustedCheckOptionPrompt` var is not concurrency-safe under Swift 6.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
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
        } else if allowEscape, mods.isEmpty, event.keyCode == 36 || event.keyCode == 76 { // Return / keypad Enter
            onReturn?()
        }
    }
}
