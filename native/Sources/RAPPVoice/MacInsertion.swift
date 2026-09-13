import AppKit
import ApplicationServices
import Carbon
import RAPPVoiceCore

@MainActor final class MacPasteboard: PasteboardAccess {
    private let pasteboard = NSPasteboard.general
    var changeCount: Int { pasteboard.changeCount }
    func snapshot() throws -> [PasteboardItem] {
        try (pasteboard.pasteboardItems ?? []).map { item in
            var values: [String: Data] = [:]
            for type in item.types {
                guard let data = item.data(forType: type) else { throw CocoaError(.fileReadUnknown) }
                values[type.rawValue] = data
            }
            return PasteboardItem(values)
        }
    }
    func write(_ items: [PasteboardItem]) throws -> Int {
        let objects = try items.map { item -> NSPasteboardItem in
            let object = NSPasteboardItem()
            for (type, data) in item.representations {
                guard object.setData(data, forType: .init(type)) else { throw CocoaError(.fileWriteUnknown) }
            }
            return object
        }
        let cleared = pasteboard.clearContents()
        guard objects.isEmpty || pasteboard.writeObjects(objects) else { throw PasteboardWriteFailure(ownedChangeCount: cleared) }
        return pasteboard.changeCount
    }
    func writeText(_ text: String) throws -> Int {
        try write([.init([NSPasteboard.PasteboardType.string.rawValue: Data(text.utf8)])])
    }
}

@MainActor final class MacInput: InputAccess {
    private var targetElement: AXUIElement?
    private var targetElementID: String?
    private weak var targetEditor: NSTextView?
    private var targetRange = NSRange(location: 0, length: 0)
    private(set) var targetAppName = ""
    private(set) var targetBundleID = ""

    func capture() -> FocusSnapshot {
        targetElement = nil
        targetElementID = nil
        targetEditor = nil
        let app = NSWorkspace.shared.frontmostApplication
        targetAppName = app?.localizedName ?? ""
        targetBundleID = app?.bundleIdentifier ?? ""
        return focus(assignTarget: true)
    }
    func context() -> InsertionContext {
        let flags = CGEventSource.flagsState(.combinedSessionState)
        let held = !flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift, .maskSecondaryFn]).isEmpty
        return .init(focus: focus(assignTarget: false), accessibility: AXIsProcessTrusted(),
                     postEvents: CGPreflightPostEventAccess(), secureInput: IsSecureEventInputEnabled(), modifiersPressed: held)
    }
    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
    private func focus(assignTarget: Bool) -> FocusSnapshot {
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        let own = pid == ProcessInfo.processInfo.processIdentifier
        if own, let editor = NSApp.keyWindow?.firstResponder as? NSTextView {
            let secure = editor.delegate is NSSecureTextField
            if assignTarget { targetEditor = editor; targetRange = editor.selectedRange() }
            let range = editor.selectedRange()
            return .init(processID: pid, elementID: String(describing: ObjectIdentifier(editor)),
                         selection: "\(range.location):\(range.length)", editable: editor.isEditable,
                         secure: secure, ownApp: true)
        }
        guard !own, pid > 0, AXIsProcessTrusted() else {
            return .init(processID: pid, elementID: nil, editable: false, ownApp: own)
        }
        let application = AXUIElementCreateApplication(pid)
        guard let value = attribute(application, kAXFocusedUIElementAttribute),
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return .init(processID: pid, elementID: nil, editable: false)
        }
        let element = value as! AXUIElement
        if assignTarget { targetElement = element; targetElementID = UUID().uuidString }
        let same = targetElement.map { CFEqual($0, element) } ?? false
        let role = attribute(element, kAXRoleAttribute) as? String ?? ""
        let subrole = attribute(element, kAXSubroleAttribute) as? String ?? ""
        let secure = subrole == "AXSecureTextField" || role.contains("Secure")
            || attribute(element, "AXProtectedContent") as? Bool == true
        let enabled = attribute(element, kAXEnabledAttribute) as? Bool == true
        var selectedRange: String?
        if !secure, let selection = attribute(element, kAXSelectedTextRangeAttribute),
           CFGetTypeID(selection) == AXValueGetTypeID() {
            let axValue = selection as! AXValue
            var range = CFRange()
            if AXValueGetType(axValue) == .cfRange, AXValueGetValue(axValue, .cfRange, &range) {
                selectedRange = "\(range.location):\(range.length)"
            }
        }
        let editable = enabled && selectedRange != nil && ["AXTextField", "AXTextArea", "AXComboBox"].contains(role)
        return .init(processID: pid, elementID: same ? targetElementID : nil, selection: selectedRange,
                     editable: editable, secure: secure)
    }
    func insertIntoOwnEditor(_ text: String) throws {
        guard let editor = targetEditor, NSApp.keyWindow?.firstResponder === editor,
              editor.isEditable, !(editor.delegate is NSSecureTextField),
              editor.selectedRange() == targetRange, !IsSecureEventInputEnabled() else {
            throw VoiceError.invalidAction("the editor focus changed")
        }
        let expected = (editor.string as NSString).replacingCharacters(in: targetRange, with: text)
        editor.insertText(text, replacementRange: targetRange)
        guard editor.string == expected else { throw VoiceError.invalidAction("the editor did not confirm insertion; review it before copying") }
    }
    private func events(key: CGKeyCode, text: String? = nil, flags: CGEventFlags = []) throws {
        guard AXIsProcessTrusted(), CGPreflightPostEventAccess(), !IsSecureEventInputEnabled(),
              let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) else {
            throw VoiceError.invalidAction("event permission is unavailable or Secure Input is active")
        }
        down.flags = flags; up.flags = flags
        if let text {
            let codeUnits = Array(text.utf16)
            guard codeUnits.count <= 20 else { throw VoiceError.invalidAction("use paste for this extended Unicode character") }
            codeUnits.withUnsafeBufferPointer { pointer in
                if let base = pointer.baseAddress {
                    down.keyboardSetUnicodeString(stringLength: codeUnits.count, unicodeString: base)
                    up.keyboardSetUnicodeString(stringLength: codeUnits.count, unicodeString: base)
                }
            }
        }
        for event in [down, up] {
            event.setIntegerValueField(.eventSourceUserData, value: ShortcutMonitor.syntheticEventTag)
            event.post(tap: .cgSessionEventTap)
        }
    }
    func postPaste() throws { try events(key: 9, flags: .maskCommand) }
    func postText(_ text: String) throws { try events(key: 0, text: text) }
}
