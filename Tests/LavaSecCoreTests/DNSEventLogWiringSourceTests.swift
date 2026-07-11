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
        XCTAssertTrue(source.contains("try? writer.prune(before: clearedAt)"))

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
}
