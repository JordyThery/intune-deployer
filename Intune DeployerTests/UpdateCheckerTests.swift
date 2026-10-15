import Testing
@testable import Intune_Deployer

@Suite("Update checker")
struct UpdateCheckerTests {
    @Test func comparesVersionsNumerically() {
        #expect(UpdateChecker.isNewer("1.1", than: "1.0"))
        #expect(UpdateChecker.isNewer("1.10", than: "1.9"))
        #expect(UpdateChecker.isNewer("2.0", than: "1.99.9"))
        #expect(UpdateChecker.isNewer("1.0.1", than: "1.0"))
        #expect(!UpdateChecker.isNewer("1.0", than: "1.0.0"))
        #expect(!UpdateChecker.isNewer("1.0", than: "1.0"))
        #expect(!UpdateChecker.isNewer("0.9", than: "1.0"))
    }
}
