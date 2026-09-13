import CryptoKit
import Foundation

public enum VoiceShortcut: String, CaseIterable, Codable, Sendable, Identifiable {
    case rightCmd, leftCmd, rightOption, leftOption, rightShift, leftShift, fn
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .rightCmd: return "Right ⌘"
        case .leftCmd: return "Left ⌘"
        case .rightOption: return "Right ⌥"
        case .leftOption: return "Left ⌥"
        case .rightShift: return "Right ⇧"
        case .leftShift: return "Left ⇧"
        case .fn: return "Fn / Globe"
        }
    }
    public var keyCode: Int64 {
        switch self {
        case .rightCmd: return 54
        case .leftCmd: return 55
        case .rightOption: return 61
        case .leftOption: return 58
        case .rightShift: return 60
        case .leftShift: return 56
        case .fn: return 63
        }
    }
    public var deviceMask: UInt64 {
        switch self {
        case .rightCmd: return 0x10
        case .leftCmd: return 0x08
        case .rightOption: return 0x40
        case .leftOption: return 0x20
        case .rightShift: return 0x04
        case .leftShift: return 0x02
        case .fn: return 0x00800000
        }
    }
    public var oppositeMask: UInt64 {
        switch self {
        case .rightCmd: return Self.leftCmd.deviceMask
        case .leftCmd: return Self.rightCmd.deviceMask
        case .rightOption: return Self.leftOption.deviceMask
        case .leftOption: return Self.rightOption.deviceMask
        case .rightShift: return Self.leftShift.deviceMask
        case .leftShift: return Self.rightShift.deviceMask
        case .fn: return 0
        }
    }
    public var aggregateMask: UInt64 {
        switch self {
        case .rightCmd, .leftCmd: return 0x00100000
        case .rightOption, .leftOption: return 0x00080000
        case .rightShift, .leftShift: return 0x00020000
        case .fn: return 0x00800000
        }
    }
    public func removingReservedModifier(from flags: UInt64) -> UInt64 {
        var cleaned = flags & ~deviceMask
        if oppositeMask == 0 || flags & oppositeMask == 0 { cleaned &= ~aggregateMask }
        return cleaned
    }
}

public enum InsertMethod: String, Codable, CaseIterable, Sendable, Identifiable {
    case paste, type, manual
    public var id: String { rawValue }
}

public struct PolishSettings: Codable, Equatable, Sendable {
    public var enabled = false
    public var provider = ""
    public var hookPath = ""
    public var approvedProvider: String?
    public var approvedHookPath: String?
    public var approvedFingerprint: String?
    public init() {}
    public var hasConsent: Bool {
        guard enabled, !provider.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              hookPath.hasPrefix("/"), provider == approvedProvider,
              normalizedHookPath == approvedHookPath, let approvedFingerprint else { return false }
        return (try? fingerprint()) == approvedFingerprint
    }
    private var normalizedHookPath: String {
        URL(fileURLWithPath: hookPath).standardizedFileURL.path
    }
    public func fingerprint() throws -> String {
        let executable = URL(fileURLWithPath: normalizedHookPath)
        guard FileManager.default.isExecutableFile(atPath: executable.path),
              (try executable.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else {
            throw VoiceError.invalidAction("the selected polish hook is not an executable regular file")
        }
        var hash = SHA256()
        hash.update(data: Data("\(provider)\n\(executable.path)\n".utf8))
        let handle = try FileHandle(forReadingFrom: executable)
        defer { try? handle.close() }
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            hash.update(data: chunk)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    public mutating func revoke() {
        enabled = false
        approvedProvider = nil
        approvedHookPath = nil
        approvedFingerprint = nil
    }
    public mutating func approve() throws {
        let fingerprint = try fingerprint()
        approvedProvider = provider
        approvedHookPath = normalizedHookPath
        approvedFingerprint = fingerprint
        enabled = true
    }
}

public struct VoiceSettings: Codable, Equatable, Sendable {
    public var shortcut = VoiceShortcut.rightCmd
    public var shortcutEnabled = true
    public var modelID = "small.en"
    public var language = "en"
    public var insertMethod = InsertMethod.paste
    public var minRecordSeconds = 0.35
    public var maxRecordSeconds = 600.0
    public var tapMaxSeconds = 0.25
    public var doubleTapSeconds = 0.35
    public var transcriptionTimeout = 120.0
    public var polishTimeout = 60.0
    public var pasteDelay = 0.05
    public var clipboardRestoreDelay = 0.25
    public var polishTrigger = "polish"
    public var polish = PolishSettings()
    public var fillers = ["um", "uh", "uhm", "erm", "hmm", "mhm", "you know"]
    public var rawApps = [
        "Terminal", "iTerm2", "Ghostty", "Code", "Cursor", "Alacritty", "kitty", "WezTerm", "Warp",
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty",
        "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92",
    ]
    public init() {}
    public func validated() throws -> Self {
        guard minRecordSeconds.isFinite, (0.1...5).contains(minRecordSeconds),
              maxRecordSeconds.isFinite, (1...600).contains(maxRecordSeconds),
              minRecordSeconds < maxRecordSeconds,
              tapMaxSeconds.isFinite, (0.05...1).contains(tapMaxSeconds),
              doubleTapSeconds.isFinite, (0.1...1).contains(doubleTapSeconds),
              transcriptionTimeout.isFinite, (1...600).contains(transcriptionTimeout),
              polishTimeout.isFinite, (1...120).contains(polishTimeout),
              pasteDelay.isFinite, (0...2).contains(pasteDelay),
              clipboardRestoreDelay.isFinite, (0.1...5).contains(clipboardRestoreDelay),
              language.range(of: "^[a-z]{2,3}$|^auto$", options: .regularExpression) != nil,
              !polishTrigger.isEmpty, !polishTrigger.contains("\0")
        else { throw VoiceError.invalidSettings }
        return self
    }
}

public enum VoiceError: LocalizedError, Equatable {
    case invalidSettings, microphoneDenied, microphoneUndetermined, modelMissing, runtimeMissing
    case invalidWAV(String), recordingFailed(String), timeout(String), invalidAction(String)
    public var errorDescription: String? {
        switch self {
        case .invalidSettings: return "Invalid settings. Recording must be bounded to 600 seconds; check timing values."
        case .microphoneDenied: return "Microphone access is denied. Enable RAPP Voice in System Settings."
        case .microphoneUndetermined: return "Enable Microphone in Setup first, then start a new dictation."
        case .modelMissing: return "Download a speech model in Setup before recording."
        case .runtimeMissing: return "Bundled whisper-cli is missing. Reinstall the complete native application."
        case .invalidWAV(let detail): return "Unsupported recording: \(detail)"
        case .recordingFailed(let detail): return "Recording failed: \(detail)"
        case .timeout(let stage): return "\(stage) timed out. Try a shorter dictation."
        case .invalidAction(let detail): return "Invalid action: \(detail)"
        }
    }
}

public enum MicrophonePermission: String, Sendable { case undetermined, denied, authorized }

public enum CaptureReadiness {
    public static func check(microphone: MicrophonePermission, modelInstalled: Bool, runtimeAvailable: Bool) throws {
        switch microphone {
        case .denied: throw VoiceError.microphoneDenied
        case .undetermined: throw VoiceError.microphoneUndetermined
        case .authorized: break
        }
        guard modelInstalled else { throw VoiceError.modelMissing }
        guard runtimeAvailable else { throw VoiceError.runtimeMissing }
    }
}
