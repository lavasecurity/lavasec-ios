import CryptoKit
import Foundation
import LavaSecKit

/// Opaque process-local display ownership, independent of read-cache mutations.
public struct PresentationOwnerRevision: Sendable {
    private var owners: Set<String>?
    private var generation: UInt64 = 0

    /// Creates a tracker without publishing native account identifiers.
    public init() {}

    /// Returns a stable revision for the same owners and advances on ownership changes.
    public mutating func revision(for ownerIDs: [String]) -> String {
        let current = Set(ownerIDs)
        if current != owners {
            owners = current
            generation &+= 1
        }
        return String(generation)
    }
}

/// Detects actual filter-library replacement without treating cache maintenance as new data.
public struct PresentationLibraryRevision: Sendable {
    private struct Content: Encodable {
        let schema: Int
        let activeFilterID: String
        let filters: [FilterContent]
    }
    private struct FilterContent: Encodable {
        let id: String
        let name: String
        let emoji: String
        let createdAt: Date
        let enabledBlocklistIDs: [String]
        let customBlocklists: [CustomSourceContent]
        let blockedDomains: [String]
        let allowedDomains: [String]
    }
    private struct CustomSourceContent: Encodable {
        let id: String
        let displayName: String
        let sourceURL: URL
        let parseFormat: CatalogBlocklistSource.CatalogParseFormat
        let createdAt: Date
    }
    private var digest: Data?
    private var generation: UInt64 = 0

    /// Creates an empty process-local content tracker.
    public init() {}

    /// Returns an opaque revision after excluding device-local persistence/cache metadata.
    public mutating func revision(for value: FilterLibrary) -> String {
        let content = Content(schema: value.schemaVersion, activeFilterID: value.activeFilterID,
            filters: value.filters.map { filter in
                FilterContent(id: filter.id, name: filter.name, emoji: filter.emoji, createdAt: filter.createdAt,
                    enabledBlocklistIDs: filter.enabledBlocklistIDs.sorted(), customBlocklists: filter.customBlocklists.map {
                        CustomSourceContent(id: $0.id, displayName: $0.displayName, sourceURL: $0.sourceURL,
                            parseFormat: $0.parseFormat, createdAt: $0.createdAt)
                    },
                    blockedDomains: filter.blockedDomains.sorted(), allowedDomains: filter.allowedDomains.sorted())
            })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // Retain a digest only: a deleted library must not survive in a second
        // plaintext frame-identity tracker. Encoding failure conservatively retires.
        let current = (try? encoder.encode(content)).map { Data(SHA256.hash(data: $0)) }
        if current == nil || current != digest {
            digest = current
            generation &+= 1
        }
        return String(generation)
    }
}

/// Native policy for reusable presentation values. Runtime tunnel stores have a
/// separate process purpose and are never exposed through this registry.
public enum PresentationReadPolicy: String, CaseIterable, Sendable {
    /// Activity summaries may be reused only as authenticated in-memory ciphertext.
    case activity = "activity.query"
    /// Catalog results include private custom-source selections; do not retain them.
    case catalog = "catalog.query"
    /// Domain history/search results are transient authorized presentation values.
    case domains = "domains.query"
    /// Network events are transient authorized presentation values.
    case network = "network.query"
    /// Diagnostic details are transient authorized presentation values.
    case stats = "stats.query"
    /// Sharing codes and QR derivatives are never reusable presentation cache entries.
    case share = "share.query"
    /// Domain mutation reviews are transactional, not reusable query results.
    case domainReview = "domains.stage"

    /// Only the Activity consumer currently opts into encrypted reuse.
    /// Every other declared result remains sensitive/no-store, including sharing.
    public var permitsEncryptedReuse: Bool { self == .activity }
}

/// Complete native-owned identity for an authorized presentation result. None of
/// these values is accepted as proof of authorization; the live check is separate.
public struct PresentationCacheScope: Codable, Equatable, Sendable {
    /// Data owner; use a stable native account/local-owner identity, never a JS grant.
    public let owner: String
    /// Canonical resource/range identity, including all result-affecting query inputs.
    public let resource: String
    /// Authoritative source revision, changed by mutation, clear and restore.
    public let sourceRevision: String
    /// Current retention/logging choices affecting the result.
    public let logPolicy: String
    /// Native authentication-policy generation, not a caller-supplied JS epoch.
    public let authorizationPolicyGeneration: String
    /// Presentation payload schema version.
    public let schema: Int

    /// Creates a scope from native-validated identity and current source policy.
    public init(owner: String, resource: String, sourceRevision: String,
                logPolicy: String, authorizationPolicyGeneration: String, schema: Int = 1) {
        self.owner = owner
        self.resource = resource
        self.sourceRevision = sourceRevision
        self.logPolicy = logPolicy
        self.authorizationPolicyGeneration = authorizationPolicyGeneration
        self.schema = schema
    }
}

/// A process-local native cache using AES-GCM and a fresh random 256-bit key.
///
/// This is software authorization plus encrypted memory, NOT a claim that a Lava
/// passcode cryptographically wraps the key. Device Keychain unlock is not used.
/// The owner must invalidate on background/lock, policy/credential changes, owner
/// changes and source deletion. That destroys eligible reuse across those events;
/// no entry/key is persisted, exported, shared with JS or available after relaunch.
/// Authorized plaintext exists only in caller-owned render/source values, which
/// the caller must conceal and release when access ends. Runtime copies cannot be
/// promised zeroized. See docs/architecture/presentation-cache-security.md.
@MainActor
public final class SecurePresentationCache {
    /// A cache operation rejected by policy, revocation, integrity or authorization.
    public enum Failure: Error, Equatable {
        /// An undeclared read must not silently acquire a retention policy.
        case undeclaredRead
        /// Current native authorization does not permit this read.
        case unauthorized
        /// Work began before the last invalidation, or belongs to another service.
        case revoked
    }

    /// Native-only operation capability. The initializer is not public, so a bridge
    /// caller cannot construct one from booleans, cached UI state or an old epoch.
    public struct ReadTicket: Sendable {
        fileprivate let service: UUID
        fileprivate let generation: UUID
        fileprivate let policy: PresentationReadPolicy
        fileprivate let context: Data
    }

    private struct Entry {
        let sealed: Data
        let expiresAt: TimeInterval
    }

    private let service = UUID()
    private var generation = UUID()
    private var key: SymmetricKey?
    private var entries: [Data: Entry] = [:]
    private let maximumEntries: Int
    private let maximumEntryBytes: Int
    private let lifetime: TimeInterval
    private let monotonicNow: () -> TimeInterval

    /// Creates an empty process-only cache with bounded retention and byte size.
    /// The monotonic clock seam supports deterministic expiry tests without sleeps.
    public init(maximumEntries: Int = 8, maximumEntryBytes: Int = 512 * 1024,
                lifetime: TimeInterval = 30,
                monotonicNow: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.maximumEntries = max(1, maximumEntries)
        self.maximumEntryBytes = max(1, maximumEntryBytes)
        self.lifetime = lifetime.isFinite ? max(0, lifetime) : 0
        self.monotonicNow = monotonicNow
    }

    /// Begins an operation only after a live native policy/grant check. The closure
    /// must also validate active lifecycle, owner and current scope. Call it again
    /// at delivery: a ticket does not itself confer permission to publish plaintext.
    public func beginRead(query: String, scope: PresentationCacheScope,
                          authorize: () -> Bool) throws -> ReadTicket {
        guard let policy = PresentationReadPolicy(rawValue: query) else { throw Failure.undeclaredRead }
        guard authorize() else { throw Failure.unauthorized }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // Only the digest is retained. Query terms/owner identities never become
        // plaintext dictionary keys or filesystem metadata. Context binds schema,
        // owner, source, policy and range; AES-GCM authenticates it on every open.
        let context = Data(SHA256.hash(data: try encoder.encode(scope) + Data("presentation-policy-v1:".utf8) + Data(query.utf8)))
        return ReadTicket(service: service, generation: generation, policy: policy, context: context)
    }

    /// Decrypts a matching fresh hit only after native authorization. A no-store
    /// policy always misses; corrupt entries are evicted, never decoded as plaintext.
    public func cachedData(for ticket: ReadTicket, authorize: () -> Bool) throws -> Data? {
        try validate(ticket, authorize: authorize)
        guard ticket.policy.permitsEncryptedReuse else { return nil }
        guard let entry = entries[ticket.context], let key else { return nil }
        guard entry.expiresAt > monotonicNow() else {
            entries.removeValue(forKey: ticket.context)
            return nil
        }
        let plaintext: Data
        do {
            plaintext = try Self.open(entry.sealed, key: key, context: ticket.context)
        } catch {
            entries.removeValue(forKey: ticket.context)
            return nil
        }
        try validate(ticket, authorize: authorize)
        return plaintext
    }

    /// Seals an authorized fresh result. Invalidated tickets cannot resurrect data
    /// after an async source read. Caller must recheck authorization before sending
    /// ANY result, including a no-store result, to a renderer or bridge subscriber.
    @discardableResult
    public func store(_ data: Data, for ticket: ReadTicket, authorize: () -> Bool) throws -> Bool {
        try validate(ticket, authorize: authorize)
        guard ticket.policy.permitsEncryptedReuse,
              data.count <= maximumEntryBytes, lifetime > 0 else { return false }
        let currentKey = key ?? SymmetricKey(size: .bits256)
        let sealed = try Self.seal(data, key: currentKey, context: ticket.context)
        try validate(ticket, authorize: authorize)
        let now = monotonicNow()
        entries = entries.filter { $0.value.expiresAt > now }
        if entries.count >= maximumEntries, entries[ticket.context] == nil,
           let oldest = entries.min(by: { $0.value.expiresAt < $1.value.expiresAt })?.key {
            entries.removeValue(forKey: oldest)
        }
        key = currentKey
        entries[ticket.context] = Entry(sealed: sealed, expiresAt: now + lifetime)
        return true
    }

    /// Checks a ticket immediately before publishing an asynchronous fresh result.
    /// This also applies to declared no-store queries; no fallback bypasses policy.
    public func validate(_ ticket: ReadTicket, authorize: () -> Bool) throws {
        guard ticket.service == service, ticket.generation == generation else { throw Failure.revoked }
        guard authorize() else { throw Failure.unauthorized }
        // A native callback can synchronously publish a policy change. Validate
        // again after it returns so even reentrant invalidation fails closed.
        guard ticket.service == service, ticket.generation == generation else { throw Failure.revoked }
    }

    /// Revokes all pending work and drops the only key reference and all entries.
    /// Safe default for lock/background, account/policy changes, clear and restore.
    public func invalidate() {
        generation = UUID()
        entries.removeAll(keepingCapacity: false)
        key = nil
    }

    // Internal seams exercise the exact crypto used by storage, including wrong
    // keys, swapped authenticated contexts and byte corruption. No export API.
    static func seal(_ data: Data, key: SymmetricKey, context: Data) throws -> Data {
        let box = try AES.GCM.seal(data, using: key, authenticating: context)
        // CryptoKit creates a fresh random 96-bit nonce for each invocation.
        guard let combined = box.combined else { throw CryptoKitError.incorrectParameterSize }
        return combined
    }

    static func open(_ data: Data, key: SymmetricKey, context: Data) throws -> Data {
        try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key, authenticating: context)
    }
}
