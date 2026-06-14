import Foundation

public enum BackupPasswordRequirementID: String, Codable, CaseIterable, Sendable {
    case minimumLength
    case number
    case symbol
    case matchesConfirmation
}

public struct BackupPasswordRequirement: Equatable, Sendable {
    public let id: BackupPasswordRequirementID
    public let label: String
    public let isSatisfied: Bool

    public init(id: BackupPasswordRequirementID, label: String, isSatisfied: Bool) {
        self.id = id
        self.label = label
        self.isSatisfied = isSatisfied
    }
}

public struct BackupPasswordValidationResult: Equatable, Sendable {
    public let requirements: [BackupPasswordRequirement]

    public init(requirements: [BackupPasswordRequirement]) {
        self.requirements = requirements
    }

    public var isValid: Bool {
        requirements.allSatisfy(\.isSatisfied)
    }
}

public enum BackupPasswordPolicy {
    public static func validate(password: String, confirmation: String) -> BackupPasswordValidationResult {
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
