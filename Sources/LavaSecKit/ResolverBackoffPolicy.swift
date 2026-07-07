import Foundation

public protocol ResolverBackoffClock: Sendable {
    var now: Date { get }
}

public struct SystemResolverBackoffClock: ResolverBackoffClock {
    public init() {}

    public var now: Date { Date() }
}

public struct ResolverBackoffPolicy: Sendable {
    public enum AttemptOutcome: String, Sendable {
        case success
        case timeout
        case httpStatusFailure = "http-status-failure"
        case backedOff = "backed-off"
        case sendFailed = "send-failed"
        case receiveFailed = "receive-failed"
        case invalidAddress = "invalid-address"
        case unsupported
        case socketUnavailable = "socket-unavailable"
        case mismatchedResponse = "mismatched-response"
        case deviceDNSUnavailable = "device-dns-unavailable"
    }

    public struct Attempt: Equatable, Sendable {
        public let address: String
        public let outcome: AttemptOutcome

        public init(address: String, outcome: AttemptOutcome) {
            self.address = address
            self.outcome = outcome
        }
    }

    private let interval: TimeInterval
    private let clock: any ResolverBackoffClock
    private var backoffUntilByAddress: [String: Date]

    public init(
        interval: TimeInterval = 30,
        clock: any ResolverBackoffClock = SystemResolverBackoffClock()
    ) {
        self.interval = interval
        self.clock = clock
        backoffUntilByAddress = [:]
    }

    public func availableAddresses(from addresses: [String], now: Date? = nil) -> [String] {
        let now = now ?? clock.now
        return addresses.filter { address in
            guard let backoffUntil = backoffUntilByAddress[address] else {
                return true
            }

            return backoffUntil <= now
        }
    }

    public func isBackedOff(_ address: String, now: Date? = nil) -> Bool {
        let now = now ?? clock.now
        guard let backoffUntil = backoffUntilByAddress[address] else {
            return false
        }

        return backoffUntil > now
    }

    public func backoffExpiration(for address: String) -> Date? {
        backoffUntilByAddress[address]
    }

    public mutating func record(_ attempts: [Attempt], now: Date? = nil) {
        let now = now ?? clock.now
        for attempt in attempts {
            switch attempt.outcome {
            case .success:
                backoffUntilByAddress.removeValue(forKey: attempt.address)
            case .timeout,
                 .httpStatusFailure,
                 .sendFailed,
                 .receiveFailed,
                 .invalidAddress,
                 .socketUnavailable,
                 .mismatchedResponse:
                backoffUntilByAddress[attempt.address] = now.addingTimeInterval(interval)
            case .backedOff, .unsupported, .deviceDNSUnavailable:
                break
            }
        }
    }

    public mutating func reset() {
        backoffUntilByAddress = [:]
    }
}
