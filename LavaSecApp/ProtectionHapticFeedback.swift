import Foundation
import UIKit
@preconcurrency import CoreHaptics
import LavaSecKit
import LavaSecPresentation

enum ProtectionHapticFeedback {
    @MainActor private static let selectionChangeGenerator = UISelectionFeedbackGenerator()

    case protectionOnSucceeded
    case protectionStartFailed
    case protectionTurnedOff
    case guardianTapAcknowledged
    // Outcome haptics for the rest of the app's consequential actions. They route
    // through the same `play` choke point so the Customization toggle silences them
    // alongside the protection and guardian-tap feedback.
    case actionSucceeded
    case actionFailed
    case selectionRejected
    case selectionConfirmed
    /// A restrained tick for controls that continuously scrub through adjacent choices (for
    /// example, the Sudoku keypad). `UISelectionFeedbackGenerator` is intentionally lighter than
    /// the confirmation impact and is designed to repeat at discrete selection boundaries.
    case selectionChanged
    /// A low-intensity soft pulse for inspecting a missing or measured-zero chart bucket.
    case inspectionEmpty
    /// A real no-op: `play` returns without touching a generator. This exists so a caller that
    /// takes a haptic parameter can express "no feedback at all" without the parameter becoming
    /// Optional. Its caller was `turnOffAfterFailedChainedEstablishment`, deleted in PR #629 when
    /// the connect gate stopped tearing the tunnel down — the case it existed for (a background
    /// chained gate turning protection off silently, because remapping to `.protectionTurnedOff`
    /// still fired a `.warning` buzz at a pocketed phone — Kilo, PR #594) no longer occurs. Kept:
    /// it is the only way a haptic parameter can say "no feedback at all" without going Optional.
    case silent

    /// Source of truth for the "Lava Haptics" Customization toggle. Lava haptics
    /// default on, so a missing key reads as enabled and preserves the prior
    /// always-on behavior. AppViewModel writes this key; `play` reads it.
    static let preferenceDefaultsKeyName = "lavasec.customization.lavaHaptics"

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: preferenceDefaultsKeyName) as? Bool ?? true
    }

    @MainActor static func prepareSelectionChange() {
        guard isEnabled else { return }
        selectionChangeGenerator.prepare()
    }

    @MainActor static func play(_ feedback: ProtectionHapticFeedback) {
        // Retained generation-owned controllers share the same foreground gate as semantic operations.
        // Suppression is final: a status refresh or wake never queues hardware feedback for replay.
        guard isEnabled, UIApplication.shared.applicationState == .active, !Task.isCancelled else {
            return
        }

        switch feedback {
        case .silent:
            return
        case .protectionOnSucceeded:
            let generator = UINotificationFeedbackGenerator()
            generator.prepare()
            generator.notificationOccurred(.success)
        case .protectionStartFailed:
            let generator = UINotificationFeedbackGenerator()
            generator.prepare()
            generator.notificationOccurred(.error)
        case .protectionTurnedOff:
            let generator = UIImpactFeedbackGenerator(style: .light)
            generator.prepare()
            generator.impactOccurred()
        case .guardianTapAcknowledged:
            let generator = UIImpactFeedbackGenerator(style: .light)
            generator.prepare()
            generator.impactOccurred()
        case .actionSucceeded:
            let generator = UINotificationFeedbackGenerator()
            generator.prepare()
            generator.notificationOccurred(.success)
        case .actionFailed:
            let generator = UINotificationFeedbackGenerator()
            generator.prepare()
            generator.notificationOccurred(.error)
        case .selectionRejected:
            let generator = UINotificationFeedbackGenerator()
            generator.prepare()
            generator.notificationOccurred(.warning)
        case .selectionConfirmed:
            let generator = UIImpactFeedbackGenerator(style: .light)
            generator.prepare()
            generator.impactOccurred()
        case .inspectionEmpty:
            let generator = UIImpactFeedbackGenerator(style: .soft)
            generator.prepare()
            generator.impactOccurred(intensity: 0.12)
        case .selectionChanged:
            selectionChangeGenerator.selectionChanged()
            // Keep the shared generator warm so rapid keypad boundary crossings remain crisp.
            selectionChangeGenerator.prepare()
        }
    }

    /// Plays one pulse of the Guard long-press "charge" ramp (`GuardianLongPressHaptics`), the
    /// gesture that reveals the Lava Guard picker. The curve — which pulse, when — is owned by the
    /// pure `GuardianLongPressHaptics` model; this is the UIKit playback, mapping the level to a
    /// feedback generator. Gated by the same Lava Haptics toggle as every other surface, so the
    /// whole ramp goes silent when haptics are off. The lightest step is a `.light` impact at full
    /// intensity — identical to `.guardianTapAcknowledged` — so the ramp's floor equals the tap.
    @MainActor static func playGuardianLongPressStep(_ step: GuardianLongPressHapticStep) {
        guard isEnabled else {
            return
        }

        let generator = UIImpactFeedbackGenerator(style: step.level.impactFeedbackStyle)
        generator.prepare()
        generator.impactOccurred(intensity: step.intensity)
    }
}

/// Plays the Guard long-press "charge" as a single continuous Core Haptics event whose intensity and
/// sharpness swell along `GuardianLongPressHaptics.continuousRamp` — one smooth gradient instead of a
/// train of discrete `UIImpactFeedbackGenerator` impacts (which the Taptic Engine renders as separate
/// taps, the "choppy" feel this replaces). Used where the hardware `supportsHaptics`; GuardView falls
/// back to the discrete `schedule` where it does not — all iPads, pre-Core-Haptics iPhones (PR #404).
///
/// Lives in the app target rather than a package layer because it drives Core Haptics and the
/// app-only `ProtectionHapticFeedback`/UIKit façade, which the narrow SPM products deliberately don't
/// link — the tunnel especially runs under a jetsam ceiling (`INV-MEM-1`) and carries no haptics. The
/// pure input it renders — the floor→peak `GuardianLongPressHaptics.continuousRamp` shape — DOES live
/// in `LavaSecKit`, where it gets real behavioral tests (`GuardianLongPressHapticsTests`); this class
/// is the thin, source-pinned player around it.
///
/// `@MainActor`-confined so the gesture's start/stop are serialized with the app's other haptics and
/// the engine/player references never leave the main actor. Haptics are non-essential feedback, so
/// every Core Haptics failure is swallowed — a broken engine must never disrupt the long-press reveal.
@MainActor
final class GuardianLongPressContinuousRampPlayer {
    /// Whether this hardware can render the continuous gradient (a Taptic Engine + Core Haptics).
    /// False on all iPads and pre-Core-Haptics iPhones, where GuardView uses the discrete fallback.
    ///
    /// `nonisolated static let` (cached, not recomputed): hardware haptics capability is fixed device
    /// state that never changes at runtime, so the probe runs ONCE instead of allocating a fresh
    /// `Capabilities` struct on every guard — one per gesture in `startGuardianLongPressRamp` plus one
    /// per `start()` on the hot path (OCR review on lavasec-ios#69). The nonisolated
    /// `ProtectionHapticFeedback.supportsContinuousLongPressRamp` façade reads it without hopping to the
    /// main actor (the class itself stays `@MainActor` for the engine/player state).
    nonisolated static let isSupported: Bool =
        CHHapticEngine.capabilitiesForHardware().supportsHaptics

    private var engine: CHHapticEngine?
    private var player: CHHapticPatternPlayer?

    /// Starts the swell from the top of the ramp. Fails silent when the hardware can't render it or
    /// Core Haptics errors — the reveal still happens; only the charge haptic is skipped.
    func start() {
        guard Self.isSupported else { return }
        // Defensive stop-before-start: if a prior gesture's player is still held in `self.player` when
        // start() is re-entered without an intervening stop() (e.g. SwiftUI re-firing
        // `onPressingChanged(true)`), the `self.player = player` assignment below would drop the old
        // handle WITHOUT stopping it, orphaning a player that keeps buzzing on the shared engine until
        // its pattern ends. stop() is main-actor + synchronous + safe on a nil/stale handle, so — unlike
        // the async reset handler `resolvedEngine()` deliberately omits — it can't nil a live player out
        // from under the next gesture (OCR review on lavasec-ios#69).
        stop()
        do {
            let engine = try resolvedEngine()
            try engine.start()
            let player = try engine.makePlayer(with: Self.makePattern())
            self.player = player
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            // A dead engine — e.g. after a media-services reset — can't recover in place, so drop it
            // (synchronously, on the main actor); the next gesture rebuilds a fresh one via
            // `resolvedEngine()`. Non-essential feedback: never propagate, just clean up.
            self.engine = nil
            stop()
        }
    }

    /// Stops any in-flight swell — on finger-lift, reveal, navigate-away, or backgrounding. Safe to
    /// call when nothing is playing. The engine is left to auto-shut-down when idle.
    func stop() {
        try? player?.stop(atTime: CHHapticTimeImmediate)
        player = nil
    }

    private func resolvedEngine() throws -> CHHapticEngine {
        if let engine {
            return engine
        }
        let engine = try CHHapticEngine()
        // Idle-shutdown between gestures instead of holding the Taptic Engine awake; `start()`
        // restarts it on the next press, and a reset/dead engine is rebuilt from `start()`'s catch.
        //
        // Deliberately NO stopped/reset handler that nils `player`: those fire on an arbitrary queue,
        // so a hop-to-main task from a PRIOR gesture's stop (e.g. idle auto-shutdown) could land AFTER
        // the next gesture assigned its fresh player, nil'ing the only handle to an actively-playing
        // player — an aborted/backgrounded press would then keep buzzing until the pattern ends
        // (Codex P2 on #404). We don't need one: `start()` always builds a new player, and `stop()`
        // no-ops on a stale one, so nothing plays on a dead engine and the stop handle is never lost.
        engine.isAutoShutdownEnabled = true
        self.engine = engine
        return engine
    }

    private static func makePattern() throws -> CHHapticPattern {
        // The ramp already accounts for Core Haptics' control asymmetry — `baseIntensity` full (the
        // intensity control multiplies) and `baseSharpness` zero (the sharpness control adds) — so
        // both curves modulate their absolute floor→peak envelope here without clamping (Codex P2 #404).
        let ramp = GuardianLongPressHaptics.continuousRamp
        let event = CHHapticEvent(
            eventType: .hapticContinuous,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: ramp.baseIntensity),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: ramp.baseSharpness)
            ],
            relativeTime: ramp.startDelay,
            duration: ramp.duration
        )
        // The event and both curves share the `startDelay` offset, so the swell stays silent through
        // the grace period and then modulates across the event window.
        let intensityCurve = CHHapticParameterCurve(
            parameterID: .hapticIntensityControl,
            controlPoints: ramp.intensityCurve.map {
                CHHapticParameterCurve.ControlPoint(relativeTime: $0.relativeTime, value: $0.value)
            },
            relativeTime: ramp.startDelay
        )
        let sharpnessCurve = CHHapticParameterCurve(
            parameterID: .hapticSharpnessControl,
            controlPoints: ramp.sharpnessCurve.map {
                CHHapticParameterCurve.ControlPoint(relativeTime: $0.relativeTime, value: $0.value)
            },
            relativeTime: ramp.startDelay
        )
        return try CHHapticPattern(events: [event], parameterCurves: [intensityCurve, sharpnessCurve])
    }
}

extension ProtectionHapticFeedback {
    @MainActor static func playSemantic(_ semantic: LavaFeedbackSemantic) {
        switch semantic {
        case .selected: play(.selectionChanged)
        case .engaged, .acknowledged: play(.selectionConfirmed)
        case .succeeded: play(.actionSucceeded)
        case .attentionRequired: play(.selectionRejected)
        case .failed: play(.actionFailed)
        case .inspectionEmpty: play(.inspectionEmpty)
        }
    }
    /// Shared, main-actor player for the continuous long-press swell — one instance so the engine is
    /// reused across gestures (rebuilt only after a system stop/reset).
    @MainActor private static let longPressContinuousRampPlayer = GuardianLongPressContinuousRampPlayer()

    /// Whether the continuous gradient can play on this hardware; GuardView uses the discrete
    /// `schedule` fallback when false.
    static var supportsContinuousLongPressRamp: Bool {
        GuardianLongPressContinuousRampPlayer.isSupported
    }

    /// Starts the continuous long-press gradient, gated by the same Lava Haptics toggle as every
    /// other surface so it goes silent when haptics are off.
    @MainActor static func startGuardianLongPressContinuousRamp() {
        guard isEnabled else {
            return
        }
        longPressContinuousRampPlayer.start()
    }

    /// Stops the continuous long-press gradient. Safe to call when nothing is playing.
    @MainActor static func stopGuardianLongPressContinuousRamp() {
        longPressContinuousRampPlayer.stop()
    }
}

private extension GuardianLongPressHapticLevel {
    /// The UIKit impact weight for this ramp band. `.light` matches the guardian-tap floor.
    var impactFeedbackStyle: UIImpactFeedbackGenerator.FeedbackStyle {
        switch self {
        case .light:
            .light
        case .medium:
            .medium
        case .heavy:
            .heavy
        @unknown default:
            // Forward-compatible with a future ramp band on the public enum; the floor light impact
            // is the safe default (matches the guardian-tap feel).
            .light
        }
    }
}
