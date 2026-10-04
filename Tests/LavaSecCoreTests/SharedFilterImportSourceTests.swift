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
        let source = try readSource(.shareableFiltersUI)
        let finish = try sourceBlock(in: source, startingAt: "private func finishImport()", endingBefore: "private func go(to newStage:")
        XCTAssertTrue(finish.contains("guard case .completed = stage else { return }"))
        XCTAssertTrue(finish.contains("if completion.acknowledge() { onImported?() }"))
        XCTAssertTrue(finish.contains("dismiss()"))
        let completion = try sourceBlock(in: source, startingAt: "final class ImportFiltersCompletion:", endingBefore: "struct ImportFiltersFlow:")
        XCTAssertTrue(completion.contains("guard filterName != nil, !acknowledged else { return false }"))
        XCTAssertTrue(completion.contains("acknowledged = true"))
        let add = try sourceBlock(in: source, startingAt: "private func addNew(", endingBefore: "private func replace(")
        XCTAssertTrue(add.contains("completion.recordCommittedFilter(named: saved.name, unavailableListCount: plan.droppedCount(of: .unavailableBlocklist))"))
        XCTAssertTrue(add.contains("go(to: .completed(filterName: saved.name))"))
        XCTAssertFalse(add.contains("dismiss()"))
    }

    func testCommittedResultSurvivesNativeFlowRecreationButImportDraftDoesNot() throws {
        let ui = try readSource(.shareableFiltersUI)
        let flows = try readSource(.reactNativeAppFlows)
        let host = try readSource(.reactNativeAppHost)
        let completion = try sourceBlock(in: ui, startingAt: "final class ImportFiltersCompletion:", endingBefore: "struct ImportFiltersFlow:")
        XCTAssertTrue(completion.contains("@Published private(set) var filterName: String?"))
        XCTAssertTrue(completion.contains("guard filterName == nil else { return }"))
        let initializer = try sourceBlock(in: completion, startingAt: "final class ImportFiltersCompletion:", endingBefore: "func recordCommittedFilter")
        XCTAssertFalse(initializer.contains("LavaFeedbackCoordinator.shared.begin"),
                       "Discarded SwiftUI state initializers must not invalidate an active import's feedback lane.")
        let commit = try sourceBlock(in: completion, startingAt: "func recordCommittedFilter", endingBefore: "func acknowledge")
        XCTAssertTrue(commit.contains("LavaFeedbackCoordinator.shared.begin(\"filter.import\")"))
        for privateDraft in ["ShareableFilterConfiguration", "ImportFiltersStartMode", "Stage", "QRCodeScanner", "enteredCode"] {
            XCTAssertFalse(completion.contains(privateDraft), "The owner must not retain \(privateDraft) across privacy teardown.")
        }
        XCTAssertTrue(flows.contains("var importCompletion = ImportFiltersCompletion()"))
        XCTAssertEqual(flows.components(separatedBy: "completion: flow.importCompletion").count - 1, 2,
                       "Method/code/scanner and deep-link import must share the same result owner.")
        XCTAssertTrue(ui.contains("_completion = StateObject(wrappedValue: completion)"))
        XCTAssertTrue(ui.contains("completion.filterName.map { .completed(filterName: $0) } ?? Stage(startMode: startMode)"),
                      "Recreation resumes only a confirmed result; an uncommitted importer starts afresh.")
        XCTAssertTrue(ui.contains(".onChange(of: completion.filterName, initial: true)"),
                      "A commit finishing after recreation must still reach the new terminal screen.")
        let replace = try sourceBlock(in: ui, startingAt: "let result = await viewModel.replaceFilterWithImportedShareableConfiguration(", endingBefore: "// MARK: Method chooser")
        XCTAssertTrue(replace.contains("case .success:\n                let filterName"))
        XCTAssertTrue(replace.contains("completion.recordCommittedFilter(named: filterName, unavailableListCount: unavailableListCount)"))
        let failed = try sourceBlock(in: replace, startingAt: "case .failure(let message):", endingBefore: "\n            }")
        XCTAssertFalse(failed.contains("recordCommittedFilter"))
        XCTAssertTrue(flows.contains("if flow.isImport && (security.isAppUnlockBlockingUI || security.isAppUnlockPrivacyMaskVisible)"))
        XCTAssertTrue(flows.contains("Color.clear"))
        XCTAssertTrue(host.contains("let desiredFlow = withholdImport ? nil : pendingFlow"))
        XCTAssertTrue(host.contains("if withholdImport && presentedFlowID == pendingFlow?.id { controller.onDismiss = nil }"))
    }

    func testEveryImportEntryRetainsCompletionAbovePrivacyTeardown() throws {
        let source = try readSource(.reactNativeAppFlows)
        XCTAssertTrue(source.contains("completion: flow.importCompletion"))
        XCTAssertTrue(source.contains("requireFreshAuthentication(for: .filterEditing"))
    }

    func testReplacementReviewShowsRemovalsAndRechecksItsBasisAfterAuth() throws {
        let ui = try readSource(.shareableFiltersUI)
        let chooser = try sourceBlock(in: ui, startingAt: "case .chooseReplace(let config):", endingBefore: "case .applying:")
        XCTAssertTrue(chooser.contains("go(to: .reviewReplacement("))
        XCTAssertTrue(chooser.contains("viewModel.importPlan(for: config).applied"))
        XCTAssertTrue(ui.contains("case reviewReplacement("))
        XCTAssertTrue(ui.contains("struct ImportReplacementReviewView"))
        let message = try sourceBlock(in: ui, startingAt: "private func replacementConfirmationMessage(", endingBefore: "private func addNew(")
        for field in ["addedBlocklistIDs", "addedBlockedDomains", "addedCustomBlocklists", "addedAllowedDomains"] {
            XCTAssertTrue(message.contains(field))
        }
        for field in ["removedBlocklistIDs", "removedBlockedDomains", "removedCustomBlocklists", "removedAllowedDomains"] {
            XCTAssertTrue(ui.contains(field))
        }
        let replace = try sourceBlock(in: ui, startingAt: "private func replace(", endingBefore: "// MARK: Method chooser")
        let auth = try XCTUnwrap(replace.range(of: "await authorizeImport()"))
        let basis = try XCTUnwrap(replace.range(of: "current.strippingLocalCacheState() == filter.strippingLocalCacheState()"))
        let apply = try XCTUnwrap(replace.range(of: "replaceFilterWithImportedShareableConfiguration("))
        XCTAssertLessThan(auth.lowerBound, basis.lowerBound)
        XCTAssertLessThan(basis.lowerBound, apply.lowerBound)
        XCTAssertTrue(replace.contains("viewModel.importPlan(for: originalConfiguration).applied == config"))
    }

    func testReplacementBackNavigationKeepsTheOriginalSharePayload() throws {
        let ui = try readSource(.shareableFiltersUI)
        let chooser = try sourceBlock(in: ui, startingAt: "case .chooseReplace(let config):", endingBefore: "case .applying:")
        XCTAssertTrue(chooser.contains("onBack: { go(to: .confirm(config)) }"))
        XCTAssertTrue(chooser.contains(".reviewReplacement(original: config"))
        XCTAssertTrue(chooser.contains("onBack: { go(to: .chooseReplace(original)) }"))
        let replace = try sourceBlock(in: ui, startingAt: "private func replace(", endingBefore: "// MARK: Method chooser")
        XCTAssertTrue(replace.contains("go(to: .chooseReplace(originalConfiguration))"))
        XCTAssertFalse(replace.contains("go(to: .chooseReplace(config))"))
        XCTAssertTrue(ui.contains("originalConfiguration: confirmed.originalConfiguration"))
    }

    func testCompletionPushesForwardAndCannotReplayACommittedImport() throws {
        let ui = try readSource(.shareableFiltersUI)
        let completion = try sourceBlock(in: ui, startingAt: "final class ImportFiltersCompletion:", endingBefore: "struct ImportFiltersFlow:")
        XCTAssertTrue(completion.contains("guard filterName == nil else { return }"))
        XCTAssertTrue(completion.contains("guard filterName != nil, !acknowledged else { return false }"))
        XCTAssertTrue(ui.contains("completion.recordCommittedFilter(named: saved.name, unavailableListCount: plan.droppedCount(of: .unavailableBlocklist))"))
        XCTAssertTrue(ui.contains("completion.recordCommittedFilter(named: filterName, unavailableListCount: unavailableListCount)"))
        XCTAssertTrue(ui.contains("if completion.acknowledge() { onImported?() }"))
        XCTAssertTrue(ui.contains(".interactiveDismissDisabled(stage.transitionID == \"applying\" || stage.transitionID == \"completed\")"))
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
        XCTAssertTrue(source.contains("toolbarButton('Close'"))
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
        XCTAssertTrue(presenter.contains("present(activityItems: [ShareCardActivityItemSource(image: image)]"))
        XCTAssertTrue(presenter.contains("metadata.title = \"Scan to import my Lava filter\".lavaLocalized"))
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
        let card = try readSource(.shareableFilterCard)
        // Stepping down changes only the correction level, never the bytes encoded.
        XCTAssertTrue(card.contains("static let correctionLevels = [\"Q\", \"M\", \"L\"]"))
        XCTAssertTrue(card.contains("LavaQRCode.image(for: string, correctionLevel: level)"))
        XCTAssertFalse(
            card.contains("prefix("),
            "Nothing in the card path may truncate a payload."
        )
    }

    func testCardIsDeterministicAndSizedForMessaging() throws {
        let card = try readSource(.shareableFilterCard)
        XCTAssertTrue(card.contains("static let pointSize = CGSize(width: 360, height: 450)"))
        XCTAssertTrue(card.contains("static let renderScale: CGFloat = 3"))
        // The code is sized against the quiet-zone ceiling, not by eye: the card's
        // own white margin must hold four modules on every side.
        XCTAssertTrue(card.contains("static let maximumQRSide: CGFloat = 294"))
        XCTAssertTrue(card.contains("static let horizontalMargin: CGFloat = 33"))
        // The code must be the FLEXIBLE element. A fixed frame here previously
        // overflowed the 450pt card and pushed the provenance line off the bottom.
        XCTAssertTrue(card.contains(".aspectRatio(1, contentMode: .fit)"))
        XCTAssertTrue(card.contains(".frame(maxWidth: ShareableFilterCardRenderer.maximumQRSide)"))
        XCTAssertFalse(
            card.contains("Spacer("),
            "Fixed-height gaps only: a Spacer would let the code push fixed rows out of frame."
        )
        XCTAssertTrue(
            card.contains(".interpolation(.none)"),
            "Smoothed modules are the classic cause of an unscannable exported code."
        )
        XCTAssertTrue(card.contains(".background(.white)"))
    }

    /// The quiet zone must be four modules on EVERY side, not just the two the page
    /// margin happens to cover.
    ///
    /// The original card satisfied it horizontally (33pt margin) and left roughly a
    /// third of the requirement vertically, where the neighbours are a summary chip
    /// and a line of instruction text. A valid code that a camera cannot read after
    /// a messenger recompresses it is the one failure this feature cannot absorb.
    func testCardReservesTheQuietZoneVerticallyToo() throws {
        let card = try readSource(.shareableFilterCard)
        XCTAssertTrue(
            card.contains(".padding(.vertical, verticalQuietZone)"),
            "The code needs explicit vertical clear space; no page margin supplies it."
        )
        XCTAssertTrue(
            card.contains("SharedFilterCardQuietZone.additionalClearance(widestModule:"),
            "Clearance must come from the module width, not a hand-picked constant."
        )
        XCTAssertTrue(
            card.contains("moduleCount: LavaQRCode.moduleCount(of: qrImage)"),
            "Module count is measured from the generated code, not assumed per version."
        )

        // The ad-hoc gaps that used to sit between the chips, the code and the
        // instruction line are what made the clear space look adequate at a glance.
        // `qrField` owns the whole vertical zone so tidying a spacing constant cannot
        // quietly eat into it.
        let body = try sourceBlock(in: card, startingAt: "var body: some View {", endingBefore: "private var header:")
        XCTAssertTrue(body.contains("qrField\n"), "qrField must carry no external padding.")
        XCTAssertFalse(
            sourceExcludingComments(body).contains("qrField\n                    .padding"),
            "Vertical clear space must live inside qrField, not beside it."
        )
    }

    /// The bar bleeds to the top edge, and it can only do that if the frame anchors top.
    ///
    /// A centring frame — the default — splits the slack left over when the code hits its
    /// width cap, putting white above the bar. Caught on a zh-Hant device render, where
    /// shorter text metrics made the content's natural height fall furthest below 450.
    func testCardAnchorsContentToTheTopEdge() throws {
        let card = try readSource(.shareableFilterCard)
        let frame = try sourceBlock(
            in: card,
            startingAt: "width: ShareableFilterCardRenderer.pointSize.width,",
            endingBefore: ".background(.white)"
        )
        XCTAssertTrue(
            sourceExcludingComments(frame).contains("alignment: .top"),
            "Without a top anchor the ember bar stops bleeding to the edge."
        )
    }

    /// Export branding uses the original awake guardian and canonical light orange.
    /// The fixed appearance also keeps the exported image independent of app theme.
    func testCardUsesTheCanonicalShieldShapeAndFixedBrandOrange() throws {
        let card = try readSource(.shareableFilterCard)
        let code = sourceExcludingComments(card)

        XCTAssertTrue(code.contains("SoftShieldGuardian(size: 42, state: .awake, animates: false, shieldStyle: .original)"))
        XCTAssertTrue(code.contains(".environment(\\.colorScheme, .light)"))
        XCTAssertTrue(code.contains(".environment(\\.redactionReasons, [])"))
        XCTAssertFalse(
            code.contains("RoundedRectangle(cornerRadius: 4, style: .continuous)"),
            "The hand-drawn stand-in mascot must not come back."
        )

        // Exact token values, so a future nudge cannot drift the brand by eye.
        XCTAssertTrue(
            code.contains("ember = Color(red: 0.95, green: 0.34, blue: 0.18)"),
            "Fills carry LavaStyle.lavaOrange's light value."
        )
        XCTAssertFalse(
            code.contains("Color(red: 0.77, green: 0.38, blue: 0.18)"),
            "The invented off-token orange must not return."
        )
        XCTAssertTrue(
            code.contains("Text(verbatim: \"Lava Security\")")
                && code.contains(".foregroundColor(Self.ember)"),
            "The branded wordmark uses the same canonical orange as the top rule."
        )
    }

    func testCardCarriesRecipientCopyAndNoSenderSuppliedName() throws {
        let card = try readSource(.shareableFilterCard)
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
        let card = try readSource(.shareableFilterCard)
        let summary = try sourceBlock(
            in: card,
            startingAt: "struct ShareableFilterCardSummary",
            endingBefore: "struct ShareableFilterCard: View"
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
            The onboarding overlay owns real completion through its binding. \
            Any additional assignment is an external trigger completing setup.
            """
        )

        // The onboarding flow owns the completion binding; navigation cannot finish it.
        XCTAssertTrue(root.contains("LavaOnboardingView(hasSeenOnboarding: $hasSeenLavaOnboarding"))
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
        let onboarding = try readSource(.onboardingFlowView)
        XCTAssertFalse(onboarding.contains("ImportFiltersFlow"))
        XCTAssertFalse(onboarding.contains("startMode: .scanCode"))
        XCTAssertFalse(onboarding.contains("startMode: .enterCode"))
    }

    func testSharedConfigurationOpensDirectlyAtTheReview() throws {
        let root = try readSource(.rootView)
        XCTAssertTrue(root.contains("case .sharedConfiguration(let configuration):"))
        XCTAssertTrue(root.contains("return .review(configuration)"))

        let ui = try readSource(.shareableFiltersUI)
        // `.review` must land on the SAME confirm stage every other origin reaches.
        XCTAssertTrue(ui.contains("case .review(let configuration):"))
        XCTAssertTrue(ui.contains("self = .confirm(configuration)"))
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
        let ui = try readSource(.shareableFiltersUI)
        let chooser = try sourceBlock(in: ui, startingAt: "case .chooseReplace(let config):", endingBefore: "case .reviewReplacement(let original, let config, let filter):")
        XCTAssertTrue(chooser.contains("go(to: .reviewReplacement(original: config"))
        XCTAssertFalse(chooser.contains("replace("), "Selecting a target only opens the review stage.")
        let review = try sourceBlock(in: ui, startingAt: "case .reviewReplacement(let original, let config, let filter):", endingBefore: "case .applying:")
        XCTAssertTrue(review.contains("if filter.id == viewModel.library.activeFilterID"))
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
        let ui = try readSource(.shareableFiltersUI)
        let replace = try sourceBlock(
            in: ui,
            startingAt: "private func replace(",
            endingBefore: "// MARK: Method chooser"
        )
        let authIndex = try XCTUnwrap(replace.range(of: "await authorizeImport()")).lowerBound
        let recheckIndex = try XCTUnwrap(
            replace.range(of: "filter.id != viewModel.library.activeFilterID")
        ).lowerBound
        let applyIndex = try XCTUnwrap(
            replace.range(of: "replaceFilterWithImportedShareableConfiguration(")
        ).lowerBound
        XCTAssertLessThan(authIndex, recheckIndex, "The re-read must happen AFTER authentication.")
        XCTAssertLessThan(recheckIndex, applyIndex, "And before anything is replaced.")
        XCTAssertTrue(
            replace.contains("pendingActiveReplacement = PendingActiveReplacement("),
            "A target that became active must route to the destructive confirmation."
        )
        // Without the confirmed flag the confirmed path would re-stage itself forever.
        XCTAssertTrue(replace.contains("confirmedActiveReplacement || filter.id !="))
    }

    /// Consent to replacing the filter in effect exists in exactly one place.
    func testOnlyTheDestructiveConfirmationSetsTheConfirmedFlag() throws {
        let code = sourceExcludingComments(try readSource(.shareableFiltersUI))
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
        let ui = try readSource(.shareableFiltersUI)
        let chooser = try sourceBlock(in: ui, startingAt: "ImportChooseReplaceTargetView(", endingBefore: "case .applying:")
        XCTAssertTrue(chooser.contains("go(to: .reviewReplacement("))
        XCTAssertTrue(chooser.contains("if filter.id == viewModel.library.activeFilterID"))
        XCTAssertTrue(chooser.contains("replace(config, originalConfiguration: original, into: filter)"))
    }

    func testOnlyTheDestructiveConfirmationRunsTheActiveReplacement() throws {
        let ui = try readSource(.shareableFiltersUI)
        let alert = try sourceBlock(in: ui, startingAt: "get: { pendingActiveReplacement != nil }", endingBefore: ".lavaTier(.calm)")
        XCTAssertTrue(alert.contains("Button(\"Cancel\", role: .cancel)"))
        XCTAssertTrue(alert.contains("Button(\"Replace active filter\", role: .destructive)"))
        XCTAssertTrue(sourceContainsInOrder(["confirmed.configuration,", "into: confirmed.target,",
                                           "confirmedActiveReplacement: true"], in: alert))
        let message = try sourceBlock(in: ui, startingAt: "private func replacementConfirmationMessage(", endingBefore: "private func addNew(")
        XCTAssertTrue(message.contains("This changes the filter protecting this device."))
        XCTAssertTrue(message.contains("keeps its name and receives the reviewed content"))
    }

    func testCancellingTheDestructiveConfirmationMutatesNothing() throws {
        let ui = try readSource(.shareableFiltersUI)
        let alert = try sourceBlock(in: ui, startingAt: "get: { pendingActiveReplacement != nil }", endingBefore: ".lavaTier(.calm)")
        let cancel = try sourceBlock(in: alert, startingAt: "Button(\"Cancel\", role: .cancel)", endingBefore: "Button(\"Replace active filter\"")
        XCTAssertTrue(cancel.contains("pendingActiveReplacement = nil"))
        for forbidden in ["replace(", "authorizeImport", "viewModel."] {
            XCTAssertFalse(cancel.contains(forbidden), "Cancel must not \(forbidden)")
        }
    }

    func testFreshAuthStillPrecedesEveryReplacement() throws {
        let ui = try readSource(.shareableFiltersUI)
        let replace = try sourceBlock(
            in: ui,
            startingAt: "private func replace(",
            endingBefore: "\n}"
        )
        // The confirmation is an ADDITIONAL gate, not a substitute for fresh auth.
        XCTAssertTrue(replace.contains("guard await authorizeImport() else {"))
        let authIndex = try XCTUnwrap(replace.range(of: "authorizeImport()")).lowerBound
        let mutateIndex = try XCTUnwrap(
            replace.range(of: "replaceFilterWithImportedShareableConfiguration(")
        ).lowerBound
        XCTAssertLessThan(authIndex, mutateIndex, "Auth must precede the mutation.")
    }

    // MARK: Same-device photo import

    func testPhotoImportUsesThePickerNotBroadLibraryAccess() throws {
        let ui = try readSource(.shareableFiltersUI)
        XCTAssertTrue(ui.contains("PhotosPicker(selection: $photoItem, matching: .images"))
        // The picker runs out of process and returns only the chosen item, so Lava
        // never requests the whole library — and therefore ships no usage string.
        XCTAssertFalse(ui.contains("PHPhotoLibrary.requestAuthorization"))

        let infoPlist = try readSource(.appInfoPlist)
        XCTAssertFalse(
            infoPlist.contains("NSPhotoLibraryUsageDescription"),
            "PhotosPicker is the privacy boundary; a usage string would mean broad access."
        )
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
        for origin in [SourceFile.shareableFiltersUI, .shareableFilterImageDecoder] {
            let source = sourceExcludingComments(try readSource(origin))
            XCTAssertFalse(
                source.contains("ShareableFilterConfiguration.decode("),
                "\(origin.rawValue) must reach a configuration only via ShareableFilterLink."
            )
        }

        let ui = try readSource(.shareableFiltersUI)
        XCTAssertTrue(
            ui.contains("try ShareableFilterLink.decode(scanned)"),
            "Camera scans must accept the canonical link this app encodes."
        )
        XCTAssertTrue(
            ui.contains("try ShareableFilterLink.decode(enteredCode)"),
            "Pasted input must accept a link as readily as a bare code."
        )

        let decoder = try readSource(.shareableFilterImageDecoder)
        XCTAssertTrue(decoder.contains("ShareableFilterLink.decode(payload)"))
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
        let ui = try readSource(.shareableFiltersUI)
        XCTAssertTrue(
            ui.contains("onDecodedFromPhoto: { go(to: .confirm($0)) }"),
            "A photo is another way in, never a shortcut past the review."
        )
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
