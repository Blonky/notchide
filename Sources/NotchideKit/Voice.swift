import Foundation

/// One unit of speech-to-text output.
///
/// - `volatile`: an in-progress hypothesis that may still change; surfaced to the
///   HUD for live feedback but never committed.
/// - `final`: a stabilized result the recognizer will not revise; the only kind
///   `VoiceController` will commit into a `VoiceIntent`.
public enum Transcript: Sendable, Equatable {
    case volatile(String)
    case final(String)

    /// The recognized text, regardless of stability.
    public var text: String {
        switch self {
        case .volatile(let text), .final(let text):
            return text
        }
    }

    /// Whether this is a stabilized (final) result.
    public var isFinal: Bool {
        if case .final = self { return true }
        return false
    }
}

/// A source of speech transcripts.
///
/// The mic-bound implementations (AVFoundation / `SFSpeechRecognizer`) live in the
/// app target; the core ships only this protocol plus `StubVoiceProvider` so the
/// voice pipeline is headless-testable.
public protocol VoiceProvider: Sendable {
    /// Begins recognition and returns a stream of transcripts. The stream
    /// finishes when recognition ends (or `stop()` is called).
    func start() -> AsyncStream<Transcript>
    /// Ends recognition. Idempotent.
    func stop()
}

/// A `VoiceProvider` that replays a fixed script of transcripts, for tests.
///
/// `start()` yields each scripted `Transcript` in order and then finishes, so a
/// test can drive the full pipeline deterministically without a microphone.
public final class StubVoiceProvider: VoiceProvider, @unchecked Sendable {
    private let script: [Transcript]

    public init(_ script: [Transcript]) {
        self.script = script
    }

    public func start() -> AsyncStream<Transcript> {
        let script = self.script
        return AsyncStream { continuation in
            for transcript in script {
                continuation.yield(transcript)
            }
            continuation.finish()
        }
    }

    public func stop() {}
}

/// A committed voice instruction, produced by `VoiceController` when a session is
/// sent.
///
/// `VoiceController` NEVER pastes or routes this text anywhere — it merely emits
/// the intent. Delivering it to a session (e.g. via `AgentAction.prompt`) is the
/// app's job. `targetSession` is whatever the app supplied when the utterance
/// began; `nil` means "route to the app's current default target".
public struct VoiceIntent: Sendable, Equatable {
    public let targetSession: SessionKey?
    public let text: String

    public init(targetSession: SessionKey?, text: String) {
        self.targetSession = targetSession
        self.text = text
    }
}
