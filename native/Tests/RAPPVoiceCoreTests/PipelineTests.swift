import Foundation
import XCTest
@testable import RAPPVoiceCore

final class PipelineTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        // Never use the microphone, system temporary directory, or a user's speech/dictionary.
        let nativeRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        directory = nativeRoot.appendingPathComponent(".build/test-work/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }
    private func request(seconds: Double = 0.5, silent: Bool = false) throws -> DictationRequest {
        let wav = directory.appendingPathComponent("synthetic.wav")
        let count = Int(16_000 * seconds)
        let samples = (0..<count).map { index in silent ? Int16(0) : Int16(index % 2 == 0 ? 1200 : -1200) }
        try WAVAudio.pcm16(samples: samples).write(to: wav)
        let model = directory.appendingPathComponent("fixture-model.bin")
        try Data("not-a-real-model".utf8).write(to: model)
        return .init(audioURL: wav, modelURL: model, appName: "TextEdit", dictionary: .init("OpenRappter\n"))
    }
    private var forbiddenPolish: VoicePipeline.Polish {
        { _, _, _ in XCTFail("Polish must not run"); throw VoiceError.invalidAction("forbidden") }
    }
    private func approvePolish(_ input: inout DictationRequest, provider: String = "Local fixture") throws -> URL {
        let hook = directory.appendingPathComponent("polish-hook")
        try Data("#!/bin/sh\ncat \"$1\"\n".utf8).write(to: hook)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hook.path)
        input.settings.polish.provider = provider
        input.settings.polish.hookPath = hook.path
        try input.settings.polish.approve()
        return hook
    }
    func testLocalPipelineForwardsWeightedPrompt() async throws {
        let input = try request()
        let result = try await VoicePipeline.run(input, transcribe: { _, _, language, prompt in
            XCTAssertEqual(prompt, "OpenRappter. OpenRappter.")
            XCTAssertEqual(language, "en")
            return "um hello openrappter"
        }, polish: forbiddenPolish)
        XCTAssertEqual(result.text, "Hello OpenRappter.")
        XCTAssertEqual(result.cleanup, .localOnly)
    }
    func testShortClipAndDigitalSilenceNeverInvokeASR() async throws {
        for (seconds, silent, reason) in [(0.1, false, "too_short"), (0.5, true, "digital_silence")] {
            let input = try request(seconds: seconds, silent: silent)
            let result = try await VoicePipeline.run(input, transcribe: { _, _, _, _ in
                XCTFail("Silent audio must not be transcribed"); return "hallucination"
            }, polish: forbiddenPolish)
            XCTAssertEqual(result.text, "")
            XCTAssertEqual(result.silenceReason, reason)
        }
    }
    func testPunctuationAndAnnotationsReturnNoSpeech() async throws {
        let result = try await VoicePipeline.run(try request(), transcribe: { _, _, _, _ in "[BLANK_AUDIO] *noise*" }, polish: forbiddenPolish)
        XCTAssertEqual(result.silenceReason, "no_speech")
        XCTAssertEqual(result.text, "")
    }
    func testMissingModelAndMalformedWAVFailBeforeASR() async throws {
        var input = try request()
        input.modelURL = directory.appendingPathComponent("absent.bin")
        do {
            _ = try await VoicePipeline.run(input, transcribe: { _, _, _, _ in XCTFail("No ASR expected"); return "" }, polish: forbiddenPolish)
            XCTFail("Missing model must fail")
        } catch { XCTAssertEqual(error as? VoiceError, .modelMissing) }
        input = try request()
        try Data("not a wav".utf8).write(to: input.audioURL)
        do {
            _ = try await VoicePipeline.run(input, transcribe: { _, _, _, _ in XCTFail("No ASR expected"); return "" }, polish: forbiddenPolish)
            XCTFail("Invalid WAV must fail")
        } catch { XCTAssertTrue(error is VoiceError) }
    }
    func testWAVChunkParsingAndDuration() throws {
        let wav = WAVAudio.pcm16(samples: Array(repeating: 100, count: 8000))
        let parsed = try WAVAudio(data: wav)
        XCTAssertEqual(parsed.duration, 0.5)
        XCTAssertGreaterThan(parsed.peak, 0)
        XCTAssertEqual(parsed.sampleCount, 8000)
        XCTAssertThrowsError(try WAVAudio(data: wav.dropLast()))
        var invalid = wav
        invalid[22] = 2
        XCTAssertThrowsError(try WAVAudio(data: invalid))
    }
    func testPolishIsOffByDefaultEvenWithTriggerAndKnownHook() async throws {
        var input = try request()
        input.settings.polish.provider = "Anthropic"
        input.settings.polish.hookPath = "/reviewed/hook"
        let result = try await VoicePipeline.run(input, transcribe: { _, _, _, _ in "polish um hello" }, polish: forbiddenPolish)
        XCTAssertEqual(result.text, "Polish hello.")
        XCTAssertEqual(result.cleanup, .localOnly)
    }
    func testPolishRequiresCurrentConsentAndTrigger() async throws {
        var input = try request()
        _ = try approvePolish(&input)
        let result = try await VoicePipeline.run(input, transcribe: { _, _, _, _ in "Polish, hello" }, polish: { text, _, _ in
            XCTAssertEqual(text, "hello"); return "hello, cleaned"
        })
        XCTAssertEqual(result.text, "Hello, cleaned.")
        XCTAssertEqual(result.cleanup, .polished(provider: "Local fixture"))
        input.settings.polish.provider = "Changed recipient"
        XCTAssertFalse(input.settings.polish.hasConsent)
        _ = try await VoicePipeline.run(input, transcribe: { _, _, _, _ in "polish hello" }, polish: forbiddenPolish)
    }
    func testPolishFailurePreservesUsefulLocalText() async throws {
        var input = try request()
        _ = try approvePolish(&input, provider: "Fixture")
        let result = try await VoicePipeline.run(input, transcribe: { _, _, _, _ in "polish um hello openrappter" },
                                                polish: { _, _, _ in throw VoiceError.invalidAction("fixture failure") })
        XCTAssertEqual(result.text, "Hello OpenRappter.")
        guard case .localFallback = result.cleanup else { return XCTFail("Must accurately label local fallback") }
    }
    func testTranscriptionTimeoutAndCancellationNeverReturnSuccess() async throws {
        var input = try request()
        input.settings.transcriptionTimeout = 0.005
        do {
            _ = try await VoicePipeline.run(input, transcribe: { _, _, _, _ in
                try await Task.sleep(nanoseconds: 1_000_000_000); return "late"
            }, polish: forbiddenPolish)
            XCTFail("Expected timeout")
        } catch { XCTAssertEqual(error as? VoiceError, .timeout("Transcription")) }
        input.settings.transcriptionTimeout = 30
        do {
            _ = try await VoicePipeline.run(input, transcribe: { _, _, _, _ in throw CancellationError() }, polish: forbiddenPolish)
            XCTFail("Expected cancellation")
        } catch { XCTAssertTrue(error is CancellationError) }
    }
    func testCancellationDuringPolishDoesNotInsertLocalFallback() async throws {
        var input = try request()
        _ = try approvePolish(&input, provider: "Fixture")
        do {
            _ = try await VoicePipeline.run(input, transcribe: { _, _, _, _ in "polish hello" },
                                           polish: { _, _, _ in throw CancellationError() })
            XCTFail("Expected cancellation")
        } catch { XCTAssertTrue(error is CancellationError) }
    }
    func testDictionarySaveDetectsExternalEditsAndPreservesOtherLines() throws {
        let file = DictionaryFile(url: directory.appendingPathComponent("dictionary.txt"))
        XCTAssertEqual(try file.read(), "")
        try file.append("OpenRappter")
        let original = try file.read()
        try file.append("GPT-4")
        XCTAssertThrowsError(try file.save("lost entries", expecting: original))
        XCTAssertEqual(try file.read(), "OpenRappter\nGPT-4\n")
        XCTAssertFalse(try file.append("OpenRappter"))
        XCTAssertThrowsError(try file.append("line one\nline two"))
        XCTAssertThrowsError(try file.save("bad\0data", expecting: try file.read()))
    }
    func testActionDecoderIsTypedBoundedAndDoesNotEvaluatePayloads() throws {
        let text = #""; os.execute('no'); [==]"#
        let data = try JSONSerialization.data(withJSONObject: ["action": "process", "text": text])
        XCTAssertEqual(try NativeRequest.decode(data).text, text)
        XCTAssertThrowsError(try NativeRequest.decode(Data(#"{"action":"record"}"#.utf8)))
        XCTAssertThrowsError(try NativeRequest.decode(Data(#"{"action":"doctor","shell":"no"}"#.utf8)))
        XCTAssertThrowsError(try NativeRequest.decode(Data(repeating: 65, count: 65_537)))
    }
    func testSettingsRoundTripDoesNotActivatePolishOrOverwriteLegacy() throws {
        let file = SettingsFile(url: directory.appendingPathComponent("settings.json"))
        XCTAssertFalse(try file.read().polish.hasConsent)
        var settings = VoiceSettings()
        settings.shortcut = .rightOption
        try file.save(settings)
        XCTAssertEqual(try file.read(), settings)
        settings.maxRecordSeconds = .infinity
        XCTAssertThrowsError(try file.save(settings))
        XCTAssertEqual(try file.read().maxRecordSeconds, 600)

        settings = VoiceSettings()
        settings.polish.enabled = true
        settings.polish.provider = "Fixture"
        settings.polish.hookPath = "/missing"
        settings.polish.approvedProvider = "Fixture"
        settings.polish.approvedHookPath = "/missing"
        settings.polish.approvedFingerprint = "corrupt"
        try file.save(settings)
        XCTAssertFalse(try file.read().polish.hasConsent)
    }
    func testPolishTimeoutReturnsLabeledLocalText() async throws {
        var input = try request()
        _ = try approvePolish(&input, provider: "Fixture")
        input.settings.polishTimeout = 0.005
        let result = try await VoicePipeline.run(input, transcribe: { _, _, _, _ in "polish um hello" },
                                                polish: { _, _, _ in
            try await Task.sleep(nanoseconds: 1_000_000_000)
            return "too late"
        })
        XCTAssertEqual(result.text, "Hello.")
        guard case .localFallback(let reason) = result.cleanup else { return XCTFail("Expected explicit local fallback") }
        XCTAssertTrue(reason.contains("timed out"))
    }
    func testPolishConsentIsBoundToExecutableBytes() throws {
        var input = try request()
        let hook = try approvePolish(&input)
        XCTAssertTrue(input.settings.polish.hasConsent)
        try Data("#!/bin/sh\nprintf changed\n".utf8).write(to: hook)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hook.path)
        XCTAssertFalse(input.settings.polish.hasConsent)
        try input.settings.polish.approve()
        XCTAssertTrue(input.settings.polish.hasConsent)
    }
}
