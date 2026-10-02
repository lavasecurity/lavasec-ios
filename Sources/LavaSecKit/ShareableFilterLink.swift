import Foundation

/// Why a raw share input could not be turned into a ``ShareableFilterConfiguration``.
///
/// The three cases are deliberately distinguishable so the importer can say
/// something true and specific: a mistyped code, a link that is not ours, and a
/// genuine payload that arrived corrupted are different problems for a recipient.
public enum ShareableFilterInputError: Error, Equatable, Sendable {
    /// The input is neither an `LF1-` code nor anything shaped like a URL.
    case unrecognizedFormat
    /// The input parses as a URL but is not the exact canonical Lava import link.
    case invalidUniversalLink
    /// The input carried a code, but the code itself is unusable.
    case configurationCode(ShareableFilterConfigurationCodeError)
}

/// The single boundary that turns untrusted share input into a configuration.
///
/// Every import origin — pasted code, camera scan, photo scan, Universal Link —
/// funnels through ``decode(_:)``. Keeping one parser is the point: a second,
/// laxer path is how a payload eventually reaches the importer through a link
/// nobody audited.
///
/// **The payload rides in the URL fragment, and that is load-bearing.** Fragments
/// are not transmitted in HTTP requests, so a shared code never reaches the web
/// server, its logs, its referrers, or any analytics. That is what lets the whole
/// feature exist with no share record, no short code, and no server endpoint.
///
/// **This type establishes bounded authority, not authenticity.** The `LF1-`
/// integrity tag is a corruption guard, not a signature — anyone can build a
/// payload and recompute it. A link that survives this parser has earned the
/// right to be *reviewed*, never to be applied. See
/// `lavasec-infra/plans/2026-07-14-recipient-first-shared-filter-card-plan.md`.
public enum ShareableFilterLink {
    /// The canonical, published prefix. Everything after it is the complete code.
    public static let canonicalURLPrefix = "https://lavasecurity.app/app/import/#"

    private static let canonicalScheme = "https"
    private static let canonicalHost = "lavasecurity.app"
    private static let canonicalPath = "/app/import/"

    /// base64url alphabet plus the `LF1-` prefix's own characters. Notably absent:
    /// `+`, `/`, `=`, and `%` — so a percent-encoded fragment can never be decoded
    /// into something that looks legitimate.
    private static let allowedCodeCharacters = Set(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-"
    )

    /// Longest legitimate bare code: the `LF1-` prefix plus the encoded-body cap.
    private static var maxCodeLength: Int {
        ShareableFilterConfiguration.codePrefix.count
            + ShareableFilterConfiguration.maxEncodedCodeLength
    }

    /// Longest legitimate canonical link: the published prefix plus a max code.
    private static var maxURLLength: Int {
        canonicalURLPrefix.count + maxCodeLength
    }

    // MARK: - Creation

    /// Wraps `configuration` in the canonical Universal Link.
    ///
    /// - Throws: ``ShareableFilterInputError`` if the encoded code cannot be
    ///   represented. The payload is never trimmed to make it fit — callers fall
    ///   back to the copyable setup code instead.
    public static func url(for configuration: ShareableFilterConfiguration) throws -> URL {
        try url(forConfigurationCode: configuration.encodedConfigurationCode())
    }

    /// Wraps an existing code — the exact string the share sheet already holds.
    ///
    /// This overload exists so the UI never decodes and re-encodes a payload just
    /// to build a link; a re-encode is an opportunity to silently change bytes.
    public static func url(forConfigurationCode code: String) throws -> URL {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)

        guard trimmed.count <= maxCodeLength else {
            throw ShareableFilterInputError.configurationCode(.payloadTooLarge)
        }
        guard isWellFormedCode(trimmed) else {
            throw ShareableFilterInputError.unrecognizedFormat
        }
        guard let url = URL(string: canonicalURLPrefix + trimmed) else {
            throw ShareableFilterInputError.invalidUniversalLink
        }
        return url
    }

    // MARK: - Decoding

    /// Decodes either a raw `LF1-…` code or the exact canonical Universal Link.
    ///
    /// Rejects everything else — including a code embedded in surrounding text.
    /// The parser never searches for `LF1-` inside an arbitrary string, because a
    /// substring search is how a hostile page smuggles a payload past a host check.
    public static func decode(_ rawInput: String) throws -> ShareableFilterConfiguration {
        let trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ShareableFilterInputError.unrecognizedFormat
        }

        // Branch before bounding so each format reports its own precise reason.
        if hasCodePrefix(trimmed) {
            guard trimmed.count <= maxCodeLength else {
                throw ShareableFilterInputError.configurationCode(.payloadTooLarge)
            }
            return try decodeConfigurationCode(trimmed)
        }

        // Anything with a scheme is a URL *attempt* and gets URL error reporting;
        // anything else is simply not a share input.
        guard let components = URLComponents(string: trimmed), components.scheme != nil else {
            throw ShareableFilterInputError.unrecognizedFormat
        }
        guard trimmed.count <= maxURLLength else {
            throw ShareableFilterInputError.configurationCode(.payloadTooLarge)
        }

        return try decodeConfigurationCode(try canonicalCode(from: components))
    }

    // MARK: - Canonical link validation

    /// Extracts the code from `components`, or throws if the link deviates from
    /// the canonical form in any way.
    private static func canonicalCode(from components: URLComponents) throws -> String {
        guard components.scheme?.lowercased() == canonicalScheme else {
            throw ShareableFilterInputError.invalidUniversalLink
        }

        // Userinfo is the classic confusable: in `https://lavasecurity.app@evil.com/`
        // the host is evil.com. Refusing userinfo outright removes the whole class.
        guard components.user == nil, components.password == nil, components.port == nil else {
            throw ShareableFilterInputError.invalidUniversalLink
        }

        // A code in the query would be sent to the server — the one thing the
        // fragment design exists to prevent. Refuse queries entirely.
        guard components.query == nil else {
            throw ShareableFilterInputError.invalidUniversalLink
        }

        // Compare the percent-encoded forms: `host` and `path` decode escapes,
        // which would let `%2F` or an encoded homograph masquerade as canonical.
        guard let host = components.percentEncodedHost,
              host.lowercased() == canonicalHost else {
            throw ShareableFilterInputError.invalidUniversalLink
        }
        guard components.percentEncodedPath == canonicalPath else {
            throw ShareableFilterInputError.invalidUniversalLink
        }

        guard let fragment = components.percentEncodedFragment,
              isWellFormedCode(fragment) else {
            throw ShareableFilterInputError.invalidUniversalLink
        }
        return fragment
    }

    // MARK: - Helpers

    /// Matches ``ShareableFilterConfiguration/decode(configurationCode:)``, which
    /// accepts the prefix case-insensitively so a hand-typed code still works.
    private static func hasCodePrefix(_ value: String) -> Bool {
        value.lowercased().hasPrefix(ShareableFilterConfiguration.codePrefix.lowercased())
    }

    /// A complete, self-consistent code: correct prefix, non-empty body, and not a
    /// single character outside the base64url alphabet.
    private static func isWellFormedCode(_ value: String) -> Bool {
        guard hasCodePrefix(value) else { return false }
        guard value.count > ShareableFilterConfiguration.codePrefix.count else { return false }
        return value.allSatisfy { allowedCodeCharacters.contains($0) }
    }

    /// Passes the *entire* extracted code to the existing decoder. Never truncates,
    /// never re-scans for a later `LF1-`, never drops a payload field.
    private static func decodeConfigurationCode(
        _ code: String
    ) throws -> ShareableFilterConfiguration {
        do {
            return try ShareableFilterConfiguration.decode(configurationCode: code)
        } catch let error as ShareableFilterConfigurationCodeError {
            throw ShareableFilterInputError.configurationCode(error)
        }
    }
}
