import Foundation
import LavaSecKit
import SwiftUI

// The customization-preferences feature, peeled out of AppViewModel (Phase D5,
// lavasec-infra plans/2026-07-07-ios-modularization-scaffolding-plan.md): the
// appearance / text-size / LavaGuard-look / app-icon / Live-Activities / haptics-toggle
// preference cluster, its UserDefaults persistence, the Customization → Notifications
// per-category toggle mirrors, and the launch-time preference load. The hub
// (AppViewModel) remains the owner of the configuration (Plus flag, unlock ledger,
// keep-progress flag), the LavaGuard PROGRESS accrual engine and its @Published value,
// the Live Activity reconcile machinery (it reads VPN status + pause state), and the
// protection-outcome haptic PLAY path — this controller reaches those only through the
// narrow `CustomizationHubBridging` surface below, mirroring the scoped-controller
// pattern of BackupController / LavaSecurityPlusController / AccountController /
// DiagnosticsController. Haptics-placement judgement (Phase D5): the play helpers
// (`playProtectionOnSucceededHapticIfNeeded` / `playProtectionStartFailedHaptic`) and
// their `awaitsProtectionOnHaptic` arm stay hub-side — they are driven entirely by the
// hub's VPN-status observation, and the ONLY customization coupling is the shared
// `ProtectionHapticFeedback.preferenceDefaultsKeyName` this controller's toggle writes and
// the enum's `play` choke point reads, so no bridge member is needed for playback.

// LavaAppearancePreference / LavaTextSize / LavaGuardAvailability moved here verbatim
// from AppViewModel.swift with the Phase D5 peel (customization-only models; they stay
// app-target because they lean on SwiftUI types — ColorScheme / DynamicTypeSize — that
// the SwiftUI-free LavaSecAppServices layer deliberately does not import).

enum LavaAppearancePreference: String, CaseIterable, Identifiable {
    case light
    case dark
    case system

    var id: Self {
        self
    }

    var displayName: String {
        switch self {
        case .light:
            "Light"
        case .dark:
            "Dark"
        case .system:
            "System"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .light:
            .light
        case .dark:
            .dark
        case .system:
            nil
        }
    }
}

/// In-app Dynamic Type override for the Customization → Text Size control. Covers the seven
/// standard content sizes (the same range as iOS Settings → Display & Brightness → Text Size).
/// Larger accessibility sizes stay reachable through the system's Larger Text setting, which the
/// app respects whenever "Match System" is on — so this control never has to reproduce them.
enum LavaTextSize: String, CaseIterable, Identifiable {
    case xSmall
    case small
    case medium
    case large
    case xLarge
    case xxLarge
    case xxxLarge

    var id: Self {
        self
    }

    /// Matches the system's out-of-the-box Dynamic Type size, so turning "Match System" off does
    /// not jump the text until the user actually moves the slider.
    static let systemDefault: LavaTextSize = .large

    var dynamicTypeSize: DynamicTypeSize {
        switch self {
        case .xSmall:
            .xSmall
        case .small:
            .small
        case .medium:
            .medium
        case .large:
            .large
        case .xLarge:
            .xLarge
        case .xxLarge:
            .xxLarge
        case .xxxLarge:
            .xxxLarge
        }
    }

    /// A short, localized name for the size, announced to VoiceOver as the Text Size slider's value
    /// so a non-sighted user knows which size they've chosen (the slider is otherwise just a 0–6
    /// numeric position). Rendered via `.lavaLocalized` at the call site, like the appearance names.
    var displayName: String {
        switch self {
        case .xSmall:
            "Extra Small"
        case .small:
            "Small"
        case .medium:
            "Medium"
        case .large:
            "Large"
        case .xLarge:
            "Extra Large"
        case .xxLarge:
            "Extra Extra Large"
        case .xxxLarge:
            "Largest"
        }
    }

    /// The in-app size closest to a system `DynamicTypeSize`, clamping the larger accessibility
    /// sizes (which this control does not expose) down to the largest in-range size. Used to seed
    /// the slider from the current system size the first time "Match System" is turned off, so
    /// nothing jumps for users whose iOS text size isn't the default.
    static func matching(_ dynamicTypeSize: DynamicTypeSize) -> LavaTextSize {
        switch dynamicTypeSize {
        case .xSmall:
            .xSmall
        case .small:
            .small
        case .medium:
            .medium
        case .large:
            .large
        case .xLarge:
            .xLarge
        case .xxLarge:
            .xxLarge
        case .xxxLarge:
            .xxxLarge
        default:
            .xxxLarge
        }
    }
}

struct LavaGuardAvailability: Equatable {
    let isSelectable: Bool
    let isRevealed: Bool
    let progress: LavaGuardGoalProgress?
    let isProgressEnabled: Bool
    let showsProgressDetail: Bool
}

/// The narrow hub surface the customization controller depends on (Phase D5). Everything
/// the customization cluster needs from AppViewModel and nothing else, so the hub stays
/// the owner of the shared state:
///
/// - **Configuration reads**: `hasLavaSecurityPlus` (re-declared with
///   LavaSecurityPlusHubBridging's exact signature, so the hub's one existing conformance
///   member witnesses both bridges), `lavaGuardUnlocks`, and `keepsLavaGuardProgress`
///   feed the LavaGuard availability policy — the ledger and keep-flag live on the
///   hub-owned configuration, and the PROGRESS accrual engine that writes them never
///   leaves the hub.
/// - **LavaGuard progress read**: `lavaGuardProgress` is the hub's @Published progress
///   value (written by the hub's usage accrual + diagnostics refresh); availability rows
///   only ever read it.
/// - **Live Activity seam**: `canOfferLiveActivities` is the hub's device-class gate
///   (it owns the AmbientProtectionPresenter), and `reconcileLiveActivity()` republishes
///   the activity after a look / toggle / pause-length change — the reconcile machinery
///   stays hub-side because it reads VPN status and pause state.
/// - **Notification permission**: `requestNotificationAuthorization()` reaches the
///   hub-owned ProtectionUserNotificationController for the contextual permission
///   request when a Customization → Notifications toggle is enabled.
@MainActor
protocol CustomizationHubBridging: AnyObject {
    var hasLavaSecurityPlus: Bool { get }
    var lavaGuardUnlocks: LavaGuardAchievementLedger { get }
    var keepsLavaGuardProgress: Bool { get }
    var lavaGuardProgress: LavaGuardProgress { get }
    var canOfferLiveActivities: Bool { get }
    func reconcileLiveActivity()
    @discardableResult func requestNotificationAuthorization() async -> Bool
}

@MainActor
final class CustomizationController: ObservableObject {
    @Published private(set) var appearancePreference: LavaAppearancePreference = .system
    @Published private(set) var textSizeMatchesSystem: Bool = true
    @Published private(set) var textSize: LavaTextSize = .systemDefault
    @Published private(set) var lavaGuardLook: GuardianShieldStyle = .original
    @Published private(set) var updatesAppIconWithLavaGuard = true
    @Published private(set) var usesLiveActivities = false
    @Published private(set) var liveActivityPauseMinutes = LiveActivityPausePreference.defaultMinutes
    @Published private(set) var usesLavaHaptics = true
    /// Customization → Notifications per-category toggles. SwiftUI-bindable mirrors of the cross-process
    /// app-group store (`LavaNotificationPreferences`) the extension + tunnel read; default ON.
    @Published private(set) var notifiesFilterChanges = true
    @Published private(set) var notifiesFilterCouldNotApply = true
    @Published private(set) var notifiesProtectionResumed = true
    @Published private(set) var notifiesConnectivity = true

    private let appearancePreferenceDefaultsKeyName = "lavasec.customization.appearance"
    private let textSizeMatchesSystemDefaultsKeyName = "lavasec.customization.textSizeMatchesSystem"
    private let textSizeDefaultsKeyName = "lavasec.customization.textSize"
    private let lavaGuardLookDefaultsKey = LavaSecAppGroup.customizationLavaGuardLookDefaultsKeyName
    private let updatesAppIconWithLavaGuardDefaultsKeyName = "lavasec.customization.updatesAppIconWithLavaGuard"
    private let usesLiveActivitiesDefaultsKeyName = "lavasec.customization.liveActivities"
    private let usesLavaHapticsDefaultsKey = ProtectionHapticFeedback.preferenceDefaultsKeyName
    // Same stores the hub keeps for ITS preference reads/writes — both resolve to the
    // process-wide singletons (UserDefaults.standard / the shared app-group suite), so
    // the moved bodies persist to the exact pre-peel locations.
    private let defaults = UserDefaults.standard
    private let appGroupDefaults = LavaSecAppGroup.sharedDefaults
    private let iconPersonalizer: IconPersonalizing = UIKitIconPersonalizer()

    // The hub outlives this controller (AppViewModel owns it strongly), so an unowned
    // back-reference avoids a retain cycle without weak-optional noise on every call.
    private unowned let hub: any CustomizationHubBridging

    init(hub: any CustomizationHubBridging) {
        self.hub = hub
    }

    // MARK: - Derived presentation

    var customizationSummaryText: String {
        let appearance = appearancePreference.displayName.lavaLocalized
        guard canOfferLiveActivities else {
            return appearance
        }

        return usesLiveActivities
            ? "%@, Live Activities on".lavaLocalizedFormat(appearance)
            : "%@, Live Activities off".lavaLocalizedFormat(appearance)
    }

    var canOfferLiveActivities: Bool {
        hub.canOfferLiveActivities
    }

    var preferredColorScheme: ColorScheme? {
        appearancePreference.colorScheme
    }

    // MARK: - Customization preferences (appearance, LavaGuard look, icon, haptics)

    func setAppearancePreference(_ preference: LavaAppearancePreference) {
        guard appearancePreference != preference else {
            return
        }

        appearancePreference = preference
        defaults.set(preference.rawValue, forKey: appearancePreferenceDefaultsKeyName)
    }

    /// The Dynamic Type size to force app-wide, or `nil` to follow the system (the default).
    /// `RootView` applies this only when it is non-nil, so "Match System" leaves the system's
    /// Larger Text setting fully in charge.
    var textSizeOverride: DynamicTypeSize? {
        textSizeMatchesSystem ? nil : textSize.dynamicTypeSize
    }

    /// Toggles "Match System". `systemTextSize` is the app's *current* system Dynamic Type size
    /// (read from the environment at the call site): the first time Match System is turned off with
    /// no saved Lava-specific size, the slider is seeded from it so the app doesn't jump before the
    /// user has chosen a size. A previously-saved Lava size always wins over the seed.
    func setTextSizeMatchesSystem(_ matchesSystem: Bool, seedingFrom systemTextSize: LavaTextSize) {
        guard textSizeMatchesSystem != matchesSystem else {
            return
        }

        if !matchesSystem, defaults.object(forKey: textSizeDefaultsKeyName) == nil {
            textSize = systemTextSize
            defaults.set(systemTextSize.rawValue, forKey: textSizeDefaultsKeyName)
        }

        textSizeMatchesSystem = matchesSystem
        defaults.set(matchesSystem, forKey: textSizeMatchesSystemDefaultsKeyName)
    }

    func setTextSize(_ size: LavaTextSize) {
        guard textSize != size else {
            return
        }

        textSize = size
        defaults.set(size.rawValue, forKey: textSizeDefaultsKeyName)
    }

    func setLavaGuardLook(_ look: GuardianShieldStyle) {
        guard isLavaGuardLookSelectable(look) else {
            return
        }

        guard lavaGuardLook != look else {
            persistLavaGuardLook(look)
            syncAppIcon(to: look)
            hub.reconcileLiveActivity()
            return
        }

        lavaGuardLook = look
        persistLavaGuardLook(look)
        syncAppIcon(to: look)
        hub.reconcileLiveActivity()
    }

    func lavaGuardAvailability(for look: GuardianShieldStyle) -> LavaGuardAvailability {
        let isSelectable = LavaGuardAvailabilityPolicy.isAvailable(
            guardID: look.lavaGuardID,
            isOriginal: look == .original,
            hasLavaSecurityPlus: hub.hasLavaSecurityPlus,
            ledger: hub.lavaGuardUnlocks,
            courtesyGuardID: lavaGuardLook.lavaGuardID
        )
        let showsProgressDetail = look.lavaGuardID == nextLavaGuardProgressDetailGuardID

        return LavaGuardAvailability(
            isSelectable: isSelectable,
            isRevealed: isSelectable,
            progress: hub.lavaGuardProgress.progress(
                for: look.lavaGuardID,
                ledger: hub.lavaGuardUnlocks
            ),
            isProgressEnabled: hub.keepsLavaGuardProgress,
            showsProgressDetail: showsProgressDetail
        )
    }

    private var nextLavaGuardProgressDetailGuardID: String? {
        guard hub.keepsLavaGuardProgress else {
            return nil
        }

        for goal in LavaGuardProgressPolicy.unlockGoals {
            let isAvailable = LavaGuardAvailabilityPolicy.isAvailable(
                guardID: goal.guardID,
                isOriginal: false,
                hasLavaSecurityPlus: hub.hasLavaSecurityPlus,
                ledger: hub.lavaGuardUnlocks,
                courtesyGuardID: lavaGuardLook.lavaGuardID
            )
            if !isAvailable {
                return goal.guardID
            }
        }

        return nil
    }

    private func isLavaGuardLookSelectable(_ look: GuardianShieldStyle) -> Bool {
        lavaGuardAvailability(for: look).isSelectable
    }

    func setUpdatesAppIconWithLavaGuard(_ isEnabled: Bool) {
        guard updatesAppIconWithLavaGuard != isEnabled else {
            syncAppIcon(to: lavaGuardLook)
            return
        }

        updatesAppIconWithLavaGuard = isEnabled
        defaults.set(isEnabled, forKey: updatesAppIconWithLavaGuardDefaultsKeyName)
        syncAppIcon(to: lavaGuardLook)
    }

    private func persistLavaGuardLook(_ look: GuardianShieldStyle) {
        defaults.set(look.rawValue, forKey: lavaGuardLookDefaultsKey)
        appGroupDefaults.set(look.rawValue, forKey: lavaGuardLookDefaultsKey)
    }

    private func syncAppIcon(to look: GuardianShieldStyle) {
        guard iconPersonalizer.supportsAppIconPersonalization else {
            return
        }

        let targetIconName = updatesAppIconWithLavaGuard ? look.alternateAppIconName : nil
        guard iconPersonalizer.currentAppIconName != targetIconName else {
            return
        }

        Task {
            do {
                try await iconPersonalizer.setAppIcon(targetIconName)
            } catch {
                #if DEBUG || LAVA_QA_TOOLS
                LavaSecDeviceDebugLog.append(component: "app", event: "app-icon-switch-failed", details: [
                    "error": error.localizedDescription
                ])
                #endif
            }
        }
    }

    func setUsesLiveActivities(_ isEnabled: Bool) {
        let canEnableLiveActivities = canOfferLiveActivities && isEnabled

        guard usesLiveActivities != canEnableLiveActivities else {
            return
        }

        usesLiveActivities = canEnableLiveActivities
        defaults.set(canEnableLiveActivities, forKey: usesLiveActivitiesDefaultsKeyName)
        hub.reconcileLiveActivity()
    }

    /// User-facing label for the Live Activity pause-length stepper, e.g.
    /// "Pause length: 5 min".
    var liveActivityPauseLengthLabel: String {
        "Pause length: %d min".lavaLocalizedFormat(liveActivityPauseMinutes)
    }

    func setLiveActivityPauseMinutes(_ minutes: Int) {
        let clampedMinutes = LiveActivityPausePreference.clamp(minutes)
        guard liveActivityPauseMinutes != clampedMinutes else {
            return
        }

        liveActivityPauseMinutes = clampedMinutes
        // Persisted in the app-group defaults so the widget button label and the
        // pause intent (both out of process) resolve the same length.
        LiveActivityPausePreference.setMinutes(
            clampedMinutes,
            in: ProtectionUserDefaultsStorage(defaults: appGroupDefaults)
        )
        hub.reconcileLiveActivity()
    }

    func setUsesLavaHaptics(_ isEnabled: Bool) {
        guard usesLavaHaptics != isEnabled else {
            return
        }

        usesLavaHaptics = isEnabled
        defaults.set(isEnabled, forKey: usesLavaHapticsDefaultsKey)

        // Play a sample tap when turning haptics on so the user feels what they just
        // enabled. Turning off stays silent — `play` is already gated by the new value.
        if isEnabled {
            ProtectionHapticFeedback.play(.selectionConfirmed)
        }
    }

    // MARK: - Preference load & notification toggles

    // Internal (not private) since the Phase D5 peel: the hub's non-headless init calls
    // it, in the exact pre-peel slot, so the launch-time side effects (persistLavaGuardLook
    // backfill, syncAppIcon, the Live-Activities capability clamp) still never run on the
    // HEADLESS background-refresh instances.
    func loadCustomizationPreferences() {
        if let rawValue = defaults.string(forKey: appearancePreferenceDefaultsKeyName),
           let preference = LavaAppearancePreference(rawValue: rawValue) {
            appearancePreference = preference
        } else {
            appearancePreference = .system
        }

        if defaults.object(forKey: textSizeMatchesSystemDefaultsKeyName) != nil {
            textSizeMatchesSystem = defaults.bool(forKey: textSizeMatchesSystemDefaultsKeyName)
        } else {
            textSizeMatchesSystem = true
        }

        if let rawValue = defaults.string(forKey: textSizeDefaultsKeyName),
           let size = LavaTextSize(rawValue: rawValue) {
            textSize = size
        } else {
            textSize = .systemDefault
        }

        if let rawValue = defaults.string(forKey: lavaGuardLookDefaultsKey)
            ?? appGroupDefaults.string(forKey: lavaGuardLookDefaultsKey),
           let look = GuardianShieldStyle(rawValue: rawValue) {
            lavaGuardLook = look
            persistLavaGuardLook(look)
        } else {
            lavaGuardLook = .original
            persistLavaGuardLook(.original)
        }

        updatesAppIconWithLavaGuard = defaults.object(forKey: updatesAppIconWithLavaGuardDefaultsKeyName) as? Bool ?? true
        if !updatesAppIconWithLavaGuard {
            syncAppIcon(to: lavaGuardLook)
        }

        let persistedUsesLiveActivities = defaults.object(forKey: usesLiveActivitiesDefaultsKeyName) as? Bool ?? false
        usesLiveActivities = canOfferLiveActivities && persistedUsesLiveActivities
        if !canOfferLiveActivities {
            defaults.set(false, forKey: usesLiveActivitiesDefaultsKeyName)
        }

        liveActivityPauseMinutes = LiveActivityPausePreference.minutes(
            from: ProtectionUserDefaultsStorage(defaults: appGroupDefaults)
        )

        usesLavaHaptics = defaults.object(forKey: usesLavaHapticsDefaultsKey) as? Bool ?? true

        // Notification toggles live in the SHARED app-group defaults (the extension + tunnel read them);
        // mirror them into the @Published properties for the Customization → Notifications section.
        notifiesFilterChanges = LavaNotificationPreferences.isEnabled(.filterChanged, in: appGroupDefaults)
        notifiesFilterCouldNotApply = LavaNotificationPreferences.isEnabled(.filterCouldNotApply, in: appGroupDefaults)
        notifiesProtectionResumed = LavaNotificationPreferences.isEnabled(.protectionResumed, in: appGroupDefaults)
        notifiesConnectivity = LavaNotificationPreferences.isEnabled(.connectivity, in: appGroupDefaults)
    }

    /// Set a Customization → Notifications category toggle: persist to the shared app-group store (so the
    /// extension + tunnel see it), update the @Published mirror, and — when ENABLING — request notification
    /// permission contextually (the user just asked for this kind of alert), mirroring onboarding's request.
    func setNotificationCategoryEnabled(_ category: LavaNotificationCategory, _ enabled: Bool) {
        LavaNotificationPreferences.setEnabled(enabled, for: category, in: appGroupDefaults)
        switch category {
        case .filterChanged: notifiesFilterChanges = enabled
        case .filterCouldNotApply: notifiesFilterCouldNotApply = enabled
        case .protectionResumed: notifiesProtectionResumed = enabled
        case .connectivity: notifiesConnectivity = enabled
        }
        if enabled {
            // Strong local so the fire-and-forget permission request keeps the hub alive
            // exactly as the pre-peel `Task { _ = await protectionUserNotifications.… }`
            // (self = the hub) did.
            let hub = self.hub
            Task { _ = await hub.requestNotificationAuthorization() }
        }
    }
}

// Used by the LavaGuard availability policy calls above; moved with them from
// AppViewModel.swift (Phase D5), where it was the same private extension.
private extension GuardianShieldStyle {
    var lavaGuardID: String {
        rawValue
    }
}
