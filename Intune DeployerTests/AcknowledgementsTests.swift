import Foundation
import JTKit
import Testing
@testable import Intune_Deployer

@MainActor
@Suite("Acknowledgements")
struct AcknowledgementsTests {
    /// The licence shown in About must be the one in THIRD-PARTY-NOTICES.md, unchanged.
    @Test func licenceMatchesThirdPartyNotices() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let notices = try String(contentsOf: repository.appendingPathComponent("THIRD-PARTY-NOTICES.md"), encoding: .utf8)
        let start = try #require(notices.range(of: "```\nMIT License"))
        let end = try #require(notices.range(of: "\n```", range: start.upperBound..<notices.endIndex))
        let fromNotices = String(notices[notices.index(start.lowerBound, offsetBy: 4)..<end.lowerBound])
        let inApp = try #require(Acknowledgement.msal.licence)
        #expect(inApp == fromNotices)
        #expect(inApp.contains("Copyright (c) Microsoft Corporation"))
        #expect(notices.contains("2.16.0"))
    }

    @Test func linksPointToMSAL() {
        #expect(Acknowledgement.msal.links.map(\.url.absoluteString) == [
            "https://github.com/AzureAD/microsoft-authentication-library-for-objc",
        ])
        #expect(Acknowledgement.msal.heading == "Microsoft Authentication Library for iOS and macOS (MSAL) by Microsoft Corporation")
        #expect(Acknowledgement.msal.licenceName == "MIT License")
    }

    @Test func aboutCreditsMSAL() {
        let about = AboutConfiguration.intuneDeployer
        #expect(about.acknowledgements == [.msal])
        #expect(about.links.map(\.url.absoluteString) == ["https://github.com/JordyThery/intune-deployer"])
    }

    @Test func aboutShowsTheCopyrightLine() {
        #expect(AboutConfiguration.intuneDeployer.copyright?.text == "© 2026 Jordy Thery. Released under the MIT License.")
    }
}
