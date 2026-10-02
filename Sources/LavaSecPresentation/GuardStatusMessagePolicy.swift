import Foundation

/// Chooses the single notice above Guard's primary action. Inputs are localized by the app.
/// Keeping selection independent of either renderer prevents stale setup failures from
/// surviving an automatic OFF transition and keeps reconnect failures visible with setup closed.
public enum GuardStatusMessagePolicy {
    public enum Source: Equatable, Sendable {
        case setupIssue, errorMessage, settingsApplyError, lifecycleNotice, permissionMessage
    }

    /// The one message and its semantic error cue, shared by native and RN presentation.
    public struct Message: Equatable, Sendable {
        /// Localized display copy.
        public let text: String
        /// Whether Guard should use neutral panel material and a recovery-toned action.
        public let isError: Bool
        /// The chosen notice lane, so callers can distinguish an old marker from a current error.
        public let source: Source
    }

    /// Selects a notice, or nil when the ordinary protection-state subtitle should be used.
    /// A retired setup error is identified by its owned text, so unrelated errors survive.
    public static func select(
        chainingEnabled: Bool,
        setupIssue: String?,
        errorMessage: String?,
        settingsApplyError: String?,
        lifecycleNotice: String?,
        permissionMessage: String?
    ) -> Message? {
        // An empty producer must not hide the current protection-state description.
        // Keep nonempty operational details verbatim; normalization is only an emptiness check.
        let setupIssue = nonempty(setupIssue)
        let errorMessage = nonempty(errorMessage)
        let settingsApplyError = nonempty(settingsApplyError)
        let lifecycleNotice = nonempty(lifecycleNotice)
        let permissionMessage = nonempty(permissionMessage)
        if chainingEnabled, let setupIssue {
            return Message(text: setupIssue, isError: true, source: .setupIssue)
        }
        if let errorMessage, chainingEnabled || errorMessage != setupIssue {
            return Message(text: errorMessage, isError: true, source: .errorMessage)
        }
        if let settingsApplyError {
            return Message(text: settingsApplyError, isError: true, source: .settingsApplyError)
        }
        if let lifecycleNotice {
            return Message(text: lifecycleNotice, isError: true, source: .lifecycleNotice)
        }
        if let permissionMessage {
            return Message(text: permissionMessage, isError: false, source: .permissionMessage)
        }
        return nil
    }

    private static func nonempty(_ text: String?) -> String? {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }
}
