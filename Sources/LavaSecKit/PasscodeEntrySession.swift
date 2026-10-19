import Foundation

/// Ephemeral native input state. Passcode bytes never enter an RN snapshot or command.
public struct PasscodeEntrySession {
    /// The two presentations share input behavior but retain their authentication owners.
    public enum Mode {
        /// Collects an initial passcode and its matching confirmation.
        case setup
        /// Submits each complete entry to the existing authentication owner.
        case authenticate
    }
    /// Native effects requested after a complete four-digit entry.
    public enum Effect: Equatable {
        /// The entry is incomplete or setup needs another input.
        case none
        /// Requests native storage of the confirmed passcode.
        case setPasscode(String)
        /// Requests validation by the current native authentication request.
        case authenticate(String)
    }
    /// Current setup phase; this value contains no credential material.
    public private(set) var confirming = false
    /// Display-ready validation key. The host localizes it before projection.
    public private(set) var message: String?
    private var firstCode = ""
    private let mode: Mode

    /// Creates a single visit; retiring the host discards all entered credentials.
    public init(mode: Mode) { self.mode = mode }

    /// Only native input calls this method. Incomplete and nonnumeric input cannot submit.
    public mutating func enter(_ rawValue: String) -> Effect {
        let code = String(rawValue.filter(\.isNumber).prefix(4))
        guard code.count == 4 else { return .none }
        if mode == .authenticate { return .authenticate(code) }
        if !confirming {
            firstCode = code; confirming = true; message = nil
            return .none
        }
        guard code == firstCode else {
            firstCode = ""; confirming = false; message = "Passcodes did not match"
            return .none
        }
        firstCode = ""
        return .setPasscode(code)
    }

    /// Keeps native validation failures in the same visit without retaining the submitted code.
    public mutating func failed(_ message: String) {
        firstCode = ""; confirming = false; self.message = message
    }
}
