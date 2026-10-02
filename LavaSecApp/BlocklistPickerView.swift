import SwiftUI
import LavaSecKit

private enum CustomBlocklistFocusField: Hashable {
    case displayName
    case url
}

struct BringYourOwnListView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var customDisplayName = ""
    @State private var customURL = ""
    @State private var customMessage: String?
    @FocusState private var focusedField: CustomBlocklistFocusField?

    let isOverBudget: Bool
    let allowsCustomBlocklists: Bool
    let upgradeAccessory: LavaNavigationCardAccessory
    let addCustomSource: (String, String) -> String?
    let showUpgrade: () -> Void
    var onDismissRequested: (() -> Void)? = nil

    var body: some View {
        LavaSheetScaffold(spacing: 18, scrolls: true) {
            if allowsCustomBlocklists {
                customListForm
            } else {
                upgradeRow
            }
        }
        .navigationTitle("Bring your own list".lavaLocalized)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var customListForm: some View {
        LavaCustomEntryForm(actionTitle: "Add Blocklist", actionSymbol: "plus", enabled: canAddCustomSource, submit: submit) {
                LavaTextInputRow(title: "Name (optional)") {
                    TextField("My blocklist".lavaLocalized, text: $customDisplayName)
                        .lavaTextInputBody()
                        .focused($focusedField, equals: .displayName)
                }

                Divider()

                LavaTextInputRow(title: "Blocklist URL") {
                    TextField("https://example.com/pi-hole-style-list.txt", text: $customURL)
                        .lavaTextInputBody(keyboardType: .URL)
                        .focused($focusedField, equals: .url)
                }
        } notice: {
            if let customSourceFooterText {
                Text(customSourceFooterText.lavaLocalized)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(LavaStyle.lavaOrangeText)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }

            if let customMessage {
                DomainRejectPanel(title: "Custom source cannot be added", message: customMessage)
            }

        }
    }

    private var upgradeRow: some View {
        Button(action: showUpgrade) {
            LavaNavigationCardLabel(
                badge: .custom(LavaSecurityPlusGlyph()),
                badgeSize: 34,
                rowSpacing: LavaSpacing.md,
                title: "Upgrade",
                summary: .standardLocalized("Bring your own list"),
                accessory: upgradeAccessory
            )
        }
        .buttonStyle(LavaCondensedRowButtonStyle())
    }

    private var trimmedCustomURL: String {
        customURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canAddCustomSource: Bool {
        !trimmedCustomURL.isEmpty && !isOverBudget
    }

    private var customSourceFooterText: String? {
        if isOverBudget {
            return "Remove a list before adding another — you're at your filter-rule limit."
        }

        return nil
    }

    private func submit() {
        customMessage = nil
        if let error = addCustomSource(customDisplayName, trimmedCustomURL) {
            customMessage = error
            return
        }

        customDisplayName = ""
        customURL = ""
        if let onDismissRequested { onDismissRequested() } else { dismiss() }
    }
}
