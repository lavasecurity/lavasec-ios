import XCTest

final class BackupRestoreReviewSourceTests: XCTestCase {
    func testUnlockOnlyPresentsReviewAndConfirmationIsASeparateAction() throws {
        let source = try readSource(.backupRestoreView)
        let prepare = try sourceBlock(in: source, startingAt: "private func prepareRestore()",
                                      endingBefore: "private func confirmRestore(")
        XCTAssertTrue(prepare.contains("backup.prepareEncryptedBackupRestore("))
        XCTAssertTrue(prepare.contains("review = prepared"))
        XCTAssertTrue(prepare.contains("restoreStatus = .reviewing"))
        XCTAssertFalse(prepare.contains("confirmPreparedBackupRestore("))
        XCTAssertFalse(prepare.contains("restoreStatus = .success"))
        let confirm = try sourceBlock(in: source, startingAt: "private func confirmRestore(",
                                      endingBefore: "private func reportRestoreFailure(")
        XCTAssertTrue(confirm.contains("backup.confirmPreparedBackupRestore(id: review.id, resolverChangeConfirmed: resolverChangeConfirmed)"))
        XCTAssertTrue(confirm.contains("guard !isRestoring else { return }"))
        XCTAssertTrue(source.contains("review == nil ? \"Review Backup\" : \"Restore Backup\""))
    }

    func testReviewRendersBothSidesOfRecordingAndDNSChanges() throws {
        let source = try readSource(.backupRestoreView)
        let review = try sourceBlock(in: source, startingAt: "private func restoreReview(",
                                     endingBefore: "private func reviewRow(")
        XCTAssertTrue(review.contains("reviewRow(\"Protection on this device\""))
        for field in ["keepFilteringCounts", "keepDomainDiagnostics", "keepNetworkActivity", "keepLavaGuardProgress"] {
            XCTAssertTrue(review.contains("plan.previousConfiguration.\(field)"), field)
            XCTAssertTrue(review.contains("plan.configuration.\(field)"), field)
        }
        XCTAssertTrue(review.contains("savedCustomDNS(plan.previousConfiguration)"))
        XCTAssertTrue(review.contains("savedCustomDNS(plan.configuration)"))
        let savedDNS = try sourceBlock(in: source, startingAt: "private func savedCustomDNS(",
                                        endingBefore: "private func state(")
        XCTAssertTrue(savedDNS.contains("configuration.customResolverName"))
        XCTAssertTrue(savedDNS.contains("configuration.fallbackCustomResolverName"))
        XCTAssertTrue(review.contains("if plan.requiresResolverConfirmation"))
        XCTAssertTrue(review.contains("isOn: $resolverChangeConfirmed"))
        XCTAssertTrue(source.contains("$0.plan.requiresResolverConfirmation && !resolverChangeConfirmed"))
    }

    func testLibraryReviewShowsOrderEvenWhenPerFilterContentsAreUnchanged() throws {
        let source = try readSource(.backupRestoreView)
        XCTAssertTrue(source.contains("orderedFilters(plan.previousLibrary)"))
        XCTAssertTrue(source.contains("orderedFilters(plan.library)"))
        let order = try sourceBlock(in: source, startingAt: "private func orderedFilters(", endingBefore: "private func reviewRow(")
        XCTAssertTrue(order.contains("library.filters.enumerated()"))
        XCTAssertFalse(order.contains("sorted"))
    }

    func testReviewShowsUnlocksSeparatelyFromTheRecordingPreference() throws {
        let source = try readSource(.backupRestoreView)
        XCTAssertTrue(source.contains("unlocks(plan.previousConfiguration.lavaGuardUnlocks)"))
        XCTAssertTrue(source.contains("unlocks(plan.configuration.lavaGuardUnlocks)"))
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
        let formatter = try sourceBlock(in: source, startingAt: "private func customSources(",
                                         endingBefore: "private func savedCustomDNS(")
        XCTAssertTrue(formatter.contains("$0.parseFormat.rawValue"))
        let review = try sourceBlock(in: source, startingAt: "private func filterReview(",
                                     endingBefore: "private func domains(")
        XCTAssertTrue(review.contains("customSources(change.before?.customBlocklists ?? [])"))
        XCTAssertTrue(review.contains("customSources(change.after?.customBlocklists ?? [])"))
    }

    func testReviewSeparatesDomainAdditionsAndRemovalsFromUnchangedEntries() throws {
        let source = try readSource(.backupRestoreView)
        for field in ["addedAllowedDomains", "removedAllowedDomains", "addedBlockedDomains", "removedBlockedDomains"] {
            XCTAssertTrue(source.contains("change.selectionDiff.\(field)"), field)
        }
        let review = try sourceBlock(in: source, startingAt: "private func domainReview(", endingBefore: "private func blocklistName(")
        XCTAssertTrue(review.contains("if !added.isEmpty"))
        XCTAssertTrue(review.contains("if !removed.isEmpty"))
        XCTAssertTrue(review.contains("domains(Set(added))"))
        XCTAssertTrue(review.contains("domains(Set(removed))"))
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
        XCTAssertTrue(source.contains(".onDisappear {"))
        XCTAssertTrue(source.contains("restoreTask?.cancel()"))
        XCTAssertTrue(source.contains("if let review { backup.discardPreparedBackupRestore(id: review.id) }"))
        let prepare = try sourceBlock(in: source, startingAt: "private func prepareRestore()",
                                      endingBefore: "private func confirmRestore(")
        XCTAssertTrue(prepare.contains("guard !Task.isCancelled else {"))
        XCTAssertTrue(prepare.contains("backup.discardPreparedBackupRestore(id: prepared.id)"))
        let discard = try sourceBlock(in: try readSource(.backupController), startingAt: "func discardPreparedBackupRestore(",
                                      endingBefore: "func confirmPreparedBackupRestore(")
        XCTAssertTrue(discard.contains("if pendingRestore?.review.id == id"))
        XCTAssertTrue(discard.contains("pendingRestore = nil"))
    }
}
