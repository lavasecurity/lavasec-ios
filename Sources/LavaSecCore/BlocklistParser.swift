import Foundation

public enum BlocklistFormat: String, Codable, Sendable {
    case auto
    case plainDomains
    case hosts
    case adblock
    case dnsmasq
}

// Invalidation constant for caches of PARSED rules (RuleSetCache). Bump when
// parse behavior changes in any way that can alter output for the same input
// bytes: clean()/candidateDomains()/auto-format detection, DomainName.normalize
// semantics, the maxLineLength/maxRules defaults, or the
// DomainRuleSet.lavaSecProtectedDomains list (cached entries are post-filter).
public enum BlocklistParsingRules {
    // v2: parseHosts now emits every host on a multi-domain line (was: first only),
    // so the same source bytes can yield more rules. Bumped to orphan stale RuleSetCache
    // entries parsed under the first-host-only behavior.
    // v3: the production per-source rule cap was raised from a flat 1,000,000 to the
    // Plus subscription ceiling (FeatureLimits.plus.maxFilterRules, 2M), so a single
    // large list that was previously truncated at 1M can now yield up to a full 2M-rule
    // filter; bumped to orphan caches parsed under the old cap. (The streaming byte-parse
    // added alongside is output-identical for LF/CR/CRLF text and would not require a
    // bump on its own.)
    public static let rulesVersion = 3
}

public struct RejectedBlocklistLine: Equatable, Sendable {
    public let lineNumber: Int
    public let content: String
    public let reason: String

    public init(lineNumber: Int, content: String, reason: String) {
        self.lineNumber = lineNumber
        self.content = content
        self.reason = reason
    }
}

public struct BlocklistParseResult: Sendable {
    public let rules: [DomainRule]
    public let rejectedLines: [RejectedBlocklistLine]

    public init(rules: [DomainRule], rejectedLines: [RejectedBlocklistLine]) {
        self.rules = rules
        self.rejectedLines = rejectedLines
    }

    public var ruleSet: DomainRuleSet {
        DomainRuleSet.build(from: rules)
    }
}

public struct BlocklistRuleSetParseResult: Sendable {
    public let ruleSet: DomainRuleSet
    public let rejectedLines: [RejectedBlocklistLine]

    public init(ruleSet: DomainRuleSet, rejectedLines: [RejectedBlocklistLine]) {
        self.ruleSet = ruleSet
        self.rejectedLines = rejectedLines
    }
}

public struct BlocklistParser: Sendable {
    public let maxLineLength: Int
    public let maxRules: Int

    public init(maxLineLength: Int = 4_096, maxRules: Int = 1_000_000) {
        self.maxLineLength = maxLineLength
        self.maxRules = maxRules
    }

    public func parse(_ text: String, format: BlocklistFormat = .auto) -> BlocklistParseResult {
        var rules: [DomainRule] = []
        var rejected: [RejectedBlocklistLine] = []

        parseLoop: for (offset, rawLine) in text.split(whereSeparator: \.isNewline).enumerated() {
            let lineNumber = offset + 1
            let line = String(rawLine)

            guard line.count <= maxLineLength else {
                rejected.append(RejectedBlocklistLine(lineNumber: lineNumber, content: "", reason: "Line is too long."))
                continue
            }

            guard rules.count < maxRules else {
                rejected.append(RejectedBlocklistLine(lineNumber: lineNumber, content: "", reason: "Rule limit reached."))
                break
            }

            let cleaned = clean(line)
            guard !cleaned.isEmpty else {
                continue
            }

            let candidates = candidateDomains(from: cleaned, format: format)
            guard !candidates.isEmpty else {
                if shouldRecordRejection(cleaned) {
                    rejected.append(RejectedBlocklistLine(lineNumber: lineNumber, content: cleaned, reason: "Unsupported rule syntax."))
                }
                continue
            }

            // A single hosts line can carry several domains; enforce maxRules per rule
            // (not per line) so a multi-host line near the cap can't overshoot it.
            for candidate in candidates {
                guard rules.count < maxRules else {
                    rejected.append(RejectedBlocklistLine(lineNumber: lineNumber, content: "", reason: "Rule limit reached."))
                    break parseLoop
                }

                do {
                    let rule = try DomainRule(domain: candidate.domain, matchesSubdomains: candidate.matchesSubdomains)
                    rules.append(rule)
                } catch {
                    rejected.append(RejectedBlocklistLine(lineNumber: lineNumber, content: cleaned, reason: "Invalid domain."))
                }
            }
        }

        return BlocklistParseResult(rules: dedupe(rules), rejectedLines: rejected)
    }

    public func parseRuleSet(_ text: String, format: BlocklistFormat = .auto) -> BlocklistRuleSetParseResult {
        parseRuleSet(lines: text.split(whereSeparator: \.isNewline), format: format)
    }

    /// Streaming variant: parses directly from the raw payload bytes, decoding one
    /// line at a time (lenient UTF-8) without materializing the whole file as a
    /// `String` or an eager array of line slices. For a multi-megabyte list this
    /// removes the two largest avoidable transients (the whole-file `String` copy and
    /// the `[Substring]` split array), leaving only the result set. Output is identical
    /// to `parseRuleSet(_ text:)` for LF/CR/CRLF-delimited text (the only line endings
    /// real blocklists use); see `BlocklistLineSequence` for the deliberate exclusion of
    /// exotic Unicode separators, which doesn't affect rule output.
    public func parseRuleSet(data: Data, format: BlocklistFormat = .auto) -> BlocklistRuleSetParseResult {
        parseRuleSet(lines: BlocklistLineSequence(data: data), format: format)
    }

    /// Streaming emit: parses the raw payload and hands each accepted, normalized BLOCK
    /// rule to `onRule` WITHOUT building a `DomainRuleSet`. The in-extension streaming
    /// compile uses this to fold each rule directly into the on-disk compact artifact, so
    /// NO per-source dirty `Set<String>` is ever resident — the bottleneck that otherwise
    /// caps how large a single source can be compiled in the packet-tunnel jetsam budget.
    /// Within-source duplicates are NOT removed here (the caller dedups globally). `onRule`
    /// may throw to stop the parse early (e.g. an aggregate-budget gate); the throw
    /// propagates. Allow (`@@`) and rejected lines are skipped silently (no `rejectedLines`
    /// array is accumulated, so a pathological source can't grow an unbounded reject list).
    public func forEachBlockRule(
        data: Data,
        format: BlocklistFormat = .auto,
        onRule: (_ rule: DomainRule) throws -> Void
    ) rethrows {
        try forEachRule(
            lines: BlocklistLineSequence(data: data),
            format: format,
            onReject: { _ in },
            onRule: onRule
        )
    }

    private func parseRuleSet<Lines: Sequence>(
        lines: Lines,
        format: BlocklistFormat
    ) -> BlocklistRuleSetParseResult where Lines.Element: StringProtocol {
        var ruleSet = DomainRuleSet()
        var rejected: [RejectedBlocklistLine] = []
        forEachRule(
            lines: lines,
            format: format,
            onReject: { rejected.append($0) },
            onRule: { ruleSet.insert($0) }
        )
        return BlocklistRuleSetParseResult(ruleSet: ruleSet, rejectedLines: rejected)
    }

    /// Shared per-line core. Both the `String`/`Data` set-building entry points and the
    /// streaming `forEachBlockRule` emit feed it a line sequence so the accept/reject/cap
    /// logic stays in one place. `onRule` is called once per accepted, normalized rule and
    /// may throw (the streaming caller throws to stop early); `onReject` records skipped
    /// lines (the set-building callers collect them; the streaming caller drops them).
    private func forEachRule<Lines: Sequence>(
        lines: Lines,
        format: BlocklistFormat,
        onReject: (RejectedBlocklistLine) -> Void,
        onRule: (DomainRule) throws -> Void
    ) rethrows where Lines.Element: StringProtocol {
        var acceptedRuleCount = 0

        parseLoop: for (offset, rawLine) in lines.enumerated() {
            let lineNumber = offset + 1
            let line = String(rawLine)

            guard line.count <= maxLineLength else {
                onReject(RejectedBlocklistLine(lineNumber: lineNumber, content: "", reason: "Line is too long."))
                continue
            }

            guard acceptedRuleCount < maxRules else {
                onReject(RejectedBlocklistLine(lineNumber: lineNumber, content: "", reason: "Rule limit reached."))
                break
            }

            let cleaned = clean(line)
            guard !cleaned.isEmpty else {
                continue
            }

            let candidates = candidateDomains(from: cleaned, format: format)
            guard !candidates.isEmpty else {
                if shouldRecordRejection(cleaned) {
                    onReject(RejectedBlocklistLine(lineNumber: lineNumber, content: cleaned, reason: "Unsupported rule syntax."))
                }
                continue
            }

            // A single hosts line can carry several domains; enforce maxRules per rule
            // (not per line) so a multi-host line near the cap can't overshoot it.
            for candidate in candidates {
                guard acceptedRuleCount < maxRules else {
                    onReject(RejectedBlocklistLine(lineNumber: lineNumber, content: "", reason: "Rule limit reached."))
                    break parseLoop
                }

                let rule: DomainRule
                do {
                    rule = try DomainRule(domain: candidate.domain, matchesSubdomains: candidate.matchesSubdomains)
                } catch {
                    // Only the domain-normalization failure is a "rejected line"; an
                    // `onRule` throw (e.g. the streaming budget gate) must propagate.
                    onReject(RejectedBlocklistLine(lineNumber: lineNumber, content: cleaned, reason: "Invalid domain."))
                    continue
                }
                try onRule(rule)
                acceptedRuleCount += 1
            }
        }
    }

    private func clean(_ line: String) -> String {
        var line = line.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !line.isEmpty else {
            return ""
        }

        if line.hasPrefix("#") || line.hasPrefix("!") || line.hasPrefix("[") {
            return ""
        }

        if let hash = line.firstIndex(of: "#") {
            line = String(line[..<hash])
        }

        return line.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func candidateDomains(from line: String, format: BlocklistFormat) -> [(domain: String, matchesSubdomains: Bool)] {
        switch format {
        case .plainDomains:
            return parsePlainDomain(line).map { [$0] } ?? []
        case .hosts:
            return parseHosts(line)
        case .adblock:
            return parseAdblock(line).map { [$0] } ?? []
        case .dnsmasq:
            return parseDNSMasq(line).map { [$0] } ?? []
        case .auto:
            // hosts can carry multiple domains; the other formats are one-per-line.
            let hosts = parseHosts(line)
            if !hosts.isEmpty {
                return hosts
            }
            if let domain = parseDNSMasq(line) ?? parseAdblock(line) ?? parsePlainDomain(line) {
                return [domain]
            }
            return []
        }
    }

    private func parsePlainDomain(_ line: String) -> (domain: String, matchesSubdomains: Bool)? {
        var candidate = line

        if candidate.hasPrefix("*.") {
            candidate.removeFirst(2)
            return (candidate, true)
        }

        if candidate.hasPrefix(".") {
            candidate.removeFirst()
            return (candidate, true)
        }

        guard !candidate.contains("/") else {
            return nil
        }

        guard !candidate.contains(" ") && !candidate.contains("\t") else {
            return nil
        }

        return (candidate, true)
    }

    private func parseHosts(_ line: String) -> [(domain: String, matchesSubdomains: Bool)] {
        let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard parts.count >= 2 else {
            return []
        }

        let address = parts[0]
        guard isNullRoutingAddress(address) else {
            return []
        }

        // A hosts line may map one null-route address to several domains
        // (`0.0.0.0 a.com b.com c.com`); block every host, not just the first.
        return parts[1...].map { (domain: $0, matchesSubdomains: true) }
    }

    private func parseAdblock(_ line: String) -> (domain: String, matchesSubdomains: Bool)? {
        guard !line.hasPrefix("@@") else {
            return nil
        }

        if line.hasPrefix("||") {
            var remainder = String(line.dropFirst(2))
            if let terminator = remainder.firstIndex(where: { character in
                character == "^" || character == "/" || character == "$"
            }) {
                remainder = String(remainder[..<terminator])
            }
            return (remainder, true)
        }

        if line.hasPrefix("|http://") || line.hasPrefix("|https://") || line.hasPrefix("http://") || line.hasPrefix("https://") {
            let stripped = line.trimmingCharacters(in: CharacterSet(charactersIn: "|"))
            guard let url = URL(string: stripped), let host = url.host else {
                return nil
            }
            return (host, true)
        }

        return nil
    }

    private func parseDNSMasq(_ line: String) -> (domain: String, matchesSubdomains: Bool)? {
        let prefixes = ["address=/", "server=/", "local=/"]

        for prefix in prefixes where line.hasPrefix(prefix) {
            let start = line.index(line.startIndex, offsetBy: prefix.count)
            guard let end = line[start...].firstIndex(of: "/") else {
                return nil
            }
            return (String(line[start..<end]), true)
        }

        return nil
    }

    private func isNullRoutingAddress(_ address: String) -> Bool {
        address == "0.0.0.0"
            || address == "127.0.0.1"
            || address == "::"
            || address == "::1"
    }

    private func shouldRecordRejection(_ line: String) -> Bool {
        !line.isEmpty && !line.hasPrefix("@@")
    }

    private func dedupe(_ rules: [DomainRule]) -> [DomainRule] {
        Array(Set(rules)).sorted { left, right in
            if left.domain == right.domain {
                return left.matchesSubdomains && !right.matchesSubdomains
            }
            return left.domain < right.domain
        }
    }
}

/// Lazily yields one decoded line at a time from raw blocklist bytes, splitting on
/// LF (`0x0A`), CR (`0x0D`), and CRLF (collapsed to one break). Each line's bytes
/// are decoded as lenient UTF-8 (invalid bytes → U+FFFD), matching the previous
/// whole-file `String(decoding:as:)`. Byte-splitting on LF/CR is UTF-8-safe: those
/// bytes never occur inside a multi-byte sequence. Peak extra memory is O(longest
/// line), not O(file).
///
/// This matches `Character.isNewline` (used by the `String` parse path) for the
/// line terminators that occur in real blocklists — LF, CR, CRLF. It deliberately
/// does NOT treat the exotic Unicode separators VT/FF/NEL/U+2028/U+2029 as breaks:
/// they never appear between two domain tokens on one line in practice, and
/// `clean()` trims them at line ends anyway, so the rule output is unaffected.
private struct BlocklistLineSequence: Sequence {
    let data: Data

    func makeIterator() -> Iterator {
        Iterator(data: data)
    }

    struct Iterator: IteratorProtocol {
        private let data: Data
        private var index: Data.Index

        init(data: Data) {
            self.data = data
            self.index = data.startIndex
        }

        mutating func next() -> String? {
            guard index < data.endIndex else { return nil }

            let lineStart = index
            let terminator = data[index...].firstIndex(where: { $0 == 0x0A || $0 == 0x0D })
            let lineEnd = terminator ?? data.endIndex

            if let terminator {
                if data[terminator] == 0x0D {
                    // Collapse a CRLF pair into a single break; a lone CR still breaks.
                    let afterCR = data.index(after: terminator)
                    index = (afterCR < data.endIndex && data[afterCR] == 0x0A)
                        ? data.index(after: afterCR)
                        : afterCR
                } else {
                    index = data.index(after: terminator)
                }
            } else {
                index = data.endIndex
            }

            return String(decoding: data[lineStart..<lineEnd], as: UTF8.self)
        }
    }
}
