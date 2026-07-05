import XCTest

/// Guardrail for the Lava Security Plus paywall product-load path.
///
/// Regression: `AppViewModel.lavaSecurityPlusOffers` was pre-seeded with the fallback offers, so the
/// paywall's on-appear guard (`offers.isEmpty` → load) never fired. The screen then showed the
/// hardcoded fallback prices ($3.99 / $29.99) instead of the live StoreKit prices and never surfaced
/// the yearly-paid-monthly offer, even though products loaded fine on purchase. These pins keep the
/// offers array starting EMPTY (loaded lazily) while `displayedOffers` still substitutes the fallback
/// list until the load completes, so the UI is never blank.
final class LavaSecurityPlusOffersLoadSourceTests: XCTestCase {

    func testOffersStartEmptySoTheLoadGuardCanFire() throws {
        let source = try readSource(.appViewModel)
        XCTAssertTrue(source.contains("var lavaSecurityPlusOffers: [LavaSecurityPlusOffer] = []"),
                      "lavaSecurityPlusOffers must start empty — pre-seeding it defeats the paywall's isEmpty load guard and freezes the paywall on hardcoded fallback prices.")
        XCTAssertFalse(source.contains("var lavaSecurityPlusOffers: [LavaSecurityPlusOffer] = LavaSecurityPlusPolicy.fallbackOfferOrder"),
                       "lavaSecurityPlusOffers must not be pre-seeded with the fallback offers.")
    }

    func testPaywallLoadsProductsWhileOffersAreEmpty() throws {
        let compact = try readSource(.settingsView).filter { !$0.isWhitespace }
        XCTAssertTrue(compact.contains("viewModel.lavaSecurityPlusOffers.isEmpty{awaitviewModel.loadLavaSecurityPlusProducts()}"),
                      "The paywall must load live StoreKit products while the offers array is empty.")
    }

    func testDisplayedOffersFallBackWhileEmpty() throws {
        let compact = try readSource(.settingsView).filter { !$0.isWhitespace }
        XCTAssertTrue(compact.contains("if!viewModel.lavaSecurityPlusOffers.isEmpty{returnviewModel.lavaSecurityPlusOffers}"),
                      "displayedOffers must return the loaded offers when present.")
        XCTAssertTrue(compact.contains("returnLavaSecurityPlusPolicy.fallbackOfferOrder.map"),
                      "displayedOffers must fall back to the hardcoded list while offers are empty, so the paywall is never blank.")
    }

    func testLoadPopulatesOffersFromStore() throws {
        let compact = try readSource(.appViewModel).filter { !$0.isWhitespace }
        XCTAssertTrue(compact.contains("awaitlavaSecurityPlusStore.loadProducts()lavaSecurityPlusOffers=lavaSecurityPlusStore.offers"),
                      "loadLavaSecurityPlusProducts must apply the store's loaded offers to the published array.")
    }

    func testStoreOffersStartEmptyAndAreNeverFabricated() throws {
        let source = try readSource(.lavaSecurityPlusStore)
        XCTAssertTrue(source.contains("offers = []"),
                      "LavaSecurityPlusStore must initialize offers EMPTY — seeding the fallback list keeps the paywall's isEmpty load guard from ever retrying after a failed launch load.")
        XCTAssertFalse(source.contains("Self.fallbackOffers()"),
                       "The store must not fabricate fallback offers (in init or the loadProducts catch); offers holds live StoreKit offers or stays empty, and displayedOffers supplies the display fallback.")
        XCTAssertFalse(source.contains("func fallbackOffers()"),
                       "The store's fallbackOffers() helper must be removed — the hardcoded fallback list lives only in the view's displayedOffers.")
    }
}
