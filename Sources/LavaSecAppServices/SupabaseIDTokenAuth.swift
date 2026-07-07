import Foundation
import LavaSecKit

public struct SupabaseIDTokenAuthConfiguration: Equatable, Sendable {
    public let projectURL: URL
    public let publishableKey: String

    public init(projectURL: URL, publishableKey: String) {
        self.projectURL = projectURL
        self.publishableKey = publishableKey
    }
}

public struct SupabaseIDTokenAuthUser: Codable, Equatable, Sendable {
    public let id: String
    public let email: String?
    public let provider: String?
    public let providers: [String]

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

public struct SupabaseIDTokenAuthSession: Codable, Equatable, Sendable {
    public let accessToken: String
    public let refreshToken: String
    public let expiresIn: Int?
    public let expiresAt: Int?
    public let user: SupabaseIDTokenAuthUser

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case expiresAt = "expires_at"
        case user
    }

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

public enum SupabaseIDTokenAuthError: Error, Equatable, LocalizedError {
    case invalidEndpoint
    case invalidResponse
    case requestFailed(statusCode: Int, message: String?)

    public var errorDescription: String? {
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

public enum SupabaseIDTokenAuth {
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
