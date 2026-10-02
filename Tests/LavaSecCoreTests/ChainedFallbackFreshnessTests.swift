import XCTest

@testable import LavaSecKit

/// Whether the live session's fallback evidence still describes what settings shows.
///
/// These were unreachable while the predicate lived in `VPNChainingSettingsView` — the app target
/// is outside the package suite — and every defect it has had was found by review rather than by a
/// test. That is the reason the decision moved (PR #575).
final class ChainedFallbackFreshnessTests: XCTestCase {
    // A TRANSPORT-AWARE IDENTITY, not an address list. The list came from `plainDNSVariant`, so
    // Cloudflare-plain and Cloudflare-DoH produced an identical array and this answered true while
    // the session ran the other one (the plan's S4 obligation).
    private static let cloudflarePlain = "cloudflare-1111|plain-dns|1.1.1.1,1.0.0.1"
    private static let cloudflareDoH =
        "cloudflare-1111-doh|dns-over-https|1.1.1.1,1.0.0.1,doh:https://cloudflare-dns.com/dns-query"

    private func isCurrent(
        latched: String = cloudflarePlain,
        selected: String = cloudflarePlain,
        latchedFingerprint: String = "aaaa1111",
        stored: ChainedFallbackFreshness.StoredConfiguration = .present(fingerprint: "aaaa1111")
    ) -> Bool {
        ChainedFallbackFreshness.isLatchedSelectionCurrent(
            latchedIdentity: latched, selectedIdentity: selected,
            latchedConfigurationFingerprint: latchedFingerprint, storedConfiguration: stored)
    }

    func testARemovedConfigurationIsAChangeAndNotAnUnknown() {
        // `removeStoredConfiguration()` clears the store WITHOUT stopping a live session, so the
        // tunnel keeps running the configuration it latched while settings shows none. Treating
        // that as agreement left the panel reporting the old session's counters as current —
        // "Working", for an upstream the user had just deleted (Codex, PR #575).
        XCTAssertFalse(
            isCurrent(stored: .absent),
            "a session running a configuration that no longer exists is not current")
    }

    func testAnUnreadableStoreClaimsNothing() {
        // The OPPOSITE nil, and the reason one flag cannot serve both: a locked Keychain is
        // ignorance, not evidence. Reporting staleness here would send the user to restart
        // protection for a change that may not have happened.
        XCTAssertTrue(
            isCurrent(stored: .unreadable),
            "absence of evidence is not evidence of a change")
    }

    func testTheConfigurationHalfDecidesEvenWhenTheAddressesAgree() {
        // The finding that introduced the fingerprint: swapping a full-tunnel configuration for a
        // split one reverses the admission verdict while the chosen resolver sits untouched.
        XCTAssertFalse(
            isCurrent(stored: .present(fingerprint: "bbbb2222")),
            "a replaced configuration is a pending change even with the same resolver")
        XCTAssertTrue(isCurrent(stored: .present(fingerprint: "aaaa1111")))
    }

    func testTheResolverHalfDecidesEvenWhenTheConfigurationAgrees() {
        XCTAssertFalse(
            isCurrent(selected: "quad9-secure|plain-dns|9.9.9.9"),
            "a switched resolver is a pending change even under the same configuration")
        // An EMPTY selected identity, which is a selection the app could not name at all — not
        // Device DNS, which this comment used to claim. Device DNS has always produced a real
        // identity here (`device|device-dns|`), and since PR #592 it is an eligible rung besides,
        // so naming it as the no-rung case was wrong on both halves. What the case still covers
        // is the direction that matters: an unnameable selection must not read as agreement with
        // whatever the session latched.
        XCTAssertFalse(
            isCurrent(selected: ""),
            "a selection the app cannot name is a disagreement, not agreement")
    }

    /// THE COLLISION THIS TYPE'S INPUT CHANGED FOR. Two transports of one provider are two
    /// resolvers; a coerced address list said they were the same one, so the panel reported
    /// "current" for a session still running plaintext.
    func testTwoTransportsOfOneProviderAreNotTheSameSelection() {
        XCTAssertFalse(
            isCurrent(latched: Self.cloudflarePlain, selected: Self.cloudflareDoH),
            "a plain session must not report current once the user has picked the DoH variant")
        XCTAssertTrue(isCurrent(latched: Self.cloudflareDoH, selected: Self.cloudflareDoH))
    }

    /// NOTHING LATCHED IS NOT A DISAGREEMENT. Before a session publishes an identity there is no
    /// claim to contradict, and the caller's `hasEvaluated` gate is what actually covers it.
    func testNothingLatchedYetAgrees() {
        XCTAssertTrue(isCurrent(latched: "", selected: Self.cloudflareDoH))
    }

    func testNothingPublishedYetAgreesOnTheConfigurationHalf() {
        // Before a session publishes a fingerprint there is no claim to contradict. The caller's
        // `hasEvaluated` gate is what actually covers this case; this only ensures the predicate
        // does not manufacture a disagreement out of an empty string.
        XCTAssertTrue(isCurrent(latchedFingerprint: "", stored: .absent))
        XCTAssertTrue(isCurrent(latchedFingerprint: "", stored: .unreadable))
        // The resolver half still applies with nothing published.
        XCTAssertFalse(
            isCurrent(selected: "quad9-secure|plain-dns|9.9.9.9", latchedFingerprint: ""))
    }
    /// Turning the fallback OFF is a change the latch must report.
    ///
    /// This is PR #575's failure arriving through a new door. The provider serves the rung from
    /// `latchedChainedTierOneResolverConfiguration` for the session's whole life, so switching
    /// `chainedTierOneFallbackEnabled` off does not stop the lookups. With only resolver identity
    /// and configuration fingerprint compared, this read CURRENT; `ChainedFallbackStatus` then
    /// answered `.off` from the new preference, and `.off` is not surfaced — so the switch read
    /// off, the panel said nothing, and names kept leaving the tunnel until the next restart.
    ///
    /// On the one setting where a silent disagreement is a PRIVACY failure rather than a cosmetic
    /// one. Reported stale, the caller answers `.pendingDisable`: off after you restart.
    ///
    /// AND THE OTHER DIRECTION, which the first version of this fix missed. A session that
    /// started with the fallback off publishes an EMPTY latched identity, so switching the toggle on gave a
    /// genuine flag disagreement with no identity to compare — and the empty-identity
    /// short-circuit answered "current" before the flags were read. The caller fell past
    /// `.awaitingRestart` to `.noneUsable`, which tells the user to pick a different resolver
    /// about a resolver that was never the problem. The flags are now compared first
    /// (Codex P2, PR #598, on a retro review of the merged code).
    func testTurningTheFallbackOffIsAChangeTheLatchMustReport() {
        // THE LATCHED FLAG IS NOT FREE, and this helper is what the first version of this
        // test got wrong. The former settings projection derived `latchedFallbackEnabled`
        // from `!chainedFallbackLatchedIdentity.isEmpty` — a session
        // latches a rung only when the fallback was permitted at start, and publishes no
        // identity otherwise. So the two inputs are coupled: only (identity, true) and
        // ("", false) describe the runtime. The original test passed a non-empty identity with
        // `latchedEnabled: false` to model "switched on mid-session", which is a state the
        // caller cannot construct — so it asserted the right answer about the wrong world and
        // left the real off-to-on path, where the identity is EMPTY, untested and broken
        // (Codex P2, PR #598, on a retro review of the merged code).
        //
        // Coupling them here means this test can only ask questions the app can actually ask.
        func current(latchedEnabled: Bool, selectedEnabled: Bool) -> Bool {
            let identity = "doh:https://dns.example/dns-query"
            return ChainedFallbackFreshness.isLatchedSelectionCurrent(
                latchedIdentity: latchedEnabled ? identity : "",
                selectedIdentity: identity,
                latchedConfigurationFingerprint: latchedEnabled ? "fp-1" : "",
                storedConfiguration: .present(fingerprint: "fp-1"),
                latchedFallbackEnabled: latchedEnabled,
                selectedFallbackEnabled: selectedEnabled)
        }

        XCTAssertFalse(
            current(latchedEnabled: true, selectedEnabled: false),
            "the session is still asking a resolver the switch says is off")
        // THE DIRECTION THAT WAS BROKEN. The session latched no rung, so there is no identity to
        // compare — the answer has to come from the flags alone, which is why they are compared
        // ahead of the empty-identity short-circuit. Answering "current" here sent
        // `ChainedFallbackStatus` past `.awaitingRestart` to `.noneUsable`: "pick a different
        // resolver", about a resolver that was never the problem.
        XCTAssertFalse(
            current(latchedEnabled: false, selectedEnabled: true),
            "switched on mid-session: this session latched no rung and cannot grow one")
        XCTAssertTrue(current(latchedEnabled: true, selectedEnabled: true))
        XCTAssertTrue(current(latchedEnabled: false, selectedEnabled: false))

        // NOTHING LATCHED YET is still not a disagreement once the flags AGREE — a session that
        // has published no identity has made no claim about WHICH resolver it runs. Without this
        // the panel would report a pending change before any session had run. It is now reached
        // only after the flag comparison, which is the whole point: an empty identity no longer
        // buys agreement it has not earned.
        XCTAssertTrue(
            ChainedFallbackFreshness.isLatchedSelectionCurrent(
                latchedIdentity: "",
                selectedIdentity: "doh:https://dns.example/dns-query",
                latchedConfigurationFingerprint: "",
                storedConfiguration: .present(fingerprint: "fp-1"),
                latchedFallbackEnabled: false,
                selectedFallbackEnabled: false),
            "no latched identity, and the switch agrees there should not be one")

        // THE DEFAULTED CALLER still means what it meant. Every call site that predates the flags
        // omits them and gets `(true, true)`, which agrees and falls straight through to the
        // identity comparison exactly as before.
        XCTAssertTrue(
            ChainedFallbackFreshness.isLatchedSelectionCurrent(
                latchedIdentity: "",
                selectedIdentity: "doh:https://dns.example/dns-query",
                latchedConfigurationFingerprint: "",
                storedConfiguration: .present(fingerprint: "fp-1")),
            "an omitted flag pair is agreement, so pre-existing callers are unaffected")
    }
}
