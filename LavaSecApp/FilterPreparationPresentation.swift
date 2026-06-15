import LavaSecCore

/// Per-OS presentation for filter-preparation phases. The core `FilterPreparationPhase`
/// is a stable Codable state; this maps each phase to user copy on iOS (the views
/// localize via `.lavaLocalized` at render). Android maps the same phases. Exhaustive.
enum FilterPreparationPresentation {
    static func message(for phase: FilterPreparationPhase) -> String {
        switch phase {
        case .downloading: return "(1/3) Downloading lists"
        case .compiling:   return "(2/3) Compiling the list"
        case .saving:      return "(3/3) Saving the list"
        }
    }
}
