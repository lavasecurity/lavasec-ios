import Foundation

public enum GuardianMascotState: Equatable, Sendable {
    case sleeping
    case waking
    case awake
    case paused
    case retrying
    case concerned
    case grateful

    public var allowedNextStates: [GuardianMascotState] {
        switch self {
        case .sleeping:
            [.waking]
        case .waking:
            [.awake, .retrying, .concerned, .sleeping]
        case .awake:
            [.sleeping, .paused, .retrying, .concerned, .grateful]
        case .paused:
            [.awake, .sleeping]
        case .retrying:
            [.awake, .concerned, .sleeping]
        case .concerned:
            [.awake, .retrying, .sleeping]
        case .grateful:
            [.awake]
        }
    }
}
