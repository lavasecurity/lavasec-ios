import Darwin
import Foundation
import SwiftUI
import UIKit
@preconcurrency import CoreHaptics
@preconcurrency import NetworkExtension
@preconcurrency import UserNotifications
import LavaSecKit
import LavaSecFilterPipeline
import LavaSecAppServices

// One concern of `AppViewModel`, split out of the former single-file view model.
// Stored state (`@Published` and otherwise) lives in LavaSecApp/AppViewModel.swift (extensions
// cannot declare stored properties); every file under AppViewModel/ is one `// MARK:` section.

extension AppViewModel {
    // MARK: - Report surfaces refresh

    // refreshDiagnostics (the DiagnosticsStore read/prune lifecycle) and the whole
    // bug-report draft/send + rage-shake feature live on `reports`
    // (DiagnosticsController) since the Phase D4 peel. These two refreshers stay
    // hub-side because they fan out across BOTH owners: the controller's diagnostics
    // plus the hub-owned tunnel health and network-activity log.

    func refreshReports() {
        reports.refreshDiagnostics()
        refreshTunnelHealth()
        refreshNetworkActivityLog()
    }

    /// - Parameter force: passed through to `sampleTunnelHealth`; set it when the sample is a
    ///   one-shot capture rather than a poll tick. See that method for why.
    func sampleReports(force: Bool = false) async {
        reports.refreshDiagnostics()
        await sampleTunnelHealth(force: force)
        refreshNetworkActivityLog(force: true)
    }

    func refreshFilterNumberSummaries() async {
        loadPersistedConfiguration()
        refreshCompiledBlocklistRuleCount()

        if let summary = await loadPreparedFilterSummaryForCurrentConfiguration() {
            compiledRuleCount = summary.blockRuleCount
            protectedRuleCount = summary.blockedDomainRuleCount
            if let blocklistRuleCount = summary.blocklistRuleCount {
                compiledBlocklistRuleCount = blocklistRuleCount
            } else if compiledBlocklistRuleCount == 0 {
                compiledBlocklistRuleCount = estimatedBlocklistRuleCount(fromTotalRuleCount: summary.blockRuleCount)
            }
            return
        }

        let snapshot = currentSnapshot()
        let summary = PreparedFilterSnapshotSummary(snapshot: snapshot)
        compiledRuleCount = summary.blockRuleCount
        protectedRuleCount = summary.blockedDomainRuleCount
        if compiledBlocklistRuleCount == 0 {
            compiledBlocklistRuleCount = estimatedBlocklistRuleCount(fromTotalRuleCount: snapshot.blockRules.count)
        }
    }

    func refreshTunnelHealth(force: Bool = false) {
        guard let containerURL = LavaSecAppGroup.containerURL else {
            tunnelHealthReadGate.reset()
            return
        }

        let url = containerURL.appendingPathComponent(LavaSecAppGroup.tunnelHealthFilename)
        guard let modifiedAt = modificationDate(for: url) else {
            tunnelHealthReadGate.reset()
            return
        }

        guard tunnelHealthReadGate.shouldRead(modifiedAt: modifiedAt, force: force) else {
            return
        }

        guard let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(TunnelHealthSnapshot.self, from: data)
        else {
            return
        }

        let previousHealth = tunnelHealth
        tunnelHealthReadGate.markRead(modifiedAt: modifiedAt)
        tunnelHealth = snapshot
        scheduleProtectionNotificationIfNeeded()

        // The Live Activity / Dynamic Island transient states (reconnecting,
        // networkUnavailable, needsReconnect) are derived from tunnel health, not
        // from NEVPNStatus — which stays `.connected` straight through a
        // reconnect. Reconcile whenever the health content actually changes so
        // the Dynamic Island reflects those states promptly instead of waiting
        // for the next status transition (UR-6: Dynamic Island lag during
        // retry/reconnect). `reconcile` dedupes by published content, so this is
        // a no-op when the derived DI state is unchanged.
        if snapshot != previousHealth {
            reconcileLiveActivity()
        }
    }

    private static let tunnelHealthFlushMinimumInterval: TimeInterval = 30

    /// - Parameter force: bypasses the 30 s throttle. The throttle exists for the repeating
    ///   5 s UI poll; a one-shot capture is not that. A Feedback report is the only reading
    ///   of the tunnel's state anyone gets for the session it describes, and the tunnel
    ///   hands back its suppressed unanswered-query tail on this message (PR #620), so a
    ///   throttled skip would export a burst as its first occurrence alone.
    func sampleTunnelHealth(force: Bool = false) async {
        let now = Date()
        guard force
            || now.timeIntervalSince(lastTunnelHealthFlushRequestedAt) >= Self.tunnelHealthFlushMinimumInterval
        else {
            refreshTunnelHealth()
            return
        }

        lastTunnelHealthFlushRequestedAt = now
        await requestTunnelHealthFlush()
        refreshTunnelHealth(force: true)
    }

    /// The visible stats page alone requests live samples. Entry, timer and manual
    /// reads share one bounded request, with no change to the global flush cadence.
    /// A replaced manager/session or configuration invalidates an in-flight reply.
    @discardableResult
    func sampleTunnelHealthForStats() async -> Bool {
        if let task = visibleStatsSamplingTask { return await task.value }
        let task = Task { @MainActor [self] in
            #if targetEnvironment(simulator)
            return false
            #else
            guard UIApplication.shared.applicationState == .active,
                  let session = tunnelManager?.connection as? NETunnelProviderSession,
                  session.status == .connected else { return false }
            let connectedAt = session.connectedDate
            let expectedConfiguration = configuration
            let data = await LavaProtectionStatusReader.query(session, message: LavaSecAppGroup.readTunnelHealthMessage)
            guard !Task.isCancelled, UIApplication.shared.applicationState == .active,
                  tunnelManager?.connection === session, session.status == .connected,
                  session.connectedDate == connectedAt, configuration == expectedConfiguration,
                  let data, let sample = try? JSONDecoder().decode(TunnelHealthSnapshot.self, from: data),
                  (0...5).contains(Date().timeIntervalSince(sample.updatedAt)) else { return false }
            tunnelHealth = sample
            return true
            #endif
        }
        visibleStatsSamplingTask = task
        let captured = await task.value
        visibleStatsSamplingTask = nil
        return captured
    }

    /// Keeps the two diagnostic reads within one connection/configuration lifetime.
    /// Callers use nil handshake evidence after a transition, never an older success.
    func sampleTunnelStats() async -> (captured: Bool, handshake: LavaSecAppGroup.ChainedHandshakeStatus?) {
        let connection = tunnelManager?.connection
        let connectedAt = connection?.connectedDate
        let expectedConfiguration = configuration
        let captured = await sampleTunnelHealthForStats()
        let handshake = await queryChainedHandshakeStatus()
        guard !Task.isCancelled, tunnelManager?.connection === connection,
              connection?.connectedDate == connectedAt, configuration == expectedConfiguration else {
            return (false, nil)
        }
        return (captured, handshake)
    }

    func listSummary(count: Int, singular: String, plural: String, values: [String]) -> String {
        guard count > 0 else {
            return "Not configured yet"
        }

        let label = count == 1 ? singular : plural
        let visibleValues = values.prefix(2)
        let visibleText = visibleValues.joined(separator: ", ")

        if count > 2 {
            return "\(count) \(label): \(visibleText), +\(count - 2) more"
        }

        return "\(count) \(label): \(visibleText)"
    }

}
