/// Semantic icon roles — the portable icon layer. Views and components name a role;
/// each platform resolves it (iOS → SF Symbol below; Android → a Material icon from
/// the same role table). Keeps Apple-proprietary glyph strings out of the UI so the
/// Android port maps intent, not `Image(systemName:)` literals.
enum LavaIconRole: Sendable {
    // Primary tabs
    case guardShield, filters, activity, settings
    // Navigation-row destinations
    case domainHistory, networkActivity, blocked, allowed
    // Recurring chrome
    case chevronRight
}

extension LavaIconRole {
    /// iOS rendering: today's exact SF Symbol, so adopting the role layer is a visual
    /// no-op. (Cross-check against the call sites being migrated.)
    var sfSymbolName: String {
        switch self {
        case .guardShield:     "shield.fill"
        case .filters:         "line.3.horizontal.decrease.circle"
        case .activity:        "chart.bar.xaxis"
        case .settings:        "gearshape"
        case .domainHistory:   "clock.arrow.circlepath"
        case .networkActivity: "waveform.path.ecg.rectangle"
        case .blocked:         "hand.raised.fill"
        case .allowed:         "arrow.right.circle.fill"
        case .chevronRight:    "chevron.right"
        }
    }

    /// Tab-bar glyph for a given selection state: the **filled** variant when the tab is selected,
    /// the **outline** variant when it is not — a non-color (Differentiate Without Color) cue so the
    /// active tab reads by shape, not just tint. Only the Guard and Settings tabs vary by state today
    /// (the two with a distinct filled variant); any other role — including the Filters and Activity
    /// tabs — falls back to its canonical `sfSymbolName`. Glyph strings stay in this role layer, out of the UI.
    func tabBarSymbolName(isSelected: Bool) -> String {
        switch self {
        case .guardShield: isSelected ? "shield.fill" : "shield"
        case .settings:    isSelected ? "gearshape.fill" : "gearshape"
        default:           sfSymbolName
        }
    }
}
