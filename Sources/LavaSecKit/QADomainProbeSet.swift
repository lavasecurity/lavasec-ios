import Foundation

/// Four DNS probe hostnames used to verify allow, block, exception, and guardrail behavior.
public struct QADomainProbeSet: Equatable, Codable, Sendable {
    /// The hosted QA page that exercises the canonical probe set.
    public static let hostedPageURL = URL(string: "https://lavasecurity.app/qa/")!

    /// The canonical probe set hosted beneath `lavasecurity.app`.
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

    /// The hostname expected to resolve through an allow path.
    public let allowedDomain: String
    /// The hostname expected to exercise ordinary blocking.
    public let blockedDomain: String
    /// The hostname expected to exercise an allow exception to blocking.
    public let exceptionDomain: String
    /// The hostname expected to remain blocked by a non-overridable threat guardrail.
    public let guardrailDomain: String

    /// Creates four probe hostnames by prefixing the validated suffix with their probe roles.
    public init(suffix: String) throws {
        let normalizedSuffix = try DomainName.normalize(suffix)
        try self.init(
            allowedDomain: "allowed.\(normalizedSuffix)",
            blockedDomain: "blocked.\(normalizedSuffix)",
            exceptionDomain: "exception.\(normalizedSuffix)",
            guardrailDomain: "guardrail.\(normalizedSuffix)"
        )
    }

    /// Creates a probe set after independently validating and normalizing all four hostnames.
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

    /// The four probe hostnames in allow, block, exception, then guardrail order.
    public var allDomains: [String] {
        [allowedDomain, blockedDomain, exceptionDomain, guardrailDomain]
    }
}
