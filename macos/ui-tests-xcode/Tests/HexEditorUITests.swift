import AppKit
import XCTest

// Accessibility identifiers mirror those defined in macos/src/HexEditor.mm.
private enum AXID {
    static let root = "hex-editor.root"
    static let table = "hex-editor.table"
    static let status = "hex-editor.status"
}

@MainActor
final class HexEditorUITests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
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
            "View in",
            "Zoom In", "Zoom Out", "Restore Default Zoom",
        ]
        for label in expectedItems {
            let item = app.menuItems[label]
            XCTAssertTrue(item.waitForExistence(timeout: 3), "Context menu missing item: \(label)")
        }

        // Dismiss the context menu.
        app.typeKey(.escape, modifierFlags: [])
    }

    // MARK: - Helpers

    private func launchNotepad() throws -> XCUIApplication {
        let app = XCUIApplication(url: try notepadAppURL())
        // -nosession suppresses session restore so each test starts with a single empty,
        // focused buffer (AppDelegate creates a fresh untitled document when no session
        // is restored and no files were passed on the command line).
        app.launchArguments = ["-nosession"]
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
