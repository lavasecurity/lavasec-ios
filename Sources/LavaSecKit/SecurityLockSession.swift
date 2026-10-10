import Foundation

/// The lifetime of UI authentication, independent of SwiftUI, React and LAContext.
/// A suspended visit is an intent to restore, never authority to read while locked.
public struct SecurityLockSession: Sendable {
    public struct Ticket: Equatable, Sendable {
        public let token: UInt64
        public let isAppUnlock: Bool
    }

    public private(set) var isForeground = true
    public private(set) var appUnlocked = false
    public private(set) var viewRevision: UInt64 = 1
    public private(set) var surfaces = Set<SecurityProtectedSurface>()
    public private(set) var credentialAuthorized = false
    private var sequence: UInt64 = 1
    private var foregroundRevision: UInt64 = 0
    private var automaticUnlockAttempted = false
    private var suspendedSurfaces = Set<SecurityProtectedSurface>()
    private var suspendedCredential = false

    public init() {}

    public var hasSuspendedVisit: Bool { !suspendedSurfaces.isEmpty || suspendedCredential }

    public mutating func enterForeground() { isForeground = true }

    public mutating func claimAutomaticUnlock() -> Bool {
        guard isForeground, !automaticUnlockAttempted else { return false }
        automaticUnlockAttempted = true
        return true
    }

    /// Idempotent: UIKit, the scene and protected-data callbacks can report the same boundary.
    public mutating func suspend() {
        guard isForeground else { return }
        suspendedSurfaces.formUnion(surfaces.intersection([.filterEditing, .activityViewing, .appSettings]))
        suspendedCredential = suspendedCredential || credentialAuthorized
        revokeForeground()
        isForeground = false
    }

    /// Account/credential loss discards the visit as well as its authorization.
    public mutating func reset() {
        suspendedSurfaces = []
        suspendedCredential = false
        revokeForeground()
    }

    private mutating func revokeForeground() {
        appUnlocked = false
        surfaces = []
        credentialAuthorized = false
        sequence += 1
        foregroundRevision = sequence
        sequence += 1
        viewRevision = sequence
        automaticUnlockAttempted = false
    }

    public mutating func endViewTurn(preservingCredentials: Bool = false) {
        surfaces = []
        if !preservingCredentials { credentialAuthorized = false }
        suspendedSurfaces = []
        suspendedCredential = false
        sequence += 1
        viewRevision = sequence
    }

    public func ticket(appUnlock: Bool = false) -> Ticket {
        Ticket(token: appUnlock ? foregroundRevision : viewRevision, isAppUnlock: appUnlock)
    }

    public func contains(_ ticket: Ticket) -> Bool {
        isForeground && ticket.token == (ticket.isAppUnlock ? foregroundRevision : viewRevision)
    }

    @discardableResult
    public mutating func authorize(_ surface: SecurityProtectedSurface?, ticket: Ticket) -> Bool {
        guard contains(ticket), ticket.isAppUnlock == (surface == .appUnlock) else { return false }
        if surface == .appUnlock {
            appUnlocked = true
            surfaces.formUnion(suspendedSurfaces)
            credentialAuthorized = credentialAuthorized || suspendedCredential
            suspendedSurfaces = []
            suspendedCredential = false
        } else if let surface {
            surfaces.insert(surface)
        } else {
            credentialAuthorized = true
        }
        return true
    }

    /// Enabling App Unlock from an already-authenticated settings visit applies on next resume.
    public mutating func setAppUnlockEnabled(_ enabled: Bool) { appUnlocked = enabled }
}
