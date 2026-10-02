import SwiftUI
import LavaSecKit
import StoreKit
import UIKit

/// Upgrade is a **sales surface**, intentionally exempt from the strict Settings-page anatomy
/// (it keeps its marketing layout) but still declaring its depth `tier`. The eyebrow +
/// `LavaInfoCard { UpgradePlanComparisonView() }` free-vs-paid table already plays the
/// orientation-panel role, so no separate `LavaInfoPanel` intro is added.
///
/// Documented divergences / improvement opportunities (deferred — keep the current sales
/// layout for now, per product):
///   - The nav title is `.navigationTitle("Lava Plus".lavaLocalized)` so every entry path (the
///     upgrade sheet, the DNS page, and the VPN-chaining page) shows the shortened product name
///     in every locale.
///   - The plan-pitch strings + the "…and a pitch for your parent" subtitle are jokey
///     marketing copy, now localized (pitch via .lavaLocalized; subtitle via a literal Text).
///     Swap in finalized marketing copy when ready.
struct UpgradeSettingsView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @EnvironmentObject private var plus: LavaSecurityPlusController
    @EnvironmentObject private var security: SecurityController

    var body: some View {
        SettingsSubpageContent(tier: .celebratory) {
            VStack(alignment: .leading, spacing: 10) {
                Text("More room for your rules")
                    .foregroundStyle(LavaStyle.lavaOrangeText)
                    .font(.title3.bold())

                LavaInfoCard {
                    UpgradePlanComparisonView()
                }
            }

            if viewModel.configuration.hasLavaSecurityPlus {
                UpgradeThankYouView()
                subscriberManagementSection
            } else if !plus.hasCheckedLavaSecurityPlusEntitlements
                || plus.isRefreshingLavaSecurityPlusEntitlements {
                UpgradeEntitlementCheckingView()
            } else {
                purchaseOptions
            }

            UpgradeLegalFooter(
                showsYearlyPaidMonthly: displayedOffers.contains { $0.plan.kind == .yearlyPaidMonthly }
            )

            if let message = plus.lavaSecurityPlusMessage {
                Text(message)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(plus.lavaSecurityPlusMessageIsError ? LavaStyle.errorText : LavaStyle.safeGreen)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .navigationTitle("Lava Plus".lavaLocalized)
        .navigationBarTitleDisplayMode(.large)
        .onAppear {
            plus.clearLavaSecurityPlusMessage()
        }
        .onDisappear {
            plus.clearLavaSecurityPlusMessage()
        }
        .task {
            // Check entitlements once per session — re-checking on every appear
            // flips the loading flag (flicker) and re-applies the entitlement,
            // which can churn the paid status. The displayed status is driven by
            // the persisted configuration, which stays truthful between checks.
            if !plus.hasCheckedLavaSecurityPlusEntitlements {
                await plus.refreshLavaSecurityPlusEntitlements()
            }
            if !viewModel.configuration.hasLavaSecurityPlus, plus.lavaSecurityPlusOffers.isEmpty {
                await plus.loadLavaSecurityPlusProducts()
            }
        }
    }

    private var purchaseOptions: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Choose a plan")
                    .font(.title3.bold())
                    .foregroundStyle(LavaStyle.ink)

                Text("... and a pitch for your parent")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(LavaStyle.secondaryText)
            }

            VStack(spacing: 10) {
                ForEach(displayedOffers) { offer in
                    Button {
                        purchase(offer)
                    } label: {
                        UpgradePlanOfferRow(
                            offer: offer,
                            pitch: planPitch(for: offer)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(plus.isPurchasingLavaSecurityPlus)
                }

                Text("or if you have already made a purchase")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(LavaStyle.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
                    .padding(.bottom, 2)

                Button {
                    restorePurchases()
                } label: {
                    SettingsActionRow(title: "Restore Purchase") {
                        if plus.isPurchasingLavaSecurityPlus {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise.circle")
                                .font(.title3.weight(.semibold))
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(plus.isPurchasingLavaSecurityPlus)
                .padding(16)
                .lavaSurface(.card, cornerRadius: LavaSurface.compactCornerRadius)
            }
        }
    }

    private var displayedOffers: [LavaSecurityPlusOffer] {
        Self.displayedOffers(for: plus)
    }

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

    // Returns the fully localized pitch. The yearly pitch quotes the saving only
    // when StoreKit gave us a real, storefront-computed figure (`offer.savingsPercent`);
    // otherwise it falls back to number-free copy so we never show a hard-coded
    // percentage that isn't true in the customer's currency.
    private func planPitch(for offer: LavaSecurityPlusOffer) -> String {
        Self.planPitch(for: offer)
    }

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

    private func performAppSettingsMutation(reason: String, action: @escaping @MainActor () async -> Void) {
        Task {
            guard await security.requireAuthentication(for: .appSettings, reason: reason) else {
                return
            }

            await action()
        }
    }

    private func purchase(_ offer: LavaSecurityPlusOffer) {
        performAppSettingsMutation(reason: "Upgrade to Lava Security Plus") {
            await plus.purchaseLavaSecurityPlus(offer)
        }
    }

    private func restorePurchases() {
        performAppSettingsMutation(reason: "Restore Lava Security Plus") {
            await plus.restoreLavaSecurityPlusPurchases()
        }
    }

    @ViewBuilder
    private var subscriberManagementSection: some View {
        LavaCondensedList {
            // Manage / cancel is shown to any Plus subscriber, gated on the DURABLE paid flag — NOT the
            // in-memory `lavaSecurityPlusExpiresAt`, which is nil until the first entitlement read
            // populates it and is not persisted across launches. Gating on the expiry hid this control on
            // a cold-launch transient-empty read that KEEPS Plus (EntitlementApplicationPolicy), leaving a
            // paying subscriber unable to manage their subscription until StoreKit warmed (Codex, PR #560).
            // Every plan is an auto-renewable subscription, so a Plus user can always manage.
            if viewModel.configuration.hasLavaSecurityPlus {
                Button {
                    manageSubscription()
                } label: {
                    SettingsActionRow(title: "Manage Subscription") {
                        Image(systemName: "creditcard.circle")
                            .font(.title3.weight(.semibold))
                    }
                    .lavaRow()
                }
                .buttonStyle(.plain)
                .disabled(plus.isPurchasingLavaSecurityPlus)

                LavaCondensedDivider()
            }

            // Restore — relevant for any plan after a reinstall or device switch.
            Button {
                restorePurchases()
            } label: {
                SettingsActionRow(title: "Restore Purchase") {
                    if plus.isPurchasingLavaSecurityPlus {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise.circle")
                            .font(.title3.weight(.semibold))
                    }
                }
                .lavaRow()
            }
            .buttonStyle(.plain)
            .disabled(plus.isPurchasingLavaSecurityPlus)
        }
    }

    private func manageSubscription() {
        performAppSettingsMutation(reason: "Manage Lava Security Plus") {
            await Self.presentManageSubscriptions(plus: plus)
        }
    }

    @MainActor
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

/// Guideline 3.1.2 disclosure: auto-renew terms + functional Terms (EULA) and
/// Privacy Policy links, shown on the paywall wherever subscriptions are offered.
private struct UpgradeLegalFooter: View {
    /// Whether the "Yearly, paid monthly" plan is actually offered on this paywall. That plan is the
    /// only one carrying a 12-month commitment, and it appears only when its `.monthly` billing plan
    /// is configured in App Store Connect (and on iOS 26.4+). When it isn't shown, we drop the
    /// commitment sentence so the disclosure never describes a plan the customer can't see.
    let showsYearlyPaidMonthly: Bool

    var body: some View {
        VStack(spacing: 8) {
            Text(disclosureText)
                .lavaQuietNoteText()
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { termsLink; privacyLink }
                VStack(spacing: 0) { termsLink; privacyLink }
            }
            .font(.footnote.weight(.semibold))
            .tint(LavaStyle.safeGreen)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }

    private var termsLink: some View {
        Link(destination: LavaWebLinks.terms) {
            Text("Terms of Use").frame(minHeight: 44).contentShape(Rectangle())
        }
    }

    private var privacyLink: some View {
        Link(destination: LavaWebLinks.privacy) {
            Text("Privacy Policy").frame(minHeight: 44).contentShape(Rectangle())
        }
    }

    // Two fully-localized variants: the with-commitment paragraph is used only when the
    // yearly-paid-monthly plan is on the paywall; otherwise the shorter sibling drops the
    // "12-month commitment" sentence. Both are string-literal keys so SwiftUI localizes them from
    // Localizable.xcstrings.
    private var disclosureText: LocalizedStringKey {
        if showsYearlyPaidMonthly {
            return "Monthly and yearly plans auto-renew. Yearly paid monthly is billed monthly on a 12-month commitment; after that, cancelling affects the next renewal per App Store terms. Payment is charged to your Apple Account at purchase and renews unless turned off at least 24 hours before the period ends. Manage or cancel in Apple Account settings."
        }

        return "Monthly and yearly plans auto-renew. Payment is charged to your Apple Account at purchase and renews unless turned off at least 24 hours before the period ends. Manage or cancel in Apple Account settings."
    }
}

private struct UpgradeThankYouView: View {
    @EnvironmentObject private var plus: LavaSecurityPlusController
    @EnvironmentObject private var customization: CustomizationController

    var body: some View {
        LavaPlainCard {
            VStack(spacing: 14) {
                GuardianThankYouAnimation(size: 96, shieldStyle: customization.lavaGuardLook)

                VStack(spacing: 6) {
                    Text("Thank you for your support")
                        .font(.title3.bold())
                        .foregroundStyle(LavaStyle.ink)
                        .multilineTextAlignment(.center)

                    Text("Lava Security Plus is active")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(LavaStyle.secondaryText)
                        .multilineTextAlignment(.center)

                    if let expiresAt = plus.lavaSecurityPlusExpiresAt {
                        Text("Expiration: %@".lavaLocalizedFormat(expiresAt.formatted(date: .abbreviated, time: .omitted)))
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(LavaStyle.secondaryText)
                            .multilineTextAlignment(.center)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
    }
}

private struct UpgradeEntitlementCheckingView: View {
    var body: some View {
        LavaPlainCard {
            VStack(spacing: 14) {
                ProgressView()
                    .controlSize(.large)
                    .tint(LavaStyle.safeGreen)

                Text("Checking Lava Security Plus")
                    .font(.headline)
                    .foregroundStyle(LavaStyle.ink)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
        }
    }
}

struct LavaPlusUpgradeDestination: View {
    var body: some View {
        UpgradeSettingsView()
    }
}

private enum UpgradePlanComparisonValue: Equatable {
    case text(String)
    case unlocked
}

private struct UpgradePlanComparisonView: View {
    private let differences: [(title: String, free: String?, paid: UpgradePlanComparisonValue)] = [
        ("Filters", "\(FeatureLimits.free.maxFilters)", .text("\(FeatureLimits.paid.maxFilters)")),
        ("All filter rules", AppViewModel.abbreviatedRuleCount(FeatureLimits.free.maxFilterRules), .text(AppViewModel.abbreviatedRuleCount(FeatureLimits.paid.maxFilterRules))),
        ("Allowed domains", "\(FeatureLimits.free.maxAllowedDomains)", .text("\(FeatureLimits.paid.maxAllowedDomains)")),
        ("Blocked domains", "\(FeatureLimits.free.maxBlockedDomains)", .text("\(FeatureLimits.paid.maxBlockedDomains)")),
        ("All Lava Guards", nil, .unlocked),
        ("Family Sharing", nil, .unlocked),
        ("Custom blocklists", nil, .unlocked),
        ("Custom DNS", nil, .unlocked)
    ]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(differences.indices, id: \.self) { index in
                let row = differences[index]
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        comparisonTitle(row.title)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        comparisonValues(free: row.free, paid: row.paid)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        comparisonTitle(row.title)

                        comparisonValues(free: row.free, paid: row.paid)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
                .font(.body.weight(.bold))
                .monospacedDigit()
                .padding(.vertical, 12)

                if index + 1 < differences.count {
                    Divider()
                }
            }
        }
        // First/last rows otherwise pick up the card inset (16) + row padding (12) = 28 at the
        // top/bottom edges vs 24 between rows; pull the stack 4pt into the card inset so every
        // vertical gap reads as 24 — consistent with the inter-row rhythm.
        .padding(.vertical, -4)
    }

    private func comparisonTitle(_ title: String) -> some View {
        Text(title.lavaLocalized)
            .foregroundStyle(LavaStyle.ink)
            .lineLimit(1)
            .minimumScaleFactor(0.82)
    }

    private func comparisonValues(free: String?, paid: UpgradePlanComparisonValue) -> some View {
        HStack(spacing: 6) {
            if let free {
                Text(free)
                    .foregroundStyle(LavaStyle.secondaryText)
                Text("→")
                    .foregroundStyle(LavaStyle.secondaryText)
            }
            paidValue(paid)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.78)
        .fixedSize(horizontal: true, vertical: false)
        .layoutPriority(1)
    }

    @ViewBuilder
    private func paidValue(_ value: UpgradePlanComparisonValue) -> some View {
        switch value {
        case .text(let text):
            Text(text)
                .foregroundStyle(LavaStyle.safeGreen)
        case .unlocked:
            Text("Unlocked")
                .foregroundStyle(LavaStyle.safeGreen)
        }
    }
}

private struct UpgradePlanOfferRow: View {
    let offer: LavaSecurityPlusOffer
    let pitch: String

    var body: some View {
        LavaPlainCard {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(offer.title.lavaLocalized)
                        .font(.headline)
                        .foregroundStyle(LavaStyle.ink)

                    Text(pitch)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(LavaStyle.secondaryText)
                        .lineLimit(2)
                        .minimumScaleFactor(0.88)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .trailing, spacing: 3) {
                    Text(offer.displayPrice)
                        .font(.headline.weight(.bold))
                        .foregroundStyle(LavaStyle.safeGreen)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)

                    if offer.plan.kind == .yearlyPaidMonthly,
                       let commitmentDisplayPrice = offer.commitmentDisplayPrice {
                        Text("%@ total".lavaLocalizedFormat(commitmentDisplayPrice))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(LavaStyle.secondaryText)
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.78)
                    }
                }
                .layoutPriority(1)
            }
        }
    }
}
