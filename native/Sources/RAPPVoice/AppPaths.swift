import Foundation
import RAPPDesktopSupport
import RAPPVoiceCore

struct AppPaths {
    let support: URL
    let legacy: URL
    var settings: SettingsFile { .init(url: support.appendingPathComponent("settings.json")) }
    var dictionary: DictionaryFile { .init(url: legacy.appendingPathComponent("dictionary.txt")) }
    var modelDirectory: URL { support.appendingPathComponent("Models", isDirectory: true) }
    var logURL: URL { support.appendingPathComponent("events.jsonl") }

    init() throws {
        let environment = ProcessInfo.processInfo.environment
        if let override = environment["RAPPVOICE_NATIVE_HOME"], !override.isEmpty {
            support = URL(fileURLWithPath: override, isDirectory: true)
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        } else {
            support = try ApplicationDirectories.support(bundleID: "io.rapp.voice")
        }
        legacy = URL(fileURLWithPath: environment["RAPPVOICE_HOME"]
                     ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".rappvoice").path,
                     isDirectory: true)
    }

    func createJob() throws -> URL {
        let job = support.appendingPathComponent("Work", isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: job, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        return job
    }
    func log(event: String, detail: String, characters: Int = 0) throws {
        // Keep timing/status, not transcripts or microphone content, in persistent diagnostics.
        let entry: [String: Any] = [
            "event": event, "detail": detail, "characters": characters,
            "ts": ISO8601DateFormatter().string(from: Date()), "engine": "native-whisper-cli",
        ]
        var data = try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys])
        data.append(10)
        if !FileManager.default.fileExists(atPath: logURL.path) {
            guard FileManager.default.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let file = try FileHandle(forWritingTo: logURL)
        defer { try? file.close() }
        try file.seekToEnd()
        try file.write(contentsOf: data)
    }
}
