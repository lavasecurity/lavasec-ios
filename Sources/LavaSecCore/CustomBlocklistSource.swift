import Foundation

public enum CustomBlocklistSourceError: LocalizedError, Equatable {
    case invalidURL
    case unsupportedScheme
    case missingHost
    case privateNetworkHost
    case credentialsNotAllowed

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            "Enter a valid blocklist URL."
        case .unsupportedScheme:
            "Custom blocklists must use HTTPS."
        case .missingHost:
            "Custom blocklist URL must include a host."
        case .privateNetworkHost:
            "Custom blocklist URLs must use a public host."
        case .credentialsNotAllowed:
            "Custom blocklist URLs cannot include usernames or passwords."
        }
    }
}

public struct CustomBlocklistSource: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public var displayName: String
    public let sourceURL: URL
    public var parseFormat: CatalogBlocklistSource.CatalogParseFormat
    public var createdAt: Date
    public var lastAcceptedHash: String?

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

    public var cacheIdentity: String {
        [
            sourceURL.absoluteString,
            parseFormat.rawValue,
            lastAcceptedHash ?? ""
        ].joined(separator: "|")
    }
}
