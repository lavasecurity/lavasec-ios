import Foundation
import LavaSecKit

/// Endpoint and public API credential used to construct Supabase Auth requests.
public struct SupabaseIDTokenAuthConfiguration: Equatable, Sendable {
    /// Base URL of the Supabase project.
    public let projectURL: URL
    /// Publishable project key sent in the `apikey` request header.
    public let publishableKey: String

    /// Creates an authentication configuration from a project URL and publishable key.
    public init(projectURL: URL, publishableKey: String) {
        self.projectURL = projectURL
        self.publishableKey = publishableKey
    }
}

/// Supabase user identity retained with an authenticated session.
public struct SupabaseIDTokenAuthUser: Codable, Equatable, Sendable {
    /// Stable Supabase user identifier.
    public let id: String
    /// User email returned by Supabase, when available.
    public let email: String?
    /// Primary provider value from Supabase app metadata.
    public let provider: String?
    /// Deduplicated, lowercase provider list assembled from available identity metadata.
    public let providers: [String]

    /// Creates a user and normalizes the supplied provider list while preserving the primary value.
    public init(id: String, email: String?, provider: String? = nil, providers: [String] = []) {
        self.id = id
        self.email = email
        self.provider = provider
        self.providers = Self.normalizedProviders(providers + [provider].compactMap { $0 })
    }

    enum CodingKeys: String, CodingKey {
        case id
        case email
        case appMetadata = "app_metadata"
        case identities
    }

    /// Decodes user and identity metadata, merging provider sources into normalized order.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        email = try container.decodeIfPresent(String.self, forKey: .email)
        let appMetadata = try container.decodeIfPresent(AppMetadata.self, forKey: .appMetadata)
        let identities = try container.decodeIfPresent([SupabaseIDTokenAuthIdentity].self, forKey: .identities) ?? []
        provider = appMetadata?.provider
        providers = Self.normalizedProviders(
            [appMetadata?.provider].compactMap { $0 } +
            (appMetadata?.providers ?? []) +
            identities.map(\.provider)
        )
    }

    /// Encodes persisted user fields and app metadata using Supabase wire keys.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(email, forKey: .email)
        if provider != nil || !providers.isEmpty {
            try container.encode(AppMetadata(provider: provider, providers: providers), forKey: .appMetadata)
        }
    }

    private static func normalizedProviders(_ providers: [String]) -> [String] {
        var seen = Set<String>()
        return providers.compactMap { provider in
            let normalized = provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !normalized.isEmpty, !seen.contains(normalized) else {
                return nil
            }

            seen.insert(normalized)
            return normalized
        }
    }
}

private struct AppMetadata: Codable, Equatable, Sendable {
    let provider: String?
    let providers: [String]?
}

private struct SupabaseIDTokenAuthIdentity: Codable, Equatable, Sendable {
    let provider: String
}

/// Access and refresh credentials plus the Supabase user returned for a session.
public struct SupabaseIDTokenAuthSession: Codable, Equatable, Sendable {
    /// Bearer access token returned by Supabase Auth.
    public let accessToken: String
    /// Refresh token used to obtain a replacement access token.
    public let refreshToken: String
    /// Server-reported access-token lifetime in seconds, when supplied.
    public let expiresIn: Int?
    /// Server-reported Unix expiry timestamp, when supplied.
    public let expiresAt: Int?
    /// User identity associated with the session.
    public let user: SupabaseIDTokenAuthUser

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case expiresAt = "expires_at"
        case user
    }

    /// Creates a session from the supplied token, expiry, and user values.
    public init(
        accessToken: String,
        refreshToken: String,
        expiresIn: Int?,
        expiresAt: Int?,
        user: SupabaseIDTokenAuthUser
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresIn = expiresIn
        self.expiresAt = expiresAt
        self.user = user
    }
}

package enum SupabaseIDTokenAuthError: Error, Equatable, LocalizedError {
    case invalidEndpoint
    case invalidResponse
    case requestFailed(statusCode: Int, message: String?)

    package var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            "The Supabase Auth endpoint is not valid."
        case .invalidResponse:
            "The Supabase Auth response was not valid."
        case .requestFailed(let statusCode, let message):
            if let message, !message.isEmpty {
                "Supabase Auth returned status \(statusCode): \(message)"
            } else {
                "Supabase Auth returned status \(statusCode)."
            }
        }
    }
}

/// Constructs Supabase ID-token and refresh requests and decodes their session responses.
public enum SupabaseIDTokenAuth {
    /// Builds an ID-token grant request with optional provider access-token support.
    public static func makeTokenRequest(
        configuration: SupabaseIDTokenAuthConfiguration,
        provider: String,
        idToken: String,
        accessToken: String? = nil,
        nonce: String
    ) throws -> URLRequest {
        try makeGrantRequest(
            configuration: configuration,
            grantType: "id_token",
            body: TokenRequestBody(
                provider: provider,
                idToken: idToken,
                accessToken: accessToken,
                nonce: nonce
            )
        )
    }

    /// Builds a refresh-token grant request.
    public static func makeRefreshTokenRequest(
        configuration: SupabaseIDTokenAuthConfiguration,
        refreshToken: String
    ) throws -> URLRequest {
        try makeGrantRequest(
            configuration: configuration,
            grantType: "refresh_token",
            body: RefreshTokenRequestBody(refreshToken: refreshToken)
        )
    }

    /// Decodes a session from a successful HTTP response or throws a categorized auth error.
    public static func decodeSession(data: Data, response: URLResponse) throws -> SupabaseIDTokenAuthSession {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SupabaseIDTokenAuthError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw SupabaseIDTokenAuthError.requestFailed(
                statusCode: httpResponse.statusCode,
                message: decodeErrorMessage(from: data)
            )
        }

        return try JSONDecoder().decode(SupabaseIDTokenAuthSession.self, from: data)
    }

    private static func makeGrantRequest<Body: Encodable>(
        configuration: SupabaseIDTokenAuthConfiguration,
        grantType: String,
        body: Body
    ) throws -> URLRequest {
        let authURL = configuration.projectURL.appending(path: "auth/v1/token")
        guard var components = URLComponents(url: authURL, resolvingAgainstBaseURL: false) else {
            throw SupabaseIDTokenAuthError.invalidEndpoint
        }

        components.queryItems = [
            URLQueryItem(name: "grant_type", value: grantType)
        ]

        guard let url = components.url else {
            throw SupabaseIDTokenAuthError.invalidEndpoint
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(configuration.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    private static func decodeErrorMessage(from data: Data) -> String? {
        guard let error = try? JSONDecoder().decode(AuthErrorResponse.self, from: data) else {
            return nil
        }

        return error.errorDescription ?? error.message ?? error.error
    }
}

private struct TokenRequestBody: Encodable {
    let provider: String
    let idToken: String
    let accessToken: String?
    let nonce: String

    enum CodingKeys: String, CodingKey {
        case provider
        case idToken = "id_token"
        case accessToken = "access_token"
        case nonce
    }
}

private struct RefreshTokenRequestBody: Encodable {
    let refreshToken: String

    enum CodingKeys: String, CodingKey {
        case refreshToken = "refresh_token"
    }
}

private struct AuthErrorResponse: Decodable {
    let error: String?
    let errorDescription: String?
    let message: String?

    enum CodingKeys: String, CodingKey {
        case error
        case errorDescription = "error_description"
        case message
    }
}
