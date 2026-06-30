import Foundation

public enum DomainHistoryDomainTarget: Equatable, Sendable {
    case blocked
    case allowed
}

public struct DomainHistoryDomainActionResult: Equatable, Sendable {
    public let configuration: AppConfiguration
    public let normalizedDomain: String
    public let target: DomainHistoryDomainTarget
}

public enum DomainHistoryDomainActionError: LocalizedError, Equatable, Sendable {
    case invalidDomain(message: String)
    case alreadyBlocked(domain: String)
    case alreadyAllowed(domain: String)
    case blockedDomainLimitReached(limit: Int)
    case allowedDomainLimitReached(limit: Int)
    case allowedDomainRejected(message: String)

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

public extension AppConfiguration {
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
