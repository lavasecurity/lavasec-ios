import Foundation

/// Typed persistence used by protection lifecycle state machines.
///
/// The `UserDefaults` adapter is suitable for preference-like state but not safety-critical
/// cross-process compare-and-set because Foundation caches preference domains per process. Those
/// transactions use `ProtectionFileKeyValueStorage` under an external file lock.
public protocol ProtectionKeyValueStorage: Sendable {
    /// Reads an optional string value.
    func string(forKey key: String) -> String?
    /// Reads an optional date value.
    func date(forKey key: String) -> Date?
    /// Reads an integer value, returning zero when absent.
    func integer(forKey key: String) -> Int
    /// Stores a string value.
    func set(_ value: String, forKey key: String)
    /// Stores a date value.
    func set(_ value: Date, forKey key: String)
    /// Stores an integer value.
    func set(_ value: Int, forKey key: String)
    /// Removes the value for a key regardless of its stored type.
    func removeObject(forKey key: String)
}

/// A `UserDefaults`-backed adapter for preference-like protection state within one process view.
public struct ProtectionUserDefaultsStorage: ProtectionKeyValueStorage, @unchecked Sendable {
    private let defaults: UserDefaults

    /// Creates an adapter over the supplied defaults domain.
    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// Reads an optional string from the defaults domain.
    public func string(forKey key: String) -> String? {
        defaults.string(forKey: key)
    }

    /// Reads an optional date from the defaults domain.
    public func date(forKey key: String) -> Date? {
        defaults.object(forKey: key) as? Date
    }

    /// Reads an integer, returning the defaults domain's zero value when absent.
    public func integer(forKey key: String) -> Int {
        defaults.integer(forKey: key)
    }

    /// Stores a string in the defaults domain.
    public func set(_ value: String, forKey key: String) {
        defaults.set(value, forKey: key)
    }

    /// Stores a date in the defaults domain.
    public func set(_ value: Date, forKey key: String) {
        defaults.set(value, forKey: key)
    }

    /// Stores an integer in the defaults domain.
    public func set(_ value: Int, forKey key: String) {
        defaults.set(value, forKey: key)
    }

    /// Removes a value from the defaults domain.
    public func removeObject(forKey key: String) {
        defaults.removeObject(forKey: key)
    }
}

/// A freshly loaded, atomically persisted key-value record for cross-process coordination.
///
/// Unlike `UserDefaults`, this storage has no process-local cache. Callers must externally
/// serialize each load/mutate/persist transaction (for example with a cross-process file lock),
/// then call `persistIfNeeded()` before releasing that lock.
public final class ProtectionFileKeyValueStorage: ProtectionKeyValueStorage, @unchecked Sendable {
    private struct Document: Codable {
        var strings: [String: String] = [:]
        var dates: [String: Date] = [:]
        var integers: [String: Int] = [:]
    }

    private let fileURL: URL
    private var document: Document
    private var isDirty = false

    /// Loads an existing complete record, or begins an empty record when the file is absent.
    public init(fileURL: URL) throws {
        self.fileURL = fileURL
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let data = try Data(contentsOf: fileURL)
            document = try JSONDecoder().decode(Document.self, from: data)
        } else {
            document = Document()
        }
    }

    /// Reads an optional string from the loaded transaction record.
    public func string(forKey key: String) -> String? {
        document.strings[key]
    }

    /// Reads an optional date from the loaded transaction record.
    public func date(forKey key: String) -> Date? {
        document.dates[key]
    }

    /// Reads an integer from the loaded record, returning zero when absent.
    public func integer(forKey key: String) -> Int {
        document.integers[key] ?? 0
    }

    /// Updates a string and marks the transaction dirty only when its value changed.
    public func set(_ value: String, forKey key: String) {
        guard document.strings[key] != value else {
            return
        }
        document.strings[key] = value
        isDirty = true
    }

    /// Updates a date and marks the transaction dirty only when its value changed.
    public func set(_ value: Date, forKey key: String) {
        guard document.dates[key] != value else {
            return
        }
        document.dates[key] = value
        isDirty = true
    }

    /// Updates an integer and marks the transaction dirty only when its value changed.
    public func set(_ value: Int, forKey key: String) {
        guard document.integers[key] != value else {
            return
        }
        document.integers[key] = value
        isDirty = true
    }

    /// Removes every typed representation of a key and marks the transaction dirty when needed.
    public func removeObject(forKey key: String) {
        let removedString = document.strings.removeValue(forKey: key) != nil
        let removedDate = document.dates.removeValue(forKey: key) != nil
        let removedInteger = document.integers.removeValue(forKey: key) != nil
        isDirty = isDirty || removedString || removedDate || removedInteger
    }

    /// Persists the complete record with an atomic replacement, so a reader sees either the old
    /// transaction or the new one and never a partially written owner/token/generation tuple.
    public func persistIfNeeded() throws {
        guard isDirty else {
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(document).write(
            to: fileURL,
            options: SharedStateFileProtection.atomicControlPlaneWritingOptions
        )
        isDirty = false
    }
}

/// Executes a synchronous transaction under a caller-selected critical-section policy.
public protocol ProtectionCriticalSectionLock: Sendable {
    /// Runs `body` while the critical section is owned, preserving its result or error.
    func withCriticalSection<T>(_ body: () throws -> T) throws -> T
}

/// A no-op lock for callers that already hold the required external critical section.
public struct ProtectionNoopCriticalSectionLock: ProtectionCriticalSectionLock {
    /// Creates a no-op critical-section adapter.
    public init() {}

    /// Runs `body` directly because exclusion is owned by the caller.
    public func withCriticalSection<T>(_ body: () throws -> T) throws -> T {
        try body()
    }
}

/// An in-process `NSLock` adapter for storage used by multiple threads in one process.
public final class ProtectionNSLock: ProtectionCriticalSectionLock, @unchecked Sendable {
    private let lock = NSLock()

    /// Creates an unlocked in-process critical section.
    public init() {}

    /// Runs `body` while holding the in-process lock.
    public func withCriticalSection<T>(_ body: () throws -> T) throws -> T {
        lock.lock()
        defer {
            lock.unlock()
        }
        return try body()
    }
}

/// Supplies the current time to deterministic protection lifecycle state machines.
public protocol ProtectionClock: Sendable {
    /// The clock's current instant.
    var now: Date { get }
}

/// Production wall clock backed by `Date()`.
public struct SystemProtectionClock: ProtectionClock {
    /// Creates a system clock.
    public init() {}

    /// The current wall-clock date.
    public var now: Date {
        Date()
    }
}
