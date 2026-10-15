import Foundation

/// One explicitly entered hostname or web URL, reduced to the engine's hostname grammar.
public struct DomainCheckInput: Equatable, Sendable {
    public let domain: String
    public let ignoredURLParts: Bool
    public let repairedScheme: Bool

    public init(_ raw: String) throws {
        guard raw.utf8.count <= 4096 else { throw DomainCheckInputError.tooLong }
        var input = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { throw DomainCheckInputError.empty }
        guard !input.unicodeScalars.contains(where: {
            CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0)
        }), !input.contains("\\") else { throw DomainCheckInputError.invalid }

        let lower = input.lowercased()
        repairedScheme = lower.hasPrefix("http//") || lower.hasPrefix("https//")
        if repairedScheme { input.insert(":", at: input.firstIndex(of: "/")!) }
        let hasScheme = input.range(of: #"^[A-Za-z][A-Za-z0-9+.-]*://"#, options: .regularExpression) != nil
        ignoredURLParts = hasScheme || repairedScheme || input.contains(where: { "/?#:".contains($0) })
        let urlText = hasScheme ? input : input.hasPrefix("//") ? "https:" + input : "https://" + input
        guard let parts = URLComponents(string: urlText),
              ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
              parts.user == nil, parts.password == nil,
              let host = parts.host, !host.isEmpty else { throw DomainCheckInputError.invalid }
        // Do not decode attacker-controlled delimiters or accept a forgiving URL parser's repairs.
        let authority = urlText.components(separatedBy: "://")[1].prefix { !"/?#".contains($0) }
        guard !authority.contains("%"), !authority.contains("@"), !authority.hasSuffix(":"),
              parts.port.map({ (1...65535).contains($0) }) ?? true else { throw DomainCheckInputError.invalid }
        do { domain = try DomainName.normalize(host) }
        catch { throw DomainCheckInputError.invalid }
    }
}

/// Messages never reflect arbitrary clipboard text, URL credentials, or paths.
public enum DomainCheckInputError: Error, Equatable, LocalizedError, Sendable {
    case empty, tooLong, invalid
    public var errorDescription: String? {
        switch self {
        case .empty: "Enter a domain or URL."
        case .tooLong: "This address is too long. Enter its domain instead."
        case .invalid: "Enter one valid domain or web URL."
        }
    }
}
