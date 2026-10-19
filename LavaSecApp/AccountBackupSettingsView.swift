import SwiftUI
import LavaSecKit

enum BackupMaintenanceAction: Identifiable {
    case clear
    case disable

    var id: String {
        switch self {
        case .clear:
            return "clear"
        case .disable:
            return "disable"
        }
    }

    var buttonTitle: String {
        switch self {
        case .clear:
            return "Delete online backup copy"
        case .disable:
            return "Turn off & delete backup"
        }
    }

    var title: String {
        switch self {
        case .clear:
            return "Delete online backup copy?"
        case .disable:
            return "Turn off & delete backup?"
        }
    }

    var actionTitle: String {
        switch self {
        case .clear:
            return "Delete online backup copy"
        case .disable:
            return "Turn off & delete backup"
        }
    }

    var message: String {
        switch self {
        case .clear:
            return "Permanently deletes your account's encrypted backup — this can't be undone. Backup stays on, and a fresh copy uploads next time."
        case .disable:
            return "Turns off backup on this device and permanently deletes your account's copy. This can't be undone — you can set up a new backup later."
        }
    }

    var authReason: String {
        switch self {
        case .clear:
            return "Clear encrypted backup"
        case .disable:
            return "Disable encrypted backup"
        }
    }
}
