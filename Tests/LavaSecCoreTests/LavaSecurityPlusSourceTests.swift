import XCTest

final class LavaSecurityPlusSourceTests: XCTestCase {
    func testUpgradeScreenUsesRealPlusProductsAndRestoreActions() throws {
        let settingsSource = try readSource(.settingsView)
        let viewModelSource = try readSource(.appViewModel)

        XCTAssertFalse(settingsSource.contains("TODO_REPLACE_WITH_APP_STORE_PRODUCT_ID"))
        XCTAssertTrue(settingsSource.contains("LavaSecurityPlusPolicy.fallbackOfferOrder"))
        XCTAssertTrue(settingsSource.contains("viewModel.purchaseLavaSecurityPlus"))
        XCTAssertTrue(settingsSource.contains("viewModel.restoreLavaSecurityPlusPurchases"))
        XCTAssertTrue(settingsSource.contains(".navigationTitle(\"Lava Security Plus\")"))
        XCTAssertTrue(settingsSource.contains(".navigationBarTitleDisplayMode(.large)"))
        XCTAssertTrue(settingsSource.contains("Text(\"More room for your rules\")"))
        // Retinted to lavaOrangeText for WCAG contrast (visual a11y Task 3) — still the orange role.
        XCTAssertTrue(settingsSource.contains("Text(\"More room for your rules\")\n                    .foregroundStyle(LavaStyle.lavaOrangeText)"))
        XCTAssertFalse(settingsSource.contains("title: \"More room for your rules\""))
        XCTAssertFalse(settingsSource.contains("UpgradeLargeTitle()"))
        XCTAssertFalse(settingsSource.contains("Text(\"Lava Security Plus\")\n                        .foregroundStyle(LavaStyle.lavaOrange)\n                    Text(\" unlocks\")"))
        XCTAssertTrue(viewModelSource.contains("func purchaseLavaSecurityPlus"))
        XCTAssertTrue(viewModelSource.contains("func restoreLavaSecurityPlusPurchases"))
        XCTAssertTrue(viewModelSource.contains("configuration.hasLavaSecurityPlus ? \"Lava Security Plus\" : \"Free plan\""))
    }

    func testUpgradeScreenMasksPurchaseControlsWhenPlusIsActive() throws {
        let settingsSource = try readSource(.settingsView)
        let viewModelSource = try readSource(.appViewModel)
        let upgradeViewBlock = try sourceBlock(
            in: settingsSource,
            startingAt: "private struct UpgradeSettingsView: View",
            endingBefore: "struct LavaPlusUpgradeDestination"
        )

        XCTAssertTrue(upgradeViewBlock.contains("if viewModel.configuration.hasLavaSecurityPlus"))
        XCTAssertTrue(upgradeViewBlock.contains("UpgradeThankYouView()"))
        XCTAssertTrue(upgradeViewBlock.contains("} else if !viewModel.hasCheckedLavaSecurityPlusEntitlements"))
        XCTAssertTrue(upgradeViewBlock.contains("|| viewModel.isRefreshingLavaSecurityPlusEntitlements {"))
        XCTAssertTrue(upgradeViewBlock.contains("UpgradeEntitlementCheckingView()"))
        XCTAssertTrue(upgradeViewBlock.contains("} else {\n                purchaseOptions"))
        // Entitlements are checked once per session (guarded) to avoid the
        // per-appear flicker/churn; products load only when not already loaded.
        XCTAssertTrue(upgradeViewBlock.contains("if !viewModel.hasCheckedLavaSecurityPlusEntitlements {\n                await viewModel.refreshLavaSecurityPlusEntitlements()\n            }"))
        XCTAssertTrue(upgradeViewBlock.contains("await viewModel.loadLavaSecurityPlusProducts()"))
        XCTAssertFalse(upgradeViewBlock.contains("await viewModel.loadLavaSecurityPlusProducts()\n            await viewModel.refreshLavaSecurityPlusEntitlements()"))
        XCTAssertTrue(viewModelSource.contains("@Published private(set) var hasCheckedLavaSecurityPlusEntitlements = false"))
        XCTAssertTrue(viewModelSource.contains("@Published private(set) var isRefreshingLavaSecurityPlusEntitlements = false"))
        XCTAssertTrue(viewModelSource.contains("hasCheckedLavaSecurityPlusEntitlements = true"))
        XCTAssertTrue(viewModelSource.contains("defer {\n            isRefreshingLavaSecurityPlusEntitlements = false\n        }"))

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
        XCTAssertTrue(thankYouMascotBlock.contains("SoftShieldGuardian(size: 96, state: mascotState, shieldStyle: viewModel.lavaGuardLook)"))
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
        let settingsSource = try readSource(.settingsView)
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
        let viewModelSource = try readSource(.appViewModel)
        let settingsSource = try readSource(.settingsView)

        XCTAssertTrue(storeSource.contains("case .yearlyPaidMonthly"))
        XCTAssertTrue(storeSource.contains("Product.products(for: LavaSecurityPlusPolicy.paywallProductIDs)"))
        XCTAssertTrue(storeSource.contains("pricingTerms"))
        XCTAssertTrue(storeSource.contains("if #available(iOS 26.4, *)"))
        XCTAssertTrue(storeSource.contains("billingPlanType == .monthly"))
        XCTAssertTrue(storeSource.contains("product.subscription?.pricingTerms.contains"))
        XCTAssertTrue(storeSource.contains("options.insert(.billingPlanType(.monthly))"))
        XCTAssertTrue(storeSource.contains("commitmentDisplayPrice"))
        XCTAssertTrue(storeSource.contains("yearlyPaidMonthlyOffer(from: productsByID[plan.productID])"))
        XCTAssertTrue(storeSource.contains("LavaSecurityPlusPolicy.fallbackOfferOrder"))
        XCTAssertTrue(storeSource.contains("LavaSecurityPlusPolicy.recommendedOfferOrder.compactMap"))
        XCTAssertTrue(viewModelSource.contains("LavaSecurityPlusPolicy.fallbackOfferOrder.map"))
        XCTAssertTrue(settingsSource.contains("LavaSecurityPlusPolicy.fallbackOfferOrder.map"))
        XCTAssertFalse(viewModelSource.contains("lavaSecurityPlusOffers: [LavaSecurityPlusOffer] = LavaSecurityPlusPolicy.recommendedOfferOrder.map"))
    }

    func testUpgradeScreenShowsCommitmentPitchAndFamilySharingBenefit() throws {
        let settingsSource = try readSource(.settingsView)
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

    func testStoreKitBoundaryMirrorsEntitlementsAfterLocalVerification() throws {
        let storeSource = try readSource(.lavaSecurityPlusStore)
        let viewModelSource = try readSource(.appViewModel)

        XCTAssertTrue(storeSource.contains("Transaction.currentEntitlements"))
        XCTAssertTrue(storeSource.contains("Transaction.updates"))
        XCTAssertTrue(storeSource.contains("AppStore.sync()"))
        XCTAssertTrue(storeSource.contains(".appAccountToken"))
        XCTAssertTrue(viewModelSource.contains("LavaSecurityPlusEntitlementSyncClient"))
        XCTAssertTrue(viewModelSource.contains("syncLavaSecurityPlusEntitlementIfPossible"))
        XCTAssertTrue(viewModelSource.contains("signedTransactionJWS"))
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
