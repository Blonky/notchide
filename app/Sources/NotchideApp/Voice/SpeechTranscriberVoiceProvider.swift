// AVFAudio's mic/converter types (AVAudioPCMBuffer, AVAudioConverter's input
// block) predate Sendable annotations; the converter block is invoked
// synchronously, so `@preconcurrency` keeps that interop warning-free.
@preconcurrency import AVFoundation
import Foundation
import NotchideKit
import Speech

/// A real `VoiceProvider` backed by Apple's on-device Speech framework
/// (`SpeechAnalyzer` + `SpeechTranscriber`, macOS 26+).
///
/// It taps the microphone with an `AVAudioEngine`, converts each captured buffer
/// to the analyzer's preferred format, feeds them to a `SpeechTranscriber`
/// configured for `.volatileResults`, and maps each result to
/// `Transcript.volatile` / `.final` on the returned `AsyncStream`.
///
/// The engine machinery is isolated behind `if #available(macOS 26, *)` in a
/// gated inner class so the provider still *compiles* on the deployment target
/// (macOS 13). On an OS without the API, `start()` yields a single `.final("")`
/// and ends — never a crash.
///
/// `@unchecked Sendable`: the mutable engine reference is guarded by `lock`, and
/// the audio-thread tap only touches the (thread-safe) `AsyncStream` continuation.
public final class SpeechTranscriberVoiceProvider: VoiceProvider, @unchecked Sendable {
    private let lock = NSLock()
    /// Holds a `SpeechEngine` on macOS 26+, `nil` otherwise. Untyped so the
    /// gated type is never named outside an availability check.
    private var engine: AnyObject?

    public init() {}

    public func start() -> AsyncStream<Transcript> {
        AsyncStream { continuation in
            if #available(macOS 26.0, *) {
                let engine = SpeechEngine(continuation: continuation)
                self.lock.lock()
                self.engine = engine
                self.lock.unlock()
                continuation.onTermination = { [weak self] _ in self?.stop() }
                engine.start()
            } else {
                // Speech's on-device SpeechAnalyzer is unavailable on this OS; the
                // WhisperKit fallback provider handles pre-26 machines. Emit an
                // empty final so the pipeline ends cleanly instead of hanging.
                continuation.yield(.final(""))
                continuation.finish()
            }
        }
    }

    public func stop() {
        lock.lock()
        let engine = self.engine
        self.engine = nil
        lock.unlock()
        if #available(macOS 26.0, *) {
            (engine as? SpeechEngine)?.stop()
        }
    }
}

/// One-shot latch for the AVAudioConverter input block (see `convert`). The block
/// is invoked synchronously on the calling thread, so this is safe to mark
/// `@unchecked Sendable`.
private final class ConversionState: @unchecked Sendable {
    var supplied = false
}

// MARK: - macOS 26 engine

/// The actual mic-tap + `SpeechAnalyzer` pipeline. Gated to macOS 26 so its use
/// of `SpeechTranscriber` / `SpeechAnalyzer` / `AnalyzerInput` is only ever
/// referenced where those types exist.
@available(macOS 26.0, *)
private final class SpeechEngine: @unchecked Sendable {
    private let continuation: AsyncStream<Transcript>.Continuation
    private let audioEngine = AVAudioEngine()

    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var setupTask: Task<Void, Never>?
    private var resultsTask: Task<Void, Never>?

    private let stateLock = NSLock()
    private var stopped = false

    init(continuation: AsyncStream<Transcript>.Continuation) {
        self.continuation = continuation
    }

    func start() {
        setupTask = Task { [weak self] in
            guard let self else { return }
            guard await Self.requestAuthorization() else {
                self.finish()
                return
            }
            do {
                try await self.configureAndRun()
            } catch {
                NSLog("notchide: voice engine failed: \(error.localizedDescription)")
                self.finish()
            }
        }
    }

    func stop() {
        stateLock.lock()
        if stopped { stateLock.unlock(); return }
        stopped = true
        stateLock.unlock()

        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        inputContinuation?.finish()
        resultsTask?.cancel()
        setupTask?.cancel()

        // Flush any buffered audio through the analyzer, then end the stream.
        let analyzer = self.analyzer
        Task {
            try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        }
        continuation.finish()
    }

    // MARK: Pipeline

    private func configureAndRun() async throws {
        let transcriber = SpeechTranscriber(
            locale: Locale.current,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: []
        )
        self.transcriber = transcriber

        // Ensure the on-device model for this locale is present (a no-op once
        // installed). `assetInstallationRequest` returns nil when nothing is
        // needed.
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }

        let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])

        // The analyzer consumes an async sequence of AnalyzerInput; the mic tap
        // pushes converted buffers into this continuation.
        var inputContinuation: AsyncStream<AnalyzerInput>.Continuation!
        let inputSequence = AsyncStream<AnalyzerInput>(bufferingPolicy: .unbounded) {
            inputContinuation = $0
        }
        self.inputContinuation = inputContinuation

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer

        // Drain transcriber results → Transcript on the outer stream.
        resultsTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    self.yield(result.isFinal ? .final(text) : .volatile(text))
                }
            } catch {
                // A cancelled/finished analyzer surfaces here; treat as end-of-stream.
            }
            self.finish()
        }

        try startAudioTap(targetFormat: analyzerFormat, into: inputContinuation)
        try await analyzer.start(inputSequence: inputSequence)
    }

    private func startAudioTap(
        targetFormat: AVAudioFormat?,
        into inputContinuation: AsyncStream<AnalyzerInput>.Continuation
    ) throws {
        let input = audioEngine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        let converter: AVAudioConverter? = targetFormat.flatMap { format in
            format == inputFormat ? nil : AVAudioConverter(from: inputFormat, to: format)
        }

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
            let outBuffer = SpeechEngine.convert(buffer, using: converter, to: targetFormat) ?? buffer
            inputContinuation.yield(AnalyzerInput(buffer: outBuffer))
        }

        audioEngine.prepare()
        try audioEngine.start()
    }

    /// Converts a captured buffer to the analyzer's format. Returns the input
    /// untouched when no conversion is required or possible.
    private static func convert(
        _ buffer: AVAudioPCMBuffer,
        using converter: AVAudioConverter?,
        to format: AVAudioFormat?
    ) -> AVAudioPCMBuffer? {
        guard let converter, let format else { return buffer }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            return nil
        }
        // A reference-typed latch avoids the "mutation of captured var" diagnostic
        // in the (synchronously-invoked) converter input block.
        let state = ConversionState()
        var conversionError: NSError?
        converter.convert(to: out, error: &conversionError) { _, status in
            if state.supplied {
                status.pointee = .noDataNow
                return nil
            }
            state.supplied = true
            status.pointee = .haveData
            return buffer
        }
        return conversionError == nil ? out : nil
    }

    // MARK: Helpers

    private func yield(_ transcript: Transcript) {
        continuation.yield(transcript)
    }

    private func finish() {
        continuation.finish()
    }

    /// Requests speech-recognition and microphone authorization. Both are needed
    /// before the analyzer can run; a denial ends the session quietly.
    private static func requestAuthorization() async -> Bool {
        let speechAuthorized = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status == .authorized)
            }
        }
        guard speechAuthorized else { return false }

        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            AVAudioApplication.requestRecordPermission { granted in
                cont.resume(returning: granted)
            }
        }
    }
}
