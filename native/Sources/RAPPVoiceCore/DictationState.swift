import Foundation

public enum DictationMode: String, Equatable, Sendable { case idle, recording, latched, working }

public struct DictationState: Sendable {
    public enum Event: Equatable, Sendable {
        case keyDown(Double), keyUp(Double), startButton, stopButton, cancel, shortcutLost
        case maximumDuration(UInt64), completed(UInt64), failed(UInt64)
    }
    public enum Effect: Equatable, Sendable {
        case start(session: UInt64, latched: Bool)
        case stop(session: UInt64, discard: Bool)
        case cancel(session: UInt64)
    }
    public private(set) var mode = DictationMode.idle
    public private(set) var session: UInt64 = 0
    public private(set) var keyIsDown = false
    private var downAt = 0.0
    private var lastTapAt: Double?
    private var latchArmed = false
    private var ignoreNextUp = false
    public var tapMaxSeconds: Double
    public var doubleTapSeconds: Double
    public init(tapMaxSeconds: Double = 0.25, doubleTapSeconds: Double = 0.35) {
        self.tapMaxSeconds = tapMaxSeconds
        self.doubleTapSeconds = doubleTapSeconds
    }
    private mutating func start(latched: Bool) -> Effect {
        session &+= 1
        mode = latched ? .latched : .recording
        return .start(session: session, latched: latched)
    }
    private mutating func finish() -> [Effect] {
        guard mode == .recording || mode == .latched else { return [] }
        mode = .working
        latchArmed = false
        lastTapAt = nil
        return [.stop(session: session, discard: false)]
    }
    @discardableResult public mutating func handle(_ event: Event) -> [Effect] {
        switch event {
        case .keyDown(let now):
            guard !keyIsDown else { return [] }
            keyIsDown = true
            downAt = now
            if mode == .latched {
                ignoreNextUp = true
                return finish()
            }
            guard mode == .idle else { return [] }
            latchArmed = lastTapAt.map { now >= $0 && now - $0 < doubleTapSeconds } ?? false
            return [start(latched: false)]
        case .keyUp(let now):
            guard keyIsDown else { return [] }
            keyIsDown = false
            if ignoreNextUp { ignoreNextUp = false; return [] }
            guard mode == .recording else { return [] }
            if now - downAt < tapMaxSeconds {
                let effect = Effect.stop(session: session, discard: true)
                mode = .idle
                lastTapAt = now
                let latch = latchArmed
                latchArmed = false
                return latch ? [effect, start(latched: true)] : [effect]
            }
            return finish()
        case .startButton:
            guard mode == .idle else { return [] }
            lastTapAt = nil
            return [start(latched: true)]
        case .stopButton:
            ignoreNextUp = keyIsDown
            return finish()
        case .maximumDuration(let id):
            guard id == session else { return [] }
            ignoreNextUp = keyIsDown
            return finish()
        case .cancel, .shortcutLost:
            let old = session
            session &+= 1
            mode = .idle
            lastTapAt = nil
            latchArmed = false
            if event == .shortcutLost { keyIsDown = false }
            ignoreNextUp = keyIsDown
            return [.cancel(session: old)]
        case .completed(let id), .failed(let id):
            guard id == session else { return [] }
            mode = .idle
            latchArmed = false
            lastTapAt = nil
            ignoreNextUp = keyIsDown
            return []
        }
    }
}
