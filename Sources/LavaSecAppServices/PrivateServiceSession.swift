import Foundation

/// HTTP transport for private account, backup and diagnostic services. Explicit
/// bearer/token headers remain owned by their clients; URLSession must not create
/// an alternate reusable response, cookie or credential store for these values.
public enum PrivateServiceSession {
    /// Process-only session with caching, shared cookies and credentials disabled.
    public static let shared: URLSession = {
        // Old releases used URLSession.shared for private responses. Retire that
        // discardable cache before the first private request; never touch the
        // authoritative configuration, Keychain sessions or encrypted backups.
        URLCache.shared.removeAllCachedResponses()
        return URLSession(configuration: configuration())
    }()

    /// Returns an independent configuration for production and transport tests.
    public static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        return configuration
    }
}
