import XCTest
import JTKitUITestSupport

/// Takes the README's screenshots (docs/browser.png, plan.png, apply.png) in
/// demo mode: "Contoso Intune (Demo)", sample files, nothing real. Not part
/// of the release check; run it by hand when the interface changes:
///
///     xcodebuild test -project "Intune Deployer.xcodeproj" \
///       -scheme "Intune Deployer Release Check" -resultBundlePath /tmp/shots.xcresult \
///       -only-testing "Intune DeployerUITests/ReadmeScreenshotsUITests"
///     xcrun xcresulttool export attachments --path /tmp/shots.xcresult --output-path /tmp/shots
///
/// The images are attached to the test result under their file names (the
/// sandboxed test runner can't write into the repository).
final class ReadmeScreenshotsUITests: JTKitUITestCase {

    override var appName: String { "Intune Deployer" }

    override func launchApp() {
        launchInDemo()
    }

    override func didLaunch() {
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 20), "The main window did not open")
        let skip = app.buttons["Skip Tour"].firstMatch
        if skip.waitForExistence(timeout: 3) { skip.click() }
    }

    func testReadmeScreenshots() throws {
        try addBaseline()
        // An item's details next to the list: its name, not its checkbox.
        let item = app.staticTexts.matching(NSPredicate(format: "value == 'Rosetta 2' OR label == 'Rosetta 2'")).firstMatch
        tap(item, timeout: 10)
        sleep(2)
        save("browser")

        // The Plan: creates and the demo tenant's left-over to delete (not ticked).
        tap(app.toolbars.buttons["Plan"].firstMatch, timeout: 10)
        let plan = app.sheets.firstMatch
        XCTAssertTrue(plan.waitForExistence(timeout: 10), "The Plan didn't open")
        XCTAssertTrue(anyContaining("Create (").waitForExistence(timeout: 60), "The Plan shows no creates")
        sleep(2)
        save("plan")

        // Apply and its results.
        tap(plan.buttons["Apply…"], timeout: 10)
        let confirm = dialogButton("Apply")
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "Apply asks for no confirmation")
        confirm.click()
        XCTAssertTrue(anyContaining("Applied").waitForExistence(timeout: 120), "Apply didn't finish")
        sleep(2)
        save("apply")
        tap(plan.buttons["Close"], timeout: 10)
    }

    // MARK: Helpers

    /// Attaches the main window (with its sheet) as `<name>.png`.
    private func save(_ name: String) {
        let attachment = XCTAttachment(data: app.windows.firstMatch.screenshot().pngRepresentation,
                                       uniformTypeIdentifier: "public.png")
        attachment.name = "\(name).png"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Writes a small sample baseline into the test's folder, adds it as a
    /// source and includes every item.
    private func addBaseline() throws {
        let baseline = testFolder.appending(path: "Contoso Baseline", directoryHint: .isDirectory)
        let files = [
            "Settings Catalog/content-caching.json": """
            {"name": "macOS - Disable Content Caching", "description": "", "platforms": "macOS", "technologies": "mdm",
             "settings": [{"@odata.type": "#microsoft.graph.deviceManagementConfigurationSetting",
               "settingInstance": {"@odata.type": "#microsoft.graph.deviceManagementConfigurationChoiceSettingInstance",
                 "settingDefinitionId": "com.apple.applicationaccess_allowcontentcaching",
                 "choiceSettingValue": {"value": "com.apple.applicationaccess_allowcontentcaching_false", "children": []}}}]}
            """,
            "Compliance/encryption.json": """
            {"@odata.type": "#microsoft.graph.macOSCompliancePolicy", "displayName": "macOS - Compliance - Encryption",
             "storageRequireEncryption": true,
             "scheduledActionsForRule": [{"ruleName": "PasswordRequired",
               "scheduledActionConfigurations": [{"actionType": "block", "gracePeriodHours": 24}]}]}
            """,
            "Filters/corporate-macs.json": """
            {"displayName": "macOS - Corporate Macs", "platform": "macOS",
             "rule": "(device.deviceOwnership -eq \\"Corporate\\")"}
            """,
            "Profiles/login-window.mobileconfig": """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict>
            <key>PayloadContent</key><array><dict>
            <key>PayloadType</key><string>com.apple.loginwindow</string>
            <key>PayloadIdentifier</key><string>com.contoso.loginwindow.payload</string>
            <key>PayloadUUID</key><string>6F3C2A10-1B5E-4C3B-9E0A-2D4F5A6B7C81</string>
            <key>PayloadVersion</key><integer>1</integer>
            <key>LoginwindowText</key><string>Property of Contoso</string>
            </dict></array>
            <key>PayloadDisplayName</key><string>macOS - Login Window</string>
            <key>PayloadIdentifier</key><string>com.contoso.loginwindow</string>
            <key>PayloadType</key><string>Configuration</string>
            <key>PayloadUUID</key><string>0A1B2C3D-4E5F-4061-8273-94A5B6C7D8E9</string>
            <key>PayloadVersion</key><integer>1</integer>
            </dict></plist>
            """,
            "Scripts/Rosetta 2.sh": "#!/bin/zsh\n# intune: runAsAccount=system retries=3\n/usr/sbin/softwareupdate --install-rosetta --agree-to-license\n",
            "CustomAttributes/FileVault Status.sh": "#!/bin/zsh\n/usr/bin/fdesetup status\n",
        ]
        for (path, text) in files {
            let url = baseline.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        tap(app.buttons["Add Folder…"].firstMatch, timeout: 15)
        goToFolder(baseline.path)
        tap(app.buttons["OKButton"].firstMatch, timeout: 15)
        let source = app.outlines["Sidebar"].staticTexts
            .matching(NSPredicate(format: "value == 'Contoso Baseline' OR label == 'Contoso Baseline'")).firstMatch
        tap(source, timeout: 30)
        XCTAssertTrue(anyContaining("Rosetta 2").waitForExistence(timeout: 30), "The baseline's items aren't listed")
        let selection = app.toolbars.menuButtons["Selection"].firstMatch
        tap(selection.exists ? selection : app.menuButtons["Selection"].firstMatch, timeout: 10)
        tap(app.menuItems["Include All Shown"].firstMatch, timeout: 5)
    }
}
