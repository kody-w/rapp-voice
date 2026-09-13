import Foundation

public enum TextProcessor {
    private static func replace(_ text: String, _ pattern: String, _ replacement: String) -> String {
        text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
    }
    private static func bounded(_ phrase: String) -> String {
        let literal = phrase.components(separatedBy: " ").map(NSRegularExpression.escapedPattern(for:)).joined(separator: "\\s+")
        let word = CharacterSet.alphanumerics
        let firstIsWord = phrase.unicodeScalars.first.map(word.contains) ?? false
        let lastIsWord = phrase.unicodeScalars.last.map(word.contains) ?? false
        return "(?i)" + (firstIsWord ? "(?<![\\p{L}\\p{N}])" : "") + literal
            + (lastIsWord ? "(?![\\p{L}\\p{N}])" : "")
    }
    private static func literalReplace(_ text: String, phrase: String, with replacement: String) -> String {
        guard !phrase.isEmpty else { return text }
        return replace(text, bounded(phrase), NSRegularExpression.escapedTemplate(for: replacement))
    }
    public static func isRawApp(name: String, bundleID: String, settings: VoiceSettings = .init()) -> Bool {
        settings.rawApps.contains(name) || settings.rawApps.contains(bundleID)
    }
    public static func process(_ raw: String, rawMode: Bool, dictionary: VoiceDictionary = .init(),
                               settings: VoiceSettings = .init()) -> String {
        var text = replace(raw, "\\[[^\\]]*\\]", " ")
        text = replace(text, "\\*[^*]*\\*", " ").trimmingCharacters(in: .whitespacesAndNewlines)
        if isWholeParenthetical(text) { text = "" }
        for filler in settings.fillers { text = literalReplace(text, phrase: filler, with: "") }
        text = replace(text, "\\s+", " ")
        text = replace(text, "\\s+([,.!?;:])", "$1")
        for _ in 0..<3 { text = replace(text, "([,;:])\\s*[,;:]", "$1") }
        text = replace(text, "^[\\s,;:.\\-]+", "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.rangeOfCharacter(from: .alphanumerics) != nil else { return "" }
        for rewrite in dictionary.rewrites.sorted(by: { $0.from.utf8.count > $1.from.utf8.count }) {
            text = literalReplace(text, phrase: rewrite.from, with: rewrite.to)
        }
        if rawMode {
            text = replace(text, "[.!?]+$", "")
            if let range = text.range(of: "^[\\p{L}]+", options: .regularExpression) {
                let first = String(text[range])
                if first.dropFirst() == first.dropFirst().lowercased(), let letter = text.first {
                    text.replaceSubrange(text.startIndex...text.startIndex, with: String(letter).lowercased())
                }
            }
        }
        for term in dictionary.terms { text = literalReplace(text, phrase: term, with: term) }
        if !rawMode {
            let regex = try? NSRegularExpression(pattern: "(^|[.!?]\\s+)([\\p{L}])")
            let matches = regex?.matches(in: text, range: NSRange(text.startIndex..., in: text)) ?? []
            for match in matches.reversed() {
                if let range = Range(match.range(at: 2), in: text) {
                    text.replaceSubrange(range, with: text[range].uppercased())
                }
            }
            if text.range(of: "[\\p{L}\\p{N})\"']$", options: .regularExpression) != nil { text += "." }
        }
        return text
    }
    public static func polishRemainder(_ raw: String, trigger: String) -> String? {
        guard !trigger.isEmpty else { return nil }
        let pattern = "^\\s*" + bounded(trigger) + "[\\s,.:;!\\-]*"
        guard let range = raw.range(of: pattern, options: .regularExpression) else { return nil }
        return String(raw[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private static func isWholeParenthetical(_ text: String) -> Bool {
        guard text.first == "(", text.last == ")" else { return false }
        var depth = 0
        for (index, character) in text.enumerated() {
            if character == "(" { depth += 1 }
            if character == ")" { depth -= 1 }
            if depth == 0 && index != text.count - 1 { return false }
            if depth < 0 { return false }
        }
        return depth == 0
    }
}
