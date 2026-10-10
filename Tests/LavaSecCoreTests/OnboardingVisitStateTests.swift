import XCTest
import LavaSecAppServices

final class OnboardingVisitStateTests: XCTestCase {
    func testVisitCannotSkipVPNAndKeepsChoicesAcrossBackAndReentry() {
        var visit = OnboardingVisitState(encryptedFallback: true)
        XCTAssertFalse(visit.move(to: .done, vpnInstalled: true, busy: false))
        XCTAssertFalse(visit.move(to: .vpn, vpnInstalled: false, busy: false))
        XCTAssertFalse(visit.move(to: .done, vpnInstalled: false, busy: false))
        XCTAssertTrue(visit.move(to: .features, vpnInstalled: false, busy: false))
        XCTAssertFalse(visit.move(to: .vpn, vpnInstalled: false, busy: true))
        XCTAssertTrue(visit.move(to: .vpn, vpnInstalled: false, busy: false))
        XCTAssertFalse(visit.move(to: .connectionQuality, vpnInstalled: false, busy: false))
        XCTAssertFalse(visit.move(to: .protectionLevel, vpnInstalled: false, busy: false))
        XCTAssertEqual(visit.page, .vpn)
        XCTAssertTrue(visit.move(to: .protectionLevel, vpnInstalled: true, busy: false))
        visit.protectionLevel = .comprehensive
        XCTAssertTrue(visit.move(to: .connectionQuality, vpnInstalled: true, busy: false))
        visit.encryptedFallback = false
        XCTAssertTrue(visit.goBack(busy: false))
        XCTAssertEqual(visit.protectionLevel, .comprehensive)
        XCTAssertTrue(visit.move(to: .connectionQuality, vpnInstalled: true, busy: false, revisit: true))
        XCTAssertFalse(visit.encryptedFallback)
        XCTAssertFalse(visit.move(to: .done, vpnInstalled: true, busy: false, revisit: true))
    }
}
