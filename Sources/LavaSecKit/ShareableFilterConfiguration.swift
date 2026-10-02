import Foundation
import CryptoKit
import Compression

/// Portable selected-filter configuration. Version 2 includes explicit allowed
/// exceptions and stored disabled custom sources, with no account/device/cache data.
/// Codes detect corruption; they do not authenticate or hide the sender's content.
public struct ShareableFilterConfiguration: Equatable, Sendable {
    /// Version 2 requires explicit exceptions, distinguishing an empty set from
    /// the absent exceptions in legacy version 1. Unsupported versions are rejected.
    public static let currentSchemaVersion = 2

    public private(set) var emoji: String?
    public private(set) var schemaVersion: Int
    public private(set) var enabledBlocklistIDs: Set<String>
    public private(set) var blockedDomains: Set<String>
    /// Nil denotes a legacy block-only payload; an empty set deliberately clears exceptions.
    public private(set) var allowedDomains: Set<String>?
    public private(set) var customBlocklists: [CustomBlocklistSource]

    public init(
        schemaVersion: Int = ShareableFilterConfiguration.currentSchemaVersion,
        emoji: String? = nil,
        enabledBlocklistIDs: Set<String> = [],
        blockedDomains: Set<String> = [],
        customBlocklists: [CustomBlocklistSource] = [],
        allowedDomains: Set<String>? = []
    ) {
        self.emoji = schemaVersion == 1 ? emoji.flatMap { FilterIdentityPolicy.isValidEmoji($0) ? $0 : nil } : nil
        self.schemaVersion = schemaVersion
        self.enabledBlocklistIDs = enabledBlocklistIDs
        self.blockedDomains = blockedDomains
        self.customBlocklists = customBlocklists
        self.allowedDomains = schemaVersion >= 2 ? allowedDomains : nil
    }

    /// Captures only filter-scoped values, including disabled stored definitions.
    public init(configuration: AppConfiguration, emoji: String? = nil) {
        self.init(
            enabledBlocklistIDs: configuration.enabledBlocklistIDs,
            blockedDomains: configuration.blockedDomains,
            customBlocklists: configuration.customBlocklists,
            allowedDomains: configuration.allowedDomains
        )
    }
    /// Captures the selected library filter independently from the active filter.
    public init(filter: Filter) {
        self.init(
            enabledBlocklistIDs: filter.enabledBlocklistIDs,
            blockedDomains: filter.blockedDomains,
            customBlocklists: filter.customBlocklists,
            allowedDomains: filter.allowedDomains
        )
    }

    /// `true` when there is nothing meaningful to share or apply.
    public var isEmpty: Bool {
        enabledBlocklistIDs.isEmpty && blockedDomains.isEmpty && customBlocklists.isEmpty && (allowedDomains?.isEmpty ?? true)
    }

    /// Query/fragment data can carry credentials or private identifiers. Full-content
    /// sharing must refuse such a source instead of stripping its parameters silently.
    public var containsPrivateSourceParameters: Bool {
        customBlocklists.contains { source in
            source.sourceURL.query != nil || source.sourceURL.fragment != nil || source.sourceURL.user != nil
        }
    }

    /// Whether this configuration is small enough for a recipient to import — i.e. within
    /// the HIGHER of the two share limits (a QR fits less than a copyable code). Gates on
    /// BOTH caps `decode(configurationCode:)` enforces: the encoded-code length AND the
    /// uncompressed payload size. The latter matters because a highly compressible but very
    /// large setup (e.g. an overlong custom-list name) can yield a short code that still
    /// blows the inflate limit on import (Codex). Beyond either, the setup is too big to share.
    public func fitsShareableCodeCapacity() -> Bool {
        guard Self.deterministicJSONData(for: self).count <= Self.maxInflatedPayloadBytes else {
            return false
        }
        return encodedConfigurationCode().count - Self.codePrefix.count <= Self.maxEncodedCodeLength
    }
}

// MARK: - Deterministic Codable

extension ShareableFilterConfiguration: Codable {
    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "v"
        case emoji
        case enabledBlocklistIDs = "lists"
        case blockedDomains = "blocked"
        case allowedDomains = "allowed"
        case customBlocklists = "custom"
    }

    /// On the wire a custom list is just what's needed to recreate it on import:
    /// id, name, URL, and parse format. Internal bookkeeping (`createdAt`,
    /// `lastAcceptedHash`) is deliberately omitted — it's local state the
    /// recipient regenerates on first sync, and dropping it keeps codes small.
    private struct WireCustomBlocklist: Codable {
        let id: String
        let name: String
        let url: String
        let format: CatalogBlocklistSource.CatalogParseFormat

        enum CodingKeys: String, CodingKey {
            case id = "i"
            case name = "n"
            case url = "u"
            case format = "f"
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedEmoji = try container.decodeIfPresent(String.self, forKey: .emoji)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
            ?? 1
        emoji = schemaVersion == 1 ? decodedEmoji.flatMap { FilterIdentityPolicy.isValidEmoji($0) ? $0 : nil } : nil
        let lists = try container.decodeIfPresent([String].self, forKey: .enabledBlocklistIDs) ?? []
        let blocked = try container.decodeIfPresent([String].self, forKey: .blockedDomains) ?? []
        enabledBlocklistIDs = Set(lists)
        blockedDomains = Set(blocked)
        if schemaVersion >= 2 {
            // Version 2 must be explicit: missing allowed content is not an empty replacement.
            allowedDomains = Set(try container.decode([String].self, forKey: .allowedDomains))
        } else { allowedDomains = nil }
        let wire = try container.decodeIfPresent([WireCustomBlocklist].self, forKey: .customBlocklists) ?? []
        // Reject malformed definitions instead of silently claiming a complete import.
        customBlocklists = try wire.map { entry in
            try CustomBlocklistSource(id: entry.id, displayName: entry.name,
                                      rawURL: entry.url, parseFormat: entry.format)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        // Keep legacy v1 identity readable without transmitting it in new v2 shares.
        if schemaVersion == 1 { try container.encodeIfPresent(emoji, forKey: .emoji) }
        try container.encode(schemaVersion, forKey: .schemaVersion)
        // Sets are encoded as sorted arrays so the same setup always produces an
        // identical, reproducible payload (and therefore an identical code/QR).
        try container.encode(enabledBlocklistIDs.sorted(), forKey: .enabledBlocklistIDs)
        try container.encode(blockedDomains.sorted(), forKey: .blockedDomains)
        if schemaVersion >= 2 { try container.encode((allowedDomains ?? []).sorted(), forKey: .allowedDomains) }
        let wire = customBlocklists
            .sorted { $0.id < $1.id }
            .map { source in
                WireCustomBlocklist(
                    id: source.id,
                    name: source.displayName,
                    url: source.sourceURL.absoluteString,
                    format: source.parseFormat
                )
            }
        try container.encode(wire, forKey: .customBlocklists)
    }
}

// MARK: - Shareable config code (tamper-evident text token)

public enum ShareableFilterConfigurationCodeError: Error, Equatable, Sendable {
    /// The code does not start with the recognized `LF1-` envelope.
    case unrecognizedFormat
    /// The code is structurally valid base64url but the integrity tag does not
    /// match — it was edited, truncated, or corrupted in transit.
    case integrityCheckFailed
    /// The envelope advertises a schema this build is too old to read.
    case unsupportedVersion(Int)
    /// The decoded bytes are not a valid configuration payload.
    case malformedPayload
    /// The encoded code, or its decompressed body, exceeds the import size
    /// budget. Guards against a compression-bomb in an untrusted code.
    case payloadTooLarge
}

public extension ShareableFilterConfiguration {
    /// Human-recognizable prefix: "Lava Filters, format 1".
    static let codePrefix = "LF1-"

    /// Number of leading SHA-256 bytes embedded as an integrity tag. This is an
    /// accidental-tamper / corruption guard, not a cryptographic signature —
    /// there is no shared secret, by design (the code is meant to be shared).
    private static let integrityTagByteCount = 6

    /// Hard caps so an untrusted code can't allocate/parse an oversized payload.
    /// Both are far above any legitimate setup (even a Plus user with hundreds
    /// of blocked domains and several custom lists).
    /// Module-visible (not public) so ``ShareableFilterLink`` can bound a complete
    /// untrusted input up front without duplicating the magic number. Measured on
    /// the encoded body *after* ``codePrefix``, matching the check in
    /// ``decode(configurationCode:)``.
    internal static let maxEncodedCodeLength = 16 * 1024
    private static let maxInflatedPayloadBytes = 512 * 1024

    /// Produces the compact, URL-safe, tamper-evident code that backs both the
    /// copyable text and the QR payload. The JSON is deflate-compressed before
    /// framing so large setups stay well under QR capacity.
    func encodedConfigurationCode() -> String {
        let json = Self.deterministicJSONData(for: self)
        let body = Self.deflate(json)
        let tag = Self.integrityTag(for: body)
        let framed = tag + body
        return Self.codePrefix + Self.base64URLEncode(framed)
    }

    /// Parses a code produced by ``encodedConfigurationCode()``. Throws a
    /// ``ShareableFilterConfigurationCodeError`` describing why a code is
    /// unusable so callers can show a precise message.
    static func decode(configurationCode rawCode: String) throws -> ShareableFilterConfiguration {
        let trimmed = rawCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix(codePrefix.lowercased()) else {
            throw ShareableFilterConfigurationCodeError.unrecognizedFormat
        }

        let encodedBody = String(trimmed.dropFirst(codePrefix.count))
        guard encodedBody.count <= maxEncodedCodeLength else {
            throw ShareableFilterConfigurationCodeError.payloadTooLarge
        }
        guard let framed = base64URLDecode(encodedBody), framed.count > integrityTagByteCount else {
            throw ShareableFilterConfigurationCodeError.unrecognizedFormat
        }

        let tag = framed.prefix(integrityTagByteCount)
        let body = Data(framed.suffix(from: framed.index(framed.startIndex, offsetBy: integrityTagByteCount)))
        guard integrityTag(for: body) == Data(tag) else {
            throw ShareableFilterConfigurationCodeError.integrityCheckFailed
        }

        let json: Data
        switch boundedInflate(body, limit: maxInflatedPayloadBytes) {
        case .data(let inflated):
            json = inflated
        case .tooLarge:
            throw ShareableFilterConfigurationCodeError.payloadTooLarge
        case .notCompressed:
            // Rare: `deflate` fell back to raw bytes; treat the body as the JSON.
            json = body
        }

        let decoder = JSONDecoder()
        let configuration: ShareableFilterConfiguration
        do {
            configuration = try decoder.decode(ShareableFilterConfiguration.self, from: json)
        } catch {
            throw ShareableFilterConfigurationCodeError.malformedPayload
        }

        guard (1...currentSchemaVersion).contains(configuration.schemaVersion) else {
            throw ShareableFilterConfigurationCodeError.unsupportedVersion(configuration.schemaVersion)
        }

        return configuration
    }

    // MARK: Internals

    private static func deterministicJSONData(for configuration: ShareableFilterConfiguration) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // Encoding cannot fail for this value type; fall back to an empty object
        // rather than trapping so a share action never crashes the app.
        return (try? encoder.encode(configuration)) ?? Data("{}".utf8)
    }

    private static func integrityTag(for body: Data) -> Data {
        let digest = SHA256.hash(data: body)
        return Data(digest.prefix(integrityTagByteCount))
    }

    /// zlib-compress the payload. Falls back to the raw bytes if compression
    /// somehow fails; `inflate` mirrors this so the pair is always symmetric.
    private static func deflate(_ data: Data) -> Data {
        guard let compressed = try? (data as NSData).compressed(using: .zlib) as Data else {
            return data
        }
        return compressed
    }

    private enum InflateOutcome {
        case data(Data)
        case tooLarge
        case notCompressed
    }

    /// Streaming inverse of `deflate` that stops once output passes `limit`, so a
    /// crafted code can't expand into an arbitrarily large allocation. Returns
    /// `.notCompressed` when the body isn't a deflate stream (the rare `deflate`
    /// fallback), letting the caller treat it as raw JSON.
    private static func boundedInflate(_ input: Data, limit: Int) -> InflateOutcome {
        guard !input.isEmpty else {
            return .notCompressed
        }

        let bufferSize = 32_768
        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { destination.deallocate() }

        var stream = compression_stream(
            dst_ptr: destination,
            dst_size: bufferSize,
            src_ptr: UnsafePointer(destination),
            src_size: 0,
            state: nil
        )
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            return .notCompressed
        }
        defer { compression_stream_destroy(&stream) }

        return input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> InflateOutcome in
            guard let source = raw.bindMemory(to: UInt8.self).baseAddress else {
                return .notCompressed
            }
            stream.src_ptr = source
            stream.src_size = input.count

            var output = Data()
            while true {
                stream.dst_ptr = destination
                stream.dst_size = bufferSize
                let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                switch status {
                case COMPRESSION_STATUS_OK, COMPRESSION_STATUS_END:
                    output.append(destination, count: bufferSize - stream.dst_size)
                    if output.count > limit {
                        return .tooLarge
                    }
                    if status == COMPRESSION_STATUS_END {
                        return .data(output)
                    }
                default:
                    return .notCompressed
                }
            }
        }
    }

    private static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func base64URLDecode(_ string: String) -> Data? {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 {
            base64.append(String(repeating: "=", count: 4 - remainder))
        }
        return Data(base64Encoded: base64)
    }
}

// MARK: - Applying an imported config

public extension AppConfiguration {
    /// Replaces filter content only. Legacy v1 payloads preserve local exceptions;
    /// v2 explicitly replaces them, including an intentionally empty set.
    func applyingImportedShareableConfiguration(
        _ applied: ShareableFilterConfiguration
    ) -> AppConfiguration {
        var updated = self
        updated.enabledBlocklistIDs = applied.enabledBlocklistIDs
        updated.customBlocklists = applied.customBlocklists
        updated.blockedDomains = applied.blockedDomains
        if let allowed = applied.allowedDomains { updated.allowedDomains = allowed }
        return updated
    }
}

public extension ShareableFilterConfiguration {
    /// Reviews every reconciled filter-content addition and removal.
    func replacementSummary(for target: Filter) -> FilterReplacementSummary {
        var replacement = target
        replacement.enabledBlocklistIDs = enabledBlocklistIDs
        replacement.customBlocklists = customBlocklists
        replacement.blockedDomains = blockedDomains
        if let allowedDomains { replacement.allowedDomains = allowedDomains }
        // The wire omits creation dates and accepted hashes. Compare only the source
        // definition it can carry; local metadata must not invent a removal/re-addition.
        var reviewedTarget = target
        reviewedTarget.customBlocklists = target.customBlocklists.map { previous in
            customBlocklists.first {
                $0.id == previous.id && $0.displayName == previous.displayName
                    && $0.sourceURL == previous.sourceURL && $0.parseFormat == previous.parseFormat
            } ?? previous
        }
        return FilterReplacementSummary(before: reviewedTarget, after: replacement)
    }
}

// MARK: - Import planning (robust against device differences)

/// What this device can actually accept, used to decide which parts of a shared
/// config can be imported and which must be dropped.
public struct ShareableFilterImportCapabilities: Equatable, Sendable {
    /// Curated blocklist IDs offered by the recipient's server catalog.
    /// Bundled definitions and existing selections do not grant import availability.
    public let availableCuratedBlocklistIDs: Set<String>
    /// Known canonical/legacy catalog URLs carried as custom sources in a share.
    /// These must use catalog availability rather than bypass it with a custom ID.
    public let catalogSourceIDsByCustomURL: [URL: String]
    /// IDs an imported *custom* blocklist may not claim — curated and guardrail
    /// list IDs — so a crafted code can't shadow a trusted list with its own URL.
    public let reservedBlocklistIDs: Set<String>
    /// Whether custom blocklist sources are unlocked (Lava Security+).
    public let allowsCustomBlocklists: Bool
    /// The maximum number of manually blocked domains on the current plan.
    public let maxBlockedDomains: Int
    /// Maximum allowed exceptions accepted by the recipient.
    public let maxAllowedDomains: Int
    /// Current threat rules used by the same validation as manual exception editing.
    public let nonAllowableThreatRules: DomainRuleSet
    /// The tier ceiling on total compiled filter rules (what snapshot preparation
    /// enforces). Defaults to "no limit" so callers that don't model it opt out.
    public let maxFilterRules: Int
    /// Known per-list rule counts for available lists. Lists absent here count as
    /// 0 known rules (their true size is resolved at compile time, by design),
    /// mirroring the manual picker's soft-budget behavior.
    public let blocklistRuleCounts: [String: Int]
    /// Rules the recipient already has that the import preserves (their allowlist
    /// exceptions). Snapshot preparation counts these against `maxFilterRules`
    /// too, so the budget has to start from them.
    public let preservedRuleCount: Int

    public init(
        availableCuratedBlocklistIDs: Set<String>,
        reservedBlocklistIDs: Set<String> = [],
        catalogSourceIDsByCustomURL: [URL: String] = [:],
        allowsCustomBlocklists: Bool,
        maxBlockedDomains: Int,
        maxFilterRules: Int = .max,
        blocklistRuleCounts: [String: Int] = [:],
        preservedRuleCount: Int = 0,
        maxAllowedDomains: Int = .max,
        nonAllowableThreatRules: DomainRuleSet = DomainRuleSet()
    ) {
        self.availableCuratedBlocklistIDs = availableCuratedBlocklistIDs
        self.catalogSourceIDsByCustomURL = catalogSourceIDsByCustomURL
        self.reservedBlocklistIDs = reservedBlocklistIDs
        self.allowsCustomBlocklists = allowsCustomBlocklists
        self.maxBlockedDomains = maxBlockedDomains
        self.maxAllowedDomains = maxAllowedDomains
        self.nonAllowableThreatRules = nonAllowableThreatRules
        self.maxFilterRules = maxFilterRules
        self.blocklistRuleCounts = blocklistRuleCounts
        self.preservedRuleCount = preservedRuleCount
    }
}

/// The result of reconciling a shared config against this device: the subset
/// that will actually be applied, plus a human-describable list of what was
/// dropped and why.
public struct ShareableFilterImportPlan: Equatable, Sendable {
    public struct DroppedEntry: Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            /// A curated blocklist that isn't in this build's catalog.
            case unavailableBlocklist
            /// A custom blocklist that needs Lava Security+ to use.
            case requiresUpgrade
            /// A manually blocked domain beyond the current plan's limit.
            case exceedsLimit
            /// A malformed or prohibited manually entered domain.
            case invalidDomain
            /// A custom blocklist rejected for safety: an unsafe URL (non-HTTPS,
            /// credentialed, or private-network) or an ID that shadows a trusted
            /// list. LF1 codes are unsigned, so imported sources are never trusted.
            case unsafeSource
            /// A blocklist dropped because keeping it would exceed the recipient's
            /// tier filter-rule budget (e.g. a Plus setup imported on Free).
            case exceedsRuleBudget
        }

        public let kind: Kind
        public let label: String

        public init(kind: Kind, label: String) {
            self.kind = kind
            self.label = label
        }
    }

    /// The sanitized subset safe to apply on this device.
    public let applied: ShareableFilterConfiguration
    /// Everything that couldn't be imported, in a stable order.
    public let dropped: [DroppedEntry]

    public init(applied: ShareableFilterConfiguration, dropped: [DroppedEntry]) {
        self.applied = applied
        self.dropped = dropped
    }

    public var hasUnsupportedEntries: Bool { !dropped.isEmpty }

    public func droppedCount(of kind: DroppedEntry.Kind) -> Int {
        dropped.lazy.filter { $0.kind == kind }.count
    }
}

public extension ShareableFilterConfiguration {
    /// Reconciles this shared config against a device's capabilities, returning
    /// the subset that can be applied and a list of dropped entries. Importing
    /// `A + B + C` onto a device that only supports `A + B` yields an `applied`
    /// of `A + B` and one dropped entry for `C` — never a failure.
    ///
    /// Because LF1 codes are unsigned and may come from anyone, imported custom
    /// blocklists are treated as untrusted: each is re-validated through the same
    /// HTTPS/public-host/no-credentials checks as the manual "add custom list"
    /// path, and any custom source whose ID shadows a curated or guardrail list
    /// is rejected so it can't silently override a trusted list's rules.
    func importPlan(capabilities: ShareableFilterImportCapabilities) -> ShareableFilterImportPlan {
        var dropped: [ShareableFilterImportPlan.DroppedEntry] = []

        // Validate custom sources and canonicalize known catalog URLs before the Plus gate.
        var supportedCustomBlocklists: [CustomBlocklistSource] = []
        var matchedCuratedIDs: Set<String> = []
        var seenCustomIDs: Set<String> = []
        for source in customBlocklists {
            // Collapse duplicate IDs from a crafted code — persisting two custom
            // sources with the same ID later traps `Dictionary(uniqueKeysWithValues:)`.
            guard seenCustomIDs.insert(source.id).inserted else {
                continue
            }

            // An imported custom ID must not claim a curated/guardrail list ID,
            // or it would shadow that trusted list with its own URL.
            if capabilities.reservedBlocklistIDs.contains(source.id) {
                dropped.append(.init(kind: .unsafeSource, label: source.displayName))
                continue
            }

            // Re-run the validating initializer the manual path uses, so an
            // unsigned code can't smuggle in a non-HTTPS, credentialed, or
            // private-network URL for the snapshot syncer to fetch.
            guard let validated = try? CustomBlocklistSource(
                id: source.id,
                displayName: source.displayName,
                rawURL: source.sourceURL.absoluteString,
                parseFormat: source.parseFormat,
                createdAt: source.createdAt,
                lastAcceptedHash: source.lastAcceptedHash
            ) else {
                dropped.append(.init(kind: .unsafeSource, label: source.displayName))
                continue
            }

            if let catalogID = capabilities.catalogSourceIDsByCustomURL[validated.sourceURL] {
                if !capabilities.availableCuratedBlocklistIDs.contains(catalogID) {
                    // Inactive definitions also carry references: do not import a withdrawn source.
                    dropped.append(.init(kind: .unavailableBlocklist, label: source.displayName))
                    continue
                } else if enabledBlocklistIDs.contains(source.id) {
                    matchedCuratedIDs.insert(catalogID)
                    continue
                }
                // Keep an available inactive definition without enabling it; the normal Plus gate applies.
            }
            guard capabilities.allowsCustomBlocklists else {
                dropped.append(.init(kind: .requiresUpgrade, label: source.displayName))
                continue
            }

            supportedCustomBlocklists.append(validated)
        }

        let customSourceIDs = Set(customBlocklists.map(\.id))
        let supportedCustomIDs = Set(supportedCustomBlocklists.map(\.id))
        let acceptableListIDs = capabilities.availableCuratedBlocklistIDs.union(supportedCustomIDs)

        // Enabled lists: keep curated IDs that exist here and supported custom
        // IDs. IDs belonging to dropped custom lists are already reported above,
        // so they're skipped silently here to avoid double-counting.
        var supportedListIDs = matchedCuratedIDs
        for id in enabledBlocklistIDs.sorted() {
            if acceptableListIDs.contains(id) {
                supportedListIDs.insert(id)
            } else if customSourceIDs.contains(id) && !capabilities.reservedBlocklistIDs.contains(id) {
                continue
            } else {
                dropped.append(.init(kind: .unavailableBlocklist, label: id))
            }
        }

        // Blocked domains: normalize through the same primitive the manual
        // editor uses, so the preview count matches what will actually compile
        // into rules. Invalid entries from a crafted code (single labels, IPs,
        // junk) are dropped here instead of being counted toward a "non-empty"
        // import that would otherwise contribute zero effective rules.
        var normalizedDomains: Set<String> = []
        for domain in blockedDomains {
            if let normalized = try? DomainName.normalize(domain) { normalizedDomains.insert(normalized) }
            else { dropped.append(.init(kind: .invalidDomain, label: domain)) }
        }
        let sortedDomains = normalizedDomains.sorted()
        let keptDomains = sortedDomains.prefix(max(0, capabilities.maxBlockedDomains))
        for domain in sortedDomains.dropFirst(keptDomains.count) {
            dropped.append(.init(kind: .exceedsLimit, label: domain))
        }

        let validator = AllowlistValidator(nonAllowableThreatRules: capabilities.nonAllowableThreatRules)
        var normalizedAllowed: Set<String> = []
        for domain in (allowedDomains ?? []).sorted() {
            let result = validator.validate(domain)
            if result.isAllowed, let normalized = result.normalizedDomain { normalizedAllowed.insert(normalized) }
            else { dropped.append(.init(kind: .invalidDomain, label: domain)) }
        }
        let keptAllowed = Set(normalizedAllowed.sorted().prefix(max(0, capabilities.maxAllowedDomains)))
        for domain in normalizedAllowed.subtracting(keptAllowed).sorted() {
            dropped.append(.init(kind: .exceedsLimit, label: domain))
        }

        // Filter-rule budget: keep lists whose known rule counts fit the tier
        // ceiling that snapshot preparation enforces, so an over-budget selection
        // (e.g. a Plus setup imported on Free) is trimmed here instead of failing
        // only after the user confirms. Each kept blocked domain also costs a
        // rule, and so do the recipient's preserved allowlist exceptions;
        // unknown-size lists count as 0 known, like the manual picker.
        var runningRuleCount = keptDomains.count + (allowedDomains == nil ? capabilities.preservedRuleCount : keptAllowed.count)
        var budgetedListIDs: Set<String> = []
        for id in supportedListIDs.sorted() {
            let cost = capabilities.blocklistRuleCounts[id] ?? 0
            if runningRuleCount + cost <= capabilities.maxFilterRules {
                runningRuleCount += cost
                budgetedListIDs.insert(id)
            } else {
                dropped.append(.init(kind: .exceedsRuleBudget, label: id))
            }
        }
        let budgetedCustomBlocklists = supportedCustomBlocklists.filter {
            !enabledBlocklistIDs.contains($0.id) || budgetedListIDs.contains($0.id)
        }

        let applied = ShareableFilterConfiguration(
            schemaVersion: schemaVersion,
            emoji: emoji,
            enabledBlocklistIDs: budgetedListIDs,
            blockedDomains: Set(keptDomains),
            customBlocklists: budgetedCustomBlocklists,
            allowedDomains: allowedDomains == nil ? nil : keptAllowed
        )

        return ShareableFilterImportPlan(applied: applied, dropped: dropped)
    }
}
