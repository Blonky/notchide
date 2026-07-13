import Testing
import Foundation
@testable import NotchideKit

@Suite("HotkeyConfig")
struct HotkeyConfigTests {

    private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(T.self, from: data)
    }

    @Test("PTTTrigger round-trips through Codable, including .custom")
    func pttTriggerRoundTrip() throws {
        let triggers: [PTTTrigger] = [
            .fnDoubleTap,
            .controlOption,
            .custom(modifiers: ["⌃", "⌥"], key: "Space"),
            .custom(modifiers: [], key: "F5"),
            .custom(modifiers: ["⌘"], key: nil),
        ]
        for trigger in triggers {
            #expect(try roundTrip(trigger) == trigger)
        }
    }

    @Test("HotkeyConfig round-trips through Codable")
    func configRoundTrip() throws {
        let config = HotkeyConfig(
            pushToTalk: .fnDoubleTap,
            interrupt: .controlOption,
            openPalette: .custom(modifiers: ["⌃", "⌥"], key: "P")
        )
        #expect(try roundTrip(config) == config)
    }

    @Test("defaultConfig binds fn-double-tap push-to-talk and nothing else")
    func defaultConfigDefaults() {
        #expect(HotkeyConfig.defaultConfig.pushToTalk == .fnDoubleTap)
        #expect(HotkeyConfig.defaultConfig.interrupt == nil)
        #expect(HotkeyConfig.defaultConfig.openPalette == nil)
    }

    @Test("displayName is non-empty and correctly formatted for each trigger")
    func displayNames() {
        let triggers: [PTTTrigger] = [
            .fnDoubleTap,
            .controlOption,
            .custom(modifiers: ["⌃", "⌥"], key: "Space"),
        ]
        for trigger in triggers {
            #expect(!trigger.displayName.isEmpty)
        }
        #expect(PTTTrigger.fnDoubleTap.displayName == "Fn Fn")
        #expect(PTTTrigger.controlOption.displayName == "⌃⌥")
        #expect(PTTTrigger.custom(modifiers: ["⌃", "⌥"], key: "Space").displayName == "⌃⌥ + Space")
        #expect(PTTTrigger.custom(modifiers: ["⌃", "⌥"], key: nil).displayName == "⌃⌥")
        #expect(PTTTrigger.custom(modifiers: [], key: "F5").displayName == "F5")
    }

    @Test("isValid() rejects an empty custom chord")
    func isValidRejectsEmptyCustom() {
        let invalid = HotkeyConfig(pushToTalk: .custom(modifiers: [], key: nil))
        #expect(invalid.isValid() == false)
    }

    @Test("isValid() accepts a custom chord with a modifier or a key")
    func isValidAcceptsNonEmptyCustom() {
        #expect(HotkeyConfig(pushToTalk: .custom(modifiers: ["⌘"], key: nil)).isValid())
        #expect(HotkeyConfig(pushToTalk: .custom(modifiers: [], key: "F5")).isValid())
        #expect(HotkeyConfig.defaultConfig.isValid())
    }

    @Test("isValid() checks every bound action, not just push-to-talk")
    func isValidChecksOptionalBindings() {
        let config = HotkeyConfig(
            pushToTalk: .fnDoubleTap,
            interrupt: .custom(modifiers: [], key: nil)
        )
        #expect(config.isValid() == false)
    }
}
