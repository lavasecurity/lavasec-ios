import Foundation
import SwiftUI
import UIKit
import LavaSecKit

/// The preparation owner is the native operation, not `bridge.flow`. A second
/// modal, privacy teardown or a new RN surface cannot lend it another identity.
extension LavaAppBridge {
    private var preparationRetryIsAvailable: Bool {
        let drafts = model.filterDrafts
        guard model.filterPreparationUpgradeReason == nil else { return false }
        if let target = drafts.pendingSwitchFilterID {
            guard model.library.filter(id: target) != nil, !model.isFilterFrozen(target),
                  model.activeFilterID != target else { return false }
        } else {
            guard model.filterEditDraft != nil, model.filterDraftHasChanges else { return false }
        }
        return drafts.preparationFailureIsRetryable || model.filterPreparationCanResumeAfterUpgrade
    }

    var currentPreparationAttemptID: UUID? {
        let drafts = model.filterDrafts
        guard drafts.isPreparationPresented,
              drafts.preparationReplacementEpoch == model.configurationReplacementGate.epoch else { return nil }
        return drafts.preparationPresentation.id
    }

    /// Called by the host before selecting its full-screen presentation. A
    /// coverless replacement may supersede an already-failed attempt, which has
    /// no suspended operation left to clear the old cover itself.
    func reconcilePreparationPresentation() {
        let drafts = model.filterDrafts
        guard drafts.isPreparationPresented,
              drafts.preparationReplacementEpoch != model.configurationReplacementGate.epoch else { return }
        drafts.preparationUpgradeContext = nil
        drafts.isPreparationPresented = false
    }

    func preparationProjection() -> [String: Any]? {
        guard let id = currentPreparationAttemptID, canReadPresentation(.appUnlock) else { return nil }
        let drafts = model.filterDrafts
        let state: String
        let title: String
        let message: String
        switch drafts.preparationState {
        case .idle:
            state = "idle"
            title = FilterPreparationPresentation.message(for: .downloading)
            message = ""
        case .preparing(let progress, let phase):
            state = progress >= 1 ? "success" : "preparing"
            title = progress >= 1 ? "Success" : phase
            message = ""
        case .failed(let failure):
            state = "failed"
            title = "We couldn't update your filter"
            message = failure
        }
        let upgrade = state == "failed" ? model.filterPreparationUpgradeReason : nil
        let canRetry = state == "failed" && preparationRetryIsAvailable
        return ["id": id.uuidString, "origin": drafts.preparationOrigin.rawValue,
            "state": state, "progress": drafts.preparationState.progress,
            "title": title.lavaLocalized, "message": message.lavaLocalized,
            "busy": drafts.preparationRecoveryInFlight,
            "recovery": ["retry": canRetry,
                "editReturn": state == "failed" && model.filterPreparationFailureOffersEditReturn,
                "keepCurrent": state == "failed", "upgrade": upgrade.map { $0 as Any } ?? NSNull()]]
    }

    func preparationCommand(_ action: String, _ input: [String: Any]) async throws -> Any {
        guard let text = input["id"] as? String, let id = UUID(uuidString: text),
              currentPreparationAttemptID == id else { throw CommandError("The app screen closed before this action started.") }
        let drafts = model.filterDrafts
        if action == "preparation.enter" {
            try await authorize(.appUnlock, "Unlock Lava")
            guard UIApplication.shared.applicationState == .active, currentPreparationAttemptID == id,
                  canReadPresentation(.appUnlock) else { throw CommandError("Read access changed.") }
            return NSNull()
        }
        guard UIApplication.shared.applicationState == .active, canReadPresentation(.appUnlock) else {
            throw CommandError("Read access changed.")
        }
        if action == "preparation.presented" {
            guard drafts.acknowledgePreparationSuccess(id: id) else { throw CommandError("Read access changed.") }
            return true
        }
        if action == "preparation.rendered" {
            return drafts.noteRenderedPreparationSuccess(id: id)
        }
        if action == "preparation.announce" {
            return drafts.announcePreparationOutcome(id: id)
        }
        guard ["preparation.retry", "preparation.editReturn", "preparation.keepCurrent", "preparation.upgrade"].contains(action),
              case .failed = drafts.preparationState, !drafts.preparationRecoveryInFlight else {
            throw CommandError("Read access changed.")
        }
        drafts.preparationRecoveryInFlight = true
        var retryScheduled = false
        defer {
            if currentPreparationAttemptID == id, !retryScheduled { drafts.preparationRecoveryInFlight = false }
        }
        // These are continuations of the already-admitted native failure visit.
        // The former screen gated them with App Unlock; adding another protected
        // editing turn would change retry, discard and upgrade behavior.
        guard UIApplication.shared.applicationState == .active, currentPreparationAttemptID == id,
              canReadPresentation(.appUnlock), case .failed = drafts.preparationState else {
            throw CommandError("Read access changed.")
        }
        switch action {
        case "preparation.retry":
            guard preparationRetryIsAvailable else {
                throw CommandError("Read access changed.")
            }
            retryScheduled = true
            model.retryFilterPreparation()
        case "preparation.editReturn":
            guard model.filterPreparationFailureOffersEditReturn else { throw CommandError("Read access changed.") }
            model.returnToFilterEditAfterPrepareFailure()
        case "preparation.keepCurrent": model.keepCurrentFiltersAfterPrepareFailure()
        case "preparation.upgrade":
            guard let reason = model.filterPreparationUpgradeReason else { throw CommandError("Read access changed.") }
            drafts.preparationUpgradeContext = reason
        default: break
        }
        publish()
        return true
    }
}

/// Only the Plus sheet remains native containment; the preparation body is RN.
struct LavaPreparationUpgradePresentation: ViewModifier {
    @ObservedObject private var drafts = LavaAppBridge.shared.model.filterDrafts
    @ObservedObject private var model = LavaAppBridge.shared.model
    func body(content: Content) -> some View {
        content.sheet(isPresented: Binding(get: { drafts.preparationUpgradeContext != nil }, set: {
            if !$0 { drafts.preparationUpgradeContext = nil }
        })) {
            if let context = drafts.preparationUpgradeContext {
                LavaPlusUpgradeSheet(context: context)
            }
        }
        .onChange(of: model.configuration.hasLavaSecurityPlus) { _, enabled in
            if enabled { drafts.preparationUpgradeContext = nil }
        }
    }
}
