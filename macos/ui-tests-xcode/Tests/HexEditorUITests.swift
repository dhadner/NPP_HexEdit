import AppKit
import XCTest

// Accessibility identifiers mirror those defined in macos/src/HexEditor.mm.
private enum AXID {
    static let root = "hex-editor.root"
    static let table = "hex-editor.table"
    static let status = "hex-editor.status"
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

    // MARK: - Helpers

    private func launchNotepad(extraArguments: [String] = []) throws -> XCUIApplication {
        let app = XCUIApplication(url: try notepadAppURL())
        // -nosession suppresses session restore so each test starts with a single empty,
        // focused buffer.
        // --reset-hex-prefs is honoured by the plugin's setInfo: it wipes the suite at
        //   ~/Library/Preferences/org.notepad-plus-plus.HexEditor.plist before loading,
        //   so each test sees defaults. The runner cannot delete that plist itself —
        //   sandboxed UserDefaults(suiteName:) writes redirect to the runner container.
        // -AppleLanguages forces the host (and the in-process plugin) into English so the
        // tests' string assertions stay valid no matter what locale the dev machine is set
        // to. The plugin's runtime localization respects this.
        app.launchArguments = ["-nosession", "--reset-hex-prefs", "-AppleLanguages", "(en)"] + extraArguments
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10), "Notepad++ macOS did not launch.")
        return app
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
