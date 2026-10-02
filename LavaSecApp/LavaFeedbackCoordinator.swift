import Foundation
import UIKit
import LavaSecPresentation

/// One terminal cue per explicit operation; background completion is consumed without replay.
@MainActor final class LavaFeedbackCoordinator {
    static let shared = LavaFeedbackCoordinator()
    private var policy = LavaFeedbackPolicy()
    private let render: @MainActor (LavaFeedbackSemantic) -> Void
    init(render: @escaping @MainActor (LavaFeedbackSemantic) -> Void = ProtectionHapticFeedback.playSemantic) { self.render = render }
    func begin(_ lane: String) -> UUID { policy.begin(lane) }
    func finish(_ lane: String, _ id: UUID, _ semantic: LavaFeedbackSemantic, cancelled: Bool = false) {
        if let effect = policy.finish(lane, id: id, semantic: semantic,
            active: UIApplication.shared.applicationState == .active, cancelled: cancelled || Task.isCancelled) { render(effect) }
    }
    func interaction(_ semantic: LavaFeedbackSemantic, control: String, value: String? = nil) {
        if let effect = policy.interaction(semantic, control: control, value: value,
            now: ProcessInfo.processInfo.systemUptime, active: UIApplication.shared.applicationState == .active) { render(effect) }
    }
}
