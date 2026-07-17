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

/// One control point of the continuous ramp's parameter curve: an effective value in `0…1` at
/// `relativeTime` seconds from the continuous event's start.
///
/// The app layer turns each of these into a `CHHapticParameterCurve.ControlPoint`. Keeping the curve
/// as plain data here (no Core Haptics import) is what lets the swell carry executable tests rather
/// than a source pin.
public struct GuardianLongPressHapticCurvePoint: Equatable, Sendable {
    /// Seconds from the continuous event's start at which the curve reaches `value`.
    public let relativeTime: TimeInterval
    /// The effective parameter value (`0…1`) at `relativeTime`.
    public let value: Float

    /// Creates a control point from a fire time and a normalized value.
    ///
    /// Both inputs feed `CHHapticParameterCurve.ControlPoint`: `relativeTime` must be non-negative (a
    /// negative time places the control point before the event start, which Core Haptics rejects at
    /// playback) and `value` must be in `0...1` (the intensity / sharpness controls are 0…1). The
    /// preconditions localize either contract violation to construction rather than a clamped or silent
    /// Core Haptics curve at the call site (OCR review on lavasec-ios#69).
    public init(relativeTime: TimeInterval, value: Float) {
        precondition(
            relativeTime >= 0,
            "GuardianLongPressHapticCurvePoint.relativeTime must be non-negative, got \(relativeTime)"
        )
        precondition(
            value >= 0 && value <= 1,
            "GuardianLongPressHapticCurvePoint.value must be in 0...1, got \(value)"
        )
        self.relativeTime = relativeTime
        self.value = value
    }
}

/// A single continuous haptic "charge" that swells from the light-tap floor to the reveal peak.
///
/// This is the Core-Haptics rendering of the ramp: instead of a burst of discrete transients (the
/// `schedule` fallback), the app layer plays ONE `CHHapticEvent(.hapticContinuous)` for `duration`
/// seconds and modulates it with the `intensityCurve` / `sharpnessCurve` parameter curves, so the
/// strength climbs as one unbroken *gradient* rather than a machine-gun of taps —  feedback that
/// `UIImpactFeedbackGenerator` cannot produce, since it only fires discrete impacts. The event is
/// offset by `startDelay` so a quick tap or aborted press stays silent, exactly like the discrete
/// schedule's grace period.
public struct GuardianLongPressHapticContinuousRamp: Equatable, Sendable {
    /// Silence before the swell begins (seconds from press-start) — the continuous mirror of the
    /// discrete schedule's `gracePeriod`.
    public let startDelay: TimeInterval
    /// Length of the continuous event, sized so `startDelay + duration` lands on the reveal.
    public let duration: TimeInterval
    /// Base `hapticIntensity`. Core Haptics' `.hapticIntensityControl` is MULTIPLICATIVE, so a full
    /// base (1.0) lets the intensity curve carry the whole `0…1` envelope (effective = base × curve).
    public let baseIntensity: Float
    /// Base `hapticSharpness`. Core Haptics' `.hapticSharpnessControl` is ADDITIVE (an offset), not
    /// multiplicative, so the base must be ZERO for the sharpness curve to carry the absolute envelope
    /// (effective = base + curve). A full base would saturate every positive curve point to max
    /// sharpness and flatten the gradient to a constant crisp buzz (Codex P2 on #404).
    /// // pinned: GuardianLongPressHapticsTests.testContinuousRampSpansGraceToRevealFloorToPeak
    public let baseSharpness: Float
    /// Effective-intensity control points across `[0, duration]`, floor → peak.
    public let intensityCurve: [GuardianLongPressHapticCurvePoint]
    /// Effective-sharpness control points across `[0, duration]`, floor → peak.
    public let sharpnessCurve: [GuardianLongPressHapticCurvePoint]

    /// Creates a continuous ramp from its window, base parameters, and pre-sampled curves.
    ///
    /// Preconditions localize — at construction rather than as a silent or rejected Core Haptics curve
    /// at playback — the contracts `CHHapticParameterCurve`, `.hapticIntensityControl`, and
    /// `.hapticSharpnessControl` impose: a positive `duration` (a non-positive one, e.g.
    /// `holdDuration <= gracePeriod`, would place control points at non-positive `relativeTime`); a
    /// non-negative `startDelay`; `baseIntensity` and `baseSharpness` in `0...1`; and non-empty curves
    /// whose control points are sorted by STRICTLY ascending `relativeTime` (Core Haptics requires
    /// strictly increasing control-point times — two points at the same `relativeTime` are rejected)
    /// and stay within `[0, duration]` (per-point `relativeTime >= 0` is enforced by
    /// `GuardianLongPressHapticCurvePoint.init`). (OCR review on lavasec-ios#69.)
    public init(
        startDelay: TimeInterval,
        duration: TimeInterval,
        baseIntensity: Float,
        baseSharpness: Float,
        intensityCurve: [GuardianLongPressHapticCurvePoint],
        sharpnessCurve: [GuardianLongPressHapticCurvePoint]
    ) {
        precondition(duration > 0, "GuardianLongPressHapticContinuousRamp.duration must be positive")
        precondition(startDelay >= 0, "GuardianLongPressHapticContinuousRamp.startDelay must be non-negative")
        precondition(
            baseIntensity >= 0 && baseIntensity <= 1,
            "GuardianLongPressHapticContinuousRamp.baseIntensity must be in 0...1, got \(baseIntensity)"
        )
        precondition(
            baseSharpness >= 0 && baseSharpness <= 1,
            "GuardianLongPressHapticContinuousRamp.baseSharpness must be in 0...1, got \(baseSharpness)"
        )
        precondition(!intensityCurve.isEmpty, "GuardianLongPressHapticContinuousRamp.intensityCurve must be non-empty")
        precondition(!sharpnessCurve.isEmpty, "GuardianLongPressHapticContinuousRamp.sharpnessCurve must be non-empty")
        precondition(
            Self.isSortedWithinWindow(intensityCurve, duration: duration),
            "GuardianLongPressHapticContinuousRamp.intensityCurve must be sorted ascending within [0, duration]"
        )
        precondition(
            Self.isSortedWithinWindow(sharpnessCurve, duration: duration),
            "GuardianLongPressHapticContinuousRamp.sharpnessCurve must be sorted ascending within [0, duration]"
        )
        self.startDelay = startDelay
        self.duration = duration
        self.baseIntensity = baseIntensity
        self.baseSharpness = baseSharpness
        self.intensityCurve = intensityCurve
        self.sharpnessCurve = sharpnessCurve
    }

    /// Whether `curve`'s control points are ordered by strictly increasing `relativeTime` and every
    /// point lies within `[0, duration]` — the ordering and window `CHHapticParameterCurve` requires.
    private static func isSortedWithinWindow(
        _ curve: [GuardianLongPressHapticCurvePoint],
        duration: TimeInterval
    ) -> Bool {
        var previousTime = -Double.greatestFiniteMagnitude
        for point in curve {
            guard point.relativeTime > previousTime, point.relativeTime <= duration else {
                return false
            }
            previousTime = point.relativeTime
        }
        return true
    }
}

/// Pure description of the Guard long-press gesture that reveals the Lava Guard picker.
///
/// The gesture is a `holdDuration` press whose haptic feedback is a crescendo that opens on the
/// light guardian-tap floor and climbs into the reveal. This type owns the curve in TWO renderings,
/// both free of UIKit / Core Haptics so they carry executable tests rather than a source pin:
///
/// - `continuousRamp` — the PRIMARY path where the hardware supports Core Haptics: one continuous
///   event whose intensity and sharpness swell as a single unbroken *gradient*. This is what fixes
///   the "choppy" feel of firing discrete impacts (PR #404).
/// - `schedule` — the FALLBACK on devices without Core Haptics (all iPads, pre-Core-Haptics
///   iPhones): escalating pulses fire at a constant, frequent interval, each landing harder than the
///   last, so strength climbs while the rhythm stays steady.
///
/// The app layer renders whichever the hardware supports and drives it against a clock.
/// // pinned: GuardianLongPressHapticsTests.testFloorMatchesGuardianTap
public enum GuardianLongPressHaptics {
    /// How long the user must hold before the picker sheet reveals.
    public static let holdDuration: TimeInterval = 1.2

    /// Uniform spacing between pulses — the tightest ("most frequent") cadence, held CONSTANT so
    /// the buildup is a crescendo carried by rising strength, not by a changing rhythm.
    public static let pulseInterval: TimeInterval = 0.1

    /// Number of escalating pulses fired during the hold, ahead of the reveal crescendo — the count
    /// that fits at `pulseInterval` inside `[gracePeriod, holdDuration)`. DERIVED from the three
    /// constants as `round((holdDuration − gracePeriod) / pulseInterval)` rather than hardcoded, so a
    /// change to any of them re-derives it instead of silently leaving a stale count: a grown
    /// `holdDuration` against a fixed count would leave the tail of the hold silent before the reveal.
    /// `.rounded(.toNearestOrAwayFromZero)` (not truncation) absorbs binary-floating-point error —
    /// `(1.2 − 0.3) / 0.1` evaluates to `8.999…`, which `Int()` alone would floor to 8. The rule is
    /// spelled out even though away-from-zero is already Swift's default for `.rounded()`: it pins the
    /// tie direction that MUST hold at this count. At an exact `.5` (e.g. a future `holdDuration` of
    /// 1.15 → `8.5`) the tie has to break UP, toward more pulses — away-from-zero guarantees that,
    /// whereas `.toNearestOrEven` would round `8.5` to the even `8`, leaving the tail of the hold silent
    /// and reopening the pre-reveal gap this derivation exists to prevent. Spelling it out keeps a later
    /// edit from flipping the rule silently; behavior is unchanged from the bare `.rounded()` (OCR review
    /// on lavasec-ios#69).
    /// // pinned: GuardianLongPressHapticsTests.testScheduleWaitsForGraceThenStaysWithinTheHold
    public static let pulseCount: Int = {
        let count = Int(((holdDuration - gracePeriod) / pulseInterval).rounded(.toNearestOrAwayFromZero))
        precondition(count >= 1, "holdDuration − gracePeriod must accommodate at least one pulse at pulseInterval")
        return count
    }()

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
    /// floor — the escalation is carried entirely by the rising level, never by a quieter pulse,
    /// which is exactly the "lowest equals the current Guard tap, then grows stronger" crescendo
    /// (the cadence itself stays constant — see `schedule`).
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
    /// From there the pulses fire at a CONSTANT `pulseInterval` (the tightest, most-frequent
    /// cadence), so the rhythm never changes — the buildup is a crescendo carried entirely by the
    /// rising strength (`step(forProgress:)` steps light → medium → heavy), not by the spacing. The
    /// final crescendo (`revealStep`) is fired separately, at the reveal itself.
    public static let schedule: [GuardianLongPressHapticPulse] = (0..<pulseCount).map { index in
        let progress = pulseCount > 1 ? Double(index) / Double(pulseCount - 1) : 0
        let delay = gracePeriod + Double(index) * pulseInterval
        return GuardianLongPressHapticPulse(delay: delay, step: step(forProgress: progress))
    }

    /// The strongest pulse, fired the instant the sheet reveals — the peak of the crescendo.
    public static let revealStep = GuardianLongPressHapticStep(level: .heavy, intensity: 1.0)

    // MARK: Continuous ("gradient") ramp — the primary rendering on Core Haptics

    /// Effective intensity of the swell's floor — where the gradient opens. Device-tuned to open
    /// gently, well below the `.light` guardian tap (matching `.light`, ≈0.6 in these units, read as
    /// too strong at the start); the peak and ease-in curve carry the build into the reveal. Core
    /// Haptics and `UIImpactFeedbackGenerator` don't share a units scale, so this is a feel value, not
    /// a `.light` equivalence — lowered across device passes (0.6 → 0.45 in #405, → 0.25 in #407).
    /// // pinned: GuardianLongPressHapticsTests.testContinuousRampOpensAtTheGentleFloor
    public static let continuousFloorIntensity: Float = 0.25
    /// Sharpness of the swell's floor — dull/soft, a touch rounder than the `.light` tap so the open
    /// doesn't read as crisp (softened alongside the intensity floor in #405).
    public static let continuousFloorSharpness: Float = 0.25
    /// Effective intensity at the END of the swell — where the gradient lands as the reveal fires.
    /// Tuned on-device a touch under full so the sustained swell doesn't max out; the discrete reveal
    /// transient (`revealStep`, a full heavy impact) still punctuates harder at the very end, so the
    /// swell peak is no longer the single strongest moment of the charge (lowered from 1.0 in #407).
    public static let continuousPeakIntensity: Float = 0.8
    /// Sharpness at the peak — crisper than the floor, so the charge both strengthens AND sharpens
    /// into the reveal.
    public static let continuousPeakSharpness: Float = 0.9

    /// Control points sampled per parameter curve. A handful is enough: Core Haptics interpolates
    /// linearly between control points, so sampling the ease-in curve at this many points keeps the
    /// swell smooth without an over-long pattern.
    public static let continuousCurveSampleCount = 6

    /// Effective intensity at a normalized hold `progress` (0 at the floor, 1 at the reveal).
    ///
    /// Ease-IN (`progress²`): the swell starts slow and accelerates, which reads as 漸強 — a
    /// crescendo that builds toward the reveal rather than a flat linear rise. Clamped to `0...1`.
    public static func continuousIntensity(atProgress progress: Double) -> Float {
        rampedValue(from: continuousFloorIntensity, to: continuousPeakIntensity, progress: progress)
    }

    /// Effective sharpness at a normalized hold `progress`, on the SAME ease-in curve as intensity so
    /// strength and crispness climb together.
    public static func continuousSharpness(atProgress progress: Double) -> Float {
        rampedValue(from: continuousFloorSharpness, to: continuousPeakSharpness, progress: progress)
    }

    /// Shared ease-in interpolation for the swell's parameter curves: `floor` at `progress` 0, `peak`
    /// at 1, accelerating in between. `progress` is clamped to `0...1`.
    ///
    /// Preconditions `0 <= floor <= peak <= 1` so a future floor/peak constant swap that violated the
    /// envelope (e.g. floor 0.9, peak 1.1) fails HERE — naming the real culprit — instead of surfacing
    /// downstream as a confusing `GuardianLongPressHapticCurvePoint.value must be in 0...1` crash. The
    /// result is also clamped to `0...1` as belt-and-suspenders against float error at the endpoints
    /// (OCR review on lavasec-ios#69).
    private static func rampedValue(from floor: Float, to peak: Float, progress: Double) -> Float {
        precondition(
            (0...1).contains(floor) && (0...1).contains(peak) && floor <= peak,
            "rampedValue requires 0 <= floor <= peak <= 1, got floor=\(floor) peak=\(peak)"
        )
        let clamped = min(max(progress, 0), 1)
        let eased = clamped * clamped
        return min(max(floor + (peak - floor) * Float(eased), 0), 1)
    }

    /// Samples an ease-in envelope into `continuousCurveSampleCount` control points evenly spaced
    /// across `[0, duration]`, so Core Haptics interpolates a smooth gradient between them.
    private static func sampledCurve(
        _ value: (Double) -> Float,
        duration: TimeInterval,
        sampleCount: Int = continuousCurveSampleCount
    ) -> [GuardianLongPressHapticCurvePoint] {
        // A single sample would emit only the floor at relativeTime 0 — a silent constant buzz with no
        // swell (the ramp init accepts a one-point, trivially-sorted, in-window curve). Require at least
        // two so the curve always carries both a floor and a peak. `sampleCount` is a parameter (not the
        // constant read directly) so the check guards any caller rather than a compile-time literal (OCR
        // review on lavasec-ios#69).
        precondition(
            sampleCount >= 2,
            "sampledCurve sampleCount must be >= 2 so the curve spans floor → peak, got \(sampleCount)"
        )
        let lastIndex = sampleCount - 1
        return (0..<sampleCount).map { index in
            let progress = Double(index) / Double(lastIndex)
            return GuardianLongPressHapticCurvePoint(
                relativeTime: duration * progress,
                value: value(progress)
            )
        }
    }

    /// The continuous swell that renders the charge as one gradient on Core Haptics — the primary
    /// path where the hardware supports it (the `schedule` above is the discrete fallback).
    ///
    /// Runs from `gracePeriod` (silent until the press is deliberate) to `holdDuration` (the reveal),
    /// so `startDelay + duration == holdDuration`. Both parameter curves sample the ease-in curve at
    /// `continuousCurveSampleCount` points across `[0, duration]`. The base parameters differ by
    /// Core Haptics' control semantics: `baseIntensity` is full (the intensity control multiplies)
    /// while `baseSharpness` is zero (the sharpness control adds), so each curve carries its absolute
    /// floor→peak envelope without saturating.
    /// // pinned: GuardianLongPressHapticsTests.testContinuousRampSpansGraceToRevealFloorToPeak
    public static let continuousRamp: GuardianLongPressHapticContinuousRamp = {
        let duration = holdDuration - gracePeriod
        return GuardianLongPressHapticContinuousRamp(
            startDelay: gracePeriod,
            duration: duration,
            baseIntensity: 1.0,
            baseSharpness: 0.0,
            intensityCurve: sampledCurve({ continuousIntensity(atProgress: $0) }, duration: duration),
            sharpnessCurve: sampledCurve({ continuousSharpness(atProgress: $0) }, duration: duration)
        )
    }()
}
