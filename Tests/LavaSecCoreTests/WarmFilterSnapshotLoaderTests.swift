import XCTest
@testable import LavaSecCore
@testable import LavaSecKit

final class WarmFilterSnapshotLoaderTests: XCTestCase {
    /// A PLUS configuration (isPaid → allowsCustomBlocklists) with an ENABLED custom list: its bytes are in
    /// the compiled artifact and the cold path would network-first refresh them, so warm reuse must be
    /// rejected to avoid serving stale custom rules on switch-back.
    private func plusEnabledCustomListConfiguration() throws -> AppConfiguration {
        let source = try CustomBlocklistSource(
            id: "custom-1",
            displayName: "My List",
            rawURL: "https://example.com/list.txt",
            lastAcceptedHash: "stale-hash"
        )
        var configuration = AppConfiguration()
        configuration.isPaid = true // Plus → limits.allowsCustomBlocklists == true
        configuration.customBlocklists = [source]
        configuration.enabledBlocklistIDs = [source.id]
        XCTAssertTrue(configuration.limits.allowsCustomBlocklists)
        return configuration
    }

    private func customListFilter() -> Filter {
        Filter(
            id: "custom-filter",
            name: "Custom",
            enabledBlocklistIDs: ["custom-1"],
            blockedDomains: [],
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastCompiledToken: "warm-token-that-must-not-be-reused",
            lastSyncedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    /// Codex review (lavasec-ios#29): the SHARED warm-load primitive must reject a Plus configuration with an
    /// ENABLED custom list so a switch cold-compiles (network-first) instead of pointer-flipping to a possibly
    /// stale custom artifact. Gating in `loadReusable` (not just `reusableSnapshotForSwitch`) covers BOTH the
    /// headless Focus path AND the foreground manual switch (`AppViewModel.warmReusableSnapshotForSwitch`
    /// calls `loadReusable` directly). The guard returns before any disk/cache access, so this is a pure,
    /// fast check.
    func testLoadReusableRejectsEnabledCustomListForPlusUser() async throws {
        let result = await WarmFilterSnapshotLoader.loadReusable(
            token: "warm-token-that-must-not-be-reused",
            configuration: try plusEnabledCustomListConfiguration(),
            containerURL: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true),
            cacheURL: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true),
            freshnessMaxAge: 3600
        )
        XCTAssertNil(
            result,
            "loadReusable must reject a Plus configuration with an enabled custom list (cold network-first path) so rotated upstream custom bytes are refreshed before publishing (Codex #29)."
        )
    }

    /// End-to-end via the headless entry point.
    func testReusableSnapshotForSwitchRejectsEnabledCustomListForPlusUser() async throws {
        let result = await WarmFilterSnapshotLoader.reusableSnapshotForSwitch(
            target: customListFilter(),
            configuration: try plusEnabledCustomListConfiguration(),
            containerURL: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true),
            cacheURL: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true),
            freshnessMaxAge: 3600,
            backgroundWarmIndex: BackgroundWarmIndex()
        )
        XCTAssertNil(result, "A Plus enabled-custom-list filter must take the cold path on switch-back, not warm reuse (Codex #29).")
    }

    /// Precision (Codex #29 refinements): the guard must gate on BOTH `allowsCustomBlocklists` (a lapsed Plus
    /// user's cold path is `.cacheOnly`, so forcing cold gains no freshness and would only discard a valid
    /// frozen artifact) AND `enabledBlocklistIDs` (a disabled-only custom source contributes no bytes). Pinned
    /// as source text because the ALLOW cases (lapsed / disabled-only / catalog-only) and the REJECT case both
    /// surface as nil here without an on-disk artifact fixture.
    func testWarmReuseGuardGatesOnAllowsRefreshAndEnabledCustomIDs() throws {
        let source = try readSource(.warmFilterSnapshotLoader)
        XCTAssertTrue(
            source.contains("if configuration.limits.allowsCustomBlocklists,")
                && source.contains("configuration.customBlocklists.contains(where: { configuration.enabledBlocklistIDs.contains($0.id) })"),
            "The warm-reuse custom-list rejection must gate on BOTH allowsCustomBlocklists (skip lapsed/frozen tier) AND enabledBlocklistIDs (skip disabled-only sources) (Codex #29)."
        )
    }
}
