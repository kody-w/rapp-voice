import Foundation

public struct FocusSnapshot: Equatable, Sendable {
    public var processID: Int32
    public var elementID: String?
    public var selection: String?
    public var editable: Bool
    public var secure: Bool
    public var ownApp: Bool
    public init(processID: Int32, elementID: String?, selection: String? = nil,
                editable: Bool, secure: Bool = false, ownApp: Bool = false) {
        self.processID = processID; self.elementID = elementID; self.selection = selection
        self.editable = editable; self.secure = secure; self.ownApp = ownApp
    }
    public func selectionAfterInserting(_ text: String) -> String? {
        guard let selection else { return nil }
        let values = selection.split(separator: ":").compactMap { Int($0) }
        let length = text.utf16.count
        guard values.count == 2, values[0] >= 0, values[1] >= 0, values[0] <= Int.max - length else { return nil }
        return "\(values[0] + length):0"
    }
}

public struct InsertionContext: Equatable, Sendable {
    public var focus: FocusSnapshot
    public var accessibility: Bool
    public var postEvents: Bool
    public var secureInput: Bool
    public var modifiersPressed: Bool
    public init(focus: FocusSnapshot, accessibility: Bool, postEvents: Bool, secureInput: Bool = false, modifiersPressed: Bool = false) {
        self.focus = focus; self.accessibility = accessibility; self.postEvents = postEvents; self.secureInput = secureInput
        self.modifiersPressed = modifiersPressed
    }
}

public enum ManualReason: String, Equatable, Sendable {
    case requested = "Manual insertion is selected."
    case permission = "Accessibility / event permission is unavailable."
    case protectedInput = "Secure input or a protected field is active. Automatic input is disabled."
    case focusChanged = "The target application, field, or selection changed."
    case unknownField = "The target is not a verifiable editable text field."
    case clipboardChanged = "The clipboard changed before the paste. Your newer clipboard was preserved."
    case clipboardUnavailable = "The complete clipboard could not be preserved."
    case eventFailed = "Keyboard event delivery could not be started."
    case modifiersPressed = "A modifier key is still held. Release it before pasting manually."
    case unconfirmedInput = "The target did not acknowledge the expected caret change."
}

public enum InsertionPolicy {
    public static func restriction(target: FocusSnapshot, current: InsertionContext, method: InsertMethod,
                                   checkSelection: Bool = true) -> ManualReason? {
        if method == .manual { return .requested }
        if target.secure || current.focus.secure || current.secureInput { return .protectedInput }
        if current.modifiersPressed { return .modifiersPressed }
        let ownEditor = target.ownApp && current.focus.ownApp
        if !ownEditor, !current.accessibility || !current.postEvents { return .permission }
        guard target.editable, current.focus.editable, let identity = target.elementID else { return .unknownField }
        guard target.processID == current.focus.processID,
              identity == current.focus.elementID,
              !checkSelection || target.selection == current.focus.selection else { return .focusChanged }
        return nil
    }
    public static func shouldRestore(ownedChangeCount: Int, currentChangeCount: Int) -> Bool {
        ownedChangeCount == currentChangeCount
    }
}

public struct PasteboardItem: Equatable, Sendable {
    public var representations: [String: Data]
    public init(_ representations: [String: Data]) { self.representations = representations }
}

public struct PasteboardWriteFailure: LocalizedError, Sendable {
    public let ownedChangeCount: Int
    public init(ownedChangeCount: Int) { self.ownedChangeCount = ownedChangeCount }
    public var errorDescription: String? { "The pasteboard rejected replacement data." }
}

@MainActor public protocol PasteboardAccess {
    var changeCount: Int { get }
    func snapshot() throws -> [PasteboardItem]
    @discardableResult func write(_ items: [PasteboardItem]) throws -> Int
    @discardableResult func writeText(_ text: String) throws -> Int
}

@MainActor public protocol InputAccess {
    func context() -> InsertionContext
    func postPaste() throws
    func postText(_ text: String) throws
    func insertIntoOwnEditor(_ text: String) throws
}

public enum InsertionOutcome: Equatable, Sendable {
    case ownEditor
    case pasteShortcutSent
    case typingSent(characters: Int)
    case manual(ManualReason)
    case partialTyping(characters: Int, reason: ManualReason)
    public var label: String {
        switch self {
        case .ownEditor: return "Inserted into the RAPP Voice editor."
        case .pasteShortcutSent: return "Paste shortcut sent; target delivery is not confirmed."
        case .typingSent(let count): return "Typing events sent (\(count) characters); delivery is not confirmed."
        case .manual(let reason): return "Not inserted. \(reason.rawValue) Copy, then paste manually when safe."
        case .partialTyping(let count, let reason):
            return "Typing stopped after \(count) characters. \(reason.rawValue) Review the target before copying."
        }
    }
}

@MainActor public final class InsertionEngine {
    public typealias Sleep = @Sendable (Double) async throws -> Void
    private let pasteboard: any PasteboardAccess
    private let input: any InputAccess
    private let sleep: Sleep
    public private(set) var eventWasSent = false
    public private(set) var restorationError: String?

    public init(pasteboard: any PasteboardAccess, input: any InputAccess,
                sleep: @escaping Sleep = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }) {
        self.pasteboard = pasteboard; self.input = input; self.sleep = sleep
    }
    public func insert(_ text: String, target: FocusSnapshot, settings: VoiceSettings) async throws -> InsertionOutcome {
        eventWasSent = false
        restorationError = nil
        try Task.checkCancellation()
        if let reason = InsertionPolicy.restriction(target: target, current: input.context(), method: settings.insertMethod) {
            return .manual(reason)
        }
        if target.ownApp {
            try input.insertIntoOwnEditor(text)
            eventWasSent = true
            return .ownEditor
        }
        if settings.insertMethod == .type {
            var count = 0
            var expectedTarget = target
            for character in text {
                try Task.checkCancellation()
                if let reason = InsertionPolicy.restriction(target: expectedTarget, current: input.context(), method: .type) {
                    return count == 0 ? .manual(reason) : .partialTyping(characters: count, reason: reason)
                }
                guard let nextSelection = expectedTarget.selectionAfterInserting(String(character)) else {
                    return count == 0 ? .manual(.unknownField) : .partialTyping(characters: count, reason: .unknownField)
                }
                do {
                    try input.postText(String(character))
                } catch {
                    return count == 0 ? .manual(.eventFailed) : .partialTyping(characters: count, reason: .eventFailed)
                }
                eventWasSent = true
                count += 1
                try await sleep(0.002)
                var acknowledged = false
                for attempt in 0..<10 {
                    try Task.checkCancellation()
                    let current = input.context()
                    if let reason = InsertionPolicy.restriction(target: expectedTarget, current: current, method: .type,
                                                               checkSelection: false) {
                        return .partialTyping(characters: count, reason: reason)
                    }
                    if current.focus.selection == nextSelection {
                        expectedTarget.selection = nextSelection
                        acknowledged = true
                        break
                    }
                    if current.focus.selection != expectedTarget.selection {
                        return .partialTyping(characters: count, reason: .focusChanged)
                    }
                    if attempt < 9 { try await sleep(0.01) }
                }
                if !acknowledged { return .partialTyping(characters: count, reason: .unconfirmedInput) }
            }
            return .typingSent(characters: count)
        }
        let initialCount = pasteboard.changeCount
        let original: [PasteboardItem]
        do { original = try pasteboard.snapshot() } catch { return .manual(.clipboardUnavailable) }
        guard pasteboard.changeCount == initialCount else { return .manual(.clipboardChanged) }
        let owned: Int
        do {
            owned = try pasteboard.writeText(text)
        } catch let failure as PasteboardWriteFailure {
            if pasteboard.changeCount == failure.ownedChangeCount {
                do { try pasteboard.write(original) } catch { restorationError = error.localizedDescription }
            }
            return .manual(.clipboardUnavailable)
        }
        defer {
            if InsertionPolicy.shouldRestore(ownedChangeCount: owned, currentChangeCount: pasteboard.changeCount) {
                do { try pasteboard.write(original) } catch { restorationError = error.localizedDescription }
            }
        }
        try await sleep(settings.pasteDelay)
        try Task.checkCancellation()
        guard pasteboard.changeCount == owned else { return .manual(.clipboardChanged) }
        if let reason = InsertionPolicy.restriction(target: target, current: input.context(), method: .paste) {
            return .manual(reason)
        }
        do { try input.postPaste() } catch { return .manual(.eventFailed) }
        eventWasSent = true
        try await sleep(settings.clipboardRestoreDelay)
        return .pasteShortcutSent
    }
}
