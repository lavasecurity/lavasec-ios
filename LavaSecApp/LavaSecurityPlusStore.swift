import Foundation
import LavaSecCore
import StoreKit

struct LavaSecurityPlusOffer: Identifiable {
    let plan: LavaSecurityPlusPlan
    let displayPrice: String
    let product: Product?

    var id: String {
        plan.productID
    }

    var title: String {
        switch plan.kind {
        case .monthly:
            "Monthly"
        case .yearly:
            "Yearly"
        case .lifetime:
            "Lifetime"
        }
    }

    var subtitle: String {
        switch plan.kind {
        case .monthly:
            "Flexible subscription"
        case .yearly:
            "Best value"
        case .lifetime:
            "One-time unlock"
        }
    }
}

struct LavaSecurityPlusEntitlement: Equatable {
    let isActive: Bool
    let productID: String?
    let transactionID: String?
    let originalTransactionID: String?
    let signedTransactionJWS: String?
    let expiresAt: Date?
    let environment: String?

    static let inactive = LavaSecurityPlusEntitlement(
        isActive: false,
        productID: nil,
        transactionID: nil,
        originalTransactionID: nil,
        signedTransactionJWS: nil,
        expiresAt: nil,
        environment: nil
    )
}

enum LavaSecurityPlusPurchaseResult: Equatable {
    case purchased(LavaSecurityPlusEntitlement)
    case pending
    case cancelled
}

enum LavaSecurityPlusStoreError: LocalizedError {
    case productUnavailable
    case unverifiedPurchase

    var errorDescription: String? {
        switch self {
        case .productUnavailable:
            "Lava Security Plus is not available from the App Store yet. Try again later."
        case .unverifiedPurchase:
            "The App Store purchase could not be verified."
        }
    }
}

@MainActor
final class LavaSecurityPlusStore: ObservableObject {
    @Published private(set) var offers: [LavaSecurityPlusOffer]
    @Published private(set) var entitlement = LavaSecurityPlusEntitlement.inactive
    @Published private(set) var isLoadingProducts = false
    @Published private(set) var isPurchasing = false

    var entitlementChanged: ((LavaSecurityPlusEntitlement) -> Void)?

    private var updatesTask: Task<Void, Never>?

    init() {
        offers = LavaSecurityPlusPolicy.recommendedOfferOrder.map {
            LavaSecurityPlusOffer(
                plan: $0,
                displayPrice: $0.fallbackDisplayPrice,
                product: nil
            )
        }
    }

    deinit {
        updatesTask?.cancel()
    }

    func start() {
        guard updatesTask == nil else {
            return
        }

        updatesTask = Task { [weak self] in
            for await result in Transaction.updates {
                guard let self else {
                    return
                }

                await self.handle(transactionResult: result)
            }
        }
    }

    func loadProducts() async {
        isLoadingProducts = true
        defer { isLoadingProducts = false }

        do {
            let products = try await Product.products(for: LavaSecurityPlusPolicy.productIDs)
            let productsByID = Dictionary(uniqueKeysWithValues: products.map { ($0.id, $0) })
            offers = LavaSecurityPlusPolicy.recommendedOfferOrder.map { plan in
                LavaSecurityPlusOffer(
                    plan: plan,
                    displayPrice: productsByID[plan.productID]?.displayPrice ?? plan.fallbackDisplayPrice,
                    product: productsByID[plan.productID]
                )
            }
        } catch {
            offers = LavaSecurityPlusPolicy.recommendedOfferOrder.map {
                LavaSecurityPlusOffer(
                    plan: $0,
                    displayPrice: $0.fallbackDisplayPrice,
                    product: nil
                )
            }
        }
    }

    @discardableResult
    func refreshEntitlements() async -> LavaSecurityPlusEntitlement {
        var bestEntitlement: LavaSecurityPlusEntitlement?

        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                  let entitlement = activeEntitlement(
                    from: transaction,
                    signedTransactionJWS: result.jwsRepresentation
                  )
            else {
                continue
            }

            bestEntitlement = Self.preferredEntitlement(bestEntitlement, entitlement)
        }

        let nextEntitlement = bestEntitlement ?? .inactive
        setEntitlement(nextEntitlement)
        return nextEntitlement
    }

    func purchase(
        _ offer: LavaSecurityPlusOffer,
        appAccountToken: UUID?
    ) async throws -> LavaSecurityPlusPurchaseResult {
        guard !isPurchasing else {
            return .pending
        }

        isPurchasing = true
        defer { isPurchasing = false }

        let product = try await loadedProduct(for: offer)
        var options = Set<Product.PurchaseOption>()
        if let appAccountToken {
            options.insert(.appAccountToken(appAccountToken))
        }

        let result = try await product.purchase(options: options)
        switch result {
        case .success(let verificationResult):
            guard case .verified(let transaction) = verificationResult else {
                throw LavaSecurityPlusStoreError.unverifiedPurchase
            }

            guard let entitlement = activeEntitlement(
                from: transaction,
                signedTransactionJWS: verificationResult.jwsRepresentation
            ) else {
                await transaction.finish()
                let refreshedEntitlement = await refreshEntitlements()
                return .purchased(refreshedEntitlement)
            }

            setEntitlement(entitlement)
            await transaction.finish()
            return .purchased(entitlement)
        case .pending:
            return .pending
        case .userCancelled:
            return .cancelled
        @unknown default:
            return .pending
        }
    }

    @discardableResult
    func restorePurchases() async throws -> LavaSecurityPlusEntitlement {
        try await AppStore.sync()
        return await refreshEntitlements()
    }

    private func handle(transactionResult: VerificationResult<Transaction>) async {
        guard case .verified(let transaction) = transactionResult else {
            return
        }

        if let entitlement = activeEntitlement(
            from: transaction,
            signedTransactionJWS: transactionResult.jwsRepresentation
        ) {
            setEntitlement(entitlement)
        } else {
            _ = await refreshEntitlements()
        }
        await transaction.finish()
    }

    private func loadedProduct(for offer: LavaSecurityPlusOffer) async throws -> Product {
        if let product = offer.product {
            return product
        }

        let products = try await Product.products(for: [offer.plan.productID])
        guard let product = products.first(where: { $0.id == offer.plan.productID }) else {
            throw LavaSecurityPlusStoreError.productUnavailable
        }

        return product
    }

    private func activeEntitlement(
        from transaction: Transaction,
        signedTransactionJWS: String
    ) -> LavaSecurityPlusEntitlement? {
        guard LavaSecurityPlusPolicy.plan(for: transaction.productID) != nil else {
            return nil
        }

        guard transaction.revocationDate == nil else {
            return nil
        }

        if let expirationDate = transaction.expirationDate, expirationDate <= Date() {
            return nil
        }

        return LavaSecurityPlusEntitlement(
            isActive: true,
            productID: transaction.productID,
            transactionID: String(transaction.id),
            originalTransactionID: String(transaction.originalID),
            signedTransactionJWS: signedTransactionJWS,
            expiresAt: transaction.expirationDate,
            environment: String(describing: transaction.environment)
        )
    }

    private func setEntitlement(_ nextEntitlement: LavaSecurityPlusEntitlement) {
        guard entitlement != nextEntitlement else {
            return
        }

        entitlement = nextEntitlement
        entitlementChanged?(nextEntitlement)
    }

    private static func preferredEntitlement(
        _ current: LavaSecurityPlusEntitlement?,
        _ candidate: LavaSecurityPlusEntitlement
    ) -> LavaSecurityPlusEntitlement {
        guard let current else {
            return candidate
        }

        if current.expiresAt == nil {
            return current
        }

        guard let candidateExpiration = candidate.expiresAt else {
            return candidate
        }

        guard let currentExpiration = current.expiresAt else {
            return current
        }

        return candidateExpiration > currentExpiration ? candidate : current
    }
}
