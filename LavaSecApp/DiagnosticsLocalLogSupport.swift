import SwiftUI
import LavaSecKit
import UIKit

enum LocalLogPagination {
    static let initialCount = 30
    static let pageSize = 30
}

private struct LocalLogSubpageChrome: ViewModifier {
    let title: String
    let canClear: Bool
    let clear: () -> Void

    func body(content: Content) -> some View {
        content
            .navigationTitle(title.lavaLocalized)
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    NativeToolbarIconButton(systemName: "trash", accessibilityLabel: "Clear", role: .destructive, action: clear)
                        .disabled(!canClear)
                }
            }
            // Every local-log subpage (Network Activity, Domain History, Top Domains) is a
            // Workshop-depth power-user surface, so they all declare the technical tier here.
            .lavaTier(.technical)
    }
}

extension View {
    func localLogSubpageChrome(
        title: String,
        canClear: Bool,
        clear: @escaping () -> Void
    ) -> some View {
        modifier(LocalLogSubpageChrome(title: title, canClear: canClear, clear: clear))
    }
}

struct LocalLogLoadMoreSentinel: View {
    let hasMore: Bool
    let loadMore: () -> Void

    var body: some View {
        GeometryReader { proxy in
            let minY = proxy.frame(in: .global).minY

            Color.clear
                .onAppear {
                    loadMoreIfNeeded(sentinelMinY: minY)
                }
                .onChange(of: minY) { _, newMinY in
                    loadMoreIfNeeded(sentinelMinY: newMinY)
                }
        }
        .frame(height: hasMore ? 1 : 0)
    }

    private func loadMoreIfNeeded(sentinelMinY: CGFloat) {
        guard hasMore else {
            return
        }

        let preloadLine = UIScreen.main.bounds.height + 80
        guard sentinelMinY <= preloadLine else {
            return
        }

        loadMore()
    }
}

struct LocalLogSearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(LavaStyle.secondaryText)
                .frame(width: 18)

            TextField("Search domains", text: $text)
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

enum DomainHistoryFilter: String, CaseIterable, Identifiable {
    case allowed = "Allowed"
    case blocked = "Blocked"

    var id: String {
        rawValue
    }

    var action: FilterAction {
        switch self {
        case .allowed:
            .allow
        case .blocked:
            .block
        }
    }

    var emptyText: String {
        switch self {
        case .allowed:
            "No allowed domains saved yet"
        case .blocked:
            "No blocked domains saved yet"
        }
    }
}

struct DomainHistoryDomainActionAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

/// Quiet reminder shown directly above the domain rows (Top Domains / Domain
/// History) that a long-press exposes the allow/block actions. Kept at the top of
/// the list — not in the section footer — so it reads as a reminder before you act.
struct DomainRowActionHint: View {
    var body: some View {
        Text("Touch and hold a domain to allow or block it.")
            .lavaQuietNoteText()
    }
}
