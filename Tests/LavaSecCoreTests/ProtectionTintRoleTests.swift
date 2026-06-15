import XCTest
@testable import LavaSecCore

final class ProtectionTintRoleTests: XCTestCase {
    func testConnectedSeverityMapsToTintRole() {
        XCTAssertEqual(ProtectionTintRole.connected(severity: .healthy), .protected)
        XCTAssertEqual(ProtectionTintRole.connected(severity: .usingDeviceDNSFallback), .protected)
        XCTAssertEqual(ProtectionTintRole.connected(severity: .recovering), .transitioning)
        XCTAssertEqual(ProtectionTintRole.connected(severity: .dnsSlow), .attention)
        XCTAssertEqual(ProtectionTintRole.connected(severity: .needsReconnect), .attention)
        XCTAssertEqual(ProtectionTintRole.connected(severity: .networkUnavailable), .inactive)
    }
}
