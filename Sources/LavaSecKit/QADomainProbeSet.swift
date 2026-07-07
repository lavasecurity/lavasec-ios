import Foundation

public struct QADomainProbeSet: Equatable, Codable, Sendable {
    public static let hostedPageURL = URL(string: "https://lavasecurity.app/qa/")!

    public static let hosted: QADomainProbeSet = {
        do {
            return try QADomainProbeSet(
                allowedDomain: "allowed.qa-probe.lavasecurity.app",
                blockedDomain: "blocked.qa-probe.lavasecurity.app",
                exceptionDomain: "exception.qa-probe.lavasecurity.app",
                guardrailDomain: "guardrail.qa-probe.lavasecurity.app"
            )
        } catch {
            preconditionFailure("Hosted QA probe domains must be valid.")
        }
    }()

    public let allowedDomain: String
    public let blockedDomain: String
    public let exceptionDomain: String
    public let guardrailDomain: String

    public init(suffix: String) throws {
        let normalizedSuffix = try DomainName.normalize(suffix)
        try self.init(
            allowedDomain: "allowed.\(normalizedSuffix)",
            blockedDomain: "blocked.\(normalizedSuffix)",
            exceptionDomain: "exception.\(normalizedSuffix)",
            guardrailDomain: "guardrail.\(normalizedSuffix)"
        )
    }

    public init(
        allowedDomain: String,
        blockedDomain: String,
        exceptionDomain: String,
        guardrailDomain: String
    ) throws {
        self.allowedDomain = try DomainName.normalize(allowedDomain)
        self.blockedDomain = try DomainName.normalize(blockedDomain)
        self.exceptionDomain = try DomainName.normalize(exceptionDomain)
        self.guardrailDomain = try DomainName.normalize(guardrailDomain)
    }

    public var allDomains: [String] {
        [allowedDomain, blockedDomain, exceptionDomain, guardrailDomain]
    }
}
