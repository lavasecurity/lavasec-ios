import LavaSecCore
import XCTest

final class LavaSecCoreFacadeCompileTests: XCTestCase {
    func testFacadeReexportsEveryRealLayer() {
        let layerTypes: [Any.Type] = [
            AppConfiguration.self,
            PinnedPublicHTTPSFetcher.self,
            DNSMessage.self,
            BlocklistParser.self,
            GuardianMascotAnimationPlan.self,
            EncryptedBackupState.self,
        ]

        XCTAssertEqual(layerTypes.count, 6)
    }
}
