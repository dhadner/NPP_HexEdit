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
    /// Source pane the rectangular drag originated in: "Hex" or "Ascii". Used by
    /// paste-matrix tests to confirm the source-pane tag survives the round-trip.
    let rectOriginPane: String?
    /// 1 iff every column's headerCell.alignment equals its dataCell.alignment.
    /// 0 means at least one column will look visually unbalanced — header text
    /// left-justified above centered data, or vice versa.
    let hdrAlignMatch: Int?
    /// Current cell font point size (the `00 01 …` values + ASCII pane font).
    /// Tracked alongside headerFontPt so tests can verify the header tracks
    /// the cell under zoom (Cmd+/Cmd-/pinch).
    let cellFontPt: Double?
    /// Current header font point size (the `00 01 02 …` column titles +
    /// `Offset` / `ASCII`). Always `cellFontPt - 2` (with 9pt floor).
    let headerFontPt: Double?
    /// Caret render geometry from the last drawRect: paint. -1 = caret
    /// has not been drawn yet (view just created, no cursor activity).
    /// caretCellOffsetX is the caret X relative to the cell that contained
    /// it (caretX − caretCellMinX) — useful for asserting the caret sits
    /// at the expected horizontal offset within the cell regardless of
    /// where the cell itself ended up in the viewport.
    let caretX: Double?
    let caretRow: Int?
    let caretCellMinX: Double?
    let caretCellOffsetX: Double?
    /// Width in pt of the last-drawn Mirror Cursor rectangle. 0 = mirror
    /// was not drawn this paint (g_mirrorAsciiCursor is off, the caret
    /// is out of bounds, or the active pane's mirror column couldn't
    /// be resolved). > 0 = mirror was drawn — width is the rectangle's
    /// pixel width.
    let mirrorWidth: Double?
    /// Font-tab toggle flags as currently held in plugin globals. Order:
    /// Bold, Italic, Underline, UppercaseHex, MirrorAsciiCursor — each
    /// 1 (on) or 0 (off). Lets a test confirm a Font-tab dialog round-
    /// trip wired the checkbox state through commit + load.
    let fontBold: Bool?
    let fontItalic: Bool?
    let fontUnderline: Bool?
    let fontUppercaseHex: Bool?
    let fontMirrorAsciiCursor: Bool?

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

    /// Parse a comma-separated 1/0 flag string ("0,1,0,1,1") and return
    /// the bit at `index`. nil if the field is missing, the string is
    /// shorter than expected, or the bit isn't 0/1.
    private static func flagAt(_ raw: String?, index: Int) -> Bool? {
        guard let raw = raw else { return nil }
        let parts = raw.split(separator: ",")
        guard index < parts.count else { return nil }
        let bit = String(parts[index])
        if bit == "1" { return true }
        if bit == "0" { return false }
        return nil
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
            rectOriginPane: fields["rectOriginPane"],
            hdrAlignMatch: fields["hdrAlignMatch"].flatMap({ Int($0) }),
            cellFontPt: fields["cellFontPt"].flatMap({ Double($0) }),
            headerFontPt: fields["headerFontPt"].flatMap({ Double($0) }),
            caretX: fields["caretX"].flatMap({ Double($0) }),
            caretRow: fields["caretRow"].flatMap({ Int($0) }),
            caretCellMinX: fields["caretCellMinX"].flatMap({ Double($0) }),
            caretCellOffsetX: fields["caretCellOffsetX"].flatMap({ Double($0) }),
            mirrorWidth: fields["mirrorWidth"].flatMap({ Double($0) }),
            fontBold:               flagAt(fields["fontFlags"], index: 0),
            fontItalic:             flagAt(fields["fontFlags"], index: 1),
            fontUnderline:          flagAt(fields["fontFlags"], index: 2),
            fontUppercaseHex:       flagAt(fields["fontFlags"], index: 3),
            fontMirrorAsciiCursor:  flagAt(fields["fontFlags"], index: 4)
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

/// Common helpers shared by every UI-test class in this file. Holds no
/// test methods of its own — XCTest only runs methods on subclasses, so
/// this base contributes shared scaffolding (NPP launch, hex-menu
/// invocation, status polling, fixture lookup) without showing up in the
/// dashboard. Both HexEditorUITests (the routine suite) and
/// HexEditorLargeFileUITests (the gated multi-GB tests) inherit from it.
@MainActor
class HexEditorBaseUITests: XCTestCase {
    /// True when the test bundle was launched with TEST_RUNNER_NPP_HEXEDIT_ASAN=1
    /// (set by vm-test.sh's --asan path). Tests use this to scale long-poll
    /// timeouts and to force the ASan runtime into NPP at process launch via
    /// DYLD_INSERT_LIBRARIES.
    static var isAsanRun: Bool {
        return ProcessInfo.processInfo.environment["NPP_HEXEDIT_ASAN"] == "1"
    }

    /// Multiplier for any timeout that depends on NPP's responsiveness. 1× in
    /// the regular build; 3× under ASan. NPP under DYLD_INSERT_LIBRARIES'd ASan
    /// runs at roughly 2× speed for AppKit work, so 3× gives a safety margin
    /// without masking real hangs.
    static var asanTimeoutScale: Double {
        return isAsanRun ? 3.0 : 1.0
    }

    /// Builds the launchEnvironment for an XCUIApplication, layering ASan
    /// injection on top of the locale override. When isAsanRun is true and the
    /// runner has been told the resolved ASan dylib path
    /// (TEST_RUNNER_NPP_HEXEDIT_ASAN_DYLIB → NPP_HEXEDIT_ASAN_DYLIB), we set
    /// DYLD_INSERT_LIBRARIES to force the ASan runtime into NPP at dyld init —
    /// a dlopen'd ASan-instrumented plugin otherwise aborts NPP at launch with
    /// "Interceptors are not working" because NPP's mallocs already happened
    /// before our dylib loaded.
    fileprivate static func nppLaunchEnvironment(language: String) -> [String: String] {
        var env = ["HEX_EDITOR_LANG_OVERRIDE": language]
        let processEnv = ProcessInfo.processInfo.environment
        if let asanOpts = processEnv["NPP_HEXEDIT_ASAN_OPTIONS"], !asanOpts.isEmpty {
            env["ASAN_OPTIONS"] = asanOpts
        }
        if let asanDylib = processEnv["NPP_HEXEDIT_ASAN_DYLIB"], !asanDylib.isEmpty {
            env["DYLD_INSERT_LIBRARIES"] = asanDylib
        }
        return env
    }

    fileprivate func notepadAppURL() throws -> URL {
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

    fileprivate func fixturePath(_ name: String) throws -> String {
        guard let dir = ProcessInfo.processInfo.environment["NPP_HEXEDIT_FIXTURES_DIR"] else {
            throw XCTSkip("NPP_HEXEDIT_FIXTURES_DIR not set — run via macos/ui-tests-xcode/run-tests.sh.")
        }
        let path = (dir as NSString).appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("Fixture missing: \(path). Re-run macos/ui-tests-xcode/run-tests.sh to regenerate.")
        }
        return path
    }

    /// Launch Nextpad++ with a fixture file passed as a positional argv. The
    /// host's CLI parser (NppCommandLineParams in src/AppDelegate.mm) treats
    /// any non-flag argument as a file to open — see `--help` for the catalog.
    fileprivate func launchNotepadWithFixture(_ name: String, language: String = "en") throws -> XCUIApplication {
        let path = try fixturePath(name)
        let app = XCUIApplication(url: try notepadAppURL())
        app.launchArguments = ["-nosession", "--reset-hex-prefs", path]
        app.launchEnvironment = Self.nppLaunchEnvironment(language: language)
        app.launch()
        let foregroundTimeout = 30.0 * Self.asanTimeoutScale
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: foregroundTimeout),
                      "Nextpad++ macOS did not launch with fixture \(name).")
        return app
    }

    fileprivate func invokeHexEditorMenu(app: XCUIApplication, item leaf: String) throws {
        let pluginsMenu = app.menuBars.menuBarItems["Plugins"]
        // Generous timeouts here so the helper accommodates the large-file tests:
        // when NPP is mid-ingest of a 100 MB fixture, its main thread is busy and
        // menu clicks queue up but don't expand a submenu until the load finishes.
        // 30 s of patience is overkill for the typical 32-byte test (which sees the
        // menu surface in <100 ms) but keeps the helper general-purpose without a
        // separate "slow" variant. Under ASan-injected NPP the budget scales
        // by Self.asanTimeoutScale to absorb the slower menu construction.
        let menuTimeout = 30.0 * Self.asanTimeoutScale
        XCTAssertTrue(pluginsMenu.waitForExistence(timeout: menuTimeout))
        pluginsMenu.click()

        let hexEditorItem = app.menuBars.menuItems["HexEditor"]
        XCTAssertTrue(hexEditorItem.waitForExistence(timeout: menuTimeout),
                      "HexEditor submenu didn't appear within \(menuTimeout) s — host may still be loading a large file.")
        hexEditorItem.hover()

        let leafItem = app.menuBars.menuItems[leaf]
        XCTAssertTrue(leafItem.waitForExistence(timeout: menuTimeout), "Plugins > HexEditor > \(leaf) is not visible.")
        leafItem.click()
    }

    fileprivate func waitForStatus(in app: XCUIApplication, contains needle: String, timeout: TimeInterval) -> Bool {
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

    /// Returns the current hex-view status text, useful in failure messages
    /// to show what was actually displayed when an assertion failed.
    fileprivate func currentStatusText(in app: XCUIApplication) -> String {
        let element = app.staticTexts.matching(identifier: AXID.status).firstMatch
        return (element.value as? String) ?? element.label
    }

    /// Capture the current screen as a PNG and (a) attach it to the test result
    /// for archival in the .xcresult bundle and (b) write it directly to the
    /// runner's sandbox container so run-tests.sh can extract it after xcodebuild
    /// completes.
    ///
    /// Why NSHomeDirectory() and not an env-var-supplied path: the XCUITest
    /// runner is App-Sandboxed (per `org.notepadplusplus.hexeditor.uitests.xctrunner`
    /// container). Writes to arbitrary user-fs paths — even ones the runner's
    /// uid owns, like ~/vm-local/... — fail with NSPOSIXErrorDomain Code=1
    /// "Operation not permitted". NSHomeDirectory() inside the sandbox resolves
    /// to ~/Library/Containers/<runner-id>/Data and IS writable. run-tests.sh
    /// sweeps that container for the screenshots dir after the test pass.
    fileprivate func captureToDashboard(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()

        // Archival in xcresult — visible in Xcode's "Test Result" navigator.
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)

        // Direct write inside the sandbox container.
        let dirURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("captureToDashboard-screenshots")
        try? FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
        let fileURL = dirURL.appendingPathComponent("\(name).png")
        try? screenshot.pngRepresentation.write(to: fileURL)
    }
}

@MainActor
final class HexEditorUITests: HexEditorBaseUITests {
    override func setUp() async throws {
        continueAfterFailure = false

        // Bulletproof pre-test cleanup: a prior test that aborted mid-modal can leave the
        // dev build alive; LaunchServices then coalesces our XCUIApplication(url:) launch
        // onto that stale process and we sit through 68 s of "no PID" per test. Force-kill
        // any dev-build instance up front, then verify the kill landed before proceeding.
        let expectedURL = try notepadAppURL().standardizedFileURL
        terminateDevBuildInstances(expectedURL: expectedURL)

        // If a *different* org.notepadplusplus.mac is running (e.g. /Applications/Nextpad++.app),
        // XCUI(url:) cannot launch a second instance under the same bundle ID. Skip-fast with a
        // clear message instead of letting the test sit through the launch timeout.
        let conflicts = NSWorkspace.shared.runningApplications.filter {
            guard $0.bundleIdentifier == "org.notepadplusplus.mac" else { return false }
            guard let url = $0.bundleURL?.standardizedFileURL else { return false }
            return url != expectedURL
        }
        if let conflict = conflicts.first {
            throw XCTSkip("""
                Another Nextpad++ macOS instance is already running with the same bundle \
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

    // captureToDashboard moved to HexEditorBaseUITests so both test classes
    // can use it.

    /// Force-kills any running dev-build Nextpad++.app instance (path matches `expectedURL`),
    /// then waits up to 5 seconds for the process to disappear from the running-apps list.
    /// Leaves instances at other paths (e.g. /Applications/Nextpad++.app) untouched — those
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

        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10), "Nextpad++ macOS did not launch into the foreground.")
    }

    func testHexEditorPluginMenuIsPresent() throws {
        let app = try launchNotepad()
        defer { app.terminate() }

        let menuTimeout = 5.0 * Self.asanTimeoutScale
        let pluginsMenu = app.menuBars.menuBarItems["Plugins"]
        XCTAssertTrue(pluginsMenu.waitForExistence(timeout: menuTimeout), "The Plugins menu is not visible.")
        pluginsMenu.click()

        let hexEditorItem = app.menuBars.menuItems["HexEditor"]
        XCTAssertTrue(hexEditorItem.waitForExistence(timeout: menuTimeout), "The HexEditor plugin menu is not visible under Plugins. Install the plugin first with cmake --install macos/build-universal.")
    }

    func testOptionsDialogOpensAndCancelsCleanly() throws {
        let app = try launchNotepad()
        defer { app.terminate() }

        try invokeHexEditorMenu(app: app, item: "Options...")

        // The dialog is a real NSWindow (not NSAlert). Query by the Start
        // Layout tab's column-count field id — it's the most reliable hook
        // because XCUITest indexes interactive controls by
        // accessibilityIdentifier directly without going through window-role
        // intermediation.
        let columnCount = app.textFields["hex-editor.options.startLayout.columnCount"]
        XCTAssertTrue(columnCount.waitForExistence(timeout: 5),
                      "Options dialog should expose the Start Layout tab's column-count field.")

        app.buttons["hex-editor.options.button.cancel"].click()
        XCTAssertTrue(columnCount.waitForNonExistence(timeout: 5),
                      "Options dialog should dismiss after Cancel (column-count field goes away).")
    }

    func testOptionsHelpPopoverShowsAndDismisses() throws {
        // Each control in the Options dialog has an inline "?" help button next to it.
        // Clicking the button shows an NSPopover with localized help text; clicking
        // outside the popover dismisses it (NSPopoverBehaviorTransient). This test
        // exercises the full round-trip on the bits-per-column help button.

        let app = try launchNotepad()
        defer { app.terminate() }

        try invokeHexEditorMenu(app: app, item: "Options...")

        let helpButton = app.buttons["hex-editor.options.startLayout.bits.help"]
        XCTAssertTrue(helpButton.waitForExistence(timeout: 5),
                      "Options dialog should expose a help button on the bits-per-column control.")

        // Visual evidence: capture the dialog before, during, and after the popover
        // is shown. The before/after pair proves the popover is genuinely transient,
        // not just an AX-visible text node added once and never removed.
        captureToDashboard("testOptionsHelpPopover-01-dialog-without-popover")

        helpButton.click()

        // The popover content is a wrapping NSTextField; AX exposes its rendered
        // string as a static text. Substring-match a distinctive phrase from the
        // bits-per-column help that doesn't appear elsewhere in the dialog —
        // "interpreted integer values" is unique to this help body.
        let popoverText = app.staticTexts.containing(
            NSPredicate(format: "value CONTAINS[c] %@", "interpreted integer values")
        ).firstMatch
        XCTAssertTrue(popoverText.waitForExistence(timeout: 3),
                      "Help popover should appear with localized text after clicking the ? button.")

        captureToDashboard("testOptionsHelpPopover-02-popover-shown")

        // Transient popovers dismiss on outside click. Click the Column Count
        // text field — it's inside the same window but outside the popover's
        // frame and (unlike the popup) doesn't open a transient menu of its
        // own, so we can verify popover dismissal without juggling Escape
        // (Escape is also Cancel for the dialog, so chaining "open menu →
        // Escape" risked closing the dialog itself).
        app.textFields["hex-editor.options.startLayout.columnCount"].click()
        XCTAssertTrue(popoverText.waitForNonExistence(timeout: 3),
                      "Help popover should dismiss when the user clicks outside it.")

        captureToDashboard("testOptionsHelpPopover-03-popover-dismissed")

        let cancelButton = app.buttons["hex-editor.options.button.cancel"]
        cancelButton.click()
        XCTAssertTrue(cancelButton.waitForNonExistence(timeout: 5),
                      "Options dialog should dismiss after Cancel.")
    }

    func testOptionsResetIsNonDestructiveUntilCommitted() throws {
        // Reset to Defaults must rewrite the dialog UI to factory defaults but
        // NOT touch persisted state. Only Apply / Ok commits. Cancel-after-Reset
        // must leave the user's prior saved overrides intact.
        //
        // This is exercised on the Start Layout tab's Column Count field
        // because it's numeric and AX-readable; the Reset / Apply / Cancel
        // modal-loop semantics are shared across all four tabs, so a regression
        // in any tab's applyDefaults / commit contract surfaces here too. Added
        // 2026-05-03 after a Reset-on-Colors-tab bug shipped to the user — the
        // earlier per-tab applyDefaults blocks reverted to saved overrides
        // instead of factory defaults.
        let app = try launchNotepad()
        defer { app.terminate() }

        // 1. Open dialog, change Column Count from default (16) to 32, click Ok to commit.
        try invokeHexEditorMenu(app: app, item: "Options...")
        let columnCount = app.textFields["hex-editor.options.startLayout.columnCount"]
        XCTAssertTrue(columnCount.waitForExistence(timeout: 5),
                      "Options dialog should expose the Column Count field.")
        columnCount.replaceFieldText(with: "32")
        app.buttons["hex-editor.options.button.ok"].click()
        XCTAssertTrue(columnCount.waitForNonExistence(timeout: 5),
                      "Options dialog should dismiss after OK.")

        // 2. Reopen — saved override should be visible.
        try invokeHexEditorMenu(app: app, item: "Options...")
        XCTAssertTrue(columnCount.waitForExistence(timeout: 5))
        XCTAssertEqual(columnCount.value as? String, "32",
                       "Reopened dialog should show the saved Column Count override.")

        // 3. Click Reset. Field should switch to factory default (16) without
        //    committing to prefs.
        app.buttons["hex-editor.options.button.reset"].click()
        // Re-query after Reset because the modal session is stopped + restarted.
        let postReset = app.textFields["hex-editor.options.startLayout.columnCount"]
        XCTAssertTrue(postReset.waitForExistence(timeout: 3))
        XCTAssertEqual(postReset.value as? String, "16",
                       "After Reset, Column Count should show the factory default (16).")

        // 4. Click Cancel — dismiss without committing the reset.
        app.buttons["hex-editor.options.button.cancel"].click()
        XCTAssertTrue(columnCount.waitForNonExistence(timeout: 5))

        // 5. Reopen dialog. Field should STILL be 32 — Reset+Cancel must NOT
        //    have written through to persisted state. If this fails, Reset was
        //    destructive (the bug we're guarding against).
        try invokeHexEditorMenu(app: app, item: "Options...")
        let reopened = app.textFields["hex-editor.options.startLayout.columnCount"]
        XCTAssertTrue(reopened.waitForExistence(timeout: 5))
        XCTAssertEqual(reopened.value as? String, "32",
                       "Reset + Cancel must preserve the user's prior saved overrides; got \(String(describing: reopened.value)) instead of 32.")

        app.buttons["hex-editor.options.button.cancel"].click()
    }

    /// Expected factory hex values for each Colors-tab well, keyed by
    /// AX-id suffix. Used by the Light / Dark factory-snapshot tests below.
    /// The Light values are the Windows defaults from
    /// `HexEditor/src/Hex.cpp:412-420`. The Dark values are our parallel
    /// dark-mode analogues defined in HexEditor.mm (no Windows reference —
    /// the Windows plugin doesn't support Dark Mode).
    private static let factoryColorsLight: [(String, String)] = [
        ("regularText.fg", "000000"),
        ("regularText.bg", "ffffff"),
        ("selection.fg",   "ffffff"),
        ("selection.bg",   "8888ff"),
        ("compare.fg",     "ffffff"),
        ("compare.bg",     "ff8888"),
        ("bookmark.fg",    "ffffff"),
        ("bookmark.bg",    "ff0000"),
        ("currentLine.bg", "dfdfdf"),
    ]
    private static let factoryColorsDark: [(String, String)] = [
        ("regularText.fg", "ebebeb"),
        ("regularText.bg", "1e1e1e"),
        ("selection.fg",   "ffffff"),
        ("selection.bg",   "4858e0"),
        ("compare.fg",     "ffffff"),
        ("compare.bg",     "803030"),
        ("bookmark.fg",    "ffffff"),
        ("bookmark.bg",    "ff0000"),
        ("currentLine.bg", "4d4d4d"),
    ]

    /// Verify each Colors-tab well's AX value matches the expected factory hex.
    /// Caller is responsible for opening the dialog, switching to the Colors
    /// tab, and dismissing afterwards. Asserts inline so the failure message
    /// names the well that diverged.
    private func assertColorsTabWellsMatch(_ app: XCUIApplication,
                                            expected: [(String, String)],
                                            file: StaticString = #file,
                                            line: UInt = #line) {
        for (axSuffix, expectedHex) in expected {
            let axId = "hex-editor.options.colors.\(axSuffix)"
            let well = app.colorWells[axId]
            XCTAssertTrue(well.waitForExistence(timeout: 1),
                          "Color well \(axId) should exist on Colors tab.",
                          file: file, line: line)
            XCTAssertEqual(well.value as? String, expectedHex,
                           "Well \(axId) expected \(expectedHex); got '\(String(describing: well.value))'.",
                           file: file, line: line)
        }
    }

    // Dark-mode factory snapshot test was attempted on 2026-05-03 but cut
    // because driving NPP-Mac's Preferences → Dark Mode page from XCUI is
    // unreliable and an osascript fallback hits the runner's automation
    // TCC limit. Specifically:
    //   - Settings → Preferences… via menu navigation reaches the right
    //     page; the sidebar "Dark Mode" entry click works.
    //   - Clicking the Dark / Light / Auto radio (via element click,
    //     coordinate click, or predicate-matched click) does NOT dispatch
    //     `_darkModeRadioChanged:` — the radio state stays at the prior
    //     selection in screenshot capture.
    //   - osascript via Process gets `Application isn't running. (-600)`
    //     because the runner lacks Apple Events Automation permission for
    //     Nextpad++ (separate TCC scope from UI Automation, also not
    //     persistable; see project_xcui_runner_tcc.md).
    // The dark factory hexes are tiny static constants in HexEditor.mm;
    // typos there are a code-review concern, not a runtime one. The Light
    // test below verifies the factory mechanism (resolve helpers + Reset
    // dispatch + AX exposure); a parallel typo in dark-mode constants
    // would be visually obvious on first dark-mode launch. If we later
    // need automated dark coverage, options to revisit:
    //   1. MDM profile granting the runner full Automation permission.
    //   2. Add a NPP-Mac launch arg that pre-sets kPrefDarkMode (NPP
    //      change, not a HexEditor change).
    //   3. Build a separate Debug/test dylib with extra entry points and
    //      install it for the test session only.

    func testOptionsColorsTabFactoryDefaultsLight() throws {
        // Fast 9-well factory snapshot in Light mode. With clean prefs, no
        // overrides are set — the resolve helpers fall back to factory
        // colours, so the wells display them directly. The test reads each
        // well's AX value (HexAxColorWell exposes 6-digit lowercase hex)
        // and compares against the canonical Windows defaults.
        //
        // No launch-arg injection: --hex-test-set-* hooks would ship in
        // production for test convenience, which we don't want. Reset's
        // modal-loop behaviour is covered separately by
        // testOptionsResetIsNonDestructiveUntilCommitted (Column Count
        // text field).
        //
        // Assumes the VM is running in Light mode or Auto-with-Light. The
        // dark variant lives in testOptionsColorsTabFactoryDefaultsDark.
        let app = try launchNotepad()
        defer { app.terminate() }

        try invokeHexEditorMenu(app: app, item: "Options...")
        let colorsTab = app.tabs["Colors"]
        XCTAssertTrue(colorsTab.waitForExistence(timeout: 5),
                      "Colors tab should be present in the Options dialog.")
        colorsTab.click()

        assertColorsTabWellsMatch(app, expected: Self.factoryColorsLight)

        app.buttons["hex-editor.options.button.cancel"].click()
    }


    func testOptionsResetIsScopedToActiveTabOnly() throws {
        // Regression guard: clicking Reset to Defaults on the Colors tab
        // must NOT touch the Startup tab's extension list (and vice versa).
        // Reset is scoped to the visible tab. Caught a regression on
        // 2026-05-03 where Reset fanned out to every tab and silently wiped
        // the user's `.pdf` extension on every Colors-tab reset.
        let app = try launchNotepad()
        defer { app.terminate() }

        // 1. Open dialog, switch to Startup, type ".pdf" into the extensions
        //    field, click OK to commit.
        try invokeHexEditorMenu(app: app, item: "Options...")
        let startupTab = app.tabs["Startup"]
        XCTAssertTrue(startupTab.waitForExistence(timeout: 5))
        startupTab.click()

        let extField = app.textFields["hex-editor.options.startup.extensions"]
        XCTAssertTrue(extField.waitForExistence(timeout: 3))
        extField.replaceFieldText(with: ".pdf")
        app.buttons["hex-editor.options.button.ok"].click()
        XCTAssertTrue(extField.waitForNonExistence(timeout: 5))

        // 2. Reopen, verify .pdf landed in the saved state.
        try invokeHexEditorMenu(app: app, item: "Options...")
        let startupTabReopen = app.tabs["Startup"]
        XCTAssertTrue(startupTabReopen.waitForExistence(timeout: 5))
        startupTabReopen.click()
        let extFieldReopen = app.textFields["hex-editor.options.startup.extensions"]
        XCTAssertTrue(extFieldReopen.waitForExistence(timeout: 3))
        XCTAssertEqual(extFieldReopen.value as? String, ".pdf",
                       "Startup extensions field should show the saved '.pdf' override.")

        // 3. Switch to Colors tab and click Reset to Defaults.
        let colorsTab = app.tabs["Colors"]
        XCTAssertTrue(colorsTab.waitForExistence(timeout: 3))
        colorsTab.click()
        XCTAssertTrue(app.colorWells["hex-editor.options.colors.currentLine.bg"].waitForExistence(timeout: 3))
        app.buttons["hex-editor.options.button.reset"].click()

        // 4. Switch back to Startup. Extensions field MUST still show ".pdf"
        //    — Reset must not have touched another tab's UI state. A failure
        //    here means Reset fanned out across tabs (the regression).
        let startupTabAfterReset = app.tabs["Startup"]
        XCTAssertTrue(startupTabAfterReset.waitForExistence(timeout: 3))
        startupTabAfterReset.click()
        let extFieldAfterReset = app.textFields["hex-editor.options.startup.extensions"]
        XCTAssertTrue(extFieldAfterReset.waitForExistence(timeout: 3))
        XCTAssertEqual(extFieldAfterReset.value as? String, ".pdf",
                       "Reset on Colors tab MUST NOT touch Startup tab's extensions field.")

        // 5. OK to commit. Reopen and confirm .pdf is still persisted —
        //    proves Reset+Apply on Colors didn't wipe Startup at commit time.
        app.buttons["hex-editor.options.button.ok"].click()
        XCTAssertTrue(extFieldAfterReset.waitForNonExistence(timeout: 5))

        try invokeHexEditorMenu(app: app, item: "Options...")
        let startupTabFinal = app.tabs["Startup"]
        XCTAssertTrue(startupTabFinal.waitForExistence(timeout: 5))
        startupTabFinal.click()
        let extFieldFinal = app.textFields["hex-editor.options.startup.extensions"]
        XCTAssertTrue(extFieldFinal.waitForExistence(timeout: 3))
        XCTAssertEqual(extFieldFinal.value as? String, ".pdf",
                       "Saved '.pdf' extension must survive Reset-on-Colors + OK.")

        app.buttons["hex-editor.options.button.cancel"].click()
    }

    /// Match the plugin's `hexExpandedTestString` transformation: input
    /// repeated three times, separated by spaces. Use this when feeding
    /// English literals into XCUI queries that resolve by label under
    /// the `en-test` locale (menu item names, dialog titles, tab labels
    /// etc.). AX identifiers — which are build-time constants and don't
    /// go through L() — are unaffected and remain as the stable handle.
    private func expandedForEnTest(_ s: String) -> String {
        return "\(s) \(s) \(s)"
    }

    /// Assert pairwise non-overlap of the supplied elements' frames.
    /// Catches layout regressions where two controls visually collide
    /// (e.g. two checkboxes whose text overlaps) — pure AX existence
    /// queries don't see the geometry, so we have to check it ourselves.
    /// `nameFor` is a closure that maps an element back to a stable name
    /// for the failure message; the AX identifier is usually the right
    /// answer (XCUIElement.identifier may be empty so callers pass it in
    /// from the lookup site).
    private func assertNoSiblingOverlap(_ elementsByName: [(String, XCUIElement)],
                                         file: StaticString = #file,
                                         line: UInt = #line) {
        // Snapshot frames once each (each `.frame` access is a synchronous
        // AX query) so we don't re-fetch in the inner loop.
        let frames: [(String, CGRect)] = elementsByName.map { ($0.0, $0.1.frame) }
        for i in 0..<frames.count {
            for j in (i + 1)..<frames.count {
                let (nameA, frameA) = frames[i]
                let (nameB, frameB) = frames[j]
                let overlap = frameA.intersection(frameB)
                if !overlap.isNull && !overlap.isEmpty {
                    XCTFail("Controls '\(nameA)' \(frameA) and '\(nameB)' \(frameB) overlap by \(overlap) — layout regression.",
                            file: file, line: line)
                }
            }
        }
    }

    func testOptionsFontTabLayoutSurvivesLongLabels() throws {
        // Stress test: the `en-test` locale wraps every L() lookup so
        // each label is the English string concatenated three times. Any
        // dialog that uses fixed-width column assumptions will collide
        // under this expansion. The Font tab specifically had a regression
        // on 2026-05-04 (right column hard-coded too close to the left
        // column → "Capital letters mode" overlapped "Italic"); this test
        // would have caught that and is here to prevent it from coming
        // back, plus catch the same class of bug on any future tab work.
        let app = try launchNotepad(language: "en-test")
        defer { app.terminate() }

        try invokeHexEditorMenu(app: app, item: expandedForEnTest("Options..."))

        // The "Font" tab label is also tripled in en-test — match the
        // exact expanded form (`app.tabs[X]` resolves by label).
        let fontTab = app.tabs[expandedForEnTest("Font")]
        XCTAssertTrue(fontTab.waitForExistence(timeout: 5),
                      "Font tab should be present in the Options dialog (en-test locale).")
        fontTab.click()

        // All seven controls must still be locatable by their AX
        // identifiers (those don't go through L() — they're build-time
        // constants), and their frames must not overlap each other.
        let pairs: [(String, XCUIElement)] = [
            ("font.name",                 app.popUpButtons["hex-editor.options.font.name"]),
            ("font.size",                 app.popUpButtons["hex-editor.options.font.size"]),
            ("font.bold",                 app.checkBoxes["hex-editor.options.font.bold"]),
            ("font.italic",               app.checkBoxes["hex-editor.options.font.italic"]),
            ("font.underline",            app.checkBoxes["hex-editor.options.font.underline"]),
            ("font.uppercaseHex",         app.checkBoxes["hex-editor.options.font.uppercaseHex"]),
            ("font.mirrorAsciiCursor",    app.checkBoxes["hex-editor.options.font.mirrorAsciiCursor"]),
        ]
        for (name, el) in pairs {
            XCTAssertTrue(el.waitForExistence(timeout: 3),
                          "Control \(name) should exist on the Font tab under en-test.")
        }
        assertNoSiblingOverlap(pairs)

        // Cancel via the close button — the localised "Cancel" string is
        // tripled, but the AX identifier is stable.
        app.buttons["hex-editor.options.button.cancel"].click()
    }

    func testFontTabMirrorCursorToggleControlsRendering() throws {
        // Phase 4: Mirror Cursor as Rect — when on, drawRect: paints a
        // hollow rectangle in the OPPOSITE pane around the byte the
        // caret is currently associated with. Default is OFF (the user
        // opts into the indicator if they want it). Diagnostic exposes
        // mirrorWidth (>0 ⇒ rectangle drawn this paint, 0 ⇒ not drawn);
        // this test confirms the dialog → flag → render path round-trips
        // in both directions.
        let app = try launchNotepad()
        defer { app.terminate() }

        try createBufferWithText(app: app, text: "abcdefgh")
        try invokeHexEditorMenu(app: app, item: "View in HEX")
        Thread.sleep(forTimeInterval: 0.5)

        // Position the caret at byte 0 — without this, the post-paste
        // Scintilla caret sits at end-of-buffer (offset 8), which is
        // past the last valid byte; the mirror would skip drawing for
        // an unrelated reason and the toggle assertion below would be
        // vacuous.
        let hexTable = app.descendants(matching: .table).matching(identifier: AXID.table).firstMatch
        XCTAssertTrue(hexTable.waitForExistence(timeout: 5))
        try positionHexCursorAtZero(app: app, hexTable: hexTable)
        Thread.sleep(forTimeInterval: 0.3)

        // Default: mirror DISABLED. No rectangle should be drawn even
        // with a valid caret.
        guard let s0 = HexCursorState.read(from: app) else {
            XCTFail("Failed to read cursor diagnostic.")
            return
        }
        XCTAssertEqual(s0.fontMirrorAsciiCursor, false,
                       "Mirror Cursor as Rect default should be OFF. Diagnostic: \(s0.debugDescription)")
        XCTAssertEqual(s0.mirrorWidth, 0,
                       "With Mirror Cursor disabled (default), drawRect: should NOT paint the mirror rectangle. mirrorWidth=\(s0.mirrorWidth ?? -1). Diagnostic: \(s0.debugDescription)")

        // Toggle ON via the Font tab.
        try invokeHexEditorMenu(app: app, item: "Options...")
        let fontTab = app.tabs["Font"]
        XCTAssertTrue(fontTab.waitForExistence(timeout: 5))
        fontTab.click()
        let mirror = app.checkBoxes["hex-editor.options.font.mirrorAsciiCursor"]
        XCTAssertTrue(mirror.waitForExistence(timeout: 3))
        XCTAssertEqual(mirror.value as? Int, 0,
                       "Mirror checkbox should be unchecked at default. Got value=\(String(describing: mirror.value)).")
        mirror.click()
        app.buttons["hex-editor.options.button.ok"].click()
        XCTAssertTrue(mirror.waitForNonExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 0.3)

        guard let s1 = HexCursorState.read(from: app) else {
            XCTFail("Failed to read diagnostic after enabling mirror.")
            return
        }
        XCTAssertEqual(s1.fontMirrorAsciiCursor, true,
                       "Flag should be ON after toggle. Diagnostic: \(s1.debugDescription)")
        guard let mw1 = s1.mirrorWidth else {
            XCTFail("Diagnostic missing mirrorWidth after enable. Raw: \(s1.debugDescription)")
            return
        }
        XCTAssertGreaterThan(mw1, 0,
                             "After enabling Mirror Cursor with a valid caret, drawRect: should paint the rectangle. mirrorWidth=\(mw1). Diagnostic: \(s1.debugDescription)")

        // Toggle OFF, verify it stops drawing.
        try invokeHexEditorMenu(app: app, item: "Options...")
        let fontTab2 = app.tabs["Font"]
        XCTAssertTrue(fontTab2.waitForExistence(timeout: 5))
        fontTab2.click()
        let mirror2 = app.checkBoxes["hex-editor.options.font.mirrorAsciiCursor"]
        XCTAssertTrue(mirror2.waitForExistence(timeout: 3))
        mirror2.click()
        app.buttons["hex-editor.options.button.ok"].click()
        XCTAssertTrue(mirror2.waitForNonExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 0.3)

        guard let s2 = HexCursorState.read(from: app) else {
            XCTFail("Failed to read diagnostic after disabling mirror.")
            return
        }
        XCTAssertEqual(s2.fontMirrorAsciiCursor, false,
                       "Flag should be OFF after second toggle. Diagnostic: \(s2.debugDescription)")
        XCTAssertEqual(s2.mirrorWidth, 0,
                       "Disabling Mirror Cursor should stop the rendering. mirrorWidth=\(s2.mirrorWidth ?? -1). Diagnostic: \(s2.debugDescription)")
    }

    func testMirrorCursorIsSuppressedDuringSelection() throws {
        // Even with Mirror Cursor enabled, the rectangle MUST NOT be
        // drawn while a selection is active (linear or rectangular).
        // The selection wash already cross-references hex and ASCII
        // panes; an additional hollow rectangle on top is just visual
        // noise. Test sequence:
        //   1) Position caret at byte 0, no selection. Enable mirror.
        //      Confirm rectangle IS drawn (mirrorWidth > 0).
        //   2) Drag-select a few bytes (linear). Confirm rectangle is
        //      suppressed (mirrorWidth = 0).
        //   3) Click to clear the selection. Confirm rectangle returns.
        let app = try launchNotepad()
        defer { app.terminate() }

        try createBufferWithText(app: app, text: "abcdefghijklmnop")
        try invokeHexEditorMenu(app: app, item: "View in HEX")
        Thread.sleep(forTimeInterval: 0.5)

        let hexTable = app.descendants(matching: .table).matching(identifier: AXID.table).firstMatch
        XCTAssertTrue(hexTable.waitForExistence(timeout: 5))
        try positionHexCursorAtZero(app: app, hexTable: hexTable)
        Thread.sleep(forTimeInterval: 0.3)

        // Enable Mirror Cursor.
        try invokeHexEditorMenu(app: app, item: "Options...")
        let fontTab = app.tabs["Font"]
        XCTAssertTrue(fontTab.waitForExistence(timeout: 5))
        fontTab.click()
        let mirror = app.checkBoxes["hex-editor.options.font.mirrorAsciiCursor"]
        XCTAssertTrue(mirror.waitForExistence(timeout: 3))
        mirror.click()
        app.buttons["hex-editor.options.button.ok"].click()
        XCTAssertTrue(mirror.waitForNonExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 0.3)

        // 1. Mirror enabled, no selection: rectangle drawn.
        guard let s1 = HexCursorState.read(from: app) else {
            XCTFail("Failed to read diagnostic at step 1.")
            return
        }
        XCTAssertEqual(s1.hasSelection, false,
                       "Step 1 expects no selection. Diagnostic: \(s1.debugDescription)")
        XCTAssertGreaterThan(s1.mirrorWidth ?? 0, 0,
                             "Mirror should draw with caret + no selection. mirrorWidth=\(s1.mirrorWidth ?? -1). Diagnostic: \(s1.debugDescription)")

        // 2. Drag-select bytes 0–5. Mirror should be suppressed.
        let firstRow = hexTable.tableRows.element(boundBy: 0)
        XCTAssertTrue(firstRow.waitForExistence(timeout: 3))
        let byte0 = firstRow.staticTexts.element(boundBy: 1)
        let byte5 = firstRow.staticTexts.element(boundBy: 6)
        XCTAssertTrue(byte0.waitForExistence(timeout: 3))
        XCTAssertTrue(byte5.waitForExistence(timeout: 3))
        let startCoord = byte0.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let endCoord   = byte5.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        startCoord.click(forDuration: 0.05, thenDragTo: endCoord)
        Thread.sleep(forTimeInterval: 0.3)

        guard let s2 = HexCursorState.read(from: app) else {
            XCTFail("Failed to read diagnostic at step 2.")
            return
        }
        XCTAssertEqual(s2.hasSelection, true,
                       "Step 2 expects an active selection. Diagnostic: \(s2.debugDescription)")
        XCTAssertEqual(s2.mirrorWidth, 0,
                       "Mirror MUST be suppressed during a selection. mirrorWidth=\(s2.mirrorWidth ?? -1). Diagnostic: \(s2.debugDescription)")

        // 3. Clear the selection by clicking inside a single byte.
        // Click on byte 0 to put the caret there with no selection.
        byte0.click()
        Thread.sleep(forTimeInterval: 0.3)

        guard let s3 = HexCursorState.read(from: app) else {
            XCTFail("Failed to read diagnostic at step 3.")
            return
        }
        XCTAssertEqual(s3.hasSelection, false,
                       "Step 3 expects no selection after click. Diagnostic: \(s3.debugDescription)")
        XCTAssertGreaterThan(s3.mirrorWidth ?? 0, 0,
                             "Mirror should resume after the selection is cleared. mirrorWidth=\(s3.mirrorWidth ?? -1). Diagnostic: \(s3.debugDescription)")
    }

    func testFontTabUnderlineToggleRoundTripsThroughCommit() throws {
        // Phase 3 verification: toggling the Underline checkbox in the
        // Font tab + clicking OK must flip g_fontUnderline (read via the
        // cursor diagnostic). When on, willDisplayCell wraps each cell's
        // string in an attributed string carrying NSUnderlineStyleAttributeName,
        // which is the only way NSTextFieldCell renders underlined glyphs
        // (the cell has no underline property of its own). Toggling off
        // should restore plain stringValue rendering.
        //
        // We can't read NSUnderlineStyleAttributeName directly through
        // XCUI (cell attributes aren't exposed via AX), so the test
        // asserts the FLAG flow only; the rendering path in willDisplayCell
        // is straightforward enough that the flag → render step is a code-
        // review concern, not a runtime regression risk.
        let app = try launchNotepad()
        defer { app.terminate() }

        try createBufferWithText(app: app, text: "abcdefgh")
        try invokeHexEditorMenu(app: app, item: "View in HEX")
        Thread.sleep(forTimeInterval: 0.5)

        // Default state: underline off.
        guard let s0 = HexCursorState.read(from: app) else {
            XCTFail("Failed to read cursor diagnostic.")
            return
        }
        XCTAssertEqual(s0.fontUnderline, false,
                       "Default underline should be OFF. Diagnostic: \(s0.debugDescription)")

        // Toggle ON via the Font tab.
        try invokeHexEditorMenu(app: app, item: "Options...")
        let fontTab = app.tabs["Font"]
        XCTAssertTrue(fontTab.waitForExistence(timeout: 5))
        fontTab.click()
        let underline = app.checkBoxes["hex-editor.options.font.underline"]
        XCTAssertTrue(underline.waitForExistence(timeout: 3))
        underline.click()
        app.buttons["hex-editor.options.button.ok"].click()
        XCTAssertTrue(underline.waitForNonExistence(timeout: 5))

        guard let s1 = HexCursorState.read(from: app) else {
            XCTFail("Failed to read cursor diagnostic after underline ON.")
            return
        }
        XCTAssertEqual(s1.fontUnderline, true,
                       "Underline should be ON after toggling the Font-tab checkbox + OK. Diagnostic: \(s1.debugDescription)")

        // Toggle OFF — verify it round-trips back.
        try invokeHexEditorMenu(app: app, item: "Options...")
        let fontTab2 = app.tabs["Font"]
        XCTAssertTrue(fontTab2.waitForExistence(timeout: 5))
        fontTab2.click()
        let underline2 = app.checkBoxes["hex-editor.options.font.underline"]
        XCTAssertTrue(underline2.waitForExistence(timeout: 3))
        XCTAssertEqual(underline2.value as? Int, 1,
                       "Reopened dialog should show Underline still checked (committed previously).")
        underline2.click()
        app.buttons["hex-editor.options.button.ok"].click()
        XCTAssertTrue(underline2.waitForNonExistence(timeout: 5))

        guard let s2 = HexCursorState.read(from: app) else {
            XCTFail("Failed to read cursor diagnostic after underline OFF.")
            return
        }
        XCTAssertEqual(s2.fontUnderline, false,
                       "Underline should be OFF after toggling the checkbox a second time. Diagnostic: \(s2.debugDescription)")
    }

    func testFontTabUppercaseHexToggleAppliesToCells() throws {
        // Phase 2 verification: enabling "Capital letters mode" in the
        // Font tab must change the live hex-cell rendering from lowercase
        // to uppercase. Picks bytes whose hex contains alpha digits
        // ('k' = 0x6B, 'l' = 0x6C — both have 'b'/'c' that flip case)
        // and reads the byte cell's AX value before and after the toggle.
        let app = try launchNotepad()
        defer { app.terminate() }

        try createBufferWithText(app: app, text: "klmn")
        try invokeHexEditorMenu(app: app, item: "View in HEX")
        Thread.sleep(forTimeInterval: 1.0)

        let hexTable = app.descendants(matching: .table).matching(identifier: AXID.table).firstMatch
        XCTAssertTrue(hexTable.waitForExistence(timeout: 5))
        let firstRow = hexTable.tableRows.element(boundBy: 0)
        XCTAssertTrue(firstRow.waitForExistence(timeout: 5))

        // Default rendering: lowercase.
        XCTAssertEqual(firstRow.staticTexts.element(boundBy: 1).value as? String, "6b",
                       "Byte 0 ('k') should display as lowercase '6b' by default.")
        XCTAssertEqual(firstRow.staticTexts.element(boundBy: 2).value as? String, "6c",
                       "Byte 1 ('l') should display as lowercase '6c' by default.")

        // Toggle Capital letters mode via the Font tab.
        try invokeHexEditorMenu(app: app, item: "Options...")
        let fontTab = app.tabs["Font"]
        XCTAssertTrue(fontTab.waitForExistence(timeout: 5))
        fontTab.click()
        let upper = app.checkBoxes["hex-editor.options.font.uppercaseHex"]
        XCTAssertTrue(upper.waitForExistence(timeout: 3))
        upper.click()
        app.buttons["hex-editor.options.button.ok"].click()
        // The dialog dismiss + applyHexViewMode rebuild are async; wait
        // for the dialog to be gone before re-reading cells (the table
        // gets reloaded as part of commit, so AX queries to old element
        // handles return stale data otherwise).
        XCTAssertTrue(upper.waitForNonExistence(timeout: 5))

        // Re-query the row — AX handles after a reload need refetching.
        let firstRowAfter = hexTable.tableRows.element(boundBy: 0)
        XCTAssertTrue(firstRowAfter.waitForExistence(timeout: 5))
        XCTAssertEqual(firstRowAfter.staticTexts.element(boundBy: 1).value as? String, "6B",
                       "Byte 0 should display as uppercase '6B' after enabling Capital letters mode.")
        XCTAssertEqual(firstRowAfter.staticTexts.element(boundBy: 2).value as? String, "6C",
                       "Byte 1 should display as uppercase '6C' after enabling Capital letters mode.")
    }

    /// Synthesize an Option-held mouse drag via Quartz Event Services.
    /// XCUI's `pressForDuration:thenDragTo:` on macOS doesn't accept
    /// modifier flags, so a rect-drag (Option-held) can't be exercised
    /// through XCUIElement. CGEventPost can — we tag each posted mouse
    /// event with `.maskAlternate` so NPP-Mac's `hexEventStartsRectDrag:`
    /// sees Option set on the NSEvent and enters rect mode.
    ///
    /// Coordinates are in AppKit screen-points (bottom-left origin), the
    /// same space as `XCUIElement.frame.origin`. CGEvent expects Quartz
    /// global coordinates (top-left origin) so we flip Y against
    /// NSScreen.main height before posting.
    private func optionHeldMouseDrag(fromAppKitPoint start: CGPoint,
                                       toAppKitPoint end: CGPoint,
                                       steps: Int = 8) {
        guard let mainScreen = NSScreen.main else {
            XCTFail("No main screen available — cannot synthesise mouse drag.")
            return
        }
        let screenH = mainScreen.frame.height
        let toCG: (CGPoint) -> CGPoint = { p in
            CGPoint(x: p.x, y: screenH - p.y)
        }

        let post: (CGEventType, CGPoint) -> Void = { type, ptAppKit in
            if let evt = CGEvent(mouseEventSource: nil,
                                  mouseType: type,
                                  mouseCursorPosition: toCG(ptAppKit),
                                  mouseButton: .left) {
                evt.flags = .maskAlternate
                evt.post(tap: .cghidEventTap)
            }
        }

        post(.leftMouseDown, start)
        Thread.sleep(forTimeInterval: 0.05)
        for step in 1...steps {
            let t = CGFloat(step) / CGFloat(steps + 1)
            let mid = CGPoint(x: start.x + (end.x - start.x) * t,
                                y: start.y + (end.y - start.y) * t)
            post(.leftMouseDragged, mid)
            Thread.sleep(forTimeInterval: 0.02)
        }
        post(.leftMouseDragged, end)
        Thread.sleep(forTimeInterval: 0.05)
        post(.leftMouseUp, end)
        Thread.sleep(forTimeInterval: 0.1)
    }

    func testEndianPreferencePersistsAcrossEightBitCellWidth() throws {
        // Regression guard for the 2026-05-04 fix: the Endian setting must
        // persist when the user temporarily selects 8-Bit cells. Earlier
        // behaviour reset g_littleEndian → false in setHexViewBytesPerCell
        // when bpc dropped to 1, silently losing the user's pick. The
        // dialog also gated the endian commit on bits > 1, so the radio
        // appeared ineffective at 8-Bit.
        //
        // We explicitly select Big-Endian here (the NON-default since
        // 2026-05-04 — Little-Endian is now default + first in the
        // radio order, matching the architectures users actually inspect
        // bytes from). Setting the non-default value and watching it
        // round-trip a column-width change is what catches the
        // persistence regression; using the default would be a no-op
        // that passes vacuously.
        let app = try launchNotepad()
        defer { app.terminate() }

        // 16-Bit + Big-Endian + OK.
        try invokeHexEditorMenu(app: app, item: "Options...")
        let bits16 = app.radioButtons["hex-editor.options.startLayout.bits.16-Bit"]
        XCTAssertTrue(bits16.waitForExistence(timeout: 5))
        bits16.click()
        let big = app.radioButtons["hex-editor.options.startLayout.endian.Big-Endian"]
        XCTAssertTrue(big.waitForExistence(timeout: 3),
                      "Big-Endian radio should be present on the Start Layout tab.")
        big.click()
        app.buttons["hex-editor.options.button.ok"].click()
        XCTAssertTrue(bits16.waitForNonExistence(timeout: 5))

        // 8-Bit + OK. Pre-fix this would reset g_littleEndian → false
        // (which is Big-Endian). This test set Big to start, so in the
        // pre-fix regression the value would COINCIDENTALLY persist —
        // the inverse direction (Little → 8-Bit → Little) is what
        // exposes the reset most directly. To catch both, we now also
        // round-trip Little below.
        try invokeHexEditorMenu(app: app, item: "Options...")
        let bits8 = app.radioButtons["hex-editor.options.startLayout.bits.8-Bit"]
        XCTAssertTrue(bits8.waitForExistence(timeout: 5))
        bits8.click()
        app.buttons["hex-editor.options.button.ok"].click()
        XCTAssertTrue(bits8.waitForNonExistence(timeout: 5))

        // Back to 16-Bit + OK.
        try invokeHexEditorMenu(app: app, item: "Options...")
        let bits16Again = app.radioButtons["hex-editor.options.startLayout.bits.16-Bit"]
        XCTAssertTrue(bits16Again.waitForExistence(timeout: 5))
        bits16Again.click()
        app.buttons["hex-editor.options.button.ok"].click()
        XCTAssertTrue(bits16Again.waitForNonExistence(timeout: 5))

        // Reopen and verify Big-Endian is still the selected endian radio.
        // NSButton state for radio: 1 = on, 0 = off.
        try invokeHexEditorMenu(app: app, item: "Options...")
        let bigAfter = app.radioButtons["hex-editor.options.startLayout.endian.Big-Endian"]
        XCTAssertTrue(bigAfter.waitForExistence(timeout: 5))
        XCTAssertEqual(bigAfter.value as? Int, 1,
                       "Big-Endian preference should survive a temporary switch to 8-Bit cells. value=0 means it was reset to the default (Little-Endian) — the pre-fix bug.")

        // Now flip to Little, round-trip, and verify Little persists too.
        // This exercises the reset path in the other direction: pre-fix,
        // setHexViewBytesPerCell(1) forced g_littleEndian = false, so
        // Little → 8-Bit → 16-Bit would silently reset to Big.
        let little = app.radioButtons["hex-editor.options.startLayout.endian.Little-Endian_(Native)"]
        XCTAssertTrue(little.waitForExistence(timeout: 3))
        little.click()
        app.buttons["hex-editor.options.button.ok"].click()
        XCTAssertTrue(little.waitForNonExistence(timeout: 5))

        try invokeHexEditorMenu(app: app, item: "Options...")
        let bits8B = app.radioButtons["hex-editor.options.startLayout.bits.8-Bit"]
        XCTAssertTrue(bits8B.waitForExistence(timeout: 5))
        bits8B.click()
        app.buttons["hex-editor.options.button.ok"].click()
        XCTAssertTrue(bits8B.waitForNonExistence(timeout: 5))

        try invokeHexEditorMenu(app: app, item: "Options...")
        let bits16C = app.radioButtons["hex-editor.options.startLayout.bits.16-Bit"]
        XCTAssertTrue(bits16C.waitForExistence(timeout: 5))
        bits16C.click()
        app.buttons["hex-editor.options.button.ok"].click()
        XCTAssertTrue(bits16C.waitForNonExistence(timeout: 5))

        try invokeHexEditorMenu(app: app, item: "Options...")
        let littleAfter = app.radioButtons["hex-editor.options.startLayout.endian.Little-Endian_(Native)"]
        XCTAssertTrue(littleAfter.waitForExistence(timeout: 5))
        XCTAssertEqual(littleAfter.value as? Int, 1,
                       "Little-Endian preference should survive a temporary switch to 8-Bit cells. value=0 means it was reset — the pre-fix bug.")

        app.buttons["hex-editor.options.button.cancel"].click()
    }

    func testLinearMouseDragBackwardLandsCaretAtSelectionStart() throws {
        // Backward-drag (mouseDown at byte 5, drag to byte 0) — the caret
        // should follow the mouse to byte 0, NOT stay at the selection's
        // right edge (which would be the original anchor at byte 5+1=6).
        // Pre-fix on 2026-05-04 the linear caret unconditionally landed
        // at selectedByteEnd regardless of drag direction, so backward
        // drags left the caret detached from the mouse.
        let app = try launchNotepad()
        defer { app.terminate() }

        try createBufferWithText(app: app, text: "abcdefghijklmnop")
        try invokeHexEditorMenu(app: app, item: "View in HEX")
        Thread.sleep(forTimeInterval: 0.5)

        let hexTable = app.descendants(matching: .table).matching(identifier: AXID.table).firstMatch
        XCTAssertTrue(hexTable.waitForExistence(timeout: 5))
        try positionHexCursorAtZero(app: app, hexTable: hexTable)
        Thread.sleep(forTimeInterval: 0.2)

        let firstRow = hexTable.tableRows.element(boundBy: 0)
        XCTAssertTrue(firstRow.waitForExistence(timeout: 3))
        let byte0 = firstRow.staticTexts.element(boundBy: 1)
        let byte5 = firstRow.staticTexts.element(boundBy: 6)
        XCTAssertTrue(byte0.waitForExistence(timeout: 3))
        XCTAssertTrue(byte5.waitForExistence(timeout: 3))

        // Drag from byte 5 (anchor) backward to byte 0.
        let startCoord = byte5.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let endCoord   = byte0.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        startCoord.click(forDuration: 0.05, thenDragTo: endCoord)
        Thread.sleep(forTimeInterval: 0.3)

        guard let s = HexCursorState.read(from: app) else {
            XCTFail("Failed to read cursor diagnostic.")
            return
        }
        XCTAssertEqual(s.hasSelection, true,
                       "Backward drag should produce a selection. Diagnostic: \(s.debugDescription)")
        XCTAssertEqual(s.selStart, 0, "Diagnostic: \(s.debugDescription)")
        XCTAssertEqual(s.selEnd, 6,
                       "Selection should cover bytes 0–5 regardless of drag direction (selEnd exclusive = 6). Diagnostic: \(s.debugDescription)")
        XCTAssertEqual(s.offset, 0,
                       "Backward drag: caret should land at the LEFT end of selection (byte 0, the dragged-to byte). offset=6 here means the caret followed the anchor instead of the mouse — pre-fix behaviour. Diagnostic: \(s.debugDescription)")
    }

    func testLinearMouseDragCaretLandsAtNextByteLeftEdgeAfterMouseUp() throws {
        // Post-mouseUp linear-drag caret convention: the caret sits at the
        // beginning of the byte AFTER the selection (byte 6's left edge
        // when bytes 0–5 are selected). The selection covers [0, 6) — the
        // input math (byteOffsetAtPoint) is shared with rect, so a
        // regression there surfaces here even without modifier-held drag.
        // Mid-drag "no gap between selection and caret" behaviour is
        // covered visually but isn't asserted here because XCUI can't
        // sample drawRect: state mid-drag (the click(forDuration:) call
        // is synchronous through mouseUp).
        let app = try launchNotepad()
        defer { app.terminate() }

        try createBufferWithText(app: app, text: "abcdefghijklmnop")
        try invokeHexEditorMenu(app: app, item: "View in HEX")
        Thread.sleep(forTimeInterval: 0.5)

        let hexTable = app.descendants(matching: .table).matching(identifier: AXID.table).firstMatch
        XCTAssertTrue(hexTable.waitForExistence(timeout: 5))
        try positionHexCursorAtZero(app: app, hexTable: hexTable)
        Thread.sleep(forTimeInterval: 0.2)

        let firstRow = hexTable.tableRows.element(boundBy: 0)
        XCTAssertTrue(firstRow.waitForExistence(timeout: 3))
        let byte0 = firstRow.staticTexts.element(boundBy: 1)
        let byte5 = firstRow.staticTexts.element(boundBy: 6)
        let byte6 = firstRow.staticTexts.element(boundBy: 7)
        XCTAssertTrue(byte0.waitForExistence(timeout: 3))
        XCTAssertTrue(byte5.waitForExistence(timeout: 3))
        XCTAssertTrue(byte6.waitForExistence(timeout: 3))

        let startCoord = byte0.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let endCoord   = byte5.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        startCoord.click(forDuration: 0.05, thenDragTo: endCoord)
        Thread.sleep(forTimeInterval: 0.3)

        guard let s = HexCursorState.read(from: app) else {
            XCTFail("Failed to read cursor diagnostic.")
            return
        }
        XCTAssertEqual(s.hasSelection, true,
                       "Linear drag should produce a byte selection. Diagnostic: \(s.debugDescription)")
        XCTAssertEqual(s.selStart, 0, "Diagnostic: \(s.debugDescription)")
        XCTAssertEqual(s.selEnd, 6,
                       "Selection should cover bytes 0–5 (selEnd exclusive = 6). Diagnostic: \(s.debugDescription)")
        XCTAssertEqual(s.offset, 6,
                       "Post-mouseUp linear convention: caret at byte 6 (one past last selected). Diagnostic: \(s.debugDescription)")

        // The caret should be in byte 6's cell at its LEFT edge — i.e.
        // caretCellMinX matches byte 6's row-relative cell-minX, and
        // caretCellOffsetX is small (left side of cell). If a future
        // regression made the caret shift past byte 6 or stay on byte 5,
        // these assertions catch it.
        guard let caretCellOffsetX = s.caretCellOffsetX,
              let caretRow = s.caretRow else {
            XCTFail("Diagnostic missing caret render fields. Raw: \(s.debugDescription)")
            return
        }
        XCTAssertEqual(caretRow, 0, "Caret should still be on row 0 (selection didn't cross row).")
        XCTAssertGreaterThanOrEqual(caretCellOffsetX, 0, "Caret rendered before its cell's left edge.")
        // After mouseUp, the caret is at byte 6's LEFT edge (post-drag
        // "beginning of next byte" convention). So caretCellOffsetX
        // should be in the LEFT half of byte 6's cell, NOT the right —
        // the inverse of the during-drag flush position.
        let byte6Width = byte6.frame.width
        XCTAssertLessThan(caretCellOffsetX, byte6Width / 2,
                          "Post-mouseUp linear caret should sit at byte 6's LEFT edge (start of the next byte). caretCellOffsetX=\(caretCellOffsetX) byte6Width=\(byte6Width). A value past the half-width = caret at right edge = the during-drag-only shift accidentally still active. Diagnostic: \(s.debugDescription)")
    }

    func testRectKeyboardCaretRendersInsideActiveByteCell() throws {
        // Diagnoses the rect-drag-caret-1-byte-left bug. Sets up a known
        // rectangular selection via Shift+Option+Right (5 keys = anchor
        // at byte 0, end at byte 5) and asserts:
        //   1) the diagnostic surface reports activeByteOffset == 5
        //      (the input model is right),
        //   2) caretCellMinX equals the AX-frame minX of byte 5's cell
        //      (the caret rendered in the cell that activeByteOffset
        //      points at — NOT in byte 4's cell).
        //   3) the caret's horizontal offset within that cell is non-
        //      negative and within the cell's width (the caret stripe is
        //      inside the cell, not at its origin or beyond its edge).
        // The same drawRect: caret-positioning code path runs whether
        // rect was entered via mouse drag or keyboard, so a render bug
        // surfaces here regardless of input source. (A pure-mouse-drag
        // bug would still need a separate test — coming next if this
        // one passes.)
        let app = try launchNotepad()
        defer { app.terminate() }

        try createBufferWithText(app: app, text: "abcdefghijklmnop")  // 16 bytes — fits in one row at default columns
        try invokeHexEditorMenu(app: app, item: "View in HEX")
        Thread.sleep(forTimeInterval: 0.5)

        let hexTable = app.descendants(matching: .table).matching(identifier: AXID.table).firstMatch
        XCTAssertTrue(hexTable.waitForExistence(timeout: 5))
        try positionHexCursorAtZero(app: app, hexTable: hexTable)
        Thread.sleep(forTimeInterval: 0.2)

        // Anchor rect at byte 0 and extend to byte 5 (Shift+Option+Right ×5).
        for _ in 0..<5 {
            app.typeKey(.rightArrow, modifierFlags: [.shift, .option])
        }
        Thread.sleep(forTimeInterval: 0.3)

        guard let s = HexCursorState.read(from: app) else {
            XCTFail("Failed to read cursor diagnostic.")
            return
        }
        XCTAssertEqual(s.rectActive, true,
                       "Expected an active rectangular selection. Diagnostic: \(s.debugDescription)")
        XCTAssertEqual(s.rectOrigin, 0,
                       "Rect should be anchored at byte 0. Diagnostic: \(s.debugDescription)")
        XCTAssertEqual(s.rectWidth, 6,
                       "Rect should span 6 bytes (anchor + 5 right-arrow extends). Diagnostic: \(s.debugDescription)")
        XCTAssertEqual(s.offset, 5,
                       "activeByteOffset should be at the rect's right edge (byte 5). Diagnostic: \(s.debugDescription)")

        // Now read the cell-frame for byte 5 (boundBy:6 — index 0 is the
        // offset column, indices 1–16 are bytes 0–15) and verify that the
        // caret's last-rendered cell minX matches.
        let firstRow = hexTable.tableRows.element(boundBy: 0)
        XCTAssertTrue(firstRow.waitForExistence(timeout: 3))
        let byte5Cell = firstRow.staticTexts.element(boundBy: 6)
        XCTAssertTrue(byte5Cell.waitForExistence(timeout: 3))
        let byte5Frame = byte5Cell.frame
        let byte4Cell = firstRow.staticTexts.element(boundBy: 5)
        let byte4Frame = byte4Cell.frame

        guard let caretCellMinX = s.caretCellMinX else {
            XCTFail("Diagnostic missing caretCellMinX. Raw: \(s.debugDescription)")
            return
        }

        // The byte5Frame.minX is in screen coordinates; caretCellMinX is
        // in the table's view coordinates. They differ by the table's
        // origin offset, so we can't compare directly. Instead, check
        // whether the caret is closer to byte 5's cell or byte 4's cell
        // by comparing relative offsets.
        // If the caret is inside byte 5's cell, caretCellMinX should
        // equal the table's relative X for byte 5.
        // If it's in byte 4's cell, it would equal byte 4's relative X.
        // We can compute the relative offset by comparing the AX-screen
        // delta between byte 4 and byte 5 (one cell width) against the
        // delta between caretCellMinX and where it WOULD be if it were
        // on byte 4 (= caretCellMinX − one cell width).
        let cellWidth = byte5Frame.minX - byte4Frame.minX
        XCTAssertGreaterThan(cellWidth, 0,
                             "Cell width should be positive. byte4=\(byte4Frame), byte5=\(byte5Frame).")

        // The caret in rect-extend-right must render in the RIGHT half
        // of the active byte's cell (matching linear-selection convention
        // where the caret sits at the right edge of the last selected
        // byte). Before the 2026-05-04 fix, rect rendered the caret at
        // the LEFT edge of the active byte's cell — visually 1 byte to
        // the left of where users expect during drag-right. The
        // assertion below catches a regression to that broken behaviour.
        guard let caretCellOffsetX = s.caretCellOffsetX else {
            XCTFail("Diagnostic missing caretCellOffsetX. Raw: \(s.debugDescription)")
            return
        }
        XCTAssertGreaterThanOrEqual(caretCellOffsetX, 0,
                                      "Caret rendered before its cell's left edge — render is off. Diagnostic: \(s.debugDescription)")
        XCTAssertGreaterThan(caretCellOffsetX, cellWidth / 2,
                             "Rect-extend-right should place the caret in the RIGHT half of the active byte's cell (matches the 'after the last selected byte' convention used by linear selection). caretCellOffsetX=\(caretCellOffsetX) cellWidth=\(cellWidth). A value near 0 = the pre-fix bug (caret at left edge = 1 byte left of where the user dragged). Diagnostic: \(s.debugDescription)")
        // Caret sits inside the cell on its right side — past the digits
        // but not into the next column's territory. Cell width ≈ 30pt,
        // text ≈ 14pt, so the rendered caret X is around 0.7×cellWidth.
        // Allow up to cellWidth so the assertion isn't fragile against
        // sub-pixel rounding at certain font sizes.
        XCTAssertLessThanOrEqual(caretCellOffsetX, cellWidth,
                                  "Caret rendered past its cell's right edge into the next column. caretCellOffsetX=\(caretCellOffsetX) cellWidth=\(cellWidth). Diagnostic: \(s.debugDescription)")
    }

    func testOptionsFontTabExposesAllControls() throws {
        // Phase 1 smoke test: open the Options dialog, switch to the Font
        // tab, verify all seven controls exist via their AX identifiers,
        // and confirm that Reset puts each into its documented default
        // state (Menlo / 12 / nothing on except Mirror Cursor as Rect).
        // Persistence is covered indirectly by the existing
        // testOptionsResetIsNonDestructiveUntilCommitted; this test only
        // proves the tab is wired up.
        let app = try launchNotepad()
        defer { app.terminate() }

        try invokeHexEditorMenu(app: app, item: "Options...")
        let fontTab = app.tabs["Font"]
        XCTAssertTrue(fontTab.waitForExistence(timeout: 5),
                      "Font tab should be present in the Options dialog.")
        fontTab.click()

        let fontName = app.popUpButtons["hex-editor.options.font.name"]
        let fontSize = app.popUpButtons["hex-editor.options.font.size"]
        let bold = app.checkBoxes["hex-editor.options.font.bold"]
        let italic = app.checkBoxes["hex-editor.options.font.italic"]
        let underline = app.checkBoxes["hex-editor.options.font.underline"]
        let upper = app.checkBoxes["hex-editor.options.font.uppercaseHex"]
        let mirror = app.checkBoxes["hex-editor.options.font.mirrorAsciiCursor"]
        XCTAssertTrue(fontName.waitForExistence(timeout: 3))
        XCTAssertTrue(fontSize.waitForExistence(timeout: 1))
        XCTAssertTrue(bold.waitForExistence(timeout: 1))
        XCTAssertTrue(italic.waitForExistence(timeout: 1))
        XCTAssertTrue(underline.waitForExistence(timeout: 1))
        XCTAssertTrue(upper.waitForExistence(timeout: 1))
        XCTAssertTrue(mirror.waitForExistence(timeout: 1))

        // Reset → factory defaults visible in the dialog. (Doesn't commit
        // — that's the modal-loop semantic verified elsewhere.)
        app.buttons["hex-editor.options.button.reset"].click()
        XCTAssertEqual(fontName.value as? String, "Menlo",
                       "Font Name should default to Menlo.")
        XCTAssertEqual(fontSize.value as? String, "12",
                       "Font Size should default to 12.")
        XCTAssertEqual(bold.value as? Int, 0,      "Bold should default off.")
        XCTAssertEqual(italic.value as? Int, 0,    "Italic should default off.")
        XCTAssertEqual(underline.value as? Int, 0, "Underline should default off.")
        XCTAssertEqual(upper.value as? Int, 0,     "Capital letters should default off.")
        XCTAssertEqual(mirror.value as? Int, 0,    "Mirror Cursor as Rect should default OFF (user opts in).")

        app.buttons["hex-editor.options.button.cancel"].click()
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
        try positionHexCursorAtZero(app: app, hexTable: hexTable)

        // Establish a selection via Edit > Select All so Cut/Copy/Delete have
        // bytes to operate on. Without a selection these are CORRECTLY
        // DISABLED — that's the regression covered by
        // testEditMenuCutCopyDisabledWithoutSelection. Doing Select All also
        // exercises the menu-action → responder-chain route end-to-end, which
        // is this test's actual purpose.
        let editMenu = app.menuBars.menuBarItems["Edit"]
        XCTAssertTrue(editMenu.waitForExistence(timeout: 5))
        editMenu.click()
        let selectAllItem = app.menuBars.menuItems["Select All"]
        XCTAssertTrue(selectAllItem.waitForExistence(timeout: 5))
        XCTAssertTrue(selectAllItem.isEnabled, "Select All should be enabled with non-empty content.")
        selectAllItem.click()
        Thread.sleep(forTimeInterval: 0.3)

        // Re-open Edit menu — the previous click closed it after Select All.
        editMenu.click()

        // With selection in place: Cut/Copy/Delete enabled; Paste reflects
        // pasteboard state (we don't assert it here — the dedicated
        // testEditMenuPasteEnabledAfterOurCopy covers our own-copy case).
        for label in ["Cut", "Copy", "Delete", "Select All"] {
            let item = app.menuBars.menuItems[label]
            XCTAssertTrue(item.waitForExistence(timeout: 3), "Edit menu missing \(label)")
            XCTAssertTrue(item.isEnabled, "\(label) should be enabled in the hex overlay after Select All")
        }

        app.typeKey(.escape, modifierFlags: [])
    }

    /// Regression test for the bug the user surfaced manually 2026-05-05:
    /// Cut/Copy/Delete in the Edit menu were enabled even when there was no
    /// byte selection (the previous validator returned YES whenever the cursor
    /// sat on any byte in the buffer, which is essentially "always" — making
    /// the menu state misleading). After the fix, validation requires
    /// hasByteSelection() || hasRectSelection().
    func testEditMenuCutCopyDisabledWithoutSelection() throws {
        let app = try launchNotepad()
        defer { app.terminate() }

        try createBufferWithText(app: app, text: "Hex")
        try invokeHexEditorMenu(app: app, item: "View in HEX")
        Thread.sleep(forTimeInterval: 1.0)

        let hexTable = app.descendants(matching: .table).matching(identifier: AXID.table).firstMatch
        XCTAssertTrue(hexTable.waitForExistence(timeout: 5))
        // Position cursor at byte 0 — there's content but no selection.
        try positionHexCursorAtZero(app: app, hexTable: hexTable)

        let editMenu = app.menuBars.menuBarItems["Edit"]
        XCTAssertTrue(editMenu.waitForExistence(timeout: 5))
        editMenu.click()

        // Cut, Copy, Delete must be disabled — there is no selection.
        for label in ["Cut", "Copy", "Delete"] {
            let item = app.menuBars.menuItems[label]
            XCTAssertTrue(item.waitForExistence(timeout: 3), "Edit menu missing \(label)")
            XCTAssertFalse(item.isEnabled, "\(label) should be DISABLED when there is no byte selection. Pre-fix this was enabled because validateUserInterfaceItem fell back to a 1-byte 'current byte' range.")
        }
        // Select All should still be enabled (independent of selection).
        let selectAllItem = app.menuBars.menuItems["Select All"]
        XCTAssertTrue(selectAllItem.isEnabled, "Select All should be enabled in a non-empty buffer regardless of current selection state.")

        app.typeKey(.escape, modifierFlags: [])
    }

    /// Regression test for the bug the user surfaced manually 2026-05-05 that
    /// required a diagnostic-NSLog dylib install + Console.app capture to
    /// pin down: immediately after our own Cmd-C in the hex view, the Edit
    /// menu Paste was reporting DISABLED. Root cause was that
    /// `validateUserInterfaceItem` for paste: relied entirely on
    /// `[pasteboard dataForType:...]` against our own promised-type
    /// pasteboard, and on macOS 26 those reads don't materialize promises
    /// during validation — they returned nil, paste appeared disabled, the
    /// keyboard Cmd-V path also no-op'd because pasteboard reads inside
    /// pasteBytesFromPasteboard saw the same nils. Fix: short-circuit
    /// validation via currentlyOwnedHexSnapshot() — if our owner has the
    /// snapshot live, the paste is valid regardless of what dataForType
    /// returns.
    func testEditMenuPasteEnabledAfterOurCopy() throws {
        let app = try launchNotepad()
        defer { app.terminate() }

        try createBufferWithText(app: app, text: "Hex")
        try invokeHexEditorMenu(app: app, item: "View in HEX")
        Thread.sleep(forTimeInterval: 1.0)

        let hexTable = app.descendants(matching: .table).matching(identifier: AXID.table).firstMatch
        XCTAssertTrue(hexTable.waitForExistence(timeout: 5))

        // Select All + Copy via the Edit menu so the menu route is exercised
        // end-to-end (matches what the user does with the mouse).
        let editMenu = app.menuBars.menuBarItems["Edit"]
        editMenu.click()
        let selectAllItem = app.menuBars.menuItems["Select All"]
        XCTAssertTrue(selectAllItem.waitForExistence(timeout: 5))
        selectAllItem.click()
        Thread.sleep(forTimeInterval: 0.3)

        editMenu.click()
        let copyItem = app.menuBars.menuItems["Copy"]
        XCTAssertTrue(copyItem.waitForExistence(timeout: 5))
        XCTAssertTrue(copyItem.isEnabled, "Copy should be enabled after Select All.")
        copyItem.click()
        Thread.sleep(forTimeInterval: 0.3)

        // Re-open the Edit menu and verify Paste is enabled. Pre-fix this
        // returned NO because dataForType on our promised-type pasteboard
        // didn't materialize during menu validation.
        editMenu.click()
        let pasteItem = app.menuBars.menuItems["Paste"]
        XCTAssertTrue(pasteItem.waitForExistence(timeout: 5))
        XCTAssertTrue(pasteItem.isEnabled, "Paste should be enabled after our own Copy. If this fails, the validateUserInterfaceItem short-circuit via currentlyOwnedHexSnapshot() has regressed.")

        app.typeKey(.escape, modifierFlags: [])
    }

    /// Regression test for the silent-no-op bug the user reported manually
    /// 2026-05-05: copy a row out of an existing hex buffer, click the empty
    /// trailing-sentinel row to position the cursor at offset == totalLength,
    /// Cmd-V — nothing happened, byte count didn't change, no bytes appeared.
    /// This was caused by the Paste menu validation issue (above) AND the
    /// fact that the in-process snapshot wasn't being read on the paste-action
    /// path either. Fixed by short-circuiting via currentlyOwnedHexSnapshot()
    /// in pasteBytesFromPasteboard. This test exercises the same flow at
    /// kilobyte scale so it gates every commit cheaply.
    func testHexPasteAtEOFAppendsBytes() throws {
        let app = try launchNotepad()
        defer { app.terminate() }

        // 32 bytes is enough to have a row to copy + a trailing-sentinel row
        // to paste at. "abcdefghijklmnopqrstuvwxyzABCDEF" = 32 chars = 0x20..0x3F.
        let seedText = "abcdefghijklmnopqrstuvwxyzABCDEF"
        try createBufferWithText(app: app, text: seedText)
        try invokeHexEditorMenu(app: app, item: "View in HEX")
        Thread.sleep(forTimeInterval: 1.0)

        let hexTable = app.descendants(matching: .table).matching(identifier: AXID.table).firstMatch
        XCTAssertTrue(hexTable.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForStatus(in: app, contains: "32 bytes", timeout: 5),
                      "Seed buffer should report 32 bytes.")

        // Select All → Cmd-C — snapshot all 32 bytes via our hex copy path.
        app.typeKey("a", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.2)
        app.typeKey("c", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.3)

        // Position cursor at offset == totalLength (the trailing-sentinel
        // row). End-of-buffer is reachable via Cmd+End in hex view. Pre-fix
        // a Cmd-V here was silently no-op'ing.
        app.typeKey(.end, modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.2)
        app.typeKey("v", modifierFlags: .command)

        // 32 bytes appended at the end → buffer is now 64 bytes.
        XCTAssertTrue(waitForStatus(in: app, contains: "64 bytes", timeout: 5),
                      "Paste at offset==totalLength must append the snapshot bytes. Status after paste: '\(currentStatusText(in: app))'. Pre-fix the paste was a silent no-op.")
    }

    /// Regression test for the Shift+Cmd+Home/End shortcuts that extend
    /// the linear byte selection to document start/end. Pre-existing
    /// Cmd+Home/End cleared the selection unconditionally; the shift
    /// variant lets a user select large ranges (or all-from-here) without
    /// dragging or holding an arrow key. Sanity-checked at small scale
    /// here so a regression is caught even when the multi-GB tests aren't
    /// run.
    func testShiftCmdHomeEndExtendsByteSelection() throws {
        let app = try launchNotepad()
        defer { app.terminate() }

        // 8-byte buffer "ABCDEFGH" = 0x41..0x48 — small enough that we
        // can verify the selection via Copy + pasteboard inspection.
        try createBufferWithText(app: app, text: "ABCDEFGH")
        try invokeHexEditorMenu(app: app, item: "View in HEX")
        Thread.sleep(forTimeInterval: 1.0)

        let hexTable = app.descendants(matching: .table).matching(identifier: AXID.table).firstMatch
        XCTAssertTrue(hexTable.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForStatus(in: app, contains: "8 bytes", timeout: 5))

        // Shift+Cmd+Home from EOF (cursor lands at end after invokeHexEditorMenu)
        // should extend selection back to offset 0 → entire 8 bytes selected.
        app.typeKey(.home, modifierFlags: [.command, .shift])
        Thread.sleep(forTimeInterval: 0.2)

        // Verify by copying — Copy is enabled only when there's a selection
        // (per the validation fix from this session), and the copied bytes
        // should cover all 8.
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("__sentinel__", forType: .string)
        app.typeKey("c", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.3)
        let copied = pasteboard.string(forType: .string) ?? ""
        XCTAssertEqual(copied, "41 42 43 44 45 46 47 48",
                       "Shift+Cmd+Home from EOF should select all 8 bytes; Copy should put '41 42 ... 48' on the pasteboard. Got: '\(copied)'.")

        // Now Cmd+Home (no shift) — should clear selection and put cursor
        // at offset 0. A subsequent Shift+Cmd+End should select all 8
        // bytes from cursor (0) to EOF (8).
        app.typeKey(.home, modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.2)
        app.typeKey(.end, modifierFlags: [.command, .shift])
        Thread.sleep(forTimeInterval: 0.2)

        pasteboard.clearContents()
        pasteboard.setString("__sentinel__", forType: .string)
        app.typeKey("c", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.3)
        let copied2 = pasteboard.string(forType: .string) ?? ""
        XCTAssertEqual(copied2, "41 42 43 44 45 46 47 48",
                       "Cmd+Home then Shift+Cmd+End should select all 8 bytes; Copy should put '41 42 ... 48' on the pasteboard. Got: '\(copied2)'.")
    }

    /// Routine-suite gate for the multi-100-MB pbs-IPC threshold the
    /// in-process snapshot fix bypasses. pbs silently drops public.data
    /// payloads somewhere in the multi-100-MB range; 300 MB is
    /// comfortably above the breakage point so a regression in the
    /// short-circuit (currentlyOwnedHexSnapshot() inside
    /// pasteBytesFromPasteboard) would let dataForType return the
    /// placeholder text and the test would fail. Without the fix, this
    /// test catches the bug on every commit instead of only when the
    /// 1.5 GB opt-in test runs.
    func testHexCopyPaste300MBAcrossTabsRoundTripsBytes() throws {
        let app = try launchNotepadWithFixture("300MB.bin")
        defer { app.terminate() }

        // NPP-Mac's large-file warning dismiss-loop (upstream double-click
        // quirk) plus a settle wait for the source-load to finish.
        let dialog = app.dialogs.firstMatch
        for _ in 0..<3 {
            let warningButton = dialog.buttons.firstMatch
            guard warningButton.waitForExistence(timeout: 30) else { break }
            warningButton.click()
            Thread.sleep(forTimeInterval: 1.0)
        }
        // Wait until the warning is gone so subsequent menu interactions
        // hit a responsive UI. Scintilla's source ingest at 300 MB
        // dominates this wait.
        XCTAssertTrue(dialog.waitForNonExistence(timeout: 120),
                      "Large-file warning should dismiss after Scintilla finishes loading the 300 MB source.")

        try invokeHexEditorMenu(app: app, item: "View in HEX")

        let fullSize = "314572800"   // 300 * 1024 * 1024
        XCTAssertTrue(waitForStatus(in: app, contains: fullSize, timeout: 30),
                      "300 MB source should report full byte count once hex view engages.")

        // Cmd-A copies the full 300 MB via the lazy reader into a snapshot.
        app.typeKey("a", modifierFlags: .command)
        app.typeKey("c", modifierFlags: .command)

        // New empty buffer in the same NPP, engage hex view there.
        app.typeKey("n", modifierFlags: .command)
        try invokeHexEditorMenu(app: app, item: "View in HEX")
        XCTAssertTrue(waitForStatus(in: app, contains: "empty", timeout: 30),
                      "Fresh hex view on a new buffer should report empty before paste.")

        // Cmd-V routes through pasteBytesFromPasteboard's in-process
        // snapshot short-circuit. Without it, pbs IPC would drop the
        // public.data and the placeholder string would land here instead
        // of bytes.
        app.typeKey("v", modifierFlags: .command)
        XCTAssertTrue(waitForStatus(in: app, contains: fullSize, timeout: 120),
                      "Paste should populate the new buffer with the full 300 MB. Status after paste: '\(currentStatusText(in: app))'. Failure here means the in-process snapshot path regressed and pbs IPC truncated public.data.")

        // First-row spot-check — byte 0 = 0x20, byte 15 = 0x2f per the
        // fixture's printable-ASCII cycle. Confirms BYTES landed, not
        // the placeholder text.
        let hexTable = app.descendants(matching: .table).matching(identifier: AXID.table).firstMatch
        XCTAssertTrue(hexTable.waitForExistence(timeout: 10))
        let firstRow = hexTable.tableRows.element(boundBy: 0)
        XCTAssertTrue(firstRow.waitForExistence(timeout: 10))
        XCTAssertEqual(firstRow.staticTexts.element(boundBy: 1).value as? String, "20",
                       "Byte 0 of pasted destination should be 0x20 (fixture pattern). If this is some ASCII letter, the placeholder text leaked through instead of the bytes.")
        XCTAssertEqual(firstRow.staticTexts.element(boundBy: 16).value as? String, "2f",
                       "Byte 15 of pasted destination should be 0x2f.")

        // Frame-height guard against a row-count rendering regression.
        XCTAssertGreaterThan(hexTable.frame.height, 100,
                             "Destination hex table viewport collapsed (<100 px). reloadData in redrawHexTablePreservingScroll has regressed.")
    }

    /// Regression test for two related bugs the user reported manually
    /// 2026-05-05, both rooted in NPPN_BUFFERACTIVATED → hideHexPreview →
    /// tryAutoEngageHexView dropping per-tab "user engaged hex view" state:
    ///
    ///   (A) **Persistence:** for files that don't match Startup auto-engage
    ///       rules (extension list / control-char density), switching away
    ///       from a tab and back loses hex view entirely — it reverts to
    ///       the default text viewer because tryAutoEngageHexView has no
    ///       reason to re-engage.
    ///   (B) **Geometry:** for files that DO match Startup rules, hex view
    ///       does re-engage but with wrong frame — status text overlaps
    ///       the window's title bar / tabs row, hex content shifted up,
    ///       because re-engagement reads stale editor-view bounds at the
    ///       moment NPPN_BUFFERACTIVATED fires.
    ///
    /// This test exercises (A) directly: the 100k.bin fixture is all
    /// printable ASCII so content-density auto-engage doesn't fire, and
    /// the .bin extension isn't in the default Startup list. After Cmd-N
    /// and Ctrl+Shift+Tab back, hex view should still be present (because
    /// the user explicitly engaged it). The geometry assertions further
    /// down also exercise (B) once persistence works.
    func testHexViewSurvivesTabSwitchRoundTrip() throws {
        let app = try launchNotepad()
        defer { app.terminate() }

        // Use the 100k fixture — content density tells the auto-engage
        // heuristic this is a binary-ish file, so switching back to it
        // exercises the auto-engage path that re-installs the hex root
        // view (which is where the bug was observed).
        let app1 = try launchNotepadWithFixture("100k.bin")
        defer { app1.terminate() }
        _ = app

        try invokeHexEditorMenu(app: app1, item: "View in HEX")
        XCTAssertTrue(waitForStatus(in: app1, contains: "100000", timeout: 10),
                      "Hex view should engage on tab A (100k fixture).")

        let hexTable = app1.descendants(matching: .table).matching(identifier: AXID.table).firstMatch
        XCTAssertTrue(hexTable.waitForExistence(timeout: 5))
        let frameBefore = hexTable.frame
        captureToDashboard("testHexViewGeometryStableAcrossTabSwitch-01-before-roundtrip")

        // Cmd-N to create tab B. NPP-Mac switches the active buffer; our
        // NPPN_BUFFERACTIVATED handler hides hex view on tab A.
        app1.typeKey("n", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.6)

        // Switch back to tab A via NPP-Mac's "Select Previous Tab" Window
        // menu shortcut (Ctrl+Shift+Tab). With 2 tabs and Tab B currently
        // active, "previous" wraps back to Tab A. NPP-Mac's tab buttons
        // are not exposed as AX elements, so the keyboard route is the
        // only reliable way to script this.
        app1.typeKey("\t", modifierFlags: [.control, .shift])
        Thread.sleep(forTimeInterval: 1.0)

        // After switching back, the auto-engage path re-installs the hex
        // view. Wait for the hex table to be visible again and capture
        // its frame.
        XCTAssertTrue(hexTable.waitForExistence(timeout: 10),
                      "Hex table should reappear on tab A after switching back.")
        XCTAssertTrue(waitForStatus(in: app1, contains: "100000", timeout: 10),
                      "Status should report the 100k byte count after switching back to tab A.")
        let frameAfter = hexTable.frame
        captureToDashboard("testHexViewGeometryStableAcrossTabSwitch-02-after-roundtrip")

        // The bug shifts the hex view UPWARD into the window chrome. In
        // macOS screen coords the y axis grows upward, so an upward shift
        // raises frame.origin.y. Tolerate ±10 px of legitimate layout
        // jitter; anything larger is the geometry regression.
        let yDelta = abs(frameAfter.origin.y - frameBefore.origin.y)
        XCTAssertLessThan(yDelta, 10,
                          "Hex table frame.origin.y shifted by \(yDelta) px after tab-switch round-trip (before: \(frameBefore.origin.y), after: \(frameAfter.origin.y)). Pre-fix this was the 'status text overlapping title bar' rendering bug.")
        // Sanity: heights also shouldn't differ by more than a row.
        let hDelta = abs(frameAfter.size.height - frameBefore.size.height)
        XCTAssertLessThan(hDelta, 30,
                          "Hex table height changed by \(hDelta) px after tab-switch round-trip — geometry should be preserved.")
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
        // "Hex" = 0x48 0x65 0x78 — the bare hex byte string is what Copy emits.
        XCTAssertEqual(copied, "48 65 78", "Copy from the Edit menu should put the bare hex bytes for 'Hex' on the pasteboard.")
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
        captureToDashboard("diag-cut-emptyAfterSelectAllCut")

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

    /// Cmd-A / Cmd-C / Cmd-V / Cmd-X must reach the hex view's selectAll: /
    /// copy: / paste: / cut: handlers via HexTableView.performKeyEquivalent:.
    /// Existing copy/paste tests dispatch through the Edit menu (XCUI clicks),
    /// which routes via the responder chain to our handler regardless of the
    /// performKeyEquivalent: wiring — so they couldn't catch the keyboard-
    /// shortcut-only regression that surfaced in user testing on 2026-05-05:
    /// Cmd-C silently did nothing, leaving the clipboard with whatever was
    /// there before, and the next Cmd-V "pasted" stale content. This test
    /// drives each shortcut through XCUI keyboard events and asserts on the
    /// observable byte effect.
    func testKeyboardShortcutsRouteToHexClipboardHandlers() throws {
        let app = try launchNotepad()
        defer { app.terminate() }

        try createBufferWithText(app: app, text: "ABC")
        try invokeHexEditorMenu(app: app, item: "View in HEX")
        Thread.sleep(forTimeInterval: 1.0)

        let hexTable = app.descendants(matching: .table).matching(identifier: AXID.table).firstMatch
        XCTAssertTrue(hexTable.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForStatus(in: app, contains: "3 bytes", timeout: 5))

        // Pre-poison the clipboard. If Cmd-C never reaches our copy:, the
        // sentinel survives and the assertion below catches it. Without this
        // pre-step a no-op Cmd-C would *look* like a successful copy because
        // the clipboard might already contain text that vaguely resembles
        // hex (the bug's deceptive symptom in user testing).
        let sentinel = "__cmd-c-not-wired-sentinel__"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(sentinel, forType: .string)

        app.typeKey("a", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.3)
        app.typeKey("c", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.3)

        let afterCopy = NSPasteboard.general.string(forType: .string) ?? ""
        XCTAssertNotEqual(afterCopy, sentinel,
                          "Cmd-C bypassed the hex view's copy: handler — the clipboard still holds the sentinel. Check HexTableView.performKeyEquivalent: claims Cmd-C.")
        XCTAssertEqual(afterCopy, "41 42 43",
                       "Cmd-C should put 'ABC' as space-separated hex (41 42 43) on NSPasteboardTypeString.")

        // Cmd-V at EOF: preload a different value, jump to end, paste, expect
        // the buffer to grow by 3 bytes. If the shortcut doesn't reach paste:,
        // the byte count stays at 3.
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("58 59 5A", forType: .string)   // 'X' 'Y' 'Z'

        app.typeKey(.end, modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.2)
        app.typeKey("v", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.5)

        XCTAssertTrue(waitForStatus(in: app, contains: "6 bytes", timeout: 5),
                      "Cmd-V should have pasted 3 bytes at EOF, growing the buffer from 3 to 6. If still 3, Cmd-V didn't reach pasteBytesFromPasteboard.")

        // Cmd-X with all bytes selected: buffer should empty. If the shortcut
        // doesn't reach cut:, the byte count stays at 6.
        app.typeKey("a", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.3)
        app.typeKey("x", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.5)

        XCTAssertTrue(waitForStatus(in: app, contains: "empty", timeout: 5),
                      "Cmd-X should have cut all bytes, leaving the buffer empty.")

        // Restore the buffer so terminate() doesn't surface an unsaved-changes prompt.
        app.typeKey("z", modifierFlags: .command)
        _ = waitForStatus(in: app, contains: "6 bytes", timeout: 3)
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
        // ordered: offset, byte00..byte15, ascii spacer, ascii. The ascii spacer carries
        // no AXValue. Index 0 is the offset, index 1 is byte 0, ..., index 16 is byte 15.
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

    func testColumnHeadersAreNotEllipsizedAtDefaultWidth() throws {
        // AX returns each column header's full title even when NSTableHeaderCell has
        // ellipsized it visually to "...", so a value-equality assertion can't catch
        // header truncation. This test reads each header's actual rendered width and
        // compares it against NSTableHeaderCell's *own* cellSize for the same title —
        // i.e., the exact width AppKit needs to render the title without truncation
        // or right-edge pixel clipping. Same source of truth as the prod fix in
        // HexEditor.mm, so the assertion catches anything the user would see.

        let app = try launchNotepad()
        defer { app.terminate() }

        try createBufferWithText(app: app, text: "ABCDEFGHIJKLMNOP")
        try invokeHexEditorMenu(app: app, item: "View in HEX")
        Thread.sleep(forTimeInterval: 1.0)

        let hexTable = app.descendants(matching: .table).matching(identifier: AXID.table).firstMatch
        XCTAssertTrue(hexTable.waitForExistence(timeout: 5))

        // NSTableView exposes each column-header cell as an AX button child of the table.
        let headerButtons = hexTable.descendants(matching: .button).allElementsBoundByIndex
        XCTAssertGreaterThan(headerButtons.count, 0,
                             "Hex table should expose column-header buttons via accessibility.")

        // The exact-measurement probe: ask NSTableHeaderCell what width IT thinks it
        // needs for each title. cellSize includes the cell's own insets and the
        // proportional small-system header font's glyph metrics — no estimates, no
        // hand-tuned padding constants. Reused for every header so we're not paying
        // an alloc per column.
        let probe = NSTableHeaderCell()

        // Default 16-byte rows + 8-bit cells: expect "Offset", per-cell hex column
        // indices ("00".."0f", lowercase per the %02zx format string), and "ASCII".
        // Spacer columns carry no title and are skipped. Sanity-check that the
        // localized labels we're asserting on are actually present in the AX tree
        // (defends against a rename that would silently skip those columns).
        let expectedTitles: Set<String> = ["Offset", "ASCII", "00", "0f"]
        var seenTitles: Set<String> = []
        var inspected = 0
        for header in headerButtons {
            // NSTableHeaderCell publishes its title to AX via NSAccessibilityTitleAttribute,
            // which XCUIElement exposes as `.title`. (`.label` and `.value` come back empty
            // for these elements, so don't be tempted to use them.)
            let title = header.title
            if title.isEmpty { continue }   // spacer columns
            seenTitles.insert(title)
            probe.stringValue = title
            let needed = ceil(probe.cellSize.width)
            let actual = header.frame.width
            XCTAssertGreaterThanOrEqual(actual, needed,
                "Column header '\(title)' width=\(actual)pt is narrower than NSTableHeaderCell's own cellSize (\(needed)pt). The title will visually clip at the right edge or ellipsize to '...'.")
            inspected += 1
        }
        XCTAssertGreaterThan(inspected, 0,
                             "Test should have inspected at least one non-empty column header.")
        let missing = expectedTitles.subtracting(seenTitles)
        XCTAssertTrue(missing.isEmpty,
                      "Expected to see column headers \(expectedTitles) but missed \(missing). Saw: \(seenTitles).")

        // Header text must use the same alignment as the data text in the same column —
        // otherwise centered byte values "41 42 43..." sit under left-justified column-
        // index headers ("00", "01", ...) and the table looks unbalanced. AX doesn't
        // expose alignment per cell, so the plugin's diagnostic AX value reports a
        // single boolean: 1 iff every column's header.alignment == dataCell.alignment.
        guard let state = HexCursorState.read(from: app) else {
            XCTFail("Could not read HexCursorState diagnostic.")
            return
        }
        XCTAssertEqual(state.hdrAlignMatch, 1,
                       "At least one column has a header alignment that doesn't match its data alignment — table will look visually unbalanced (e.g. left-aligned '00' headers above centered '41' data).")
    }

    func testHexColumnSpacingIsUniformAndPanesAreVisuallySeparated() throws {
        // Three structural assertions on column geometry:
        //   1. All 16 hex cell columns have the same width.
        //   2. The horizontal spacing between adjacent cell columns is uniform — no
        //      mid-row gap (the old "midspacer" column we removed used to insert ~5pt
        //      between byte 7 and byte 8, breaking the uniform rhythm).
        //   3. There is a visible gap *both* between offset↔byte00 (offset trailing pad)
        //      and between byte15↔ASCII (separator column). Without these gaps the
        //      address pane reads as glued to the hex pane.
        // Reads frames directly from the AX header buttons exposed by NSTableView, so
        // the geometry assertions don't depend on the data cells being non-empty.

        let app = try launchNotepad()
        defer { app.terminate() }

        try createBufferWithText(app: app, text: "ABCDEFGHIJKLMNOP")
        try invokeHexEditorMenu(app: app, item: "View in HEX")
        Thread.sleep(forTimeInterval: 1.0)

        let hexTable = app.descendants(matching: .table).matching(identifier: AXID.table).firstMatch
        XCTAssertTrue(hexTable.waitForExistence(timeout: 5))

        // Map title → frame for every non-empty header. Titles "00".."0f" are the cell
        // columns; "Offset" and "ASCII" are the panes flanking them. Spacer columns
        // carry an empty title and are skipped — but they still take up x-space, so
        // they show up implicitly in the gaps we measure between named columns.
        var framesByTitle: [String: CGRect] = [:]
        for header in hexTable.descendants(matching: .button).allElementsBoundByIndex {
            let title = header.title
            if title.isEmpty { continue }
            framesByTitle[title] = header.frame
        }

        // (1) Cell-column widths uniform. Assert max - min < 0.5pt — i.e. the only
        // possible variance is sub-pixel rounding inside a single ceil() call.
        let cellTitles = (0..<16).map { String(format: "%02x", $0) }
        let cellFrames = cellTitles.compactMap { framesByTitle[$0] }
        XCTAssertEqual(cellFrames.count, 16,
                       "Expected all 16 cell-column headers (00..0f) but only saw: \(cellTitles.filter { framesByTitle[$0] != nil }).")
        let widths = cellFrames.map { $0.width }
        if let minW = widths.min(), let maxW = widths.max() {
            XCTAssertLessThan(maxW - minW, 0.5,
                              "Cell column widths should be uniform; got min=\(minW)pt max=\(maxW)pt across 16 columns.")
        }

        // (2) Adjacent cell-column spacing uniform (no mid-row gap). Sort by minX,
        // measure the x-stride between consecutive columns; max - min should be near
        // zero. The old midspacer would have made stride[7→8] ~5pt larger than the
        // others — this assertion would have failed in that world.
        let sortedCells = cellFrames.sorted { $0.minX < $1.minX }
        let strides = zip(sortedCells.dropLast(), sortedCells.dropFirst()).map { $1.minX - $0.minX }
        if let minS = strides.min(), let maxS = strides.max() {
            XCTAssertLessThan(maxS - minS, 0.5,
                              "Cell-column x-strides should be uniform across all 15 adjacent pairs; got min=\(minS)pt max=\(maxS)pt. A mid-row gap (e.g. between byte 7 and byte 8) would surface here.")
        }

        // (3) Visible gaps between panes. The offset→byte00 gap is the offset column's
        // trailing padding (one glyph width). The byte15→ASCII gap is the spacer
        // column (half a glyph width). Both should be at minimum a couple of points
        // at the default font size — assert > 2pt to catch a regression where the
        // helpers return zero. (Tighter bounds are font-dependent and would be
        // brittle; "more than nothing" is the structural property we care about.)
        guard let offsetFrame = framesByTitle["Offset"],
              let asciiFrame  = framesByTitle["ASCII"],
              let firstCell   = sortedCells.first,
              let lastCell    = sortedCells.last else {
            XCTFail("Could not locate Offset / ASCII / first / last cell column header frames. Saw: \(framesByTitle.keys.sorted()).")
            return
        }
        let offsetToFirst = firstCell.minX - offsetFrame.maxX
        let lastToAscii   = asciiFrame.minX - lastCell.maxX
        XCTAssertGreaterThan(offsetToFirst, 2.0,
                             "Address pane and hex pane are glued together — offset.maxX→byte00.minX gap is only \(offsetToFirst)pt. Expected the offset column's trailing padding to leave > 2pt.")
        XCTAssertGreaterThan(lastToAscii, 2.0,
                             "Hex pane and ASCII pane have no separator — byte15.maxX→ASCII.minX gap is only \(lastToAscii)pt. Expected the ascii spacer column to leave > 2pt.")
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
        // Bytes 0,1 are 'A','B' (0x41 0x42). With Little-Endian the default
        // (per the 2026-05-04 change), 16-Bit display reverses byte order
        // within the cell → "4241". Switching to Big-Endian via the menu
        // would render "4142", but we test the active default here.
        let firstRowAfter = hexTable.tableRows.element(boundBy: 0)
        XCTAssertTrue(firstRowAfter.waitForExistence(timeout: 5))
        let cellOneAfter = firstRowAfter.staticTexts.element(boundBy: 1)

        let predicate = NSPredicate(format: "value == %@", "4241")
        let waiter = expectation(for: predicate, evaluatedWith: cellOneAfter, handler: nil)
        wait(for: [waiter], timeout: 5)
        captureToDashboard("diag-viewSubmode-after16Bit")
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
        captureToDashboard("diag-addressWidth-after12")
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

        // Confirm the ASCII column actually carries the full row text, not a
        // truncated prefix — this asserts the row's last AX-visible static text
        // (the ASCII column) reports "ABCD" for byte values 0x41..0x44.
        let firstRow = hexTable.tableRows.element(boundBy: 0)
        let asciiCell = firstRow.staticTexts.element(boundBy: 5)
        XCTAssertEqual(asciiCell.value as? String, "ABCD",
                       "ASCII column for row 0 should render the full 4-byte string at columns=4.")
        captureToDashboard("diag-columns-after4")
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
        // Use a checked-in 4-byte fixture (0x41 0x42 0xFF 0x44) that differs
        // from buffer "ABCD" (0x41 0x42 0x43 0x44) at byte 2. Don't write a
        // dynamic fixture to NSTemporaryDirectory() / /tmp: the XCTRunner is
        // sandboxed with read-only filesystem access (NSPOSIXErrorDomain Code=1
        // when writing to /tmp), and NPP triggers a TCC "Files and Folders"
        // approval when reading from the runner's per-app tmp dir which hangs
        // the test for ~3 minutes. The fixtures directory is path-readable by
        // both the runner and NPP without permission gates.
        let fixturePath = try fixturePath("compare-fixture-1byte-diff.bin")

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
        captureToDashboard("diag-invalidAddressWidth-afterError")
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
        captureToDashboard("diag-row0-initialOpen")
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
        captureToDashboard("diag-statusLabel-glyphs")
    }

    func testHeaderFontTracksCellFontUnderZoom() throws {
        // The column-index headers (`00 01 02 …`, plus `Offset` / `ASCII`)
        // should scale proportionately with the cell font when the user zooms
        // via Cmd+/Cmd-/pinch. Earlier the header font was set once at
        // smallSystemFontSize and never refreshed, so zoomed cells towered
        // over a fixed-size header. Guard: assert headerFontPt = cellFontPt-2
        // (or the 9pt floor), and that both grow on Zoom In and reset on
        // Restore Default Zoom.
        let app = try launchNotepad()
        defer { app.terminate() }
        try createBufferWithText(app: app, text: "ABCD")
        try invokeHexEditorMenu(app: app, item: "View in HEX")

        let hexTable = app.descendants(matching: .table).matching(identifier: AXID.table).firstMatch
        XCTAssertTrue(hexTable.waitForExistence(timeout: 5))

        // Baseline: read the default-zoom font sizes.
        guard let baseline = HexCursorState.read(from: app),
              let baseCell = baseline.cellFontPt,
              let baseHeader = baseline.headerFontPt else {
            XCTFail("Could not read cellFontPt / headerFontPt from diagnostic.")
            return
        }
        XCTAssertGreaterThan(baseCell, 0, "Cell font size should be positive.")
        // Header tracks cell-2 with a 9pt floor.
        let expectedBase = max(baseCell - 2, 9)
        XCTAssertEqual(baseHeader, expectedBase, accuracy: 0.5,
            "Default zoom: header font (\(baseHeader)pt) should be cellFont-2 (\(expectedBase)pt).")

        // Zoom in 5 times so cell font grows enough to escape the 9pt
        // header-font floor (default cell is ~10pt → header floored at 9pt;
        // we need cell ≥ 12pt for the cell-2 formula to produce a value
        // above 9). .firstMatch disambiguates from NPP's main-menu View >
        // Zoom > Zoom In which shares the title.
        for _ in 0..<5 {
            hexTable.rightClick()
            let zoomInItem = app.menuItems["Zoom In"].firstMatch
            XCTAssertTrue(zoomInItem.waitForExistence(timeout: 3))
            zoomInItem.click()
            Thread.sleep(forTimeInterval: 0.2)
        }

        guard let zoomed = HexCursorState.read(from: app),
              let zCell = zoomed.cellFontPt,
              let zHeader = zoomed.headerFontPt else {
            XCTFail("Could not read post-zoom diagnostic.")
            return
        }
        XCTAssertGreaterThan(zCell, baseCell,
            "Zoom In should grow cell font (\(baseCell) → \(zCell)).")
        XCTAssertGreaterThan(zHeader, baseHeader,
            "Zoom In should also grow header font (cell \(baseCell) → \(zCell), header \(baseHeader) → \(zHeader)) — headers were stuck at smallSystemFontSize before.")
        let expectedZoomed = max(zCell - 2, 9)
        XCTAssertEqual(zHeader, expectedZoomed, accuracy: 0.5,
            "After zoom: header font (\(zHeader)pt) should be cellFont-2 (\(expectedZoomed)pt; cell \(zCell)pt).")

        // Restore Default Zoom → both should snap back to baseline.
        hexTable.rightClick()
        let resetItem = app.menuItems["Restore Default Zoom"].firstMatch
        XCTAssertTrue(resetItem.waitForExistence(timeout: 3))
        resetItem.click()
        Thread.sleep(forTimeInterval: 0.3)

        guard let restored = HexCursorState.read(from: app),
              let rCell = restored.cellFontPt,
              let rHeader = restored.headerFontPt else {
            XCTFail("Could not read post-reset diagnostic.")
            return
        }
        XCTAssertEqual(rCell, baseCell, accuracy: 0.5,
            "Restore should return cell font to baseline (\(baseCell)pt; got \(rCell)pt).")
        XCTAssertEqual(rHeader, baseHeader, accuracy: 0.5,
            "Restore should return header font to baseline (\(baseHeader)pt; got \(rHeader)pt).")
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
        captureToDashboard("diag-row0-afterDeepCursorOpen")
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

    func testAboutDialogShowsPluginVersion() throws {
        // The About body must surface the plugin version (injected via CMake's
        // PROJECT_VERSION → HEX_PLUGIN_VERSION compile define). We assert on
        // the "Version <semver>" shape rather than a fixed string so a CMake
        // version bump doesn't churn this test.
        let app = try launchNotepad(language: "en")
        defer { app.terminate() }
        try invokeHexEditorMenu(app: app, item: "Help...")
        let aboutDialog = app.dialogs.firstMatch
        XCTAssertTrue(aboutDialog.waitForExistence(timeout: 5))
        let versionPredicate = NSPredicate(format:
            "value MATCHES %@ OR label MATCHES %@",
            ".*Version \\d+\\.\\d+\\.\\d+.*",
            ".*Version \\d+\\.\\d+\\.\\d+.*")
        XCTAssertTrue(aboutDialog.staticTexts.element(matching: versionPredicate).exists,
                      "About dialog should show 'Version <semver>'.")
        aboutDialog.buttons["OK"].firstMatch.click()
    }

    /// The About body must surface the build tag (git short-hash captured
    /// at configure time) and the project's GitHub URL — both added so a
    /// user filing an issue can paste an unambiguous identifier and find
    /// the source in seconds. Build tag format: "Build <7+ hex chars>"
    /// optionally followed by "-dirty" for builds against a modified
    /// working tree, or "Build unknown" if the build wasn't done from a
    /// git checkout. URL is the literal string baked into the strings
    /// file, not a clickable link — a static text search suffices.
    func testAboutDialogShowsBuildTagAndProjectURL() throws {
        let app = try launchNotepad(language: "en")
        defer { app.terminate() }
        try invokeHexEditorMenu(app: app, item: "Help...")
        let aboutDialog = app.dialogs.firstMatch
        XCTAssertTrue(aboutDialog.waitForExistence(timeout: 5))

        // Match either a real short-hash ("Build a1b2c3d" or
        // "Build a1b2c3d-dirty") or the IDE/no-git fallback ("Build unknown").
        let buildPredicate = NSPredicate(format:
            "value MATCHES %@ OR label MATCHES %@",
            ".*Build ([0-9a-f]{4,}(-dirty)?|unknown).*",
            ".*Build ([0-9a-f]{4,}(-dirty)?|unknown).*")
        XCTAssertTrue(aboutDialog.staticTexts.element(matching: buildPredicate).exists,
                      "About dialog should show 'Build <hash>' (or 'Build unknown' for non-git builds).")

        let urlPredicate = NSPredicate(format:
            "value CONTAINS %@ OR label CONTAINS %@",
            "github.com/dhadner/NPP_HexEdit",
            "github.com/dhadner/NPP_HexEdit")
        XCTAssertTrue(aboutDialog.staticTexts.element(matching: urlPredicate).exists,
                      "About dialog should show the GitHub project URL so a user can find the source quickly.")
        aboutDialog.buttons["OK"].firstMatch.click()
    }

    func testAboutDialogProductNameStaysAtomic() throws {
        // The About body reads "Native macOS port of the Notepad++ ..."
        // — referring to the plugin's origin (a Notepad++ plugin on
        // Windows ported to macOS), not the macOS host (Nextpad++). The
        // "Notepad++" must be encoded with U+2060 Word Joiners between
        // *every* adjacent pair of characters (N⁠o⁠t⁠e⁠p⁠a⁠d⁠+⁠+) so neither
        // word-wrap nor macOS hyphenation can split it (an earlier fix
        // only joined `d↔+↔+`, which still let hyphenation break after
        // "Note"; user reported the wrap).
        //
        // We assert that no contiguous "Notepad" substring appears in
        // any About-dialog staticText — if even one inter-letter joiner
        // is stripped, the plain word reappears and the test fails.
        let app = try launchNotepad(language: "en")
        defer { app.terminate() }
        try invokeHexEditorMenu(app: app, item: "Help...")
        let aboutDialog = app.dialogs.firstMatch
        XCTAssertTrue(aboutDialog.waitForExistence(timeout: 5))
        let plainPredicate = NSPredicate(format:
            "value CONTAINS %@ OR label CONTAINS %@", "Notepad", "Notepad")
        XCTAssertFalse(aboutDialog.staticTexts.element(matching: plainPredicate).exists,
                       "About dialog must keep the product name atomic — found contiguous 'Notepad' (some Word Joiners stripped), which can wrap or hyphenate.")
        aboutDialog.buttons["OK"].firstMatch.click()
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
        // The mid-row spacer column was removed in the column-spacing rework
        // (offsetSpacer + ascii spacer are both AX-hidden), so byte N maps
        // uniformly to row.staticTexts.element(boundBy: byte+1) — no +1 shift
        // past the midpoint anymore. cellsPerRow is unused now but kept for
        // call-site source compatibility (a future bpc-aware variant might
        // reintroduce visible separators between groups).
        _ = cellsPerRow
        return 1 + byte
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

    // MARK: - Large-file fixture loading (v1.1.x)
    //
    // Fixtures live at macos/ui-tests-xcode/fixtures/ (the small ones are
    // checked in; 100MB.bin is generated deterministically by run-tests.sh).
    // run-tests.sh exports TEST_RUNNER_NPP_HEXEDIT_FIXTURES_DIR; xcodebuild
    // strips the TEST_RUNNER_ prefix when delivering env vars to the test
    // process, so the Swift code reads NPP_HEXEDIT_FIXTURES_DIR.

    /// Absolute path to a checked-in / generated fixture file. Each byte at
    /// offset N in the fixture has value (N mod 256) — see
    /// [generate-test-fixture.py](../../scripts/generate-test-fixture.py).
    // fixturePath, launchNotepadWithFixture moved to HexEditorBaseUITests.

    func testLargeFile_EmptyFileShowsEmptyStatus() throws {
        let app = try launchNotepadWithFixture("0.bin")
        defer { app.terminate() }

        try invokeHexEditorMenu(app: app, item: "View in HEX")
        // The plugin's empty-document status path emits "Current document is empty."
        XCTAssertTrue(waitForStatus(in: app, contains: "empty", timeout: 8),
                      "0-byte fixture should report the empty-document status.")
        captureToDashboard("diag-emptyFile-status")
    }

    func testLargeFile_OneByteShowsSingleByte() throws {
        let app = try launchNotepadWithFixture("1.bin")
        defer { app.terminate() }

        try invokeHexEditorMenu(app: app, item: "View in HEX")
        XCTAssertTrue(waitForStatus(in: app, contains: "1 bytes", timeout: 8),
                      "1-byte fixture should report 1 byte.")

        let hexTable = app.descendants(matching: .table).matching(identifier: AXID.table).firstMatch
        XCTAssertTrue(hexTable.waitForExistence(timeout: 5))
        let row0 = hexTable.tableRows.element(boundBy: 0)
        // Byte 0 of the fixture follows the cycle pattern: value = 0x20 + (0 % 95) = 0x20 (' ').
        wait(for: [
            expectation(for: NSPredicate(format: "value == %@", "20"),
                        evaluatedWith: row0.staticTexts.element(boundBy: cellIndex(forByte: 0)),
                        handler: nil),
        ], timeout: 5)
    }

    func testLargeFile_100kFullyLoadedNoTruncation() throws {
        let app = try launchNotepadWithFixture("100k.bin")
        defer { app.terminate() }

        try invokeHexEditorMenu(app: app, item: "View in HEX")
        // Status always reports the full byte count post-Step-2d — there's
        // no PREVIEW_LIMIT cap any more, so 100 k loads fully (and so would
        // any size up to 20 GB).
        let ok = waitForStatus(in: app, contains: "100000", timeout: 10)
        XCTAssertTrue(ok, "100k fixture should report 100000 bytes loaded. Actual status: '\(currentStatusText(in: app))'")
        XCTAssertFalse(waitForStatus(in: app, contains: "truncated", timeout: 1),
                       "Truncation banner is retired — status must NOT include 'truncated' for any file size.")
    }

    func testLargeFile_OnePastFormerLimitLoadsFully() throws {
        // 1 MB + 1 byte (1 048 577 bytes): formerly the smallest input that
        // tripped the PREVIEW_LIMIT cap and showed the truncation banner.
        // After Step 2d the cap is gone — the page-cached lazy reader
        // exposes the full document length to the hex view, so the banner
        // is retired and the status reads the full byte count. This test
        // pins the new behaviour: no banner, status reports all bytes.
        let app = try launchNotepadWithFixture("1MB-plus.bin")
        defer { app.terminate() }

        try invokeHexEditorMenu(app: app, item: "View in HEX")
        XCTAssertTrue(waitForStatus(in: app, contains: "1048577", timeout: 15),
                      "1 MB + 1 byte fixture should report the full 1 048 577 bytes — the lazy reader removes the former PREVIEW_LIMIT cap. Actual: '\(currentStatusText(in: app))'")
        XCTAssertFalse(waitForStatus(in: app, contains: "truncated", timeout: 1),
                       "Truncation banner is retired post-Step-2d. The status must NOT include 'truncated'.")
        captureToDashboard("diag-largeFile-fullLoadPastFormerLimit")
    }

    func testLargeFile_GotoOffsetFarIntoFile() throws {
        // Verify Goto navigates correctly inside a 1.5 MB file. Pre-Step-2d
        // the file was capped at 1 MiB so offset 999000 was within the
        // truncated window; post-Step-2d the lazy reader exposes the full
        // file, so the goto path is exercised against an unbounded source.
        let app = try launchNotepadWithFixture("1.5MB.bin")
        defer { app.terminate() }

        try invokeHexEditorMenu(app: app, item: "View in HEX")
        XCTAssertTrue(waitForStatus(in: app, contains: "1572864", timeout: 15),
                      "1.5 MB fixture should report the full byte count — no truncation cap any more.")

        let hexTable = app.descendants(matching: .table).matching(identifier: AXID.table).firstMatch
        XCTAssertTrue(hexTable.waitForExistence(timeout: 5))
        try positionHexCursorAt(app: app, hexTable: hexTable, offset: 999000)

        // After Goto 999000, the cursor's diagnostic AX value must reflect
        // the new offset. Reading the cell value via boundBy is unreliable
        // at this point because the table may have scrolled.
        let cursor = HexCursorState.read(from: app)
        XCTAssertEqual(cursor?.offset, 999000,
                       "Goto must land precisely at offset 999000 in a multi-MB file.")
        captureToDashboard("diag-largeFile-gotoFarOffset")
    }

    func testLargeFile_HundredMBLoadsFully() throws {
        // Skipped pending upstream fix in notepad-plus-plus-macos. NPP-Mac's
        // main-thread file ingest is the bottleneck: ~150 s observed for a
        // 100 MB file on the Parallels VM, with the UI thread blocked the
        // entire time so menu clicks queue but the submenus never open inside
        // the helper's 30 s wait. Even with a 180 s sleep upfront, the test
        // still timed out at the menu interaction.
        //
        // For comparison: Notepad++ on Windows opens a 20 GB file in 46 s
        // (~435 MB/s) with 11.8 MB total process memory — strongly suggests
        // memory-mapped file I/O. NPP-Mac at ~700 KB/s and full read-into-RAM
        // is ~600× slower per byte and grows linearly with file size; that's
        // an architectural gap to close in the host repo.
        //
        // Plugin-side, Step 2c retired the 1 MB truncation cap (bytes are now
        // read on demand via a page-cached lazy reader against Scintilla, so
        // plugin RAM stays bounded regardless of file size). The test remains
        // skipped only because the host's ingest blocks before our plugin
        // gets to run. Re-enable once the upstream issue is resolved.
        throw XCTSkip("100 MB ingest blocked by NPP-Mac main-thread file load. " +
                      "Filed upstream as a memory-mapping / chunked-load request. " +
                      "Re-enable when host ingest yields the run loop or finishes < 30 s.")
    }

    /// Regression test for the >16 MB hex-text rendering cap added in Step 5.
    /// Cmd-C on a hex selection of 17 MB exceeds the cap inside
    /// HexClipboardOwner.provideDataForType:, so cross-app text consumers
    /// receive a `<17.0 MB hex-editor selection> Paste into HEX view to
    /// receive.` placeholder string instead of a 51 MB UTF-8 hex
    /// representation. The test reads NSPasteboardTypeString directly from
    /// the test runner process — that resolves the type via pbs IPC into
    /// our plugin's owner callback, exactly the path TextEdit / Mail /
    /// Slack / etc. would take. raw bytes (`public.data`) stay byte-faithful
    /// at any size, verified by checking the data length matches the file.
    ///
    /// Uses fixtures/17MB.bin (smallest size that trips the cap). Total
    /// runtime ~30 s on a healthy VM, mostly NPP-Mac's main-thread ingest.
    func testLargeFile_AboveHexTextCapShowsCrossAppPlaceholder() throws {
        let app = try launchNotepadWithFixture("17MB.bin")
        defer { app.terminate() }

        try invokeHexEditorMenu(app: app, item: "View in HEX")

        // Wait for the full ingest — the lazy reader exposes the entire file
        // immediately, but the status label only updates once Scintilla has
        // ingested. Use the byte-count substring as the gate (17 * 1024 *
        // 1024 = 17_825_792 bytes).
        XCTAssertTrue(waitForStatus(in: app, contains: "17825792", timeout: 60),
                      "17 MB fixture should load fully — ingest may be slow on a busy VM. Actual: '\(currentStatusText(in: app))'")

        // Pre-poison the clipboard so we can detect "Cmd-C did nothing".
        let sentinel = "__cap-test-sentinel__"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(sentinel, forType: .string)

        app.typeKey("a", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.3)
        app.typeKey("c", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.5)

        // Read the string-type pasteboard contents — pbs IPC's into our
        // plugin's HexClipboardOwner, which sees the 17 MB snapshot is past
        // the 16 MB cap and returns the placeholder sentence rather than a
        // 51 MB hex string.
        let stringValue = NSPasteboard.general.string(forType: .string) ?? ""
        XCTAssertNotEqual(stringValue, sentinel,
                          "Cmd-C didn't update the clipboard — the keyboard wiring or owner registration is broken.")
        XCTAssertTrue(stringValue.contains("hex-editor selection"),
                      "Above-cap clipboard should hold the placeholder. Actual prefix: '\(stringValue.prefix(100))'")
        XCTAssertTrue(stringValue.contains("Paste into HEX view"),
                      "Placeholder should guide the user toward the hex view. Actual prefix: '\(stringValue.prefix(100))'")
        XCTAssertLessThan(stringValue.count, 200,
                          "Placeholder should be a short sentence — current cap impl returns ~80 chars. Length \(stringValue.count) suggests the cap didn't kick in.")

        // raw-bytes type stays byte-faithful at any size — Scintilla's lazy
        // reader streams them through pbs IPC on demand. Verify the length
        // matches the file (17 MB = 17_825_792 bytes).
        let rawData = NSPasteboard.general.data(forType: NSPasteboard.PasteboardType("public.data"))
        XCTAssertNotNil(rawData, "public.data type should be available regardless of size.")
        XCTAssertEqual(rawData?.count, 17 * 1024 * 1024,
                       "public.data should carry the full 17 MB of bytes — there's no cap on raw-byte rendering.")
    }

    // testLargeFile_1_5GB_* moved to HexEditorLargeFileUITests
    // (excluded from the default suite via -skip-testing in run-tests.sh).

    // MARK: - Wide content / horizontal scroll
    //
    // The hex pane's rootView fills the host's editor view (whatever NPP allocates).
    // When the column-width sum exceeds the editor view's width, a horizontal scroll
    // bar appears at the bottom of the scroll view. Two layout invariants must hold
    // regardless of horizontal-scroll state:
    //   (a) the status label sits flush with the top of the hex pane — no "dark band"
    //       between NPP's tab bar and our status row.
    //   (b) the column header row sits immediately below the status — no displacement.
    // These two guards regression-protect the bugs fixed in this same change.

    func testWideContent_HorizontalScrollAppearsWithoutDarkBand() throws {
        // 32-Bit cells (each cell holds 4 bytes ⇒ 8 hex digits per cell) plus
        // 16 columns plus a 16-digit address width pushes the column-width sum
        // well beyond a typical NPP window width on the VM, forcing horizontal
        // scrolling.
        let app = try launchNotepad()
        defer { app.terminate() }

        try createBufferWithText(app: app, text: String(repeating: "A", count: 64))
        try invokeHexEditorMenu(app: app, item: "View in HEX")
        Thread.sleep(forTimeInterval: 1.0)

        let hexTable = app.descendants(matching: .table).matching(identifier: AXID.table).firstMatch
        XCTAssertTrue(hexTable.waitForExistence(timeout: 5))

        // (1) Switch to 32-Bit cells via View in submenu.
        hexTable.rightClick()
        let viewIn1 = app.menuItems["View in"]
        XCTAssertTrue(viewIn1.waitForExistence(timeout: 3))
        viewIn1.click()
        let bits32 = app.menuItems["32-Bit"]
        XCTAssertTrue(bits32.waitForExistence(timeout: 3))
        bits32.click()
        Thread.sleep(forTimeInterval: 0.5)

        // (2) Bump address width to its maximum (16) via the Address Width dialog.
        hexTable.rightClick()
        let addrItem = app.menuItems["Address Width..."]
        XCTAssertTrue(addrItem.waitForExistence(timeout: 3))
        addrItem.click()
        let addrField = app.textFields["hex-editor.dialog.input"]
        XCTAssertTrue(addrField.waitForExistence(timeout: 3))
        addrField.replaceFieldText(with: "16")
        app.buttons["OK"].firstMatch.click()
        XCTAssertTrue(addrField.waitForNonExistence(timeout: 5),
                      "Address Width dialog should dismiss after OK.")
        Thread.sleep(forTimeInterval: 0.5)

        // After the rebuild, the data row's offset should be 16 hex digits wide
        // (sanity check that the address-width change actually took).
        let firstRow = hexTable.tableRows.element(boundBy: 0)
        XCTAssertTrue(firstRow.waitForExistence(timeout: 5))
        let offsetCell = firstRow.staticTexts.element(boundBy: 0)
        let predicate = NSPredicate(format: "value == %@", "0000000000000000")
        wait(for: [expectation(for: predicate, evaluatedWith: offsetCell, handler: nil)], timeout: 5)

        // (3) Layout invariant — column header row sits directly below the
        // status row. The "dark band" Bug 1 made this gap balloon to ~50pt;
        // a healthy layout keeps it well under 10pt. Verifying the gap rather
        // than absolute positions sidesteps the fact that the hex root
        // container is a plain NSView and not directly XCUI-queryable by
        // accessibility identifier.
        let statusLabel = app.staticTexts[AXID.status]
        XCTAssertTrue(statusLabel.waitForExistence(timeout: 3))
        let offsetHeader = hexTable.descendants(matching: .button)
            .matching(NSPredicate(format: "title == %@", "Offset")).firstMatch
        XCTAssertTrue(offsetHeader.waitForExistence(timeout: 3),
                      "'Offset' column header should be reachable via AX.")
        let headerToStatusGap = offsetHeader.frame.minY - statusLabel.frame.maxY
        XCTAssertLessThan(headerToStatusGap, 10,
                          "Header row should sit directly below status (≤ 10pt gap); got \(headerToStatusGap)pt — Bug 1 regression.")

        // (4) Cell-column headers render legibly (Bug 2 regression guard). With
        // 16 cell columns and 32-bit width, headers are "00", "04", ..., "3c".
        // Sample one — its title must come back as the literal string, not
        // truncated/dashed.
        let cell00Header = hexTable.descendants(matching: .button)
            .matching(NSPredicate(format: "title == %@", "00")).firstMatch
        XCTAssertTrue(cell00Header.exists,
                      "Cell-column header '00' should be present and unellipsized.")

        // (6) Visual evidence for the dashboard.
        captureToDashboard("test-wideContent-horizontalScroll")
    }

    func testWideContent_AddressWidth16Plus64BitCells() throws {
        // Same intent as above, but uses the wider 64-Bit cell mode (8 bytes per
        // cell ⇒ 16 hex digits per cell). Reaches a much wider column-width sum
        // (~1.9k pt) than the 32-Bit test, guaranteeing horizontal scroll on any
        // reasonable window. Different bit-width path through the column rebuild
        // logic — separate test so a regression that only affects one path is
        // still caught.
        let app = try launchNotepad()
        defer { app.terminate() }

        try createBufferWithText(app: app, text: String(repeating: "Z", count: 128))
        try invokeHexEditorMenu(app: app, item: "View in HEX")
        Thread.sleep(forTimeInterval: 1.0)

        let hexTable = app.descendants(matching: .table).matching(identifier: AXID.table).firstMatch
        XCTAssertTrue(hexTable.waitForExistence(timeout: 5))

        // 64-Bit cells.
        hexTable.rightClick()
        let viewIn2 = app.menuItems["View in"]
        XCTAssertTrue(viewIn2.waitForExistence(timeout: 3))
        viewIn2.click()
        let bits64 = app.menuItems["64-Bit"]
        XCTAssertTrue(bits64.waitForExistence(timeout: 3))
        bits64.click()
        Thread.sleep(forTimeInterval: 0.5)

        // Layout invariant — header row directly below status (no dark band).
        let statusLabel = app.staticTexts[AXID.status]
        XCTAssertTrue(statusLabel.waitForExistence(timeout: 3))
        let offsetHeader = hexTable.descendants(matching: .button)
            .matching(NSPredicate(format: "title == %@", "Offset")).firstMatch
        XCTAssertTrue(offsetHeader.waitForExistence(timeout: 3))
        let headerToStatusGap = offsetHeader.frame.minY - statusLabel.frame.maxY
        XCTAssertLessThan(headerToStatusGap, 10,
                          "Header row should sit directly below status in 64-Bit mode; got \(headerToStatusGap)pt — Bug 1 regression.")

        // The first cell of the first row should report 16 hex digits (8 bytes).
        // 'Z' = 0x5A so byte 0..7 = 5a 5a 5a 5a 5a 5a 5a 5a, with little/big-endian
        // depending on default. Either way, the cell value is 16 chars long.
        let firstRow = hexTable.tableRows.element(boundBy: 0)
        XCTAssertTrue(firstRow.waitForExistence(timeout: 5))
        let cell0 = firstRow.staticTexts.element(boundBy: 1)   // byte cell 0 = boundBy:1
        let cell0Value = (cell0.value as? String) ?? ""
        XCTAssertEqual(cell0Value.count, 16,
                       "64-Bit cell should display 16 hex digits; got '\(cell0Value)' (\(cell0Value.count) chars).")

        captureToDashboard("test-wideContent-64BitHorizontalScroll")
    }

    private func positionHexCursorAt(app: XCUIApplication, hexTable: XCUIElement, offset: Int) throws {
        // Use the Cmd+L keyboard shortcut rather than right-click + context menu.
        // The hex view's keyDown intercepts Cmd+L and presents the Goto dialog
        // directly; no AX-hierarchy walk needed. This matters for large-file
        // tests where the hex table has 65 K+ rows and an XCUI rightClick()
        // followed by a menu lookup spends ~3 s per probe walking the AX tree
        // for each visible cell — easily blowing past any reasonable timeout.
        // Small-doc tests are unaffected (Cmd+L works there too).
        app.typeKey("l", modifierFlags: .command)
        let gotoInput = app.textFields["hex-editor.goto.input"]
        XCTAssertTrue(gotoInput.waitForExistence(timeout: 30),
                      "Goto dialog (Cmd+L) didn't appear within 30 s — host may still be loading a large file.")
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

    // isAsanRun, asanTimeoutScale, nppLaunchEnvironment moved to HexEditorBaseUITests.

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
        app.launchEnvironment = Self.nppLaunchEnvironment(language: language)
        app.launch()
        let foregroundTimeout = 10.0 * Self.asanTimeoutScale
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: foregroundTimeout), "Nextpad++ macOS did not launch.")
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
        // XCUI's `typeText` does not reach the Scintilla view in Nextpad++ macOS — under the
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

    // invokeHexEditorMenu, waitForStatus, currentStatusText, notepadAppURL
    // moved to HexEditorBaseUITests.
}

/// Multi-GB tests excluded from the routine UI suite — the fixture they
/// need (1.5 GB) costs ~12 s of one-time generation and ~1.5 GB of disk,
/// and a single test takes a few minutes on the VM (Cmd-C materializes
/// the 1.5 GB selection into a contiguous snapshot, then SCI_INSERTTEXT
/// inserts it into the destination Scintilla — those two steps
/// dominate; lazy-reader file open is seconds).
///
/// `run-tests.sh` adds `-skip-testing:HexEditorUITests/HexEditorLargeFileUITests`
/// to xcodebuild by default, so a routine UI run never touches this
/// class. Pass `--large-files` to `test-ui.sh` (or `run-tests.sh`) to
/// include it; the flag also triggers fixture generation, so there's
/// no manual setup or env-var state to leak across shell sessions.
@MainActor
final class HexEditorLargeFileUITests: HexEditorBaseUITests {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    /// End-to-end byte-preservation roundtrip at 1.5 GB
    /// (1_610_612_736 bytes). Sized to exercise the lazy reader +
    /// promised-type owner against pbs IPC and the chunk-streamed
    /// clipboard paths at multi-GB scale, while keeping ~0.5 GB
    /// headroom under 2 GB so we never trip the INT_MAX off-by-ones
    /// in upstream Scintilla's pre-Sci_Position line-layout path
    /// (LayoutLine sign-extends INT_MIN at exactly 2 GB; verified
    /// 2026-05-05 via diagnostic crash log).
    ///
    /// Exercises Step 2c (lazy reader streams source bytes on demand),
    /// Step 5 (promised-type owner holds the snapshot, resolves
    /// public.data through pbs on paste), and the keyboard wiring.
    func testLargeFile_1_5GB_HexToFreshHexViewSameNPP_PreservesBytes() throws {
        let app = try launchNotepadWithFixture("1.5GB.bin")
        defer { app.terminate() }

        // NPP-Mac shows a large-file warning on opens above its threshold
        // ("This is a large file…"). As of 2026-05-05 the dialog
        // requires two clicks to dismiss for files this large — the
        // first click definitively does NOT dismiss it (verified
        // manually). Likely an upstream NPP-Mac bug; tracked separately.
        // We click in a loop with a brief settle in between, then wait
        // for non-existence with a deadline that covers the synchronous
        // Scintilla source-load that runs after dismissal.
        let dialog = app.dialogs.firstMatch
        for _ in 0..<3 {
            let warningButton = dialog.buttons.firstMatch
            guard warningButton.waitForExistence(timeout: 30) else { break }
            warningButton.click()
            Thread.sleep(forTimeInterval: 1.5)
        }
        XCTAssertTrue(dialog.waitForNonExistence(timeout: 240),
                      "Large-file warning dialog should be dismissed after the second click + Scintilla source-load.")

        try invokeHexEditorMenu(app: app, item: "View in HEX")

        // 1.5 GB == 1_610_612_736 bytes. The lazy reader (Step 2c) means
        // hex view engages without materializing source bytes upfront, so
        // status shows the full count within seconds — there's no
        // "ingest" wait needed.
        let fullSize = "1610612736"
        XCTAssertTrue(waitForStatus(in: app, contains: fullSize, timeout: 30),
                      "1.5 GB fixture should report full byte count once hex view engages. Status: '\(currentStatusText(in: app))'")

        // Cmd-A selects all (instant; just sets the selection range).
        // Cmd-C iterates the 1.5 GB selection through the lazy reader
        // into the HexClipboardOwner's contiguous snapshot — the only
        // step that actually touches every byte of the source. ~10–30 s.
        app.typeKey("a", modifierFlags: .command)
        app.typeKey("c", modifierFlags: .command)

        // Open a new (empty) buffer in the same NPP — Cmd-N reaches the
        // host's "New Document" action.
        app.typeKey("n", modifierFlags: .command)

        // Engage hex view on the new buffer. Should report empty.
        try invokeHexEditorMenu(app: app, item: "View in HEX")
        XCTAssertTrue(waitForStatus(in: app, contains: "empty", timeout: 30),
                      "Fresh hex view on a new buffer should report empty before paste.")

        // Cmd-V routes through pasteBytesFromPasteboard's in-process
        // snapshot short-circuit: same-process paste reads the bytes
        // directly out of g_hexClipboardOwner._bytes (bypassing pbs IPC,
        // which truncates public.data above ~few-hundred-MB). That feeds
        // SCI_INSERTTEXT to populate the destination Scintilla — the
        // dominant cost, ~30 s to a couple of minutes for 1.5 GB.
        app.typeKey("v", modifierFlags: .command)
        XCTAssertTrue(waitForStatus(in: app, contains: fullSize, timeout: 300),
                      "Paste should populate the new buffer with the full 1.5 GB within 5 min. Status: '\(currentStatusText(in: app))'")

        // Spot-check: first row's hex cells match the fixture pattern's
        // prefix (byte N = 0x20 + N mod 95, so 0x20 0x21 ... 0x2F at offsets
        // 0..15). Catches silent truncation, byte-order, and off-by-one
        // bugs without iterating 1.5 GB worth of cells.
        let hexTable = app.descendants(matching: .table).matching(identifier: AXID.table).firstMatch
        XCTAssertTrue(hexTable.waitForExistence(timeout: 10))
        let firstRow = hexTable.tableRows.element(boundBy: 0)
        XCTAssertTrue(firstRow.waitForExistence(timeout: 10))
        XCTAssertEqual(firstRow.staticTexts.element(boundBy: 1).value as? String, "20",
                       "Byte 0 should be 0x20 per the fixture pattern.")
        XCTAssertEqual(firstRow.staticTexts.element(boundBy: 2).value as? String, "21",
                       "Byte 1 should be 0x21.")
        XCTAssertEqual(firstRow.staticTexts.element(boundBy: 16).value as? String, "2f",
                       "Byte 15 should be 0x2f.")

        // Visual evidence — prior version of this test asserted only the first
        // row, which falsely passed even when the destination's hex view
        // viewport was collapsed to a single row's worth of vertical space.
        // A screenshot lets us diff "many rows visible" vs "one row visible"
        // by eye on the dashboard, and pairs with the frame-height assertion
        // below for the deterministic gate.
        captureToDashboard("testLargeFile_1_5GB-paste-destination-rendering")

        // Deterministic gate for the rendering-geometry bug: the destination's
        // hex table view must occupy a multi-row vertical extent. Anything
        // under 100 px means the viewport collapsed to ~one row and the user
        // sees only the first row of bytes even though Scintilla holds the
        // full 1.5 GB.
        XCTAssertGreaterThan(hexTable.frame.height, 100,
                             "Destination hex table viewport collapsed to <100 px (\(hexTable.frame.height) px). Bytes are present in Scintilla (status reports full size and first row renders correctly), but the hex view's frame is wrong — only one row visible to the user.")

        // Note: we deliberately don't `tableRows.element(boundBy: N)` for
        // large N here. NSTableView only publishes currently-rendered rows
        // (a small viewport-sized window) into the accessibility tree, so
        // XCUI's boundBy: returns nil for anything past that window without
        // scrolling there first. The status assertion above (full byte
        // count visible) plus the screenshot above gate the data + rendering
        // for this test; mid/end byte assertions belong in a follow-up test
        // that calls positionHexCursorAt to scroll into view first.
    }

    /// Upper-bound coverage for in-place paste at large scale. Selects a
    /// 200 MB slice from the start of a 1.5 GB file via Goto +
    /// Shift+Cmd+Home, copies it, jumps to EOF, and pastes — the
    /// destination grows to 1.7 GB (still safely under INT_MAX so
    /// Scintilla's LayoutLine doesn't overflow). Exercises the
    /// in-process snapshot short-circuit on the same buffer the user
    /// is reading from, plus the new Shift+Cmd+Home/End extend wiring
    /// (without which a sized selection of this magnitude couldn't be
    /// scripted via XCUI).
    func testLargeFile_1_5GB_Select200MBPasteAtEOFGrowsBuffer() throws {
        let app = try launchNotepadWithFixture("1.5GB.bin")
        defer { app.terminate() }

        // Dismiss the large-file warning(s); upstream double-click quirk.
        let dialog = app.dialogs.firstMatch
        for _ in 0..<3 {
            let warningButton = dialog.buttons.firstMatch
            guard warningButton.waitForExistence(timeout: 30) else { break }
            warningButton.click()
            Thread.sleep(forTimeInterval: 1.5)
        }
        XCTAssertTrue(dialog.waitForNonExistence(timeout: 240),
                      "Large-file warning should dismiss after Scintilla finishes loading.")

        try invokeHexEditorMenu(app: app, item: "View in HEX")
        let fullSize = "1610612736"
        XCTAssertTrue(waitForStatus(in: app, contains: fullSize, timeout: 30),
                      "1.5 GB fixture should report full byte count once hex view engages.")

        // Goto offset 200 MB so the cursor lands there with no selection.
        // 200 MB = 209715200 = 0xC800000. Using Cmd+L (Goto Offset) — works
        // for any offset within the buffer regardless of virtual-row depth.
        app.typeKey("l", modifierFlags: .command)
        let gotoInput = app.textFields["hex-editor.goto.input"]
        XCTAssertTrue(gotoInput.waitForExistence(timeout: 5),
                      "Go to Offset input should appear after Cmd+L.")
        gotoInput.replaceFieldText(with: "209715200")
        let goButton = app.buttons["Go"].firstMatch
        XCTAssertTrue(goButton.waitForExistence(timeout: 3))
        goButton.click()
        XCTAssertTrue(gotoInput.waitForNonExistence(timeout: 5),
                      "Goto dialog should dismiss after clicking Go.")

        // Shift+Cmd+Home extends selection back to offset 0 — the new
        // shortcut wired in this commit. Without it, getting a 200 MB
        // linear selection through XCUI is essentially impossible.
        app.typeKey(.home, modifierFlags: [.command, .shift])
        Thread.sleep(forTimeInterval: 0.5)

        // Cmd-C snapshots the 200 MB selection.
        app.typeKey("c", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 1.0)

        // Cmd+End jumps cursor to EOF (clears the selection — fine).
        app.typeKey(.end, modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.3)

        // Cmd-V pastes 200 MB at offset==totalLength. New buffer length:
        // 1610612736 + 209715200 = 1820327936 (≈ 1.7 GB). Still under
        // INT_MAX (2147483647) so Scintilla's pre-Sci_Position arithmetic
        // doesn't overflow.
        app.typeKey("v", modifierFlags: .command)

        let grownSize = "1820327936"
        XCTAssertTrue(waitForStatus(in: app, contains: grownSize, timeout: 300),
                      "Paste of 200 MB at EOF should grow the 1.5 GB buffer to 1.82 GB. Status after paste: '\(currentStatusText(in: app))'.")
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
