import AppKit
import XCTest

// Accessibility identifiers mirror those defined in macos/src/HexEditor.mm.
private enum AXID {
    static let root = "hex-editor.root"
    static let table = "hex-editor.table"
    static let status = "hex-editor.status"
    static let cursor = "hex-editor.cursor.diagnostic"
}

/// Snapshot of the hex view's caret + selection state, parsed from the AX value
/// of the diagnostic element. Format contract is owned by HexCursorDiagnosticView
/// in HexEditor.mm: "offset=<size_t>;selStart=<size_t>;selEnd=<size_t>;hasSelection=<0|1>"
private struct HexCursorState {
    let offset: Int
    let selStart: Int
    let selEnd: Int
    let hasSelection: Bool
    /// Status-label frame height (points). Set when the diagnostic includes layout fields.
    let statusFrameHeight: Double?
    /// Minimum height the status-label font needs to render without clipping descenders.
    let statusFontLineHeight: Double?
    /// Raw values captureScintillaSelection() most recently observed from
    /// Scintilla. -1 = sentinel ("not yet run"). Useful for diagnosing why a
    /// selection-mirror assertion failed.
    let sciSelStart: Int?
    let sciSelEnd: Int?
    let sciCaret: Int?
    /// Rectangular (block) selection state. nil when the diagnostic was emitted by an
    /// older build that didn't carry these fields; rectActive=false otherwise.
    let rectActive: Bool?
    let rectOrigin: Int?
    let rectWidth: Int?
    let rectHeight: Int?
    let rectBpr: Int?
    /// Source pane the rectangular drag originated in: "Hex", "Ascii", or "Address".
    /// Used by chunk 3 paste-matrix tests to confirm the source-pane tag survives.
    let rectOriginPane: String?

    /// Compact dump of all fields for failure messages.
    var debugDescription: String {
        var s = "offset=\(offset);selStart=\(selStart);selEnd=\(selEnd);hasSelection=\(hasSelection)"
        if let a = sciSelStart, let b = sciSelEnd, let c = sciCaret {
            s += ";sciSelStart=\(a);sciSelEnd=\(b);sciCaret=\(c)"
        }
        if let r = rectActive, r,
           let o = rectOrigin, let w = rectWidth, let h = rectHeight, let p = rectOriginPane {
            s += ";rect=\(o)+\(w)x\(h)@\(p)"
        }
        return s
    }

    static func read(from app: XCUIApplication) -> HexCursorState? {
        let element = app.descendants(matching: .any).matching(identifier: AXID.cursor).firstMatch
        guard element.waitForExistence(timeout: 3) else { return nil }
        guard let raw = element.value as? String else { return nil }
        var fields: [String: String] = [:]
        for piece in raw.split(separator: ";") {
            let kv = piece.split(separator: "=", maxSplits: 1)
            if kv.count == 2 { fields[String(kv[0])] = String(kv[1]) }
        }
        guard let offset = fields["offset"].flatMap({ Int($0) }),
              let selStart = fields["selStart"].flatMap({ Int($0) }),
              let selEnd = fields["selEnd"].flatMap({ Int($0) }),
              let has = fields["hasSelection"].flatMap({ Int($0) }) else { return nil }
        return HexCursorState(
            offset: offset,
            selStart: selStart,
            selEnd: selEnd,
            hasSelection: has != 0,
            statusFrameHeight: fields["statusH"].flatMap({ Double($0) }),
            statusFontLineHeight: fields["statusFontH"].flatMap({ Double($0) }),
            sciSelStart: fields["sciSelStart"].flatMap({ Int($0) }),
            sciSelEnd: fields["sciSelEnd"].flatMap({ Int($0) }),
            sciCaret: fields["sciCaret"].flatMap({ Int($0) }),
            rectActive: fields["rectActive"].flatMap({ Int($0) }).map { $0 != 0 },
            rectOrigin: fields["rectOrigin"].flatMap({ Int($0) }),
            rectWidth: fields["rectWidth"].flatMap({ Int($0) }),
            rectHeight: fields["rectHeight"].flatMap({ Int($0) }),
            rectBpr: fields["rectBpr"].flatMap({ Int($0) }),
            rectOriginPane: fields["rectOriginPane"]
        )
    }
}

private extension XCUIElement {
    /// Replace a text field's contents with `text`. Uses Cmd+A + typeText which is the
    /// only sequence empirically delivered reliably to NSAlert-hosted NSTextFields under
    /// XCUI — typeKey(.delete, ...) and typeKey(.end, ...) are silently dropped in this
    /// configuration; Cmd+modifier shortcuts go through NSStandardKeyBindingResponding
    /// and route correctly. Brief pauses around the modifier press let click+focus settle
    /// before the select-all fires (without them the select-all sometimes races the click
    /// and selects nothing, leaving the original value intact).
    func replaceFieldText(with text: String) {
        click()
        Thread.sleep(forTimeInterval: 0.1)
        typeKey("a", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.1)
        typeText(text)
    }
}

@MainActor
final class HexEditorUITests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false

        // Bulletproof pre-test cleanup: a prior test that aborted mid-modal can leave the
        // dev build alive; LaunchServices then coalesces our XCUIApplication(url:) launch
        // onto that stale process and we sit through 68 s of "no PID" per test. Force-kill
        // any dev-build instance up front, then verify the kill landed before proceeding.
        let expectedURL = try notepadAppURL().standardizedFileURL
        terminateDevBuildInstances(expectedURL: expectedURL)

        // If a *different* org.notepadplusplus.mac is running (e.g. /Applications/Notepad++.app),
        // XCUI(url:) cannot launch a second instance under the same bundle ID. Skip-fast with a
        // clear message instead of letting the test sit through the launch timeout.
        let conflicts = NSWorkspace.shared.runningApplications.filter {
            guard $0.bundleIdentifier == "org.notepadplusplus.mac" else { return false }
            guard let url = $0.bundleURL?.standardizedFileURL else { return false }
            return url != expectedURL
        }
        if let conflict = conflicts.first {
            throw XCTSkip("""
                Another Notepad++ macOS instance is already running with the same bundle \
                identifier (org.notepadplusplus.mac):
                  \(conflict.bundleURL?.path ?? "(unknown path)")
                Quit it before running UI tests. XCUIApplication(url:) cannot launch a \
                second instance under the same bundle ID. Expected dev build is:
                  \(expectedURL.path)
                """)
        }
    }

    override func tearDown() async throws {
        // Bulletproof post-test cleanup. If a test fails after opening a modal NSAlert,
        // app.terminate() will not dismiss the modal and the host stays alive forever.
        // forceTerminate() goes through Mach IPC (SIGKILL) and bypasses the modal entirely.
        if let url = try? notepadAppURL().standardizedFileURL {
            terminateDevBuildInstances(expectedURL: url)
        }
        try await super.tearDown()
    }

    /// Force-kills any running dev-build Notepad++.app instance (path matches `expectedURL`),
    /// then waits up to 5 seconds for the process to disappear from the running-apps list.
    /// Leaves instances at other paths (e.g. /Applications/Notepad++.app) untouched — those
    /// belong to the user.
    private func terminateDevBuildInstances(expectedURL: URL) {
        let dev = NSWorkspace.shared.runningApplications.filter {
            guard $0.bundleIdentifier == "org.notepadplusplus.mac" else { return false }
            guard let url = $0.bundleURL?.standardizedFileURL else { return false }
            return url == expectedURL
        }
        for app in dev {
            // forceTerminate() is SIGKILL via Mach — survives modal alert blocks that
            // would otherwise wedge a SIGTERM-based terminate().
            app.forceTerminate()
        }
        for _ in 0..<50 {
            let stillRunning = NSWorkspace.shared.runningApplications.contains {
                $0.bundleIdentifier == "org.notepadplusplus.mac" &&
                $0.bundleURL?.standardizedFileURL == expectedURL
            }
            if !stillRunning { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    func testHostApplicationLaunches() throws {
        let app = try launchNotepad()
        defer { app.terminate() }

        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10), "Notepad++ macOS did not launch into the foreground.")
    }

    func testHexEditorPluginMenuIsPresent() throws {
        let app = try launchNotepad()
        defer { app.terminate() }

        let pluginsMenu = app.menuBars.menuBarItems["Plugins"]
        XCTAssertTrue(pluginsMenu.waitForExistence(timeout: 5), "The Plugins menu is not visible.")
        pluginsMenu.click()

        let hexEditorItem = app.menuBars.menuItems["HEX-Editor"]
        XCTAssertTrue(hexEditorItem.waitForExistence(timeout: 5), "The HEX-Editor plugin menu is not visible under Plugins. Install the plugin first with cmake --install macos/build-universal.")
    }

    func testOptionsDialogOpensAndCancelsCleanly() throws {
        let app = try launchNotepad()
        defer { app.terminate() }

        try invokeHexEditorMenu(app: app, item: "Options...")

        let dialog = app.dialogs.firstMatch
        XCTAssertTrue(dialog.waitForExistence(timeout: 5),
                      "Options... should open a modal dialog.")

        let modifierPopup = app.popUpButtons["hex-editor.options.rectMod.popup"]
        XCTAssertTrue(modifierPopup.waitForExistence(timeout: 3),
                      "Options dialog should expose the rectangular-modifier popup.")

        dialog.buttons["Cancel"].click()
        XCTAssertTrue(dialog.waitForNonExistence(timeout: 5),
                      "Options dialog should dismiss after Cancel.")
    }

    func testViewInHexToggle() throws {
        let app = try launchNotepad()
        defer { app.terminate() }

        try createBufferWithText(app: app, text: "Hello, hex world! 0123ABCD")

        try invokeHexEditorMenu(app: app, item: "View in HEX")

        let hexTable = app.descendants(matching: .table).matching(identifier: AXID.table).firstMatch
        XCTAssertTrue(hexTable.waitForExistence(timeout: 5), "Hex table did not appear after View in HEX.")

        try invokeHexEditorMenu(app: app, item: "View in HEX")

        let disappeared = hexTable.waitForNonExistence(timeout: 5)
        XCTAssertTrue(disappeared, "Hex table did not disappear after toggling View in HEX off.")
    }

func testStatusLabelReportsByteCount() throws {
        let app = try launchNotepad()
        defer { app.terminate() }

        try createBufferWithText(app: app, text: "Hello")
        try invokeHexEditorMenu(app: app, item: "View in HEX")

        let hexTable = app.descendants(matching: .table).matching(identifier: AXID.table).firstMatch
        XCTAssertTrue(hexTable.waitForExistence(timeout: 5))

        XCTAssertTrue(waitForStatus(in: app, contains: "5 bytes", timeout: 5), "Status label should report exactly 5 bytes for a 5-character buffer.")
    }

    func testEditMenuActionsRouteToHexOverlay() throws {
        let app = try launchNotepad()
        defer { app.terminate() }

        try createBufferWithText(app: app, text: "Hex")
        try invokeHexEditorMenu(app: app, item: "View in HEX")
        // Toggling the overlay calls `[hexTableView.window makeFirstResponder:hexTableView]`,
        // but XCUI can outrun that focus change. Without a brief settle, the Edit menu
        // validation can run against a stale responder and the action items report disabled.
        Thread.sleep(forTimeInterval: 1.0)

        let hexTable = app.descendants(matching: .table).matching(identifier: AXID.table).firstMatch
        XCTAssertTrue(hexTable.waitForExistence(timeout: 5))
        // Cursor preservation places the hex caret at end-of-paste (= EOF append slot).
        // Cut/Copy/Delete are correctly disabled at EOF because there's no current byte.
        // Reposition to byte 0 so we test the responder-chain routing (the test's actual
        // intent), not edge-of-buffer caret semantics.
        try positionHexCursorAtZero(app: app, hexTable: hexTable)

        let editMenu = app.menuBars.menuBarItems["Edit"]
        XCTAssertTrue(editMenu.waitForExistence(timeout: 5))
        editMenu.click()

        // With session-restored content the buffer is non-empty, so Cut/Copy/Paste/Delete/
        // Select All must be enabled (Undo/Redo depend on edit history we haven't created).
        for label in ["Cut", "Copy", "Paste", "Delete", "Select All"] {
            let item = app.menuBars.menuItems[label]
            XCTAssertTrue(item.waitForExistence(timeout: 3), "Edit menu missing \(label)")
            XCTAssertTrue(item.isEnabled, "\(label) should be enabled in the hex overlay with content present")
        }

        app.typeKey(.escape, modifierFlags: [])
    }

    func testEditMenuCopyFromHexView() throws {
        let app = try launchNotepad()
        defer { app.terminate() }

        try createBufferWithText(app: app, text: "Hex")
        try invokeHexEditorMenu(app: app, item: "View in HEX")
        Thread.sleep(forTimeInterval: 1.0)

        let hexTable = app.descendants(matching: .table).matching(identifier: AXID.table).firstMatch
        XCTAssertTrue(hexTable.waitForExistence(timeout: 5))

        // Select All from the Edit menu — exercises the menu → first-responder route end-to-end.
        let editMenu = app.menuBars.menuBarItems["Edit"]
        editMenu.click()
        let selectAllItem = app.menuBars.menuItems["Select All"]
        XCTAssertTrue(selectAllItem.waitForExistence(timeout: 5))
        selectAllItem.click()
        Thread.sleep(forTimeInterval: 0.3)

        // Stamp the pasteboard with a sentinel so we can detect whether Copy actually wrote.
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let sentinel = "__hexedit-test-sentinel-\(UUID().uuidString)__"
        pasteboard.setString(sentinel, forType: .string)

        editMenu.click()
        let copyItem = app.menuBars.menuItems["Copy"]
        XCTAssertTrue(copyItem.waitForExistence(timeout: 5))
        copyItem.click()
        Thread.sleep(forTimeInterval: 0.3)

        let copied = pasteboard.string(forType: .string)
        XCTAssertNotEqual(copied, sentinel, "Copy from the Edit menu should have replaced the sentinel.")
        XCTAssertNotNil(copied, "Pasteboard should contain a string after Copy.")
        // Copy from the hex field emits lowercase, space-separated hex text matching Windows.
        // "Hex" = 0x48 0x65 0x78.
        XCTAssertEqual(copied, "48 65 78", "Copy should produce lowercase space-separated hex text.")
    }

    func testHexByteAppendUndoRedo() throws {
        let app = try launchNotepad()
        defer { app.terminate() }

        try createBufferWithText(app: app, text: "ABC")
        try invokeHexEditorMenu(app: app, item: "View in HEX")
        Thread.sleep(forTimeInterval: 1.0)

        let hexTable = app.descendants(matching: .table).matching(identifier: AXID.table).firstMatch
        XCTAssertTrue(hexTable.waitForExistence(timeout: 5))

        XCTAssertTrue(waitForStatus(in: app, contains: "3 bytes", timeout: 5), "Initial status should report 3 bytes for the seeded buffer.")

        // End walks to end of row 0; for a 3-byte doc that is offset 3 (EOF, append slot).
        app.typeKey(.end, modifierFlags: [])
        // Type a hex digit at EOF — the planner appends one byte, growing the doc to 4 bytes.
        app.typeText("F")
        XCTAssertTrue(waitForStatus(in: app, contains: "4 bytes", timeout: 5), "Append-at-EOF should report 4 bytes.")

        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(waitForStatus(in: app, contains: "3 bytes", timeout: 5), "Cmd+Z should revert the append back to 3 bytes.")

        app.typeKey("z", modifierFlags: [.command, .shift])
        XCTAssertTrue(waitForStatus(in: app, contains: "4 bytes", timeout: 5), "Cmd+Shift+Z should reapply the append.")

        // Leave the doc in its pre-append state so app.terminate() does not surface a save prompt.
        app.typeKey("z", modifierFlags: .command)
    }

    func testHexCutAndUndo() throws {
        let app = try launchNotepad()
        defer { app.terminate() }

        try createBufferWithText(app: app, text: "Cut Me")
        try invokeHexEditorMenu(app: app, item: "View in HEX")
        Thread.sleep(forTimeInterval: 1.0)

        let hexTable = app.descendants(matching: .table).matching(identifier: AXID.table).firstMatch
        XCTAssertTrue(hexTable.waitForExistence(timeout: 5))

        XCTAssertTrue(waitForStatus(in: app, contains: "6 bytes", timeout: 5), "Seeded buffer should report 6 bytes.")

        // Edit > Select All — exercises menu → responder chain → plugin selectAll: end-to-end.
        let editMenu = app.menuBars.menuBarItems["Edit"]
        editMenu.click()
        let selectAllItem = app.menuBars.menuItems["Select All"]
        XCTAssertTrue(selectAllItem.waitForExistence(timeout: 5))
        selectAllItem.click()
        Thread.sleep(forTimeInterval: 0.3)

        // Edit > Cut — should remove all selected bytes via the plugin's cut: handler.
        editMenu.click()
        let cutItem = app.menuBars.menuItems["Cut"]
        XCTAssertTrue(cutItem.waitForExistence(timeout: 5))
        XCTAssertTrue(cutItem.isEnabled, "Cut should be enabled after Select All.")
        cutItem.click()

        XCTAssertTrue(waitForStatus(in: app, contains: "empty", timeout: 5), "After Cut, status should report the document is empty.")

        // Undo should restore the cut bytes.
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(waitForStatus(in: app, contains: "6 bytes", timeout: 5), "Cmd+Z should restore the cut bytes.")

        // Redo should cut them again.
        app.typeKey("z", modifierFlags: [.command, .shift])
        XCTAssertTrue(waitForStatus(in: app, contains: "empty", timeout: 5), "Cmd+Shift+Z should re-cut the bytes.")

        // Final undo so app.terminate() doesn't surface a save prompt for unsaved changes.
        app.typeKey("z", modifierFlags: .command)
        _ = waitForStatus(in: app, contains: "6 bytes", timeout: 3)
    }

    func testHexPasteAtCmdEnd() throws {
        let app = try launchNotepad()
        defer { app.terminate() }

        try createBufferWithText(app: app, text: "ABC")
        try invokeHexEditorMenu(app: app, item: "View in HEX")
        Thread.sleep(forTimeInterval: 1.0)

        let hexTable = app.descendants(matching: .table).matching(identifier: AXID.table).firstMatch
        XCTAssertTrue(hexTable.waitForExistence(timeout: 5))

        XCTAssertTrue(waitForStatus(in: app, contains: "3 bytes", timeout: 5))

        // Cmd+End jumps the hex cursor to the end of the document. Without this mapping
        // (added to HexTableView.keyDown), End only reaches end-of-row, so this test would
        // be limited to <=16-byte buffers. The shortcut goes through commandOrControl
        // branch in keyDown which now special-cases Cmd+End.
        app.typeKey(.end, modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.3)

        // Paste 3 bytes at EOF via the Edit menu (clipboard route — typeText doesn't reach
        // hex view's paste: handler reliably here).
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("XYZ", forType: .string)

        let editMenu = app.menuBars.menuBarItems["Edit"]
        editMenu.click()
        let pasteItem = app.menuBars.menuItems["Paste"]
        XCTAssertTrue(pasteItem.waitForExistence(timeout: 5))
        pasteItem.click()

        XCTAssertTrue(waitForStatus(in: app, contains: "6 bytes", timeout: 5), "Pasting 3 bytes at EOF should grow the doc from 3 to 6 bytes.")

        // Undo so termination is clean.
        app.typeKey("z", modifierFlags: .command)
        _ = waitForStatus(in: app, contains: "3 bytes", timeout: 3)
    }

    func testHexTableDisplaysCorrectByteValues() throws {
        let app = try launchNotepad()
        defer { app.terminate() }

        try createBufferWithText(app: app, text: "ABC")
        try invokeHexEditorMenu(app: app, item: "View in HEX")
        Thread.sleep(forTimeInterval: 1.0)

        let hexTable = app.descendants(matching: .table).matching(identifier: AXID.table).firstMatch
        XCTAssertTrue(hexTable.waitForExistence(timeout: 5))

        // The hex table exposes each row's cells as a flat list of NSStaticText elements
        // ordered: offset, byte00..byte07, midspacer, byte08..byte15, ascii spacer, ascii.
        // Spacer cells have no AXValue. Index 0 is the offset, index 1 is byte 0, etc.
        let firstRow = hexTable.tableRows.element(boundBy: 0)
        XCTAssertTrue(firstRow.waitForExistence(timeout: 5))

        let offsetCell = firstRow.staticTexts.element(boundBy: 0)
        let byte0 = firstRow.staticTexts.element(boundBy: 1)
        let byte1 = firstRow.staticTexts.element(boundBy: 2)
        let byte2 = firstRow.staticTexts.element(boundBy: 3)

        XCTAssertEqual(offsetCell.value as? String, "00000000", "Offset cell should display 8-digit hex offset.")
        XCTAssertEqual(byte0.value as? String, "41", "Byte 0 should display 41 ('A' = 0x41).")
        XCTAssertEqual(byte1.value as? String, "42", "Byte 1 should display 42 ('B' = 0x42).")
        XCTAssertEqual(byte2.value as? String, "43", "Byte 2 should display 43 ('C' = 0x43).")
    }

    func testHexBookmarkClickPath() throws {
        let app = try launchNotepad()
        defer { app.terminate() }

        try createBufferWithText(app: app, text: "Bookmark me")
        try invokeHexEditorMenu(app: app, item: "View in HEX")
        Thread.sleep(forTimeInterval: 1.0)

        let hexTable = app.descendants(matching: .table).matching(identifier: AXID.table).firstMatch
        XCTAssertTrue(hexTable.waitForExistence(timeout: 5))

        let firstRow = hexTable.tableRows.element(boundBy: 0)
        XCTAssertTrue(firstRow.waitForExistence(timeout: 5))
        let offsetCell = firstRow.staticTexts.element(boundBy: 0)
        XCTAssertTrue(offsetCell.waitForExistence(timeout: 5))

        // Click the offset cell to toggle the bookmark on that row. We can't observe the
        // bookmark color through accessibility, but we can verify the click reaches the
        // plugin without crashing and the table remains usable for subsequent interactions.
        offsetCell.click()
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertTrue(hexTable.exists, "Hex table should remain visible after bookmark click.")

        offsetCell.click()
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertTrue(hexTable.exists, "Hex table should remain visible after un-bookmark click.")
    }

func testContextMenuCommands() throws {
        let app = try launchNotepad()
        defer { app.terminate() }

        try createBufferWithText(app: app, text: "ContextTest")
        try invokeHexEditorMenu(app: app, item: "View in HEX")

        let hexTable = app.descendants(matching: .table).matching(identifier: AXID.table).firstMatch
        XCTAssertTrue(hexTable.waitForExistence(timeout: 5))

        hexTable.rightClick()

        let expectedItems = [
            "Undo", "Redo",
            "Cut", "Copy", "Paste", "Delete",
            "Cut Binary Content", "Copy Binary Content", "Paste Binary Content",
            "Find…", "Find and Replace…", "Find Next", "Find Previous",
            "Go to Offset…",
            "View in",
            "Address Width...", "Columns...",
            "Zoom In", "Zoom Out", "Restore Default Zoom",
        ]
        for label in expectedItems {
            let item = app.menuItems[label]
            XCTAssertTrue(item.waitForExistence(timeout: 3), "Context menu missing item: \(label)")
        }

        // Dismiss the context menu.
        app.typeKey(.escape, modifierFlags: [])
    }

    func testViewSubmodeSwitchesCellWidth() throws {
        let app = try launchNotepad()
        defer { app.terminate() }

        try createBufferWithText(app: app, text: "ABCD")
        try invokeHexEditorMenu(app: app, item: "View in HEX")
        Thread.sleep(forTimeInterval: 1.0)

        let hexTable = app.descendants(matching: .table).matching(identifier: AXID.table).firstMatch
        XCTAssertTrue(hexTable.waitForExistence(timeout: 5))

        let firstRow = hexTable.tableRows.element(boundBy: 0)
        XCTAssertTrue(firstRow.waitForExistence(timeout: 5))

        let cellOne = firstRow.staticTexts.element(boundBy: 1)
        XCTAssertEqual(cellOne.value as? String, "41",
                       "Default 8-Bit hex should render byte 0 ('A' = 0x41) as a 2-char cell.")

        hexTable.rightClick()
        let viewIn = app.menuItems["View in"]
        XCTAssertTrue(viewIn.waitForExistence(timeout: 3))
        viewIn.click()

        let bits16 = app.menuItems["16-Bit"]
        XCTAssertTrue(bits16.waitForExistence(timeout: 3))
        bits16.click()

        // Wait for the table to rebuild — the cell at index 1 must now span 2 bytes (4 hex chars).
        let firstRowAfter = hexTable.tableRows.element(boundBy: 0)
        XCTAssertTrue(firstRowAfter.waitForExistence(timeout: 5))
        let cellOneAfter = firstRowAfter.staticTexts.element(boundBy: 1)

        let predicate = NSPredicate(format: "value == %@", "4142")
        let waiter = expectation(for: predicate, evaluatedWith: cellOneAfter, handler: nil)
        wait(for: [waiter], timeout: 5)
    }

    func testAddressWidthDialogChangesOffsetGutter() throws {
        let app = try launchNotepad()
        defer { app.terminate() }

        try createBufferWithText(app: app, text: "X")
        try invokeHexEditorMenu(app: app, item: "View in HEX")
        Thread.sleep(forTimeInterval: 1.0)

        let hexTable = app.descendants(matching: .table).matching(identifier: AXID.table).firstMatch
        XCTAssertTrue(hexTable.waitForExistence(timeout: 5))

        let firstRow = hexTable.tableRows.element(boundBy: 0)
        XCTAssertTrue(firstRow.waitForExistence(timeout: 5))
        let offsetCell = firstRow.staticTexts.element(boundBy: 0)
        XCTAssertEqual(offsetCell.value as? String, "00000000",
                       "Default address width should produce an 8-digit offset.")

        hexTable.rightClick()
        let addrItem = app.menuItems["Address Width..."]
        XCTAssertTrue(addrItem.waitForExistence(timeout: 3))
        addrItem.click()

        let dialogField = app.textFields["hex-editor.dialog.input"]
        XCTAssertTrue(dialogField.waitForExistence(timeout: 3))
        dialogField.replaceFieldText(with: "12")
        XCTAssertEqual(dialogField.value as? String, "12",
                       "Dialog field should contain '12' before clicking OK.")

        let okButton = app.buttons["OK"].firstMatch
        XCTAssertTrue(okButton.waitForExistence(timeout: 3))
        okButton.click()
        XCTAssertTrue(dialogField.waitForNonExistence(timeout: 5),
                      "Dialog should dismiss after OK.")

        // After the table rebuilds, the offset should be 12 hex digits wide.
        let firstRowAfter = hexTable.tableRows.element(boundBy: 0)
        XCTAssertTrue(firstRowAfter.waitForExistence(timeout: 5))
        let offsetCellAfter = firstRowAfter.staticTexts.element(boundBy: 0)
        let predicate = NSPredicate(format: "value == %@", "000000000000")
        let waiter = expectation(for: predicate, evaluatedWith: offsetCellAfter, handler: nil)
        wait(for: [waiter], timeout: 5)
    }

    func testColumnsDialogChangesRowCount() throws {
        let app = try launchNotepad()
        defer { app.terminate() }

        // 24 bytes → at the default 16 bytes/row that is 2 rows; at columns=4 (×1-byte cells) that is 6 rows.
        try createBufferWithText(app: app, text: "ABCDEFGHIJKLMNOPQRSTUVWX")
        try invokeHexEditorMenu(app: app, item: "View in HEX")
        Thread.sleep(forTimeInterval: 1.0)

        let hexTable = app.descendants(matching: .table).matching(identifier: AXID.table).firstMatch
        XCTAssertTrue(hexTable.waitForExistence(timeout: 5))

        // Sanity: at least 2 rows initially (allow for the trailing append-slot row).
        XCTAssertGreaterThanOrEqual(hexTable.tableRows.count, 2,
                                     "24-byte buffer at default 16 bytes/row should render 2+ rows.")

        hexTable.rightClick()
        let colsItem = app.menuItems["Columns..."]
        XCTAssertTrue(colsItem.waitForExistence(timeout: 3))
        colsItem.click()

        let dialogField = app.textFields["hex-editor.dialog.input"]
        XCTAssertTrue(dialogField.waitForExistence(timeout: 3))
        dialogField.replaceFieldText(with: "4")
        XCTAssertEqual(dialogField.value as? String, "4",
                       "Dialog field should contain '4' before clicking OK.")

        let okButton = app.buttons["OK"].firstMatch
        XCTAssertTrue(okButton.waitForExistence(timeout: 3))
        okButton.click()
        XCTAssertTrue(dialogField.waitForNonExistence(timeout: 5),
                      "Dialog should dismiss after OK.")

        // 24 bytes / 4-bytes-per-row = 6 rows, plus an append-slot row when the doc fully populates
        // the last row, so accept ≥6 rows as the post-resize target.
        let predicate = NSPredicate(format: "count >= 6")
        let waiter = expectation(for: predicate, evaluatedWith: hexTable.tableRows, handler: nil)
        wait(for: [waiter], timeout: 5)
    }

    func testFindNextLandsOnAsciiMatch() throws {
        let app = try launchNotepad()
        defer { app.terminate() }

        // Buffer: "AAAA-BBBB-CCCC". Match "BBBB" at offset 5.
        try createBufferWithText(app: app, text: "AAAA-BBBB-CCCC")
        try invokeHexEditorMenu(app: app, item: "View in HEX")
        Thread.sleep(forTimeInterval: 1.0)

        let hexTable = app.descendants(matching: .table).matching(identifier: AXID.table).firstMatch
        XCTAssertTrue(hexTable.waitForExistence(timeout: 5))

        // Use Cmd+F directly — much simpler than menu navigation, and the host's Edit
        // menu also has a "Find…" item which makes app.menuItems["Find…"] ambiguous.
        // The hex view's keyDown handler routes Cmd+F to presentHexFindDialog.
        app.typeKey("f", modifierFlags: .command)

        let findField = app.textFields["hex-editor.find.input"]
        XCTAssertTrue(findField.waitForExistence(timeout: 3),
                      "Cmd+F should open the hex Find dialog. If this fails, the host may have intercepted the shortcut.")
        findField.replaceFieldText(with: "BBBB")

        let findNextButton = app.buttons["Find Next"].firstMatch
        XCTAssertTrue(findNextButton.waitForExistence(timeout: 3))
        findNextButton.click()
        XCTAssertTrue(findField.waitForNonExistence(timeout: 5),
                      "Find dialog should dismiss after Find Next.")

        // After Find Next, the cursor should be at offset 5. Type "00" to overwrite byte 5
        // (which is 0x42 'B'). If the find didn't land, byte 5 would not become 0x00 — or some
        // other byte would change instead.
        app.typeText("00")

        let firstRow = hexTable.tableRows.element(boundBy: 0)
        let byte5 = firstRow.staticTexts.element(boundBy: 6)
        let predicate = NSPredicate(format: "value == %@", "00")
        let waiter = expectation(for: predicate, evaluatedWith: byte5, handler: nil)
        wait(for: [waiter], timeout: 5)

        // Untouched byte sanity.
        let byte4 = firstRow.staticTexts.element(boundBy: 5)
        XCTAssertEqual(byte4.value as? String, "2d",
                       "Byte 4 ('-' = 0x2D) must be untouched — Find should land precisely on byte 5.")

        // Two undos to revert the nibble edits.
        app.typeKey("z", modifierFlags: .command)
        app.typeKey("z", modifierFlags: .command)
    }

    func testFindNextHexPattern() throws {
        let app = try launchNotepad()
        defer { app.terminate() }

        // "ABCDEFGH" → bytes 41 42 43 44 45 46 47 48. Search for hex "44 45" (offset 3).
        try createBufferWithText(app: app, text: "ABCDEFGH")
        try invokeHexEditorMenu(app: app, item: "View in HEX")
        Thread.sleep(forTimeInterval: 1.0)

        let hexTable = app.descendants(matching: .table).matching(identifier: AXID.table).firstMatch
        XCTAssertTrue(hexTable.waitForExistence(timeout: 5))

        app.typeKey("f", modifierFlags: .command)

        let findField = app.textFields["hex-editor.find.input"]
        XCTAssertTrue(findField.waitForExistence(timeout: 3),
                      "Cmd+F should open the hex Find dialog.")
        findField.replaceFieldText(with: "44 45")
        app.buttons["Find Next"].firstMatch.click()
        XCTAssertTrue(findField.waitForNonExistence(timeout: 5))

        // Cursor should now be at byte 3 (0x44 = 'D'). Type "00" to overwrite.
        app.typeText("00")

        let firstRow = hexTable.tableRows.element(boundBy: 0)
        let byte3 = firstRow.staticTexts.element(boundBy: 4)
        let predicate = NSPredicate(format: "value == %@", "00")
        let waiter = expectation(for: predicate, evaluatedWith: byte3, handler: nil)
        wait(for: [waiter], timeout: 5)

        app.typeKey("z", modifierFlags: .command)
        app.typeKey("z", modifierFlags: .command)
    }

    func testFindNotFoundShowsErrorAndKeepsBuffer() throws {
        let app = try launchNotepad()
        defer { app.terminate() }

        try createBufferWithText(app: app, text: "ABCD")
        try invokeHexEditorMenu(app: app, item: "View in HEX")
        Thread.sleep(forTimeInterval: 1.0)

        let hexTable = app.descendants(matching: .table).matching(identifier: AXID.table).firstMatch
        XCTAssertTrue(hexTable.waitForExistence(timeout: 5))

        app.typeKey("f", modifierFlags: .command)

        let findField = app.textFields["hex-editor.find.input"]
        XCTAssertTrue(findField.waitForExistence(timeout: 3),
                      "Cmd+F should open the hex Find dialog.")
        findField.replaceFieldText(with: "ZZZZ")
        app.buttons["Find Next"].firstMatch.click()

        // The find dialog dismisses, then a "not found" NSAlert appears with an OK button.
        let okAfter = app.buttons["OK"].firstMatch
        XCTAssertTrue(okAfter.waitForExistence(timeout: 3),
                      "A not-found error dialog should appear and offer OK.")
        okAfter.click()

        // Buffer is untouched.
        let firstRow = hexTable.tableRows.element(boundBy: 0)
        let byte0 = firstRow.staticTexts.element(boundBy: 1)
        XCTAssertEqual(byte0.value as? String, "41",
                       "Failed find must not modify the buffer.")
    }

    func testReplaceAllChangesAllAsciiOccurrences() throws {
        let app = try launchNotepad()
        defer { app.terminate() }

        // 3 occurrences of "X": "AXBXCX". Replacing X with Y → "AYBYCY".
        try createBufferWithText(app: app, text: "AXBXCX")
        try invokeHexEditorMenu(app: app, item: "View in HEX")
        Thread.sleep(forTimeInterval: 1.0)

        let hexTable = app.descendants(matching: .table).matching(identifier: AXID.table).firstMatch
        XCTAssertTrue(hexTable.waitForExistence(timeout: 5))

        // Cmd+Alt+F → Find and Replace dialog (replace mode).
        app.typeKey("f", modifierFlags: [.command, .option])

        let findField = app.textFields["hex-editor.find.input"]
        XCTAssertTrue(findField.waitForExistence(timeout: 3),
                      "Cmd+Alt+F should open the Find and Replace dialog.")
        findField.replaceFieldText(with: "X")

        let replaceField = app.textFields["hex-editor.replace.input"]
        XCTAssertTrue(replaceField.waitForExistence(timeout: 3))
        replaceField.replaceFieldText(with: "Y")

        let replaceAllButton = app.buttons["Replace All"].firstMatch
        XCTAssertTrue(replaceAllButton.waitForExistence(timeout: 3))
        replaceAllButton.click()

        // Confirmation alert ("Replaced 3 occurrences."). Dismiss with OK.
        let okAfter = app.buttons["OK"].firstMatch
        XCTAssertTrue(okAfter.waitForExistence(timeout: 3))
        okAfter.click()

        // Verify byte values: bytes 1, 3, 5 should be 0x59 ('Y'), bytes 0/2/4 unchanged.
        let firstRow = hexTable.tableRows.element(boundBy: 0)
        // byte index → AX boundBy: 0 = offset, byte N = N+1
        let predicate = NSPredicate(format: "value == %@", "59")
        let waiter1 = expectation(for: predicate, evaluatedWith: firstRow.staticTexts.element(boundBy: 2), handler: nil)
        let waiter3 = expectation(for: predicate, evaluatedWith: firstRow.staticTexts.element(boundBy: 4), handler: nil)
        let waiter5 = expectation(for: predicate, evaluatedWith: firstRow.staticTexts.element(boundBy: 6), handler: nil)
        wait(for: [waiter1, waiter3, waiter5], timeout: 5)

        XCTAssertEqual(firstRow.staticTexts.element(boundBy: 1).value as? String, "41",
                       "Byte 0 ('A') must be untouched.")
        XCTAssertEqual(firstRow.staticTexts.element(boundBy: 3).value as? String, "42",
                       "Byte 2 ('B') must be untouched.")

        // Single undo reverts the entire Replace All (one undo group).
        app.typeKey("z", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.3)
        let firstRowAfterUndo = hexTable.tableRows.element(boundBy: 0)
        let byte1After = firstRowAfterUndo.staticTexts.element(boundBy: 2)
        let revertPredicate = NSPredicate(format: "value == %@", "58")
        let revertWaiter = expectation(for: revertPredicate, evaluatedWith: byte1After, handler: nil)
        wait(for: [revertWaiter], timeout: 5)
    }

    func testCompareHexHighlightsDifferingBytes() throws {
        // Write a fixture file that differs from the buffer at known positions.
        let fixturePath = NSTemporaryDirectory() + "hex-compare-fixture-\(UUID().uuidString).bin"
        // Buffer "ABCD" → 0x41 0x42 0x43 0x44
        // Fixture            0x41 0x42 0xFF 0x44 → byte 2 differs.
        let fixtureBytes: [UInt8] = [0x41, 0x42, 0xFF, 0x44]
        let fixtureData = Data(fixtureBytes)
        try fixtureData.write(to: URL(fileURLWithPath: fixturePath))
        defer { try? FileManager.default.removeItem(atPath: fixturePath) }

        // Pass the fixture path through --test-compare-with so the plugin bypasses the
        // NSOpenPanel (XCUI cannot drive system panels reliably).
        let app = try launchNotepad(extraArguments: ["--test-compare-with=\(fixturePath)"])
        defer { app.terminate() }

        try createBufferWithText(app: app, text: "ABCD")
        try invokeHexEditorMenu(app: app, item: "View in HEX")
        Thread.sleep(forTimeInterval: 1.0)

        let hexTable = app.descendants(matching: .table).matching(identifier: AXID.table).firstMatch
        XCTAssertTrue(hexTable.waitForExistence(timeout: 5))

        // Trigger Compare HEX from the plugin menu — fixture picks up via the launch arg.
        try invokeHexEditorMenu(app: app, item: "Compare HEX")

        // Confirmation alert: "1 byte differ.\n…" — dismiss with OK.
        let summaryButton = app.buttons["OK"].firstMatch
        XCTAssertTrue(summaryButton.waitForExistence(timeout: 5),
                      "Compare HEX should present a summary dialog.")
        // Optional: assert the summary text mentions "1 byte differ" — accessible via AX.
        let summaryDialog = app.dialogs.firstMatch
        if summaryDialog.exists {
            // The dialog's static texts include the message text; loose match for "1 byte".
            XCTAssertTrue(summaryDialog.staticTexts.element(matching:
                NSPredicate(format: "value CONTAINS '1 byte'")).exists ||
                summaryDialog.staticTexts.element(matching:
                NSPredicate(format: "label CONTAINS '1 byte'")).exists,
                "Summary alert should report exactly 1 byte differing.")
        }
        summaryButton.click()

        // The hex view should still be functional. Now trigger Clear Compare Result and
        // verify it doesn't surface the "no active comparison" message.
        try invokeHexEditorMenu(app: app, item: "Clear Compare Result")
        // No alert is expected when an active comparison is cleared. Nothing more to check.

        // Trigger Clear again — this time the plugin should surface "No active comparison".
        try invokeHexEditorMenu(app: app, item: "Clear Compare Result")
        let secondClearOK = app.buttons["OK"].firstMatch
        XCTAssertTrue(secondClearOK.waitForExistence(timeout: 3),
                      "Second Clear Compare Result should explain that nothing is active.")
        secondClearOK.click()
    }

    func testPatternReplaceFillsSelectionWithRepeatingPattern() throws {
        let app = try launchNotepad()
        defer { app.terminate() }

        // 4 bytes: 'A' 'B' 'C' 'D' → 0x41 0x42 0x43 0x44.
        try createBufferWithText(app: app, text: "ABCD")
        try invokeHexEditorMenu(app: app, item: "View in HEX")
        Thread.sleep(forTimeInterval: 1.0)

        let hexTable = app.descendants(matching: .table).matching(identifier: AXID.table).firstMatch
        XCTAssertTrue(hexTable.waitForExistence(timeout: 5))

        // Select All so Pattern Replace has something to fill.
        let editMenu = app.menuBars.menuBarItems["Edit"]
        editMenu.click()
        let selectAllItem = app.menuBars.menuItems["Select All"]
        XCTAssertTrue(selectAllItem.waitForExistence(timeout: 5))
        selectAllItem.click()
        Thread.sleep(forTimeInterval: 0.3)

        // Trigger Pattern Replace from the plugin menu.
        try invokeHexEditorMenu(app: app, item: "Pattern Replace...")

        let patternField = app.textFields["hex-editor.patternreplace.pattern"]
        XCTAssertTrue(patternField.waitForExistence(timeout: 5),
                      "Pattern Replace pattern field should appear.")
        // 2-byte pattern; selection is 4 bytes; pattern cycles to fill: AB AB.
        patternField.replaceFieldText(with: "AB CD")

        let replaceButton = app.buttons["Replace"].firstMatch
        XCTAssertTrue(replaceButton.waitForExistence(timeout: 3))
        replaceButton.click()

        // Confirmation alert "Replaced 4 bytes…". Dismiss with OK.
        let okButton = app.buttons["OK"].firstMatch
        XCTAssertTrue(okButton.waitForExistence(timeout: 3))
        okButton.click()

        // Verify the buffer is now AB CD AB CD across the 4-byte row.
        let firstRow = hexTable.tableRows.element(boundBy: 0)
        XCTAssertTrue(firstRow.waitForExistence(timeout: 5))
        let predicateAB = NSPredicate(format: "value == %@", "ab")
        let predicateCD = NSPredicate(format: "value == %@", "cd")
        let waiterByte0 = expectation(for: predicateAB,
                                       evaluatedWith: firstRow.staticTexts.element(boundBy: 1),
                                       handler: nil)
        let waiterByte1 = expectation(for: predicateCD,
                                       evaluatedWith: firstRow.staticTexts.element(boundBy: 2),
                                       handler: nil)
        let waiterByte2 = expectation(for: predicateAB,
                                       evaluatedWith: firstRow.staticTexts.element(boundBy: 3),
                                       handler: nil)
        let waiterByte3 = expectation(for: predicateCD,
                                       evaluatedWith: firstRow.staticTexts.element(boundBy: 4),
                                       handler: nil)
        wait(for: [waiterByte0, waiterByte1, waiterByte2, waiterByte3], timeout: 5)

        // Single undo reverts the entire pattern fill (one undo group).
        app.typeKey("z", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.3)
        let firstRowAfterUndo = hexTable.tableRows.element(boundBy: 0)
        let revertPredicate = NSPredicate(format: "value == %@", "41")
        let revertWaiter = expectation(for: revertPredicate,
                                        evaluatedWith: firstRowAfterUndo.staticTexts.element(boundBy: 1),
                                        handler: nil)
        wait(for: [revertWaiter], timeout: 5)
    }

    func testPatternReplaceRequiresSelection() throws {
        let app = try launchNotepad()
        defer { app.terminate() }

        try createBufferWithText(app: app, text: "AB")
        try invokeHexEditorMenu(app: app, item: "View in HEX")
        Thread.sleep(forTimeInterval: 1.0)

        // No selection: Pattern Replace should surface a directive instead of opening the dialog.
        try invokeHexEditorMenu(app: app, item: "Pattern Replace...")
        let okButton = app.buttons["OK"].firstMatch
        XCTAssertTrue(okButton.waitForExistence(timeout: 3),
                      "Pattern Replace without a selection should present a clarifying alert.")
        okButton.click()

        // The pattern field must NOT have appeared.
        let patternField = app.textFields["hex-editor.patternreplace.pattern"]
        XCTAssertFalse(patternField.exists,
                       "The Pattern Replace dialog should not open when there is no selection.")
    }

    func testInsertColumnsExpandsRowAndInjectsPattern() throws {
        let app = try launchNotepad()
        defer { app.terminate() }

        // 16 ASCII bytes 0x41..0x50 ("ABCDEFGHIJKLMNOP"). One row in default 16-byte mode.
        try createBufferWithText(app: app, text: "ABCDEFGHIJKLMNOP")
        try invokeHexEditorMenu(app: app, item: "View in HEX")
        Thread.sleep(forTimeInterval: 1.0)

        let hexTable = app.descendants(matching: .table).matching(identifier: AXID.table).firstMatch
        XCTAssertTrue(hexTable.waitForExistence(timeout: 5))

        // Sanity: byte 4 starts as 'E' = 0x45.
        let firstRow = hexTable.tableRows.element(boundBy: 0)
        XCTAssertTrue(firstRow.waitForExistence(timeout: 5))
        XCTAssertEqual(firstRow.staticTexts.element(boundBy: 5).value as? String, "45",
                       "Byte 4 should start as 0x45 ('E').")

        // Open Insert Columns from the plugin menu.
        try invokeHexEditorMenu(app: app, item: "Insert Columns...")

        // Fill in pattern, count, position.
        let patternField = app.textFields["hex-editor.insertcolumns.pattern"]
        XCTAssertTrue(patternField.waitForExistence(timeout: 5),
                      "Insert Columns pattern field should appear.")
        patternField.replaceFieldText(with: "FF")

        let countField = app.textFields["hex-editor.insertcolumns.count"]
        XCTAssertTrue(countField.waitForExistence(timeout: 3))
        countField.replaceFieldText(with: "2")

        let positionField = app.textFields["hex-editor.insertcolumns.position"]
        XCTAssertTrue(positionField.waitForExistence(timeout: 3))
        positionField.replaceFieldText(with: "4")

        let insertButton = app.buttons["Insert"].firstMatch
        XCTAssertTrue(insertButton.waitForExistence(timeout: 3))
        insertButton.click()

        // A confirmation alert appears with "Inserted N columns…". Dismiss its OK.
        let okAfter = app.buttons["OK"].firstMatch
        XCTAssertTrue(okAfter.waitForExistence(timeout: 3))
        okAfter.click()

        // After insertion at column 4 with count=2 (bpc=1), bytes 0-3 stay, then two 0xFF
        // bytes are injected, then the original bytes 4-15 follow. The row width is now 18.
        // Verify byte 4 and 5 are now 0xff and byte 6 is the original 'E' (0x45).
        let firstRowAfter = hexTable.tableRows.element(boundBy: 0)
        XCTAssertTrue(firstRowAfter.waitForExistence(timeout: 5))
        let byte4Predicate = NSPredicate(format: "value == %@", "ff")
        let waiter4 = expectation(for: byte4Predicate,
                                  evaluatedWith: firstRowAfter.staticTexts.element(boundBy: 5),
                                  handler: nil)
        let waiter5 = expectation(for: byte4Predicate,
                                  evaluatedWith: firstRowAfter.staticTexts.element(boundBy: 6),
                                  handler: nil)
        wait(for: [waiter4, waiter5], timeout: 5)

        XCTAssertEqual(firstRowAfter.staticTexts.element(boundBy: 7).value as? String, "45",
                       "Byte 6 (formerly byte 4 'E' = 0x45) should now sit at column 6.")

        // Single undo reverts the entire insertion (one undo group).
        app.typeKey("z", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.3)
        let firstRowReverted = hexTable.tableRows.element(boundBy: 0)
        let revertPredicate = NSPredicate(format: "value == %@", "45")
        let revertWaiter = expectation(for: revertPredicate,
                                        evaluatedWith: firstRowReverted.staticTexts.element(boundBy: 5),
                                        handler: nil)
        wait(for: [revertWaiter], timeout: 5)
    }

    func testBinaryNotationBitEdit() throws {
        let app = try launchNotepad()
        defer { app.terminate() }

        // "@A" → bytes 0x40 0x41 → binary "01000000" "01000001".
        try createBufferWithText(app: app, text: "@A")
        try invokeHexEditorMenu(app: app, item: "View in HEX")
        Thread.sleep(forTimeInterval: 1.0)

        let hexTable = app.descendants(matching: .table).matching(identifier: AXID.table).firstMatch
        XCTAssertTrue(hexTable.waitForExistence(timeout: 5))
        // The hex view opens with the caret at end-of-paste (the new cursor-preservation
        // behavior). This test exercises bit-editing on byte 0, so navigate there first.
        try positionHexCursorAtZero(app: app, hexTable: hexTable)

        // Switch to binary notation via View in → to Binary
        hexTable.rightClick()
        let viewIn = app.menuItems["View in"].firstMatch
        XCTAssertTrue(viewIn.waitForExistence(timeout: 3))
        viewIn.click()
        let toBinary = app.menuItems["to Binary"].firstMatch
        XCTAssertTrue(toBinary.waitForExistence(timeout: 3))
        toBinary.click()
        Thread.sleep(forTimeInterval: 0.3)

        // Cell 0 should show byte 0 (0x40) as 8 binary chars.
        let firstRow = hexTable.tableRows.element(boundBy: 0)
        XCTAssertTrue(firstRow.waitForExistence(timeout: 5))
        let cell0 = firstRow.staticTexts.element(boundBy: 1)
        let initialPredicate = NSPredicate(format: "value == %@", "01000000")
        let initialWaiter = expectation(for: initialPredicate, evaluatedWith: cell0, handler: nil)
        wait(for: [initialWaiter], timeout: 5)

        // Cursor defaults to byte 0 bit 0 (MSB). Type "1" → set MSB → "11000000" = 0xC0.
        app.typeText("1")
        let cell0AfterFirst = hexTable.tableRows.element(boundBy: 0).staticTexts.element(boundBy: 1)
        let firstPredicate = NSPredicate(format: "value == %@", "11000000")
        let firstWaiter = expectation(for: firstPredicate, evaluatedWith: cell0AfterFirst, handler: nil)
        wait(for: [firstWaiter], timeout: 5)

        // Cursor is now at bit 1 (was a 1, since 0x40 = 01000000 + bit 0 set = 11000000).
        // Type "0" → clear bit 1 → 10000000.
        app.typeText("0")
        // Cursor at bit 2 (was 0). Type "1" → 10100000 = 0xA0.
        app.typeText("1")
        let cell0AfterThree = hexTable.tableRows.element(boundBy: 0).staticTexts.element(boundBy: 1)
        let thirdPredicate = NSPredicate(format: "value == %@", "10100000")
        let thirdWaiter = expectation(for: thirdPredicate, evaluatedWith: cell0AfterThree, handler: nil)
        wait(for: [thirdWaiter], timeout: 5)

        // Three undos to revert each bit edit before terminate.
        app.typeKey("z", modifierFlags: .command)
        app.typeKey("z", modifierFlags: .command)
        app.typeKey("z", modifierFlags: .command)
    }

    func testGotoOffsetMovesCursor() throws {
        let app = try launchNotepad()
        defer { app.terminate() }

        // 16 ASCII bytes 0x41 ('A') through 0x50 ('P').
        try createBufferWithText(app: app, text: "ABCDEFGHIJKLMNOP")
        try invokeHexEditorMenu(app: app, item: "View in HEX")
        Thread.sleep(forTimeInterval: 1.0)

        let hexTable = app.descendants(matching: .table).matching(identifier: AXID.table).firstMatch
        XCTAssertTrue(hexTable.waitForExistence(timeout: 5))

        let firstRow = hexTable.tableRows.element(boundBy: 0)
        XCTAssertTrue(firstRow.waitForExistence(timeout: 5))
        // Sanity: byte 5 starts as 'F' (0x46). Cell index 6 in the row's flat staticTexts list
        // (0=offset, 1..8=byte0..byte7, ...).
        let byte5 = firstRow.staticTexts.element(boundBy: 6)
        XCTAssertEqual(byte5.value as? String, "46",
                       "Byte 5 should start as 0x46 ('F') before the Goto edit.")

        // Right-click → Go to Offset…
        hexTable.rightClick()
        let gotoItem = app.menuItems["Go to Offset…"]
        XCTAssertTrue(gotoItem.waitForExistence(timeout: 3))
        gotoItem.click()

        let dialogField = app.textFields["hex-editor.goto.input"]
        XCTAssertTrue(dialogField.waitForExistence(timeout: 3))
        dialogField.replaceFieldText(with: "5")
        XCTAssertEqual(dialogField.value as? String, "5",
                       "Goto field should hold '5' before clicking Go.")

        let goButton = app.buttons["Go"].firstMatch
        XCTAssertTrue(goButton.waitForExistence(timeout: 3))
        goButton.click()
        XCTAssertTrue(dialogField.waitForNonExistence(timeout: 5),
                      "Goto dialog should dismiss after clicking Go.")

        // Cursor is now at offset 5. Type "00" to overwrite byte 5 → 0x00.
        app.typeText("00")

        let firstRowAfter = hexTable.tableRows.element(boundBy: 0)
        let byte5After = firstRowAfter.staticTexts.element(boundBy: 6)
        let predicate = NSPredicate(format: "value == %@", "00")
        let waiter = expectation(for: predicate, evaluatedWith: byte5After, handler: nil)
        wait(for: [waiter], timeout: 5)

        // Byte 4 must remain 0x45 ('E') — proves the cursor really landed on byte 5, not byte 4.
        let byte4After = firstRowAfter.staticTexts.element(boundBy: 5)
        XCTAssertEqual(byte4After.value as? String, "45",
                       "Byte 4 must be untouched — Goto should land precisely on byte 5.")

        // Two undos to restore both nibble edits before terminate (no save prompt).
        app.typeKey("z", modifierFlags: .command)
        app.typeKey("z", modifierFlags: .command)
    }

    func testGotoOffsetRejectsGarbage() throws {
        let app = try launchNotepad()
        defer { app.terminate() }

        try createBufferWithText(app: app, text: "ABCD")
        try invokeHexEditorMenu(app: app, item: "View in HEX")
        Thread.sleep(forTimeInterval: 1.0)

        let hexTable = app.descendants(matching: .table).matching(identifier: AXID.table).firstMatch
        XCTAssertTrue(hexTable.waitForExistence(timeout: 5))

        hexTable.rightClick()
        app.menuItems["Go to Offset…"].click()

        let dialogField = app.textFields["hex-editor.goto.input"]
        XCTAssertTrue(dialogField.waitForExistence(timeout: 3))
        dialogField.replaceFieldText(with: "wat")
        app.buttons["Go"].firstMatch.click()

        // Plugin's NSAlert validation error should be presented; dismiss it.
        let okAfter = app.buttons["OK"].firstMatch
        XCTAssertTrue(okAfter.waitForExistence(timeout: 3),
                      "Invalid Goto input should surface an OK-only error dialog.")
        okAfter.click()

        // Hex view should still be intact and the buffer untouched.
        let firstRow = hexTable.tableRows.element(boundBy: 0)
        XCTAssertTrue(firstRow.waitForExistence(timeout: 5))
        let byte0 = firstRow.staticTexts.element(boundBy: 1)
        XCTAssertEqual(byte0.value as? String, "41",
                       "Byte 0 must remain 0x41 — the rejected Goto should not change buffer state.")
    }

    func testInvalidAddressWidthShowsErrorAndKeepsOriginal() throws {
        let app = try launchNotepad()
        defer { app.terminate() }

        try createBufferWithText(app: app, text: "X")
        try invokeHexEditorMenu(app: app, item: "View in HEX")
        Thread.sleep(forTimeInterval: 1.0)

        let hexTable = app.descendants(matching: .table).matching(identifier: AXID.table).firstMatch
        XCTAssertTrue(hexTable.waitForExistence(timeout: 5))

        hexTable.rightClick()
        app.menuItems["Address Width..."].click()

        let dialogField = app.textFields["hex-editor.dialog.input"]
        XCTAssertTrue(dialogField.waitForExistence(timeout: 3))
        dialogField.replaceFieldText(with: "99")  // out of range
        app.buttons["OK"].firstMatch.click()

        // Plugin's NSAlert validation error appears next; dismiss its OK.
        let okAfter = app.buttons["OK"].firstMatch
        XCTAssertTrue(okAfter.waitForExistence(timeout: 3))
        okAfter.click()

        // Offset gutter must still be 8 digits — the invalid value was rejected.
        let firstRow = hexTable.tableRows.element(boundBy: 0)
        XCTAssertTrue(firstRow.waitForExistence(timeout: 5))
        let offsetCell = firstRow.staticTexts.element(boundBy: 0)
        XCTAssertEqual(offsetCell.value as? String, "00000000",
                       "Invalid Address Width should be rejected and original 8-digit width preserved.")
    }

    // MARK: - Initial open state
    //
    // These tests catch the class of regressions where the hex view opens with the
    // wrong cursor or with row 0 hidden behind the column-header bar. The earlier
    // suite asserted only on AX-tree existence (`tableRows.element(boundBy: 0)`),
    // which passes whether row 0 is visible or clipped — and never observed the
    // hex caret position because no AX surface exposed it. The diagnostic element
    // (HexCursorDiagnosticView) plus visibility checks below close those gaps.

    func testRow0HittableOnInitialOpen() throws {
        let app = try launchNotepad()
        defer { app.terminate() }
        try createBufferWithText(app: app, text: "Hello, hex world! 0123ABCD")
        try invokeHexEditorMenu(app: app, item: "View in HEX")

        let hexTable = app.descendants(matching: .table).matching(identifier: AXID.table).firstMatch
        XCTAssertTrue(hexTable.waitForExistence(timeout: 5))

        let firstRow = hexTable.tableRows.element(boundBy: 0)
        XCTAssertTrue(firstRow.waitForExistence(timeout: 3))
        // The actual visibility check — `waitForExistence` alone passes even when
        // the row is fully clipped behind the header. `isHittable` is true only
        // when the element's interactive area is on-screen and unobscured by other
        // elements (such as the floating column-header bar).
        XCTAssertTrue(firstRow.isHittable,
                      "Row 0 must be fully visible on initial open, not clipped behind the column-header bar.")
        // Stronger guard: row 0 must extend at least its full height vertically.
        // A "sliver" row (top hidden behind the header, only a few pixels visible)
        // would have a frame.height much smaller than the row height.
        XCTAssertGreaterThan(firstRow.frame.height, 10,
                             "Row 0 frame height \(firstRow.frame.height) is too small — row is being clipped.")
    }

    func testHexCursorMatchesScintillaCaretAfterPaste() throws {
        // After createBufferWithText pastes via Edit > Paste, Scintilla's caret
        // sits at the end of the pasted text. Opening the hex view must mirror
        // that caret position into activeByteOffset (no selection state).
        let text = "ABCDEFGHIJKLMNOP"   // 16 bytes
        let app = try launchNotepad()
        defer { app.terminate() }
        try createBufferWithText(app: app, text: text)
        try invokeHexEditorMenu(app: app, item: "View in HEX")

        let hexTable = app.descendants(matching: .table).matching(identifier: AXID.table).firstMatch
        XCTAssertTrue(hexTable.waitForExistence(timeout: 5))

        let cursor = HexCursorState.read(from: app)
        XCTAssertNotNil(cursor, "Cursor diagnostic AX element should be present after the hex view opens.")
        XCTAssertEqual(cursor?.offset, text.count,
                       "Hex cursor must land at the Scintilla caret offset (\(text.count)), got \(cursor?.offset ?? -1).")
        XCTAssertFalse(cursor?.hasSelection ?? true,
                       "No Scintilla selection ⇒ no hex selection.")
    }

    func testHexSelectionMirrorsScintillaSelectAll() throws {
        // Paste, then Cmd+A to select the whole buffer in Scintilla. The hex view
        // must mirror selStart=0, selEnd=length, and place the caret at the end.
        let text = "0123456789ABCDEFGHIJ"   // 20 bytes
        let app = try launchNotepad()
        defer { app.terminate() }
        try createBufferWithText(app: app, text: text)

        // After Edit > Paste, keyboard focus is on the SplitGroup, not Scintilla
        // itself, so Cmd+A and Edit > Select All silently no-op against the source
        // text. Explicitly click Scintilla to make it first responder; then both
        // keyboard and menu actions route to it. Verified by inspecting the AX
        // hierarchy + the diagnostic AX (sciSelStart/End match expected after
        // this click; before it, Scintilla's state never changed).
        try focusScintilla(in: app)

        // Cmd+A now reaches Scintilla because it's the first responder.
        app.typeKey("a", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.3)

        try invokeHexEditorMenu(app: app, item: "View in HEX")
        let hexTable = app.descendants(matching: .table).matching(identifier: AXID.table).firstMatch
        XCTAssertTrue(hexTable.waitForExistence(timeout: 5))

        let cursor = HexCursorState.read(from: app)
        XCTAssertNotNil(cursor)
        let diag = cursor?.debugDescription ?? "(no diagnostic)"
        XCTAssertTrue(cursor?.hasSelection ?? false,
                      "Scintilla had a selection; hex view should mirror it. Diagnostic: \(diag)")
        XCTAssertEqual(cursor?.selStart, 0, "Selection should start at 0. Diagnostic: \(diag)")
        XCTAssertEqual(cursor?.selEnd, text.count, "Selection should end at \(text.count). Diagnostic: \(diag)")
        XCTAssertEqual(cursor?.offset, text.count, "Hex caret should land at end of selection. Diagnostic: \(diag)")
    }

    func testStatusLabelGlyphsNotClipped() throws {
        // The status row above the column headers reports buffer size. Earlier the
        // label's frame height was hardcoded at 16pt while the font's line-height
        // could exceed that, so descender glyphs ('y' in "Showing N bytes.") got
        // clipped at the bottom. The layout now sizes the label from the font's
        // ascender+descender extent; this test guards against future regressions
        // by asserting the label's rendered frame is at least as tall as the font
        // it must display.
        let app = try launchNotepad()
        defer { app.terminate() }
        try createBufferWithText(app: app, text: "Hello, hex world!")
        try invokeHexEditorMenu(app: app, item: "View in HEX")

        let hexTable = app.descendants(matching: .table).matching(identifier: AXID.table).firstMatch
        XCTAssertTrue(hexTable.waitForExistence(timeout: 5))

        let state = HexCursorState.read(from: app)
        XCTAssertNotNil(state)
        let frameH = state?.statusFrameHeight ?? 0
        let fontH = state?.statusFontLineHeight ?? .infinity
        XCTAssertGreaterThanOrEqual(frameH, fontH,
            "Status label frame (\(frameH)pt) must be at least as tall as its font's line-height (\(fontH)pt) so descenders don't clip.")
    }

    func testCanReachRow0AfterDeepCursorOpen() throws {
        // Paste a buffer big enough that the Scintilla caret (which lands at end
        // of paste) puts the hex view's initial scroll deep into the file. Then
        // navigate back to offset 0 via Cmd+L (Go to Offset) and assert row 0 is
        // reachable. This catches the "scrollable range excludes row 0" class of
        // regression that survived earlier suites because no test ever opened
        // far-down then asked for row 0.
        let longText = String(repeating: "0123456789ABCDEF", count: 64)   // 1024 bytes
        let app = try launchNotepad()
        defer { app.terminate() }
        try createBufferWithText(app: app, text: longText)
        try invokeHexEditorMenu(app: app, item: "View in HEX")

        let hexTable = app.descendants(matching: .table).matching(identifier: AXID.table).firstMatch
        XCTAssertTrue(hexTable.waitForExistence(timeout: 5))

        // Initial state: caret deep, row 0 likely off-screen (not hittable).
        let initialCursor = HexCursorState.read(from: app)
        XCTAssertEqual(initialCursor?.offset, longText.count,
                       "Initial hex caret should match Scintilla caret (end of paste, \(longText.count)).")

        // Navigate to offset 0 via right-click → Go to Offset… (matches the
        // pattern used by other goto-bearing tests in this suite).
        hexTable.rightClick()
        let gotoItem = app.menuItems["Go to Offset…"]
        XCTAssertTrue(gotoItem.waitForExistence(timeout: 3))
        gotoItem.click()
        let gotoInput = app.textFields["hex-editor.goto.input"]
        XCTAssertTrue(gotoInput.waitForExistence(timeout: 5),
                      "Go to Offset input should appear after invoking the menu item.")
        gotoInput.replaceFieldText(with: "0")
        let goButton = app.buttons["Go"].firstMatch
        XCTAssertTrue(goButton.waitForExistence(timeout: 3))
        goButton.click()
        XCTAssertTrue(gotoInput.waitForNonExistence(timeout: 5),
                      "Goto dialog should dismiss after clicking Go.")

        // Now row 0 must be visible and hittable.
        let firstRow = hexTable.tableRows.element(boundBy: 0)
        XCTAssertTrue(firstRow.waitForExistence(timeout: 3))
        XCTAssertTrue(firstRow.isHittable,
                      "After navigating to offset 0, row 0 must be visible and hittable.")
        let postCursor = HexCursorState.read(from: app)
        XCTAssertEqual(postCursor?.offset, 0,
                       "After Cmd+L → 0, the hex caret should be at offset 0.")
    }

    // MARK: - Localization cascade
    //
    // Drive the runtime localization chain by force-launching the host with
    // -AppleLanguages '(<tag>)' and asserting the About dialog's diagnostic line
    // ("about.localeTag" key) shows the file we expect was loaded. Each shipped
    // .strings file declares its own tag, so:
    //   - en        → "Strings: en"                (canonical en.strings)
    //   - en-GB     → "Strings: en-GB"             (regional override layer 1)
    //   - en-US     → "Strings: en-US"             (regional override layer 1)
    //   - de        → "Strings: de"                (full German translation)
    //   - fr (etc.) → "Strings: (embedded)"        (no shipped file → defaults)
    //
    // For en-GB / en-US, only the localeTag is overridden — every other key
    // cascades to en.strings, which we verify by also checking that the body
    // text is the English about.body rather than something else.

    func testLocalizationCascadeDefaultEnglish() throws {
        let app = try launchNotepad(language: "en")
        defer { app.terminate() }
        try assertAboutDialog(app: app, helpItem: "Help...",
                              expectedTag: "Strings: en",
                              expectedBodyContains: "Native macOS port")
    }

    func testLocalizationCascadeBritishEnglish() throws {
        let app = try launchNotepad(language: "en-GB")
        defer { app.terminate() }
        // en-GB only overrides the locale tag; body cascades to en.strings.
        try assertAboutDialog(app: app, helpItem: "Help...",
                              expectedTag: "Strings: en-GB",
                              expectedBodyContains: "Native macOS port")
    }

    func testLocalizationCascadeAmericanEnglish() throws {
        let app = try launchNotepad(language: "en-US")
        defer { app.terminate() }
        // en-US only overrides the locale tag; body cascades to en.strings.
        try assertAboutDialog(app: app, helpItem: "Help...",
                              expectedTag: "Strings: en-US",
                              expectedBodyContains: "Native macOS port")
    }

    func testLocalizationCascadeGerman() throws {
        let app = try launchNotepad(language: "de")
        defer { app.terminate() }
        // German is a full translation, so the leaf menu item is "Hilfe..." and
        // the body text is the German about.body.
        try assertAboutDialog(app: app, helpItem: "Hilfe...",
                              expectedTag: "Strings: de",
                              expectedBodyContains: "Native macOS-Portierung")
    }

    func testLocalizationCascadeUnsupportedFallsBackToEmbedded() throws {
        // "fr" is unsupported — no Localizable.fr.strings ships. The cascade
        // chain ends up empty, L() falls through to the embedded English
        // defaults table, and the diagnostic tag is "Strings: (embedded)".
        let app = try launchNotepad(language: "fr")
        defer { app.terminate() }
        try assertAboutDialog(app: app, helpItem: "Help...",
                              expectedTag: "Strings: (embedded)",
                              expectedBodyContains: "Native macOS port")
    }

    // MARK: - Rectangular (block) selection — v1.1.0

    /// Bootstraps a 1×1 rect at the caret then extends to (1+addCols)×(1+addRows)
    /// via Shift+Option+arrow. Caller must have positioned the cursor at the rect's
    /// intended top-left corner and have the hex view focused before calling.
    /// The first Shift+Option+Right press creates the 1×1 anchor + advances one
    /// column = 2×1 rect, so for a final width W you need (W-1) Right presses.
    private func extendRectViaKeyboard(app: XCUIApplication, addCols: Int, addRows: Int) {
        for _ in 0..<addCols {
            app.typeKey(.rightArrow, modifierFlags: [.shift, .option])
        }
        for _ in 0..<addRows {
            app.typeKey(.downArrow, modifierFlags: [.shift, .option])
        }
        Thread.sleep(forTimeInterval: 0.2)
    }

    /// Translates a byte-offset-within-row into the AX index of the cell that holds
    /// it under `row.staticTexts.element(boundBy:)`. The hex table inserts an empty
    /// "midspacer" column between bytes 7 and 8 (for the default 16-byte row) to
    /// draw the visual half-row gap; that empty cell counts as one static text in
    /// AX traversal, so any byte at or past the midpoint shifts by +1. The offset
    /// column also occupies index 0, so add 1 unconditionally.
    /// See [HexEditor.mm: addHexCellColumns](../../macos/src/HexEditor.mm) for the
    /// canonical column layout: `offset, cell00..cell0(M-1), midspacer, cell0M..cell0F, spacer, ascii`.
    private func cellIndex(forByte byte: Int, cellsPerRow: Int = 16) -> Int {
        let midpoint = cellsPerRow / 2
        let offsetSlot = 1
        return byte < midpoint ? offsetSlot + byte : offsetSlot + byte + 1
    }

    /// Clicks an Edit-menu item (Cut / Copy / Paste / etc.). Existing tests use this
    /// route rather than the Cmd+letter shortcuts because XCUI key delivery to the
    /// hex view is reliable for Cmd+key only when the host's menu binding does the
    /// work — synthesizing a raw Cmd+C event into the hex view often hits NSTableView's
    /// default `copy:` (which copies row indices, not the rect data) instead of
    /// dispatching through the responder chain to `hexCopy:`.
    private func invokeEditMenuItem(app: XCUIApplication, item: String) {
        let editMenu = app.menuBars.menuBarItems["Edit"]
        XCTAssertTrue(editMenu.waitForExistence(timeout: 5))
        editMenu.click()
        let menuItem = app.menuBars.menuItems[item]
        XCTAssertTrue(menuItem.waitForExistence(timeout: 5),
                      "Edit > \(item) should be visible.")
        XCTAssertTrue(menuItem.isEnabled, "Edit > \(item) should be enabled.")
        menuItem.click()
        Thread.sleep(forTimeInterval: 0.3)
    }

    func testRectKeyboardCreatesAndExtendsRectangle() throws {
        let app = try launchNotepad()
        defer { app.terminate() }

        // 32 bytes = two full 16-byte rows, so a 4×2 rect fits comfortably.
        try createBufferWithText(app: app, text: "ABCDEFGHIJKLMNOPabcdefghijklmnop")
        try invokeHexEditorMenu(app: app, item: "View in HEX")
        Thread.sleep(forTimeInterval: 1.0)

        let hexTable = app.descendants(matching: .table).matching(identifier: AXID.table).firstMatch
        XCTAssertTrue(hexTable.waitForExistence(timeout: 5))
        try positionHexCursorAtZero(app: app, hexTable: hexTable)

        // No rect yet.
        let preState = HexCursorState.read(from: app)
        XCTAssertNotNil(preState, "Diagnostic AX must report cursor state.")
        XCTAssertEqual(preState?.rectActive, false, "No rect should be active before extension.")

        // First Shift+Option+Right bootstraps a 1×1 rect at offset 0, then advances
        // the far corner one column → 2×1 rect.
        app.typeKey(.rightArrow, modifierFlags: [.shift, .option])
        Thread.sleep(forTimeInterval: 0.2)
        let after1 = HexCursorState.read(from: app)
        XCTAssertEqual(after1?.rectActive, true, "After one Shift+Option+Right, a rect should be active.")
        XCTAssertEqual(after1?.rectOrigin, 0)
        XCTAssertEqual(after1?.rectWidth, 2, "Width should be 2 after one extension press.")
        XCTAssertEqual(after1?.rectHeight, 1)
        XCTAssertEqual(after1?.rectOriginPane, "Hex")

        // Two more Right + one Down → 4 wide, 2 tall.
        app.typeKey(.rightArrow, modifierFlags: [.shift, .option])
        app.typeKey(.rightArrow, modifierFlags: [.shift, .option])
        app.typeKey(.downArrow, modifierFlags: [.shift, .option])
        Thread.sleep(forTimeInterval: 0.2)
        let after4x2 = HexCursorState.read(from: app)
        XCTAssertEqual(after4x2?.rectWidth, 4)
        XCTAssertEqual(after4x2?.rectHeight, 2)

        // Plain Left arrow (no modifiers) collapses the rect — clearAllByteSelections
        // fires on the linear-arrow path.
        app.typeKey(.leftArrow, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.2)
        let afterCollapse = HexCursorState.read(from: app)
        XCTAssertEqual(afterCollapse?.rectActive, false,
                       "Plain arrow should collapse the rect to a caret. State: \(afterCollapse?.debugDescription ?? "nil")")
    }

    func testRectCopyPasteRoundTripPreservesBytes() throws {
        let app = try launchNotepad()
        defer { app.terminate() }

        // 32 bytes laid out as two 16-byte rows of distinct content so we can spot
        // exactly which bytes moved. Row 0 = "ABCDEFGHIJKLMNOP" (0x41..0x50);
        // row 1 = "abcdefghijklmnop" (0x61..0x70).
        try createBufferWithText(app: app, text: "ABCDEFGHIJKLMNOPabcdefghijklmnop")
        try invokeHexEditorMenu(app: app, item: "View in HEX")
        Thread.sleep(forTimeInterval: 1.0)

        let hexTable = app.descendants(matching: .table).matching(identifier: AXID.table).firstMatch
        XCTAssertTrue(hexTable.waitForExistence(timeout: 5))
        try positionHexCursorAtZero(app: app, hexTable: hexTable)

        // Build a 4×2 rect at offset 0 covering "ABCD" (bytes 0..3) on row 0 and
        // "abcd" (bytes 16..19) on row 1.
        extendRectViaKeyboard(app: app, addCols: 3, addRows: 1)
        let srcRect = HexCursorState.read(from: app)
        XCTAssertEqual(srcRect?.rectWidth, 4)
        XCTAssertEqual(srcRect?.rectHeight, 2)

        invokeEditMenuItem(app: app, item: "Copy")

        // Move the cursor to byte offset 8 via Goto (which now collapses the rect)
        // and rebuild a same-shape rect at the new origin.
        try positionHexCursorAt(app: app, hexTable: hexTable, offset: 8)
        extendRectViaKeyboard(app: app, addCols: 3, addRows: 1)
        let destRect = HexCursorState.read(from: app)
        XCTAssertEqual(destRect?.rectWidth, 4)
        XCTAssertEqual(destRect?.rectHeight, 2)
        XCTAssertEqual(destRect?.rectOrigin, 8)

        invokeEditMenuItem(app: app, item: "Paste")
        Thread.sleep(forTimeInterval: 0.3)

        // After paste, row 0 cols 8..11 should be "ABCD" (0x41..0x44) and row 1 cols
        // 8..11 should be "abcd" (0x61..0x64). Cell indices in staticTexts: 0=offset,
        // 1..16 = bytes 0..15 of that row.
        let row0 = hexTable.tableRows.element(boundBy: 0)
        XCTAssertTrue(row0.waitForExistence(timeout: 5))
        let row1 = hexTable.tableRows.element(boundBy: 1)
        XCTAssertTrue(row1.waitForExistence(timeout: 5))

        let row0byte8 = row0.staticTexts.element(boundBy: cellIndex(forByte: 8))
        let row1byte8 = row1.staticTexts.element(boundBy: cellIndex(forByte: 8))
        wait(for: [
            expectation(for: NSPredicate(format: "value == %@", "41"), evaluatedWith: row0byte8, handler: nil),
            expectation(for: NSPredicate(format: "value == %@", "61"), evaluatedWith: row1byte8, handler: nil),
        ], timeout: 5)

        let row0byte11 = row0.staticTexts.element(boundBy: cellIndex(forByte: 11))
        let row1byte11 = row1.staticTexts.element(boundBy: cellIndex(forByte: 11))
        wait(for: [
            expectation(for: NSPredicate(format: "value == %@", "44"), evaluatedWith: row0byte11, handler: nil),
            expectation(for: NSPredicate(format: "value == %@", "64"), evaluatedWith: row1byte11, handler: nil),
        ], timeout: 5)

        // Bytes outside the rect (col 12 'M' = 0x4D in row 0) must be untouched.
        let row0byte12 = row0.staticTexts.element(boundBy: cellIndex(forByte: 12))
        wait(for: [
            expectation(for: NSPredicate(format: "value == %@", "4d"), evaluatedWith: row0byte12, handler: nil),
        ], timeout: 5)
    }

    func testRectDeleteZeroFillsBytes() throws {
        let app = try launchNotepad()
        defer { app.terminate() }

        try createBufferWithText(app: app, text: "ABCDEFGHIJKLMNOPabcdefghijklmnop")
        try invokeHexEditorMenu(app: app, item: "View in HEX")
        Thread.sleep(forTimeInterval: 1.0)

        let hexTable = app.descendants(matching: .table).matching(identifier: AXID.table).firstMatch
        XCTAssertTrue(hexTable.waitForExistence(timeout: 5))
        try positionHexCursorAtZero(app: app, hexTable: hexTable)

        // 4×2 rect at offset 4 → covers "EFGH" + "efgh".
        try positionHexCursorAt(app: app, hexTable: hexTable, offset: 4)
        extendRectViaKeyboard(app: app, addCols: 3, addRows: 1)
        let rect = HexCursorState.read(from: app)
        XCTAssertEqual(rect?.rectWidth, 4)
        XCTAssertEqual(rect?.rectHeight, 2)

        // Edit > Cut deletes the rect (and copies it to the clipboard — same
        // observable byte-state as Delete, more reliable than the right-click
        // context menu under XCUI which intermittently hits "open menu during
        // menu traversal" retry timeouts).
        invokeEditMenuItem(app: app, item: "Cut")

        // Bytes 4..7 in row 0 should now be 00; row 1 cols 4..7 same.
        let row0 = hexTable.tableRows.element(boundBy: 0)
        let row1 = hexTable.tableRows.element(boundBy: 1)
        wait(for: [
            expectation(for: NSPredicate(format: "value == %@", "00"),
                        evaluatedWith: row0.staticTexts.element(boundBy: cellIndex(forByte: 4)), handler: nil),
            expectation(for: NSPredicate(format: "value == %@", "00"),
                        evaluatedWith: row0.staticTexts.element(boundBy: cellIndex(forByte: 7)), handler: nil),
            expectation(for: NSPredicate(format: "value == %@", "00"),
                        evaluatedWith: row1.staticTexts.element(boundBy: cellIndex(forByte: 4)), handler: nil),
            expectation(for: NSPredicate(format: "value == %@", "00"),
                        evaluatedWith: row1.staticTexts.element(boundBy: cellIndex(forByte: 7)), handler: nil),
        ], timeout: 5)
        // Outside the rect: byte 3 = 'D' = 0x44, byte 8 = 'I' = 0x49 in row 0.
        wait(for: [
            expectation(for: NSPredicate(format: "value == %@", "44"),
                        evaluatedWith: row0.staticTexts.element(boundBy: cellIndex(forByte: 3)), handler: nil),
            expectation(for: NSPredicate(format: "value == %@", "49"),
                        evaluatedWith: row0.staticTexts.element(boundBy: cellIndex(forByte: 8)), handler: nil),
        ], timeout: 5)
    }

    func testRectPatternReplaceFillsPerRow() throws {
        let app = try launchNotepad()
        defer { app.terminate() }

        try createBufferWithText(app: app, text: "ABCDEFGHIJKLMNOPabcdefghijklmnop")
        try invokeHexEditorMenu(app: app, item: "View in HEX")
        Thread.sleep(forTimeInterval: 1.0)

        let hexTable = app.descendants(matching: .table).matching(identifier: AXID.table).firstMatch
        XCTAssertTrue(hexTable.waitForExistence(timeout: 5))
        try positionHexCursorAtZero(app: app, hexTable: hexTable)

        // 4×2 rect at offset 0 → covers row 0 cols 0..3 and row 1 cols 0..3.
        extendRectViaKeyboard(app: app, addCols: 3, addRows: 1)

        try invokeHexEditorMenu(app: app, item: "Pattern Replace...")
        let patternField = app.textFields["hex-editor.patternreplace.pattern"]
        XCTAssertTrue(patternField.waitForExistence(timeout: 5))
        patternField.replaceFieldText(with: "DE AD")

        let replaceButton = app.buttons["Replace"].firstMatch
        XCTAssertTrue(replaceButton.waitForExistence(timeout: 3))
        replaceButton.click()

        // Confirmation alert "Filled 4 × 2 rectangle (8 bytes)…". Dismiss with OK.
        let okButton = app.buttons["OK"].firstMatch
        XCTAssertTrue(okButton.waitForExistence(timeout: 3))
        okButton.click()

        // Per-row restart: each row's 4 bytes = DE AD DE AD (pattern restarts at
        // col 0 of each row, NOT continuous across rows).
        let row0 = hexTable.tableRows.element(boundBy: 0)
        let row1 = hexTable.tableRows.element(boundBy: 1)
        wait(for: [
            expectation(for: NSPredicate(format: "value == %@", "de"),
                        evaluatedWith: row0.staticTexts.element(boundBy: 1), handler: nil),
            expectation(for: NSPredicate(format: "value == %@", "ad"),
                        evaluatedWith: row0.staticTexts.element(boundBy: 2), handler: nil),
            expectation(for: NSPredicate(format: "value == %@", "de"),
                        evaluatedWith: row0.staticTexts.element(boundBy: 3), handler: nil),
            expectation(for: NSPredicate(format: "value == %@", "ad"),
                        evaluatedWith: row0.staticTexts.element(boundBy: 4), handler: nil),
            // Row 1 also starts with DE — proves per-row restart, not continuous fill.
            expectation(for: NSPredicate(format: "value == %@", "de"),
                        evaluatedWith: row1.staticTexts.element(boundBy: 1), handler: nil),
            expectation(for: NSPredicate(format: "value == %@", "ad"),
                        evaluatedWith: row1.staticTexts.element(boundBy: 2), handler: nil),
        ], timeout: 5)
    }

    func testRectPasteShapeMismatchShowsDialog() throws {
        let app = try launchNotepad()
        defer { app.terminate() }

        try createBufferWithText(app: app, text: "ABCDEFGHIJKLMNOPabcdefghijklmnop")
        try invokeHexEditorMenu(app: app, item: "View in HEX")
        Thread.sleep(forTimeInterval: 1.0)

        let hexTable = app.descendants(matching: .table).matching(identifier: AXID.table).firstMatch
        XCTAssertTrue(hexTable.waitForExistence(timeout: 5))
        try positionHexCursorAtZero(app: app, hexTable: hexTable)

        // Source: 4×2 rect at offset 0.
        extendRectViaKeyboard(app: app, addCols: 3, addRows: 1)
        invokeEditMenuItem(app: app, item: "Copy")

        // Destination: a 2×2 rect at offset 8 — wrong shape (need 4×2 to match).
        try positionHexCursorAt(app: app, hexTable: hexTable, offset: 8)
        extendRectViaKeyboard(app: app, addCols: 1, addRows: 1)
        let dest = HexCursorState.read(from: app)
        XCTAssertEqual(dest?.rectWidth, 2)
        XCTAssertEqual(dest?.rectHeight, 2)

        // Paste should pop up the strict-shape error dialog naming the required
        // dimensions (4 × 2). The dialog text is the expanded form of
        // paste.rect.errorShapeMismatch with the required width / height.
        invokeEditMenuItem(app: app, item: "Paste")
        let dialog = app.dialogs.firstMatch
        XCTAssertTrue(dialog.waitForExistence(timeout: 5),
                      "Strict-shape paste should surface an error dialog for a mismatched destination.")
        let dialogText = dialog.staticTexts.allElementsBoundByIndex.compactMap { $0.value as? String }.joined(separator: " | ")
        XCTAssertTrue(dialogText.contains("4 bytes wide") && dialogText.contains("2 bytes high"),
                      "Dialog should name required width × height. Got: \(dialogText)")
        dialog.buttons["OK"].click()
        XCTAssertTrue(dialog.waitForNonExistence(timeout: 5))

        // Bytes at offset 8 should be untouched ('I' = 0x49) since the paste was rejected.
        let row0 = hexTable.tableRows.element(boundBy: 0)
        wait(for: [
            expectation(for: NSPredicate(format: "value == %@", "49"),
                        evaluatedWith: row0.staticTexts.element(boundBy: cellIndex(forByte: 8)), handler: nil),
        ], timeout: 5)
    }

    // MARK: - Pasteboard attack regression net (v1.1.1+)
    //
    // These tests pipe deliberately malformed custom-UTI payloads through the
    // system pasteboard, then trigger Edit > Paste in the hex view, and verify
    // (a) the plugin doesn't crash (XCTest catches any process exit), and (b)
    // the destination buffer is unchanged. The full attack matrix lives in the
    // libFuzzer suite under macos/fuzz/; these three are representative
    // regression-net cases so a future change that breaks decodeRectPayload's
    // bounds checks fails the regular UI suite, not just the opt-in fuzz pass.

    /// Custom UTI that the plugin's rectangular copy/paste uses. Must match
    /// kHexRectPasteboardType in [HexEditor.mm](../../macos/src/HexEditor.mm).
    private static let rectPasteboardType =
        NSPasteboard.PasteboardType("org.notepad-plus-plus.HexEditor.rectangular")

    /// Run a single pasteboard-attack case: open a known buffer, place
    /// `payload` on the pasteboard under the rectangular UTI, trigger Edit >
    /// Paste, then assert the buffer's first row is unchanged. We do NOT
    /// create a destination rect — a malformed payload should fall through
    /// the rect path silently (no crash, no dialog, no edit) and be picked
    /// up only if the public-text fallback exists, which we explicitly clear.
    private func runMalformedPastePayload(_ payload: Data, label: String) throws {
        let app = try launchNotepad()
        defer { app.terminate() }

        try createBufferWithText(app: app, text: "ABCDEFGHIJKLMNOPabcdefghijklmnop")
        try invokeHexEditorMenu(app: app, item: "View in HEX")
        Thread.sleep(forTimeInterval: 1.0)

        let hexTable = app.descendants(matching: .table).matching(identifier: AXID.table).firstMatch
        XCTAssertTrue(hexTable.waitForExistence(timeout: 5))
        try positionHexCursorAtZero(app: app, hexTable: hexTable)

        // Wipe the pasteboard to nothing-but-the-payload, so the public-text
        // fallback can't accidentally rescue the paste with parseable text.
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(payload, forType: Self.rectPasteboardType)

        invokeEditMenuItem(app: app, item: "Paste")

        // Buffer's first row must be intact — byte 0 = 'A' = 0x41,
        // byte 8 = 'I' = 0x49, byte 15 = 'P' = 0x50.
        let row0 = hexTable.tableRows.element(boundBy: 0)
        wait(for: [
            expectation(for: NSPredicate(format: "value == %@", "41"),
                        evaluatedWith: row0.staticTexts.element(boundBy: cellIndex(forByte: 0)),
                        handler: nil),
            expectation(for: NSPredicate(format: "value == %@", "49"),
                        evaluatedWith: row0.staticTexts.element(boundBy: cellIndex(forByte: 8)),
                        handler: nil),
            expectation(for: NSPredicate(format: "value == %@", "50"),
                        evaluatedWith: row0.staticTexts.element(boundBy: cellIndex(forByte: 15)),
                        handler: nil),
        ], timeout: 5)
        // Belt-and-braces: if the malformed payload somehow opened an alert
        // dialog, dismiss it so the test cleans up rather than leaving a
        // floating window for the next test.
        let possibleDialog = app.dialogs.firstMatch
        if possibleDialog.exists {
            possibleDialog.buttons["OK"].click()
        }
        XCTAssertTrue(true, "Pasteboard attack '\(label)' did not crash the host or modify the buffer.")
    }

    // MARK: - Cross-app paste from external hex tools (v1.1.1+)
    //
    // Verifies that text on the system pasteboard formatted by common
    // debuggers / hex viewers (lldb, gdb, xxd, x64dbg, IDA, C-string escapes,
    // C array literals) parses correctly when pasted into the hex view.
    // The full format catalogue is unit-tested in HexCore — these UI tests
    // are the in-suite end-to-end check that the clipboard plumbing applies
    // the preprocessor on the real Edit > Paste path.

    func testCrossAppPaste_LldbMemoryDumpLineSurvivesAddressAndAsciiStripping() throws {
        let app = try launchNotepad()
        defer { app.terminate() }

        // Seed with a buffer that's larger than what we'll paste, so we can
        // verify the paste OVERWROTE only the first 16 bytes and left the rest
        // untouched.
        try createBufferWithText(app: app, text: "0123456789abcdef0123456789abcdef")
        try invokeHexEditorMenu(app: app, item: "View in HEX")
        Thread.sleep(forTimeInterval: 1.0)

        let hexTable = app.descendants(matching: .table).matching(identifier: AXID.table).firstMatch
        XCTAssertTrue(hexTable.waitForExistence(timeout: 5))
        try positionHexCursorAtZero(app: app, hexTable: hexTable)

        // Realistic lldb `memory read` output — leading address, the split
        // 2-space gap between bytes 7 and 8, trailing ASCII gloss.
        let lldbDump = "0x100000000: 48 65 6c 6c 6f 20 77 6f  72 6c 64 21 0a 00 00 00  Hello world!...."
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(lldbDump, forType: .string)

        invokeEditMenuItem(app: app, item: "Paste")
        Thread.sleep(forTimeInterval: 0.3)

        // First row should now show the 16 lldb bytes: 48 65 6c 6c 6f 20 77 6f
        // followed by 72 6c 64 21 0a 00 00 00. NOT the address bytes 0x10, 0x00,
        // 0x00, 0x00, ... that the pre-fix parser would have spuriously included.
        let row0 = hexTable.tableRows.element(boundBy: 0)
        XCTAssertTrue(row0.waitForExistence(timeout: 5))
        wait(for: [
            expectation(for: NSPredicate(format: "value == %@", "48"),
                        evaluatedWith: row0.staticTexts.element(boundBy: cellIndex(forByte: 0)),
                        handler: nil),
            expectation(for: NSPredicate(format: "value == %@", "6f"),
                        evaluatedWith: row0.staticTexts.element(boundBy: cellIndex(forByte: 4)),
                        handler: nil),
            expectation(for: NSPredicate(format: "value == %@", "72"),
                        evaluatedWith: row0.staticTexts.element(boundBy: cellIndex(forByte: 8)),
                        handler: nil),
            expectation(for: NSPredicate(format: "value == %@", "00"),
                        evaluatedWith: row0.staticTexts.element(boundBy: cellIndex(forByte: 15)),
                        handler: nil),
        ], timeout: 5)

        // Undo so terminate doesn't surface a save-changes prompt.
        app.typeKey("z", modifierFlags: .command)
        _ = waitForStatus(in: app, contains: "32 bytes", timeout: 3)
    }

    func testCrossAppPaste_RectangularFromMultiLineXxdDump() throws {
        let app = try launchNotepad()
        defer { app.terminate() }

        try createBufferWithText(app: app, text: "ABCDEFGHIJKLMNOPabcdefghijklmnop")
        try invokeHexEditorMenu(app: app, item: "View in HEX")
        Thread.sleep(forTimeInterval: 1.0)

        let hexTable = app.descendants(matching: .table).matching(identifier: AXID.table).firstMatch
        XCTAssertTrue(hexTable.waitForExistence(timeout: 5))
        try positionHexCursorAtZero(app: app, hexTable: hexTable)

        // Build a 4×2 destination rect at offset 0 to receive the paste.
        extendRectViaKeyboard(app: app, addCols: 3, addRows: 1)
        let rect = HexCursorState.read(from: app)
        XCTAssertEqual(rect?.rectWidth, 4)
        XCTAssertEqual(rect?.rectHeight, 2)

        // Two-line xxd-format dump — addresses + concatenated nibble pairs +
        // ASCII gloss. Each cleaned line yields exactly 4 bytes so the rect
        // shape match passes (4×2 dest = 4×2 source).
        let xxdDump =
            "00000000: dead beef  ....\n" +
            "00000010: cafe babe  ....\n"
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(xxdDump, forType: .string)

        invokeEditMenuItem(app: app, item: "Paste")
        Thread.sleep(forTimeInterval: 0.5)

        // Row 0 cols 0..3 should now be DE AD BE EF; row 1 cols 0..3 = CA FE BA BE.
        let row0 = hexTable.tableRows.element(boundBy: 0)
        let row1 = hexTable.tableRows.element(boundBy: 1)
        wait(for: [
            expectation(for: NSPredicate(format: "value == %@", "de"),
                        evaluatedWith: row0.staticTexts.element(boundBy: cellIndex(forByte: 0)),
                        handler: nil),
            expectation(for: NSPredicate(format: "value == %@", "ef"),
                        evaluatedWith: row0.staticTexts.element(boundBy: cellIndex(forByte: 3)),
                        handler: nil),
            expectation(for: NSPredicate(format: "value == %@", "ca"),
                        evaluatedWith: row1.staticTexts.element(boundBy: cellIndex(forByte: 0)),
                        handler: nil),
            expectation(for: NSPredicate(format: "value == %@", "be"),
                        evaluatedWith: row1.staticTexts.element(boundBy: cellIndex(forByte: 3)),
                        handler: nil),
        ], timeout: 5)
    }

    func testPasteboardAttack_TruncatedHeader() throws {
        // 5 bytes — well below kRectPayloadHeaderSize (20). decodeRectPayload
        // must reject before reading any of the multi-byte header fields.
        let payload = Data([0x48, 0x58, 0x52, 0x31, 0x01])  // "HXR1\x01" — looks like a partial header
        try runMalformedPastePayload(payload, label: "truncated header (5 bytes)")
    }

    func testPasteboardAttack_WrongMagic() throws {
        // 20-byte header with wrong magic — the rest is ignored.
        var payload = Data(count: 20)
        payload[0] = 0x58; payload[1] = 0x58; payload[2] = 0x58; payload[3] = 0x31  // "XXX1"
        payload[4] = 0x01  // version
        // dataLength stays 0; even if magic check were bypassed, the parse
        // would stop at the first downstream check.
        try runMalformedPastePayload(payload, label: "wrong magic (XXX1 instead of HXR1)")
    }

    func testPasteboardAttack_ForgedDataLength() throws {
        // Valid magic + version, but dataLength claims 1000 bytes follow when
        // the actual payload is just the 20-byte header. This is the OOB-read
        // attack — if the bound check missed, the plugin would read 1000
        // bytes past the end of the NSData buffer.
        var payload = Data(count: 20)
        payload[0] = 0x48; payload[1] = 0x58; payload[2] = 0x52; payload[3] = 0x31  // "HXR1"
        payload[4] = 0x01  // version
        payload[5] = 0x00  // kind = Bytes
        // dataLength = 1000 (LE32 at offset 16..19)
        payload[16] = 0xE8; payload[17] = 0x03; payload[18] = 0x00; payload[19] = 0x00
        try runMalformedPastePayload(payload, label: "forged dataLength (1000 with empty body)")
    }

    private func positionHexCursorAt(app: XCUIApplication, hexTable: XCUIElement, offset: Int) throws {
        hexTable.rightClick()
        let gotoItem = app.menuItems["Go to Offset…"]
        XCTAssertTrue(gotoItem.waitForExistence(timeout: 3))
        gotoItem.click()
        let gotoInput = app.textFields["hex-editor.goto.input"]
        XCTAssertTrue(gotoInput.waitForExistence(timeout: 3))
        gotoInput.replaceFieldText(with: String(offset))
        let goButton = app.buttons["Go"].firstMatch
        XCTAssertTrue(goButton.waitForExistence(timeout: 3))
        goButton.click()
        XCTAssertTrue(gotoInput.waitForNonExistence(timeout: 5))
    }

    private func assertAboutDialog(app: XCUIApplication,
                                   helpItem: String,
                                   expectedTag: String,
                                   expectedBodyContains: String,
                                   file: StaticString = #file,
                                   line: UInt = #line) throws {
        try invokeHexEditorMenu(app: app, item: helpItem)

        let aboutDialog = app.dialogs.firstMatch
        XCTAssertTrue(aboutDialog.waitForExistence(timeout: 5),
                      "About dialog should appear after Help.", file: file, line: line)

        // The dialog body is delivered as one informativeText combining about.body
        // and about.localeTag separated by a blank line. Match against either
        // staticText `value` or `label` since NSAlert exposes the text via both.
        let tagPredicate = NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@",
                                       expectedTag, expectedTag)
        XCTAssertTrue(aboutDialog.staticTexts.element(matching: tagPredicate).exists,
                      "About dialog should display \(expectedTag).",
                      file: file, line: line)

        let bodyPredicate = NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@",
                                        expectedBodyContains, expectedBodyContains)
        XCTAssertTrue(aboutDialog.staticTexts.element(matching: bodyPredicate).exists,
                      "About dialog should contain '\(expectedBodyContains)'.",
                      file: file, line: line)

        // Dismiss — OK label is localized; under German it's still "OK" (the
        // string file matches the macOS convention).
        let okButton = aboutDialog.buttons["OK"].firstMatch
        XCTAssertTrue(okButton.waitForExistence(timeout: 3),
                      "About dialog should have an OK button.", file: file, line: line)
        okButton.click()
    }

    // MARK: - Helpers

    private func launchNotepad(language: String = "en", extraArguments: [String] = []) throws -> XCUIApplication {
        let app = XCUIApplication(url: try notepadAppURL())
        // -nosession suppresses session restore so each test starts with a single empty,
        // focused buffer.
        // --reset-hex-prefs is honoured by the plugin's setInfo: it wipes the suite at
        //   ~/Library/Preferences/org.notepad-plus-plus.HexEditor.plist before loading,
        //   so each test sees defaults. The runner cannot delete that plist itself —
        //   sandboxed UserDefaults(suiteName:) writes redirect to the runner container.
        app.launchArguments = ["-nosession", "--reset-hex-prefs"] + extraArguments
        // Drive the plugin's localization cascade via a plugin-only env var
        // instead of -AppleLanguages or `defaults write`. The argv form pollutes
        // NPP Mac's positional file-opener (it tries to open `(de)` as a file
        // and fails to create an empty buffer). The persistent-prefs path is
        // silently sandbox-redirected when invoked from the XCUI runner — the
        // write goes to the runner's container, not the user defaults NPP Mac
        // reads. The env var path bypasses both: the plugin checks
        // HEX_EDITOR_LANG_OVERRIDE first in hexUserPreferredLanguages().
        app.launchEnvironment = ["HEX_EDITOR_LANG_OVERRIDE": language]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10), "Notepad++ macOS did not launch.")
        return app
    }

    /// Positions the hex view's caret at byte 0 by invoking Go to Offset → 0.
    /// Scintilla doesn't reliably receive synthetic key events from XCUITest
    /// (paste-via-Edit-menu works; typeKey to Scintilla does not), so we cannot
    /// reset Scintilla's caret from the test runner. Instead, we open the hex
    /// view (which mirrors Scintilla's caret — typically at end-of-paste) and
    /// then navigate to byte 0 via the hex view's own Go to Offset dialog.
    /// HexTableView.performKeyEquivalent: intercepts Cmd+L so this works even
    /// though typeKey-to-Scintilla doesn't.
    /// Brings Scintilla to first-responder status. After menu-driven actions
    /// (Edit > Paste), the macOS focus lands on the enclosing SplitGroup rather
    /// than the Scintilla TextView itself. Subsequent keyboard / Edit menu
    /// actions that should target Scintilla (Cmd+A, Cmd+Z, Select All, etc.)
    /// silently no-op until something gives Scintilla focus. Clicking the
    /// Scintilla view fixes that. Required before any keyboard input or
    /// selectAll: action that needs to affect the source buffer.
    private func focusScintilla(in app: XCUIApplication) throws {
        let scintilla = app.descendants(matching: .textView).matching(identifier: "Scintilla").firstMatch
        XCTAssertTrue(scintilla.waitForExistence(timeout: 5),
                      "Scintilla TextView should be present in the AX hierarchy.")
        scintilla.click()
        Thread.sleep(forTimeInterval: 0.3)
    }

    private func positionHexCursorAtZero(app: XCUIApplication, hexTable: XCUIElement) throws {
        hexTable.rightClick()
        let gotoItem = app.menuItems["Go to Offset…"]
        XCTAssertTrue(gotoItem.waitForExistence(timeout: 3))
        gotoItem.click()
        let gotoInput = app.textFields["hex-editor.goto.input"]
        XCTAssertTrue(gotoInput.waitForExistence(timeout: 3))
        gotoInput.replaceFieldText(with: "0")
        let goButton = app.buttons["Go"].firstMatch
        XCTAssertTrue(goButton.waitForExistence(timeout: 3))
        goButton.click()
        XCTAssertTrue(gotoInput.waitForNonExistence(timeout: 5),
                      "Go to Offset dialog should dismiss after clicking Go.")
    }

    private func createBufferWithText(app: XCUIApplication, text: String) throws {
        // XCUI's `typeText` does not reach the Scintilla view in Notepad++ macOS — under the
        // sandboxed UI test runner, synthetic key events are silently dropped before they
        // reach Scintilla's input handler. Edit menu actions (clicked via the menu bar) DO
        // route correctly, so we seed the buffer via Edit > Paste with the clipboard
        // pre-populated. This is reliable and does not require keyboard delivery.
        Thread.sleep(forTimeInterval: 0.5)

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        let editMenu = app.menuBars.menuBarItems["Edit"]
        XCTAssertTrue(editMenu.waitForExistence(timeout: 5))
        editMenu.click()
        let pasteItem = app.menuBars.menuItems["Paste"]
        XCTAssertTrue(pasteItem.waitForExistence(timeout: 3))
        pasteItem.click()
        Thread.sleep(forTimeInterval: 0.5)
    }

    private func invokeHexEditorMenu(app: XCUIApplication, item leaf: String) throws {
        let pluginsMenu = app.menuBars.menuBarItems["Plugins"]
        XCTAssertTrue(pluginsMenu.waitForExistence(timeout: 5))
        pluginsMenu.click()

        let hexEditorItem = app.menuBars.menuItems["HEX-Editor"]
        XCTAssertTrue(hexEditorItem.waitForExistence(timeout: 5))
        hexEditorItem.hover()

        let leafItem = app.menuBars.menuItems[leaf]
        XCTAssertTrue(leafItem.waitForExistence(timeout: 5), "Plugins > HEX-Editor > \(leaf) is not visible.")
        leafItem.click()
    }

    private func waitForStatus(in app: XCUIApplication, contains needle: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        let element = app.staticTexts.matching(identifier: AXID.status).firstMatch
        while Date() < deadline {
            let text = (element.value as? String) ?? element.label
            if text.contains(needle) {
                return true
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return false
    }

    private func notepadAppURL() throws -> URL {
        if let explicitPath = ProcessInfo.processInfo.environment["NPP_MACOS_APP"], !explicitPath.isEmpty {
            let explicitURL = URL(fileURLWithPath: explicitPath)
            try XCTSkipUnless(FileManager.default.fileExists(atPath: explicitURL.path), "NPP_MACOS_APP does not exist: \(explicitURL.path)")
            return explicitURL
        }

        // #filePath: <repo>/macos/ui-tests-xcode/Tests/HexEditorUITests.swift
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let defaultURL = repoRoot
            .appendingPathComponent("../notepad-plus-plus-macos/build/Notepad++.app")
            .standardizedFileURL

        try XCTSkipUnless(FileManager.default.fileExists(atPath: defaultURL.path), "Set NPP_MACOS_APP=/path/to/Notepad++.app before running UI tests.")
        return defaultURL
    }
}

private extension XCUIElement {
    func waitForNonExistence(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !exists {
                return true
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return !exists
    }
}
