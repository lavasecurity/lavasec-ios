import Foundation
import Combine
import SwiftUI
import UIKit
import PhotosUI
@preconcurrency import AVFoundation
import UniformTypeIdentifiers
import LavaSecKit
import LavaSecAppServices
import LavaSecPresentation

/// Import content stays in this visit. React receives display rows and a stage
/// token; commands cannot submit a replacement configuration of their own.
@MainActor
final class LavaAppImportSession {
    enum Stage: Equatable {
        case chooseMethod
        case enterCode
        case scanCode
        case confirm(ShareableFilterConfiguration)
        case chooseReplace(ShareableFilterConfiguration)
        case reviewReplacement(original: ShareableFilterConfiguration, applied: ShareableFilterConfiguration, target: Filter)
        case applying(ShareableFilterConfiguration)
        case completed(filterName: String)

        init(startMode: ImportFiltersStartMode) {
            switch startMode {
            case .chooseMethod: self = .chooseMethod
            case .enterCode: self = .enterCode
            case .scanCode: self = .scanCode
            case .review(let configuration): self = .confirm(configuration)
            }
        }
        var transitionID: String {
            switch self {
            case .chooseMethod: "chooseMethod"
            case .enterCode: "enterCode"
            case .scanCode: "scanCode"
            case .confirm: "confirm"
            case .chooseReplace: "chooseReplace"
            case .reviewReplacement: "reviewReplacement"
            case .applying: "applying"
            case .completed: "completed"
            }
        }
        var order: Int {
            switch self {
            case .chooseMethod: 0
            case .enterCode, .scanCode: 1
            case .confirm: 2
            case .chooseReplace: 3
            case .reviewReplacement: 4
            case .applying: 5
            case .completed: 6
            }
        }
    }
    struct PendingActiveReplacement {
        let id = UUID()
        let configuration: ShareableFilterConfiguration
        let originalConfiguration: ShareableFilterConfiguration
        let target: Filter
    }
    let id: UUID
    let startMode: ImportFiltersStartMode
    let completion: ImportFiltersCompletion
    let viewModel: AppViewModel
    private(set) var stage: Stage
    private(set) var stageID = UUID()
    private(set) var navDirection = "forward"
    private(set) var enteredCode = ""
    private(set) var errorMessage = ""
    private(set) var cameraDenied = false
    private(set) var checkingCatalog = false
    private(set) var catalogCheckFailed = false
    var decodingPhoto: Bool { photoLifetime.requestID != nil }
    private(set) var applyError: String?
    private(set) var alertTitle = "Couldn't import"
    private(set) var pendingActiveReplacement: PendingActiveReplacement?
    private(set) var alertID = UUID()
    private(set) var showingMaxFilters = false
    private var isRetired = false
    private var presentationRetired = false
    private var catalogTask: Task<Void, Never>?
    private var photoPicker: LavaImportPhotoPicker?
    private var photoLifetime = FilterImportPhotoLifetime()
    private var upgradeObservation: AnyCancellable?
    var publish: () -> Void = {}
    var dismiss: () -> Void = {}
    var onImported: (() -> Void)?
    var authorizeImport: () async -> Bool = { false }
    var ownsFlow: () -> Bool = { false }
    var permitsDelivery: () -> Bool = { false }
    var openUpgrade: () -> Void = {}

    init(flow: LavaAppNativeFlow, model: AppViewModel) {
        id = flow.id
        viewModel = model
        startMode = flow.importStartMode ?? (flow.name == "importCode" ? .enterCode : flow.name == "importScan" ? .scanCode : .chooseMethod)
        completion = flow.importCompletion
        stage = completion.filterName.map { .completed(filterName: $0) } ?? Stage(startMode: startMode)
    }

    var canDismiss: Bool { stage.transitionID != "applying" && stage.transitionID != "completed" }
    var closeAtRoot: Bool {
        if case .confirm = stage, case .review = startMode { return true }
        return stage == .chooseMethod
    }

    func go(to requestedStage: Stage) {
        var newStage = requestedStage
        if presentationRetired, requestedStage.transitionID != "applying", requestedStage.transitionID != "completed" {
            newStage = Stage(startMode: startMode)
            presentationRetired = false; applyError = nil; pendingActiveReplacement = nil
        }
        retirePhotoSelection()
        catalogTask?.cancel(); catalogTask = nil
        navDirection = newStage.order >= stage.order ? "forward" : "backward"
        stage = newStage; stageID = UUID(); errorMessage = ""; enteredCode = ""; cameraDenied = false
        checkingCatalog = false; catalogCheckFailed = false
        if case .confirm(let configuration) = newStage { checkCatalog(configuration) }
        publish()
    }

    func begin() { if case .confirm(let configuration) = stage { checkCatalog(configuration) } }

    func concealAcceptedPresentation() {
        presentationRetired = true
        enteredCode = ""; errorMessage = ""; pendingActiveReplacement = nil
        retirePhotoSelection()
    }

    func retire() {
        isRetired = true
        upgradeObservation = nil
        catalogTask?.cancel(); catalogTask = nil
        retirePhotoSelection()
        enteredCode = ""; errorMessage = ""; pendingActiveReplacement = nil
    }

    func trackUpgrade(_ controller: UIViewController) {
        // Match the prior parent sheet binding: a confirmed subscription closes
        // this contextual RN upgrade and returns to the same import review.
        upgradeObservation = viewModel.plus.objectWillChange.sink { [weak self, weak controller] _ in
            Task { @MainActor [weak self, weak controller] in
                guard let self, self.viewModel.configuration.hasLavaSecurityPlus else { return }
                self.upgradeObservation = nil
                controller?.dismiss(animated: true)
            }
        }
    }

    func back() {
        guard canDismiss else { return }
        pendingActiveReplacement = nil
        switch stage {
        case .chooseMethod: dismiss()
        case .enterCode, .scanCode:
            if case .chooseMethod = startMode { go(to: .chooseMethod) } else { dismiss() }
        case .confirm:
            if case .review = startMode { dismiss() }
            else { go(to: Stage(startMode: startMode)) }
        case .chooseReplace(let configuration): go(to: .confirm(configuration))
        case .reviewReplacement(let original, _, _): go(to: .chooseReplace(original))
        default: break
        }
    }

    func changeCode(_ value: String) {
        guard case .enterCode = stage else { return }
        enteredCode = value; errorMessage = ""; publish()
    }

    func continueCode(_ value: String) {
        guard case .enterCode = stage else { return }
        enteredCode = value
        do {
            let configuration = try ShareableFilterLink.decode(enteredCode)
            guard !configuration.isEmpty else { errorMessage = "This code doesn't contain a filter to import."; publish(); return }
            go(to: .confirm(configuration))
        } catch { errorMessage = ShareableFilterImportMessages.message(for: error); publish() }
    }

    func scan(_ scanned: String) -> Bool {
        guard !isRetired, permitsDelivery(), case .scanCode = stage else { return false }
        do {
            let configuration = try ShareableFilterLink.decode(scanned)
            guard !configuration.isEmpty else { errorMessage = "That QR code doesn't contain a filter to import."; publish(); return false }
            go(to: .confirm(configuration)); return true
        } catch { errorMessage = ShareableFilterImportMessages.message(for: error); publish(); return false }
    }

    func reconcileCameraAuthorization() {
        guard !isRetired, cameraDenied, case .scanCode = stage,
              UIApplication.shared.applicationState == .active,
              AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { return }
        // Foreground native projection owns this recheck. A React AppState
        // callback may precede private-presentation hydration and be withheld.
        cameraDenied = false; stageID = UUID()
    }

    func cameraAttempt() { guard case .scanCode = stage else { return }; errorMessage = ""; publish() }
    func cameraUnavailable() { guard case .scanCode = stage else { return }; cameraDenied = true; publish() }

    func checkCatalog(_ configuration: ShareableFilterConfiguration) {
        guard !checkingCatalog else { return }
        checkingCatalog = true; catalogCheckFailed = false
        let token = stageID
        catalogTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do { try await viewModel.refreshCatalogForSharedImport(configuration) }
            catch {
                guard !Task.isCancelled, stageID == token, ownsFlow() else { return }
                catalogCheckFailed = true
            }
            guard !Task.isCancelled, stageID == token, ownsFlow() else { return }
            checkingCatalog = false; publish()
        }
    }

    func chooseTarget(_ id: String) {
        guard case .chooseReplace(let configuration) = stage, let target = viewModel.library.filter(id: id) else { return }
        if viewModel.isFilterFrozen(target.id) { openUpgrade(); return }
        // Selecting a row only stages the package-owned diff. It never grants
        // active-filter consent or invokes a mutating model operation.
        // pinned: SharedFilterImportSourceTests.testSelectingTheActiveTargetOnlyStagesIt
        go(to: .reviewReplacement(original: configuration, applied: viewModel.importPlan(for: configuration).applied, target: target))
    }

    func add() {
        guard case .confirm(let configuration) = stage, !checkingCatalog, !catalogCheckFailed else { return }
        if viewModel.canCreateFilter { addNew(configuration) }
        else if viewModel.configuration.hasLavaSecurityPlus { showingMaxFilters = true; alertID = UUID(); publish() }
        else { openUpgrade() }
    }

    func replaceReviewed() {
        guard case .reviewReplacement(let original, let configuration, let target) = stage else { return }
        if target.id == viewModel.library.activeFilterID {
            pendingActiveReplacement = PendingActiveReplacement(configuration: configuration, originalConfiguration: original, target: target)
            alertID = UUID(); publish()
        } else { replace(configuration, originalConfiguration: original, into: target) }
    }

    func confirmActiveReplacement(_ token: String) {
        guard let confirmed = pendingActiveReplacement, confirmed.id.uuidString == token else { return }
        pendingActiveReplacement = nil
        // This is the only command that carries explicit destructive consent.
        // pinned: SharedFilterImportSourceTests.testOnlyTheDestructiveConfirmationSetsTheConfirmedFlag
        replace(confirmed.configuration, originalConfiguration: confirmed.originalConfiguration,
                into: confirmed.target, confirmedActiveReplacement: true)
    }

    func clearAlert() { pendingActiveReplacement = nil; applyError = nil; showingMaxFilters = false; alertTitle = "Couldn't import"; publish() }

    func finishImport() {
        guard case .completed = stage else { return }
        if completion.acknowledge() { onImported?() }
        dismiss()
    }

    private func addNew(_ config: ShareableFilterConfiguration) {
        guard canDismiss else { return }
        let plan = viewModel.importPlan(for: config)
        let applied = plan.applied
        guard !applied.isEmpty else { return }
        go(to: .applying(config))
        Task { @MainActor in
            guard await authorizeImport() else { go(to: .confirm(config)); return }
            guard ownsFlow() else { return }
            guard viewModel.importPlan(for: config).applied == applied else {
                applyError = "Something else updated your filter while this imported. Try again."
                alertID = UUID(); go(to: .confirm(config)); return
            }
            if let id = viewModel.addImportedShareableConfigurationAsNewFilter(applied), let saved = viewModel.library.filter(id: id) {
                completion.recordCommittedFilter(named: saved.name, unavailableListCount: plan.droppedCount(of: .unavailableBlocklist))
                go(to: .completed(filterName: saved.name))
            } else {
                applyError = "Couldn't add this filter. Please try again."
                alertID = UUID(); go(to: .confirm(config))
            }
        }
    }

    private func replace(_ config: ShareableFilterConfiguration, originalConfiguration: ShareableFilterConfiguration,
                         into filter: Filter, confirmedActiveReplacement: Bool = false) {
        guard canDismiss else { return }
        go(to: .applying(config))
        Task { @MainActor in
            guard await authorizeImport() else { go(to: .chooseReplace(originalConfiguration)); return }
            guard ownsFlow() else { return }
            guard let current = viewModel.library.filter(id: filter.id),
                  current.strippingLocalCacheState() == filter.strippingLocalCacheState(),
                  viewModel.importPlan(for: originalConfiguration).applied == config else {
                applyError = "Something else updated your filter while this imported. Try again."
                alertID = UUID(); go(to: .chooseReplace(originalConfiguration)); return
            }
            // Focus/Shortcuts can make the selected target active during auth.
            // Re-read after that await and require a fresh consequence dialog.
            // pinned: SharedFilterImportSourceTests.testActiveReplacementIsRecheckedAfterAuthentication
            guard confirmedActiveReplacement || filter.id != viewModel.library.activeFilterID else {
                pendingActiveReplacement = PendingActiveReplacement(configuration: config, originalConfiguration: originalConfiguration, target: filter)
                alertID = UUID(); go(to: .chooseReplace(originalConfiguration)); return
            }
            let unavailableListCount = viewModel.importPlan(for: originalConfiguration).droppedCount(of: .unavailableBlocklist)
            let result = await viewModel.replaceFilterWithImportedShareableConfiguration(id: filter.id, config,
                confirmedActiveReplacement: confirmedActiveReplacement)
            switch result {
            case .success:
                let filterName = viewModel.library.filter(id: filter.id)?.name ?? filter.name
                completion.recordCommittedFilter(named: filterName, unavailableListCount: unavailableListCount)
                go(to: .completed(filterName: filterName))
            case .failure(let message): applyError = message; alertID = UUID(); go(to: .chooseReplace(originalConfiguration))
            }
        }
    }

    private func retirePhotoSelection() {
        photoLifetime.cancel()
        photoPicker?.retire(); photoPicker = nil
    }

    func pickPhoto() {
        guard case .chooseMethod = stage, photoPicker == nil, let request = photoLifetime.begin() else { return }
        let token = stageID
        photoPicker = LavaImportPhotoPicker { [weak self] result in
            guard let self, !self.isRetired, self.ownsFlow(), self.stageID == token,
                  self.photoLifetime.finish(request) else { return }
            self.photoPicker = nil
            guard let result else { self.publish(); return }
            switch result {
            case .success(let configuration): self.go(to: .confirm(configuration))
            case .failure(let error):
                self.alertTitle = "Couldn't read that image"
                self.applyError = (error as? ShareableFilterImageDecodeError)?.errorDescription ?? ShareableFilterImageDecodeError.unreadableImage.errorDescription
                self.alertID = UUID(); self.publish()
            }
        }
        publish()
        guard photoPicker?.present() == true else { retirePhotoSelection(); publish(); return }
    }
}

extension LavaAppBridge {
    func importOwner(_ flow: LavaAppNativeFlow) -> LavaAppImportSession {
        if let importSession, importSession.id == flow.id { return importSession }
        importSession?.retire()
        let owner = LavaAppImportSession(flow: flow, model: model)
        importSession = owner
        owner.ownsFlow = { [weak self] in self?.flow?.id == flow.id }
        owner.permitsDelivery = { [weak self] in
            guard let self else { return false }
            return self.flow?.id == flow.id && self.canReadPresentation(.appUnlock)
                && UIApplication.shared.applicationState == .active
                && !self.security.isAppUnlockBlockingUI && !self.security.isAppUnlockPrivacyMaskVisible
        }
        owner.publish = { [weak self] in self?.publish() }
        owner.dismiss = { [weak self] in
            guard let self, self.flow?.id == flow.id else { return }
            self.importSession?.retire(); self.importSession = nil; self.flow = nil; self.publish()
        }
        owner.authorizeImport = { [weak self] in
            guard let self, self.flow?.id == flow.id else { return false }
            let accepted = await self.security.requireFreshAuthentication(for: .filterEditing, reason: "Import filter")
            return accepted && self.flow?.id == flow.id && UIApplication.shared.applicationState == .active
                && self.security.protectedDataIsAvailableForPresentation
        }
        owner.openUpgrade = { [weak self] in self?.presentImportUpgrade(flowID: flow.id) }
        owner.begin()
        return owner
    }

    func retireImportPresentation() {
        // Accepted writes retain their native owner and committed completion.
        // Unaccepted entry/review/photo state is discarded at the same boundary
        // that previously unmounted the SwiftUI importer.
        guard let importSession else { return }
        if importSession.stage.transitionID == "applying" { importSession.concealAcceptedPresentation(); return }
        importSession.retire(); self.importSession = nil
    }

    func importProjection(_ flow: LavaAppNativeFlow) -> [String: Any]? {
        guard flow.isImport, canReadPresentation(.appUnlock) else { return nil }
        let owner = importOwner(flow)
        owner.reconcileCameraAuthorization()
        var value: [String: Any] = ["stage": owner.stage.transitionID, "stageID": owner.stageID.uuidString,
            "direction": owner.navDirection, "code": owner.enteredCode, "error": owner.errorMessage.lavaLocalized,
            "cameraDenied": owner.cameraDenied, "checkingCatalog": owner.checkingCatalog,
            "catalogCheckFailed": owner.catalogCheckFailed, "decodingPhoto": owner.decodingPhoto,
            "canDismiss": owner.canDismiss, "closeAtRoot": owner.closeAtRoot, "alertID": owner.alertID.uuidString]
        if let message = owner.applyError { value["alert"] = ["title": owner.alertTitle.lavaLocalized, "message": message.lavaLocalized] }
        if owner.showingMaxFilters {
            value["alert"] = ["title": "Maximum filters reached".lavaLocalized,
                "message": "You can host up to %d filters. Delete one to add another.".lavaLocalizedFormat(model.configuration.limits.maxFilters), "tint": "confirmation"]
        }
        if let pending = owner.pendingActiveReplacement {
            let summary = pending.configuration.replacementSummary(for: pending.target)
            value["activeReplacement"] = ["id": pending.id.uuidString,
                "message": ["This changes the filter protecting this device. “%@” keeps its name and receives the reviewed content.".lavaLocalizedFormat(pending.target.name),
                    importRemovalSummary(summary),
                    "Added: %1$lld blocklists, %2$lld blocked domains, %3$lld custom sources, %4$lld allowed exceptions.".lavaLocalizedFormat(summary.addedBlocklistIDs.count, summary.selectionDiff.addedBlockedDomains.count, summary.addedCustomBlocklists.count, summary.selectionDiff.addedAllowedDomains.count)].joined(separator: "\n\n")]
        }
        switch owner.stage {
        case .confirm(let configuration): value["review"] = importReviewProjection(configuration)
        case .chooseReplace:
            value["targets"] = model.filters.map { filter -> [String: Any] in
                let locked = model.isFilterFrozen(filter.id)
                var summary = filter.isEmpty ? "Blocks nothing".lavaLocalized : "%@ rules".lavaLocalizedFormat(model.filterRuleCount(for: filter).formatted())
                if filter.id == model.activeFilterID { summary = "%1$@ · %2$@".lavaLocalizedFormat(summary, "In effect".lavaLocalized) }
                return ["id": filter.id, "name": filter.name, "summary": locked ? "Locked".lavaLocalized : summary, "locked": locked]
            }
        case .reviewReplacement(_, let configuration, let filter):
            let summary = configuration.replacementSummary(for: filter)
            func listName(_ id: String, _ filter: Filter?) -> String { filter?.customBlocklists.first(where: { $0.id == id })?.displayName ?? model.blocklistName(for: id) }
            func source(_ value: CustomBlocklistSource) -> String { "\(value.displayName) · \(value.sourceURL.absoluteString) · \(value.parseFormat.rawValue)" }
            value["replacement"] = ["name": summary.before?.name ?? "", "removed": importRemovalSummary(summary), "groups": [
                ["title": "Blocklists", "removed": summary.removedBlocklistIDs.map { listName($0, summary.before) }, "added": summary.addedBlocklistIDs.map { listName($0, summary.after) }],
                ["title": "Blocked domains", "removed": summary.selectionDiff.removedBlockedDomains, "added": summary.selectionDiff.addedBlockedDomains],
                ["title": "Custom blocklists", "removed": summary.removedCustomBlocklists.map(source), "added": summary.addedCustomBlocklists.map(source)],
                ["title": "Allowed Exceptions", "removed": summary.selectionDiff.removedAllowedDomains, "added": summary.selectionDiff.addedAllowedDomains]]]
        case .completed(let filterName):
            value["completed"] = ["message": "The shared filter was imported as “%@” in Your filters.".lavaLocalizedFormat(filterName),
                "unavailable": importUnavailableMessage(owner.completion.unavailableListCount)]
        default: break
        }
        return value
    }

    func importCommand(_ action: String, _ input: [String: Any]) async throws -> Any {
        guard let flow, flow.isImport, input["id"] as? String == flow.id.uuidString,
              canReadPresentation(.appUnlock), UIApplication.shared.applicationState == .active else { throw CommandError("Read access changed.") }
        let owner = importOwner(flow)
        guard input["stageID"] as? String == owner.stageID.uuidString else { throw CommandError("The app screen closed before this action started.") }
        switch action {
        case "import.back": owner.back()
        case "import.dismiss": if owner.canDismiss { owner.dismiss() }
        case "import.method":
            guard owner.stage == .chooseMethod, let method = input["method"] as? String,
                  ["code", "scan", "photo"].contains(method) else { throw CommandError("Invalid app command.") }
            if method == "code" { owner.go(to: .enterCode) }
            else if method == "scan" { owner.go(to: .scanCode) }
            else { owner.pickPhoto() }
        case "import.code": owner.changeCode(input["value"] as? String ?? "")
        case "import.continue": owner.continueCode(input["value"] as? String ?? "")
        case "import.retry": if case .confirm(let configuration) = owner.stage { owner.checkCatalog(configuration) }
        case "import.add": owner.add()
        case "import.targets": if case .confirm(let configuration) = owner.stage, !owner.checkingCatalog, !owner.catalogCheckFailed { owner.go(to: .chooseReplace(configuration)) }
        case "import.target": owner.chooseTarget(input["target"] as? String ?? "")
        case "import.replace": owner.replaceReviewed()
        case "import.confirmActive": owner.confirmActiveReplacement(input["confirmation"] as? String ?? "")
        case "import.clearAlert": owner.clearAlert()
        case "import.upgrade": owner.openUpgrade()
        case "import.done": owner.finishImport()
        case "import.cameraSettings":
            guard case .scanCode = owner.stage else { throw CommandError("Invalid app command.") }
            if let url = URL(string: UIApplication.openSettingsURLString) { await UIApplication.shared.open(url) }
        case "import.cameraRetry":
            if case .scanCode = owner.stage, AVCaptureDevice.authorizationStatus(for: .video) == .authorized { owner.go(to: .scanCode) }
        default: throw CommandError("Invalid app command.")
        }
        return NSNull()
    }

    private func presentImportUpgrade(flowID: UUID) {
        guard flow?.id == flowID else { return }
        // The existing RN upgrade surface runs in this same runtime; the
        // importer remains its retained parent, including the review token.
        guard let root = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).flatMap(\.windows).first(where: \.isKeyWindow)?.rootViewController else { return }
        var top = root; while let next = top.presentedViewController { top = next }
        let controller = UIHostingController(rootView: LavaPlusUpgradeSheet(context: "fullImport")
            .environmentObject(model).environmentObject(model.plus).environmentObject(security)
            .preferredColorScheme(model.customization.preferredColorScheme)
            .lavaTextSizeOverride(model.customization.textSizeOverride).tint(LavaStyle.safeGreen))
        controller.modalPresentationStyle = .pageSheet
        importSession?.trackUpgrade(controller)
        top.present(controller, animated: true)
    }

    private func importReviewProjection(_ configuration: ShareableFilterConfiguration) -> [String: Any] {
        let plan = model.importPlan(for: configuration)
        let customIDs = Set(plan.applied.customBlocklists.map(\.id))
        func count(_ id: String, custom: CustomBlocklistSource? = nil) -> String? {
            let count: Int?
            if let custom {
                guard model.configuration.customBlocklists.contains(where: { $0.id == custom.id && $0.sourceURL == custom.sourceURL && $0.parseFormat == custom.parseFormat }) else { return nil }
                count = model.cachedBlockRuleSets[id]?.count
            } else if let source = model.sharedImportCatalogSourcesByID?[id], source.entryCount > 0 { count = source.entryCount }
            else { count = model.cachedBlockRuleSets[id]?.count }
            return count.map { "%@ rules".lavaLocalizedFormat($0.formatted()) }
        }
        var rows: [[String: Any]] = plan.applied.enabledBlocklistIDs.subtracting(customIDs).sorted {
            model.blocklistName(for: $0).localizedCaseInsensitiveCompare(model.blocklistName(for: $1)) == .orderedAscending
        }.map { ["id": "list:\($0)", "title": model.blocklistName(for: $0), "metadata": count($0) ?? "", "verbatim": false] }
        rows += plan.applied.customBlocklists.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }.map { source in
            ["id": "list:\(source.id)", "title": source.displayName, "verbatim": true,
             "metadata": [count(source.id, custom: source), source.sourceURL.absoluteString, plan.applied.enabledBlocklistIDs.contains(source.id) ? nil : "Not enabled".lavaLocalized].compactMap { $0 }.joined(separator: " · ")]
        }
        rows += plan.applied.blockedDomains.sorted().map { ["id": "domain:\($0)", "title": $0, "metadata": "", "verbatim": true] }
        let upgradeRows = plan.dropped.filter { [.requiresUpgrade, .exceedsLimit, .exceedsRuleBudget].contains($0.kind) }
            .map { $0.kind == .exceedsRuleBudget ? model.blocklistName(for: $0.label) : $0.label }
        var warnings: [[String: Any]] = []
        func warning(_ kind: ShareableFilterImportPlan.DroppedEntry.Kind, _ singular: String, _ plural: String) {
            let amount = plan.droppedCount(of: kind)
            if amount > 0 { warnings.append(["message": (amount == 1 ? singular : plural).lavaLocalizedFormat(amount.formatted()), "quiet": false]) }
        }
        let invalid = plan.droppedCount(of: .invalidDomain)
        if invalid > 0 { warnings.append(["message": "Some domains were invalid or cannot be allowed.".lavaLocalized, "quiet": false]) }
        let unavailable = plan.droppedCount(of: .unavailableBlocklist)
        if unavailable > 0 { warnings.append(["message": importUnavailableMessage(unavailable), "quiet": true]) }
        warning(.requiresUpgrade, "%@ custom blocklist needs Lava Security+", "%@ custom blocklists need Lava Security+")
        warning(.exceedsLimit, "%@ domain is over your plan's limit", "%@ domains are over your plan's limit")
        warning(.unsafeSource, "%@ custom blocklist was skipped for safety", "%@ custom blocklists were skipped for safety")
        warning(.exceedsRuleBudget, "%@ blocklist didn't fit your plan's rule limit", "%@ blocklists didn't fit your plan's rule limit")
        return ["blocked": rows, "allowed": plan.applied.allowedDomains.map { $0.sorted() as Any } ?? NSNull(),
            "canImport": !plan.applied.isEmpty, "showUpgrade": !model.configuration.hasLavaSecurityPlus && !upgradeRows.isEmpty,
            "upgradeRows": upgradeRows, "warnings": warnings]
    }
    private func importRemovalSummary(_ summary: FilterReplacementSummary) -> String {
        "Removed: %1$lld blocklists, %2$lld blocked domains, %3$lld custom sources, %4$lld allowed exceptions.".lavaLocalizedFormat(summary.removedBlocklistIDs.count, summary.selectionDiff.removedBlockedDomains.count, summary.removedCustomBlocklists.count, summary.selectionDiff.removedAllowedDomains.count)
    }
    private func importUnavailableMessage(_ count: Int) -> String {
        guard count > 0 else { return "" }
        return (count == 1 ? "%@ list wasn’t imported because it’s no longer available." : "%@ lists weren’t imported because they’re no longer available.").lavaLocalizedFormat(count.formatted())
    }
}

/// System photo selection remains a native island. Only a bounded file is
/// copied from the selected provider; photo bytes and decoded payload never
/// cross Fabric, and dismissal does not consume the import stage.
@MainActor
private final class LavaImportPhotoPicker: NSObject, PHPickerViewControllerDelegate {
    private var completion: ((Result<ShareableFilterConfiguration, Error>?) -> Void)?
    private weak var controller: PHPickerViewController?
    init(_ completion: @escaping (Result<ShareableFilterConfiguration, Error>?) -> Void) { self.completion = completion }
    func present() -> Bool {
        guard let root = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).flatMap(\.windows).first(where: \.isKeyWindow)?.rootViewController else { return false }
        var top = root; while let next = top.presentedViewController { top = next }
        var config = PHPickerConfiguration(); config.filter = .images; config.selectionLimit = 1
        let picker = PHPickerViewController(configuration: config); picker.delegate = self; controller = picker
        top.present(picker, animated: true); return true
    }
    func retire() { completion = nil; controller?.dismiss(animated: false) }
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard let provider = results.first?.itemProvider else { finish(nil); return }
        provider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { [weak self] url, _ in
            let result: Result<URL, Error>
            do {
                guard let url else { throw ShareableFilterImageDecodeError.unreadableImage }
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                guard let byteCount = attributes[.size] as? Int else { throw ShareableFilterImageDecodeError.unreadableImage }
                do { try SharedFilterImageLimits.validate(byteCount: byteCount) }
                catch { throw ShareableFilterImageDecodeError.imageTooLarge }
                result = .success(try PrivateImportFiles.copy(url))
            } catch { result = .failure(error) }
            Task { @MainActor [weak self] in
                switch result {
                case .success(let file):
                    defer { try? FileManager.default.removeItem(at: file) }
                    guard let self, self.completion != nil else { return }
                    do { self.finish(.success(try await ShareableFilterImageDecoder.decode(fileURL: file))) }
                    catch { self.finish(.failure(error)) }
                case .failure(let error): self?.finish(.failure(error))
                }
            }
        }
    }
    private func finish(_ result: Result<ShareableFilterConfiguration, Error>?) { let callback = completion; completion = nil; callback?(result) }
}

/// Camera-only island. React controls its frame; the native visit validates and
/// parses scan delivery synchronously before accepting a single capture.
@objc(LavaImportScannerContent)
@MainActor
final class LavaImportScannerContent: UIView {
    private var controller: QRScannerViewController?
    private var ownerID = ""
    @objc func configure(ownerID: String) {
        guard self.ownerID != ownerID else { return }
        resetForRecycle(); self.ownerID = ownerID
        guard let owner = LavaAppBridge.shared.importSession, owner.id.uuidString == ownerID,
              owner.stage.transitionID == "scanCode" else { return }
        let stageID = owner.stageID
        let camera = QRScannerViewController()
        camera.onScan = { [weak owner] value in
            guard let owner, owner.stageID == stageID else { return false }
            return owner.scan(value)
        }
        camera.onAttemptBegan = { [weak owner] in
            guard let owner, owner.stageID == stageID else { return }
            owner.cameraAttempt()
        }
        camera.onCameraAuthorizationDenied = { [weak owner] in
            guard let owner, owner.stageID == stageID else { return }
            owner.cameraUnavailable()
        }
        controller = camera; updateContainment(); camera.resumeCaptureIfVisible()
    }
    @objc func resetForRecycle() {
        if let controller { controller.retireCapture(); LavaNativeContainment.remove(controller) }
        controller = nil; ownerID = ""
    }
    override func layoutSubviews() { super.layoutSubviews(); updateContainment() }
    override func didMoveToSuperview() { super.didMoveToSuperview(); updateContainment() }
    override func didMoveToWindow() {
        super.didMoveToWindow(); updateContainment()
        if window == nil { controller?.suspendCapture() } else { controller?.resumeCaptureIfVisible() }
    }
    private func updateContainment() {
        guard let controller else { return }
        LavaNativeContainment.update(controller, in: self) { _ in }
    }
}
