import XCTest
@testable import RAPPVoiceCore

@MainActor final class InsertionTests: XCTestCase {
    @MainActor final class Board: PasteboardAccess {
        var items = [PasteboardItem(["public.png": Data([1, 2, 3]), "public.utf8-plain-text": Data("original".utf8)])]
        var changeCount = 1
        var writes = 0
        var rejectSnapshot = false
        var failNextTextWrite = false
        var changeDuringSnapshot = false
        func snapshot() throws -> [PasteboardItem] {
            if rejectSnapshot { throw CocoaError(.fileReadUnknown) }
            let original = items
            if changeDuringSnapshot {
                items = [.init(["public.utf8-plain-text": Data("newer copy".utf8)])]
                changeCount += 1
            }
            return original
        }
        func write(_ items: [PasteboardItem]) throws -> Int {
            self.items = items; changeCount += 1; writes += 1; return changeCount
        }
        func writeText(_ text: String) throws -> Int {
            if failNextTextWrite {
                failNextTextWrite = false
                items = []; changeCount += 1
                throw PasteboardWriteFailure(ownedChangeCount: changeCount)
            }
            return try write([.init(["public.utf8-plain-text": Data(text.utf8)])])
        }
    }
    @MainActor final class Input: InputAccess {
        var current = InsertionContext(
            focus: .init(processID: 123, elementID: "editor", selection: "3:0", editable: true),
            accessibility: true, postEvents: true
        )
        var pasteCount = 0
        var typed = ""
        var own = ""
        var advanceCaret = true
        func context() -> InsertionContext { current }
        func postPaste() throws { pasteCount += 1 }
        func postText(_ text: String) throws {
            typed += text
            if advanceCaret { current.focus.selection = current.focus.selectionAfterInserting(text) }
        }
        func insertIntoOwnEditor(_ text: String) throws { own += text }
    }
    func testPreservesAllItemsAndEmptyClipboardAfterPasteRequest() async throws {
        for original in [[PasteboardItem(["public.png": Data([1, 2]), "public.file-url": Data("file:///fixture".utf8)])], []] {
            let board = Board(); board.items = original
            let input = Input()
            let engine = InsertionEngine(pasteboard: board, input: input, sleep: { _ in })
            let result = try await engine.insert("hello", target: input.current.focus, settings: .init())
            XCTAssertEqual(result, .pasteShortcutSent)
            XCTAssertEqual(input.pasteCount, 1)
            XCTAssertEqual(board.items, original)
            XCTAssertFalse(result.label.lowercased().contains("pasted"))
        }
    }
    func testChangedClipboardIsNeitherPastedNorClobbered() async throws {
        let board = Board()
        let input = Input()
        let engine = InsertionEngine(pasteboard: board, input: input, sleep: { _ in
            await MainActor.run { _ = try? board.writeText("new user copy") }
        })
        let result = try await engine.insert("hello", target: input.current.focus, settings: .init())
        XCTAssertEqual(result, .manual(.clipboardChanged))
        XCTAssertEqual(input.pasteCount, 0)
        XCTAssertEqual(board.items.first?.representations["public.utf8-plain-text"], Data("new user copy".utf8))
    }
    func testFocusOrSelectionChangeDuringPasteDelayRestoresAndDoesNotType() async throws {
        for selectionChange in [false, true] {
            let board = Board()
            let original = board.items
            let input = Input()
            let engine = InsertionEngine(pasteboard: board, input: input, sleep: { _ in
                await MainActor.run {
                    if selectionChange { input.current.focus.selection = "8:0" }
                    else { input.current.focus.elementID = "different editor" }
                }
            })
            let result = try await engine.insert("hello", target: input.current.focus, settings: .init())
            XCTAssertEqual(result, .manual(.focusChanged))
            XCTAssertEqual(board.items, original)
            XCTAssertEqual(input.pasteCount, 0)
        }
    }
    func testProtectedMissingPermissionUnknownAndManualNeverTouchClipboard() async throws {
        for scenario in 0..<6 {
            let board = Board()
            let input = Input()
            var settings = VoiceSettings()
            switch scenario {
            case 0: input.current.focus.secure = true
            case 1: input.current.secureInput = true
            case 2: input.current.accessibility = false
            case 3: input.current.focus.editable = false
            case 4: input.current.modifiersPressed = true
            default: settings.insertMethod = .manual
            }
            let engine = InsertionEngine(pasteboard: board, input: input, sleep: { _ in })
            let outcome = try await engine.insert("hello", target: input.current.focus, settings: settings)
            guard case .manual = outcome else { return XCTFail("Expected manual, got \(outcome)") }
            XCTAssertEqual(board.writes, 0)
            XCTAssertEqual(input.pasteCount, 0)
            XCTAssertEqual(input.typed, "")
        }
    }
    func testOwnEditorWorksWithoutGlobalPermissionsButOnlyWithSameFocus() async throws {
        let board = Board()
        let input = Input()
        input.current.focus.ownApp = true
        input.current.accessibility = false; input.current.postEvents = false
        let engine = InsertionEngine(pasteboard: board, input: input, sleep: { _ in })
        let result = try await engine.insert("hello", target: input.current.focus, settings: .init())
        XCTAssertEqual(result, .ownEditor)
        XCTAssertEqual(input.own, "hello")
        XCTAssertEqual(board.writes, 0)
    }
    func testUnpreservableClipboardDoesNotOverwriteAnything() async throws {
        let board = Board(); board.rejectSnapshot = true
        let input = Input()
        let engine = InsertionEngine(pasteboard: board, input: input, sleep: { _ in })
        let result = try await engine.insert("hello", target: input.current.focus, settings: .init())
        XCTAssertEqual(result, .manual(.clipboardUnavailable))
        XCTAssertEqual(board.writes, 0)
    }
    func testCancellationDuringPasteDelayRestoresClipboard() async {
        let board = Board()
        let original = board.items
        let input = Input()
        let engine = InsertionEngine(pasteboard: board, input: input, sleep: { _ in throw CancellationError() })
        do { _ = try await engine.insert("hello", target: input.current.focus, settings: .init()); XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(board.items, original)
        XCTAssertEqual(input.pasteCount, 0)
        XCTAssertFalse(engine.eventWasSent)
    }
    func testTypingDoesNotTouchClipboardAndStopsIfFocusChanges() async throws {
        let board = Board()
        let input = Input()
        var settings = VoiceSettings(); settings.insertMethod = .type
        let engine = InsertionEngine(pasteboard: board, input: input, sleep: { _ in
            await MainActor.run { input.current.focus.processID = 456 }
        })
        let result = try await engine.insert("hello", target: input.current.focus, settings: settings)
        XCTAssertEqual(result, .partialTyping(characters: 1, reason: .focusChanged))
        XCTAssertEqual(input.typed, "h")
        XCTAssertEqual(board.writes, 0)
    }
    func testRestoreNeverOverwritesNewClipboard() {
        XCTAssertTrue(InsertionPolicy.shouldRestore(ownedChangeCount: 3, currentChangeCount: 3))
        XCTAssertFalse(InsertionPolicy.shouldRestore(ownedChangeCount: 3, currentChangeCount: 4))
    }
    func testCancellationAfterPasteReportsThatInputWasAlreadySent() async {
        let board = Board()
        let original = board.items
        let input = Input()
        let engine = InsertionEngine(pasteboard: board, input: input, sleep: { seconds in
            if seconds > 0.1 { throw CancellationError() }
        })
        do { _ = try await engine.insert("hello", target: input.current.focus, settings: .init()); XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(input.pasteCount, 1)
        XCTAssertTrue(engine.eventWasSent)
        XCTAssertEqual(board.items, original)
    }
    func testClipboardWriteFailureRestoresOriginalIfStillOwned() async throws {
        let board = Board()
        let original = board.items
        board.failNextTextWrite = true
        let input = Input()
        let engine = InsertionEngine(pasteboard: board, input: input, sleep: { _ in })
        let result = try await engine.insert("hello", target: input.current.focus, settings: .init())
        XCTAssertEqual(result, .manual(.clipboardUnavailable))
        XCTAssertEqual(board.items, original)
        XCTAssertEqual(input.pasteCount, 0)
    }
    func testClipboardChangedDuringSnapshotIsNeverOverwritten() async throws {
        let board = Board()
        board.changeDuringSnapshot = true
        let input = Input()
        let engine = InsertionEngine(pasteboard: board, input: input, sleep: { _ in })
        let result = try await engine.insert("hello", target: input.current.focus, settings: .init())
        XCTAssertEqual(result, .manual(.clipboardChanged))
        XCTAssertEqual(board.writes, 0)
        XCTAssertEqual(input.pasteCount, 0)
    }
    func testTypingTracksUTF16CaretAndNeverUsesClipboard() async throws {
        let board = Board()
        let input = Input()
        var settings = VoiceSettings(); settings.insertMethod = .type
        let engine = InsertionEngine(pasteboard: board, input: input, sleep: { _ in })
        let result = try await engine.insert("Hi 👋", target: input.current.focus, settings: settings)
        XCTAssertEqual(result, .typingSent(characters: 4))
        XCTAssertEqual(input.typed, "Hi 👋")
        XCTAssertEqual(input.current.focus.selection, "8:0")
        XCTAssertEqual(board.writes, 0)
    }
    func testTypingStopsWhenSelectionMovesInsideTheSameField() async throws {
        let board = Board()
        let input = Input()
        var settings = VoiceSettings(); settings.insertMethod = .type
        let engine = InsertionEngine(pasteboard: board, input: input, sleep: { _ in
            await MainActor.run { input.current.focus.selection = "20:0" }
        })
        let result = try await engine.insert("hello", target: input.current.focus, settings: settings)
        XCTAssertEqual(result, .partialTyping(characters: 1, reason: .focusChanged))
        XCTAssertEqual(input.typed, "h")
    }
    func testTypingStopsWhenTheTargetDoesNotAcknowledgeInput() async throws {
        let board = Board()
        let input = Input(); input.advanceCaret = false
        var settings = VoiceSettings(); settings.insertMethod = .type
        let engine = InsertionEngine(pasteboard: board, input: input, sleep: { _ in })
        let result = try await engine.insert("hello", target: input.current.focus, settings: settings)
        XCTAssertEqual(result, .partialTyping(characters: 1, reason: .unconfirmedInput))
        XCTAssertEqual(input.typed, "h")
    }
}
