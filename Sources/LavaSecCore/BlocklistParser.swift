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
    public static let rulesVersion = 2
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
        var ruleSet = DomainRuleSet()
        var rejected: [RejectedBlocklistLine] = []
        var acceptedRuleCount = 0

        parseLoop: for (offset, rawLine) in text.split(whereSeparator: \.isNewline).enumerated() {
            let lineNumber = offset + 1
            let line = String(rawLine)

            guard line.count <= maxLineLength else {
                rejected.append(RejectedBlocklistLine(lineNumber: lineNumber, content: "", reason: "Line is too long."))
                continue
            }

            guard acceptedRuleCount < maxRules else {
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
                guard acceptedRuleCount < maxRules else {
                    rejected.append(RejectedBlocklistLine(lineNumber: lineNumber, content: "", reason: "Rule limit reached."))
                    break parseLoop
                }

                do {
                    let rule = try DomainRule(domain: candidate.domain, matchesSubdomains: candidate.matchesSubdomains)
                    ruleSet.insert(rule)
                    acceptedRuleCount += 1
                } catch {
                    rejected.append(RejectedBlocklistLine(lineNumber: lineNumber, content: cleaned, reason: "Invalid domain."))
                }
            }
        }

        return BlocklistRuleSetParseResult(ruleSet: ruleSet, rejectedLines: rejected)
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
