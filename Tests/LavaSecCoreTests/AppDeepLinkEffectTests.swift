import XCTest
@testable import LavaSecCore

/// Locks the core security invariant of the deeplink system: a deeplink can
/// `navigate` or `stage` (open a review one step before a change), but can never
/// `apply` a change. These tests fail the moment someone widens the effect model
/// or wires a hot-path mutation onto a route — a deliberate, visible gate.
final class AppDeepLinkEffectTests: XCTestCase {
    /// Every deeplink intent the parser can ever produce, so the effect sweep
    /// below is exhaustive. If a new case is added to `LavaAppDeepLink`, the
    /// compiler-incomplete sweep here is a reminder to classify it.
    private static let allIntents: [LavaAppDeepLink] = {
        let settings: [LavaAppDeepLink] = [.settings(nil)]
            + [
                LavaSettingsDeepLink.account,
                .upgrade,
                .dnsResolver,
                .privacyData,
                .security,
                .feedback,
                .legalNotices,
                .nerdStats,
            ].map { .settings($0) }
        let imports: [LavaAppDeepLink] = [
            LavaImportDeepLinkEntry.chooser,
            .scan,
            .enterCode,
        ].map { .importFilters($0) }
        return [.guardPanel, .filters, .activity] + settings + imports
    }()

    func testEffectModelHasNoApplyEffect() {
        // Exactly two effects exist, and neither applies a change. Adding an
        // `.apply`/`.mutate` effect must be a conscious act that trips this test.
        XCTAssertEqual(DeepLinkEffect.allCases.count, 2)
        XCTAssertEqual(Set(DeepLinkEffect.allCases), [.navigate, .stage])
    }

    func testEveryIntentIsNavigateOrStage() {
        for intent in Self.allIntents {
            XCTAssertTrue(
                intent.effect == .navigate || intent.effect == .stage,
                "\(intent) must not apply a change"
            )
        }
    }

    func testNavigationRoutesAreNavigate() {
        XCTAssertEqual(LavaAppDeepLink.guardPanel.effect, .navigate)
        XCTAssertEqual(LavaAppDeepLink.filters.effect, .navigate)
        XCTAssertEqual(LavaAppDeepLink.activity.effect, .navigate)
        XCTAssertEqual(LavaAppDeepLink.settings(nil).effect, .navigate)
        // The DNS resolver route only *navigates* to the picker; changing a
        // resolver is an explicit in-app tap behind the settings auth gate.
        XCTAssertEqual(LavaAppDeepLink.settings(.dnsResolver).effect, .navigate)
    }

    func testImportRoutesStage() {
        XCTAssertEqual(LavaAppDeepLink.importFilters(.chooser).effect, .stage)
        XCTAssertEqual(LavaAppDeepLink.importFilters(.scan).effect, .stage)
        XCTAssertEqual(LavaAppDeepLink.importFilters(.enterCode).effect, .stage)
    }
}
