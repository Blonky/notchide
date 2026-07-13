import SwiftUI
import AppKit
import NotchideKit

/// The Hotkeys pane — edits the real `HotkeyConfig`.
///
/// Push-to-talk is presented with `⌃⌥` (`.controlOption`) as the **recommended**
/// default: double-tap-Fn *is* the macOS Dictation trigger and would collide, so
/// that option carries a caution. Each action can also take an arbitrary
/// `.custom` chord via a live recorder; optional actions can be turned off.
struct HotkeysPane: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        PaneScaffold(
            title: "Hotkeys",
            subtitle: "Bindings for voice and the command palette. Summon (open a session) is a separate, permission-free key; these are the press-and-hold and palette actions."
        ) {
            SettingsCallout(
                .caution,
                "Push-to-talk is press-and-hold. Don't bind it to double-tap-Fn — that chord is macOS Dictation, and notchide would fight the OS for it. ⌃⌥ (Control+Option) is the recommended default and never collides."
            )

            HotkeyRow(
                title: "Push to talk",
                subtitle: "Hold to dictate a steer to the focused session.",
                allowOff: false,
                trigger: Binding(
                    get: { store.hotkeys.pushToTalk },
                    set: { new in
                        var config = store.hotkeys
                        config.pushToTalk = new ?? .controlOption
                        store.updateHotkeys(config)
                    }
                )
            )

            HotkeyRow(
                title: "Interrupt",
                subtitle: "Cut the current agent turn short.",
                allowOff: true,
                trigger: Binding(
                    get: { store.hotkeys.interrupt },
                    set: { new in
                        var config = store.hotkeys
                        config.interrupt = new
                        store.updateHotkeys(config)
                    }
                )
            )

            HotkeyRow(
                title: "Open palette",
                subtitle: "Bring up the command palette.",
                allowOff: true,
                trigger: Binding(
                    get: { store.hotkeys.openPalette },
                    set: { new in
                        var config = store.hotkeys
                        config.openPalette = new
                        store.updateHotkeys(config)
                    }
                )
            )

            SettingsCallout(
                .success,
                "Summon is permission-free — it uses Carbon RegisterEventHotKey and never prompts. Push-to-talk additionally needs Accessibility + Input Monitoring, requested once at voice onboarding (not lazily on first press). Decline and summon-only still works; PTT stays disabled until granted."
            )
        }
    }
}

/// A single action's binding editor: a mode picker plus a live chord recorder for
/// the `.custom` case.
private struct HotkeyRow: View {
    let title: String
    let subtitle: String
    /// Whether this action may be unbound (optional actions only).
    let allowOff: Bool
    @Binding var trigger: PTTTrigger?

    private enum Mode: Hashable { case recommended, fnDoubleTap, custom, off }

    private var mode: Mode {
        switch trigger {
        case .none: return .off
        case .controlOption: return .recommended
        case .fnDoubleTap: return .fnDoubleTap
        case .custom: return .custom
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(Typo.title)
                    Text(subtitle)
                        .font(Typo.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: Theme.Spacing.md)

                Picker("", selection: Binding(
                    get: { mode },
                    set: { applyMode($0) }
                )) {
                    Text("⌃⌥  (recommended)").tag(Mode.recommended)
                    Text("Fn Fn").tag(Mode.fnDoubleTap)
                    Text("Custom…").tag(Mode.custom)
                    if allowOff {
                        Divider()
                        Text("Off").tag(Mode.off)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 190)
            }

            if mode == .custom {
                HStack(spacing: Theme.Spacing.sm) {
                    ShortcutRecorder(current: trigger) { captured in
                        trigger = captured
                    }
                    .frame(height: 30)
                    .frame(maxWidth: 260)
                    Text("Click, then press a chord.")
                        .font(Typo.caption)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
            } else if mode == .fnDoubleTap {
                SettingsCallout(.caution, "This collides with macOS Dictation. Prefer ⌃⌥.")
            }
        }
        .padding(Theme.Spacing.md)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private func applyMode(_ newMode: Mode) {
        switch newMode {
        case .recommended: trigger = .controlOption
        case .fnDoubleTap: trigger = .fnDoubleTap
        case .off: trigger = nil
        case .custom:
            // Seed with the existing custom chord, or an empty one to record into.
            if case .custom = trigger { break }
            trigger = .custom(modifiers: ["⌃", "⌥"], key: "Space")
        }
    }
}

// MARK: - Chord recorder (AppKit)

/// A KeyboardShortcuts-style recorder: click to arm, press a modifier+key chord to
/// capture it as a `PTTTrigger.custom`. Renders its own chip so it needs no
/// surrounding chrome.
private struct ShortcutRecorder: NSViewRepresentable {
    let current: PTTTrigger?
    let onCapture: (PTTTrigger) -> Void

    func makeNSView(context: Context) -> RecorderView {
        let view = RecorderView()
        view.onCapture = onCapture
        view.current = current
        return view
    }

    func updateNSView(_ nsView: RecorderView, context: Context) {
        nsView.current = current
        nsView.onCapture = onCapture
        nsView.needsDisplay = true
    }
}

private final class RecorderView: NSView {
    var onCapture: ((PTTTrigger) -> Void)?
    var current: PTTTrigger?
    private var recording = false {
        didSet { needsDisplay = true }
    }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    override func mouseDown(with event: NSEvent) {
        recording.toggle()
        if recording { window?.makeFirstResponder(self) }
    }

    override func keyDown(with event: NSEvent) {
        guard recording else { super.keyDown(with: event); return }
        let modifiers = event.modifierFlags.notchideGlyphs
        let key = RecorderView.keyName(for: event)
        // Require at least one modifier or a key so the result is a valid chord.
        guard !modifiers.isEmpty || key != nil else {
            NSSound.beep()
            return
        }
        recording = false
        onCapture?(.custom(modifiers: modifiers, key: key))
    }

    override func resignFirstResponder() -> Bool {
        recording = false
        return super.resignFirstResponder()
    }

    override func draw(_ dirtyRect: NSRect) {
        let radius = Theme.Radius.control
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: radius, yRadius: radius)
        (recording ? NSColor.controlAccentColor.withAlphaComponent(0.12) : NSColor.textBackgroundColor).setFill()
        path.fill()
        (recording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.lineWidth = recording ? 2 : 1
        path.stroke()

        let label: String
        if recording {
            label = "Type a shortcut…"
        } else if let displayName = current?.displayName, !displayName.isEmpty {
            label = displayName
        } else {
            label = "Click to record"
        }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: recording ? NSColor.controlAccentColor : NSColor.labelColor,
        ]
        let text = NSAttributedString(string: label, attributes: attributes)
        let size = text.size()
        let origin = NSPoint(x: 10, y: (bounds.height - size.height) / 2)
        text.draw(at: origin)
    }

    /// A display name for the pressed non-modifier key, or `nil` for a bare
    /// modifier chord.
    static func keyName(for event: NSEvent) -> String? {
        switch event.keyCode {
        case 49: return "Space"
        case 36, 76: return "Return"
        case 48: return "Tab"
        case 53: return "Esc"
        case 51: return "Delete"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        default:
            let chars = (event.charactersIgnoringModifiers ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return chars.isEmpty ? nil : chars.uppercased()
        }
    }
}

private extension NSEvent.ModifierFlags {
    /// The chord glyphs in canonical macOS order (⌃⌥⇧⌘).
    var notchideGlyphs: [String] {
        var glyphs: [String] = []
        if contains(.control) { glyphs.append("⌃") }
        if contains(.option) { glyphs.append("⌥") }
        if contains(.shift) { glyphs.append("⇧") }
        if contains(.command) { glyphs.append("⌘") }
        return glyphs
    }
}
