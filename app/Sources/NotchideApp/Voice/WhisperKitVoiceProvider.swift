import Foundation
import NotchideKit

/// The offline fallback `VoiceProvider` — a STUB for now.
///
/// On machines without the macOS 26 on-device `SpeechAnalyzer`
/// (`SpeechTranscriberVoiceProvider`), notchide will fall back to a bundled
/// WhisperKit model. That real implementation is intentionally NOT wired yet:
/// pulling it in means adding the `argmaxinc/argmax-oss-swift` (WhisperKit) SPM
/// dependency, which would fetch/compile a large model stack and make the app
/// build far less reliable. Until that lands, this stub keeps the voice pipeline
/// type-complete and the build fast/hermetic.
///
/// TODO: Replace with a real WhisperKit-backed provider:
///   • add the `argmaxinc/argmax-oss-swift` package (product `WhisperKit`),
///   • bundle a small model (e.g. `openai_whisper-base`) in the app resources,
///   • initialize `WhisperKit` with `download: false` / a local `modelFolder` so
///     it NEVER reaches the network at runtime (remote fetch disabled),
///   • stream `transcribe(audioArray:)` partials into `Transcript.volatile` /
///     `.final`, mirroring `SpeechTranscriberVoiceProvider`.
public final class WhisperKitVoiceProvider: VoiceProvider, @unchecked Sendable {
    public init() {}

    public func start() -> AsyncStream<Transcript> {
        AsyncStream { continuation in
            // Emit a single, explanatory final so a caller on a pre-26 OS gets a
            // clear signal rather than a silent hang. It is short enough that the
            // VoiceController's ≥minWords guard will not actuate it.
            continuation.yield(.final("WhisperKit fallback not bundled"))
            continuation.finish()
        }
    }

    public func stop() {}
}
