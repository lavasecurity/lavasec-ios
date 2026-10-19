import XCTest

final class BackupRestoreReviewSourceTests: XCTestCase {
    func testUnlockOnlyPresentsReviewAndConfirmationIsASeparateAction() throws {
        let source = try readSource(.backupRestoreView)
        let prepare = try sourceBlock(in: source, startingAt: "func prepareRestore()", endingBefore: "func confirmRestore()")
        XCTAssertTrue(prepare.contains("backup.prepareEncryptedBackupRestore("))
        XCTAssertTrue(prepare.contains("review = prepared"))
        XCTAssertFalse(prepare.contains("confirmPreparedBackupRestore("))
        XCTAssertTrue(source.contains("backup.confirmPreparedBackupRestore(id: review.id, resolverChangeConfirmed: resolverChangeConfirmed)"))
    }

    func testReviewRendersBothSidesOfRecordingAndDNSChanges() throws {
        let source = try readSource(.backupRestoreView)
        XCTAssertTrue(source.contains("let a = plan.previousConfiguration, b = plan.configuration"))
        for field in ["keepFilteringCounts", "keepDomainDiagnostics", "keepNetworkActivity", "keepLavaGuardProgress"] {
            XCTAssertTrue(source.contains("a.\(field)")); XCTAssertTrue(source.contains("b.\(field)"))
        }
        XCTAssertTrue(source.contains("savedCustomDNS(a), savedCustomDNS(b)"))
        XCTAssertTrue(source.contains("c.customResolverName"))
        XCTAssertTrue(source.contains("c.fallbackCustomResolverName"))
        XCTAssertTrue(source.contains("!$0.plan.requiresResolverConfirmation || resolverChangeConfirmed"))
    }

    func testLibraryReviewShowsOrderEvenWhenPerFilterContentsAreUnchanged() throws {
        let source = try readSource(.backupRestoreView)
        XCTAssertTrue(source.contains("orderedFilters(plan.previousLibrary)"))
        XCTAssertTrue(source.contains("orderedFilters(plan.library)"))
        let order = try sourceBlock(in: source, startingAt: "private func orderedFilters(", endingBefore: "private func blocklistName(")
        XCTAssertTrue(order.contains("library.filters.enumerated()")); XCTAssertFalse(order.contains("sorted"))
    }

    func testReviewShowsUnlocksSeparatelyFromTheRecordingPreference() throws {
        let source = try readSource(.backupRestoreView)
        XCTAssertTrue(source.contains("unlocks(a.lavaGuardUnlocks), unlocks(b.lavaGuardUnlocks)"))
    }

    func testReviewUsesTheReviewedCustomNamesAndDisclosesContentVersionChanges() throws {
        let source = try readSource(.backupRestoreView)
        XCTAssertTrue(source.contains("blocklistName(for: $0, in: change.before)"))
        XCTAssertTrue(source.contains("blocklistName(for: $0, in: change.after)"))
        XCTAssertTrue(source.contains("if !change.changedCustomContentVersionIDs.isEmpty"))
        let name = try sourceBlock(in: source, startingAt: "private func blocklistName(",
                                    endingBefore: "private func domains(")
        let customName = try XCTUnwrap(name.range(of: "filter?.customBlocklists.first(where:")?.lowerBound)
        let fallback = try XCTUnwrap(name.range(of: "?? viewModel.blocklistName(for: id)")?.lowerBound)
        XCTAssertLessThan(customName, fallback)
    }

    func testCustomSourceReviewExposesTheParsingFormatOnBothSides() throws {
        let source = try readSource(.backupRestoreView)
        XCTAssertTrue(source.contains("$0.parseFormat.rawValue"))
        XCTAssertTrue(source.contains("customSources(change.before?.customBlocklists ?? [])"))
        XCTAssertTrue(source.contains("customSources(change.after?.customBlocklists ?? [])"))
    }

    func testReviewSeparatesDomainAdditionsAndRemovalsFromUnchangedEntries() throws {
        let source = try readSource(.backupRestoreView)
        for field in ["addedAllowedDomains", "removedAllowedDomains", "addedBlockedDomains", "removedBlockedDomains"] { XCTAssertTrue(source.contains("change.selectionDiff.\(field)")) }
        XCTAssertTrue(source.contains("if !added.isEmpty")); XCTAssertTrue(source.contains("if !removed.isEmpty"))
        XCTAssertTrue(source.contains("domains(Set(added))")); XCTAssertTrue(source.contains("domains(Set(removed))"))
    }

    func testRestorePersistsUnlockStateOnlyAfterApplyAndOwnershipChecks() throws {
        let source = try readSource(.backupController)
        let confirm = try sourceBlock(in: source, startingAt: "func confirmPreparedBackupRestore(",
                                      endingBefore: "func clearEncryptedBackup()")
        let checkpoint = try XCTUnwrap(confirm.range(of: "let checkpoint = backupEnvelopeStore.checkpoint()"))
        let stage = try XCTUnwrap(confirm.range(of: "try backupEnvelopeStore.saveEnvelope(acceptedEnvelope)"))
        let apply = try XCTUnwrap(confirm.range(of: "try await hub.applyReviewedBackup("))
        XCTAssertTrue(confirm.contains("try requireExplicitBackupSetupAllowed()"))
        XCTAssertTrue(confirm.contains("pending.lifecycleGeneration == lifecycleGeneration"))
        XCTAssertTrue(confirm.contains("pending.accountID == hub.currentBackupAccountID"))
        XCTAssertTrue(confirm.contains("isBackupMaintenanceInProgress = true"))
        XCTAssertTrue(confirm.contains("defer { isBackupMaintenanceInProgress = false }"))
        XCTAssertLessThan(checkpoint.lowerBound, stage.lowerBound)
        XCTAssertLessThan(apply.lowerBound, stage.lowerBound)
        XCTAssertTrue(confirm.contains("backupEnvelopeStore.clearUploadMarker()"))
        XCTAssertTrue(confirm.contains("ReviewedBackupApplyError.rejectedBeforeWrite(let underlying)"))
        XCTAssertTrue(confirm.contains("backupEnvelopeStore.checkpoint() == checkpoint"))
        XCTAssertTrue(confirm.contains("backupKeychainStore.loadDeviceSecret() == stagedSecret"))
        XCTAssertTrue(confirm.contains("backupKeychainStore.saveDeviceSecret(previousDeviceSecret)"))
        XCTAssertTrue(confirm.contains("backupKeychainStore.deleteDeviceSecret()"))
        XCTAssertTrue(confirm.contains("backupEnvelopeStore.restoreCheckpoint(checkpoint)"))
        let hub = try readAppViewModelSource()
        let restore = try sourceBlock(in: hub, startingAt: "func applyReviewedBackup(",
                                      endingBefore: "// MARK: - LavaSecurity+ hub bridge")
        XCTAssertTrue(restore.contains("if error is SharedFilterStatePersistence.StaleBaseGenerationError"))
        XCTAssertTrue(restore.contains("throw ReviewedBackupApplyError.rejectedBeforeWrite(error)"))
        let staleRejection = try sourceBlock(in: restore, startingAt: "if error is SharedFilterStatePersistence.StaleBaseGenerationError",
                                             endingBefore: "            throw error")
        XCTAssertTrue(staleRejection.contains("rejectedBeforeWrite(BackupRestorePlanError.staleReview)"))
    }

    func testRestorePublishesEnabledCacheAtTheSharedCommitBoundary() throws {
        let source = try readSource(.backupController)
        let commit = try sourceBlock(in: source,
                                     startingAt: "private func completeExplicitBackupEnablement()",
                                     endingBefore: "deinit {")
        XCTAssertTrue(commit.contains("isBackupEnabled = true"))
        let confirm = try sourceBlock(in: source, startingAt: "func confirmPreparedBackupRestore(",
                                      endingBefore: "func clearEncryptedBackup()")
        XCTAssertTrue(confirm.contains("try completeExplicitBackupEnablement()"))
    }

    func testDurableApplyFailurePreservesBackupCommitAndReportsPartialCompletion() throws {
        let hub = try readAppViewModelSource()
        let apply = try sourceBlock(in: hub, startingAt: "func applyReviewedBackup(",
                                    endingBefore: "// MARK: - LavaSecurity+ hub bridge")
        let durable = try sourceBlock(in: apply,
                                      startingAt: "if configuration.configurationGeneration > generationBeforeRestorePersist",
                                      endingBefore: "} else {")
        XCTAssertTrue(durable.contains("completion = .filteringNeedsAttention"))
        XCTAssertFalse(durable.contains("throw error"))
        XCTAssertTrue(apply.contains("return completion"))
        let view = try readSource(.backupRestoreView)
        XCTAssertTrue(view.contains("restoreStatus = completion == .complete ? .success : .restoredNeedsAttention"))
        XCTAssertTrue(view.contains("\"Backup restored\""))
        XCTAssertTrue(view.contains("\"Filtering could not update.\""))
    }

    func testDismissalAndCancelledUnlockDiscardOnlyTheirOwnReview() throws {
        let source = try readSource(.backupRestoreView)
        XCTAssertTrue(source.contains("restoreTask?.cancel()"))
        XCTAssertTrue(source.contains("if let review { backup.discardPreparedBackupRestore(id: review.id) }"))
        XCTAssertTrue(source.contains("guard !Task.isCancelled, !retired, isCurrent()"))
        XCTAssertTrue(source.contains("backup.discardPreparedBackupRestore(id: prepared.id)"))
        let discard = try sourceBlock(in: try readSource(.backupController), startingAt: "func discardPreparedBackupRestore(", endingBefore: "func confirmPreparedBackupRestore(")
        XCTAssertTrue(discard.contains("if pendingRestore?.review.id == id")); XCTAssertTrue(discard.contains("pendingRestore = nil"))
    }

}
