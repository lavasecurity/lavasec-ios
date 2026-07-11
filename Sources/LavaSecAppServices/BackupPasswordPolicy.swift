import Foundation
import LavaSecKit

package enum BackupPasswordRequirementID: String, Codable, CaseIterable, Sendable {
    case minimumLength
    case number
    case symbol
    case matchesConfirmation
}

package struct BackupPasswordRequirement: Equatable, Sendable {
    package let id: BackupPasswordRequirementID
    package let label: String
    package let isSatisfied: Bool

    package init(id: BackupPasswordRequirementID, label: String, isSatisfied: Bool) {
        self.id = id
        self.label = label
        self.isSatisfied = isSatisfied
    }
}

package struct BackupPasswordValidationResult: Equatable, Sendable {
    package let requirements: [BackupPasswordRequirement]

    package init(requirements: [BackupPasswordRequirement]) {
        self.requirements = requirements
    }

    package var isValid: Bool {
        requirements.allSatisfy(\.isSatisfied)
    }
}

package enum BackupPasswordPolicy {
    package static func validate(password: String, confirmation: String) -> BackupPasswordValidationResult {
        BackupPasswordValidationResult(requirements: [
            BackupPasswordRequirement(
                id: .minimumLength,
                label: "At least 8 characters",
                isSatisfied: password.count >= 8
            ),
            BackupPasswordRequirement(
                id: .number,
                label: "Includes at least 1 number",
                isSatisfied: password.rangeOfCharacter(from: .decimalDigits) != nil
            ),
            BackupPasswordRequirement(
                id: .symbol,
                label: "Includes at least 1 symbol",
                isSatisfied: password.rangeOfCharacter(from: symbolCharacters) != nil
            ),
            BackupPasswordRequirement(
                id: .matchesConfirmation,
                label: "Both password fields match",
                isSatisfied: !password.isEmpty && password == confirmation
            )
        ])
    }

    private static let symbolCharacters = CharacterSet.punctuationCharacters.union(.symbols)
}
