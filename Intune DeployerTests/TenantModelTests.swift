import Foundation
import JTKit
import Testing
@testable import Intune_Deployer

@Suite("Tenant models")
struct TenantModelTests {
    @Test func tenantProfileRoundTripsThroughJSON() throws {
        let profile = TenantProfile(
            displayName: "Lab9 Pro",
            clientID: "e445f0a6-0000-0000-0000-000000000000",
            tenantID: "c0ffee00-0000-0000-0000-000000000000",
            namingPrefix: "[LAB9]",
            variables: ["EnrollmentProfileName": "Lab9 ADE"],
            selectedItemIDs: ["3f9a1c2e"],
            accountIdentifier: "uid.tid"
        )
        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(TenantProfile.self, from: data)
        #expect(decoded == profile)
        #expect(profile.hasValidClientID)
    }

    @Test func legacyProfileWithoutClientIDStillDecodes() throws {
        // Saved by builds before client ID moved into the tenant profile.
        let legacy = Data(#"""
        {"id": "11111111-2222-3333-4444-555555555555",
         "displayName": "Legacy Tenant",
         "tenantID": "contoso.com",
         "namingPrefix": "",
         "variables": {},
         "selectedItemIDs": []}
        """#.utf8)
        let profile = try JSONDecoder().decode(TenantProfile.self, from: legacy)
        #expect(profile.displayName == "Legacy Tenant")
        #expect(profile.clientID.isEmpty)
        #expect(!profile.hasValidClientID)
        #expect(profile.accountIdentifier == nil)
    }

    @Test func tenantObjectDecodesGraphPayloadAndFindsTag() throws {
        let json = Data(#"""
        {
            "@odata.type": "#microsoft.graph.macOSCompliancePolicy",
            "id": "abc-123",
            "displayName": "macOS - Compliance",
            "description": "Managed. [gw:3f9a1c2e]",
            "lastModifiedDateTime": "2026-01-15T10:30:00.1234567Z"
        }
        """#.utf8)
        let object = try Graph.Client.decode(TenantObject.self, from: json)
        #expect(object.resolvedName == "macOS - Compliance")
        #expect(object.taggedShortID == "3f9a1c2e")
        #expect(object.odataType == "#microsoft.graph.macOSCompliancePolicy")
        #expect(object.lastModifiedDateTime != nil)
    }

    @Test func settingsCatalogObjectUsesNameProperty() throws {
        let json = Data(#"{"id": "x", "name": "macOS - Updates", "description": null}"#.utf8)
        let object = try Graph.Client.decode(TenantObject.self, from: json)
        #expect(object.resolvedName == "macOS - Updates")
        #expect(object.taggedShortID == nil)
    }
}
