import Foundation
import JTKit
import JTKitMSAL
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
        let inApp = try #require(Acknowledgement.intuneDeployerMSAL.license)
        #expect(inApp == fromNotices)
        #expect(inApp.contains("Copyright (c) Microsoft Corporation"))
        #expect(notices.contains("Version: \(MicrosoftSignIn.msalVersion)"), "the notice follows the MSAL version JTKit pins")
    }

    @Test func linksPointToMSAL() {
        #expect(Acknowledgement.intuneDeployerMSAL.links.map(\.url.absoluteString) == [
            "https://github.com/AzureAD/microsoft-authentication-library-for-objc",
        ])
        #expect(Acknowledgement.intuneDeployerMSAL.heading == "Microsoft Authentication Library for iOS and macOS (MSAL) by Microsoft Corporation")
        #expect(Acknowledgement.intuneDeployerMSAL.licenseName == "MIT License")
    }

    @Test func aboutCreditsMSAL() {
        let about = AboutConfiguration.intuneDeployer
        #expect(about.acknowledgements == [.intuneDeployerMSAL])
        #expect(Acknowledgement.intuneDeployerMSAL.license == Acknowledgement.msal.license, "JTKitMSAL's notice")
        #expect(about.links.map(\.url.absoluteString) == ["https://github.com/JordyThery/intune-deployer"])
    }

    @Test func aboutShowsTheCopyrightLine() {
        #expect(AboutConfiguration.intuneDeployer.copyright?.text == "© 2026 Jordy Thery. Released under the MIT License.")
    }
}
