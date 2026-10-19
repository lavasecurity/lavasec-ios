import XCTest
@testable import LavaSecCore
@testable import LavaSecKit

/// Source contracts for placing an imported shared filter.
///
/// These pin the invariants that make an untrusted card safe to accept: an import
/// may add or replace a filter, but it may never quietly change what is protecting
/// the device, must retain the versioned exception contract, and never let a
/// display name drift apart from the contents it describes.
///
/// `AppViewModel` sits outside the SPM test target, so these are text pins. The
/// executable half of this task lives in `SharedFilterNamePolicyTests`.
///
/// Plan: `lavasec-infra/plans/2026-07-14-recipient-first-shared-filter-card-plan.md`
final class SharedFilterImportSourceTests: XCTestCase {

    private func appViewModelSource() throws -> String {
        try readAppViewModelSource()
    }

    func testCompletedImportWaitsForDoneAndDeliversCallbackOnce() throws {
        let native = try readSource(.reactNativeAppImport)
        let finish = try sourceBlock(in: native, startingAt: "func finishImport()", endingBefore: "private func addNew(")
        XCTAssertTrue(finish.contains("guard case .completed = stage else { return }"))
        XCTAssertTrue(finish.contains("if completion.acknowledge() { onImported?() }"))
        XCTAssertTrue(finish.contains("dismiss()"))
        let completion = try sourceBlock(in: readSource(.shareableFiltersUI), startingAt: "final class ImportFiltersCompletion:", endingBefore: "final class QRScannerViewController:")
        XCTAssertTrue(completion.contains("guard filterName != nil, !acknowledged else { return false }"))
        let add = try sourceBlock(in: native, startingAt: "private func addNew(", endingBefore: "private func replace(")
        XCTAssertTrue(add.contains("completion.recordCommittedFilter(named: saved.name"))
        XCTAssertFalse(add.contains("dismiss()"))
    }

    func testCommittedResultSurvivesNativeFlowRecreationButImportDraftDoesNot() throws {
        let native = try readSource(.reactNativeAppImport)
        let completion = try sourceBlock(in: readSource(.shareableFiltersUI), startingAt: "final class ImportFiltersCompletion:", endingBefore: "final class QRScannerViewController:")
        XCTAssertTrue(completion.contains("guard filterName == nil else { return }"))
        for privateDraft in ["ShareableFilterConfiguration", "Stage", "QRCodeScanner", "enteredCode"] { XCTAssertFalse(completion.contains(privateDraft)) }
        XCTAssertTrue(native.contains("completion = flow.importCompletion"))
        XCTAssertTrue(native.contains("completion.filterName.map { .completed(filterName: $0) } ?? Stage(startMode: startMode)"))
        XCTAssertTrue(native.contains("func retireImportPresentation()"))
        XCTAssertTrue(native.contains("importSession.retire(); self.importSession = nil"))
        XCTAssertTrue(native.contains("enteredCode = \"\"; errorMessage = \"\"; pendingActiveReplacement = nil"))
        XCTAssertTrue(try readSource(.reactNativeAppHost).contains("retireImportPresentation()"))
    }

    func testEveryImportEntryRetainsCompletionAbovePrivacyTeardown() throws {
        let source = try readSource(.reactNativeAppImport)
        XCTAssertTrue(source.contains("completion = flow.importCompletion"))
        XCTAssertTrue(source.contains("requireFreshAuthentication(for: .filterEditing"))
        XCTAssertTrue(source.contains("owner.ownsFlow ="))
    }

    func testReactImportCommandsAndCameraRetainExactVisitAndStageAuthority() throws {
        let native = try readSource(.reactNativeAppImport)
        let boundary = try sourceBlock(in: native, startingAt: "func importCommand(", endingBefore: "private func presentImportUpgrade(")
        XCTAssertTrue(boundary.contains("input[\"id\"] as? String == flow.id.uuidString"))
        XCTAssertTrue(boundary.contains("input[\"stageID\"] as? String == owner.stageID.uuidString"))
        XCTAssertTrue(sourceContainsInOrder(["canReadPresentation(.appUnlock)", "let owner = importOwner(flow)", "input[\"stageID\"]", "switch action"], in: boundary))
        let scanner = try sourceBlock(in: native, startingAt: "final class LavaImportScannerContent:", endingBefore: "private func updateContainment()")
        XCTAssertTrue(scanner.contains("let stageID = owner.stageID"))
        XCTAssertEqual(sourceOccurrenceCount(of: "owner.stageID == stageID", in: scanner), 3)
        XCTAssertTrue(native.contains("guard !isRetired, permitsDelivery(), case .scanCode = stage"))
    }

    func testReplacementReviewShowsRemovalsAndRechecksItsBasisAfterAuth() throws {
        let native = try readSource(.reactNativeAppImport)
        let chooser = try sourceBlock(in: native, startingAt: "func chooseTarget(", endingBefore: "func add()")
        XCTAssertTrue(chooser.contains("go(to: .reviewReplacement("))
        XCTAssertFalse(chooser.contains("replaceFilterWithImportedShareableConfiguration("))
        let replace = try sourceBlock(in: native, startingAt: "private func replace(", endingBefore: "func pickPhoto()")
        XCTAssertTrue(sourceContainsInOrder(["await authorizeImport()", "current.strippingLocalCacheState() == filter.strippingLocalCacheState()", "viewModel.importPlan(for: originalConfiguration).applied == config", "replaceFilterWithImportedShareableConfiguration("], in: replace))
        for field in ["removedBlocklistIDs", "removedBlockedDomains", "removedCustomBlocklists", "removedAllowedDomains"] { XCTAssertTrue(native.contains(field)) }
    }

    func testReplacementBackNavigationKeepsTheOriginalSharePayload() throws {
        let native = try readSource(.reactNativeAppImport)
        XCTAssertTrue(native.contains("case .reviewReplacement(let original, _, _): go(to: .chooseReplace(original))"))
        XCTAssertTrue(native.contains("case .chooseReplace(let configuration): go(to: .confirm(configuration))"))
        let replace = try sourceBlock(in: native, startingAt: "private func replace(", endingBefore: "func pickPhoto()")
        XCTAssertTrue(replace.contains("go(to: .chooseReplace(originalConfiguration))"))
        XCTAssertFalse(replace.contains("go(to: .chooseReplace(config))"))
    }

    func testCompletionPushesForwardAndCannotReplayACommittedImport() throws {
        let native = try readSource(.reactNativeAppImport)
        XCTAssertTrue(native.contains("stage.transitionID != \"applying\" && stage.transitionID != \"completed\""))
        XCTAssertTrue(native.contains("navDirection = newStage.order >= stage.order ? \"forward\" : \"backward\""))
        XCTAssertTrue(native.contains("completion.recordCommittedFilter(named: saved.name"))
        XCTAssertTrue(native.contains("completion.recordCommittedFilter(named: filterName"))
    }

    // MARK: Naming is local, never sender-controlled

    func testSharedNameIsDerivedLocallyFromALocalizedBase() throws {
        let source = try appViewModelSource()
        let helper = try sourceBlock(
            in: source,
            startingAt: "private func nextSharedFilterName(",
            endingBefore: "func addImportedShareableConfigurationAsNewFilter("
        )
        XCTAssertTrue(
            helper.contains("\"Shared filter\".lavaLocalized"),
            "The base must be localized at the app boundary — the policy package does not localize."
        )
        XCTAssertTrue(
            helper.contains("uniqueFilterName(basedOn:"),
            "Shared naming must route through the one derived-name helper, not a second loop."
        )
    }

    func testNamingDelegatesToTheSharedPolicyRatherThanAnInlineLoop() throws {
        let source = try appViewModelSource()
        let unique = try sourceBlock(
            in: source,
            startingAt: "func uniqueFilterName(",
            endingBefore: "/// Create a new filter"
        )
        XCTAssertTrue(unique.contains("SharedFilterNamePolicy.nextAvailableName("))
        XCTAssertFalse(
            unique.contains("while !isFilterNameAvailable"),
            "The inline numbering loop was replaced by the policy; two implementations can drift."
        )
    }

    // MARK: Adding never changes protection

    func testAddedSharedFilterIsInactiveAndLibraryOnly() throws {
        let source = try appViewModelSource()
        let addNew = try sourceBlock(
            in: source,
            startingAt: "func addImportedShareableConfigurationAsNewFilter(",
            endingBefore: "func replaceFilterWithImportedShareableConfiguration("
        )

        // Library-only: no compile, no publish, no tunnel reload, no switch.
        for forbidden in [
            "prepareFilterSnapshot",
            "persistSharedState",
            "notifyTunnelSnapshotUpdated",
            "switchToFilter",
            "restoreProtectionIfNeeded"
        ] {
            XCTAssertFalse(
                addNew.contains(forbidden),
                "Adding an imported filter must not \(forbidden) — protection stays untouched."
            )
        }
        XCTAssertFalse(
            addNew.contains("activeFilterID ="),
            "An imported filter must never become the filter in effect."
        )
        XCTAssertTrue(addNew.contains("library.append(newFilter)"))
        XCTAssertTrue(addNew.contains("persistLibraryOnlyChange(rollingBackTo: previousLibrary)"))
    }

    func testCapIsReadFromTierLimitsRatherThanHardcoded() throws {
        let source = try appViewModelSource()
        let canCreate = try sourceBlock(
            in: source,
            startingAt: "private var filterLibraryAccessPolicy: FilterLibraryAccessPolicy {",
            endingBefore: "var canCreateFilter: Bool {"
        )
        XCTAssertTrue(
            canCreate.contains("configuration.limits.maxFilters"),
            "The filter cap must come from tier limits, never a literal 3 or 50."
        )
    }

    // MARK: Replacement keeps identity and name while applying reviewed contents

    func testReplacementPreservesIdentityAndNameButAppliesV2Exceptions() throws {
        let source = try appViewModelSource()
        let replace = try sourceBlock(
            in: source,
            startingAt: "func replaceFilterWithImportedShareableConfiguration(",
            endingBefore: "static func filterPreparationFailureMessage("
        )

        XCTAssertFalse(replace.contains("filter.name ="))
        XCTAssertTrue(replace.contains("if let allowed = applied.allowedDomains { filter.allowedDomains = allowed }"))
        XCTAssertTrue(replace.contains("filter.lastCompiledToken = nil"))
        XCTAssertTrue(replace.contains("persistLibraryOnlyChange(rollingBackTo: previousLibrary"))
    }

    func testInactiveReplacementDoesNotTouchTheActiveFilter() throws {
        let source = try appViewModelSource()
        let replace = try sourceBlock(
            in: source,
            startingAt: "func replaceFilterWithImportedShareableConfiguration(",
            endingBefore: "static func filterPreparationFailureMessage("
        )
        // The only activeFilterID reference is the fork deciding which path to take —
        // the non-active branch must never assign it.
        XCTAssertTrue(replace.contains("if id == library.activeFilterID {"))
        XCTAssertFalse(
            replace.contains("library.activeFilterID ="),
            "Replacing a non-active filter must not change which filter is in effect."
        )
    }

    func testActiveReplacementGoesThroughTheGuardedApplyPath() throws {
        let source = try appViewModelSource()
        let replace = try sourceBlock(
            in: source,
            startingAt: "func replaceFilterWithImportedShareableConfiguration(",
            endingBefore: "static func filterPreparationFailureMessage("
        )
        XCTAssertTrue(
            replace.contains(
                "return await applyImportedShareableConfiguration(applied)"
            ),
            "The active target must reuse the prepare/publish/rollback path, preserving the recipient name."
        )
    }

    // MARK: The active rename commits and unwinds with the contents

    func testActiveReplacementPreservesRecipientNameAtPersistenceBoundary() throws {
        let apply = try sourceBlock(in: appViewModelSource(), startingAt: "func applyImportedShareableConfiguration(", endingBefore: "private func nextSharedFilterName(")
        XCTAssertFalse(apply.contains("renamingActiveFilterTo"))
        XCTAssertFalse(apply.contains(".name ="))
        XCTAssertTrue(apply.contains("configurationReplacementGate.isCurrent(importToken)"))
        XCTAssertTrue(apply.contains("persistSharedState("))
    }

    /// Failed publication now restores the previous selection with a generation fence.
    func testFailedActiveImportRollbackIsGenerationFenced() throws {
        let apply = try sourceBlock(in: appViewModelSource(), startingAt: "func applyImportedShareableConfiguration(", endingBefore: "private func nextSharedFilterName(")
        XCTAssertTrue(apply.contains("expectedConfigurationGeneration: previousConfiguration.configurationGeneration"))
        XCTAssertTrue(apply.contains("expectedConfigurationGeneration: failedGeneration"))
        XCTAssertTrue(apply.contains("publicationStarted, configurationReplacementGate.isCurrent(importToken)"))
        XCTAssertTrue(apply.contains("configuration = failedConfiguration"))
        XCTAssertTrue(apply.contains("preparedSnapshot: previousSnapshot"))
    }

    /// The in-memory guard is a snapshot; the write needs the on-disk answer.
    ///
    /// A headless Focus/Shortcut switch commits from another process and the foreground adopts it
    /// asynchronously off a Darwin notification, so `library.activeFilterID` can name the previous
    /// filter while disk names the new one. The library-only replace would then overwrite a live
    /// filter — skipping the destructive confirmation AND clobbering the newer switch — so the
    /// question is re-asked under the write lock, where the answer cannot change before the write.
    func testLibraryOnlyReplaceRefusesAnOnDiskActiveTarget() throws {
        let source = try appViewModelSource()
        let replace = try sourceBlock(
            in: source,
            startingAt: "func replaceFilterWithImportedShareableConfiguration(",
            endingBefore: "static func filterPreparationFailureMessage("
        )
        XCTAssertTrue(
            replace.contains("persistLibraryOnlyChange(rollingBackTo: previousLibrary, refusesIfOnDiskActiveFilterIs: id)"),
            "The non-active branch must fence its write on the PERSISTED active filter."
        )
        // And the precondition must actually reach the shared writer.
        XCTAssertTrue(source.contains("refusesIfOnDiskActiveFilterIs: refusesIfOnDiskActiveFilterIs"))
    }

    /// The library-only path keeps its rollback: no configuration to desync from.
    func testLibraryOnlyChangesStillRollBack() throws {
        let source = try appViewModelSource()
        XCTAssertTrue(
            source.contains("rollingBackTo previousLibrary: FilterLibrary"),
            "Rollback is correct precisely where only the library moved."
        )
    }

    // MARK: The share card

    func testShareSheetUsesLeadingCloseAndTrailingShare() throws {
        let source = try readSource(.reactNativeReviewNavigation)
        XCTAssertTrue(source.contains("['ShareDetail', Screens.ShareDetailScreen"))
        XCTAssertTrue(source.contains("unstable_headerLeftItems"))
        XCTAssertTrue(source.contains("toolbarAction('Close'"))
    }

    func testCardAndOnScreenCodeEncodeTheSameDualUseLink() throws {
        let queries = try readSource(.reactNativeAppQueries)
        XCTAssertTrue(queries.contains("return try await shareCardQuery(input)"))
        let source = try readSource(.reactNativeAppShareCard)
        XCTAssertTrue(source.contains("ShareableFilterLink.url(forConfigurationCode: code)"))
        XCTAssertTrue(source.contains("ShareableFilterCardRenderer.qrImage(for: basis.payload)"))
        XCTAssertTrue(source.contains("\"url\": basis.payload"))
        XCTAssertTrue(source.contains("\"payload\": basis.payload"))
        XCTAssertTrue(source.contains("\"code\": basis.configurationCode"))
    }

    func testOnlyTheImageIsShared() throws {
        let bridge = try readSource(.reactNativeAppBridge)
        let ui = try readSource(.reactNativeAppShareCard)
        XCTAssertTrue(bridge.contains("try shareMountedCard(input)"))
        XCTAssertFalse(bridge.contains("ShareableFilterCardRenderer.render"))
        XCTAssertTrue(
            ui.contains("ShareSheetPresenter.present(image: image)"),
            "Sharing must offer the PNG alone — never the raw code or URL as a second item."
        )
        let presenter = try readSource(.activityViewController)
        XCTAssertTrue(presenter.contains("present(activityItems: [ShareCardActivityItemSource(image: image, title: title)]"))
        XCTAssertTrue(presenter.contains("self.title = title ?? \"Scan to import my Lava filter\".lavaLocalized"))
        XCTAssertTrue(presenter.contains("metadata.title = title"))
        XCTAssertTrue(presenter.contains("func activityViewController(_ activityViewController: UIActivityViewController, itemForActivityType activityType: UIActivity.ActivityType?) -> Any? { image }"))
        XCTAssertFalse(presenter.contains("metadata.imageProvider = NSItemProvider(object: image)"))
        XCTAssertFalse(presenter.contains("metadata.iconProvider = NSItemProvider(object: image)"))
        // Presenting via a SwiftUI .sheet renders an empty sheet — verified twice in
        // the simulator. The share sheet must come off the topmost controller.
        XCTAssertFalse(ui.contains("isPresentingShareSheet"))
    }

    func testOversizePayloadWithholdsTheCardInsteadOfShrinkingIt() throws {
        let source = try readSource(.reactNativeAppShareCard)
        XCTAssertTrue(source.contains("var card: Any = NSNull()"))
        XCTAssertTrue(source.contains("if let matrix = LavaShareQrMatrix.encode(basis.payload)"))
        XCTAssertTrue(source.contains("shareCardAuthority.retire()"))
        XCTAssertTrue(source.contains("LavaShareCardSurfaceRegistry.shared.retire()"))
        let capture = try readSource(.reactNativeShareCardCapture)
        XCTAssertTrue(capture.contains("for level in [\"Q\", \"M\", \"L\"]"))
        XCTAssertTrue(capture.contains("generator.message = Data(payload.utf8)"))
        XCTAssertFalse(capture.contains("payload.prefix"))
    }

    func testShippingCardCapturesNormalFabricChildrenWithExactNativeTokenAndQrPixels() throws {
        let native = try readSource(.reactNativeAppShareCard)
        XCTAssertTrue(native.contains("let token = input[\"token\"] as? String"))
        XCTAssertTrue(native.contains("shareCardAuthority.admits(token: token, basis: basis)"))
        XCTAssertTrue(native.contains("LavaShareCardSurfaceRegistry.shared.capture(token: token"))
        XCTAssertTrue(native.contains("guard current() else"))
        XCTAssertFalse(native.contains("ShareableFilterCardRenderer.render"))
        let surface = try readSource(.reactNativeShareCardSurface)
        XCTAssertFalse(surface.contains("self.contentView ="))
        XCTAssertTrue(surface.contains("updateWithView:self"))
        XCTAssertTrue(surface.contains("removeWithView:self"))
        let capture = try readSource(.reactNativeShareCardCapture)
        for required in ["weak var view: UIView?", "entry.ready", "view.window === window",
                         "pixels.width == 1080", "pixels.height == 1350",
                         "qr.matchesCapturedPixels(pixels", "entry.ready, qr.prepareForCapture"] {
            XCTAssertTrue(capture.contains(required), required)
        }
        let providers = try readSource(.reactNativePackage)
        XCTAssertTrue(providers.contains("\"LavaShareCardSurface\": \"LavaShareCardSurfaceView\""))
        XCTAssertTrue(providers.contains("\"LavaShareQr\": \"LavaShareQrView\""))
        XCTAssertTrue(try readSource(.reactNativeShareQrSpec).contains("moduleCount: CodegenTypes.Int32"))
        XCTAssertTrue(try readSource(.reactNativeAppGenerator).contains("tests/share-card/LavaRNShareCardTests.swift"))
    }

    func testCardRendererNeverTrimsThePayloadToFit() throws {
        let card = try readSource(.shareableFilterCardSupport)
        // Stepping down changes only the correction level, never the bytes encoded.
        XCTAssertTrue(card.contains("static let correctionLevels = [\"Q\", \"M\", \"L\"]"))
        XCTAssertTrue(card.contains("LavaQRCode.image(for: string, correctionLevel: level)"))
        XCTAssertFalse(
            card.contains("prefix("),
            "Nothing in the card path may truncate a payload."
        )
    }

    func testReactCardCarriesRecipientCopyAndNoSenderSuppliedName() throws {
        let card = try readSource(.reactNativeFilterShareCard)
        for copy in [
            "Shared filter",
            "Scan to import — or to get Lava first",
            "New? Install, finish setup, then scan again.",
            "Shared by another person. Not reviewed by Lava Security."
        ] {
            XCTAssertTrue(card.contains(copy), "card missing recipient copy: \(copy)")
        }
        // The disclosure names the company, not the shorthand: "Lava" alone reads as a
        // feature on a card a stranger may be seeing the brand on for the first time.
        XCTAssertFalse(
            card.contains("Not reviewed by Lava.\""),
            "The provenance line must spell out the full brand."
        )
        // The card describes the payload only in counts it derived itself.
        XCTAssertFalse(
            card.contains("filter.name"),
            "A sender-chosen name must never render on the card."
        )
    }

    func testCardSummaryCountsAreDerivedNotSenderSupplied() throws {
        let card = try readSource(.shareableFilterCardSupport)
        let summary = try sourceBlock(
            in: card,
            startingAt: "struct ShareableFilterCardSummary",
            endingBefore: "enum ShareableFilterCardRenderer"
        )
        // Custom sources ride inside enabledBlocklistIDs; counting them as curated
        // blocklists too would overstate what the card contains.
        XCTAssertTrue(summary.contains("subtracting(customIDs)"))
        XCTAssertTrue(summary.contains("configuration.blockedDomains.count"))
        XCTAssertTrue(summary.contains("configuration.customBlocklists.count"))
    }

    // MARK: Onboarding is not reachable, or completable, from a link

    func testNoDeepLinkCanCompleteOnboarding() throws {
        let root = try readSource(.rootView)
        let handler = try sourceBlock(
            in: root,
            startingAt: "private func handleDeepLink(",
            endingBefore: "private var importDeepLinkSheetItem:"
        )
        XCTAssertFalse(
            handler.contains("hasSeenLavaOnboarding = true"),
            "Setup is the one flow a link must never complete — not even as a side effect."
        )
    }

    func testNoExternalEntryPointCompletesOnboarding() throws {
        let root = try readSource(.rootView)

        // Broader than the deeplink handler on purpose: the earlier pin only covered
        // handleDeepLink, and a notification handler was quietly completing setup the
        // same way. Every assignment in this file is enumerated and justified here, so
        // a new external entry point cannot add one unnoticed.
        let assignments = root.components(separatedBy: "hasSeenLavaOnboarding = true").count - 1
        XCTAssertEqual(
            assignments, 1,
            """
            Only the debug rage-shake launch argument may assign completion here. \
            The authorized RN onboarding command owns real completion. \
            Any additional assignment is an external trigger completing setup.
            """
        )

        // Only the current native onboarding visit may complete setup.
        let onboarding = try readSource(.reactNativeAppOnboarding)
        let completion = try sourceBlock(in: onboarding, startingAt: "case \"onboarding.complete\":", endingBefore: "case \"onboarding.dismiss\":")
        XCTAssertTrue(completion.contains("visit.state.page == .done, visit.phase == \"released\""))
        XCTAssertTrue(completion.contains("if !visit.mock { UserDefaults.standard.set(true, forKey: \"hasSeenLavaOnboarding\") }"))
        // The debug path is gated behind a launch argument, never reachable in a
        // shipped build.
        XCTAssertTrue(root.contains("didHandleDebugLaunchRageShake = true"))

        // Notification-driven navigation must not be one of them.
        let notificationHandler = try sourceBlock(
            in: root,
            startingAt: ".lavaOpenGuardFromNotification",
            endingBefore: ".lavaOpenDeepLinkURL"
        )
        XCTAssertFalse(
            notificationHandler.contains("hasSeenLavaOnboarding = true"),
            "Tapping a notification must navigate, never complete setup."
        )
        XCTAssertTrue(notificationHandler.contains("selectedRootTab = .guardPanel"))
    }

    func testPreOnboardingPayloadIsDiscardedNotQueued() throws {
        let root = try readSource(.rootView)
        let handler = try sourceBlock(
            in: root,
            startingAt: "private func handleDeepLink(",
            endingBefore: "private var importDeepLinkSheetItem:"
        )
        XCTAssertTrue(handler.contains("if case .sharedConfiguration = entry, !hasSeenLavaOnboarding {"))
        XCTAssertTrue(handler.contains("isShowingFinishSetupBeforeImportNotice = true"))

        // The notice state is a bare Bool. If it ever carried the configuration, the
        // payload would survive onboarding and could resurface unrequested.
        XCTAssertTrue(
            root.contains("@State private var isShowingFinishSetupBeforeImportNotice = false"),
            "The pre-onboarding notice must hold no payload to replay."
        )
        for persistence in ["UserDefaults", "pendingImport", "queuedConfiguration"] {
            XCTAssertFalse(
                handler.contains(persistence),
                "A pre-onboarding payload must not be persisted or queued (\(persistence))."
            )
        }
    }

    func testOnboardingOffersNoImportRoute() throws {
        let onboarding = try [readSource(.reactNativeOnboardingFlow), readSource(.reactNativeAppOnboarding)].joined(separator: "\n")
        XCTAssertTrue(onboarding.contains("export function OnboardingFlow()"))
        XCTAssertTrue(onboarding.contains("case \"onboarding.complete\":"))
        XCTAssertFalse(onboarding.contains("ImportFiltersFlow"))
        XCTAssertFalse(onboarding.contains("type:'native.flow'"))
        XCTAssertFalse(onboarding.contains("startMode: .scanCode"))
        XCTAssertFalse(onboarding.contains("startMode: .enterCode"))
    }

    func testSharedConfigurationOpensDirectlyAtTheReview() throws {
        let root = try readSource(.rootView)
        XCTAssertTrue(root.contains("return .review(configuration)"))
        let native = try readSource(.reactNativeAppImport)
        XCTAssertTrue(native.contains("case .review(let configuration): self = .confirm(configuration)"))
    }

    func testNamingStageIsGone() throws {
        let ui = try readSource(.shareableFiltersUI)
        XCTAssertFalse(ui.contains("case nameNew("))
        XCTAssertFalse(
            ui.contains("ImportNameNewFilterView"),
            "The sender-named-filter screen is removed; names are derived by AppViewModel."
        )
    }

    // MARK: The second gate before the filter in effect changes

    func testSelectingTheActiveTargetOnlyStagesIt() throws {
        let native = try readSource(.reactNativeAppImport)
        let chooser = try sourceBlock(in: native, startingAt: "func chooseTarget(", endingBefore: "func add()")
        XCTAssertTrue(chooser.contains("go(to: .reviewReplacement("))
        XCTAssertFalse(chooser.contains("replace("))
        let review = try sourceBlock(in: native, startingAt: "func replaceReviewed()", endingBefore: "func confirmActiveReplacement(")
        XCTAssertTrue(review.contains("target.id == viewModel.library.activeFilterID"))
        XCTAssertTrue(review.contains("pendingActiveReplacement = PendingActiveReplacement("))
    }

    /// The selection-time check is a snapshot taken before an `await`.
    ///
    /// Authentication sits between choosing a target and replacing it, and a Focus or
    /// shortcut switch commits from another process — so a filter that was inactive
    /// when the user picked it can be the live one by the time the replace runs.
    /// Acting on the stale answer would change what is protecting the device having
    /// shown only the ordinary confirmation.
    func testActiveReplacementIsRecheckedAfterAuthentication() throws {
        let native = try readSource(.reactNativeAppImport)
        let replace = try sourceBlock(in: native, startingAt: "private func replace(", endingBefore: "func pickPhoto()")
        XCTAssertTrue(sourceContainsInOrder(["await authorizeImport()", "filter.id != viewModel.library.activeFilterID", "replaceFilterWithImportedShareableConfiguration("], in: replace))
        XCTAssertTrue(replace.contains("pendingActiveReplacement = PendingActiveReplacement("))
        XCTAssertTrue(replace.contains("confirmedActiveReplacement || filter.id !="))
    }

    /// Consent to replacing the filter in effect exists in exactly one place.
    func testOnlyTheDestructiveConfirmationSetsTheConfirmedFlag() throws {
        let code = sourceExcludingComments(try readSource(.reactNativeAppImport))
        XCTAssertEqual(sourceOccurrenceCount(of: "confirmedActiveReplacement: true", in: code), 1)
    }

    /// Defence in depth: the boundary re-reads rather than trusting its caller.
    func testActiveReplacementIsRefusedWithoutConfirmationAtTheBoundary() throws {
        let source = try appViewModelSource()
        let replace = try sourceBlock(
            in: source,
            startingAt: "func replaceFilterWithImportedShareableConfiguration(",
            endingBefore: "// Non-active: library-only replace."
        )
        XCTAssertTrue(
            replace.contains("guard confirmedActiveReplacement || id != library.activeFilterID else {"),
            "The model must not depend on a UI branch taken before an await."
        )
        let guardIndex = try XCTUnwrap(
            replace.range(of: "guard confirmedActiveReplacement ||")
        ).lowerBound
        let applyIndex = try XCTUnwrap(
            replace.range(of: "applyImportedShareableConfiguration(")
        ).lowerBound
        XCTAssertLessThan(guardIndex, applyIndex, "Refuse before the live apply path, not after.")
    }

    func testInactiveTargetsUseTheReviewStageWithoutActiveConfirmation() throws {
        let native = try readSource(.reactNativeAppImport)
        XCTAssertTrue(native.contains("else { replace(configuration, originalConfiguration: original, into: target) }"))
    }

    func testOnlyTheDestructiveConfirmationRunsTheActiveReplacement() throws {
        let native = try readSource(.reactNativeAppImport)
        let consent = try sourceBlock(in: native, startingAt: "func confirmActiveReplacement(", endingBefore: "func clearAlert()")
        XCTAssertTrue(consent.contains("confirmed.id.uuidString == token"))
        XCTAssertTrue(consent.contains("confirmedActiveReplacement: true"))
        XCTAssertTrue(native.contains("This changes the filter protecting this device."))
        XCTAssertTrue(native.contains("keeps its name and receives the reviewed content"))
    }

    func testCancellingTheDestructiveConfirmationMutatesNothing() throws {
        let native = try readSource(.reactNativeAppImport)
        let cancel = try sourceBlock(in: native, startingAt: "func clearAlert()", endingBefore: "func finishImport()")
        XCTAssertTrue(cancel.contains("pendingActiveReplacement = nil"))
        for forbidden in ["replace(", "authorizeImport", "viewModel."] { XCTAssertFalse(cancel.contains(forbidden)) }
    }

    func testFreshAuthStillPrecedesEveryReplacement() throws {
        let native = try readSource(.reactNativeAppImport)
        let replace = try sourceBlock(in: native, startingAt: "private func replace(", endingBefore: "func pickPhoto()")
        XCTAssertTrue(sourceContainsInOrder(["await authorizeImport()", "guard ownsFlow()", "replaceFilterWithImportedShareableConfiguration("], in: replace))
    }

    // MARK: Same-device photo import

    func testPhotoImportUsesThePickerNotBroadLibraryAccess() throws {
        let native = try readSource(.reactNativeAppImport)
        XCTAssertTrue(native.contains("PHPickerViewController(configuration:"))
        XCTAssertTrue(native.contains("config.filter = .images; config.selectionLimit = 1"))
        XCTAssertTrue(native.contains("provider.loadFileRepresentation("))
        XCTAssertTrue(sourceContainsInOrder(["SharedFilterImageLimits.validate(byteCount:", "PrivateImportFiles.copy(url)"], in: native))
        XCTAssertFalse(native.contains("PHPhotoLibrary.requestAuthorization"))
        XCTAssertFalse(try readSource(.appInfoPlist).contains("NSPhotoLibraryUsageDescription"))
    }

    func testPhotoDecoderIsQROnlyAndBoundedBeforeAnyDecode() throws {
        let decoder = try readSource(.shareableFilterImageDecoder)
        XCTAssertTrue(decoder.contains("request.symbologies = [.qr]"))
        XCTAssertTrue(
            decoder.contains("SharedFilterImageLimits.validate(byteCount:"),
            "Untrusted image bytes must be bounded before anything is decoded."
        )
        XCTAssertTrue(
            decoder.contains("SharedFilterImageLimits.validate(pixelWidth:"),
            "A small file can declare a huge bitmap, so dimensions are the real bound."
        )
        XCTAssertTrue(
            decoder.contains("CGImageSourceCreateThumbnailAtIndex"),
            "The bounded bitmap must come from ImageIO, not a resize after the fact."
        )
        // Comments stripped: the decoder's own rationale names the banned call.
        XCTAssertFalse(
            sourceExcludingComments(decoder).contains("UIImage(data:"),
            "UIImage(data:) then .cgImage decodes at full resolution first, which "
                + "defeats both caps — that is the defect this pin exists to hold shut."
        )
        XCTAssertTrue(
            decoder.contains("Task.detached"),
            "Detection must run off the main actor."
        )
    }

    /// Census across every import origin, not a spot-check of one.
    ///
    /// The predecessor of this pin asserted the same property for the photo decoder
    /// alone, and so could not see that the camera and manual-entry origins each
    /// called the raw-code parser directly — which made Lava reject the very QR
    /// codes it generates. Scoped pins keep missing their twins; this one enumerates.
    func testEveryImportOriginFunnelsThroughTheLinkParser() throws {
        let native = try readSource(.reactNativeAppImport)
        XCTAssertTrue(native.contains("try ShareableFilterLink.decode(scanned)"))
        XCTAssertTrue(native.contains("try ShareableFilterLink.decode(enteredCode)"))
        for origin in [SourceFile.reactNativeAppImport, .shareableFilterImageDecoder] { XCTAssertFalse(sourceExcludingComments(try readSource(origin)).contains("ShareableFilterConfiguration.decode(")) }
        XCTAssertTrue(try readSource(.shareableFilterImageDecoder).contains("ShareableFilterLink.decode(payload)"))
    }

    /// A link-parser error must not flatten into the generic message.
    func testImportMessagesUnwrapTheLinkParserError() throws {
        let ui = try readSource(.shareableFiltersUI)
        let messages = try sourceBlock(
            in: ui,
            startingAt: "enum ShareableFilterImportMessages {",
            endingBefore: "private static func message(forCode"
        )
        XCTAssertTrue(
            messages.contains("as? ShareableFilterInputError"),
            "Without unwrapping, an edited code would stop saying 'ask for a fresh one'."
        )
        XCTAssertTrue(messages.contains("case .configurationCode(let codeError):"))
    }

    func testPhotoDecoderDedupesAndRefusesAmbiguity() throws {
        let decoder = try readSource(.shareableFilterImageDecoder)
        // Vision can report one physical code twice; dedupe so a single code cannot
        // masquerade as an ambiguous pair.
        XCTAssertTrue(decoder.contains("seenPayloads.insert(payload).inserted"))
        XCTAssertTrue(decoder.contains("throw ShareableFilterImageDecodeError.noLavaFilterQRCode"))
        XCTAssertTrue(decoder.contains("throw ShareableFilterImageDecodeError.ambiguousLavaFilterQRCodes"))
        XCTAssertTrue(
            decoder.contains("guard configurations.count == 1"),
            "Two distinct valid payloads must be refused, never silently resolved."
        )
    }

    func testPhotoImportJoinsTheSameReviewStage() throws {
        let native = try readSource(.reactNativeAppImport)
        let photo = try sourceBlock(in: native, startingAt: "func pickPhoto()", endingBefore: "extension LavaAppBridge")
        XCTAssertTrue(photo.contains("self.go(to: .confirm(configuration))"))
        XCTAssertTrue(photo.contains("self.stageID == token"))
        XCTAssertTrue(photo.contains("!self.isRetired, self.ownsFlow()"))
    }

    func testStageChangesAndPrivacyRetirementReleaseTheNativePhotoOwner() throws {
        let native = try readSource(.reactNativeAppImport)
        let transition = try sourceBlock(in: native, startingAt: "func go(to requestedStage:", endingBefore: "func begin()")
        XCTAssertTrue(sourceContainsInOrder(["retirePhotoSelection()", "stageID = UUID()"], in: transition))
        let cleanup = try sourceBlock(in: native, startingAt: "private func retirePhotoSelection()", endingBefore: "func pickPhoto()")
        XCTAssertTrue(cleanup.contains("photoLifetime.cancel()"))
        XCTAssertTrue(cleanup.contains("photoPicker?.retire(); photoPicker = nil"))
        let retirement = try sourceBlock(in: native, startingAt: "func concealAcceptedPresentation()", endingBefore: "func trackUpgrade(")
        XCTAssertEqual(sourceOccurrenceCount(of: "retirePhotoSelection()", in: retirement), 2)
        let photo = try sourceBlock(in: native, startingAt: "func pickPhoto()", endingBefore: "extension LavaAppBridge")
        XCTAssertTrue(sourceContainsInOrder(["self.ownsFlow()", "self.stageID == token", "self.photoLifetime.finish(request)", "self.go(to: .confirm(configuration))"], in: photo))
    }

    func testPayloadReviewRootCanCloseWithoutRestagingItsOwnPayload() throws {
        let native = try readSource(.reactNativeAppImport)
        let root = try sourceBlock(in: native, startingAt: "var closeAtRoot: Bool", endingBefore: "func go(to requestedStage:")
        XCTAssertTrue(root.contains("if case .confirm = stage, case .review = startMode { return true }"))
        XCTAssertTrue(native.contains("\"closeAtRoot\": owner.closeAtRoot"))
        let back = try sourceBlock(in: native, startingAt: "func back()", endingBefore: "func changeCode(")
        XCTAssertTrue(back.contains("if case .review = startMode { dismiss() }"))
        XCTAssertTrue(back.contains("guard canDismiss else { return }"))
    }

    func testApplyPathStillClaimsTheSupersessionGate() throws {
        let source = try appViewModelSource()
        let apply = try sourceBlock(
            in: source,
            startingAt: "func applyImportedShareableConfiguration(",
            endingBefore: "/// The next free localized `Shared filter` name."
        )
        // Adding the rename must not have weakened the existing ownership guards.
        XCTAssertTrue(apply.contains("let importToken = configurationReplacementGate.begin()"))
        XCTAssertEqual(
            apply.components(separatedBy: "configurationReplacementGate.isCurrent(importToken)").count - 1,
            5,
            "Ownership is rechecked before commit, after persist/notification/restore, and before rollback."
        )
    }
}
