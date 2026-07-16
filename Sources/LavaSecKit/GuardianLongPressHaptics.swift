import Foundation

/// Discrete strength level for one pulse of the Guard long-press "charge" ramp.
///
/// The ramp escalates through these levels so the hold *feels* like it is building. The
/// lightest level is the floor: it is calibrated to match the guardian-tap's light impact
/// (`ProtectionHapticFeedback.guardianTapAcknowledged`), so the ramp starts from the same
/// feedback the user already knows from tapping Lava Guard, then climbs from there.
public enum GuardianLongPressHapticLevel: Int, CaseIterable, Comparable, Sendable {
    case light
    case medium
    case heavy

    /// Orders levels by ascending strength (`light < medium < heavy`).
    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// One pulse of the long-press ramp: a strength level and a 0…1 impact intensity.
public struct GuardianLongPressHapticStep: Equatable, Sendable {
    /// The escalating strength band for this pulse.
    public let level: GuardianLongPressHapticLevel
    /// The impact intensity (0…1) applied within `level`.
    public let intensity: Double

    /// Creates a pulse from a strength level and intensity.
    ///
    /// `intensity` must be in `0...1`: it is forwarded verbatim to
    /// `UIImpactFeedbackGenerator.impactOccurred(intensity:)`, whose own contract is 0…1, so the
    /// precondition localizes a contract violation to the point of construction rather than a silent
    /// or clamped UIKit haptic at the call site (OCR review on the 1.2.4 sync).
    public init(level: GuardianLongPressHapticLevel, intensity: Double) {
        precondition(
            intensity >= 0 && intensity <= 1,
            "GuardianLongPressHapticStep.intensity must be in 0...1, got \(intensity)"
        )
        self.level = level
        self.intensity = intensity
    }
}

/// One scheduled pulse of the ramp: when it fires (seconds from press-start) and what to play.
public struct GuardianLongPressHapticPulse: Equatable, Sendable {
    /// Seconds from press-start at which this pulse fires.
    public let delay: TimeInterval
    /// The impact to play at `delay`.
    public let step: GuardianLongPressHapticStep

    /// Creates a scheduled pulse from a fire delay and a step.
    public init(delay: TimeInterval, step: GuardianLongPressHapticStep) {
        self.delay = delay
        self.step = step
    }
}

/// Pure description of the Guard long-press gesture that reveals the Lava Guard picker.
///
/// The gesture is a `holdDuration` press whose haptic feedback "balloons up": each pulse lands
/// harder than the last, and the pulses cluster toward the end so the buildup *accelerates* into
/// the reveal. This type owns the curve — the strength of each pulse and when it fires — so the
/// app layer only maps a level to a `UIImpactFeedbackGenerator` and drives the schedule against a
/// clock. Keeping the curve here (no UIKit) is what lets it carry executable tests rather than a
/// source pin. // pinned: GuardianLongPressHapticsTests.testFloorMatchesGuardianTap
public enum GuardianLongPressHaptics {
    /// How long the user must hold before the picker sheet reveals.
    public static let holdDuration: TimeInterval = 2.0

    /// Number of escalating pulses fired during the hold, ahead of the reveal crescendo.
    public static let pulseCount = 10

    /// Exponent (< 1) that clusters pulses toward the end of the hold, so the cadence
    /// accelerates ("balloons up") instead of running evenly. Smaller = tighter finish.
    static let cadenceExponent = 0.6

    /// Silence before the first pulse. The gesture's `onPressingChanged(true)` fires on
    /// finger-DOWN — before the long press is recognized — so without this, a quick tap or an
    /// aborted press would buzz (and an awake tap would get this pulse *plus* the tap haptic,
    /// while sleeping/paused taps would vibrate even though the tap haptic is suppressed there).
    /// Holding this far is already past a tap, so the first pulse only lands once the touch is a
    /// deliberate press. // pinned: GuardianLongPressHapticsTests.testScheduleWaitsForGraceThenStaysWithinTheHold
    public static let gracePeriod: TimeInterval = 0.3

    /// The pulse for a normalized hold `progress` (0 at the first pulse, 1 at the reveal).
    ///
    /// The level steps light → medium → heavy across the hold; the lightest third is the floor
    /// that matches the guardian tap. Intensity stays at full so no pulse ever dips *below* that
    /// floor — the escalation is carried by the rising level (and the accelerating cadence), never
    /// by a quieter pulse, which is exactly the "lowest equals the current Guard tap, then balloon
    /// up" feel.
    public static func step(forProgress progress: Double) -> GuardianLongPressHapticStep {
        let clamped = min(max(progress, 0), 1)
        let level: GuardianLongPressHapticLevel
        switch clamped {
        case ..<(1.0 / 3.0):
            level = .light
        case ..<(2.0 / 3.0):
            level = .medium
        default:
            level = .heavy
        }
        return GuardianLongPressHapticStep(level: level, intensity: 1.0)
    }

    /// The escalating pulses in fire order, each with its delay (seconds from press-start).
    ///
    /// The first pulse fires at `gracePeriod` — not on touch-down — so a tap or aborted press
    /// stays silent; it still opens on the familiar tap *feel* (a light impact at full intensity).
    /// From there the pulses span `[gracePeriod, holdDuration)`, and because the delay grows
    /// sub-linearly (`cadenceExponent < 1`) the *gap* between successive pulses shrinks, so they
    /// crowd together into the reveal. The final crescendo (`revealStep`) is fired separately, at
    /// the reveal itself.
    public static let schedule: [GuardianLongPressHapticPulse] = (0..<pulseCount).map { index in
        let progress = Double(index) / Double(pulseCount)
        let delay = gracePeriod + (holdDuration - gracePeriod) * pow(progress, cadenceExponent)
        return GuardianLongPressHapticPulse(delay: delay, step: step(forProgress: progress))
    }

    /// The strongest pulse, fired the instant the sheet reveals — the top of the balloon.
    public static let revealStep = GuardianLongPressHapticStep(level: .heavy, intensity: 1.0)
}
