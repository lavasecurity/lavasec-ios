import Foundation

public enum LavaSecurityPlusPlanKind: String, CaseIterable, Codable, Sendable {
    case monthly
    case yearly
}

public struct LavaSecurityPlusPlan: Equatable, Codable, Identifiable, Sendable {
    public let kind: LavaSecurityPlusPlanKind
    public let productID: String
    public let displayName: String
    public let fallbackDisplayPrice: String
    public let isSubscription: Bool

    public init(
        kind: LavaSecurityPlusPlanKind,
        productID: String,
        displayName: String,
        fallbackDisplayPrice: String,
        isSubscription: Bool
    ) {
        self.kind = kind
        self.productID = productID
        self.displayName = displayName
        self.fallbackDisplayPrice = fallbackDisplayPrice
        self.isSubscription = isSubscription
    }

    public var id: String {
        productID
    }
}

public enum LavaSecurityPlusPolicy {
    public static let monthly = LavaSecurityPlusPlan(
        kind: .monthly,
        productID: "lava_security_plus_monthly",
        displayName: "Monthly",
        fallbackDisplayPrice: "$3.99/month",
        isSubscription: true
    )

    public static let yearly = LavaSecurityPlusPlan(
        kind: .yearly,
        productID: "lava_security_plus_yearly",
        displayName: "Yearly",
        fallbackDisplayPrice: "$29.99/year",
        isSubscription: true
    )

    public static let recommendedOfferOrder = [
        yearly,
        monthly
    ]

    public static let productIDs = [
        monthly.productID,
        yearly.productID
    ]

    public static func plan(for productID: String) -> LavaSecurityPlusPlan? {
        recommendedOfferOrder.first { $0.productID == productID }
    }
}
