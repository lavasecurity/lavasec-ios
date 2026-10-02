import Foundation
import LavaSecFilterPipeline
import LavaSecKit
import SwiftUI

// The LavaSecurity+ paywall & billing feature, peeled out of AppViewModel (Phase D2,
// lavasec-infra plans/2026-07-07-ios-modularization-scaffolding-plan.md): StoreKit
// product/offer loading, entitlement refresh + the Transaction.updates observation
// (via the LOCAL LavaSecurityPlusStore), purchase/restore with the paywall status
// messages, and the server entitlement sync with its single 401 refresh-retry. The hub
// (AppViewModel) remains the single owner of the configuration — including the paid
// flag and its persistence funnel — and the single ROUTING point for the Supabase
// session (owned by AccountController since the Phase D3 account peel); this controller
// reaches those only through the narrow `LavaSecurityPlusHubBridging` surface below,
// mirroring the scoped-controller pattern of BackupController / SecurityController.

private struct LavaSecurityPlusEntitlementSyncClient: Sendable {
    let urlSession: URLSession

    func sync(
        entitlement: LavaSecurityPlusEntitlement,
        session: BackupAccountSession
    ) async throws {
        guard let productID = entitlement.productID,
              let transactionID = entitlement.transactionID,
              let originalTransactionID = entitlement.originalTransactionID,
              let signedTransactionJWS = entitlement.signedTransactionJWS,
              !signedTransactionJWS.isEmpty
        else {
            return
        }

        let body = LavaSecurityPlusEntitlementSyncRequest(
            productID: productID,
            transactionID: transactionID,
            originalTransactionID: originalTransactionID,
            signedTransactionJWS: signedTransactionJWS,
            active: entitlement.isActive,
            expiresAt: entitlement.expiresAt,
            environment: entitlement.environment
        )
        let requestBody = try Self.makeJSONEncoder().encode(body)
        var lastError: Error?

        for endpoint in Self.syncEndpointURLs {
            do {
                var request = URLRequest(url: endpoint)
                request.httpMethod = "POST"
                request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                request.httpBody = requestBody

                let (responseData, response) = try await urlSession.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw LavaSecurityPlusEntitlementSyncError.invalidResponse
                }

                guard 200..<300 ~= httpResponse.statusCode else {
                    let serverMessage = String(data: responseData, encoding: .utf8) ?? "No response body"
                    throw LavaSecurityPlusEntitlementSyncError.requestFailed(
                        statusCode: httpResponse.statusCode,
                        message: serverMessage
                    )
                }

                return
            } catch {
                lastError = error
            }
        }

        throw lastError ?? LavaSecurityPlusEntitlementSyncError.invalidResponse
    }

    private static var syncEndpointURLs: [URL] {
        [LavaSecAPI.productionBaseURL, LavaSecAPI.fallbackBaseURL].map {
            $0
                .appendingPathComponent("v1")
                .appendingPathComponent("account")
                .appendingPathComponent("entitlements")
                .appendingPathComponent("app-store-sync")
        }
    }

    private static func makeJSONEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private struct LavaSecurityPlusEntitlementSyncRequest: Encodable {
    let productID: String
    let transactionID: String
    let originalTransactionID: String
    let signedTransactionJWS: String
    let active: Bool
    let expiresAt: Date?
    let environment: String?

    private enum CodingKeys: String, CodingKey {
        case productID = "product_id"
        case transactionID = "transaction_id"
        case originalTransactionID = "original_transaction_id"
        case signedTransactionJWS = "signed_transaction_jws"
        case active
        case expiresAt = "expires_at"
        case environment
    }
}

private enum LavaSecurityPlusEntitlementSyncError: Error, LocalizedError {
    case invalidResponse
    case requestFailed(statusCode: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "The subscription sync server response was not valid.".lavaLocalized
        case .requestFailed(let statusCode, let message):
            "Subscription sync returned HTTP %lld: %@".lavaLocalizedFormat(statusCode, message)
        }
    }
}

/// The narrow hub surface the LavaSecurity+ controller depends on (Phase D2).
/// Everything the billing cluster needs from AppViewModel and nothing else, so the
/// hub stays the owner of the shared state:
///
/// - **Paid-plan flag**: `hasLavaSecurityPlus` reads the persisted configuration's
///   derived plan; `persistPaidPlanFlag` writes `configuration.isPaid` and persists it
///   through the hub's configuration-only funnel (deliberately NO reload signal — the
///   rationale lives on the conformance, with the code).
/// - **Session access**: `currentBackupSession`/`refreshCurrentBackupSession` are raw
///   pass-throughs to the AccountController-owned AccountAuthService (the hub delegates
///   through its `account` controller since the Phase D3 peel); `mirrorAccountAuthState`
///   re-publishes the service state onto AccountController's `accountAuthState`. They
///   are separate calls (not a combined call-then-mirror) so the controller preserves
///   the pre-peel mirror ordering exactly at every call site. The three signatures are
///   shared with `BackupHubBridging` on purpose: AppViewModel satisfies both protocols
///   with the same members, keeping ONE canonical Supabase identity path.
@MainActor
protocol LavaSecurityPlusHubBridging: AnyObject {
    var hasLavaSecurityPlus: Bool { get }
    func persistPaidPlanFlag(_ isPaid: Bool) throws
    func currentBackupSession() async throws -> BackupAccountSession?
    func refreshCurrentBackupSession() async throws -> BackupAccountSession?
    func mirrorAccountAuthState()
}

@MainActor
final class LavaSecurityPlusController: ObservableObject {
    // Starts EMPTY on purpose — it holds offers actually loaded from StoreKit, not the display
    // fallback. The paywall's on-appear guard loads products only while this is empty, and
    // `displayedOffers` substitutes the hardcoded fallback list whenever it's empty, so the UI
    // still shows something before the load completes. Pre-seeding it with the fallback offers (as
    // it was) made `.isEmpty` never true, so `loadLavaSecurityPlusProducts()` never ran and the
    // paywall showed hardcoded fallback prices ($3.99/$29.99) forever instead of live StoreKit
    // prices — and never surfaced the yearly-paid-monthly offer.
    @Published private(set) var lavaSecurityPlusOffers: [LavaSecurityPlusOffer] = []
    @Published private(set) var isLoadingLavaSecurityPlusProducts = false
    @Published private(set) var hasCheckedLavaSecurityPlusEntitlements = false
    @Published private(set) var isRefreshingLavaSecurityPlusEntitlements = false
    /// Expiry of the active auto-renewable Lava Security Plus entitlement (nil when
    /// there is no active entitlement). Drives the subscriber "Expiration" line and
    /// gates the Manage Subscription control.
    @Published private(set) var lavaSecurityPlusExpiresAt: Date?
    @Published private(set) var isPurchasingLavaSecurityPlus = false
    @Published private(set) var lavaSecurityPlusMessage: String?
    @Published private(set) var lavaSecurityPlusMessageIsError = false

    // The StoreKit boundary (products, Transaction.currentEntitlements/updates,
    // purchase/restore). Owned here: `startLavaSecurityPlusStore()` installs its
    // entitlement listener + starts its updates task, and the store cancels that task
    // in ITS deinit when this controller (its only owner) deallocates — the listener
    // and the load task below hold `self` weakly, so nothing keeps the pair alive.
    private let lavaSecurityPlusStore = LavaSecurityPlusStore()
    private let lavaSecurityPlusEntitlementSyncClient = LavaSecurityPlusEntitlementSyncClient(urlSession: .shared)

    // The hub outlives this controller (AppViewModel owns it strongly), so an unowned
    // back-reference avoids a retain cycle without weak-optional noise on every call.
    private unowned let hub: any LavaSecurityPlusHubBridging

    init(hub: any LavaSecurityPlusHubBridging) {
        self.hub = hub
    }

    // MARK: - Paywall & billing

    func loadLavaSecurityPlusProducts() async {
        isLoadingLavaSecurityPlusProducts = true
        await lavaSecurityPlusStore.loadProducts()
        lavaSecurityPlusOffers = lavaSecurityPlusStore.offers
        isLoadingLavaSecurityPlusProducts = false
    }

    func refreshLavaSecurityPlusEntitlements() async {
        guard !isRefreshingLavaSecurityPlusEntitlements else {
            return
        }

        isRefreshingLavaSecurityPlusEntitlements = true
        defer {
            isRefreshingLavaSecurityPlusEntitlements = false
        }

        // `.unconfirmed`: this is the bare `currentEntitlements` read (startup + Upgrade screen) with no
        // preceding `AppStore.sync()`, so a negative result must not demote a previously-entitled user.
        let entitlement = await lavaSecurityPlusStore.refreshEntitlements(confidence: .unconfirmed)
        applyLavaSecurityPlusEntitlement(entitlement, confidence: .unconfirmed)
        hasCheckedLavaSecurityPlusEntitlements = true
        await syncLavaSecurityPlusEntitlementIfPossible(entitlement)
    }

    func purchaseLavaSecurityPlus(_ offer: LavaSecurityPlusOffer) async {
        guard !isPurchasingLavaSecurityPlus else {
            return
        }

        isPurchasingLavaSecurityPlus = true
        let feedbackID = LavaFeedbackCoordinator.shared.begin("plus.purchase")
        lavaSecurityPlusMessage = nil
        lavaSecurityPlusMessageIsError = false
        defer {
            isPurchasingLavaSecurityPlus = false
        }

        do {
            let appAccountToken = await currentLavaSecurityPlusAppAccountToken()
            let result = try await lavaSecurityPlusStore.purchase(
                offer,
                appAccountToken: appAccountToken
            )
            lavaSecurityPlusOffers = lavaSecurityPlusStore.offers

            switch result {
            case .purchased(let entitlement):
                LavaFeedbackCoordinator.shared.finish("plus.purchase", feedbackID, entitlement.isActive ? .succeeded : .attentionRequired)
                applyLavaSecurityPlusEntitlement(entitlement, confidence: .confirmed)
                await syncLavaSecurityPlusEntitlementIfPossible(entitlement)
                if entitlement.isActive {
                    // The subscriber thank-you section already announces the
                    // active state, so skip the redundant confirmation line.
                    lavaSecurityPlusMessage = nil
                    lavaSecurityPlusMessageIsError = false
                } else {
                    // Producer-side status strings localize AT ASSIGNMENT: the render is a
                    // verbatim Text(variable) on the Upgrade page, which resolves no key
                    // (the i18n round-3 render-path class), and interpolations must be
                    // format keys at the producer.
                    lavaSecurityPlusMessage = "No active Lava Security Plus purchase was found.".lavaLocalized
                    lavaSecurityPlusMessageIsError = true
                }
            case .pending:
                lavaSecurityPlusMessage = "The App Store purchase is pending approval.".lavaLocalized
                lavaSecurityPlusMessageIsError = false
            case .cancelled:
                lavaSecurityPlusMessage = "Purchase cancelled".lavaLocalized
                lavaSecurityPlusMessageIsError = false
            }
        } catch {
            lavaSecurityPlusMessage = "Could not complete purchase: %@".lavaLocalizedFormat(error.localizedDescription)
            LavaFeedbackCoordinator.shared.finish("plus.purchase", feedbackID, .failed, cancelled: error is CancellationError)
            lavaSecurityPlusMessageIsError = true
        }
    }

    func restoreLavaSecurityPlusPurchases() async {
        guard !isPurchasingLavaSecurityPlus else {
            return
        }

        isPurchasingLavaSecurityPlus = true
        let feedbackID = LavaFeedbackCoordinator.shared.begin("plus.restore")
        lavaSecurityPlusMessage = "Checking the App Store for purchases.".lavaLocalized
        lavaSecurityPlusMessageIsError = false
        defer {
            isPurchasingLavaSecurityPlus = false
        }

        do {
            let entitlement = try await lavaSecurityPlusStore.restorePurchases()
            LavaFeedbackCoordinator.shared.finish("plus.restore", feedbackID, entitlement.isActive ? .succeeded : .attentionRequired)
            applyLavaSecurityPlusEntitlement(entitlement, confidence: .confirmed)
            await syncLavaSecurityPlusEntitlementIfPossible(entitlement)
            lavaSecurityPlusMessage = entitlement.isActive
                ? "Lava Security Plus is restored.".lavaLocalized
                : "No active Lava Security Plus purchase was found.".lavaLocalized
            lavaSecurityPlusMessageIsError = !entitlement.isActive
        } catch {
            lavaSecurityPlusMessage = "Could not restore purchases: %@".lavaLocalizedFormat(error.localizedDescription)
            LavaFeedbackCoordinator.shared.finish("plus.restore", feedbackID, .failed, cancelled: error is CancellationError)
            lavaSecurityPlusMessageIsError = true
        }
    }

    func clearLavaSecurityPlusMessage() {
        lavaSecurityPlusMessage = nil
        lavaSecurityPlusMessageIsError = false
    }

    /// Sign-in follow-up for the hub's Apple/Google success paths: now that a session
    /// exists, push the store's CURRENT entitlement to the server sync. Same call the
    /// pre-peel hub made with `lavaSecurityPlusStore.entitlement` — the store stays
    /// private here, so the hub asks for "current" instead of reaching for it.
    func syncCurrentLavaSecurityPlusEntitlementIfPossible() async {
        await syncLavaSecurityPlusEntitlementIfPossible(lavaSecurityPlusStore.entitlement)
    }

    // MARK: - Store lifecycle & entitlement application

    /// Called once from the hub's NON-headless init (the entitlement listener persists
    /// the paid flag via the hub, so the headless background-refresh instance must
    /// never install it — see the hub's init gating comment). Installs the listener,
    /// starts the store's Transaction.updates task, and kicks off the initial
    /// product-load + entitlement refresh.
    func startLavaSecurityPlusStore() {
        lavaSecurityPlusOffers = lavaSecurityPlusStore.offers
        lavaSecurityPlusStore.entitlementChanged = { [weak self] entitlement, confidence in
            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }

                self.applyLavaSecurityPlusEntitlement(entitlement, confidence: confidence)
                await self.syncLavaSecurityPlusEntitlementIfPossible(entitlement)
            }
        }
        lavaSecurityPlusStore.start()

        Task { [weak self] in
            guard let self else {
                return
            }

            await self.loadLavaSecurityPlusProducts()
            await self.refreshLavaSecurityPlusEntitlements()
        }
    }

    private func applyLavaSecurityPlusEntitlement(
        _ entitlement: LavaSecurityPlusEntitlement,
        confidence: EntitlementReadingConfidence
    ) {
        var hasLavaSecurityPlus = entitlement.isActive
        #if DEBUG || LAVA_QA_TOOLS
        // A locally built QA app has no App Store receipt, so `entitlement.isActive` is false
        // and this sync REVOKES a plan the operator deliberately forced with
        // `-LavaQAForcePaidPlan`. It fired seven times in one device session, each logged only
        // as `chained-upstream-disabled {cause: notEntitled}` from the downstream reconcile —
        // so chaining kept switching itself off mid-test and the cause was two hops away from
        // the symptom. Honour the override rather than fight it.
        //
        // QA-gated and opt-in: without the launch argument this is byte-for-byte the old
        // behaviour, and a Release build cannot reach it at all.
        if !hasLavaSecurityPlus, UserDefaults.standard.bool(forKey: "LavaQAForcePaidPlan") {
            hasLavaSecurityPlus = true
        }
        #endif
        // Only an authoritative (`.confirmed`) reading may demote a previously-entitled user. A bare
        // `currentEntitlements` pass (`.unconfirmed`) that comes back empty is treated as "unknown, keep
        // what's stored", so a cold/unsynced StoreKit cache cannot silently strip a paying subscriber's
        // tier (freezing over-cap filters, dropping Plus UI to Free) or — post-Phase-4 — destructively
        // clear their chaining preference. Mirrors the transient-false guard in
        // `reconcileChainedUpstreamAfterEligibilityChange`. See `EntitlementApplicationPolicy`.
        // pinned: EntitlementApplicationPolicyTests.testAnUnconfirmedEmptyReadingKeepsAPaidUser
        let resolvedHasLavaSecurityPlus = EntitlementApplicationPolicy.resolvedHasLavaSecurityPlus(
            computed: hasLavaSecurityPlus,
            persisted: hub.hasLavaSecurityPlus,
            confidence: confidence)

        // Surface the auto-renewable expiry (before the early-return, so the subscriber UI stays current
        // even when the active flag is unchanged — e.g. a renewal that only moves the expiry date). An
        // active reading sets it; a real demote clears it; but an UNCONFIRMED empty read we are KEEPING as
        // Plus must NOT blank the expiry — that would flash "Plus, no renewal date" on the exact transient
        // this guard exists to absorb — so leave the last-known value untouched.
        if entitlement.isActive {
            if lavaSecurityPlusExpiresAt != entitlement.expiresAt {
                lavaSecurityPlusExpiresAt = entitlement.expiresAt
            }
        } else if !resolvedHasLavaSecurityPlus, lavaSecurityPlusExpiresAt != nil {
            lavaSecurityPlusExpiresAt = nil
        }

        guard hub.hasLavaSecurityPlus != resolvedHasLavaSecurityPlus else {
            return
        }

        // Persist-only through the hub — deliberately NO configuration-reload signal;
        // the rationale lives on the LavaSecurityPlusHubBridging conformance in
        // AppViewModel.swift, with the persist code.
        do {
            try hub.persistPaidPlanFlag(resolvedHasLavaSecurityPlus)
        } catch {
            lavaSecurityPlusMessage = "Could not save plan state: %@".lavaLocalizedFormat(error.localizedDescription)
            lavaSecurityPlusMessageIsError = true
        }
    }

    private func currentLavaSecurityPlusAppAccountToken() async -> UUID? {
        guard let session = try? await hub.currentBackupSession() else {
            hub.mirrorAccountAuthState()
            return nil
        }

        hub.mirrorAccountAuthState()
        return UUID(uuidString: session.userID)
    }

    private func syncLavaSecurityPlusEntitlementIfPossible(
        _ entitlement: LavaSecurityPlusEntitlement
    ) async {
        guard entitlement.isActive,
              let signedTransactionJWS = entitlement.signedTransactionJWS,
              !signedTransactionJWS.isEmpty
        else {
            return
        }

        do {
            guard let session = try await hub.currentBackupSession() else {
                hub.mirrorAccountAuthState()
                return
            }

            hub.mirrorAccountAuthState()
            try await lavaSecurityPlusEntitlementSyncClient.sync(
                entitlement: entitlement,
                session: session
            )
        } catch LavaSecurityPlusEntitlementSyncError.requestFailed(let statusCode, _) where statusCode == 401 {
            do {
                guard let refreshedSession = try await hub.refreshCurrentBackupSession() else {
                    hub.mirrorAccountAuthState()
                    return
                }

                hub.mirrorAccountAuthState()
                try await lavaSecurityPlusEntitlementSyncClient.sync(
                    entitlement: entitlement,
                    session: refreshedSession
                )
            } catch {
                hub.mirrorAccountAuthState()
            }
        } catch {
            hub.mirrorAccountAuthState()
        }
    }
}
