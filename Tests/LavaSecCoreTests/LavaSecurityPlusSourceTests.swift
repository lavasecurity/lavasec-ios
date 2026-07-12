import XCTest

final class LavaSecurityPlusSourceTests: XCTestCase {
    func testUpgradeScreenUsesRealPlusProductsAndRestoreActions() throws {
        let settingsSource = try readSource(.upgradeSettingsView)
        let viewModelSource = try readSource(.appViewModel)
        // The billing cluster lives in LavaSecurityPlusController since the Phase D2 peel;
        // the view actions route through the `plus` environment object.
        let controllerSource = try readSource(.lavaSecurityPlusController)

        XCTAssertFalse(settingsSource.contains("TODO_REPLACE_WITH_APP_STORE_PRODUCT_ID"))
        XCTAssertTrue(settingsSource.contains("LavaSecurityPlusPolicy.fallbackOfferOrder"))
        XCTAssertTrue(settingsSource.contains("plus.purchaseLavaSecurityPlus"))
        XCTAssertTrue(settingsSource.contains("plus.restoreLavaSecurityPlusPurchases"))
        XCTAssertTrue(settingsSource.contains(".navigationTitle(\"Lava Security Plus\")"))
        XCTAssertTrue(settingsSource.contains(".navigationBarTitleDisplayMode(.large)"))
        XCTAssertTrue(settingsSource.contains("Text(\"More room for your rules\")"))
        // Retinted to lavaOrangeText for WCAG contrast (visual a11y Task 3) — still the orange role.
        XCTAssertTrue(settingsSource.contains("Text(\"More room for your rules\")\n                    .foregroundStyle(LavaStyle.lavaOrangeText)"))
        XCTAssertFalse(settingsSource.contains("title: \"More room for your rules\""))
        XCTAssertFalse(settingsSource.contains("UpgradeLargeTitle()"))
        XCTAssertFalse(settingsSource.contains("Text(\"Lava Security Plus\")\n                        .foregroundStyle(LavaStyle.lavaOrange)\n                    Text(\" unlocks\")"))
        XCTAssertTrue(controllerSource.contains("func purchaseLavaSecurityPlus"))
        XCTAssertTrue(controllerSource.contains("func restoreLavaSecurityPlusPurchases"))
        XCTAssertTrue(viewModelSource.contains("configuration.hasLavaSecurityPlus ? \"Lava Security Plus\" : \"Free plan\""))
    }

    func testUpgradeScreenMasksPurchaseControlsWhenPlusIsActive() throws {
        let settingsSource = try readSource(.upgradeSettingsView)
        // The entitlement-check state lives on LavaSecurityPlusController (Phase D2 peel);
        // the paid display gate stays on the hub's persisted configuration.
        let controllerSource = try readSource(.lavaSecurityPlusController)
        let upgradeViewBlock = try sourceBlock(
            in: settingsSource,
            startingAt: "struct UpgradeSettingsView: View",
            endingBefore: "struct LavaPlusUpgradeDestination"
        )

        XCTAssertTrue(upgradeViewBlock.contains("if viewModel.configuration.hasLavaSecurityPlus"))
        XCTAssertTrue(upgradeViewBlock.contains("UpgradeThankYouView()"))
        XCTAssertTrue(upgradeViewBlock.contains("} else if !plus.hasCheckedLavaSecurityPlusEntitlements"))
        XCTAssertTrue(upgradeViewBlock.contains("|| plus.isRefreshingLavaSecurityPlusEntitlements {"))
        XCTAssertTrue(upgradeViewBlock.contains("UpgradeEntitlementCheckingView()"))
        XCTAssertTrue(upgradeViewBlock.contains("} else {\n                purchaseOptions"))
        // Entitlements are checked once per session (guarded) to avoid the
        // per-appear flicker/churn; products load only when not already loaded.
        XCTAssertTrue(upgradeViewBlock.contains("if !plus.hasCheckedLavaSecurityPlusEntitlements {\n                await plus.refreshLavaSecurityPlusEntitlements()\n            }"))
        XCTAssertTrue(upgradeViewBlock.contains("await plus.loadLavaSecurityPlusProducts()"))
        XCTAssertFalse(upgradeViewBlock.contains("await plus.loadLavaSecurityPlusProducts()\n            await plus.refreshLavaSecurityPlusEntitlements()"))
        XCTAssertTrue(controllerSource.contains("@Published private(set) var hasCheckedLavaSecurityPlusEntitlements = false"))
        XCTAssertTrue(controllerSource.contains("@Published private(set) var isRefreshingLavaSecurityPlusEntitlements = false"))
        XCTAssertTrue(controllerSource.contains("hasCheckedLavaSecurityPlusEntitlements = true"))
        XCTAssertTrue(controllerSource.contains("defer {\n            isRefreshingLavaSecurityPlusEntitlements = false\n        }"))

        let activePlanBlock = try sourceBlock(
            in: upgradeViewBlock,
            startingAt: "if viewModel.configuration.hasLavaSecurityPlus",
            endingBefore: "} else {"
        )
        XCTAssertFalse(activePlanBlock.contains("Choose a plan"))
        XCTAssertFalse(activePlanBlock.contains("Restore Purchase"))

        let thankYouBlock = try sourceBlock(
            in: settingsSource,
            startingAt: "private struct UpgradeThankYouView: View",
            endingBefore: "struct LavaPlusUpgradeDestination"
        )
        let thankYouMascotBlock = try sourceBlock(
            in: settingsSource,
            startingAt: "private struct UpgradeThankYouMascot: View",
            endingBefore: "private struct UpgradeEntitlementCheckingView"
        )
        XCTAssertTrue(thankYouBlock.contains("UpgradeThankYouMascot()"))
        XCTAssertFalse(thankYouBlock.contains("SoftShieldGuardian(size: 96, state: .grateful"))
        XCTAssertTrue(thankYouMascotBlock.contains("@State private var mascotState: GuardianMascotState = .awake"))
        XCTAssertTrue(thankYouMascotBlock.contains("SoftShieldGuardian(size: 96, state: mascotState, shieldStyle: customization.lavaGuardLook)"))
        XCTAssertTrue(thankYouMascotBlock.contains("Task.sleep(nanoseconds: 650_000_000)"))
        XCTAssertTrue(thankYouMascotBlock.contains("mascotState = .grateful"))
        XCTAssertTrue(thankYouMascotBlock.contains("Task.sleep(nanoseconds: 900_000_000)"))
        XCTAssertTrue(thankYouMascotBlock.contains("guard !Task.isCancelled else {\n                    return\n                }\n                mascotState = .awake"))
        XCTAssertTrue(thankYouBlock.contains("Thank you for your support"))
        XCTAssertTrue(thankYouBlock.contains("Lava Security Plus is active"))

        let checkingBlock = try sourceBlock(
            in: settingsSource,
            startingAt: "private struct UpgradeEntitlementCheckingView: View",
            endingBefore: "struct LavaPlusUpgradeDestination"
        )
        XCTAssertTrue(checkingBlock.contains("ProgressView()"))
        XCTAssertTrue(checkingBlock.contains("Checking Lava Security Plus"))
        XCTAssertFalse(checkingBlock.contains("Choose a plan"))
        XCTAssertFalse(checkingBlock.contains("Restore Purchase"))
    }

    func testPlanComparisonShowsUnlockedBenefitsInGreen() throws {
        let settingsSource = try readSource(.upgradeSettingsView)
        let comparisonBlock = try sourceBlock(
            in: settingsSource,
            startingAt: "private struct UpgradePlanComparisonView: View",
            endingBefore: "private struct UpgradePlanOfferRow: View"
        )

        XCTAssertTrue(comparisonBlock.contains("\"All Lava Guards\""))
        XCTAssertTrue(comparisonBlock.contains("\"Family Sharing\""))
        XCTAssertTrue(comparisonBlock.contains("\"Custom blocklists\""))
        XCTAssertTrue(comparisonBlock.contains("\"Custom DNS\""))
        XCTAssertTrue(comparisonBlock.contains("(\"All Lava Guards\", nil, .unlocked)"))
        XCTAssertTrue(comparisonBlock.contains("(\"Family Sharing\", nil, .unlocked)"))
        XCTAssertTrue(comparisonBlock.contains("(\"Custom blocklists\", nil, .unlocked)"))
        XCTAssertTrue(comparisonBlock.contains("(\"Custom DNS\", nil, .unlocked)"))
        XCTAssertTrue(comparisonBlock.contains("if let free"))
        XCTAssertTrue(comparisonBlock.contains("Text(\"Unlocked\")"))
        XCTAssertFalse(comparisonBlock.contains("Text(\"Included\")"))
        XCTAssertTrue(comparisonBlock.contains(".foregroundStyle(LavaStyle.safeGreen)"))
        XCTAssertTrue(comparisonBlock.contains("ViewThatFits(in: .horizontal)"))
        XCTAssertTrue(comparisonBlock.contains(".fixedSize(horizontal: true, vertical: false)"))
        XCTAssertFalse(comparisonBlock.contains("(\"All Lava Guards\", \"Original\", .included)"))
        XCTAssertFalse(comparisonBlock.contains("(\"All Lava Guards\", \"Original\", .unlocked)"))
        XCTAssertLessThan(
            try XCTUnwrap(comparisonBlock.range(of: "\"All Lava Guards\"")?.lowerBound),
            try XCTUnwrap(comparisonBlock.range(of: "\"Family Sharing\"")?.lowerBound)
        )
        XCTAssertLessThan(
            try XCTUnwrap(comparisonBlock.range(of: "\"Family Sharing\"")?.lowerBound),
            try XCTUnwrap(comparisonBlock.range(of: "\"Custom blocklists\"")?.lowerBound)
        )
        XCTAssertFalse(comparisonBlock.contains("(\"Custom blocklists\", \"Off\", \"On\")"))
        XCTAssertFalse(comparisonBlock.contains("(\"Custom DNS\", \"Off\", \"On\")"))
        XCTAssertFalse(comparisonBlock.contains("(\"Custom blocklists\", \"Off\", .included)"))
        XCTAssertFalse(comparisonBlock.contains("(\"Custom DNS\", \"Off\", .included)"))
    }

    func testYearlyPaidMonthlyOfferUsesStoreKitBillingPlanPurchaseOption() throws {
        let storeSource = try readSource(.lavaSecurityPlusStore)
        // The published offers array lives on LavaSecurityPlusController (Phase D2 peel).
        let controllerSource = try readSource(.lavaSecurityPlusController)
        let settingsSource = try readSource(.upgradeSettingsView)

        XCTAssertTrue(storeSource.contains("case .yearlyPaidMonthly"))
        XCTAssertTrue(storeSource.contains("Product.products(for: LavaSecurityPlusPolicy.paywallProductIDs)"))
        XCTAssertTrue(storeSource.contains("pricingTerms"))
        XCTAssertTrue(storeSource.contains("#if compiler(>=6.3)"))
        XCTAssertTrue(storeSource.contains("if #available(iOS 26.4, *)"))
        XCTAssertTrue(storeSource.contains("billingPlanType == .monthly"))
        XCTAssertTrue(storeSource.contains("product.subscription?.pricingTerms.contains"))
        XCTAssertTrue(storeSource.contains("options.insert(.billingPlanType(.monthly))"))
        XCTAssertTrue(storeSource.contains("commitmentDisplayPrice"))
        XCTAssertTrue(storeSource.contains("yearlyPaidMonthlyOffer(from: productsByID[plan.productID])"))
        XCTAssertTrue(storeSource.contains("LavaSecurityPlusPolicy.recommendedOfferOrder.compactMap"))
        // The store must NOT fabricate fallback offers — `offers` holds live StoreKit offers or is
        // empty, and the hardcoded fallback list is supplied by `displayedOffers` in the view. The
        // store previously seeded `fallbackOfferOrder` in `init`/`loadProducts`, which kept the
        // paywall's `offers.isEmpty` load guard from ever retrying after a failed launch load.
        XCTAssertFalse(storeSource.contains("LavaSecurityPlusPolicy.fallbackOfferOrder"))
        // The controller must NOT pre-seed offers with the fallback list — doing so froze the
        // paywall's `offers.isEmpty` load guard so live StoreKit products never loaded. The fallback
        // is supplied by `displayedOffers` in the view instead (asserted below + in
        // LavaSecurityPlusOffersLoadSourceTests).
        XCTAssertFalse(controllerSource.contains("lavaSecurityPlusOffers: [LavaSecurityPlusOffer] = LavaSecurityPlusPolicy.fallbackOfferOrder.map"))
        XCTAssertTrue(settingsSource.contains("LavaSecurityPlusPolicy.fallbackOfferOrder.map"))
        XCTAssertFalse(controllerSource.contains("lavaSecurityPlusOffers: [LavaSecurityPlusOffer] = LavaSecurityPlusPolicy.recommendedOfferOrder.map"))
    }

    func testYearlySavingsPitchIsComputedFromStoreKitPricesNotHardcoded() throws {
        let storeSource = try readSource(.lavaSecurityPlusStore)
        let settingsSource = try readSource(.upgradeSettingsView)

        // The saving is derived from the customer's own storefront prices
        // (yearly vs 12× monthly), floored so it never overstates, and gated on a
        // minimum before it is shown as a number.
        XCTAssertTrue(storeSource.contains("let savingsPercent: Int?"))
        XCTAssertTrue(storeSource.contains("func yearlySavingsPercent(yearly: Product?, monthly: Product?)"))
        XCTAssertTrue(storeSource.contains("let annualizedMonthly = monthly.price * 12"))
        // Floored in Decimal space via Int(truncating:) (truncates toward zero) so it never
        // overstates — NOT through a Double round-trip, which drops a clean integer point (an exact
        // Decimal 0.37 becomes 0.36999… → 36 instead of 37). (#44 Kilo finding)
        XCTAssertTrue(storeSource.contains("Int(truncating: NSDecimalNumber("))
        XCTAssertFalse(storeSource.contains(".doubleValue * 100"),
                       "The savings floor must stay in Decimal space, not round-trip the fraction through Double.")
        XCTAssertTrue(storeSource.contains("minimumDisplayableSavingsPercent"))
        XCTAssertTrue(storeSource.contains("savingsPercent: plan.kind == .yearly ? savingsPercent : nil"))

        // The pitch quotes the computed figure via a localized placeholder, and
        // falls back to number-free copy when there is no storefront saving.
        // (The pitch strings embed literal quotes, so match the inner text rather
        // than the backslash-escaped quotes as they appear in the raw source.)
        XCTAssertTrue(settingsSource.contains("private func planPitch(for offer: LavaSecurityPlusOffer)"))
        XCTAssertTrue(settingsSource.contains("planPitch(for: offer)"))
        XCTAssertTrue(settingsSource.contains("We are saving %d%%! This has the best value."))
        XCTAssertTrue(settingsSource.contains(".lavaLocalizedFormat(savingsPercent)"))
        XCTAssertTrue(settingsSource.contains("Paying by the year beats paying by the month."))

        // Guard against the hard-coded percentage ever coming back.
        XCTAssertFalse(settingsSource.contains("We are saving 37%!"))
        XCTAssertFalse(settingsSource.contains("planPitch(for: offer.plan.kind)"))
    }

    func testUpgradeScreenShowsCommitmentPitchAndFamilySharingBenefit() throws {
        let settingsSource = try readSource(.upgradeSettingsView)
        let comparisonBlock = try sourceBlock(
            in: settingsSource,
            startingAt: "private struct UpgradePlanComparisonView: View",
            endingBefore: "private struct UpgradePlanOfferRow: View"
        )

        XCTAssertTrue(settingsSource.contains("If we commit for 12 months, each month is cheaper."))
        XCTAssertTrue(settingsSource.contains("billed monthly on a 12-month commitment"))
        XCTAssertTrue(settingsSource.contains("cancelling affects the next renewal"))
        XCTAssertTrue(settingsSource.contains("case .yearlyPaidMonthly"))
        XCTAssertTrue(settingsSource.contains("Text(offer.displayPrice)"))
        XCTAssertTrue(settingsSource.contains("Text(\"%@ total\".lavaLocalizedFormat(commitmentDisplayPrice))"))
        XCTAssertTrue(comparisonBlock.contains("\"Family Sharing\""))
        XCTAssertTrue(comparisonBlock.contains("(\"Family Sharing\", nil, .unlocked)"))
    }

    func testAutoRenewFooterDropsCommitmentSentenceWhenYearlyPaidMonthlyIsAbsent() throws {
        let settingsSource = try readSource(.upgradeSettingsView)

        // The footer is told whether the yearly-paid-monthly plan is actually offered, computed from
        // the displayed offers (that plan needs its `.monthly` billing plan configured + iOS 26.4+).
        XCTAssertTrue(settingsSource.contains("let showsYearlyPaidMonthly: Bool"))
        XCTAssertTrue(settingsSource.contains("showsYearlyPaidMonthly: displayedOffers.contains { $0.plan.kind == .yearlyPaidMonthly }"))

        // The shorter variant omits the 12-month commitment sentence — auto-renew flows straight into
        // the Payment sentence — so we never disclose a plan the customer can't see.
        XCTAssertTrue(settingsSource.contains("Monthly and yearly plans auto-renew. Payment is charged to your Apple Account at purchase"))
    }

    func testStoreKitBoundaryMirrorsEntitlementsAfterLocalVerification() throws {
        let storeSource = try readSource(.lavaSecurityPlusStore)
        // The entitlement sync client + its callers live on LavaSecurityPlusController
        // (Phase D2 peel).
        let controllerSource = try readSource(.lavaSecurityPlusController)

        XCTAssertTrue(storeSource.contains("Transaction.currentEntitlements"))
        XCTAssertTrue(storeSource.contains("Transaction.updates"))
        XCTAssertTrue(storeSource.contains("AppStore.sync()"))
        XCTAssertTrue(storeSource.contains(".appAccountToken"))
        XCTAssertTrue(controllerSource.contains("LavaSecurityPlusEntitlementSyncClient"))
        XCTAssertTrue(controllerSource.contains("syncLavaSecurityPlusEntitlementIfPossible"))
        XCTAssertTrue(controllerSource.contains("signedTransactionJWS"))
    }

    func testCurrentEntitlementsSourceTrustsStoreKitGracePeriodWindow() throws {
        // UX-3: a subscription inside the billing grace / retry window is still
        // entitled but carries a past `expirationDate`. StoreKit already includes
        // it in `Transaction.currentEntitlements`, so the store must NOT re-expire
        // it locally for that source — otherwise the user drops to Free and
        // over-cap filters freeze read-only until billing recovers.
        let storeSource = try readSource(.lavaSecurityPlusStore)
        let activeEntitlementBlock = try sourceBlock(
            in: storeSource,
            startingAt: "private func activeEntitlement(",
            endingBefore: "private func setEntitlement"
        )

        // The plan + revocation guards stay unconditional (refund/chargeback and
        // unknown products are always inactive regardless of source).
        XCTAssertTrue(activeEntitlementBlock.contains("LavaSecurityPlusPolicy.plan(for: transaction.productID) != nil"))
        XCTAssertTrue(activeEntitlementBlock.contains("guard transaction.revocationDate == nil"))

        // The raw self-expire is now gated behind the source: currentEntitlements
        // trusts StoreKit's window; the other sources keep the stricter compare.
        XCTAssertTrue(activeEntitlementBlock.contains("if !source.trustsStoreKitEntitlementWindow,"))
        XCTAssertTrue(activeEntitlementBlock.contains("expirationDate <= Date()"))
        // Guard against a regression to the unconditional self-expire.
        XCTAssertFalse(activeEntitlementBlock.contains("if let expirationDate = transaction.expirationDate, expirationDate <= Date() {"))

        // currentEntitlements is the only source that trusts StoreKit's window.
        let sourceEnumBlock = try sourceBlock(
            in: storeSource,
            startingAt: "private enum EntitlementSource {",
            endingBefore: "private func activeEntitlement("
        )
        XCTAssertTrue(sourceEnumBlock.contains("case currentEntitlements"))
        XCTAssertTrue(sourceEnumBlock.contains("case .currentEntitlements:\n                true"))
        XCTAssertTrue(sourceEnumBlock.contains("case .purchase, .transactionUpdate:\n                false"))

        // The three call sites tag their source correctly.
        XCTAssertTrue(storeSource.contains("signedTransactionJWS: result.jwsRepresentation,\n                    source: .currentEntitlements"))
        XCTAssertTrue(storeSource.contains("signedTransactionJWS: verificationResult.jwsRepresentation,\n                source: .purchase"))
        XCTAssertTrue(storeSource.contains("signedTransactionJWS: transactionResult.jwsRepresentation,\n            source: .transactionUpdate"))
    }

    func testTransactionUpdatesApplyReceivedVerifiedTransactionImmediately() throws {
        let storeSource = try readSource(.lavaSecurityPlusStore)
        let handleBlock = try sourceBlock(
            in: storeSource,
            startingAt: "private func handle(transactionResult:",
            endingBefore: "private func loadedProduct"
        )

        XCTAssertTrue(handleBlock.contains("if let entitlement = activeEntitlement("))
        XCTAssertTrue(handleBlock.contains("setEntitlement(entitlement)"))
        XCTAssertTrue(handleBlock.contains("_ = await refreshEntitlements()"))
        XCTAssertLessThan(
            try XCTUnwrap(handleBlock.range(of: "setEntitlement(entitlement)")?.lowerBound),
            try XCTUnwrap(handleBlock.range(of: "_ = await refreshEntitlements()")?.lowerBound)
        )
        XCTAssertTrue(handleBlock.contains("await transaction.finish()"))
    }
}
