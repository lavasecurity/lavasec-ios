import Foundation

/// Private native runtime leases. Snapshot readers cannot claim another
/// renderer's credential owner, and a detached runtime can never claim again.
public struct PresentationRuntimeOwnership: Sendable {
    /// A native session's logical visit and unique instance nonce.
    public struct Owner: Hashable, Sendable {
        /// The bounded native session slot, such as backup or passcode.
        public let kind: String
        /// The current native visit identifier.
        public let id: String
        /// A fresh per-instance nonce, independent of reusable memory addresses.
        public let identity: String
        /// Creates a nonsecret identity; it carries no read or service authority.
        public init(kind: String, id: String, identity: String) { self.kind = kind; self.id = id; self.identity = identity }
    }
    private var active = Set<UUID>()
    private var retired = Set<UUID>()
    private var owners: [String: (owner: Owner, runtime: UUID)] = [:]
    /// Creates an empty lifetime with no admitted native modules.
    public init() {}
    /// Admits a new module nonce; an invalidated nonce cannot be reopened.
    @discardableResult public mutating func register(_ runtime: UUID) -> Bool {
        guard !retired.contains(runtime) else { return false }
        active.insert(runtime); return true
    }
    /// Whether work from this native module may still claim presentation owners.
    public func isActive(_ runtime: UUID) -> Bool { active.contains(runtime) }
    /// Whether any native module remains to own an unclaimed native entry.
    public var hasActiveRuntimes: Bool { !active.isEmpty }
    /// Claims the current instance, releasing a replaced instance of that kind.
    /// An admitted credential presenter may transfer the same instance's lease.
    @discardableResult public mutating func claim(_ owner: Owner, runtime: UUID, presenter: Bool = false) -> Bool {
        guard active.contains(runtime) else { return false }
        if let current = owners[owner.kind], current.owner == owner, current.runtime != runtime, !presenter { return false }
        // Each native kind has only one current session. Replacement releases
        // its old identity instead of accumulating every visit in a long run.
        owners[owner.kind] = (owner, runtime); return true
    }
    /// Invalidate before cleanup so suspended work cannot add another lease.
    @discardableResult public mutating func invalidate(_ runtime: UUID) -> Set<Owner> {
        active.remove(runtime); retired.insert(runtime)
        let result = Set(owners.values.compactMap { $0.runtime == runtime ? $0.owner : nil })
        for owner in result { owners.removeValue(forKey: owner.kind) }
        return result
    }
}

/// Coordinates a cover with mounted renderers. Readiness never grants authorization.
public struct PresentationRevealGate: Sendable {
    /// Changes at every privacy boundary so a retired frame cannot release a later cover.
    public private(set) var token = UUID().uuidString
    public private(set) var required = true
    private var coverWasSelectedAtBoundary: Bool
    public var appCoverRequired: Bool { required && coverWasSelectedAtBoundary }
    private var mounted = Set<String>()
    private var ready = Set<String>()

    public init(appCoverRequired: Bool = true) { coverWasSelectedAtBoundary = appCoverRequired }

    public mutating func mount(_ id: String) { mounted.insert(id) }

    public mutating func unmount(_ id: String) {
        mounted.remove(id)
        ready.remove(id)
        settle()
    }

    public mutating func conceal(appCoverRequired: Bool = true) {
        token = UUID().uuidString
        ready.removeAll()
        required = true
        coverWasSelectedAtBoundary = appCoverRequired
    }

    /// The caller must independently check current native foreground authorization.
    public mutating func acknowledge(_ id: String, token: String, authorized: Bool) {
        guard authorized, token == self.token, mounted.contains(id) else { return }
        ready.insert(id)
        settle()
    }

    private mutating func settle() {
        if !mounted.isEmpty && mounted.isSubset(of: ready) { required = false }
    }
}
