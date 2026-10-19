import SwiftUI
import LavaSecKit
import UIKit

struct LocalLogSearchField: View {
    @Binding var text: String
    var placeholder: String = "Search domains"

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(LavaStyle.secondaryText)
                .frame(width: 18)

            TextField(placeholder.lavaLocalized, text: $text)
                .font(.body)
                .foregroundStyle(LavaStyle.primaryText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .submitLabel(.search)

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(LavaStyle.secondaryText)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
        .lavaSurface(.panel, cornerRadius: LavaSurface.compactCornerRadius, borderTint: LavaSurface.panelStroke.opacity(0.65))
    }
}

extension FilterDecisionReason {
    /// Clean, localizable source label for the Domain History / Top Domains row
    /// (rawValue.capitalized produced ugly camelCase like "Localallowlist").
    var domainHistoryLabel: String {
        switch self {
        case .defaultAllow: return "Default"
        case .localAllowlist: return "Allowlist"
        case .blocklist: return "Blocklist"
        case .threatGuardrail: return "Threat Guardrail"
        case .invalidDomain: return "Invalid domain"
        case .pausedAllow: return "Allowed on Pause"
        // Fail-closed blocks are dropped from Domain History, so this is reached only via
        // historical/exported/bug-report rendering — keep it honest rather than "Blocklist".
        case .protectionUnavailable: return "Failed safe"
        }
    }
}
