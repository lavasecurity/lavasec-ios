#if LAVA_QA_TOOLS
import CryptoKit
import Foundation
import LavaSecKit
import MetricKit

/// pinned: ReleaseGateSourceTests.testMetricKitRequiresQAWithoutDebug
/// Local QA evidence only. Never compiled for ordinary Debug or production Release.
/// Mutable file state is confined to `queue`; subscription state is main-actor isolated.
@MainActor
enum QAMetricKitCollector {
    static func start() { QAMetricKitSubscriber.shared.start() }
}

// Keep the Objective-C protocol conformance out of the app's generated Swift header.
// React Native imports that header from Objective-C++ without importing MetricKit.
private final class QAMetricKitSubscriber: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    static let shared = QAMetricKitSubscriber()
    private let queue = DispatchQueue(label: "com.lavasec.qa.metrickit", qos: .utility)
    @MainActor private var started = false
    private let maxReportBytes = 5 * 1024 * 1024
    private let maxTotalBytes = 20 * 1024 * 1024
    /// Carries MetricKit's non-Sendable payloads to `queue`. `@unchecked Sendable`: the
    /// box is immutable and `queue` is its only reader, so the payloads never race.
    private final class PayloadBox<Payload>: @unchecked Sendable {
        let payloads: [Payload]
        init(_ payloads: [Payload]) { self.payloads = payloads }
    }

    @MainActor
    func start() {
        guard !started, Bundle.main.bundleIdentifier == "com.lavasec.dev.qa" else { return }
        started = true
        queue.async { self.withDirectory { try self.prune($0) } }
        let manager = MXMetricManager.shared
        manager.add(self)
        didReceive(manager.pastPayloads)
        didReceive(manager.pastDiagnosticPayloads)
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        // Serialize OFF the caller's thread. `start()` replays the past payloads from
        // the main actor during launch, and `jsonRepresentation()` on a multi-megabyte
        // report would block app launch (and contaminate the launch-performance evidence
        // this QA tool exists to collect) before the size check can reject it — the check
        // needs the serialized size. Same path for MetricKit's own callbacks (Codex P2,
        // PR #781).
        let box = PayloadBox(payloads)
        queue.async { [weak self] in
            guard let self else { return }
            for payload in box.payloads { self.retain(payload.jsonRepresentation(), kind: "metrics") }
        }
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        let box = PayloadBox(payloads)
        queue.async { [weak self] in
            guard let self else { return }
            for payload in box.payloads { self.retain(payload.jsonRepresentation(), kind: "diagnostics") }
        }
    }

    /// Runs on `queue`: `didReceive` serializes and calls this inline, one payload at
    /// a time. The write must stay synchronous with its serialization — a nested
    /// `queue.async` here would queue every write behind the rest of the batch, letting
    /// a large replay retain all of its serialized payloads in memory past the storage
    /// budget and jetsam the QA app before preserving any evidence (Codex P2, PR #781).
    private func retain(_ data: Data, kind: String) {
        guard data.count <= maxReportBytes else {
            recordFailure("report-too-large")
            return
        }
        withDirectory { directory in
            // Content addressing deduplicates callbacks and past-payload replay.
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let file = directory.appendingPathComponent("\(kind)-\(digest).json")
            if !FileManager.default.fileExists(atPath: file.path) {
                try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            }
            try self.prune(directory)
        }
    }

    private func withDirectory(_ body: (URL) throws -> Void) {
        do {
            let manager = FileManager.default
            // App-private, not the app group: production cannot read QA reports.
            var directory = try manager.url(for: .applicationSupportDirectory,
                in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("QAMetricKit", isDirectory: true)
            try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try directory.setResourceValues(values)
            try body(directory)
        } catch {
            recordFailure("storage-failed")
        }
    }

    private func prune(_ directory: URL) throws {
        let manager = FileManager.default
        let files = try manager.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles])
            .filter { $0.pathExtension == "json" }
            .map { url in
                let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                return (url: url, date: values.contentModificationDate ?? .distantPast,
                        size: values.fileSize ?? 0)
            }
            .sorted { $0.date > $1.date }
        let retained = LocalDiagnosticRetentionPolicy.retainedIDs(
            files.map { .init(id: $0.url.lastPathComponent, receivedAt: $0.date, bytes: $0.size) },
            now: Date(), maxAge: 14 * 24 * 60 * 60, maxCount: 64,
            maxBytes: maxTotalBytes, maxReportBytes: maxReportBytes)
        for file in files where !retained.contains(file.url.lastPathComponent) {
            try manager.removeItem(at: file.url)
        }
    }

    private func recordFailure(_ reason: String) {
        LavaSecDeviceDebugLog.append(component: "qa-metrickit", event: "report-retention-failed",
            details: ["reason": reason])
    }
}
#endif
