import Foundation

public enum NativeAction: String, Codable, CaseIterable, Sendable {
    case doctor, dictionary, add_term, stats, process
}

public struct NativeRequest: Decodable, Sendable {
    public let action: NativeAction
    public let text: String?
    public let app: String?
    public let term: String?
    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= 65_536 else { throw VoiceError.invalidAction("request exceeds 64 KiB") }
        let object = try JSONSerialization.jsonObject(with: data)
        guard let fields = object as? [String: Any],
              Set(fields.keys).isSubset(of: ["action", "text", "app", "term"]) else {
            throw VoiceError.invalidAction("expected action, with optional text, app, or term")
        }
        return try JSONDecoder().decode(Self.self, from: data)
    }
}

public struct NativeResponse: Encodable, Sendable {
    public let ok: Bool
    public let runtime = "native"
    public let version = "1.1.0"
    public let action: String
    public let text: String
    public init(ok: Bool, action: String, text: String) {
        self.ok = ok; self.action = action; self.text = text
    }
}

public struct SettingsFile: Sendable {
    public let url: URL
    public init(url: URL) { self.url = url }
    public func read() throws -> VoiceSettings {
        guard FileManager.default.fileExists(atPath: url.path) else { return .init() }
        return try JSONDecoder().decode(VoiceSettings.self, from: Data(contentsOf: url)).validated()
    }
    public func save(_ settings: VoiceSettings) throws {
        _ = try settings.validated()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(settings).write(to: url, options: .atomic)
    }
}
