import UIKit
import LavaSecKit
import LavaSecPresentation

extension LavaAppBridge {
    func stopGuardRamp() {
        guardRampTask?.cancel()
        guardRampTask = nil
        ProtectionHapticFeedback.stopGuardianLongPressContinuousRamp()
    }
    func guardGesture(_ gesture: String) throws {
        switch gesture {
        case "start":
            stopGuardRamp()
            guard UIApplication.shared.applicationState == .active else { return }
            if ProtectionHapticFeedback.supportsContinuousLongPressRamp { ProtectionHapticFeedback.startGuardianLongPressContinuousRamp() }
            else {
                guardRampTask = Task { @MainActor in
                    var firedDelay: TimeInterval = 0
                    for pulse in GuardianLongPressHaptics.schedule {
                        let wait = pulse.delay - firedDelay
                        firedDelay = pulse.delay
                        if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
                        guard !Task.isCancelled else { return }
                        ProtectionHapticFeedback.playGuardianLongPressStep(pulse.step)
                    }
                }
            }
        case "end": stopGuardRamp()
        case "reveal":
            stopGuardRamp()
            ProtectionHapticFeedback.playGuardianLongPressStep(GuardianLongPressHaptics.revealStep)
        case "tap":
            ProtectionHapticFeedback.play(.guardianTapAcknowledged)
        default: throw CommandError("Unknown Guard gesture.")
        }
    }
}
