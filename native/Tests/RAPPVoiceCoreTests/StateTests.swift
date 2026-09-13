import XCTest
@testable import RAPPVoiceCore

final class StateTests: XCTestCase {
    func testNoCaptureWithoutUserActionAndSingleTapImmediatelyDiscards() {
        var state = DictationState()
        XCTAssertEqual(state.mode, .idle)
        XCTAssertEqual(state.handle(.keyUp(0)), [])
        XCTAssertEqual(state.handle(.keyDown(1)), [.start(session: 1, latched: false)])
        XCTAssertEqual(state.handle(.keyUp(1.1)), [.stop(session: 1, discard: true)])
        XCTAssertEqual(state.mode, .idle)
    }
    func testDoubleTapLatchesAndStoppingReleaseCannotRestart() {
        var state = DictationState()
        state.handle(.keyDown(1)); state.handle(.keyUp(1.1))
        XCTAssertEqual(state.handle(.keyDown(1.25)), [.start(session: 2, latched: false)])
        XCTAssertEqual(state.handle(.keyUp(1.35)), [.stop(session: 2, discard: true), .start(session: 3, latched: true)])
        XCTAssertEqual(state.mode, .latched)
        XCTAssertEqual(state.handle(.keyDown(2)), [.stop(session: 3, discard: false)])
        XCTAssertEqual(state.mode, .working)
        state.handle(.completed(3))
        XCTAssertEqual(state.handle(.keyUp(2.1)), [])
        XCTAssertEqual(state.mode, .idle)
        XCTAssertEqual(state.handle(.keyDown(2.2)), [.start(session: 4, latched: false)])
        state.handle(.keyUp(2.3))
        XCTAssertEqual(state.mode, .idle, "The latch-ending tap must not arm another latch")
    }
    func testLongHoldDictatesAndSlowDoubleTapDoesNotLatch() {
        var state = DictationState()
        state.handle(.keyDown(1))
        XCTAssertEqual(state.handle(.keyUp(2)), [.stop(session: 1, discard: false)])
        XCTAssertEqual(state.mode, .working)
        state.handle(.completed(1))
        state.handle(.keyDown(3)); state.handle(.keyUp(3.1))
        state.handle(.keyDown(4)); state.handle(.keyUp(4.1))
        XCTAssertEqual(state.mode, .idle)
    }
    func testBusyKeysAndRepeatedDownEventsDoNotCreateSessions() {
        var state = DictationState()
        state.handle(.keyDown(1))
        XCTAssertEqual(state.handle(.keyDown(1.1)), [])
        state.handle(.keyUp(2))
        XCTAssertEqual(state.handle(.keyDown(3)), [])
        XCTAssertEqual(state.handle(.keyUp(4)), [])
        XCTAssertEqual(state.session, 1)
    }
    func testCancelInvalidatesLateTranscriptionAndMaximumDuration() {
        var state = DictationState()
        state.handle(.startButton)
        XCTAssertEqual(state.handle(.cancel), [.cancel(session: 1)])
        XCTAssertEqual(state.mode, .idle)
        state.handle(.startButton)
        let current = state.session
        state.handle(.completed(1)); state.handle(.failed(1))
        XCTAssertEqual(state.handle(.maximumDuration(1)), [])
        XCTAssertEqual(state.mode, .latched)
        XCTAssertEqual(state.handle(.maximumDuration(current)), [.stop(session: current, discard: false)])
        XCTAssertEqual(state.mode, .working)
    }
    func testFailureAndCancelWithKeyHeldWaitForFreshPress() {
        var state = DictationState()
        state.handle(.keyDown(1))
        state.handle(.failed(1))
        XCTAssertEqual(state.handle(.keyDown(1.1)), [])
        XCTAssertEqual(state.handle(.keyUp(1.2)), [])
        XCTAssertEqual(state.handle(.keyDown(2)), [.start(session: 2, latched: false)])
        state.handle(.cancel)
        XCTAssertEqual(state.handle(.keyUp(3)), [])
        XCTAssertEqual(state.mode, .idle)
    }
    func testShortcutDeviceBitsDistinguishSidesAndPreventModifierLeak() {
        for key in VoiceShortcut.allCases {
            XCTAssertNotEqual(key.deviceMask, 0)
            XCTAssertEqual(key.removingReservedModifier(from: key.deviceMask | key.aggregateMask), 0)
            if key.oppositeMask != 0 {
                XCTAssertEqual(
                    key.removingReservedModifier(from: key.deviceMask | key.oppositeMask | key.aggregateMask),
                    key.oppositeMask | key.aggregateMask
                )
            }
        }
        XCTAssertNotEqual(VoiceShortcut.leftCmd.keyCode, VoiceShortcut.rightCmd.keyCode)
    }
    func testReadinessFailuresDoNotRequestPermissionsOrDownload() {
        XCTAssertThrowsError(try CaptureReadiness.check(microphone: .denied, modelInstalled: true, runtimeAvailable: true)) {
            XCTAssertEqual($0 as? VoiceError, .microphoneDenied)
        }
        XCTAssertThrowsError(try CaptureReadiness.check(microphone: .undetermined, modelInstalled: true, runtimeAvailable: true)) {
            XCTAssertEqual($0 as? VoiceError, .microphoneUndetermined)
        }
        XCTAssertThrowsError(try CaptureReadiness.check(microphone: .authorized, modelInstalled: false, runtimeAvailable: true)) {
            XCTAssertEqual($0 as? VoiceError, .modelMissing)
        }
        XCTAssertThrowsError(try CaptureReadiness.check(microphone: .authorized, modelInstalled: true, runtimeAvailable: false)) {
            XCTAssertEqual($0 as? VoiceError, .runtimeMissing)
        }
    }
    func testExclusiveFilterHandlesOwnAndOtherAppEventsIdentically() {
        // No focus-dependent global-only monitor: the same session filter sees every event.
        for _ in ["own-app", "other-app"] {
            var filter = ShortcutFilter(shortcut: .rightCmd)
            let flags = VoiceShortcut.rightCmd.deviceMask | VoiceShortcut.rightCmd.aggregateMask
            let down = filter.handle(kind: .flagsChanged, keyCode: 54, flags: flags)
            XCTAssertTrue(down.consumed)
            XCTAssertEqual(down.action, .press)
            XCTAssertNil(filter.handle(kind: .flagsChanged, keyCode: 54, flags: flags).action)
            let character = filter.handle(kind: .keyDown, keyCode: 0, flags: flags)
            XCTAssertFalse(character.consumed)
            XCTAssertEqual(character.flags, 0, "Reserved Command cannot become a command shortcut in the target")
            let up = filter.handle(kind: .flagsChanged, keyCode: 54, flags: 0)
            XCTAssertTrue(up.consumed)
            XCTAssertEqual(up.action, .release)
        }
    }
    func testFilterDoesNotCaptureHeldKeyOnEnableOrSyntheticInsertion() {
        let flags = VoiceShortcut.rightCmd.deviceMask | VoiceShortcut.rightCmd.aggregateMask
        var filter = ShortcutFilter(shortcut: .rightCmd, alreadyPressed: true)
        XCTAssertNil(filter.handle(kind: .flagsChanged, keyCode: 54, flags: flags).action)
        let synthetic = filter.handle(kind: .keyDown, keyCode: 9, flags: flags, synthetic: true)
        XCTAssertFalse(synthetic.consumed)
        XCTAssertNil(synthetic.action)
        XCTAssertEqual(synthetic.flags, flags)
        _ = filter.handle(kind: .flagsChanged, keyCode: 54, flags: 0)
        XCTAssertEqual(filter.handle(kind: .flagsChanged, keyCode: 54, flags: flags).action, .press)
    }
    func testEscapeCancellationConsumesThePairedReleaseOnlyWhileBusy() {
        var filter = ShortcutFilter(shortcut: .rightCmd)
        XCTAssertFalse(filter.handle(kind: .keyDown, keyCode: 53, flags: 0).consumed)
        filter.busy = true
        XCTAssertEqual(filter.handle(kind: .keyDown, keyCode: 53, flags: 0).action, .cancel)
        filter.busy = false
        XCTAssertTrue(filter.handle(kind: .keyUp, keyCode: 53, flags: 0).consumed)
        XCTAssertFalse(filter.handle(kind: .keyUp, keyCode: 53, flags: 0).consumed)
    }
    func testLostOwnAppFocusOrEventTapResetsMissedReleaseWithoutReusingSessionIDs() {
        var state = DictationState()
        state.handle(.keyDown(1))
        let first = state.session
        state.handle(.shortcutLost)
        XCTAssertFalse(state.keyIsDown)
        XCTAssertEqual(state.mode, .idle)
        state.handle(.keyDown(2))
        XCTAssertGreaterThan(state.session, first)
        state.handle(.completed(first))
        XCTAssertEqual(state.mode, .recording)
    }
}
