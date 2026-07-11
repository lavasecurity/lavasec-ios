import Foundation

/// What a parsed deeplink is allowed to do once handled. There are deliberately
/// only two effects, and **neither one applies a configuration change**:
///   - `.navigate` moves the UI to a screen.
///   - `.stage` opens a review/confirm surface one step *before* any change; the
///     change itself still needs explicit in-app confirmation (and that screen's
///     own auth gate).
///
/// There is intentionally no `.apply`/`.mutate` effect. The "hot path" — adding
/// an allowlist exception, removing a blocklist, changing the DNS resolver,
/// applying an imported config — is therefore *unrepresentable* as a deeplink
/// outcome: a link can carry you to the door, never through it. Adding a third
/// case here is a deliberate, test-guarded act (see `AppDeepLinkEffectTests`).
package enum DeepLinkEffect: CaseIterable, Sendable {
    case navigate
    case stage
}

/// Where an `import` deeplink drops the user inside the importer. Mirrors the
/// app-side `ImportFiltersStartMode`, but carries **no payload** — the filter
/// code is always supplied in-app (scanned, pasted, or typed), so an untrusted
/// configuration never travels inside a URL.
public enum LavaImportDeepLinkEntry: String, Equatable, Sendable {
    case chooser
    case scan
    case enterCode

    /// Maps the path component that follows `import/`. The bare `import` route
    /// has no component and resolves to `.chooser` in the parser, so only the
    /// explicit sub-entries are recognized here.
    public init?(pathComponent: String) {
        switch pathComponent {
        case "scan":
            self = .scan
        case "code", "enter-code":
            self = .enterCode
        default:
            return nil
        }
    }
}

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
    case importFilters(LavaImportDeepLinkEntry)

    /// The effect this intent is permitted to have. Every case is `.navigate` or
    /// `.stage`; none can apply a change. This is the type-level guarantee that a
    /// deeplink cannot compromise the hot path.
    package var effect: DeepLinkEffect {
        switch self {
        case .guardPanel, .filters, .activity, .settings:
            return .navigate
        case .importFilters:
            return .stage
        }
    }

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
        case "import":
            // Bare `import` opens the method chooser; `import/<entry>` jumps to a
            // specific entry. The route never carries a filter code — it only
            // surfaces the importer, which sanitizes + reviews + auth-gates any
            // apply in-app.
            if components.count == 1 {
                self = .importFilters(.chooser)
                return
            }

            guard components.count == 2,
                  let entry = LavaImportDeepLinkEntry(pathComponent: components[1])
            else {
                return nil
            }
            self = .importFilters(entry)
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
