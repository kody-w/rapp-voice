import Foundation

public struct DictationRequest: Sendable {
    public var audioURL: URL
    public var modelURL: URL
    public var appName: String
    public var bundleID: String
    public var dictionary: VoiceDictionary
    public var settings: VoiceSettings
    public init(audioURL: URL, modelURL: URL, appName: String, bundleID: String = "",
                dictionary: VoiceDictionary = .init(), settings: VoiceSettings = .init()) {
        self.audioURL = audioURL
        self.modelURL = modelURL
        self.appName = appName
        self.bundleID = bundleID
        self.dictionary = dictionary
        self.settings = settings
    }
}

public enum CleanupResult: Equatable, Sendable {
    case localOnly, polished(provider: String), localFallback(reason: String)
    public var label: String {
        switch self {
        case .localOnly: return "Local cleanup only"
        case .polished(let provider): return "Polished by \(provider)"
        case .localFallback(let reason): return "Local cleanup only — polish failed: \(reason)"
        }
    }
}

public struct DictationResult: Equatable, Sendable {
    public let text: String
    public let cleanup: CleanupResult
    public let silenceReason: String?
    public init(text: String, cleanup: CleanupResult = .localOnly, silenceReason: String? = nil) {
        self.text = text
        self.cleanup = cleanup
        self.silenceReason = silenceReason
    }
}

public enum VoicePipeline {
    public typealias Transcribe = @Sendable (_ audio: URL, _ model: URL, _ language: String, _ prompt: String?) async throws -> String
    public typealias Polish = @Sendable (_ text: String, _ settings: PolishSettings, _ directory: URL) async throws -> String

    public static func run(_ request: DictationRequest, transcribe: @escaping Transcribe,
                           polish: @escaping Polish) async throws -> DictationResult {
        try Task.checkCancellation()
        guard FileManager.default.fileExists(atPath: request.modelURL.path) else { throw VoiceError.modelMissing }
        let wav = try WAVAudio.read(request.audioURL)
        guard wav.duration <= request.settings.maxRecordSeconds + 0.25 else {
            throw VoiceError.invalidWAV("audio exceeds the configured recording limit")
        }
        if wav.duration < request.settings.minRecordSeconds {
            return .init(text: "", silenceReason: "too_short")
        }
        if wav.peak == 0 {
            return .init(text: "", silenceReason: "digital_silence")
        }
        let raw = try await withDeadline(seconds: request.settings.transcriptionTimeout, stage: "Transcription") {
            try await transcribe(request.audioURL, request.modelURL, request.settings.language, request.dictionary.weightedPrompt)
        }
        try Task.checkCancellation()
        var text = raw
        var cleanup = CleanupResult.localOnly
        if request.settings.polish.hasConsent,
           let remainder = TextProcessor.polishRemainder(raw, trigger: request.settings.polishTrigger) {
            guard !remainder.isEmpty else { return .init(text: "", silenceReason: "empty_polish_request") }
            text = remainder
            do {
                let polished = try await withDeadline(seconds: request.settings.polishTimeout, stage: "Polish") {
                    try await polish(remainder, request.settings.polish, request.audioURL.deletingLastPathComponent())
                }.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !polished.isEmpty else { throw VoiceError.invalidAction("the hook returned no text") }
                text = polished
                cleanup = .polished(provider: request.settings.polish.provider)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                cleanup = .localFallback(reason: error.localizedDescription)
            }
        }
        try Task.checkCancellation()
        let final = TextProcessor.process(
            text, rawMode: TextProcessor.isRawApp(name: request.appName, bundleID: request.bundleID, settings: request.settings),
            dictionary: request.dictionary, settings: request.settings
        )
        return .init(text: final, cleanup: cleanup, silenceReason: final.isEmpty ? "no_speech" : nil)
    }

    public static func withDeadline<T: Sendable>(seconds: Double, stage: String,
                                                 operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(0, min(seconds, 600)) * 1_000_000_000))
                throw VoiceError.timeout(stage)
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw CancellationError() }
            return first
        }
    }
}
