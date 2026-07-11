import XCTest

/// Pins the cross-process wiring of the SQLite Domain History depth store (`DNSEventLog`),
/// which the compiler can't see from the `LavaSecCore` test target: the tunnel is the
/// continuous writer (open + seed + append + prune) that feeds the Domain History list read
/// back by the app, which opens a read-only reader — plus a transient writer only on an
/// explicit user clear, to physically prune. The store's own behavior is covered by
/// `DNSEventLogTests`.
final class DNSEventLogWiringSourceTests: XCTestCase {
    func testAppGroupDeclaresTheDepthStoreFileAndClearFloor() throws {
        let source = try readSource(.appGroup)
        XCTAssertTrue(source.contains("static let dnsEventLogFilename = \"dns-events.sqlite\""))
        XCTAssertTrue(source.contains("static let dnsEventLogClearedAtKey = \"dnsEventLogClearedAtMs\""))
    }

    func testTunnelIsTheSoleWriter() throws {
        let source = try readSource(.packetTunnelProvider)

        // Owns a writer handle, opened + seeded from the JSON buffer on load.
        XCTAssertTrue(source.contains("private var dnsEventLog: DNSEventLog?"))
        XCTAssertTrue(source.contains("dnsEventLog = try? DNSEventLog(url: dnsEventLogURL)"))
        XCTAssertTrue(source.contains("try? dnsEventLog?.seedIfEmpty(from: diagnostics.recentEvents)"))

        // Appends the same population as the events buffer: gated on keepDomainDiagnostics,
        // fail-closed blocks excluded.
        XCTAssertTrue(source.contains("if configuration.keepDomainDiagnostics, decision.reason != .protectionUnavailable {"))
        // Stamped at decision time (captured before the dnsStateQueue hop), not block-run time,
        // so a queued pre-clear event lands on the correct side of the clear floor (PR #327).
        XCTAssertTrue(source.contains("let decisionTime = Date()"))
        XCTAssertTrue(source.contains("self.dnsEventLog?.appendBestEffort(domain: domain, decision: decision, timestamp: decisionTime)"))

        // Prunes below BOTH the 7-day window AND the app's clear floor, so a user clear
        // physically deletes rows within a cadence instead of leaving them stored (PR #327).
        XCTAssertTrue(source.contains("let retentionCutoff = now.addingTimeInterval(-LocalLogRetention.fineGrainedWindow)"))
        XCTAssertTrue(source.contains("forKey: LavaSecAppGroup.dnsEventLogClearedAtKey"))
        XCTAssertTrue(source.contains("try? dnsEventLog.prune(before: cutoff)"))

        // Stop cleanup drains queued fire-and-forget appends so a suspended NE process doesn't
        // drop the newest decisions from the SQLite-backed list (PR #327 review).
        XCTAssertTrue(source.contains("self.dnsEventLog?.flush()"))
    }

    func testAppReadsTheDepthStoreReadOnlyWithTheClearFloor() throws {
        let source = try readSource(.diagnosticsController)

        XCTAssertTrue(source.contains("func domainHistoryEvents(action: FilterAction, searchText: String, limit: Int) -> [DNSQueryEvent]"))
        XCTAssertTrue(source.contains("try? DNSEventLog(url: dnsEventLogURL, readOnly: true)"))
        // Clear is a shared-defaults floor: written on clear, applied on read.
        XCTAssertTrue(source.contains("forKey: LavaSecAppGroup.dnsEventLogClearedAtKey"))
        // The read floors at BOTH the clear timestamp AND the 7-day retention cutoff, so a
        // tunnel stopped >7 days can't surface stale rows in Domain History (PR #327 review).
        XCTAssertTrue(source.contains("LocalLogRetention.fineGrainedWindow"))
        XCTAssertTrue(source.contains("max(clearFloorMs, retentionFloorMs)"))
        // Falls back to the JSON events buffer before the tunnel has seeded the DB, so an
        // upgraded install isn't blank until protection starts (PR #327 review).
        XCTAssertTrue(source.contains("return diagnostics.recentEvents(action: action, searchText: searchText, limit: limit)"))
    }

    func testEveryDomainHistoryClearPathErasesTheDepthStore() throws {
        // Both the domain-history-only clear and the "All" local-log clear must erase the SQLite
        // store, or cleared rows resurface from dns-events.sqlite on reload (PR #327 review).
        let source = try readSource(.diagnosticsController)
        // The clear helper both advances the floor AND physically prunes, so an offline clear
        // (tunnel stopped, its periodic prune never runs) still removes rows from disk.
        XCTAssertTrue(source.contains("private func clearDNSEventLogHistory(at clearedAt: Date)"))
        XCTAssertTrue(source.contains("forKey: LavaSecAppGroup.dnsEventLogClearedAtKey"))
        // The stored floor AND the prune must use the +1ms clear boundary so a decision recorded
        // in the clear's exact millisecond is both hidden and pruned (lavasec-ios#51 Codex review;
        // behaviour pinned by DNSEventLogTests.testClearFloorExcludesSameMillisecondEvents).
        XCTAssertTrue(source.contains("DNSEventLog.clearFloorMilliseconds(for: clearedAt)"))
        XCTAssertTrue(source.contains("try? writer.prune(before: Date(timeIntervalSince1970: Double(floorMs) / 1000))"))

        let clearDomainHistory = try sourceBlock(
            in: source,
            startingAt: "func clearDomainHistory(",
            endingBefore: "func clearLocalFilteringCounts("
        )
        XCTAssertTrue(clearDomainHistory.contains("clearDNSEventLogHistory(at: clearedAt)"))

        let clearAllLocalLogs = try sourceBlock(
            in: source,
            startingAt: "func clearAllLocalLogs(",
            endingBefore: "private func clearDNSEventLogHistory("
        )
        XCTAssertTrue(clearAllLocalLogs.contains("clearDNSEventLogHistory(at: clearedAt)"))
    }

    func testDomainHistoryListReadsTheDepthStore() throws {
        let source = try readSource(.diagnosticsDomainHistory)
        XCTAssertTrue(source.contains("reports.domainHistoryEvents("))
    }

    func testLocalLogExportReadsTheDepthStore() throws {
        let controller = try readSource(.diagnosticsController)
        let depthExport = try sourceBlock(
            in: controller,
            startingAt: "func domainHistoryExportSource(at now: Date) -> DomainHistoryExportSource",
            endingBefore: "private func domainHistorySince(now: Date)"
        )
        // Export must read a DEDICATED connection so it can hold a consistent snapshot without
        // serializing the shared list reader (#340 follow-up).
        XCTAssertTrue(depthExport.contains("try? DNSEventLog(url: url, readOnly: true)"))
        XCTAssertTrue(depthExport.contains("return .events(diagnostics.recentEvents)"))
        XCTAssertTrue(depthExport.contains("let since = domainHistorySince(now: now)"))
        // Export must remain STREAMING: it hands back a page-at-a-time source, never a resident
        // array (#340 review — a full-history export must not spike foreground memory).
        XCTAssertTrue(depthExport.contains("DomainHistoryExportPager(log: snapshotLog, since: since)"))
        XCTAssertTrue(depthExport.contains("return DomainHistoryExportSource { pager.nextPage() }"))
        XCTAssertFalse(depthExport.contains("var events: [DNSQueryEvent] = []"))
        XCTAssertTrue(controller.contains("log.pageAllActions(before: cursor, since: since, limit: batchSize)"))
        // The snapshot must be pinned EAGERLY when the source is created (on the main actor,
        // before the caller yields to the detached drain), not lazily on the first page — else a
        // clear in that gap truncates the export. Immunity itself is proven by
        // DNSEventLogTests.testExportSnapshotIsImmuneToConcurrentPrune.
        XCTAssertTrue(depthExport.contains("snapshotLog.beginSnapshot()"))
        XCTAssertTrue(controller.contains("log.endSnapshot()"))

        let viewModel = try readSource(.appViewModel)
        let export = try sourceBlock(
            in: viewModel,
            startingAt: "func makeLocalLogExportArchive(",
            endingBefore: "private func makeLocalLogExportMetadata("
        )
        XCTAssertTrue(export.contains("reports.domainHistoryExportSource(at: generatedAt)"))
        // Export must remain OFF the main actor: the CSV+ZIP encode is hopped to a detached task
        // so a large export cannot block the main thread (#340 review — watchdog/UI hang).
        XCTAssertTrue(export.contains("async throws -> LocalLogExportArchive"))
        XCTAssertTrue(export.contains("Task.detached(priority: .userInitiated)"))
        XCTAssertTrue(export.contains("domainHistory: domainHistory"))
    }

    /// Concurrent clears can no longer truncate the archive (the export reads a pinned snapshot),
    /// so the view guard's only remaining job is to stop a second overlapping export from racing
    /// the shared exporter state. The export button must mark the export in flight and disable
    /// itself until the archive bytes are built (#340 follow-up — Codex review of PR #341).
    func testLocalLogExportGuardsOverlappingExports() throws {
        let view = try readSource(.privacySecuritySettingsView)
        XCTAssertTrue(view.contains("@State private var isExportingLocalLogs = false"))

        let export = try sourceBlock(
            in: view,
            startingAt: "private func exportLocalLogs()",
            endingBefore: "private func handleLocalLogExportCompletion("
        )
        // The flag is raised synchronously and guarded BEFORE authentication, so a double-tap
        // during the auth prompt can't queue a second overlapping export.
        XCTAssertTrue(export.contains("guard !isExportingLocalLogs else { return }"))
        XCTAssertTrue(export.contains("isExportingLocalLogs = true"))
        XCTAssertTrue(export.contains("defer { isExportingLocalLogs = false }"))
        XCTAssertTrue(view.contains(".disabled(isExportingLocalLogs)"))
    }
}
