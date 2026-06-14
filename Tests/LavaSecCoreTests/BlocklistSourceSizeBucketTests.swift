import XCTest
@testable import LavaSecCore

final class BlocklistSourceSizeBucketTests: XCTestCase {
    func testBucketsUseRequestedDomainCountThresholds() {
        XCTAssertEqual(BlocklistSourceSizeBucket.bucket(forEntryCount: 0), .small)
        XCTAssertEqual(BlocklistSourceSizeBucket.bucket(forEntryCount: 9_999), .small)
        XCTAssertEqual(BlocklistSourceSizeBucket.bucket(forEntryCount: 10_000), .medium)
        XCTAssertEqual(BlocklistSourceSizeBucket.bucket(forEntryCount: 100_000), .medium)
        XCTAssertEqual(BlocklistSourceSizeBucket.bucket(forEntryCount: 100_001), .large)
    }
}
