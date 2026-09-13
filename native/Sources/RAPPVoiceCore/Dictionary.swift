import Foundation

public struct VoiceDictionary: Equatable, Sendable {
    public struct Rewrite: Equatable, Sendable {
        public let from: String
        public let to: String
    }
    public var terms: [String] = []
    public var rewrites: [Rewrite] = []
    public init(_ text: String = "") {
        for line in text.components(separatedBy: .newlines) {
            let term = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty, !term.hasPrefix("#") else { continue }
            if let range = term.range(of: "=>") {
                let from = term[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
                let to = term[range.upperBound...].trimmingCharacters(in: .whitespaces)
                if !from.isEmpty && !to.isEmpty {
                    rewrites.append(.init(from: from, to: to))
                    terms.append(to)
                    continue
                }
            }
            terms.append(term)
        }
    }
    public var weightedPrompt: String? {
        var seen = Set<String>()
        let parts = terms.filter { seen.insert($0).inserted }.map { "\($0). \($0)." }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}

public struct DictionaryFile: Sendable {
    public let url: URL
    public init(url: URL) { self.url = url }
    public func read() throws -> String {
        guard FileManager.default.fileExists(atPath: url.path) else { return "" }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 65_536 else { throw VoiceError.invalidAction("The dictionary exceeds the native 64 KiB limit.") }
        let text = try String(contentsOf: url, encoding: .utf8)
        try validate(text)
        return text
    }
    public func save(_ text: String, expecting original: String) throws {
        try validate(text)
        guard try read() == original else {
            throw VoiceError.invalidAction("The dictionary changed outside this window. Reload before saving; no entries were overwritten.")
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
    private func validate(_ text: String) throws {
        guard text.utf8.count <= 65_536, !text.contains("\0") else {
            throw VoiceError.invalidAction("The dictionary must be at most 64 KiB and contain no NUL characters.")
        }
    }
    @discardableResult public func append(_ term: String) throws -> Bool {
        let line = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty, !term.contains("\n"), !term.contains("\r"),
              !term.contains("\0"), line.utf8.count <= 2048 else {
            throw VoiceError.invalidAction("add_term needs a single nonempty vocabulary line (maximum 2048 bytes).")
        }
        let old = try read()
        if old.components(separatedBy: .newlines).map({ $0.trimmingCharacters(in: .whitespaces) }).contains(line) {
            return false
        }
        let separator = old.isEmpty || old.hasSuffix("\n") ? "" : "\n"
        try save(old + separator + line + "\n", expecting: old)
        return true
    }
}
