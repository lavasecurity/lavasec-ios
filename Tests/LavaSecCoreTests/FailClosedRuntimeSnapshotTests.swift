import Foundation
import XCTest
@testable import LavaSecKit

/// Executable enforcement of INV-DNS-1's terminal degradation step: the snapshot the
/// tunnel installs when nothing else can serve must block EVERY domain, and must do so
/// with the honest `.protectionUnavailable` reason rather than forging a `.blocklist`
/// verdict. Before the extraction into LavaSecKit these semantics were only source-pinned
/// on the provider, so flipping `.block` to `.allow` inside the type passed the suite.
final class FailClosedRuntimeSnapshotTests: XCTestCase {
    func testBlocksEveryDomainWithProtectionUnavailableReason() {
        let snapshot = FailClosedRuntimeSnapshot(resolver: .cloudflare)

        // Benign, popular domains are the ones fail-closed windows historically
        // mislabelled — assert on exactly that shape of input, both entry points.
        for domain in ["google.com", "icloud.com", "apple.com", "ads.example.com", "a.b.c.example.co.uk"] {
            let rawDecision = snapshot.decision(for: domain)
            XCTAssertEqual(rawDecision.action, .block, "fail-closed must block \(domain)")
            XCTAssertEqual(rawDecision.reason, .protectionUnavailable, "fail-closed block of \(domain) must not be labelled a curated match")

            let normalizedDecision = snapshot.decision(forNormalizedDomain: domain)
            XCTAssertEqual(normalizedDecision.action, .block)
            XCTAssertEqual(normalizedDecision.reason, .protectionUnavailable)
        }
    }

    func testBlocksInputThatWouldNotNormalize() {
        let snapshot = FailClosedRuntimeSnapshot(resolver: .google)

        // BOTH entry points must stay fail-closed even for input DomainName would reject (empty,
        // single-label, IP literal, garbage) — degrading these to allow would open a bypass exactly
        // when no rule snapshot is resident. Pin the normalized entry point on the SAME pathological
        // inputs as the raw one so the symmetric block-regardless-of-input contract (INV-DNS-1) is
        // enforced on both: a regression that allowed non-normalizable input through
        // `decision(forNormalizedDomain:)` — while `decision(for:)` still blocked — would otherwise
        // slip past this suite, which previously exercised only the raw path here (OCR review on the
        // 1.2.4 sync).
        for rawDomain in ["", "localhost", "127.0.0.1", "not a domain", String(repeating: "a", count: 300)] {
            let rawDecision = snapshot.decision(for: rawDomain)
            XCTAssertEqual(rawDecision.action, .block, "raw entry must block \(rawDomain)")
            XCTAssertEqual(rawDecision.reason, .protectionUnavailable)

            let normalizedDecision = snapshot.decision(forNormalizedDomain: rawDomain)
            XCTAssertEqual(normalizedDecision.action, .block, "normalized entry must block \(rawDomain)")
            XCTAssertEqual(normalizedDecision.reason, .protectionUnavailable)
        }
    }

    func testReportsZeroResidentRulesAndPreservesResolver() {
        let snapshot = FailClosedRuntimeSnapshot(resolver: .quad9Secure)

        XCTAssertEqual(snapshot.blockRuleCount, 0)
        XCTAssertEqual(snapshot.allowRuleCount, 0)
        XCTAssertEqual(snapshot.guardrailRuleCount, 0)
        // Upstream selection stays pinned to the active configuration's resolver while
        // fail-closed; a preset swap here would move the user's DNS traffic silently.
        XCTAssertEqual(snapshot.resolver, .quad9Secure)
    }
}
