import LavaSecKit

enum FilterReviewOrigin: String, Identifiable {
    case filters
    case domainHistory

    var id: String { rawValue }

}
