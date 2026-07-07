import Foundation
@testable import LavaSecCore
@testable import LavaSecKit

final class FakeProtectionKeyValueStore: ProtectionKeyValueStorage, @unchecked Sendable {
    private var values: [String: Any] = [:]

    func string(forKey key: String) -> String? {
        values[key] as? String
    }

    func date(forKey key: String) -> Date? {
        values[key] as? Date
    }

    func integer(forKey key: String) -> Int {
        values[key] as? Int ?? 0
    }

    func set(_ value: String, forKey key: String) {
        values[key] = value
    }

    func set(_ value: Date, forKey key: String) {
        values[key] = value
    }

    func set(_ value: Int, forKey key: String) {
        values[key] = value
    }

    func removeObject(forKey key: String) {
        values.removeValue(forKey: key)
    }
}

final class RecordingProtectionCriticalSectionLock: ProtectionCriticalSectionLock, @unchecked Sendable {
    private(set) var entryCount = 0
    private(set) var isInsideCriticalSection = false

    func withCriticalSection<T>(_ body: () throws -> T) rethrows -> T {
        entryCount += 1
        isInsideCriticalSection = true
        defer { isInsideCriticalSection = false }
        return try body()
    }
}

final class FakeProtectionClock: ProtectionClock, @unchecked Sendable {
    var now: Date

    init(now: Date) {
        self.now = now
    }

    func advance(seconds: TimeInterval) {
        now = now.addingTimeInterval(seconds)
    }
}

final class RecordingProtectionSignalNotifier: ProtectionSignalNotifier, @unchecked Sendable {
    private(set) var postedNames: [String] = []

    func postNotification(named name: String) {
        postedNames.append(name)
    }
}

final class ReentrantProtectionSignalNotifier: ProtectionSignalNotifier, @unchecked Sendable {
    var onPostNotification: ((String) -> Void)?
    private(set) var postedNames: [String] = []

    func postNotification(named name: String) {
        postedNames.append(name)
        onPostNotification?(name)
    }
}
