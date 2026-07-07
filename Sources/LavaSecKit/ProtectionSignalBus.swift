import Foundation

public enum ProtectionSignalKind: String, Codable, CaseIterable, Equatable, Sendable {
    case pauseStateChanged
    case snapshotChanged
    case configurationChanged

    public var revisionKey: String {
        "lavasec.protection.signal.\(rawValue).revision"
    }

    public var notificationName: String {
        switch self {
        case .pauseStateChanged:
            "com.lavasec.protection.pause-state-changed"
        case .snapshotChanged:
            "com.lavasec.reload-snapshot"
        case .configurationChanged:
            "com.lavasec.protection.configuration-changed"
        }
    }
}

public struct ProtectionSignal: Equatable, Sendable {
    public let kind: ProtectionSignalKind
    public let revision: Int

    public init(kind: ProtectionSignalKind, revision: Int) {
        self.kind = kind
        self.revision = revision
    }
}

public enum ProtectionSignalDelivery: Equatable, Sendable {
    case delivered(ProtectionSignal)
    case duplicate(currentRevision: Int)
    case stale(observedRevision: Int, currentRevision: Int)
}

public protocol ProtectionSignalNotifier: Sendable {
    func postNotification(named name: String)
}

public struct NoopProtectionSignalNotifier: ProtectionSignalNotifier {
    public init() {}

    public func postNotification(named name: String) {}
}

public final class ProtectionSignalBus: @unchecked Sendable {
    private let storage: any ProtectionKeyValueStorage
    private let lock: any ProtectionCriticalSectionLock
    private let notifier: any ProtectionSignalNotifier
    private var deliveredRevisions: [ProtectionSignalKind: Int] = [:]

    public init(
        storage: any ProtectionKeyValueStorage,
        lock: any ProtectionCriticalSectionLock,
        notifier: any ProtectionSignalNotifier = NoopProtectionSignalNotifier()
    ) {
        self.storage = storage
        self.lock = lock
        self.notifier = notifier
    }

    @discardableResult
    public func publish(_ kind: ProtectionSignalKind) throws -> ProtectionSignal {
        let signal = try lock.withCriticalSection {
            let revision = storage.integer(forKey: kind.revisionKey) + 1
            storage.set(revision, forKey: kind.revisionKey)
            return ProtectionSignal(kind: kind, revision: revision)
        }

        notifier.postNotification(named: kind.notificationName)
        return signal
    }

    public func receiveWakeup(
        _ kind: ProtectionSignalKind,
        observedRevision: Int? = nil
    ) throws -> ProtectionSignalDelivery {
        try lock.withCriticalSection {
            let currentRevision = storage.integer(forKey: kind.revisionKey)
            let deliveredRevision = deliveredRevisions[kind] ?? 0

            if currentRevision > deliveredRevision {
                deliveredRevisions[kind] = currentRevision
                return .delivered(ProtectionSignal(kind: kind, revision: currentRevision))
            }

            if let observedRevision, observedRevision < deliveredRevision {
                return .stale(observedRevision: observedRevision, currentRevision: currentRevision)
            }

            return .duplicate(currentRevision: currentRevision)
        }
    }
}
