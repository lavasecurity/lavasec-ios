import Foundation

/// A reviewed rule change originating from the domain checker.
public enum DomainCheckRuleAction: String, Sendable {
    /// Add an allowed exception using the existing threat validation.
    case allowed
    /// Remove covering exceptions and ensure a manual rule blocks the checked domain.
    case blocked
    /// Remove covering exceptions without creating a blocked-domain entry.
    case removeAllowedException
    /// Remove the checked domain's exact manual block without changing other rules.
    case removeBlockedDomain
}

public extension AppConfiguration {
    /// Saved exceptions covering a hostname, including parent-domain rules.
    func allowedExceptions(matching rawDomain: String) throws -> Set<String> {
        let domain = try DomainName.normalize(rawDomain)
        return Set(allowedDomains.filter {
            ManualDomainRuleMatch.isCovered(normalizedDomain: domain, by: CollectionOfOne($0))
        })
    }

    /// Builds one configuration change; the caller reviews and saves it atomically.
    func applyingDomainCheckRuleAction(
        _ rawDomain: String,
        action: DomainCheckRuleAction,
        allowlistValidator: AllowlistValidator
    ) throws -> AppConfiguration {
        var updated = self
        if action == .blocked || action == .removeAllowedException {
            updated.allowedDomains.subtract(try allowedExceptions(matching: rawDomain))
        }
        switch action {
        case .removeAllowedException:
            return updated
        case .removeBlockedDomain:
            updated.blockedDomains.remove(try DomainName.normalize(rawDomain))
            return updated
        case .blocked:
            // Removing an override can restore an existing parent or exact block
            // without consuming capacity for a redundant entry. With no removed
            // exception, an explicit child-rule addition keeps its usual semantics.
            let domain = try DomainName.normalize(rawDomain)
            if updated.blockedDomains.contains(domain)
                || (updated.allowedDomains != allowedDomains
                    && ManualDomainRuleMatch.isCovered(normalizedDomain: domain, by: updated.blockedDomains)) {
                return updated
            }
            return try updated.applyingDomainHistoryDomainAction(domain, target: .blocked,
                allowlistValidator: allowlistValidator).configuration
        case .allowed:
            return try updated.applyingDomainHistoryDomainAction(rawDomain, target: .allowed,
                allowlistValidator: allowlistValidator).configuration
        }
    }
}
