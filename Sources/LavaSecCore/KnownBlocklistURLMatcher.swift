import Foundation

public enum KnownBlocklistURLMatcher {
    public static func catalogSourceID(for url: URL) -> String? {
        guard let key = canonicalURLKey(for: url) else {
            return nil
        }

        return catalogSourceIDsByURLKey[key]
    }

    public static func catalogSourceID(for rawURL: String) -> String? {
        guard let url = URL(string: rawURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }

        return catalogSourceID(for: url)
    }

    private static let catalogSourceIDsByURLKey: [String: String] = Dictionary(
        uniqueKeysWithValues: DefaultCatalog.curatedSources.compactMap { source in
            guard let key = canonicalURLKey(for: source.sourceURL) else {
                return nil
            }

            return (key, source.id)
        }
    )

    private static func canonicalURLKey(for url: URL) -> String? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.query == nil,
              components.fragment == nil,
              let scheme = components.scheme?.lowercased(),
              scheme == "https",
              let host = components.host?.lowercased(),
              !host.isEmpty
        else {
            return nil
        }

        components.scheme = scheme
        components.host = host
        let port = components.port == 443 ? nil : components.port
        let path = normalizedPath(components.percentEncodedPath)
        return [scheme, host, port.map(String.init), path].compactMap { $0 }.joined(separator: "|")
    }

    private static func normalizedPath(_ rawPath: String) -> String {
        var path = rawPath.isEmpty ? "/" : rawPath
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }
}

public extension AppConfiguration {
    func migratingKnownCustomBlocklistsToCatalogSources() -> AppConfiguration {
        var updatedConfiguration = self
        var migratedCatalogSourceIDsByCustomID: [String: String] = [:]

        updatedConfiguration.customBlocklists.removeAll { source in
            guard let catalogSourceID = KnownBlocklistURLMatcher.catalogSourceID(for: source.sourceURL) else {
                return false
            }

            migratedCatalogSourceIDsByCustomID[source.id] = catalogSourceID
            return true
        }

        guard !migratedCatalogSourceIDsByCustomID.isEmpty else {
            return updatedConfiguration
        }

        for (customSourceID, catalogSourceID) in migratedCatalogSourceIDsByCustomID {
            if updatedConfiguration.enabledBlocklistIDs.remove(customSourceID) != nil {
                updatedConfiguration.enabledBlocklistIDs.insert(catalogSourceID)
            }
        }

        return updatedConfiguration
    }
}
