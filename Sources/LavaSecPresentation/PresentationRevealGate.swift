import Foundation

/// Coordinates a cover with mounted renderers. Readiness never grants authorization.
public struct PresentationRevealGate: Sendable {
    /// Changes at every privacy boundary so a retired frame cannot release a later cover.
    public private(set) var token = UUID().uuidString
    public private(set) var required = true
    private var mounted = Set<String>()
    private var ready = Set<String>()

    public init() {}

    public mutating func mount(_ id: String) { mounted.insert(id) }

    public mutating func unmount(_ id: String) {
        mounted.remove(id)
        ready.remove(id)
        settle()
    }

    public mutating func conceal() {
        token = UUID().uuidString
        ready.removeAll()
        required = true
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
