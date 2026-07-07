import Foundation

public protocol LatencyClock: Sendable {
    var now: Date { get }
    var monotonicTime: TimeInterval { get }
}

public struct SystemLatencyClock: LatencyClock, Sendable {
    public init() {}

    public var now: Date {
        Date()
    }

    public var monotonicTime: TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }
}

public struct LatencyOperationID: RawRepresentable, Codable, Equatable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static func make() -> LatencyOperationID {
        LatencyOperationID(rawValue: UUID().uuidString.lowercased())
    }

    public var description: String {
        rawValue
    }
}

public struct LatencySpanID: RawRepresentable, Codable, Equatable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static func make() -> LatencySpanID {
        LatencySpanID(rawValue: UUID().uuidString.lowercased())
    }

    public var description: String {
        rawValue
    }
}

public enum LatencyEventPhase: String, Codable, Equatable, Sendable {
    case instant
    case begin
    case end
}

public struct LatencyEvent: Codable, Equatable, Sendable {
    public let operationID: LatencyOperationID
    public let timestamp: Date
    public let name: String
    public let phase: LatencyEventPhase
    public let spanID: LatencySpanID?
    public let parentSpanID: LatencySpanID?
    public let durationMilliseconds: TimeInterval?
    public let details: [String: String]

    public init(
        operationID: LatencyOperationID,
        timestamp: Date,
        name: String,
        phase: LatencyEventPhase,
        spanID: LatencySpanID? = nil,
        parentSpanID: LatencySpanID? = nil,
        durationMilliseconds: TimeInterval? = nil,
        details: [String: String] = [:]
    ) {
        self.operationID = operationID
        self.timestamp = timestamp
        self.name = name
        self.phase = phase
        self.spanID = spanID
        self.parentSpanID = parentSpanID
        self.durationMilliseconds = durationMilliseconds
        self.details = LatencyDetailRedactor.redactedDetails(details)
    }

    public func debugLogDetails(operationKind: String? = nil, sequence: Int? = nil) -> [String: String] {
        var output = details
        output["operationID"] = operationID.rawValue
        if let operationKind {
            output["operationKind"] = operationKind
        }
        if let spanID {
            output["spanID"] = spanID.rawValue
        }
        if let parentSpanID {
            output["parentSpanID"] = parentSpanID.rawValue
        }
        output["spanName"] = name
        output["spanEvent"] = phase.rawValue
        if let durationMilliseconds {
            output["durationMs"] = "\(Int(durationMilliseconds.rounded()))"
        }
        if let sequence {
            output["sequence"] = "\(sequence)"
        }
        return output
    }
}

public protocol LatencyEventSink: Sendable {
    func record(_ event: LatencyEvent)
}

public struct NoopLatencyEventSink: LatencyEventSink, Sendable {
    public init() {}

    public func record(_ event: LatencyEvent) {}
}

public final class LatencyDebugLogEventSink: LatencyEventSink, @unchecked Sendable {
    public typealias Append = (_ event: String, _ details: [String: String]) -> Void

    private let operationKind: String?
    private let append: Append
    private let sequence = LatencyDebugLogEventSequence()

    public init(operationKind: String? = nil, append: @escaping Append) {
        self.operationKind = operationKind
        self.append = append
    }

    public func record(_ event: LatencyEvent) {
        append(
            "latency-span-\(event.phase.rawValue)",
            event.debugLogDetails(
                operationKind: operationKind,
                sequence: sequence.next()
            )
        )
    }
}

private final class LatencyDebugLogEventSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }

        value += 1
        return value
    }
}

public final class LatencyTrace: @unchecked Sendable {
    public let operationID: LatencyOperationID

    private let clock: any LatencyClock
    private let sink: any LatencyEventSink
    private let spanIDGenerator: @Sendable () -> LatencySpanID

    public init(
        operationID: LatencyOperationID = .make(),
        clock: any LatencyClock = SystemLatencyClock(),
        sink: any LatencyEventSink = NoopLatencyEventSink(),
        spanIDGenerator: @escaping @Sendable () -> LatencySpanID = { .make() }
    ) {
        self.operationID = operationID
        self.clock = clock
        self.sink = sink
        self.spanIDGenerator = spanIDGenerator
    }

    public func record(_ name: String, details: [String: String] = [:]) {
        sink.record(LatencyEvent(
            operationID: operationID,
            timestamp: clock.now,
            name: name,
            phase: .instant,
            details: details
        ))
    }

    public func beginSpan(
        _ name: String,
        parent: LatencySpan? = nil,
        details: [String: String] = [:]
    ) -> LatencySpan {
        let span = LatencySpan(
            trace: self,
            name: name,
            spanID: spanIDGenerator(),
            parentSpanID: parent?.spanID,
            startedAt: clock.now,
            startedAtMonotonicTime: clock.monotonicTime
        )
        sink.record(LatencyEvent(
            operationID: operationID,
            timestamp: span.startedAt,
            name: name,
            phase: .begin,
            spanID: span.spanID,
            parentSpanID: span.parentSpanID,
            details: details
        ))
        return span
    }

    fileprivate func end(_ span: LatencySpan, details: [String: String]) {
        guard span.markEnded() else {
            return
        }

        let endedAt = clock.now
        let durationMilliseconds = max(0, (clock.monotonicTime - span.startedAtMonotonicTime) * 1_000)
        sink.record(LatencyEvent(
            operationID: operationID,
            timestamp: endedAt,
            name: span.name,
            phase: .end,
            spanID: span.spanID,
            parentSpanID: span.parentSpanID,
            durationMilliseconds: durationMilliseconds,
            details: details
        ))
    }
}

public final class LatencySpan: @unchecked Sendable {
    public let spanID: LatencySpanID

    fileprivate let trace: LatencyTrace
    fileprivate let name: String
    fileprivate let parentSpanID: LatencySpanID?
    fileprivate let startedAt: Date
    fileprivate let startedAtMonotonicTime: TimeInterval
    private let state = LatencySpanState()

    fileprivate init(
        trace: LatencyTrace,
        name: String,
        spanID: LatencySpanID,
        parentSpanID: LatencySpanID?,
        startedAt: Date,
        startedAtMonotonicTime: TimeInterval
    ) {
        self.trace = trace
        self.name = name
        self.spanID = spanID
        self.parentSpanID = parentSpanID
        self.startedAt = startedAt
        self.startedAtMonotonicTime = startedAtMonotonicTime
    }

    public func end(details: [String: String] = [:]) {
        trace.end(self, details: details)
    }

    fileprivate func markEnded() -> Bool {
        state.markEnded()
    }
}

private final class LatencySpanState: @unchecked Sendable {
    private let lock = NSLock()
    private var ended = false

    func markEnded() -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard !ended else {
            return false
        }

        ended = true
        return true
    }
}

public struct LatencyDurationPercentiles: Equatable, Sendable {
    public let count: Int
    public let p50Milliseconds: TimeInterval
    public let p95Milliseconds: TimeInterval

    public init(count: Int, p50Milliseconds: TimeInterval, p95Milliseconds: TimeInterval) {
        self.count = count
        self.p50Milliseconds = p50Milliseconds
        self.p95Milliseconds = p95Milliseconds
    }
}

public enum LatencyEventAggregation {
    public static func completedDurationPercentiles(
        from events: [LatencyEvent],
        name: String? = nil
    ) -> LatencyDurationPercentiles? {
        let durations = events.compactMap { event -> TimeInterval? in
            guard event.phase == .end else {
                return nil
            }
            if let name, event.name != name {
                return nil
            }
            return event.durationMilliseconds
        }

        guard !durations.isEmpty else {
            return nil
        }

        let sortedDurations = durations.sorted()
        return LatencyDurationPercentiles(
            count: sortedDurations.count,
            p50Milliseconds: nearestRankPercentile(0.50, in: sortedDurations),
            p95Milliseconds: nearestRankPercentile(0.95, in: sortedDurations)
        )
    }

    private static func nearestRankPercentile(_ percentile: Double, in sortedValues: [TimeInterval]) -> TimeInterval {
        let boundedPercentile = min(max(percentile, 0), 1)
        let rank = Int(ceil(boundedPercentile * Double(sortedValues.count)))
        let index = min(max(rank - 1, 0), sortedValues.count - 1)
        return sortedValues[index]
    }
}

public enum LatencyDetailRedactor {
    public static let redactedValue = "[redacted]"

    public static func redactedDetails(_ details: [String: String]) -> [String: String] {
        var redactedKeyCount = 0
        return details.keys.sorted().reduce(into: [:]) { redactedDetails, key in
            guard let value = details[key] else {
                return
            }

            let keyContainsSensitiveContent = shouldRedactValue(key)
            let outputKey: String
            if keyContainsSensitiveContent {
                redactedKeyCount += 1
                outputKey = "redactedDetail\(redactedKeyCount)"
            } else {
                outputKey = key
            }

            redactedDetails[outputKey] = shouldRedactKey(key) || keyContainsSensitiveContent || shouldRedactValue(value)
                ? redactedValue
                : value
        }
    }

    private static func shouldRedactKey(_ key: String) -> Bool {
        let tokens = Set(keyTokens(key))
        return !tokens.isDisjoint(with: sensitiveKeyTokens)
    }

    private static func shouldRedactValue(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return false
        }

        let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        return sensitiveValueRegexes.contains { regex in
            regex.firstMatch(in: trimmed, options: [], range: range) != nil
        }
    }

    private static func keyTokens(_ key: String) -> [String] {
        var normalized = key
        for replacement in keyNormalizationReplacements {
            let range = NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)
            normalized = replacement.regex.stringByReplacingMatches(
                in: normalized,
                options: [],
                range: range,
                withTemplate: replacement.template
            )
        }
        return normalized
            .lowercased()
            .split(separator: " ")
            .map(String.init)
    }

    // NSRegularExpression is immutable and thread-safe; redaction runs on every
    // traced event, so the patterns are compiled once instead of per value.
    private static let sensitiveValueRegexes: [NSRegularExpression] = sensitiveValuePatterns.compactMap { pattern in
        try? NSRegularExpression(pattern: pattern)
    }

    private static let keyNormalizationReplacements: [(regex: NSRegularExpression, template: String)] = [
        (#"([A-Z]+)([A-Z][a-z])"#, "$1 $2"),
        (#"([a-z0-9])([A-Z])"#, "$1 $2"),
        (#"[^A-Za-z0-9]+"#, " ")
    ].compactMap { pattern, template in
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        return (regex: regex, template: template)
    }

    private static let sensitiveKeyTokens: Set<String> = [
        "address",
        "addresses",
        "api",
        "apikey",
        "auth",
        "authkey",
        "authorization",
        "bearer",
        "cookie",
        "cookies",
        "credential",
        "credentials",
        "domain",
        "domainname",
        "domains",
        "host",
        "hostname",
        "hostnames",
        "hosts",
        "ip",
        "ipaddress",
        "ipaddresses",
        "jwt",
        "key",
        "password",
        "passwords",
        "secret",
        "secrets",
        "session",
        "sessions",
        "token",
        "tokens",
        "uri",
        "uris",
        "url",
        "urls"
    ]

    private static let sensitiveValuePatterns = [
        #"\b[a-zA-Z][a-zA-Z0-9+.-]*://\S+"#,
        #"\b(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,}\b"#,
        #"\b(?:(?:25[0-5]|2[0-4]\d|1?\d?\d)\.){3}(?:25[0-5]|2[0-4]\d|1?\d?\d)\b"#,
        #"(?i)\b(?:[0-9a-f]{1,4}:){2,}[0-9a-f]{0,4}\b"#,
        #"(?i)\b(?:bearer|basic)\s+[A-Za-z0-9._~+/=-]+"#,
        #"(?i)\b(?:authorization|auth|api[-_ ]?key|credential|jwt|password|secret|session|token|x-api-key)[A-Za-z0-9_-]*\s*[:=]\s*\S+"#,
        #"\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b"#
    ]
}
