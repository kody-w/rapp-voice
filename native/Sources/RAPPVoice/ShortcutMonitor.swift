import AppKit
import Carbon
import RAPPVoiceCore

@MainActor final class ShortcutMonitor {
    private var session: EventTapSession?
    private var local: Any?
    private var localFilter = ShortcutFilter(shortcut: .rightCmd)
    private var generation = UUID()
    var onPress: ((Double) -> Void)?
    var onRelease: ((Double) -> Void)?
    var onCancel: ((String) -> Void)?
    private(set) var status = "Disabled"
    var hasGlobalTap: Bool { session != nil }
    static let syntheticEventTag: Int64 = 0x52415050564F4943

    func setBusy(_ busy: Bool) { session?.setBusy(busy); localFilter.busy = busy }

    func configure(shortcut: VoiceShortcut, enabled: Bool) {
        stop()
        guard enabled else { status = "Disabled — use Start / Stop"; return }
        let alreadyPressed = CGEventSource.flagsState(.combinedSessionState).rawValue & shortcut.deviceMask != 0
        localFilter = ShortcutFilter(shortcut: shortcut, alreadyPressed: alreadyPressed)
        let epoch = generation
        let next = EventTapSession(filter: localFilter) { [weak self] action, time, interruption in
            DispatchQueue.main.async {
                guard let self, self.generation == epoch else { return }
                self.deliver(action, time: time, interruption: interruption)
            }
        }
        if AXIsProcessTrusted(), CGPreflightListenEventAccess(), next.start() {
            session = next
            status = "Exclusive session event tap — all apps, including RAPP Voice"
            return
        }
        local = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown, .keyUp]) { [weak self] event in
            guard let self, let cg = event.cgEvent, let kind = EventTapSession.kind(cg.type) else { return event }
            let result = self.localFilter.handle(
                kind: kind, keyCode: cg.getIntegerValueField(.keyboardEventKeycode), flags: cg.flags.rawValue,
                synthetic: cg.getIntegerValueField(.eventSourceUserData) == Self.syntheticEventTag
            )
            if let action = result.action {
                let time = ProcessInfo.processInfo.systemUptime
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == epoch else { return }
                    self.deliver(action, time: time, interruption: nil)
                }
            }
            if result.consumed { return nil }
            cg.flags = CGEventFlags(rawValue: result.flags)
            return NSEvent(cgEvent: cg) ?? event
        }
        status = "Own-app shortcut only — grant Accessibility and Input Monitoring for other apps"
    }
    private func deliver(_ action: ShortcutFilter.Action?, time: Double, interruption: String?) {
        if let interruption {
            status = "Shortcut interrupted — refresh permissions to reconnect"
            onCancel?(interruption)
            return
        }
        switch action {
        case .press:
            if IsSecureEventInputEnabled() {
                onCancel?("Secure Input is active. Automatic shortcut capture is disabled.")
            } else { onPress?(time) }
        case .release: onRelease?(time)
        case .cancel: onCancel?("Cancelled with Escape.")
        case nil: break
        }
    }
    func stop() {
        generation = UUID()
        session?.stop(); session = nil
        if let local { NSEvent.removeMonitor(local) }
        local = nil
    }
}

// A dedicated run loop keeps the exclusive event tap responsive while the main
// actor opens the microphone, validates a model, or updates an application view.
private final class EventTapSession: @unchecked Sendable {
    private let lock = NSLock()
    private var filter: ShortcutFilter
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var stopped = false
    private var runLoop: CFRunLoop?
    private let deliver: @Sendable (ShortcutFilter.Action?, Double, String?) -> Void

    init(filter: ShortcutFilter, deliver: @escaping @Sendable (ShortcutFilter.Action?, Double, String?) -> Void) {
        self.filter = filter
        self.deliver = deliver
    }
    func setBusy(_ busy: Bool) { lock.lock(); filter.busy = busy; lock.unlock() }
    static func kind(_ type: CGEventType) -> ShortcutFilter.Kind? {
        switch type {
        case .flagsChanged: return .flagsChanged
        case .keyDown: return .keyDown
        case .keyUp: return .keyUp
        default: return nil
        }
    }
    func start() -> Bool {
        let mask = [CGEventType.flagsChanged, .keyDown, .keyUp].reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let session = Unmanaged<EventTapSession>.fromOpaque(userInfo).takeUnretainedValue()
                return session.handle(type: type, event: event) ? nil : Unmanaged.passUnretained(event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()
        )
        guard let tap, let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else { return false }
        self.source = source
        let thread = Thread { [self] in
            let loop = CFRunLoopGetCurrent()
            lock.lock(); runLoop = loop; let shouldRun = !stopped; lock.unlock()
            if shouldRun {
                CFRunLoopAddSource(loop, source, .defaultMode)
                CGEvent.tapEnable(tap: tap, enable: true)
                while true {
                    lock.lock(); let done = stopped; lock.unlock()
                    if done { break }
                    CFRunLoopRunInMode(.defaultMode, 0.2, false)
                }
                CFRunLoopRemoveSource(loop, source, .defaultMode)
            }
            CFMachPortInvalidate(tap)
        }
        thread.name = "io.rapp.voice.shortcut"
        thread.start()
        return true
    }
    func stop() {
        lock.lock(); stopped = true; let loop = runLoop; lock.unlock()
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let loop { CFRunLoopStop(loop) }
    }
    private func handle(type: CGEventType, event: CGEvent) -> Bool {
        let time = ProcessInfo.processInfo.systemUptime
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            stop()
            deliver(nil, time, "Shortcut monitoring was interrupted. Recording was cancelled.")
            return false
        }
        guard let kind = Self.kind(type) else { return false }
        lock.lock()
        let result = filter.handle(
            kind: kind, keyCode: event.getIntegerValueField(.keyboardEventKeycode), flags: event.flags.rawValue,
            synthetic: event.getIntegerValueField(.eventSourceUserData) == 0x52415050564F4943
        )
        lock.unlock()
        if let action = result.action { deliver(action, time, nil) }
        event.flags = CGEventFlags(rawValue: result.flags)
        return result.consumed
    }
}
