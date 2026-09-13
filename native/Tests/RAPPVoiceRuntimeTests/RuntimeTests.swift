import Foundation
import XCTest
import RAPPDesktopSupport
import RAPPVoiceCore
@testable import RAPPVoice

final class RuntimeTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        directory = root.appendingPathComponent(".build/runtime-tests/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }
    private func fixture() throws -> (audio: URL, model: URL) {
        let audio = directory.appendingPathComponent("synthetic PCM.wav")
        try WAVAudio.pcm16(samples: Array(repeating: 500, count: 8000)).write(to: audio)
        let model = directory.appendingPathComponent("fixture model.bin")
        try Data("fixture only, not a speech model".utf8).write(to: model)
        return (audio, model)
    }
    func testWeightedPromptIsPassedToTheSharedRunnerAsLiteralArguments() async throws {
        let fixture = try fixture()
        let prompt = "OpenRappter. OpenRappter. Literal \"$word\"; no commands."
        let executable = directory.appendingPathComponent("whisper-cli")
        let outputBase = directory.appendingPathComponent("dictionary-transcript")
        let dependencies = VoiceSpeechTranscriber.Dependencies(
            executable: { executable },
            run: { tool, arguments in
                XCTAssertEqual(tool, executable)
                XCTAssertEqual(arguments, [
                    "-m", fixture.model.path, "-f", fixture.audio.path, "-l", "en",
                    "-otxt", "-of", outputBase.path, "-nt", "--prompt", prompt,
                ])
                try "hello OpenRappter\n".write(to: outputBase.appendingPathExtension("txt"), atomically: true, encoding: .utf8)
            },
            unweighted: { _, _, _ in XCTFail("Weighted dictation cannot discard its prompt"); return "" }
        )
        let result = try await VoiceSpeechTranscriber.transcribe(audioURL: fixture.audio, modelURL: fixture.model,
                                                                language: "en", prompt: prompt, dependencies: dependencies)
        XCTAssertEqual(result, "hello OpenRappter")
    }
    func testUnweightedPathUsesTheSharedTranscriber() async throws {
        let fixture = try fixture()
        let dependencies = VoiceSpeechTranscriber.Dependencies(
            executable: { XCTFail("Unweighted ASR is shared"); throw DesktopSupportError.missingExecutable("fixture") },
            run: { _, _ in XCTFail("Unweighted ASR is shared") },
            unweighted: { audio, model, language in
                XCTAssertEqual(audio, fixture.audio); XCTAssertEqual(model, fixture.model); XCTAssertEqual(language, "en")
                return "local fixture result"
            }
        )
        let result = try await VoiceSpeechTranscriber.transcribe(audioURL: fixture.audio, modelURL: fixture.model,
                                                                language: "en", prompt: nil, dependencies: dependencies)
        XCTAssertEqual(result, "local fixture result")
    }
    func testASRFailurePropagatesInsteadOfReturningEmptySuccess() async throws {
        let fixture = try fixture()
        let executable = directory.appendingPathComponent("whisper-cli")
        let dependencies = VoiceSpeechTranscriber.Dependencies(
            executable: { executable },
            run: { _, _ in throw DesktopSupportError.processFailed("whisper-cli", 23, "fixture model failure") },
            unweighted: { _, _, _ in XCTFail("Wrong branch"); return "" }
        )
        do {
            _ = try await VoiceSpeechTranscriber.transcribe(audioURL: fixture.audio, modelURL: fixture.model,
                                                            language: "en", prompt: "Vocabulary.", dependencies: dependencies)
            XCTFail("Expected a process failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("23"))
            XCTAssertTrue(error.localizedDescription.contains("fixture model failure"))
        }
    }
    func testCancellationPropagatesToTheSharedRunnerOperation() async throws {
        let fixture = try fixture()
        let executable = directory.appendingPathComponent("whisper-cli")
        let dependencies = VoiceSpeechTranscriber.Dependencies(
            executable: { executable },
            run: { _, _ in try await Task.sleep(nanoseconds: 30_000_000_000) },
            unweighted: { _, _, _ in XCTFail("Wrong branch"); return "" }
        )
        let operation = Task {
            try await VoiceSpeechTranscriber.transcribe(audioURL: fixture.audio, modelURL: fixture.model,
                                                        language: "en", prompt: "Vocabulary.", dependencies: dependencies)
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        operation.cancel()
        do { _ = try await operation.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
}
