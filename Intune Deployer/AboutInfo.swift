import Foundation
import JTKit
import JTKitMSAL

/// What the About window shows (JTKit's `AboutWindow`).
extension AboutConfiguration {
    static let intuneDeployer = AboutConfiguration(
        appName: "Intune Deployer",
        copyright: AboutCopyright(year: "2026", holder: "Jordy Thery"),
        author: "Created by Jordy Thery",
        summary: "Deploys macOS and iOS/iPadOS configuration to Microsoft Intune.",
        links: [
            AboutLink("github.com/JordyThery/intune-deployer", address: "https://github.com/JordyThery/intune-deployer"),
        ].compactMap { $0 },
        acknowledgements: [.intuneDeployerMSAL]
    )
}

/// Credit for Microsoft's sign-in library: JTKitMSAL's notice for the MSAL
/// version JTKit pins, with this app's sentence on what it uses MSAL for.
extension Acknowledgement {
    static let intuneDeployerMSAL = Acknowledgement.msal(
        summary: "Intune Deployer uses MSAL to sign in to Entra ID and get access to Microsoft Graph."
    )
}
