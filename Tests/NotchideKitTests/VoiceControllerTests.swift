import Testing
import Foundation
@testable import NotchideKit

@Suite("Voice controller (pure, injected time)")
struct VoiceControllerTests {

    private let key = SessionKey(provider: ProviderID("sh.claude"), agentSessionID: "s", cwd: "/tmp")

    /// Builds a controller and a mutable sink capturing the last emitted intent.
    private func makeController(
        silenceCap: TimeInterval = 15,
        totalCap: TimeInterval = 120,
        reviewGrace: TimeInterval = 1.5
    ) -> (VoiceController, () -> VoiceIntent?) {
        let controller = VoiceController(silenceCap: silenceCap, totalCap: totalCap, reviewGrace: reviewGrace)
        let box = UncheckedBox<VoiceIntent?>(nil)
        controller.onIntent = { box.value = $0 }
        return (controller, { box.value })
    }

    @Test("armed → listening → review → sent happy path")
    func happyPath() {
        let (c, intent) = makeController()
        #expect(c.state == .idle)
        c.arm()
        #expect(c.state == .armed)
        c.press()
        #expect(c.state == .listening)
        c.ingest(.final("run the tests"))
        #expect(c.state == .listening)
        #expect(c.currentText == "run the tests")
        c.release()
        #expect(c.state == .review)
        #expect(intent() == nil, "must not send before the grace elapses")
        c.advance(by: 1.5)
        #expect(c.state == .sent)
        #expect(intent()?.text == "run the tests")
    }

    @Test("the ≥3-word guard blocks a 2-word final from auto-sending")
    func wordGuardBlocksShortFinal() {
        let (c, intent) = makeController()
        c.press()
        c.ingest(.final("hello there")) // 2 words
        c.release()
        c.advance(by: 5) // well past the grace
        #expect(c.state == .review, "a short final must not reach .sent")
        #expect(intent() == nil)
    }

    @Test("Return sends immediately, skipping the remaining grace")
    func returnSendsNow() {
        let (c, intent) = makeController()
        c.press()
        c.ingest(.final("run the tests"))
        c.release()
        #expect(c.state == .review)
        c.sendNow()
        #expect(c.state == .sent)
        #expect(intent()?.text == "run the tests")
    }

    @Test("the review grace window holds the send until it elapses")
    func graceWindowHoldsThenSends() {
        let (c, intent) = makeController()
        c.press()
        c.ingest(.final("run the tests"))
        c.release()
        c.advance(by: 0.5) // partway through the 1.5s grace
        #expect(c.state == .review)
        #expect(intent() == nil)
        c.advance(by: 2.0) // now past it
        #expect(c.state == .sent)
        #expect(intent()?.text == "run the tests")
    }

    @Test("ESC cancels cleanly to idle without emitting")
    func escCancels() {
        let (c, intent) = makeController()
        c.press()
        c.ingest(.final("run the tests"))
        c.release()
        c.cancel()
        #expect(c.state == .idle)
        #expect(intent() == nil)
        // A cancelled utterance never sends, even if time passes.
        c.advance(by: 10)
        #expect(c.state == .idle)
        #expect(intent() == nil)
    }

    @Test("the 15s silence cap fires, and a new transcript resets it")
    func silenceCapFiresAndResets() {
        let (c, _) = makeController()
        c.press()
        c.advance(by: 15)
        #expect(c.state == .error(.silenceTimeout))

        // Reset case: activity at 14s pushes the deadline out to 29s.
        let (c2, _) = makeController()
        c2.press()
        c2.advance(by: 14)
        c2.ingest(.volatile("still typing"))
        c2.advance(by: 14) // total 28s, but only 14s since activity
        #expect(c2.state == .listening)
        c2.advance(by: 1) // 15s since activity → fires
        #expect(c2.state == .error(.silenceTimeout))
    }

    @Test("the 2min total cap fires despite continued speech")
    func totalCapFires() {
        let (c, _) = makeController()
        c.press()
        // Speak every 10s (< the 15s silence cap) so only the total cap can fire.
        for _ in 0..<12 {
            c.advance(by: 10)
            c.ingest(.volatile("still going strong"))
        }
        #expect(c.state == .error(.totalTimeout))
    }

    @Test("volatiles surface live but only a final is committed")
    func volatilesSurfaceOnlyFinalCommits() {
        let (c, intent) = makeController()
        c.press()
        c.ingest(.volatile("run"))
        #expect(c.currentText == "run")
        #expect(intent() == nil)
        c.ingest(.volatile("run the"))
        #expect(c.currentText == "run the")
        #expect(intent() == nil)
        c.ingest(.final("run the tests"))
        #expect(c.currentText == "run the tests")
        c.release()
        c.sendNow()
        #expect(c.state == .sent)
        #expect(intent()?.text == "run the tests")
    }

    @Test("releasing after only volatiles (no final) commits nothing")
    func noFinalCommitsNothing() {
        let (c, intent) = makeController()
        c.press()
        c.ingest(.volatile("run the tests four")) // 4 words, but volatile
        c.release()
        c.sendNow()
        #expect(c.state == .review, "with no final there is nothing to commit")
        #expect(intent() == nil)
    }

    @Test("the target session flows through to the emitted intent")
    func targetSessionFlowsThrough() {
        let (c, intent) = makeController()
        c.press(target: key)
        c.ingest(.final("run the tests"))
        c.release()
        c.sendNow()
        #expect(intent()?.targetSession == key)
    }

    @Test("onStateChange observes every transition")
    func stateChangesAreObserved() {
        let c = VoiceController()
        let box = UncheckedBox<[VoiceState]>([])
        c.onStateChange = { box.value.append($0) }
        c.arm()
        c.press()
        c.ingest(.final("run the tests"))
        c.release()
        c.advance(by: 1.5)
        #expect(box.value == [.armed, .listening, .review, .sent])
    }
}

@Suite("Stub voice provider")
struct StubVoiceProviderTests {

    @Test("replays its scripted transcript sequence in order")
    func replaysScript() async {
        let script: [Transcript] = [.volatile("a"), .volatile("ab"), .final("abc")]
        let provider = StubVoiceProvider(script)
        var received: [Transcript] = []
        for await transcript in provider.start() {
            received.append(transcript)
        }
        #expect(received == script)
    }
}
