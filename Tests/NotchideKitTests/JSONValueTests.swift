import Testing
import Foundation
@testable import NotchideKit

@Suite("JSONValue.intValue non-trapping conversion")
struct JSONValueTests {

    @Test("intValue returns nil (never traps) for NaN, ±infinity, and out-of-range doubles")
    func intValueNonTrapping() {
        // These would all trap with `Int(Double)`.
        #expect(JSONValue.number(.nan).intValue == nil)
        #expect(JSONValue.number(.infinity).intValue == nil)
        #expect(JSONValue.number(-.infinity).intValue == nil)
        #expect(JSONValue.number(1e30).intValue == nil)
        #expect(JSONValue.number(-1e30).intValue == nil)
    }

    @Test("intValue converts representable doubles (rounding to nearest)")
    func intValueConverts() {
        #expect(JSONValue.number(42.0).intValue == 42)
        #expect(JSONValue.number(0.0).intValue == 0)
        #expect(JSONValue.number(-7.0).intValue == -7)
        #expect(JSONValue.number(2.6).intValue == 3)   // rounds to nearest
        #expect(JSONValue.number(2.4).intValue == 2)
    }

    @Test("intValue is nil for non-number kinds")
    func intValueNilForNonNumbers() {
        #expect(JSONValue.string("5").intValue == nil)
        #expect(JSONValue.bool(true).intValue == nil)
        #expect(JSONValue.null.intValue == nil)
    }

    @Test("intValue survives a decoded huge value without crashing")
    func intValueFromDecodedValue() throws {
        // A tool_input carrying an enormous (but finite) number must not crash
        // accessors: 1e30 is far outside Int's range, so intValue is nil.
        let decoded = try JSONDecoder().decode(JSONValue.self, from: Data("1e30".utf8))
        #expect(decoded.doubleValue == 1e30)
        #expect(decoded.intValue == nil)
    }
}
