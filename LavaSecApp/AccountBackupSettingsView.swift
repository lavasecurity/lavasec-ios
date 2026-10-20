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
            return "Delete backup"
        case .disable:
            return "Turn off & delete backup"
        }
    }

    var title: String {
        switch self {
        case .clear:
            return "Delete backup?"
        case .disable:
            return "Turn off & delete backup?"
        }
    }

    var actionTitle: String {
        switch self {
        case .clear:
            return "Delete backup"
        case .disable:
            return "Turn off & delete backup"
        }
    }

    var message: String {
        switch self {
        case .clear:
            return "Deletes your online and local backup copies and turns off backup. This can't be undone. Your current settings stay on this device."
        case .disable:
            return "Deletes your online and local backup copies and turns off backup. This can't be undone. Your current settings stay on this device."
        }
    }

    var authReason: String {
        switch self {
        case .clear:
            return "Disable encrypted backup"
        case .disable:
            return "Disable encrypted backup"
        }
    }
}
