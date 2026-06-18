import Foundation
import CryptoKit
import Compression

/// A deterministic, security-reviewed subset of a person's filter setup that is
/// safe to hand to someone else (for example, a parent setting up a child's
/// phone by scanning a QR code).
///
/// It intentionally **excludes** anything that could weaken the recipient's
/// protection or leak a private bypass:
///   - `allowedDomains` (allowlist exceptions) are never included.
///   - Custom resolver addresses / credentials are never included.
///   - Local logging preferences and personal progress are never included.
///
/// Only the "what gets blocked" half of the setup travels: curated blocklist
/// selections, custom blocklist sources, and manually blocked domains. The
/// schema is fully `Codable` and parses **partial** payloads — any missing field
/// decodes to an empty value rather than failing — so older or trimmed configs
/// remain importable.
public struct ShareableFilterConfiguration: Equatable, Sendable {
    /// Bumped only when the wire format changes in a way older readers cannot
    /// understand. Additive fields do not require a bump because decoding is
    /// tolerant of missing keys.
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var enabledBlocklistIDs: Set<String>
    public var blockedDomains: Set<String>
    public var customBlocklists: [CustomBlocklistSource]

    public init(
        schemaVersion: Int = ShareableFilterConfiguration.currentSchemaVersion,
        enabledBlocklistIDs: Set<String> = [],
        blockedDomains: Set<String> = [],
        customBlocklists: [CustomBlocklistSource] = []
    ) {
        self.schemaVersion = schemaVersion
        self.enabledBlocklistIDs = enabledBlocklistIDs
        self.blockedDomains = blockedDomains
        self.customBlocklists = customBlocklists
    }

    /// Captures the shareable slice of a full `AppConfiguration`. Allowlist
    /// exceptions and resolver settings are deliberately dropped here.
    public init(configuration: AppConfiguration) {
        // Only share *enabled* custom lists. A disabled-but-kept source would
        // otherwise leak its URL/name and make a share look non-empty while
        // compiling to zero effective rules on import (snapshot preparation only
        // syncs custom sources whose IDs are enabled).
        let enabledCustomBlocklists = configuration.customBlocklists.filter {
            configuration.enabledBlocklistIDs.contains($0.id)
        }
        self.init(
            enabledBlocklistIDs: configuration.enabledBlocklistIDs,
            blockedDomains: configuration.blockedDomains,
            customBlocklists: enabledCustomBlocklists
        )
    }

    /// `true` when there is nothing meaningful to share or apply.
    public var isEmpty: Bool {
        enabledBlocklistIDs.isEmpty && blockedDomains.isEmpty && customBlocklists.isEmpty
    }
}

// MARK: - Deterministic Codable

extension ShareableFilterConfiguration: Codable {
    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "v"
        case enabledBlocklistIDs = "lists"
        case blockedDomains = "blocked"
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
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
            ?? ShareableFilterConfiguration.currentSchemaVersion
        let lists = try container.decodeIfPresent([String].self, forKey: .enabledBlocklistIDs) ?? []
        let blocked = try container.decodeIfPresent([String].self, forKey: .blockedDomains) ?? []
        enabledBlocklistIDs = Set(lists)
        blockedDomains = Set(blocked)
        let wire = try container.decodeIfPresent([WireCustomBlocklist].self, forKey: .customBlocklists) ?? []
        // Rebuild through the validating initializer (drops malformed/unsafe URLs
        // at the trust boundary); the import planner re-checks as defense in depth.
        customBlocklists = wire.compactMap { entry in
            try? CustomBlocklistSource(
                id: entry.id,
                displayName: entry.name,
                rawURL: entry.url,
                parseFormat: entry.format
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        // Sets are encoded as sorted arrays so the same setup always produces an
        // identical, reproducible payload (and therefore an identical code/QR).
        try container.encode(enabledBlocklistIDs.sorted(), forKey: .enabledBlocklistIDs)
        try container.encode(blockedDomains.sorted(), forKey: .blockedDomains)
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
    private static let maxEncodedCodeLength = 16 * 1024
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

        guard configuration.schemaVersion <= currentSchemaVersion else {
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
    /// Returns a copy of this configuration with the **block-side** filter
    /// fields replaced by those from an imported shareable config.
    ///
    /// "Replace" semantics: the recipient's enabled blocklists, custom blocklist
    /// sources, and manually blocked domains become exactly what is passed in.
    /// Everything else — allowlist exceptions, resolver choice, local logging,
    /// account, and protection toggle — is left untouched, so importing can never
    /// silently weaken protection or wipe personal exceptions.
    ///
    /// Callers are expected to pass an already-sanitized subset (see
    /// ``ShareableFilterConfiguration/importPlan(capabilities:)``) so that
    /// unavailable lists, upgrade-gated sources, or over-limit domains have been
    /// dropped before this point.
    func applyingImportedShareableConfiguration(
        _ applied: ShareableFilterConfiguration
    ) -> AppConfiguration {
        var updated = self
        updated.enabledBlocklistIDs = applied.enabledBlocklistIDs
        updated.customBlocklists = applied.customBlocklists
        updated.blockedDomains = applied.blockedDomains
        return updated
    }
}

// MARK: - Import planning (robust against device differences)

/// What this device can actually accept, used to decide which parts of a shared
/// config can be imported and which must be dropped.
public struct ShareableFilterImportCapabilities: Equatable, Sendable {
    /// Curated blocklist IDs that exist in this build's catalog (built-in plus
    /// anything synced). Imported IDs outside this set are treated as unavailable.
    public let availableCuratedBlocklistIDs: Set<String>
    /// IDs an imported *custom* blocklist may not claim — curated and guardrail
    /// list IDs — so a crafted code can't shadow a trusted list with its own URL.
    public let reservedBlocklistIDs: Set<String>
    /// Whether custom blocklist sources are unlocked (Lava Security+).
    public let allowsCustomBlocklists: Bool
    /// The maximum number of manually blocked domains on the current plan.
    public let maxBlockedDomains: Int
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
        allowsCustomBlocklists: Bool,
        maxBlockedDomains: Int,
        maxFilterRules: Int = .max,
        blocklistRuleCounts: [String: Int] = [:],
        preservedRuleCount: Int = 0
    ) {
        self.availableCuratedBlocklistIDs = availableCuratedBlocklistIDs
        self.reservedBlocklistIDs = reservedBlocklistIDs
        self.allowsCustomBlocklists = allowsCustomBlocklists
        self.maxBlockedDomains = maxBlockedDomains
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

        // Custom blocklists: gated behind Lava Security+, then sanitized.
        var supportedCustomBlocklists: [CustomBlocklistSource] = []
        var seenCustomIDs: Set<String> = []
        for source in customBlocklists {
            // Inactive custom sources (present but not enabled — e.g. from a
            // crafted code) compile to nothing, so they never enter the plan.
            guard enabledBlocklistIDs.contains(source.id) else {
                continue
            }

            // Collapse duplicate IDs from a crafted code — persisting two custom
            // sources with the same ID later traps `Dictionary(uniqueKeysWithValues:)`.
            guard seenCustomIDs.insert(source.id).inserted else {
                continue
            }

            guard capabilities.allowsCustomBlocklists else {
                dropped.append(.init(kind: .requiresUpgrade, label: source.displayName))
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

            supportedCustomBlocklists.append(validated)
        }

        let customSourceIDs = Set(customBlocklists.map(\.id))
        let supportedCustomIDs = Set(supportedCustomBlocklists.map(\.id))
        let acceptableListIDs = capabilities.availableCuratedBlocklistIDs.union(supportedCustomIDs)

        // Enabled lists: keep curated IDs that exist here and supported custom
        // IDs. IDs belonging to dropped custom lists are already reported above,
        // so they're skipped silently here to avoid double-counting.
        var supportedListIDs: Set<String> = []
        for id in enabledBlocklistIDs.sorted() {
            if acceptableListIDs.contains(id) {
                supportedListIDs.insert(id)
            } else if customSourceIDs.contains(id) {
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
            if let normalized = try? DomainName.normalize(domain) {
                normalizedDomains.insert(normalized)
            }
        }
        let sortedDomains = normalizedDomains.sorted()
        let keptDomains = sortedDomains.prefix(max(0, capabilities.maxBlockedDomains))
        for domain in sortedDomains.dropFirst(keptDomains.count) {
            dropped.append(.init(kind: .exceedsLimit, label: domain))
        }

        // Filter-rule budget: keep lists whose known rule counts fit the tier
        // ceiling that snapshot preparation enforces, so an over-budget selection
        // (e.g. a Plus setup imported on Free) is trimmed here instead of failing
        // only after the user confirms. Each kept blocked domain also costs a
        // rule, and so do the recipient's preserved allowlist exceptions;
        // unknown-size lists count as 0 known, like the manual picker.
        var runningRuleCount = keptDomains.count + capabilities.preservedRuleCount
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
            budgetedListIDs.contains($0.id)
        }

        let applied = ShareableFilterConfiguration(
            enabledBlocklistIDs: budgetedListIDs,
            blockedDomains: Set(keptDomains),
            customBlocklists: budgetedCustomBlocklists
        )

        return ShareableFilterImportPlan(applied: applied, dropped: dropped)
    }
}

