import Foundation

public struct ShortcutFilter: Sendable {
    public enum Kind: Sendable { case flagsChanged, keyDown, keyUp }
    public enum Action: Equatable, Sendable { case press, release, cancel }
    public struct Result: Equatable, Sendable {
        public let consumed: Bool
        public let flags: UInt64
        public let action: Action?
    }
    public var shortcut: VoiceShortcut
    public var busy = false
    private var pressed: Bool
    private var suppressEscapeUp = false
    public init(shortcut: VoiceShortcut, alreadyPressed: Bool = false) {
        self.shortcut = shortcut
        pressed = alreadyPressed
    }
    public mutating func handle(kind: Kind, keyCode: Int64, flags: UInt64, synthetic: Bool = false) -> Result {
        if synthetic { return .init(consumed: false, flags: flags, action: nil) }
        if kind == .flagsChanged, keyCode == shortcut.keyCode {
            let down = flags & shortcut.deviceMask != 0
            let action: Action? = down == pressed ? nil : (down ? .press : .release)
            pressed = down
            return .init(consumed: true, flags: flags, action: action)
        }
        if keyCode == 53 {
            if kind == .keyDown, busy || pressed {
                suppressEscapeUp = true
                return .init(consumed: true, flags: flags, action: .cancel)
            }
            if kind == .keyUp, suppressEscapeUp {
                suppressEscapeUp = false
                return .init(consumed: true, flags: flags, action: nil)
            }
        }
        let cleaned = pressed || flags & shortcut.deviceMask != 0
            ? shortcut.removingReservedModifier(from: flags) : flags
        return .init(consumed: false, flags: cleaned, action: nil)
    }
}
