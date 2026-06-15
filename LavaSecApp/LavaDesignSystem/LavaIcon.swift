import SwiftUI

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
}

/// Renders a `LavaIconRole` as its platform glyph (iOS: the SF Symbol).
struct LavaIcon: View {
    let role: LavaIconRole
    var body: some View { Image(systemName: role.sfSymbolName) }
}
