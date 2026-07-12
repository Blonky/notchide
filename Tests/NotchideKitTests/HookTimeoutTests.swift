import Testing
import Foundation
@testable import NotchideKit

@Suite("HookTimeout strict parsing / clamping")
struct HookTimeoutTests {

    @Test("nil / empty / blank falls back to the default")
    func fallbackForMissing() {
        #expect(HookTimeout.milliseconds(from: nil) == HookTimeout.defaultMilliseconds)
        #expect(HookTimeout.milliseconds(from: "") == HookTimeout.defaultMilliseconds)
        #expect(HookTimeout.milliseconds(from: "   ") == HookTimeout.defaultMilliseconds)
    }

    @Test("non-integer / NaN / inf / negative all fall back to the default (never propagate)")
    func fallbackForInvalid() {
        for bad in ["abc", "1.5", "1e3", "nan", "NaN", "inf", "Infinity", "-1", "-500", "0x10", "12ms"] {
            #expect(HookTimeout.milliseconds(from: bad) == HookTimeout.defaultMilliseconds,
                    "\(bad) should fall back")
        }
    }

    @Test("valid values are accepted and clamped to the max")
    func acceptsAndClamps() {
        #expect(HookTimeout.milliseconds(from: "0") == 0)
        #expect(HookTimeout.milliseconds(from: "250") == 250)
        #expect(HookTimeout.milliseconds(from: " 1000 ") == 1000) // trims whitespace
        #expect(HookTimeout.milliseconds(from: "600000") == 600_000)
        // Above the max clamps down rather than hanging unbounded.
        #expect(HookTimeout.milliseconds(from: "3600001") == HookTimeout.maxMilliseconds)
        #expect(HookTimeout.milliseconds(from: "999999999") == HookTimeout.maxMilliseconds)
    }

    @Test("absurdly huge (Int-overflowing) input falls back rather than trapping")
    func hugeInputFallsBack() {
        #expect(HookTimeout.milliseconds(from: "999999999999999999999999999") == HookTimeout.defaultMilliseconds)
    }
}
