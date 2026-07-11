import SwiftUI
import LavaSecKit
import UIKit

/// Top Domains lives under Local Logs as its own screen: the same Allowed/Blocked
/// segmented toggle as Domain History, over a list of domains ranked by query
/// count (`topDomains`) for the selected Activity range. Each row's subtitle is
/// the query count ("N times").
struct TopDomainsView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    // The diagnostics scope (Phase D4 peel): store reads + the domain-history clear.
    @EnvironmentObject private var reports: DiagnosticsController
    @EnvironmentObject private var security: SecurityController
    let rangeStart: Date
    let rangeEnd: Date
    @State private var selectedFilter: DomainHistoryFilter = .blocked
    @State private var searchText = ""
    @State private var showingClearHistoryConfirmation = false
    @State private var activeReviewSheet: FilterReviewOrigin?
    @State private var domainActionAlert: DomainHistoryDomainActionAlert?

    var body: some View {
        LavaScreenContent(
            spacing: 22,
            refreshAction: {
                await viewModel.sampleReports()
            }
        ) {
            LocalLogSearchField(text: $searchText)

            LavaSectionGroup("Show") {
                LavaCondensedList {
                    Picker("History Type", selection: $selectedFilter) {
                        ForEach(DomainHistoryFilter.allCases) { filter in
                            Text(filter.rawValue.lavaLocalized).tag(filter)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
            }

            LavaSectionGroup(
                selectedFilter.rawValue,
                footer: "Kept on this iPhone for 7 days, and only leaves the device if you export it or attach it to a bug report."
            ) {
                if viewModel.configuration.keepDomainDiagnostics {
                    topDomainRows
                } else {
                    LavaCondensedList {
                        LavaEmptyListRow(title: "Turn on Domain History to see your most frequent domains.")
                    }
                }
            }
        }
        .localLogSubpageChrome(
            title: "Top Domains",
            canClear: viewModel.configuration.keepDomainDiagnostics && !reports.diagnostics.recentEvents.isEmpty,
            clear: { showingClearHistoryConfirmation = true }
        )
        .lavaConfirmationAlert { host in
            host.alert(
                "Clear Domain Logs?",
                isPresented: $showingClearHistoryConfirmation
            ) {
                Button("Cancel", role: .cancel) {}
                Button("Clear Domain Logs", role: .destructive) {
                    reports.clearDomainHistory()
                }
            } message: {
                Text("This removes saved Domain Logs from this phone. Filtering counts and network activity are unchanged.")
            }
        }
        .sheet(item: $activeReviewSheet) { _ in
            FilterConfirmationSheet(origin: .domainHistory)
                .environmentObject(viewModel)
        }
        .fullScreenCover(isPresented: Binding(
            get: { viewModel.isFilterPreparationScreenPresented && viewModel.filterPreparationOrigin == .domainHistory },
            set: { if !$0 { viewModel.isFilterPreparationScreenPresented = false } }
        )) {
            FilterPreparationScreen(origin: .domainHistory) {
                activeReviewSheet = .domainHistory
            }
            .environmentObject(viewModel)
        }
        .alert(item: $domainActionAlert) { alert in
            Alert(
                title: Text(alert.title.lavaLocalized),
                message: Text(alert.message.lavaLocalized),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    @ViewBuilder
    private var topDomainRows: some View {
        let domains = reports.diagnostics.topDomains(
            action: selectedFilter.action,
            from: rangeStart,
            to: rangeEnd,
            searchText: searchText,
            limit: 20
        )

        VStack(alignment: .leading, spacing: 10) {
            if !domains.isEmpty {
                DomainRowActionHint()
            }

            LavaCondensedList {
                if domains.isEmpty {
                    LavaEmptyListRow(title: searchText.isEmpty ? selectedFilter.emptyText : "No domains match this search")
                } else {
                    ForEach(Array(domains.enumerated()), id: \.element.domain) { index, item in
                        TopDomainRow(
                            domain: item.domain,
                            count: item.count,
                            action: selectedFilter.action,
                            addToBlocked: {
                                stageDomainAction(item.domain, target: .blocked)
                            },
                            addToAllowed: {
                                stageDomainAction(item.domain, target: .allowed)
                            }
                        )

                        if index < domains.count - 1 {
                            LavaCondensedDivider(leadingInset: 54)
                        }
                    }
                }
            }
        }
    }

    private func stageDomainAction(_ domain: String, target: DomainHistoryDomainTarget) {
        Task {
            guard await security.requireFreshAuthentication(for: .filterEditing, reason: "Update domains and lists") else {
                return
            }

            let result = viewModel.stageDomainHistoryDomainAction(domain, target: target)
            guard result.isAccepted else {
                domainActionAlert = DomainHistoryDomainActionAlert(
                    title: result.title,
                    message: result.message
                )
                return
            }

            activeReviewSheet = .domainHistory
        }
    }
}
private struct TopDomainRow: View {
    let domain: String
    let count: Int
    let action: FilterAction
    let addToBlocked: () -> Void
    let addToAllowed: () -> Void

    var body: some View {
        LavaCondensedListItem(
            title: domain,
            metadata: "%@ times".lavaLocalizedFormat(count.formatted()),
            titleLineLimit: 2
        ) {
            Image(systemName: action == .block ? "hand.raised.circle.fill" : "arrow.right.circle.fill")
                .foregroundStyle(action == .block ? LavaStyle.lavaOrange : LavaStyle.safeGreen)
                .font(.title3)
                .frame(width: 28)
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button {
                UIPasteboard.general.string = domain
                ProtectionHapticFeedback.play(.selectionConfirmed)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }

            Button(action: addToBlocked) {
                Label("Block", systemImage: "hand.raised.fill")
            }

            Button(action: addToAllowed) {
                Label("Allow", systemImage: "arrow.right.circle.fill")
            }
        }
    }
}
