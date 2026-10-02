import Foundation
import Darwin

/// The two clock readings that describe when a device-log event was observed.
public struct DeviceLogObservation: Equatable, Sendable {
    /// The wall-clock time used only for the log's human-readable timestamp.
    public let observedAt: Date

    /// The reboot-scoped monotonic ordering key, or `nil` when the clock domain is unavailable.
    public let order: DeviceLogObservationOrder?

    /// Creates a paired wall-clock observation and optional monotonic ordering key.
    /// - Parameters:
    ///   - observedAt: The wall-clock time displayed with the log entry.
    ///   - order: The reboot-scoped ordering key, if the clock domain was captured.
    public init(observedAt: Date, order: DeviceLogObservationOrder?) {
        self.observedAt = observedAt
        self.order = order
    }
}

/// A total-order key inside one process-resolved `CLOCK_MONOTONIC` domain.
public struct DeviceLogObservationOrder: Equatable, Sendable {
    /// The canonical 32-character lowercase hexadecimal identifier for the clock domain.
    public let bootSessionID: String

    /// The `CLOCK_MONOTONIC` reading in nanoseconds, comparable only within `bootSessionID`.
    public let monotonicNanoseconds: UInt64

    /// Creates an order key when the clock-domain identifier has its canonical wire spelling.
    /// - Parameters:
    ///   - bootSessionID: A 32-character lowercase hexadecimal clock-domain identifier.
    ///   - monotonicNanoseconds: The monotonic clock reading in nanoseconds.
    /// - Returns: `nil` when `bootSessionID` is not canonical.
    public init?(bootSessionID: String, monotonicNanoseconds: UInt64) {
        guard Self.isCanonicalBootSessionID(bootSessionID) else {
            return nil
        }
        self.bootSessionID = bootSessionID
        self.monotonicNanoseconds = monotonicNanoseconds
    }

    /// `v1:<32 lowercase hexadecimal clock-domain ID>:<UInt64 decimal nanoseconds>`.
    public var serialized: String {
        "v1:\(bootSessionID):\(monotonicNanoseconds)"
    }

    /// Parses the canonical versioned wire spelling into an order key.
    /// - Parameter value: The candidate `v1:<clock-domain-id>:<nanoseconds>` value.
    /// - Returns: The parsed key, or `nil` for an unknown version or non-canonical component.
    public static func parse(_ value: String) -> DeviceLogObservationOrder? {
        let components = value.split(separator: ":", omittingEmptySubsequences: false)
        guard components.count == 3,
              components[0] == "v1"
        else {
            return nil
        }

        let bootSessionID = String(components[1])
        let nanosecondsString = String(components[2])
        guard isCanonicalBootSessionID(bootSessionID),
              let monotonicNanoseconds = UInt64(nanosecondsString),
              String(monotonicNanoseconds) == nanosecondsString
        else {
            return nil
        }

        return DeviceLogObservationOrder(
            bootSessionID: bootSessionID,
            monotonicNanoseconds: monotonicNanoseconds
        )
    }

    private static func isCanonicalBootSessionID(_ value: String) -> Bool {
        value.utf8.count == 32 && value.utf8.allSatisfy { byte in
            (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
        }
    }
}

/// Captures display time and a reboot-safe ordering key at the observation boundary.
public enum DeviceLogObservationClock {
    /// Evaluated once by Swift's thread-safe static initialization, so every capture in this
    /// process uses the same normalized clock-domain identifier. Resolution performs sysctl work
    /// only here, never on the steady-state capture path.
    private static let clockDomainID: String? = DeviceLogClockDomainResolver().resolve()

    /// Captures adjacent wall-clock and monotonic readings in the process's cached boot domain.
    /// - Returns: A paired observation whose order is `nil` when neither domain source is valid.
    public static func capture() -> DeviceLogObservation {
        // Resolve the cached domain before the adjacent clock reads. The first sysctl lookup can
        // allocate and must not sit between the wall and monotonic observations it identifies.
        let clockDomainID = clockDomainID
        let observedAt = Date()
        let monotonicNanoseconds = clock_gettime_nsec_np(CLOCK_MONOTONIC)
        let order = clockDomainID.flatMap {
            DeviceLogObservationOrder(
                bootSessionID: $0,
                monotonicNanoseconds: monotonicNanoseconds
            )
        }
        return DeviceLogObservation(observedAt: observedAt, order: order)
    }
}

/// Resolves one cached clock-domain identifier from the preferred UUID or public boot time.
///
/// `kern.bootsessionuuid` is unavailable with `EPERM` in the app and Network Extension sandboxes
/// on physical iOS devices. `kern.boottime` is public there and returns the same `timeval` to both
/// processes, so its complete seconds and microseconds provide the deterministic fallback. A
/// manual wall-clock step can make a later process observe a different boot-time value; treating
/// that value as a different domain is a conservative ordering barrier, never permission to
/// compare monotonic readings across it.
struct DeviceLogClockDomainResolver {
    /// The complete result of one fixed-buffer `kern.boottime` read.
    struct BootTimeReading {
        let seconds: Int64
        let microseconds: Int64
        let byteCount: Int
    }

    private let bootSessionUUID: () -> String?
    private let bootTime: () -> BootTimeReading?

    init(
        bootSessionUUID: @escaping () -> String? = Self.loadBootSessionUUID,
        bootTime: @escaping () -> BootTimeReading? = Self.loadBootTime
    ) {
        self.bootSessionUUID = bootSessionUUID
        self.bootTime = bootTime
    }

    func resolve() -> String? {
        if let rawUUID = bootSessionUUID(),
           let uuid = UUID(
               uuidString: rawUUID.trimmingCharacters(in: .whitespacesAndNewlines))
        {
            return uuid.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        }

        guard let reading = bootTime(),
              reading.byteCount == MemoryLayout<timeval>.size,
              reading.seconds >= 0,
              (0..<1_000_000).contains(reading.microseconds)
        else {
            return nil
        }

        // `62747631` is ASCII "btv1". Full-width components are lossless and keep this private
        // fallback distinguishable from normalized UUIDs without changing the 32-hex wire shape.
        return "62747631"
            + Self.hex(UInt64(reading.seconds), width: 16)
            + Self.hex(UInt64(reading.microseconds), width: 8)
    }

    private static func loadBootSessionUUID() -> String? {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0,
              size > 1
        else {
            return nil
        }

        var buffer = [UInt8](repeating: 0, count: size)
        let result = buffer.withUnsafeMutableBytes { bytes in
            sysctlbyname("kern.bootsessionuuid", bytes.baseAddress, &size, nil, 0)
        }
        guard result == 0 else {
            return nil
        }

        let uuidBytes = buffer.prefix { $0 != 0 }
        guard let value = String(bytes: uuidBytes, encoding: .utf8),
              !value.isEmpty
        else { return nil }
        return value
    }

    private static func loadBootTime() -> BootTimeReading? {
        var value = timeval()
        var size = MemoryLayout<timeval>.size
        let result = withUnsafeMutableBytes(of: &value) { bytes in
            sysctlbyname("kern.boottime", bytes.baseAddress, &size, nil, 0)
        }
        guard result == 0 else { return nil }
        return BootTimeReading(
            seconds: Int64(value.tv_sec),
            microseconds: Int64(value.tv_usec),
            byteCount: size
        )
    }

    private static func hex(_ value: UInt64, width: Int) -> String {
        let digits = String(value, radix: 16)
        return String(repeating: "0", count: width - digits.count) + digits
    }
}
