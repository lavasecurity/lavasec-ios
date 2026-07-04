import Foundation
import LavaSecCore
import StoreKit

struct LavaSecurityPlusOffer: Identifiable {
    let plan: LavaSecurityPlusPlan
    let displayPrice: String
    let commitmentDisplayPrice: String?
    /// Whole-percent annual saving versus paying the monthly plan for 12 months,
    /// computed from the customer's own storefront prices. `nil` when it can't be
    /// derived from live StoreKit prices, or is too small to advertise — the pitch
    /// then stays qualitative instead of quoting a number that isn't true here.
    let savingsPercent: Int?
    let product: Product?

    var id: String {
        plan.id
    }

    var title: String {
        switch plan.kind {
        case .monthly:
            "Monthly".lavaLocalized
        case .yearly:
            "Yearly".lavaLocalized
        case .yearlyPaidMonthly:
            "Yearly, paid monthly".lavaLocalized
        }
    }

    var subtitle: String {
        switch plan.kind {
        case .monthly:
            "Flexible subscription".lavaLocalized
        case .yearly:
            "Best value".lavaLocalized
        case .yearlyPaidMonthly:
            "Lower monthly payment".lavaLocalized
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
            "Lava Security Plus is not available from the App Store yet. Try again later.".lavaLocalized
        case .unverifiedPurchase:
            "The App Store purchase could not be verified.".lavaLocalized
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
        offers = Self.fallbackOffers()
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
            let products = try await Product.products(for: LavaSecurityPlusPolicy.paywallProductIDs)
            let productsByID = Dictionary(uniqueKeysWithValues: products.map { ($0.id, $0) })
            offers = Self.offers(from: productsByID)
        } catch {
            offers = Self.fallbackOffers()
        }
    }

    @discardableResult
    func refreshEntitlements() async -> LavaSecurityPlusEntitlement {
        var bestEntitlement: LavaSecurityPlusEntitlement?

        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                  let entitlement = activeEntitlement(
                    from: transaction,
                    signedTransactionJWS: result.jwsRepresentation,
                    source: .currentEntitlements
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
        if offer.plan.kind == .yearlyPaidMonthly {
            if #available(iOS 26.4, *) {
                guard product.subscription?.pricingTerms.contains(where: {
                    $0.billingPlanType == .monthly
                }) == true else {
                    throw LavaSecurityPlusStoreError.productUnavailable
                }

                options.insert(.billingPlanType(.monthly))
            } else {
                throw LavaSecurityPlusStoreError.productUnavailable
            }
        }

        let result = try await product.purchase(options: options)
        switch result {
        case .success(let verificationResult):
            guard case .verified(let transaction) = verificationResult else {
                throw LavaSecurityPlusStoreError.unverifiedPurchase
            }

            guard let entitlement = activeEntitlement(
                from: transaction,
                signedTransactionJWS: verificationResult.jwsRepresentation,
                source: .purchase
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
            signedTransactionJWS: transactionResult.jwsRepresentation,
            source: .transactionUpdate
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

    /// Smallest annual saving (versus 12× the monthly price) we will advertise as
    /// a percentage. Below this — or when we can't read both prices from StoreKit —
    /// the yearly pitch drops the number, so a storefront whose App Store price
    /// tiers don't preserve the base-currency ratio never shows an inflated figure.
    static let minimumDisplayableSavingsPercent = 5

    private static func fallbackOffers() -> [LavaSecurityPlusOffer] {
        LavaSecurityPlusPolicy.fallbackOfferOrder.map {
            LavaSecurityPlusOffer(
                plan: $0,
                displayPrice: $0.fallbackDisplayPrice,
                commitmentDisplayPrice: nil,
                savingsPercent: nil,
                product: nil
            )
        }
    }

    private static func offers(from productsByID: [String: Product]) -> [LavaSecurityPlusOffer] {
        let savingsPercent = yearlySavingsPercent(
            yearly: productsByID[LavaSecurityPlusPolicy.yearly.productID],
            monthly: productsByID[LavaSecurityPlusPolicy.monthly.productID]
        )

        return LavaSecurityPlusPolicy.recommendedOfferOrder.compactMap { plan in
            guard plan.kind != .yearlyPaidMonthly else {
                return yearlyPaidMonthlyOffer(from: productsByID[plan.productID])
            }

            return LavaSecurityPlusOffer(
                plan: plan,
                displayPrice: productsByID[plan.productID]?.displayPrice ?? plan.fallbackDisplayPrice,
                commitmentDisplayPrice: nil,
                savingsPercent: plan.kind == .yearly ? savingsPercent : nil,
                product: productsByID[plan.productID]
            )
        }
    }

    /// Floor-rounded annual saving of the upfront yearly plan versus paying the
    /// monthly plan for a year, in the customer's storefront currency. Rounds down
    /// so we can only ever understate the saving, and returns `nil` unless both
    /// products loaded and the saving clears `minimumDisplayableSavingsPercent`.
    private static func yearlySavingsPercent(yearly: Product?, monthly: Product?) -> Int? {
        guard let yearly, let monthly else {
            return nil
        }

        let annualizedMonthly = monthly.price * 12
        guard annualizedMonthly > 0, yearly.price < annualizedMonthly else {
            return nil
        }

        // Keep the whole computation in Decimal space and floor via Int(truncating:) (truncates
        // toward zero, i.e. floors for the positive range here). Routing the fraction through Double
        // first — as `NSDecimalNumber(decimal:).doubleValue` did — can drop a clean integer point: an
        // exact Decimal 0.37 becomes the binary64 0.36999999999999996, so `* 100` is 36.999… and the
        // floor yields 36 instead of 37, understating the saving (or pushing a real 5% down to 4% and
        // below `minimumDisplayableSavingsPercent`, suppressing it entirely). StoreKit prices are
        // Decimal everywhere else in this type; this was the only Double round-trip. (#44 review)
        let percent = Int(truncating: NSDecimalNumber(
            decimal: (annualizedMonthly - yearly.price) * 100 / annualizedMonthly))
        guard percent >= minimumDisplayableSavingsPercent else {
            return nil
        }

        return percent
    }

    private static func yearlyPaidMonthlyOffer(from product: Product?) -> LavaSecurityPlusOffer? {
        guard let product else {
            return nil
        }

        if #available(iOS 26.4, *) {
            guard let subscription = product.subscription,
                  let commitmentPricingTerms = subscription.pricingTerms.first(where: {
                $0.billingPlanType == .monthly
            }) else {
                return nil
            }

            return LavaSecurityPlusOffer(
                plan: LavaSecurityPlusPolicy.yearlyPaidMonthly,
                displayPrice: commitmentPricingTerms.billingDisplayPrice,
                commitmentDisplayPrice: commitmentPricingTerms.commitmentInfo.price.formatted(
                    product.priceFormatStyle
                ),
                savingsPercent: nil,
                product: product
            )
        }

        return nil
    }

    // Where a candidate `Transaction` came from. `Transaction.currentEntitlements`
    // is StoreKit's own source of truth: it already drops truly-lapsed
    // subscriptions and, crucially, *keeps* ones inside the billing grace / retry
    // window — those carry a past `expirationDate` while still being entitled.
    // Self-expiring against that date would wrongly demote a grace-period
    // subscriber to Free (UX-3), so we trust StoreKit for that source and only
    // apply the local expiry compare to the other, non-authoritative sources.
    private enum EntitlementSource {
        case currentEntitlements
        case purchase
        case transactionUpdate

        var trustsStoreKitEntitlementWindow: Bool {
            switch self {
            case .currentEntitlements:
                true
            case .purchase, .transactionUpdate:
                false
            }
        }
    }

    private func activeEntitlement(
        from transaction: Transaction,
        signedTransactionJWS: String,
        source: EntitlementSource
    ) -> LavaSecurityPlusEntitlement? {
        guard LavaSecurityPlusPolicy.plan(for: transaction.productID) != nil else {
            return nil
        }

        guard transaction.revocationDate == nil else {
            return nil
        }

        if !source.trustsStoreKitEntitlementWindow,
           let expirationDate = transaction.expirationDate,
           expirationDate <= Date() {
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
