import Foundation

/// A push-to-talk / shortcut trigger the user can bind to a notchide action.
///
/// The two named cases are curated defaults with fixed glyphs; `.custom` carries
/// an arbitrary chord (modifier glyphs plus an optional key) so the settings UI
/// can offer a "record shortcut" affordance without new cases per combination.
public enum PTTTrigger: Sendable, Codable, Equatable {
    /// Tap the `Fn` (globe) key twice in quick succession.
    case fnDoubleTap
    /// Hold `Control`+`Option`.
    case controlOption
    /// An arbitrary chord: zero or more modifier glyphs and an optional key.
    case custom(modifiers: [String], key: String?)

    /// A human-readable label for the settings UI, e.g. `"Fn Fn"`, `"⌃⌥"`, or a
    /// custom chord like `"⌃⌥ + Space"`.
    public var displayName: String {
        switch self {
        case .fnDoubleTap:
            return "Fn Fn"
        case .controlOption:
            return "⌃⌥"
        case let .custom(modifiers, key):
            let chord = modifiers.joined()
            switch (chord.isEmpty, key) {
            case let (false, key?):
                return "\(chord) + \(key)"
            case (false, nil):
                return chord
            case let (true, key?):
                return key
            case (true, nil):
                return ""
            }
        }
    }

    /// Whether the trigger is well-formed: the named cases always are; a `.custom`
    /// chord needs at least one modifier or a non-nil key.
    public var isValid: Bool {
        switch self {
        case .fnDoubleTap, .controlOption:
            return true
        case let .custom(modifiers, key):
            return !modifiers.isEmpty || key != nil
        }
    }
}

/// The user's hotkey bindings for notchide's voice/palette actions.
///
/// Only `pushToTalk` is required; the others are opt-in. Persisted as JSON
/// (e.g. inside the app's settings blob).
public struct HotkeyConfig: Sendable, Codable, Equatable {
    /// Trigger that starts push-to-talk dictation.
    public var pushToTalk: PTTTrigger
    /// Optional trigger that interrupts the current agent turn.
    public var interrupt: PTTTrigger?
    /// Optional trigger that opens the command palette.
    public var openPalette: PTTTrigger?

    public init(
        pushToTalk: PTTTrigger = .fnDoubleTap,
        interrupt: PTTTrigger? = nil,
        openPalette: PTTTrigger? = nil
    ) {
        self.pushToTalk = pushToTalk
        self.interrupt = interrupt
        self.openPalette = openPalette
    }

    /// The out-of-the-box bindings: fn-double-tap for push-to-talk, nothing else.
    /// (Named `defaultConfig` because `default` is a keyword.)
    public static let defaultConfig = HotkeyConfig(
        pushToTalk: .fnDoubleTap,
        interrupt: nil,
        openPalette: nil
    )

    /// Whether every bound trigger is well-formed. Unbound (`nil`) actions are
    /// always fine; a bound `.custom` must have at least one modifier or a key.
    public func isValid() -> Bool {
        [pushToTalk, interrupt, openPalette]
            .compactMap { $0 }
            .allSatisfy { $0.isValid }
    }
}
