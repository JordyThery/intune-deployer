import Foundation
import JTKit
import Testing
@testable import Intune_Deployer

@Suite("Guided tour")
@MainActor
struct GuidedTourTests {
    @Test func keepsTheExistingTourSeenSetting() throws {
        let (name, defaults) = TestSettings.makeDefaults("tour")
        defer { defaults.removePersistentDomain(forName: name) }

        // Someone who already saw the tour under the old code doesn't see it again.
        defaults.set(true, forKey: "hasSeenGuidedTour")
        let seen = IntuneDeployerTour.makeState(defaults: defaults)
        seen.startOnFirstLaunch()
        #expect(seen.index == nil)

        // On a real first launch it starts and records it under the same name.
        defaults.removeObject(forKey: "hasSeenGuidedTour")
        let fresh = IntuneDeployerTour.makeState(defaults: defaults)
        fresh.startOnFirstLaunch()
        #expect(fresh.index == 0)
        #expect(defaults.bool(forKey: "hasSeenGuidedTour"))
        #expect(fresh.steps.count == 9)
    }
}
