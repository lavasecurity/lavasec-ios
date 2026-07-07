import Foundation

// Deliberately no synchronize() requirement: UserDefaults.set delivers values to
// cfprefsd synchronously, so cross-process readers of the app-group suite already
// observe writes without a flush. Darwin notifications remain wakeups only.
public protocol ProtectionKeyValueStorage: Sendable {
    func string(forKey key: String) -> String?
    func date(forKey key: String) -> Date?
    func integer(forKey key: String) -> Int
    func set(_ value: String, forKey key: String)
    func set(_ value: Date, forKey key: String)
    func set(_ value: Int, forKey key: String)
    func removeObject(forKey key: String)
}

public struct ProtectionUserDefaultsStorage: ProtectionKeyValueStorage, @unchecked Sendable {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    public func string(forKey key: String) -> String? {
        defaults.string(forKey: key)
    }

    public func date(forKey key: String) -> Date? {
        defaults.object(forKey: key) as? Date
    }

    public func integer(forKey key: String) -> Int {
        defaults.integer(forKey: key)
    }

    public func set(_ value: String, forKey key: String) {
        defaults.set(value, forKey: key)
    }

    public func set(_ value: Date, forKey key: String) {
        defaults.set(value, forKey: key)
    }

    public func set(_ value: Int, forKey key: String) {
        defaults.set(value, forKey: key)
    }

    public func removeObject(forKey key: String) {
        defaults.removeObject(forKey: key)
    }
}

public protocol ProtectionCriticalSectionLock: Sendable {
    func withCriticalSection<T>(_ body: () throws -> T) throws -> T
}

public struct ProtectionNoopCriticalSectionLock: ProtectionCriticalSectionLock {
    public init() {}

    public func withCriticalSection<T>(_ body: () throws -> T) throws -> T {
        try body()
    }
}

public final class ProtectionNSLock: ProtectionCriticalSectionLock, @unchecked Sendable {
    private let lock = NSLock()

    public init() {}

    public func withCriticalSection<T>(_ body: () throws -> T) throws -> T {
        lock.lock()
        defer {
            lock.unlock()
        }
        return try body()
    }
}

public protocol ProtectionClock: Sendable {
    var now: Date { get }
}

public struct SystemProtectionClock: ProtectionClock {
    public init() {}

    public var now: Date {
        Date()
    }
}
