import XCTest
import JTKitUITestSupport

/// The release check's UI smoke tests (JTKit ROADMAP step 11), in demo mode:
/// "Contoso Intune (Demo)", the same answers every run, no real tenant,
/// nothing saved. Run one at a time by `Scripts/release-check.sh`; minutes,
/// not hours.
final class DemoSmokeUITests: JTKitUITestCase {

    override var appName: String { "Intune Deployer" }

    override func launchApp() {
        launchInDemo()
    }

    override func didLaunch() {
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 20), "The main window did not open")
        // A sandbox run's tour setting is new each launch: the tour opens.
        let skip = app.buttons["Skip Tour"].firstMatch
        if skip.waitForExistence(timeout: 3) { skip.click() }
    }

    func test1Launch() {
        XCTAssertTrue(toolbarButton("Plan").waitForExistence(timeout: 20), "The main window has no Plan")
        XCTAssertTrue(anyContaining("Contoso Intune (Demo)").waitForExistence(timeout: 10), "The demo tenant isn't in use")
    }

    func test2About() {
        checkAbout()
    }

    func test3SettingsTabs() {
        checkSettingsTabs(["General", "Connections", "GitHub", "Updates"])
    }

    func test4ConnectionsEditor() {
        // Made-up values: the tenant profile lives only in this run's in-memory list.
        checkConnectionsEditor(service: "Intune") { settings in
            self.type(UUID().uuidString,
                      into: settings.textFields.matching(NSPredicate(format: "placeholderValue == 'Directory ID or domain'")).firstMatch)
            self.type(UUID().uuidString,
                      into: settings.textFields.matching(NSPredicate(format: "placeholderValue == 'Application (client) ID'")).firstMatch)
        }
    }

    /// A small baseline from the test's folder, Plan on the demo tenant: the
    /// creates and "Contoso – Legacy Wi-Fi" to delete, ticked; Apply with
    /// its confirmation; the left-over is deleted and nothing fails.
    func test5MainTask() throws {
        try addBaseline()
        let plan = openPlan()
        let legacy = app.checkBoxes.matching(NSPredicate(format: "label CONTAINS 'Legacy Wi-Fi'")).firstMatch
        scrollIntoView(legacy)
        tap(legacy, timeout: 10)
        tap(plan.buttons["Apply…"], timeout: 10)
        let confirm = dialogButton("Apply")
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "Apply asks for no confirmation")
        XCTAssertTrue(anyContaining("1 deletion").exists, "The confirmation doesn't name the deletion")
        confirm.click()
        XCTAssertTrue(anyContaining("Delete orphan Contoso – Legacy Wi-Fi").waitForExistence(timeout: 120),
                      "Apply didn't delete the left-over")
        XCTAssertFalse(anyContaining("Failed").exists, "An Apply step failed")
        tap(plan.buttons["Close"], timeout: 10)
    }

    func test6ActivityLog() throws {
        try addBaseline()
        let plan = openPlan()
        tap(plan.buttons["Close"], timeout: 10)
        // Demo mode's Intune server answers these hosts inside the app; a real
        // tenant's requests can't go out under tests (UnderTest).
        checkActivityLog(alsoAllowedHosts: ["https://graph.microsoft.com/", "https://login.microsoftonline.com/"])
    }

    func test7DemoTitles() {
        tap(app.menuBars.menuBarItems[appName])
        tap(app.menuItems["About \(appName)"])
        XCTAssertTrue(window(titled: "About \(appName)").waitForExistence(timeout: 10))
        app.typeKey("l", modifierFlags: [.command, .shift])
        XCTAssertTrue(window(titled: "Activity Log").waitForExistence(timeout: 10))
        openSettings()
        checkDemoTitles()
    }

    // MARK: Helpers

    /// Writes three baseline files into the test's folder, adds it as a
    /// source and includes every item.
    private func addBaseline() throws {
        let baseline = testFolder.appending(path: "Baseline", directoryHint: .isDirectory)
        let files = [
            "Scripts/hello.sh": "#!/bin/zsh\necho \"JTKTEST smoke\"\n",
            "Compliance/encryption.json": """
            {"@odata.type": "#microsoft.graph.macOSCompliancePolicy", "displayName": "macOS - Compliance - Encryption",
             "storageRequireEncryption": true,
             "scheduledActionsForRule": [{"ruleName": "PasswordRequired",
               "scheduledActionConfigurations": [{"actionType": "block", "gracePeriodHours": 24}]}]}
            """,
            "Filters/no-device.json": """
            {"displayName": "macOS - No Device", "platform": "macOS", "rule": "(device.deviceName -eq \\"none\\")"}
            """,
        ]
        for (path, text) in files {
            let url = baseline.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        tap(app.buttons["Add Folder…"].firstMatch, timeout: 15)
        goToFolder(baseline.path)
        tap(app.buttons["OKButton"].firstMatch, timeout: 15)
        // The new source, in the sidebar: its items appear in the list.
        let source = app.outlines["Sidebar"].staticTexts.matching(NSPredicate(format: "value == 'Baseline' OR label == 'Baseline'")).firstMatch
        tap(source, timeout: 30)
        XCTAssertTrue(anyContaining("hello").waitForExistence(timeout: 30), "The baseline's items aren't listed")
        let selection = app.toolbars.menuButtons["Selection"].firstMatch
        tap(selection.exists ? selection : app.menuButtons["Selection"].firstMatch, timeout: 10)
        tap(app.menuItems["Include All Shown"].firstMatch, timeout: 5)
    }

    /// Plan (⌘P) until its creates are listed.
    private func openPlan() -> XCUIElement {
        tap(toolbarButton("Plan"), timeout: 10)
        let plan = app.sheets.firstMatch
        XCTAssertTrue(plan.waitForExistence(timeout: 10), "The Plan didn't open")
        XCTAssertTrue(anyContaining("Create (").waitForExistence(timeout: 60), "The Plan shows no creates")
        return plan
    }

    private func toolbarButton(_ label: String) -> XCUIElement {
        app.toolbars.buttons[label].firstMatch
    }
}
