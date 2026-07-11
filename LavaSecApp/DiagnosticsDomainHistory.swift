import SwiftUI
import LavaSecKit
import UIKit

struct DomainHistoryView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    // The diagnostics scope (Phase D4 peel): store reads + the domain-history clear.
    @EnvironmentObject private var reports: DiagnosticsController
    @EnvironmentObject private var security: SecurityController
    @State private var selectedFilter: DomainHistoryFilter = .blocked
    @State private var searchText = ""
    @State private var visibleEventCount = LocalLogPagination.initialCount
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
                    historyRows
                } else {
                    LavaCondensedList {
                        localHistoryOffContent
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                    }
                }
            }
        }
        .localLogSubpageChrome(
            title: "Domain History",
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
                    visibleEventCount = LocalLogPagination.initialCount
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
        .onChange(of: selectedFilter) { _, _ in
            visibleEventCount = LocalLogPagination.initialCount
        }
        .onChange(of: searchText) { _, _ in
            visibleEventCount = LocalLogPagination.initialCount
        }
        .onChange(of: reports.diagnostics.recentEvents.count) { _, _ in
            visibleEventCount = LocalLogPagination.initialCount
        }
    }

    @ViewBuilder
    private var historyRows: some View {
        // Domain History rows come from the SQLite depth store (full 7-day window) rather than
        // the 250-entry JSON buffer, so a heavy user can scroll past the last ~250 queries.
        // Top Domains and the aggregate counts still read the JSON store.
        let events = reports.domainHistoryEvents(
            action: selectedFilter.action,
            searchText: searchText,
            limit: visibleEventCount + 1
        )
        let visibleEvents = Array(events.prefix(visibleEventCount))

        VStack(alignment: .leading, spacing: 10) {
            if !events.isEmpty {
                DomainRowActionHint()
            }

            LavaCondensedList {
                if events.isEmpty {
                    LavaEmptyListRow(title: searchText.isEmpty ? selectedFilter.emptyText : "No domains match this search")
                } else {
                    ForEach(Array(visibleEvents.enumerated()), id: \.element.id) { index, event in
                        DomainHistoryRow(
                            event: event,
                            addToBlocked: {
                                stageDomainAction(event.domain, target: .blocked)
                            },
                            addToAllowed: {
                                stageDomainAction(event.domain, target: .allowed)
                            }
                        )

                        if index < visibleEvents.count - 1 {
                            LavaCondensedDivider(leadingInset: 54)
                        }
                    }

                    LocalLogLoadMoreSentinel(hasMore: events.count > visibleEvents.count) {
                        visibleEventCount += LocalLogPagination.pageSize
                    }
                }
            }
        }
    }

    private var localHistoryOffContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Local history is off", systemImage: "lock.shield")
                .font(.headline)
                .foregroundStyle(LavaStyle.safeGreen)

            Text("Turn on local history only if you want this searchable list.")
                .lavaSupportingText()

            Button("Turn On Local History") {
                reports.setKeepDomainDiagnostics(true)
            }
            .buttonStyle(.borderedProminent)
            .tint(LavaStyle.safeControlGreen)
        }
        .padding(.vertical, 6)
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
private struct DomainHistoryRow: View {
    let event: DNSQueryEvent
    let addToBlocked: () -> Void
    let addToAllowed: () -> Void

    var body: some View {
        LavaCondensedListItem(
            title: event.domain,
            metadata: rowDetailText,
            titleLineLimit: 2
        ) {
            Image(systemName: rowIconName)
                .foregroundStyle(rowIconColor)
                .font(.title3)
                .frame(width: 28)
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button {
                UIPasteboard.general.string = event.domain
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

    private var rowDetailText: String {
        "\(event.decision.reason.domainHistoryLabel.lavaLocalized) · \(event.timestampLine)"
    }

    // Paused-allows get the same "protection paused" glyph/tint used elsewhere in the app
    // (AppViewModel.protectionSymbolName, the sleeping-shield mascot) instead of the usual
    // per-action allow/block styling, so they read as "let through," not "normally allowed."
    private var rowIconName: String {
        event.decision.reason == .pausedAllow
            ? "pause.circle.fill"
            : (event.decision.action == .block ? "hand.raised.circle.fill" : "arrow.right.circle.fill")
    }

    private var rowIconColor: Color {
        event.decision.reason == .pausedAllow
            ? LavaStyle.guardianSleepGray
            : (event.decision.action == .block ? LavaStyle.lavaOrange : LavaStyle.safeGreen)
    }
}

private extension FilterDecisionReason {
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
