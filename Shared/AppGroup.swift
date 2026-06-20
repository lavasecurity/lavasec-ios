import Foundation
import LavaSecCore

enum LavaSecAppGroup {
    static let identifier = "group.com.lavasec"
    static let snapshotFilename = "filter-snapshot.json"
    static let compactSnapshotFilename = "filter-snapshot.compact"
    static let configurationFilename = "app-configuration.json"
    static let tunnelHealthFilename = "tunnel-health.json"
    static let diagnosticsFilename = "diagnostics.json"
    static let diagnosticsControlFilename = "diagnostics-control.json"
    static let networkActivityLogFilename = "network-activity-log.json"
    static let catalogCacheDirectoryName = "catalog-cache"
    static let reloadSnapshotMessage = "reload-snapshot"
    static let reloadProtectionPauseMessage = "reload-protection-pause"
    static let reloadConfigurationMessage = "reload-configuration"
    static let clearDiagnosticsMessage = "clear-diagnostics"
    static let clearFilteringCountsMessage = "clear-filtering-counts"
    static let clearNetworkActivityLogMessage = "clear-network-activity-log"
    static let flushTunnelHealthMessage = "flush-tunnel-health"
    static let vpnDebugLogFilename = "vpn-debug-log.jsonl"
    static let protectionNotificationRouteUserInfoKey = "lavaRoute"
    static let protectionNotificationGuardRouteValue = "guard"
    static let protectionNotificationRequestIdentifierPrefix = "com.lavasec.protection."
    static let protectionNotificationKindUserInfoKey = "lavaNotificationKind"
    static let protectionNotificationIDUserInfoKey = "lavaNotificationID"
    static let protectionLastDeliveredNotificationIDDefaultsKey = "lavasec.protection.lastDeliveredNotificationID"
    static let protectionLastDeliveredNotificationAtDefaultsKey = "lavasec.protection.lastDeliveredNotificationAt"
    static let protectionUnresolvedProblemNotificationIDDefaultsKey = "lavasec.protection.unresolvedProblemNotificationID"
    static let protectionUnresolvedProblemNotificationKindDefaultsKey = "lavasec.protection.unresolvedProblemNotificationKind"
    static let protectionNotificationKindSchemaVersionDefaultsKey = "lavasec.protection.notificationKindSchemaVersion"
    // Written by the app only after `saveToPreferences` confirms Connect-On-Demand
    // is armed/disarmed, and read by the tunnel to gate self-reconnect: a self-
    // cancel only recovers if on-demand will bring the tunnel back, and the app
    // persists `protectionEnabled = true` even when arming on-demand fails.
    static let protectionOnDemandConfirmedEnabledDefaultsKey = "lavasec.protection.onDemandConfirmedEnabled"
    // Aliased to the LavaSecCore stores so the app, tunnel, intents, and the
    // stores can never drift on key strings.
    static let protectionActiveSessionIDDefaultsKey = ProtectionSessionStore.Keys.activeSessionID
    static let protectionTemporaryPauseUntilDefaultsKey = ProtectionPauseStore.Keys.pausedUntil
    static let protectionTemporaryPauseSessionIDDefaultsKey = ProtectionPauseStore.Keys.pausedSessionID
    static let protectionCommandRevisionDefaultsKey = ProtectionPauseStore.Keys.commandRevision
    static let protectionCommandLockFilename = "protection-command.lock"
    static let customizationLavaGuardLookDefaultsKey = "lavasec.customization.lavaGuardLook"
    static let latencyOperationIDOptionKey = "lavasec.latency.operationID"

    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }

    /// The shared app-group `UserDefaults`, falling back to `.standard` if the
    /// group container is unavailable. Single source so the app, tunnel, intents,
    /// and command service can't drift onto `.standard` by accident.
    static var sharedDefaults: UserDefaults {
        UserDefaults(suiteName: identifier) ?? .standard
    }

    static func protectionNotificationRequestIdentifier(for identifier: String) -> String {
        "\(protectionNotificationRequestIdentifierPrefix)\(identifier)"
    }

    /// One-time migration of the persisted connectivity-notification state across the
    /// notification-kind vocabulary change (slow-DNS got its own kind). Idempotent and
    /// version-gated, so it's safe to call on every scheduling pass in both processes.
    static func migrateProtectionNotificationStateIfNeeded(_ defaults: UserDefaults = sharedDefaults) {
        ProtectionConnectivityNotificationStore.migrateLegacyKindSchemaIfNeeded(
            in: defaults,
            keys: ProtectionConnectivityNotificationStore.DefaultsKeys(
                schemaVersion: protectionNotificationKindSchemaVersionDefaultsKey,
                unresolvedProblemKind: protectionUnresolvedProblemNotificationKindDefaultsKey
            )
        )
    }
}

struct LavaSecProviderMessage: Equatable {
    let kind: String
    let operationID: String?
}

enum LavaSecProviderMessageCodec {
    private struct Envelope: Codable {
        let kind: String
        let operationID: String?
    }

    static func encode(kind: String, operationID: String?) -> Data {
        let envelope = Envelope(kind: kind, operationID: operationID)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(envelope)) ?? Data(kind.utf8)
    }

    static func decode(_ data: Data) -> LavaSecProviderMessage? {
        if let envelope = try? JSONDecoder().decode(Envelope.self, from: data) {
            return LavaSecProviderMessage(kind: envelope.kind, operationID: envelope.operationID)
        }

        guard let rawKind = String(data: data, encoding: .utf8) else {
            return nil
        }

        return LavaSecProviderMessage(kind: rawKind, operationID: nil)
    }
}

// Compiled in all configurations (including Release/TestFlight) so the optional
// Feedback report can carry the on-device VPN diagnostics. A privacy audit of
// every append site confirmed no event records a queried domain (only resolver
// endpoints, health/outcome metadata, and tunnel state); the user's domain
// history lives separately in the user-controlled DiagnosticsStore. The 8 MB cap
// plus rotation bounds the on-device footprint.
enum LavaSecDeviceDebugLog {
    // Cap keeps the on-device log from growing without bound (an 88.9 MB file was
    // observed during QA); one rotated generation is kept for dump tooling.
    static let maxLogFileBytes: UInt64 = 8 * 1024 * 1024

    // ISO8601DateFormatter is documented thread-safe; allocating one per append
    // showed up in heat triage as avoidable per-event cost.
    nonisolated(unsafe) private static let timestampFormatter = ISO8601DateFormatter()

    static func reset() {
        guard let url = logURL else {
            return
        }

        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: rotatedURL(for: url))
    }

    static func append(component: String, event: String, details: [String: String] = [:]) {
        guard let url = logURL else {
            return
        }

        var payload = details
        payload["component"] = component
        payload["event"] = event
        payload["timestamp"] = timestampFormatter.string(from: Date())

        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        else {
            return
        }

        appendLine(data + Data("\n".utf8), to: url)
    }

    // The app and tunnel processes append to the same file. O_APPEND with a single
    // write(2) per line keeps concurrent appends from tearing each other; the old
    // seekToEnd-then-write path produced corrupted JSONL lines in device dumps.
    private static func appendLine(_ line: Data, to url: URL) {
        guard var descriptor = openForAppend(url) else {
            return
        }

        var info = stat()
        if fstat(descriptor, &info) == 0, info.st_size >= Int64(maxLogFileBytes) {
            close(descriptor)
            rotate(url)
            guard let reopened = openForAppend(url) else {
                return
            }
            descriptor = reopened
        }

        line.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else {
                return
            }
            _ = write(descriptor, base, buffer.count)
        }
        close(descriptor)
    }

    private static func openForAppend(_ url: URL) -> Int32? {
        let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else {
                return -1
            }
            return open(path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        }
        return descriptor >= 0 ? descriptor : nil
    }

    private static func rotate(_ url: URL) {
        let rotated = rotatedURL(for: url)
        try? FileManager.default.removeItem(at: rotated)
        try? FileManager.default.moveItem(at: url, to: rotated)
    }

    private static func rotatedURL(for url: URL) -> URL {
        url.deletingLastPathComponent()
            .appendingPathComponent(url.lastPathComponent + ".1")
    }

    private static var logURL: URL? {
        LavaSecAppGroup.containerURL?.appendingPathComponent(LavaSecAppGroup.vpnDebugLogFilename)
    }
}
