import Foundation
import LavaSecKit

/// A setup visit is transient. Presentation cannot skip the VPN prerequisite or
/// navigate a step it has never visited; platform services own actual setup.
public struct OnboardingVisitState: Sendable {
    public enum Page: Int, CaseIterable, Sendable { case lava, features, vpn, protectionLevel, connectionQuality, done }
    public private(set) var page = Page.lava
    public private(set) var history: [Page] = []
    public private(set) var visited: Set<Page> = [.lava]
    public var protectionLevel = OnboardingProtectionLevel.recommended
    public var encryptedFallback: Bool
    public var dnsProfile = true
    public init(encryptedFallback: Bool) { self.encryptedFallback = encryptedFallback }
    public func canNavigate(to destination: Page, vpnInstalled: Bool, busy: Bool, revisit: Bool = false) -> Bool {
        !busy && destination != page && (destination.rawValue <= Page.vpn.rawValue || vpnInstalled)
            && (destination.rawValue == page.rawValue + 1 || visited.contains(destination))
            && (!revisit || visited.contains(destination))
    }
    @discardableResult public mutating func move(to destination: Page, vpnInstalled: Bool, busy: Bool, revisit: Bool = false) -> Bool {
        guard canNavigate(to: destination, vpnInstalled: vpnInstalled, busy: busy, revisit: revisit) else { return false }
        history.append(page); visited.insert(destination); page = destination; return true
    }
    public var backDestination: Page? { history.last }
    @discardableResult public mutating func goBack(busy: Bool) -> Bool {
        guard !busy, let previous = history.popLast() else { return false }; page = previous; return true
    }
}
