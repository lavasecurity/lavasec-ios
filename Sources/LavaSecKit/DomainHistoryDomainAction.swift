import Foundation

/// The filter list targeted by an action originating in domain history.
public enum DomainHistoryDomainTarget: Equatable, Sendable {
    /// Add the domain to the blocked-domain list.
    case blocked
    /// Add the domain to the allowed-domain list.
    case allowed
}

/// The configuration and normalized domain produced by a domain-history action.
public struct DomainHistoryDomainActionResult: Equatable, Sendable {
    /// The configuration after applying the requested action.
    public let configuration: AppConfiguration
    /// The normalized domain added to the target list.
    public let normalizedDomain: String
    /// The list that received the normalized domain.
    public let target: DomainHistoryDomainTarget
}

/// Errors that can prevent a domain-history action from being applied.
public enum DomainHistoryDomainActionError: LocalizedError, Equatable, Sendable {
    /// The supplied domain is invalid, with a message suitable for presentation.
    case invalidDomain(message: String)
    /// The normalized domain is already blocked.
    case alreadyBlocked(domain: String)
    /// The normalized domain is already allowed.
    case alreadyAllowed(domain: String)
    /// The blocked-domain limit has been reached.
    case blockedDomainLimitReached(limit: Int)
    /// The allowed-domain limit has been reached.
    case allowedDomainLimitReached(limit: Int)
    /// Allowlist validation rejected the supplied domain.
    case allowedDomainRejected(message: String)

    /// A localized description of the action error.
    public var errorDescription: String? {
        switch self {
        case .invalidDomain(let message):
            return message
        case .alreadyBlocked(let domain):
            return LavaCoreStrings.localizedFormat("core.domainError.alreadyBlocked", domain)
        case .alreadyAllowed(let domain):
            return LavaCoreStrings.localizedFormat("core.domainError.alreadyAllowed", domain)
        case .blockedDomainLimitReached(let limit):
            return LavaCoreStrings.localizedFormat("core.domainError.blockedLimit", limit)
        case .allowedDomainLimitReached(let limit):
            return LavaCoreStrings.localizedFormat("core.domainError.allowedLimit", limit)
        case .allowedDomainRejected(let message):
            return message
        }
    }
}

/// Domain-history actions that produce updated app configurations.
public extension AppConfiguration {
    /// Normalizes `rawDomain`, adds it to the target list, and removes it from the opposite list.
    func applyingDomainHistoryDomainAction(
        _ rawDomain: String,
        target: DomainHistoryDomainTarget,
        allowlistValidator: AllowlistValidator
    ) throws -> DomainHistoryDomainActionResult {
        switch target {
        case .blocked:
            return try addingBlockedDomainFromHistory(rawDomain)
        case .allowed:
            return try addingAllowedDomainFromHistory(rawDomain, allowlistValidator: allowlistValidator)
        }
    }

    private func addingBlockedDomainFromHistory(_ rawDomain: String) throws -> DomainHistoryDomainActionResult {
        let normalized: String
        do {
            normalized = try DomainName.normalize(rawDomain)
        } catch {
            throw DomainHistoryDomainActionError.invalidDomain(message: error.localizedDescription)
        }

        guard !blockedDomains.contains(normalized) else {
            throw DomainHistoryDomainActionError.alreadyBlocked(domain: normalized)
        }

        guard blockedDomains.count < limits.maxBlockedDomains else {
            throw DomainHistoryDomainActionError.blockedDomainLimitReached(limit: limits.maxBlockedDomains)
        }

        var updated = self
        updated.allowedDomains.remove(normalized)
        updated.blockedDomains.insert(normalized)
        return DomainHistoryDomainActionResult(
            configuration: updated,
            normalizedDomain: normalized,
            target: .blocked
        )
    }

    private func addingAllowedDomainFromHistory(
        _ rawDomain: String,
        allowlistValidator: AllowlistValidator
    ) throws -> DomainHistoryDomainActionResult {
        let validation = allowlistValidator.validate(rawDomain)
        guard validation.isAllowed, let normalized = validation.normalizedDomain else {
            throw DomainHistoryDomainActionError.allowedDomainRejected(message: validation.message)
        }

        guard !allowedDomains.contains(normalized) else {
            throw DomainHistoryDomainActionError.alreadyAllowed(domain: normalized)
        }

        guard allowedDomains.count < limits.maxAllowedDomains else {
            throw DomainHistoryDomainActionError.allowedDomainLimitReached(limit: limits.maxAllowedDomains)
        }

        var updated = self
        updated.blockedDomains.remove(normalized)
        updated.allowedDomains.insert(normalized)
        return DomainHistoryDomainActionResult(
            configuration: updated,
            normalizedDomain: normalized,
            target: .allowed
        )
    }
}
