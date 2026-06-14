import XCTest

final class LavaSecurityPlusSourceTests: XCTestCase {
    func testUpgradeScreenUsesRealPlusProductsAndRestoreActions() throws {
        let settingsSource = try Self.source(named: "SettingsView.swift", in: "LavaSecApp")
        let viewModelSource = try Self.source(named: "AppViewModel.swift", in: "LavaSecApp")

        XCTAssertFalse(settingsSource.contains("TODO_REPLACE_WITH_APP_STORE_PRODUCT_ID"))
        XCTAssertTrue(settingsSource.contains("LavaSecurityPlusPolicy.recommendedOfferOrder"))
        XCTAssertTrue(settingsSource.contains("viewModel.purchaseLavaSecurityPlus"))
        XCTAssertTrue(settingsSource.contains("viewModel.restoreLavaSecurityPlusPurchases"))
        XCTAssertTrue(settingsSource.contains(".navigationTitle(\"Lava Security Plus\")"))
        XCTAssertTrue(settingsSource.contains(".navigationBarTitleDisplayMode(.large)"))
        XCTAssertTrue(settingsSource.contains("Text(\"More room for your rules\")"))
        XCTAssertTrue(settingsSource.contains("Text(\"More room for your rules\")\n                    .foregroundStyle(LavaStyle.lavaOrange)"))
        XCTAssertFalse(settingsSource.contains("title: \"More room for your rules\""))
        XCTAssertFalse(settingsSource.contains("UpgradeLargeTitle()"))
        XCTAssertFalse(settingsSource.contains("Text(\"Lava Security Plus\")\n                        .foregroundStyle(LavaStyle.lavaOrange)\n                    Text(\" unlocks\")"))
        XCTAssertTrue(viewModelSource.contains("func purchaseLavaSecurityPlus"))
        XCTAssertTrue(viewModelSource.contains("func restoreLavaSecurityPlusPurchases"))
        XCTAssertTrue(viewModelSource.contains("configuration.hasLavaSecurityPlus ? \"Lava Security Plus\" : \"Free plan\""))
    }

    func testUpgradeScreenMasksPurchaseControlsWhenPlusIsActive() throws {
        let settingsSource = try Self.source(named: "SettingsView.swift", in: "LavaSecApp")
        let viewModelSource = try Self.source(named: "AppViewModel.swift", in: "LavaSecApp")
        let upgradeViewBlock = try Self.sourceBlock(
            settingsSource,
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

        let activePlanBlock = try Self.sourceBlock(
            upgradeViewBlock,
            startingAt: "if viewModel.configuration.hasLavaSecurityPlus",
            endingBefore: "} else {"
        )
        XCTAssertFalse(activePlanBlock.contains("Choose a plan"))
        XCTAssertFalse(activePlanBlock.contains("Restore Purchase"))

        let thankYouBlock = try Self.sourceBlock(
            settingsSource,
            startingAt: "private struct UpgradeThankYouView: View",
            endingBefore: "struct LavaPlusUpgradeDestination"
        )
        let thankYouMascotBlock = try Self.sourceBlock(
            settingsSource,
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

        let checkingBlock = try Self.sourceBlock(
            settingsSource,
            startingAt: "private struct UpgradeEntitlementCheckingView: View",
            endingBefore: "struct LavaPlusUpgradeDestination"
        )
        XCTAssertTrue(checkingBlock.contains("ProgressView()"))
        XCTAssertTrue(checkingBlock.contains("Checking Lava Security Plus"))
        XCTAssertFalse(checkingBlock.contains("Choose a plan"))
        XCTAssertFalse(checkingBlock.contains("Restore Purchase"))
    }

    func testPlanComparisonShowsUnlockedBenefitsInGreen() throws {
        let settingsSource = try Self.source(named: "SettingsView.swift", in: "LavaSecApp")
        let comparisonBlock = try Self.sourceBlock(
            settingsSource,
            startingAt: "private struct UpgradePlanComparisonView: View",
            endingBefore: "private struct UpgradePlanOfferRow: View"
        )

        XCTAssertTrue(comparisonBlock.contains("\"All Lava Guards\""))
        XCTAssertTrue(comparisonBlock.contains("\"Custom blocklists\""))
        XCTAssertTrue(comparisonBlock.contains("\"Custom DNS\""))
        XCTAssertTrue(comparisonBlock.contains("(\"All Lava Guards\", nil, .unlocked)"))
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
        XCTAssertFalse(comparisonBlock.contains("(\"Custom blocklists\", \"Off\", \"On\")"))
        XCTAssertFalse(comparisonBlock.contains("(\"Custom DNS\", \"Off\", \"On\")"))
        XCTAssertFalse(comparisonBlock.contains("(\"Custom blocklists\", \"Off\", .included)"))
        XCTAssertFalse(comparisonBlock.contains("(\"Custom DNS\", \"Off\", .included)"))
    }

    func testStoreKitBoundaryMirrorsEntitlementsAfterLocalVerification() throws {
        let storeSource = try Self.source(named: "LavaSecurityPlusStore.swift", in: "LavaSecApp")
        let viewModelSource = try Self.source(named: "AppViewModel.swift", in: "LavaSecApp")

        XCTAssertTrue(storeSource.contains("Transaction.currentEntitlements"))
        XCTAssertTrue(storeSource.contains("Transaction.updates"))
        XCTAssertTrue(storeSource.contains("AppStore.sync()"))
        XCTAssertTrue(storeSource.contains(".appAccountToken"))
        XCTAssertTrue(viewModelSource.contains("LavaSecurityPlusEntitlementSyncClient"))
        XCTAssertTrue(viewModelSource.contains("syncLavaSecurityPlusEntitlementIfPossible"))
        XCTAssertTrue(viewModelSource.contains("signedTransactionJWS"))
    }

    func testTransactionUpdatesApplyReceivedVerifiedTransactionImmediately() throws {
        let storeSource = try Self.source(named: "LavaSecurityPlusStore.swift", in: "LavaSecApp")
        let handleBlock = try Self.sourceBlock(
            storeSource,
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

    private static func source(named fileName: String, in directoryName: String) throws -> String {
        let current = URL(fileURLWithPath: #filePath)
        let testsDirectory = current.deletingLastPathComponent()
        let packageDirectory = testsDirectory
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appDirectory = packageDirectory.appendingPathComponent(directoryName)
        return try String(contentsOf: appDirectory.appendingPathComponent(fileName), encoding: .utf8)
    }

    private static func sourceBlock(
        _ source: String,
        startingAt startMarker: String,
        endingBefore endMarker: String
    ) throws -> String {
        guard let start = source.range(of: startMarker)?.lowerBound else {
            throw XCTSkip("Missing start marker: \(startMarker)")
        }
        guard let end = source[start...].range(of: endMarker)?.lowerBound else {
            throw XCTSkip("Missing end marker: \(endMarker)")
        }
        return String(source[start..<end])
    }
}
