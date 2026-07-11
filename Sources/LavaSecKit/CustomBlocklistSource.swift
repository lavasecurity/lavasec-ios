import Foundation

internal enum CustomBlocklistSourceError: LocalizedError, Equatable {
    case invalidURL
    case unsupportedScheme
    case missingHost
    case privateNetworkHost
    case credentialsNotAllowed

    internal var errorDescription: String? {
        switch self {
        case .invalidURL:
            LavaCoreStrings.localized("core.customBlocklist.invalidURL")
        case .unsupportedScheme:
            LavaCoreStrings.localized("core.customBlocklist.unsupportedScheme")
        case .missingHost:
            LavaCoreStrings.localized("core.customBlocklist.missingHost")
        case .privateNetworkHost:
            LavaCoreStrings.localized("core.customBlocklist.privateNetworkHost")
        case .credentialsNotAllowed:
            LavaCoreStrings.localized("core.customBlocklist.credentialsNotAllowed")
        }
    }
}

/// A blocklist source record and the metadata needed to parse and cache its contents.
public struct CustomBlocklistSource: Identifiable, Hashable, Codable, Sendable {
    /// The source identifier. The public initializer generates a `custom-` identifier when omitted.
    public let id: String
    /// The user-facing name. The public initializer trims it and falls back to the source hostname.
    public private(set) var displayName: String
    /// The URL stored for fetching; the public initializer accepts only validated HTTPS inputs.
    public let sourceURL: URL
    /// The parser selection used when interpreting downloaded source data.
    public private(set) var parseFormat: CatalogBlocklistSource.CatalogParseFormat
    /// The date associated with creation of this source record.
    public private(set) var createdAt: Date
    /// The hash of the most recently accepted source contents, when available.
    public package(set) var lastAcceptedHash: String?

    /// Creates a source after trimming its name and rejecting invalid, credentialed,
    /// localhost, or non-public IP URLs.
    public init(
        id: String? = nil,
        displayName: String,
        rawURL: String,
        parseFormat: CatalogBlocklistSource.CatalogParseFormat = .auto,
        createdAt: Date = Date(),
        lastAcceptedHash: String? = nil
    ) throws {
        guard let url = URL(string: rawURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw CustomBlocklistSourceError.invalidURL
        }

        guard url.scheme?.lowercased() == "https" else {
            throw CustomBlocklistSourceError.unsupportedScheme
        }

        guard let host = url.host, !host.isEmpty else {
            throw CustomBlocklistSourceError.missingHost
        }

        do {
            try NetworkEndpointValidator.validatePublicSourceURL(url)
        } catch NetworkEndpointValidationError.credentialsNotAllowed {
            throw CustomBlocklistSourceError.credentialsNotAllowed
        } catch NetworkEndpointValidationError.privateNetworkNotAllowed {
            throw CustomBlocklistSourceError.privateNetworkHost
        } catch {
            throw CustomBlocklistSourceError.invalidURL
        }

        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.id = id ?? "custom-\(UUID().uuidString.lowercased())"
        self.displayName = trimmedName.isEmpty ? host : trimmedName
        self.sourceURL = url
        self.parseFormat = parseFormat
        self.createdAt = createdAt
        self.lastAcceptedHash = lastAcceptedHash
    }

    /// A cache key derived from the URL, parse format, and last accepted content hash.
    public var cacheIdentity: String {
        [
            sourceURL.absoluteString,
            parseFormat.rawValue,
            lastAcceptedHash ?? ""
        ].joined(separator: "|")
    }
}
