import SwiftUI
import LavaSecKit

// Shared Guard catalog presentation used by the RN bridge.
extension LavaGuardAvailability {
    func title(for look: GuardianShieldStyle) -> String {
        guard !isRevealed else {
            return look.displayName
        }

        if let progress {
            return "Use Lava %d days".lavaLocalizedFormat(progress.requiredUsageDays)
        }

        return "Keep using Lava"
    }

    func subtitle(for look: GuardianShieldStyle) -> String? {
        guard !isRevealed else {
            return look.settingsDescription
        }

        guard isProgressEnabled else {
            return "Progress is off in Privacy & Data"
        }

        guard let progress else {
            return "Keep Lava protecting you to unlock this Guard."
        }

        guard showsProgressDetail else {
            return nil
        }

        let currentDays = min(progress.currentUsageDays, progress.requiredUsageDays)
        return "Currently at: %d days".lavaLocalizedFormat(currentDays)
    }

    func titleColor(for look: GuardianShieldStyle) -> Color {
        isRevealed ? look.dynamicIslandStatusGlyphColor : LavaStyle.ink
    }
}

extension GuardianShieldStyle {
    var settingsDescription: String {
        switch self {
        case .original:
            "A Lava a day keeps bad domains away."
        case .fireOpal:
            "Always check the link first."
        case .purpleObsidian:
            "Block it once. Browse in peace."
        case .obsidian:
            "Sign in where you meant to sign in."
        case .cherryQuartz:
            "Giveaways should not ask for secrets."
        case .emerald:
            "Make me your web-surfing buddy!"
        case .kiwiCreme:
            "Hey I'm no rock but I take security paw-sonally. U know what I mean?"
        case .aquamarine:
            "Something phishy? Swim away."
        }
    }

    /// A bite-sized, layman tip that unpacks the Guard's quote (`settingsDescription`) into one
    /// concrete safety habit. Shown under the quote in the picker's spotlight panel. Catalog-only
    /// (localized at the display site via `.lavaLocalized`); keep each in sync with its quote.
    var settingsTip: String {
        switch self {
        case .original:
            "Lava quietly blocks domains known for scams and malware, so most threats never load."
        case .fireOpal:
            "A link can show one name but open another. Check where it really goes before you tap."
        case .purpleObsidian:
            "Switch on a blocklist once and Lava keeps catching those domains for you."
        case .obsidian:
            "Some fake sites copy a real login page to steal your password. Open the app or type the address yourself."
        case .cherryQuartz:
            "A real prize never needs your password or a one-time code. If it asks, it's a scam."
        case .emerald:
            "Keep Lava on while you browse and it watches for risky domains in the background."
        case .kiwiCreme:
            "Small habits help: pause before you tap, and let Lava handle the domains you should skip."
        case .aquamarine:
            "If a message rushes you to click, pause. Open the official app or website yourself."
        }
    }
}
