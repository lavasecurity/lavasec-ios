import XCTest

final class LavaSecurityPlusSourceTests: XCTestCase {
    /// A transient/cold `Transaction.currentEntitlements` empty read must not demote a paying subscriber.
    /// The store tags each reading's confidence and the controller routes the demote through
    /// `EntitlementApplicationPolicy`; only authoritative (`.confirmed`) readings — purchase, restore
    /// (post `AppStore.sync()`), and `Transaction.updates` — may strip a previously-entitled user. The
    /// executable behavior lives in `EntitlementApplicationPolicyTests`; these pins hold the app-side
    /// wiring (store + controller are outside the SPM test target).
    func testATransientEmptyEntitlementReadingCannotDemoteAPaidUser() throws {
        let controllerSource = try readSource(.lavaSecurityPlusController)
        let storeSource = try readSource(.lavaSecurityPlusStore)

        // Controller: the demote decision is delegated to the policy and the PERSIST uses its result,
        // never the raw computed flag — that is what makes an unconfirmed empty read a no-op.
        XCTAssertTrue(controllerSource.contains(
            "confidence: EntitlementReadingConfidence"))
        XCTAssertTrue(controllerSource.contains(
            "EntitlementApplicationPolicy.resolvedHasLavaSecurityPlus("))
        XCTAssertTrue(controllerSource.contains("try hub.persistPaidPlanFlag(resolvedHasLavaSecurityPlus)"))
        XCTAssertFalse(controllerSource.contains("try hub.persistPaidPlanFlag(hasLavaSecurityPlus)"))

        // Controller: the bare startup / Upgrade-screen refresh is UNCONFIRMED (no preceding sync); the
        // user-initiated purchase and restore are CONFIRMED.
        XCTAssertTrue(controllerSource.contains(
            "refreshEntitlements(confidence: .unconfirmed)"))
        XCTAssertTrue(controllerSource.contains(
            "applyLavaSecurityPlusEntitlement(entitlement, confidence: .unconfirmed)"))
        XCTAssertTrue(controllerSource.contains(
            "applyLavaSecurityPlusEntitlement(entitlement, confidence: .confirmed)"))

        // Store: restore confirms only AFTER AppStore.sync(); the transaction-update push is authoritative.
        XCTAssertTrue(storeSource.contains(
            "try await AppStore.sync()\n        // Post-`AppStore.sync()`"))
        XCTAssertTrue(storeSource.contains("refreshEntitlements(confidence: .confirmed)"))
        XCTAssertTrue(storeSource.contains("setEntitlement(entitlement, confidence: .confirmed)"))
        // The change notification carries the confidence so a closure-fired demote is classified too.
        XCTAssertTrue(storeSource.contains(
            "entitlementChanged?(nextEntitlement, confidence)"))
        // A `.confirmed` lapse that equals a value an earlier `.unconfirmed` read stored must still be
        // delivered (not swallowed by a value-only guard), so a real Transaction.updates expiry demotes.
        XCTAssertTrue(storeSource.contains("EntitlementApplicationPolicy.shouldDeliverReading("))
        XCTAssertTrue(storeSource.contains("previousConfidence: deliveredEntitlementConfidence"))
        XCTAssertTrue(storeSource.contains("deliveredEntitlementConfidence = confidence"))
    }

    func testUpgradeScreenUsesRealPlusProductsAndRestoreActions() throws {
        let presentation = try readSource(.upgradeSettingsView)
        let screen = try sourceBlock(
            in: readSource(.reactNativeSettingsScreens),
            startingAt: "export function LavaPlusPage("
        )
        let bridge = try readSource(.reactNativeAppBridge)
        let controller = try readSource(.lavaSecurityPlusController)
        let buy = try sourceBlock(in: bridge, startingAt: "case \"purchase.buy\":", endingBefore: "case \"purchase.restore\":")
        let restore = try sourceBlock(in: bridge, startingAt: "case \"purchase.restore\":", endingBefore: "case \"purchase.manage\":")
        let manage = try sourceBlock(in: bridge, startingAt: "case \"purchase.manage\":", endingBefore: "case \"purchase.refresh\":")

        XCTAssertTrue(presentation.contains("enum LavaPlusPresentation"))
        XCTAssertFalse(presentation.contains("import SwiftUI"))
        XCTAssertFalse(presentation.contains(": View"))
        XCTAssertFalse(presentation.contains("TODO_REPLACE_WITH_APP_STORE_PRODUCT_ID"))
        XCTAssertTrue(presentation.contains("LavaSecurityPlusPolicy.fallbackOfferOrder"))
        XCTAssertTrue(screen.contains("live?.plus.offers.map(offer=>"))
        XCTAssertTrue(screen.contains("<SettingsPrice price={offer.price} commitment={offer.commitmentPrice}/>"))
        XCTAssertTrue(screen.contains("run({type:\"purchase.buy\",id:offer.id})"))
        XCTAssertTrue(screen.contains("run({type:'purchase.restore'})"))
        XCTAssertTrue(screen.contains("useExclusiveAppAction('purchase',!!live?.plus.busy)"))
        XCTAssertTrue(try readSource(.reactNativeReviewNavigation).contains("['Upgrade', Screens.UpgradeScreen, 'Lava Plus']"))

        // RN sends only the offer identity. Native authorization and the current
        // StoreKit-backed offer lookup still precede each billing mutation.
        XCTAssertTrue(buy.contains("try await authorize(.appSettings, \"Upgrade to Lava Security Plus\")"))
        XCTAssertTrue(buy.contains("LavaPlusPresentation.displayedOffers(for: model.plus).first(where: { $0.id == input[\"id\"] as? String })"))
        XCTAssertTrue(buy.contains("This purchase is unavailable. Refresh the available plans."))
        XCTAssertTrue(buy.contains("await model.plus.purchaseLavaSecurityPlus(offer)"))
        XCTAssertLessThan(try XCTUnwrap(buy.range(of: "try await authorize(")?.lowerBound),
                          try XCTUnwrap(buy.range(of: "await model.plus.purchaseLavaSecurityPlus(offer)")?.lowerBound))
        XCTAssertTrue(restore.contains("try await authorize(.appSettings, \"Restore Lava Security Plus\")"))
        XCTAssertTrue(restore.contains("await model.plus.restoreLavaSecurityPlusPurchases()"))
        XCTAssertTrue(manage.contains("try await authorize(.appSettings, \"Manage Lava Security Plus\")"))
        XCTAssertTrue(manage.contains("await LavaPlusPresentation.presentManageSubscriptions(plus: model.plus)"))
        XCTAssertTrue(presentation.contains("try await AppStore.showManageSubscriptions(in: scene)"))
        XCTAssertTrue(presentation.contains("await plus.refreshLavaSecurityPlusEntitlements()"))
        XCTAssertTrue(presentation.contains("https://apps.apple.com/account/subscriptions"))
        XCTAssertTrue(presentation.contains("_ = await UIApplication.shared.open(url)"))
        XCTAssertTrue(controller.contains("func purchaseLavaSecurityPlus"))
        XCTAssertTrue(controller.contains("func restoreLavaSecurityPlusPurchases"))
        XCTAssertTrue(try readAppViewModelSource().contains("configuration.hasLavaSecurityPlus ? \"Lava Security Plus\" : \"Free plan\""))
    }

    func testUpgradeScreenMasksPurchaseControlsWhenPlusIsActive() throws {
        let screen = try sourceBlock(in: readSource(.reactNativeSettingsScreens), startingAt: "export function LavaPlusPage(")
        let bridge = try readSource(.reactNativeAppBridge)
        let controller = try readSource(.lavaSecurityPlusController)
        let active = try sourceBlock(in: screen, startingAt: "{live?.plus.enabled ?", endingBefore: ": live?.plus.checking ?")
        let checking = try sourceBlock(in: screen, startingAt: ": live?.plus.checking ?", endingBefore: ": <SettingsStack>")
        let refresh = try sourceBlock(in: bridge, startingAt: "case \"purchase.refresh\":", endingBefore: "case \"purchase.clearMessage\":")

        XCTAssertTrue(bridge.contains("\"enabled\": m.configuration.hasLavaSecurityPlus"))
        XCTAssertTrue(bridge.contains("\"checking\": !m.plus.hasCheckedLavaSecurityPlusEntitlements || m.plus.isRefreshingLavaSecurityPlusEntitlements"))
        XCTAssertTrue(active.contains("<SettingsSubscriptionStatus look={live.look} expiration={live.plus.expiration}/>"))
        XCTAssertTrue(active.contains("Manage Subscription"))
        XCTAssertFalse(active.contains("purchase.buy"))
        XCTAssertFalse(active.contains("Choose a plan"))
        XCTAssertTrue(checking.contains("<SettingsLoading title=\"Checking Lava Security Plus\"/>"))
        XCTAssertFalse(checking.contains("purchase.buy"))
        XCTAssertFalse(checking.contains("Restore Purchase"))
        XCTAssertTrue(screen.contains("app.command({type:'purchase.refresh'})"))
        XCTAssertTrue(refresh.contains("if !model.plus.hasCheckedLavaSecurityPlusEntitlements { await model.plus.refreshLavaSecurityPlusEntitlements() }"))
        XCTAssertTrue(refresh.contains("if !model.configuration.hasLavaSecurityPlus, model.plus.lavaSecurityPlusOffers.isEmpty { await model.plus.loadLavaSecurityPlusProducts() }"))
        XCTAssertTrue(controller.contains("@Published private(set) var hasCheckedLavaSecurityPlusEntitlements = false"))
        XCTAssertTrue(controller.contains("@Published private(set) var isRefreshingLavaSecurityPlusEntitlements = false"))
        XCTAssertTrue(controller.contains("hasCheckedLavaSecurityPlusEntitlements = true"))
        XCTAssertTrue(controller.contains("defer {\n            isRefreshingLavaSecurityPlusEntitlements = false\n        }"))

        // Pin the mascot actually rendered by the RN paid branch, including the
        // selected look, accessible tap, gratitude cue and retirement cleanup.
        let status = try sourceBlock(in: readSource(.reactNativeSettingsScaffold), startingAt: "export function SettingsSubscriptionStatus(", endingBefore: "export function SettingsLoading(")
        let interaction = try readSource(.reactNativeMascotInteraction)
        XCTAssertTrue(status.contains("useMascotTapInteraction()"))
        XCTAssertTrue(status.contains("useMascotDownwardScroll(interaction.active,interaction.scrollDown)"))
        XCTAssertTrue(status.contains("accessibilityLabel={localized('Thank you for your support')}"))
        XCTAssertTrue(status.contains("onAccessibilityTap={interaction.tap}"))
        XCTAssertTrue(status.contains("mood={interaction.grateful?'grateful':'awake'} look={look}"))
        XCTAssertTrue(status.contains("gesturesEnabled={interaction.active}"))
        XCTAssertTrue(status.contains("Thank you for your support"))
        XCTAssertTrue(status.contains("Lava Security Plus is active"))
        XCTAssertTrue(interaction.contains("animating.current=true;setGrateful(true)"))
        XCTAssertTrue(interaction.contains("setTimeout(()=>setGrateful(false)"))
        XCTAssertTrue(interaction.contains("if(state!=='active')cancel()"))
        XCTAssertTrue(interaction.contains("timers.current.forEach(clearTimeout)"))
    }

    func testUpgradeStoryListsAllIncludedBenefitsWithoutFreePlanRestrictions() throws {
        let story = try sourceBlock(in: readSource(.reactNativePlusScaffold), startingAt: "export function LavaPlusStory()", endingBefore: "const s=StyleSheet.create(")
        XCTAssertTrue(story.contains("<PagedCards label=\"Lava Plus benefits\""))
        XCTAssertTrue(story.contains("<DisclosureRow icon=\"gift\" title=\"Everything included\""))
        for benefit in ["['Your own blocklists','Included']", "['Custom DNS','Included']", "['VPN chaining','Included']", "['All Lava Guards','Included']", "['Family Sharing','Included']"] {
            XCTAssertTrue(story.contains(benefit))
        }
        XCTAssertTrue(story.contains("['Saved filters','Up to 50']"))
        XCTAssertTrue(story.contains("['Filter rules','Up to 2 million']"))
        XCTAssertTrue(story.contains("<ListRow key={title} title={title!} metadata={value}/>"))
        XCTAssertFalse(story.contains("'Off'"))
        XCTAssertFalse(story.contains("'Original'"))

        let scene = try sourceBlock(in: readSource(.reactNativePlusScaffold), startingAt: "function BenefitScene(", endingBefore: "function RoutineCard(")
        XCTAssertTrue(scene.contains("accessibilityElementsHidden importantForAccessibility=\"no-hide-descendants\""))
        XCTAssertTrue(scene.contains("<Copy role=\"body\" weight=\"700\">{title}</Copy>"))
        XCTAssertTrue(scene.contains("<Copy role=\"body\" color={colors.secondaryText}>{description}</Copy>"))
        XCTAssertTrue(try readSource(.reactNativeSettingsScaffold).contains("<Copy role=\"row\" color={colors.safeGreen}>{price}</Copy>"))
    }

    func testYearlyPaidMonthlyOfferUsesStoreKitBillingPlanPurchaseOption() throws {
        let storeSource = try readSource(.lavaSecurityPlusStore)
        // The published offers array lives on LavaSecurityPlusController (Phase D2 peel).
        let controllerSource = try readSource(.lavaSecurityPlusController)
        let settingsSource = try readSource(.upgradeSettingsView)

        XCTAssertTrue(storeSource.contains("case .yearlyPaidMonthly"))
        XCTAssertTrue(storeSource.contains("Product.products(for: LavaSecurityPlusPolicy.paywallProductIDs)"))
        XCTAssertTrue(storeSource.contains("pricingTerms"))
        XCTAssertTrue(storeSource.contains("if #available(iOS 26.4, *)"))
        XCTAssertTrue(storeSource.contains("billingPlanType == .monthly"))
        XCTAssertTrue(storeSource.contains("product.subscription?.pricingTerms.contains"))
        XCTAssertTrue(storeSource.contains("options.insert(.billingPlanType(.monthly))"))
        XCTAssertTrue(storeSource.contains("commitmentDisplayPrice"))
        XCTAssertTrue(storeSource.contains("yearlyPaidMonthlyOffer(from: productsByID[plan.productID])"))
        XCTAssertTrue(storeSource.contains("LavaSecurityPlusPolicy.recommendedOfferOrder.compactMap"))
        // The store must NOT fabricate fallback offers — `offers` holds live StoreKit offers or is
        // empty, and the display-only fallback list is supplied by the native presentation helper. The
        // store previously seeded `fallbackOfferOrder` in `init`/`loadProducts`, which kept the
        // paywall's `offers.isEmpty` load guard from ever retrying after a failed launch load.
        XCTAssertFalse(storeSource.contains("LavaSecurityPlusPolicy.fallbackOfferOrder"))
        // The controller must NOT pre-seed offers with the fallback list — doing so froze the
        // paywall's `offers.isEmpty` load guard so live StoreKit products never loaded. The fallback
        // is supplied by `displayedOffers` in the presentation helper instead (asserted below + in
        // LavaSecurityPlusOffersLoadSourceTests).
        XCTAssertFalse(controllerSource.contains("lavaSecurityPlusOffers: [LavaSecurityPlusOffer] = LavaSecurityPlusPolicy.fallbackOfferOrder.map"))
        XCTAssertTrue(settingsSource.contains("LavaSecurityPlusPolicy.fallbackOfferOrder.map"))
        XCTAssertFalse(controllerSource.contains("lavaSecurityPlusOffers: [LavaSecurityPlusOffer] = LavaSecurityPlusPolicy.recommendedOfferOrder.map"))
    }

    func testYearlySavingsPitchIsComputedFromStoreKitPricesNotHardcoded() throws {
        let storeSource = try readSource(.lavaSecurityPlusStore)
        let presentation = try readSource(.upgradeSettingsView)
        let bridge = try readSource(.reactNativeAppBridge)
        XCTAssertTrue(storeSource.contains("let savingsPercent: Int?"))
        XCTAssertTrue(storeSource.contains("func yearlySavingsPercent(yearly: Product?, monthly: Product?)"))
        XCTAssertTrue(storeSource.contains("let annualizedMonthly = monthly.price * 12"))
        XCTAssertTrue(storeSource.contains("Int(truncating: NSDecimalNumber("))
        XCTAssertFalse(storeSource.contains(".doubleValue * 100"),
                       "The savings floor must stay in Decimal space, not round-trip the fraction through Double.")
        XCTAssertTrue(storeSource.contains("minimumDisplayableSavingsPercent"))
        XCTAssertTrue(storeSource.contains("savingsPercent: plan.kind == .yearly ? savingsPercent : nil"))
        XCTAssertTrue(presentation.contains("static func planPitch(for offer: LavaSecurityPlusOffer)"))
        XCTAssertTrue(presentation.contains("if let savingsPercent = offer.savingsPercent"))
        XCTAssertTrue(presentation.contains("We are saving %d%%! This has the best value."))
        XCTAssertTrue(presentation.contains(".lavaLocalizedFormat(savingsPercent)"))
        XCTAssertTrue(presentation.contains("Paying by the year beats paying by the month."))
        XCTAssertTrue(bridge.contains("\"subtitle\": LavaPlusPresentation.planPitch(for: offer)"))
        XCTAssertTrue(try readSource(.reactNativeSettingsScreens).contains("subtitle={offer.subtitle}"))
        XCTAssertFalse(presentation.contains("We are saving 37%!"))
        XCTAssertFalse(presentation.contains("planPitch(for: offer.plan.kind)"))
    }

    func testUpgradeScreenShowsCommitmentPitchAndFamilySharingBenefit() throws {
        let presentation = try readSource(.upgradeSettingsView)
        let screen = try readSource(.reactNativeSettingsScreens)
        let bridge = try readSource(.reactNativeAppBridge)
        XCTAssertTrue(presentation.contains("If we commit for 12 months, each month is cheaper."))
        XCTAssertTrue(presentation.contains("case .yearlyPaidMonthly"))
        XCTAssertTrue(screen.contains("billed monthly on a 12-month commitment"))
        XCTAssertTrue(screen.contains("cancelling affects the next renewal"))
        XCTAssertTrue(bridge.contains("let commitment = offer.plan.kind == .yearlyPaidMonthly ? offer.commitmentDisplayPrice : nil"))
        XCTAssertTrue(bridge.contains("\"price\": offer.displayPrice"))
        XCTAssertTrue(bridge.contains("\"commitmentPrice\": commitment.map { \"%@ total\".lavaLocalizedFormat($0) } ?? \"\""))
        XCTAssertTrue(screen.contains("<SettingsPrice price={offer.price} commitment={offer.commitmentPrice}/>"))
        XCTAssertTrue(try readSource(.reactNativePlusScaffold).contains("['Family Sharing','Included']"))
    }

    func testAutoRenewFooterDropsCommitmentSentenceWhenYearlyPaidMonthlyIsAbsent() throws {
        let screen = try sourceBlock(in: readSource(.reactNativeSettingsScreens), startingAt: "export function LavaPlusPage(")
        let bridge = try readSource(.reactNativeAppBridge)
        XCTAssertTrue(bridge.contains("\"showsYearlyPaidMonthly\": plusOffers.contains { $0.plan.kind == .yearlyPaidMonthly }"))
        XCTAssertTrue(screen.contains("live?.plus.showsYearlyPaidMonthly ? 'Monthly and yearly plans auto-renew. Yearly paid monthly is billed monthly on a 12-month commitment;"))
        XCTAssertTrue(screen.contains(": 'Monthly and yearly plans auto-renew. Payment is charged to your Apple Account at purchase"))
        XCTAssertTrue(screen.contains("title=\"Terms of Use\""))
        XCTAssertTrue(screen.contains("Linking.openURL('https://www.apple.com/legal/internet-services/itunes/dev/stdeula/')"))
        XCTAssertTrue(screen.contains("title=\"Privacy Policy\""))
        XCTAssertTrue(screen.contains("Linking.openURL('https://lavasecurity.app/privacy/')"))
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
        // A `Transaction.updates` push is authoritative, so both the immediate apply and the
        // empty-re-read fallback are `.confirmed` (a real revocation/expiry must still demote).
        XCTAssertTrue(handleBlock.contains("setEntitlement(entitlement, confidence: .confirmed)"))
        XCTAssertTrue(handleBlock.contains("_ = await refreshEntitlements(confidence: .confirmed)"))
        XCTAssertLessThan(
            try XCTUnwrap(handleBlock.range(of: "setEntitlement(entitlement, confidence: .confirmed)")?.lowerBound),
            try XCTUnwrap(handleBlock.range(of: "_ = await refreshEntitlements(confidence: .confirmed)")?.lowerBound)
        )
        XCTAssertTrue(handleBlock.contains("await transaction.finish()"))
    }
}
