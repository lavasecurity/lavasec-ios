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

extension KnownBlocklistURLMatcher {
    /// Rewrite a filter-scoped `(enabledBlocklistIDs, customBlocklists)` pair so any custom
    /// list whose URL is recognised as a known catalog source becomes that catalog source:
    /// the custom entry is dropped and, if it was enabled, its catalog id takes its place in
    /// `enabledBlocklistIDs`. The single source of truth shared by every surface that hosts
    /// these two fields — the device-global `AppConfiguration` and each hosted `Filter` —
    /// so a backup restored onto a new device migrates ALL of its filters, not just the
    /// active one mirrored into the config.
    static func migratingKnownCustomBlocklists(
        enabledBlocklistIDs: Set<String>,
        customBlocklists: [CustomBlocklistSource]
    ) -> (enabledBlocklistIDs: Set<String>, customBlocklists: [CustomBlocklistSource]) {
        var migratedCatalogSourceIDsByCustomID: [String: String] = [:]
        var remainingCustomBlocklists = customBlocklists
        remainingCustomBlocklists.removeAll { source in
            guard let catalogSourceID = catalogSourceID(for: source.sourceURL) else {
                return false
            }
            migratedCatalogSourceIDsByCustomID[source.id] = catalogSourceID
            return true
        }

        guard !migratedCatalogSourceIDsByCustomID.isEmpty else {
            return (enabledBlocklistIDs, customBlocklists)
        }

        var migratedEnabledIDs = enabledBlocklistIDs
        for (customSourceID, catalogSourceID) in migratedCatalogSourceIDsByCustomID {
            if migratedEnabledIDs.remove(customSourceID) != nil {
                migratedEnabledIDs.insert(catalogSourceID)
            }
        }

        return (migratedEnabledIDs, remainingCustomBlocklists)
    }
}

public extension AppConfiguration {
    func migratingKnownCustomBlocklistsToCatalogSources() -> AppConfiguration {
        let migrated = KnownBlocklistURLMatcher.migratingKnownCustomBlocklists(
            enabledBlocklistIDs: enabledBlocklistIDs,
            customBlocklists: customBlocklists
        )
        var updatedConfiguration = self
        updatedConfiguration.enabledBlocklistIDs = migrated.enabledBlocklistIDs
        updatedConfiguration.customBlocklists = migrated.customBlocklists
        return updatedConfiguration
    }
}

public extension Filter {
    /// Migrate THIS filter's known custom blocklists to catalog sources (see
    /// ``AppConfiguration/migratingKnownCustomBlocklistsToCatalogSources()``).
    func migratingKnownCustomBlocklistsToCatalogSources() -> Filter {
        let migrated = KnownBlocklistURLMatcher.migratingKnownCustomBlocklists(
            enabledBlocklistIDs: enabledBlocklistIDs,
            customBlocklists: customBlocklists
        )
        var copy = self
        copy.enabledBlocklistIDs = migrated.enabledBlocklistIDs
        copy.customBlocklists = migrated.customBlocklists
        return copy
    }
}

public extension FilterLibrary {
    /// Migrate EVERY hosted filter's known custom blocklists to catalog sources. Applied to
    /// a restored backup library so hosted (non-active) filters get the same known-URL →
    /// catalog rewrite the active filter receives via the config migration.
    func migratingKnownCustomBlocklistsToCatalogSources() -> FilterLibrary {
        FilterLibrary(
            filters: filters.map { $0.migratingKnownCustomBlocklistsToCatalogSources() },
            activeFilterID: activeFilterID,
            schemaVersion: schemaVersion
        )
    }
}
