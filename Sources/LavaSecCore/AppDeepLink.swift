import Foundation

public enum LavaSettingsDeepLink: Equatable, Sendable {
    case account
    case upgrade
    case dnsResolver
    case privacyData
    case security
    case feedback
    case legalNotices
    case nerdStats

    public init?(pathComponent: String) {
        switch pathComponent {
        case "account":
            self = .account
        case "upgrade":
            self = .upgrade
        case "dns-resolver":
            self = .dnsResolver
        case "privacy-data", "clear-local-logs":
            self = .privacyData
        case "security":
            self = .security
        case "feedback":
            self = .feedback
        case "legal-notices":
            self = .legalNotices
        case "nerd-stats":
            self = .nerdStats
        default:
            return nil
        }
    }
}

public enum LavaAppDeepLink: Equatable, Sendable {
    case guardPanel
    case filters
    case activity
    case settings(LavaSettingsDeepLink?)

    public init?(url: URL) {
        let components = Self.routeComponents(from: url)
        guard !components.isEmpty else {
            return nil
        }

        switch components[0] {
        case "guard":
            guard components.count == 1 else {
                return nil
            }
            self = .guardPanel
        case "filters":
            guard components.count == 1 else {
                return nil
            }
            self = .filters
        case "activity":
            guard components.count == 1 else {
                return nil
            }
            self = .activity
        case "settings":
            guard components.count <= 2 else {
                return nil
            }

            if components.count == 1 {
                self = .settings(nil)
                return
            }

            guard let settingsRoute = LavaSettingsDeepLink(pathComponent: components[1]) else {
                return nil
            }
            self = .settings(settingsRoute)
        default:
            return nil
        }
    }

    private static func routeComponents(from url: URL) -> [String] {
        guard let scheme = url.scheme?.lowercased() else {
            return []
        }

        switch scheme {
        case "https":
            guard url.host?.lowercased() == "lavasecurity.app" else {
                return []
            }

            let pathComponents = normalizedPathComponents(url.pathComponents)
            guard pathComponents.first == "app" else {
                return []
            }
            return Array(pathComponents.dropFirst())
        case "lavasecurity":
            let host = url.host.map { [$0] } ?? []
            return host + normalizedPathComponents(url.pathComponents)
        default:
            return []
        }
    }

    private static func normalizedPathComponents(_ components: [String]) -> [String] {
        components.filter { component in
            component != "/" && !component.isEmpty
        }
    }
}
