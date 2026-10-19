import Foundation
import LavaSecKit
import StoreKit
import UIKit

/// Native Plus display metadata and the system subscription-management action.
/// RN owns the sales screen, loading states, disclosures and purchase controls.
@MainActor
enum LavaPlusPresentation {
    static func displayedOffers(for plus: LavaSecurityPlusController) -> [LavaSecurityPlusOffer] {
        if !plus.lavaSecurityPlusOffers.isEmpty {
            return plus.lavaSecurityPlusOffers
        }

        return LavaSecurityPlusPolicy.fallbackOfferOrder.map {
            LavaSecurityPlusOffer(
                plan: $0,
                displayPrice: $0.fallbackDisplayPrice,
                commitmentDisplayPrice: nil,
                savingsPercent: nil,
                product: nil
            )
        }
    }

    // Quote savings only when StoreKit supplied a storefront-computed figure;
    // otherwise preserve the existing number-free localized pitch.
    static func planPitch(for offer: LavaSecurityPlusOffer) -> String {
        switch offer.plan.kind {
        case .yearly:
            if let savingsPercent = offer.savingsPercent {
                return "\"We are saving %d%%! This has the best value.\"".lavaLocalizedFormat(savingsPercent)
            }
            return "\"Paying by the year beats paying by the month.\"".lavaLocalized
        case .yearlyPaidMonthly:
            return "\"If we commit for 12 months, each month is cheaper.\"".lavaLocalized
        case .monthly:
            return "\"We already saved this by unplugging appliances.\"".lavaLocalized
        }
    }

    static func presentManageSubscriptions(plus: LavaSecurityPlusController) async {
        // Prefer Apple's in-app manage sheet; fall back to the App Store subscriptions
        // page when no foreground scene is available or the sheet can't present (e.g. the
        // Simulator, where showManageSubscriptions often no-ops).
        if let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) {
            do {
                try await AppStore.showManageSubscriptions(in: scene)
                await plus.refreshLavaSecurityPlusEntitlements()
                return
            } catch {
                // Fall through to the deep link below.
            }
        }

        if let url = URL(string: "https://apps.apple.com/account/subscriptions") {
            _ = await UIApplication.shared.open(url)
        }
    }
}
