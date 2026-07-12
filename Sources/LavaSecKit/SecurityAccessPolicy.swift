import Foundation

public enum SecurityProtectedSurface: String, CaseIterable, Codable, Sendable {
    case appUnlock
    case protectionControl
    case protectionPause
    case filterEditing
    case activityViewing
    case appSettings
}

public enum SecurityProtectedSurfaceStorage {
    /// The UserDefaults key persisting the set of surfaces gated behind app authentication.
    public static let defaultsKeyName = "securityProtectedSurfaces"
    /// Compatibility alias for existing consumers of the public package product.
    public static let defaultsKey = defaultsKeyName

    public static func loadProtectedSurfaces(from defaults: UserDefaults) -> Set<SecurityProtectedSurface> {
        let values = defaults.stringArray(forKey: defaultsKeyName) ?? []
        return Set(values.compactMap(SecurityProtectedSurface.init(rawValue:)))
    }

    public static func saveProtectedSurfaces(
        _ surfaces: Set<SecurityProtectedSurface>,
        to defaults: UserDefaults
    ) {
        let values = surfaces.map(\.rawValue).sorted()
        defaults.set(values, forKey: defaultsKeyName)
    }

    public static func isProtected(
        _ surface: SecurityProtectedSurface,
        defaults: UserDefaults
    ) -> Bool {
        loadProtectedSurfaces(from: defaults).contains(surface)
    }
}

public enum SecurityAccessPolicy: Equatable, Sendable {
    case readOnly
    case requires(SecurityProtectedSurface)

    public var requiredSurface: SecurityProtectedSurface? {
        switch self {
        case .readOnly:
            nil
        case .requires(let surface):
            surface
        }
    }
}
