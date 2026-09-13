import Foundation
import RAPPDesktopSupport

enum VoiceSpeechTranscriber {
    struct Dependencies: Sendable {
        var executable: @Sendable () throws -> URL
        var run: @Sendable (URL, [String]) async throws -> Void
        var unweighted: @Sendable (URL, URL, String) async throws -> String
        static let live = Dependencies(
            executable: { try RuntimeTools.executable(named: "whisper-cli") },
            run: { executable, arguments in _ = try await ProcessRunner.run(executable: executable, arguments: arguments) },
            unweighted: { audio, model, language in
                try await SpeechTranscriber.transcribe(audioURL: audio, modelURL: model, language: language)
            }
        )
    }
    static func transcribe(audioURL: URL, modelURL: URL, language: String, prompt: String?,
                           dependencies: Dependencies = .live) async throws -> String {
        guard let prompt, !prompt.isEmpty else {
            return try await dependencies.unweighted(audioURL, modelURL, language)
        }
        // The shared three-argument SpeechTranscriber has no decoding-prompt input.
        // Keep dictionary weighting on the same bundled engine and shared process
        // runner, without implementing another launcher, transport, or checksum.
        let executable = try dependencies.executable()
        let outputBase = audioURL.deletingLastPathComponent().appendingPathComponent("dictionary-transcript")
        try await dependencies.run(executable, [
            "-m", modelURL.path, "-f", audioURL.path, "-l", language,
            "-otxt", "-of", outputBase.path, "-nt", "--prompt", prompt,
        ])
        try Task.checkCancellation()
        let output = outputBase.appendingPathExtension("txt")
        let size = try output.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 4 * 1024 * 1024 else { throw DesktopSupportError.outputTooLarge }
        let text = try String(contentsOf: output, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw DesktopSupportError.noSpeech }
        return text
    }
}
