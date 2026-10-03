import Foundation
import LavaSecKit

/// Matches supported upstream blocklist URLs to curated catalog source identifiers.
public enum KnownBlocklistURLMatcher {
    /// Returns a bundled/legacy source ID or one learned from trusted catalog metadata.
    /// Additional URLs with query parameters match exactly; canonical matching never drops a query.
    public static func catalogSourceID(for url: URL, additionalSourceIDsByURL: [URL: String] = [:]) -> String? {
        if let sourceID = additionalSourceIDsByURL[url] { return sourceID }
        guard let key = canonicalURLKey(for: url) else { return nil }
        if let sourceID = additionalSourceIDsByURL
            .filter({ canonicalURLKey(for: $0.key) == key })
            .map(\.value).sorted().first { return sourceID }
        return catalogSourceIDsByURLKey[key]
    }

    /// Matches import references by their HTTP resource identity. Fragments are never sent
    /// to the source server; query parameters remain part of the identity. Other callers,
    /// including migrations of already-installed lists, retain their existing matching behavior.
    public static func catalogSourceIDForImport(for url: URL, additionalSourceIDsByURL: [URL: String] = [:]) -> String? {
        func withoutFragment(_ value: URL) -> URL {
            guard var components = URLComponents(url: value, resolvingAgainstBaseURL: false) else { return value }
            components.fragment = nil
            return components.url ?? value
        }
        let knownURLs = Dictionary(additionalSourceIDsByURL.map { (withoutFragment($0.key), $0.value) },
            uniquingKeysWith: { min($0, $1) })
        return catalogSourceID(for: withoutFragment(url), additionalSourceIDsByURL: knownURLs)
    }

    internal static func catalogSourceID(for rawURL: String) -> String? {
        guard let url = URL(string: rawURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }

        return catalogSourceID(for: url)
    }

    private static let catalogSourceIDsByURLKey: [String: String] = {
        var byKey = Dictionary(
            uniqueKeysWithValues: DefaultCatalog.curatedSources.compactMap { source in
                canonicalURLKey(for: source.sourceURL).map { ($0, source.id) }
            }
        )
        // A CURRENT catalog URL always wins; an alias only fills a gap.
        for (rawURL, sourceID) in retiredSourceURLAliases {
            guard let url = URL(string: rawURL), let key = canonicalURLKey(for: url) else {
                continue
            }
            if byKey[key] == nil {
                byKey[key] = sourceID
            }
        }
        return byKey
    }()

    /// URLs this catalog USED to ship, mapped to the source that replaced them.
    ///
    /// 🔴 WHY A CHANGED URL NEEDS AN ALIAS. This matcher is what turns a pasted or restored
    /// custom blocklist into the equivalent catalog source, and it is built from the CURRENT
    /// catalog URLs. So the moment a source's URL changes, anyone holding the old one — from
    /// a backup restore, a shared filter card, or a paste — stops being normalized and keeps a
    /// standalone custom list instead.
    ///
    /// That is worst in exactly the case that forces a URL change. These eleven were moved off
    /// `raw.githubusercontent.com/hagezi/dns-blocklists/...` because GitHub locked the account,
    /// so the un-migrated user keeps a custom list pointing at a DEAD host rather than
    /// following the catalog to the URL that still serves. (Codex, #536.)
    ///
    /// They now resolve through `cdn.jsdelivr.net/gh/hagezi/dns-blocklists@<version>/...`,
    /// which is the SAME repository behind a CDN — the owner is named in the path, so no third
    /// party can be served under it. A same-named GitLab mirror was rejected because nothing
    /// authenticated it; see key decision 2 in lavasec-doc. Those GitLab URLs never shipped in
    /// a tagged build, so they need no alias of their own.
    ///
    /// The version is PINNED rather than `@latest`: jsDelivr resolves `@latest` through the
    /// GitHub API, which 404s while the account is locked, so that alias survives only on
    /// cached resolution and would take all eleven back to 404 when it expires. A pinned
    /// version is cached permanently and cannot rotate. The content is therefore frozen at
    /// 2026-08-09, and moving back to a live origin is a deliberate catalog change.
    ///
    /// Aliases never override a live catalog URL, so re-adding a retired URL to the catalog
    /// later cannot be shadowed by this table.
    private static let retiredSourceURLAliases: [String: String] = [
        "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wildcard/tif.mini-onlydomains.txt":
            "hagezi-tif-mini",
        "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wildcard/light-onlydomains.txt":
            "hagezi-multi-light",
        "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wildcard/multi-onlydomains.txt":
            "hagezi-multi-normal",
        "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wildcard/pro-onlydomains.txt":
            "hagezi-multi-pro",
        "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wildcard/pro.mini-onlydomains.txt":
            "hagezi-multi-pro-mini",
        "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wildcard/pro.plus.mini-onlydomains.txt":
            "hagezi-multi-pro-plus-mini",
        "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wildcard/ultimate.mini-onlydomains.txt":
            "hagezi-multi-ultimate-mini",
        "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wildcard/social-onlydomains.txt":
            "hagezi-social",
        "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wildcard/nsfw-onlydomains.txt":
            "hagezi-nsfw",
        "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wildcard/gambling-onlydomains.txt":
            "hagezi-gambling",
        "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wildcard/anti.piracy-onlydomains.txt":
            "hagezi-anti-piracy",
    ]

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
    /// Replaces recognized custom blocklists with their curated catalog source identifiers.
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
    internal func migratingKnownCustomBlocklistsToCatalogSources() -> Filter {
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
