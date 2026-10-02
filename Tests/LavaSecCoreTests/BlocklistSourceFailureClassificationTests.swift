import XCTest
@testable import LavaSecCore
@testable import LavaSecFilterPipeline

/// The safety property under test is ASYMMETRIC, and every case below is written from that
/// asymmetry: calling a transient failure permanent drops a list the user asked for on a
/// device that would have healed itself. Calling a permanent failure transient only wastes a
/// fetch. When in doubt the classifier must say `.transient`.
final class BlocklistSourceFailureClassificationTests: XCTestCase {

    // MARK: - Permanent: facts about the resource

    func testAMissingResourceIsPermanent() {
        XCTAssertEqual(
            BlocklistSourceFailureClassification.classify(
                BlocklistCatalogSyncError.invalidHTTPStatus(404)),
            .permanent(reason: "http-404"))
        XCTAssertEqual(
            BlocklistSourceFailureClassification.classify(
                BlocklistCatalogSyncError.invalidHTTPStatus(410)),
            .permanent(reason: "http-410"))
    }

    /// 🔴 403 is NOT permanent, and it looks like it should be.
    ///
    /// "This origin will not serve you" sounds durable, but the 403-shaped failures these
    /// hosts actually produce are mostly self-healing: WAF challenges, rate limits,
    /// geo-blocks, expired signed URLs, a CDN having a bad day. Quarantining on those drops a
    /// list the user chose because a provider throttled us for ten minutes.
    func testAForbiddenResponseIsTransient() {
        XCTAssertEqual(
            BlocklistSourceFailureClassification.classify(
                BlocklistCatalogSyncError.invalidHTTPStatus(403)),
            .transient)
    }

    /// Over the byte cap: no number of retries makes the download fit, and each one transfers
    /// 45 MB before finding out.
    ///
    /// 🔴 NOT the path the chimmy outage took, despite the shared cause. That device blew the
    /// cap MID-TRANSFER, which throws `BlocklistDownloadSizeLimitExceeded` from the streaming
    /// fetcher — a type internal to LavaSecNetworking, so it never reaches this classifier.
    /// The gap is recorded at the bottom of the classification file.
    func testAnOverCapSourceIsPermanent() {
        let classification = BlocklistSourceFailureClassification.classify(
            BlocklistCatalogSyncError.blocklistTooLarge(
                sourceID: "blocklistproject-malware", byteSize: 72_161_681))
        XCTAssertTrue(classification.isPermanent)
        XCTAssertEqual(classification.logReason, "over-byte-cap-72161681")
    }

    /// Stronger than over-size: admitting it would breach INV-TIER-1, so there is no
    /// configuration of the device on which this fetch could be allowed to succeed.
    func testASourceOverTheTierRuleCapIsPermanent() {
        XCTAssertTrue(
            BlocklistSourceFailureClassification.classify(
                BlocklistCatalogSyncError.blocklistExceedsRuleLimit(
                    sourceID: "huge", ruleLimit: 2_000_000)
            ).isPermanent)
    }

    func testUnparseableBytesArePermanent() {
        XCTAssertTrue(
            BlocklistSourceFailureClassification.classify(
                BlocklistCatalogSyncError.invalidBlocklistEncoding("binary-source")
            ).isPermanent)
    }

    // MARK: - Transient: everything about the network, and two that merely look permanent

    /// 🔴 THE ONE THAT MATTERS MOST.
    ///
    /// While the resident snapshot is fail-closed the tunnel answers every query with the
    /// block-all address, so the app's own `getaddrinfo` returns it too and an ordinary
    /// catalog fetch fails `cannotFindHost` against a perfectly healthy upstream. That is the
    /// documented bootstrap deadlock, and it happens during the exact window the repair runs
    /// in. If this were permanent, the device would quarantine EVERY source precisely when it
    /// is trying to recover — turning a recoverable outage into a permanent one.
    func testTheFailClosedSinkholeIsNeverPermanent() {
        XCTAssertEqual(
            BlocklistSourceFailureClassification.classify(URLError(.cannotFindHost)), .transient)
        XCTAssertEqual(
            BlocklistSourceFailureClassification.classify(URLError(.cannotConnectToHost)),
            .transient)
    }

    /// A provider's bad ten minutes must not drop a list across the installed base.
    func testServerErrorsAreTransient() {
        for statusCode in [500, 502, 503, 504] {
            XCTAssertEqual(
                BlocklistSourceFailureClassification.classify(
                    BlocklistCatalogSyncError.invalidHTTPStatus(statusCode)),
                .transient,
                "HTTP \(statusCode) is the most retry-worthy failure there is.")
        }
    }

    func testTimeoutsAndOfflineAreTransient() {
        XCTAssertEqual(BlocklistSourceFailureClassification.classify(URLError(.timedOut)), .transient)
        XCTAssertEqual(
            BlocklistSourceFailureClassification.classify(URLError(.notConnectedToInternet)),
            .transient)
    }

    /// Counterintuitive, and the reason it is spelled out in the classifier too: a hash
    /// curation has not accepted yet is a fact about OUR catalog lagging the upstream, not
    /// about the source being broken. It resolves when curation catches up, with no user
    /// action and nothing changing on the device — so quarantining meanwhile would under-block
    /// for a lag we introduced.
    func testACurationHashLagIsTransient() {
        XCTAssertEqual(
            BlocklistSourceFailureClassification.classify(
                BlocklistCatalogSyncError.checksumMismatch(sourceID: "oisd-big")),
            .transient)
        XCTAssertEqual(
            BlocklistSourceFailureClassification.classify(
                BlocklistCatalogSyncError.noAcceptedSourceHashes(sourceID: "oisd-big")),
            .transient)
    }

    /// The default has to be "keep the list". An error nobody has classified yet is a reason
    /// to try again, not a reason to stop enforcing something the user chose.
    func testAnUnrecognisedErrorIsTransient() {
        struct SomethingNew: Error {}
        XCTAssertEqual(BlocklistSourceFailureClassification.classify(SomethingNew()), .transient)
        XCTAssertNil(BlocklistSourceFailureClassification.classify(SomethingNew()).logReason)
    }
}
