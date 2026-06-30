import Foundation

public enum DomainValidationError: Error, Equatable, LocalizedError, Sendable {
    case empty
    case tooLong
    case needsAtLeastTwoLabels
    case invalidLabel(String)
    case ipAddressNotAllowed

    public var errorDescription: String? {
        switch self {
        case .empty:
            LavaCoreStrings.localized("core.domain.empty")
        case .tooLong:
            LavaCoreStrings.localized("core.domain.tooLong")
        case .needsAtLeastTwoLabels:
            LavaCoreStrings.localized("core.domain.needsTwoLabels")
        case .invalidLabel(let label):
            LavaCoreStrings.localizedFormat("core.domain.invalidLabel", label)
        case .ipAddressNotAllowed:
            LavaCoreStrings.localized("core.domain.ipNotAllowed")
        }
    }
}

public struct DomainName: Hashable, Codable, Sendable, CustomStringConvertible {
    public let value: String

    public init(_ rawValue: String) throws {
        value = try Self.normalize(rawValue)
    }

    public var description: String { value }

    public static func normalize(_ rawValue: String) throws -> String {
        var candidate = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)

        if candidate.hasPrefix(".") {
            candidate.removeFirst()
        }

        while candidate.hasSuffix(".") {
            candidate.removeLast()
        }

        candidate = candidate.lowercased()
        candidate = normalizedIDNAHostname(candidate)

        guard !candidate.isEmpty else {
            throw DomainValidationError.empty
        }

        guard !looksLikeIPAddress(candidate) else {
            throw DomainValidationError.ipAddressNotAllowed
        }

        guard candidate.utf8.count <= 253 else {
            throw DomainValidationError.tooLong
        }

        let labels = candidate.split(separator: ".", omittingEmptySubsequences: false).map(String.init)

        guard labels.count >= 2 else {
            throw DomainValidationError.needsAtLeastTwoLabels
        }

        for label in labels {
            guard isValidLabel(label) else {
                throw DomainValidationError.invalidLabel(label)
            }
        }

        return candidate
    }

    private static func isValidLabel(_ label: String) -> Bool {
        guard !label.isEmpty, label.utf8.count <= 63 else {
            return false
        }

        guard let first = label.utf8.first, let last = label.utf8.last else {
            return false
        }

        guard first != UInt8(ascii: "-"), last != UInt8(ascii: "-") else {
            return false
        }

        return label.utf8.allSatisfy { byte in
            (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
                || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                || byte == UInt8(ascii: "-")
        }
    }

    private static func normalizedIDNAHostname(_ value: String) -> String {
        guard value.contains(where: { !$0.isASCII }) else {
            return value
        }

        return URL(string: "https://\(value)/")?.host?.lowercased() ?? value
    }

    private static func looksLikeIPAddress(_ value: String) -> Bool {
        if value.contains(":") {
            return true
        }

        let pieces = value.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count == 4 else {
            return false
        }

        return pieces.allSatisfy { piece in
            !piece.isEmpty && piece.allSatisfy(\.isNumber)
        }
    }
}
