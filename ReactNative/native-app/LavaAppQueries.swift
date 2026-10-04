import Foundation
import UIKit
import LavaSecKit
import LavaSecAppServices

extension LavaAppBridge {
    func query(_ name: String, _ input: [String: Any]) async throws -> Any {
        guard let policy = PresentationReadPolicy(rawValue: name) else { throw CommandError("Unknown query.") }
        let surface: SecurityProtectedSurface = [.activity, .domains, .network, .stats].contains(policy) ? .activityViewing : policy == .share ? .appUnlock : .filterEditing
        // `share.query` pins the module retirement epoch across BOTH of its
        // authorizations: a module invalidation during either biometric suspension
        // must abort before `shareCardQuery` mints a grant for a torn-down module.
        let shareModuleEpoch = policy == .share ? shareCardModuleEpoch : nil
        try await authorize(surface, surface == .activityViewing ? "View Activities" : "View filter", fresh: name == "domains.stage")
        // `share.query` also requires `.filterEditing`. Authorize it BEFORE the
        // presentation read ticket opens: when it is protected, the biometric
        // prompt posts `willResignActive`, which invalidates the presentation
        // cache and rotates its generation. Authorizing inside the ticket window
        // therefore made a successful share authorization look like a revoked
        // read, so the card never loaded.
        if policy == .share {
            try await authorize(.filterEditing, "Share Filter", fresh: false)
            guard shareModuleEpoch == shareCardModuleEpoch else {
                throw CommandError("This filter cannot be shared.")
            }
        }
        // Normalize/prune the local source before pinning its revision.
        if policy == .activity || policy == .domains { model.reports.refreshDiagnostics() }
        let revision = security.viewAuthenticationRevision
        let scope = presentationScope(name, input)
        let sourceGeneration = presentationSourceGeneration
        let allowed = { [self] in
            let current = presentationScope(name, input)
            return canReadPresentation(surface) && security.viewAuthenticationRevision == revision
                && presentationSourceGeneration == sourceGeneration && current.owner == scope.owner && current.logPolicy == scope.logPolicy
                && (!(policy == .activity || policy == .domains) || current.sourceRevision == scope.sourceRevision)
        }
        let ticket = try presentationCache.beginRead(query: name, scope: scope, authorize: allowed)
        if let data = try presentationCache.cachedData(for: ticket, authorize: allowed) {
            // Native authorization gates both the warm result and its independent
            // refresh. Neither keys nor a grant capability cross the JS bridge.
            Task { @MainActor [weak self] in
                guard let self, allowed() else { return }
                guard let fresh = try? await freshQuery(name, input), allowed(),
                      let data = try? JSONSerialization.data(withJSONObject: fresh) else { return }
                try? presentationCache.store(data, for: ticket, authorize: allowed)
            }
            let result = try JSONSerialization.jsonObject(with: data)
            return AuthorizedPresentationResult(value: result) {
                try self.presentationCache.validate(ticket, authorize: allowed)
            }
        }
        let result: Any
        if policy == .activity || policy == .domains {
            result = try await AuthorizedLocalReportRead.run(authorize: { ticket },
                readDiagnostics: { try await self.freshQuery(name, input) }, compose: { $0 },
                validate: { try self.presentationCache.validate($0, authorize: allowed) })
        } else { result = try await freshQuery(name, input) }
        try presentationCache.validate(ticket, authorize: allowed)
        if policy.permitsEncryptedReuse {
            try presentationCache.store(JSONSerialization.data(withJSONObject: result), for: ticket, authorize: allowed)
        }
        return AuthorizedPresentationResult(value: result) {
            try self.presentationCache.validate(ticket, authorize: allowed)
        }
    }

    func canReadPresentation(_ surface: SecurityProtectedSurface) -> Bool {
        UIApplication.shared.applicationState == .active && UIApplication.shared.isProtectedDataAvailable && security.hasCurrentAuthorization(for: surface)
    }

    // This control file changes only for destructive history/count clears, unlike
    // the live diagnostics file which legitimately advances with every sample.
    var presentationClearRevision: String {
        let control = LavaSecAppGroup.containerURL?.appendingPathComponent(LavaSecAppGroup.diagnosticsControlFilename)
        let modified = control.flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path)[.modificationDate] as? Date }
        let floor = LavaSecAppGroup.sharedDefaults.double(forKey: LavaSecAppGroup.dnsEventLogClearedAtKeyName)
        return "\(modified?.timeIntervalSince1970 ?? 0):\(floor)"
    }

    private func presentationScope(_ name: String, _ input: [String: Any]) -> PresentationCacheScope {
        let source = LavaSecAppGroup.containerURL?.appendingPathComponent(LavaSecAppGroup.diagnosticsFilename)
        let attributes = source.flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path) }
        let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
        return PresentationCacheScope(owner: model.account.accountAuthState.connections.all.map { $0.session.userID }.sorted().joined(separator: ":"),
            resource: json(input), sourceRevision: "\(presentationSourceGeneration):\(modified):\(size)",
            logPolicy: "\(model.configuration.keepFilteringCounts):\(model.configuration.keepDomainDiagnostics):\(model.configuration.keepNetworkActivity):\(presentationClearRevision)",
            authorizationPolicyGeneration: String(security.viewAuthenticationRevision))
    }

    private func freshQuery(_ name: String, _ input: [String: Any]) async throws -> Any {
        #if (DEBUG || LAVA_QA_TOOLS) && targetEnvironment(simulator)
        // Exercise real native reads while their replies are delayed. This UI-test
        // fixture never changes data, authorization, or production timing.
        if ProcessInfo.processInfo.environment["LAVA_UI_TEST_DELAY_QUERIES"] == "1" {
            NSLog("LAVA_QUERY_NATIVE_DELAY %@", name)
            try await Task.sleep(for: .seconds(5))
            NSLog("LAVA_QUERY_NATIVE_READ %@", name)
        }
        #endif
        switch name {
        case "catalog.query":
            let ids = input["ids"] as? [String] ?? []
            let available = model.blocklists.map(\.id) + model.displayedCustomBlocklists.map(\.id)
            let selected = Set(available).intersection(ids)
            let budget = model.filterRuleBudgetStatus(forEnabledIDs: selected)
            var sections: [[String: Any]] = DefaultCatalog.groupedByCategory(model.blocklists).map { section in
                ["title": section.category.displayLabel, "sources": section.sources.map { source in
                    ["id": source.id, "name": source.name, "licenseName": source.licenseName, "sourceURL": source.sourceURL.absoluteString,
                        "metadata": model.blocklistRuleCountText(for: source)]
                }]
            }
            if !model.displayedCustomBlocklists.isEmpty {
                sections.append(["title": "Your Lists", "isCustom": true, "sources": model.displayedCustomBlocklists.map { source in
                    ["id": source.id, "name": model.blocklistName(for: source.id), "licenseName": "Custom List", "sourceURL": source.sourceURL.absoluteString,
                        "metadata": model.blocklistMetadataText(for: source.id) ?? "Pending refresh"]
                }])
            }
            return ["sections": sections, "count": budget.displayedRuleCount, "budget": budget.budget,
                "pending": budget.pendingLists, "exceeded": model.enabledIDsExceedSoftRuleBudget(selected),
                "summary": model.filterRuleBudgetSelectionText(forEnabledIDs: selected),
                "fraction": budget.fraction, "indeterminate": budget.isIndeterminate, "atOrOverBudget": budget.isAtOrOverBudget]

        case "activity.query", "domains.query":
            // Activity and domains need only local diagnostics. Tunnel-health
            // capture remains independently owned by the health/Feedback paths.
            model.reports.refreshDiagnostics()
            let now = Date()
            let start = Date(timeIntervalSince1970: (input["start"] as? Double ?? now.timeIntervalSince1970 * 1000) / 1000)
            let end = Date(timeIntervalSince1970: (input["end"] as? Double ?? now.timeIntervalSince1970 * 1000) / 1000)
            guard start.timeIntervalSince1970.isFinite, end.timeIntervalSince1970.isFinite,
                  end >= start else { throw CommandError("Choose a valid date range.") }
            if name == "activity.query" {
                guard (Calendar.current.dateComponents([.day], from: start, to: end).day ?? 0) <= 731 else {
                    throw CommandError("Choose a shorter date range.")
                }
                let summary = model.reports.diagnostics.rangeSummary(from: start, to: end)
                let hourly = input["hourly"] as? Bool == true && Calendar.current.isDate(start, inSameDayAs: end)
                let buckets = model.reports.diagnostics.activityBuckets(from: start, to: end, hourly: hourly).map { bucket -> [String: Any] in
                    ["start": bucket.start.timeIntervalSince1970 * 1000,
                     "label": hourly ? bucket.start.formatted(date: .omitted, time: .shortened) : bucket.start.formatted(.dateTime.month(.abbreviated).day()),
                     "allowed": bucket.allowed, "blocked": bucket.blocked, "available": bucket.available, "partial": bucket.partial]
                }
                return ["allowed": summary.allowedCount, "blocked": summary.blockedCount, "uptime": summary.compactLocalProtectionUptimeText, "buckets": buckets]
            }
            guard model.configuration.keepDomainDiagnostics else { return [] }
            guard let decision = input["decision"] as? String, ["All", "Allowed", "Blocked"].contains(decision) else { throw CommandError("Choose All, Allowed or Blocked.") }
            let action: FilterAction? = decision == "All" ? nil : decision == "Allowed" ? .allow : .block
            let search = String((input["search"] as? String ?? "").prefix(253))
            if input["history"] as? Bool == true {
                guard let limit = input["limit"] as? Int, limit > 0 else { throw CommandError("Invalid page size.") }
                return model.reports.domainHistoryEvents(action: action, searchText: search, limit: limit).map {
                    ["id": $0.id.uuidString, "domain": $0.domain,
                     "icon": $0.decision.reason == .pausedAllow ? "pause.circle.fill" : $0.decision.action == .block ? LavaOutcomeSymbol.blocked : LavaOutcomeSymbol.allowed,
                     "tone": $0.decision.reason == .pausedAllow ? "secondary" : $0.decision.action == .block ? "accentOrange" : "green",
                     "metadata": "\($0.decision.reason.domainHistoryLabel.lavaLocalized) · \($0.timestampLine)"]
                }
            }
            return model.reports.diagnostics.topDomainOutcomes(action: action, from: start, to: end, searchText: search, limit: 20).map {
                ["id": $0.id, "domain": $0.domain,
                 "icon": $0.action == .block ? LavaOutcomeSymbol.blocked : LavaOutcomeSymbol.allowed,
                 "tone": $0.action == .block ? "accentOrange" : "green",
                 "metadata": "%@ times".lavaLocalizedFormat($0.count.formatted())]
            }

        case "share.query":
            return try await shareCardQuery(input)
        case "network.query":
            model.refreshNetworkActivityLog(force: true)
            return model.networkActivityLog.entries.map { entry -> [String: Any] in
                let theme = entry.event.activityTheme
                return ["id": entry.id.uuidString, "title": entry.eventLine, "subtitle": entry.lavaStateLine,
                    "metadata": entry.timestampLine,
                    "theme": ["title": theme.title.lavaLocalized, "symbol": theme.systemImage, "tone": theme.tone]]
            }
        case "stats.query": return await stats()
        case "domains.stage":
            guard let decision = input["decision"] as? String, ["allowed", "blocked"].contains(decision) else { throw CommandError("Choose an allowed or blocked domain action.") }
            let result = model.stageDomainHistoryDomainAction(input["domain"] as? String ?? "", target: input["decision"] as? String == "allowed" ? .allowed : .blocked)
            guard result.isAccepted else { return ["rejection": ["title": result.title, "message": result.message]] }
            guard let draft = model.filterEditDraft else { throw CommandError("Start editing this filter first.") }
            let id = model.filterEditTargetID ?? model.activeFilterID
            let token = UUID().uuidString
            standaloneDomainReviews[token] = StandaloneDomainReview(filterID: id, draft: draft)
            return ["id": id, "standaloneReview": token]
        default: throw CommandError("Unknown query.")
        }
    }
    func setActivityVisibility(_ input: [String: Any]) async throws {
        guard let token = input["token"] as? String else { throw CommandError("Missing Activity view identity.") }
        if input["visible"] as? Bool != true {
            if activityDwellToken == token { activityDwellTask?.cancel(); activityDwellTask = nil; activityDwellToken = nil }
            return
        }
        activityDwellTask?.cancel()
        activityDwellToken = token
        try await authorize(.activityViewing, "View Activities", fresh: false)
        guard activityDwellToken == token, let from = input["start"] as? Double, let to = input["end"] as? Double,
              from.isFinite, to.isFinite, to >= from else { return }
        let start = Date(timeIntervalSince1970: from / 1000), end = Date(timeIntervalSince1970: to / 1000)
        let summary = model.reports.diagnostics.rangeSummary(from: start, to: end)
        guard summary.totalCount > ReviewPromptPolicy.activityMinTotalQueries, summary.blockRate > ReviewPromptPolicy.activityMinBlockRate else { return }
        activityDwellTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(ReviewPromptPolicy.activityMinDwellSeconds))
            guard !Task.isCancelled, let self, activityDwellToken == token, UIApplication.shared.applicationState == .active else { return }
            model.reports.refreshDiagnostics()
            let current = model.reports.diagnostics.rangeSummary(from: start, to: end)
            model.noteActivityViewingReviewMoment(totalQueries: current.totalCount, blockRate: current.blockRate)
        }
    }
    func stats() async -> [String: Any] {
        let sample = await model.sampleTunnelStats()
        let systemDNS = await VersionDiagnostics.systemDNSTierSettings()
        let m = model, ladder = model.configuration.resolverLadderInputs
        let sections = VersionDiagnostics.healthSections(for: m, handshake: sample.handshake)
        return ["sampleNotice": sample.captured ? "" : "Live sample unavailable. Showing the last observation.".lavaLocalized,
            "healthSections": sections.map { section in
                ["id": section.id, "title": section.title.lavaLocalized, "rows": section.rows.map { row in
                    ["id": row.id, "title": row.title.lavaLocalized, "value": row.value.lavaLocalized]
                }] as [String: Any]
            },
            "tiers": [["T0 · VPN chaining", vpnTier()], ["1 · Primary DNS", resolverTier(ladder.resolver, enabled: true)],
            ["2 · Fallback DNS", resolverTier(ladder.configuredFallbackResolver, enabled: ladder.isConfiguredFallbackEnabled)],
            ["S · System DNS", systemDNS]],
            "app": [["Version", VersionInfo.appVersion], ["Platform", VersionInfo.platformVersion]] + (VersionInfo.sourceRevision.isEmpty ? [] : [["Source", VersionInfo.displayedSourceRevision]])]
    }
    private func vpnTier() -> String {
        let status = model.chainedUpstreamSurfaceStatus
        var rows: [String] = status.chainingEnabled ? [] : ["Off"]
        if let addresses = status.storedConfigurationDNSAddresses {
            rows.append("WireGuard")
            if status.hasConfigurationWithoutKey { rows.append("Private key missing") }
            if let split = status.storedConfigurationIsSplitTunnel { rows.append(split ? "Split tunnel" : "Full tunnel") }
            rows.append(addresses.isEmpty ? "No DNS servers configured" : addresses.joined(separator: ", "))
        } else { rows.append(status.storeUnavailableReason == nil ? "No saved configuration" : "Saved configuration unavailable") }
        return rows.map(\.lavaLocalized).joined(separator: "\n")
    }
    func resolverMetadata(_ preset: DNSResolverPreset) -> String {
        switch preset.transport {
        case .deviceDNS: return "Device DNS"
        case .plainDNS: return (preset.ipv4Servers + preset.ipv6Servers).joined(separator: ", ")
        case .dnsOverHTTPS: return preset.dohEndpoints.map { $0.url.absoluteString }.joined(separator: ", ")
        case .dnsOverTLS: return preset.dotEndpoints.map(\.displayAddress).joined(separator: ", ")
        case .dnsOverQUIC: return preset.doqEndpoints.map(\.displayAddress).joined(separator: ", ")
        }
    }
    private func resolverTier(_ preset: DNSResolverPreset, enabled: Bool) -> String {
        var rows = (enabled ? [] : ["Off"]) + [preset.settingsBasePreset.displayName]
        if preset.transport != .deviceDNS {
            rows.append(preset.transport.displayName)
            let addresses: [String]
            switch preset.transport {
            case .deviceDNS: addresses = []
            case .plainDNS: addresses = preset.ipv4Servers + preset.ipv6Servers
            case .dnsOverHTTPS: addresses = preset.dohEndpoints.compactMap { $0.url.host }
            case .dnsOverTLS: addresses = preset.dotEndpoints.map(\.displayAddress)
            case .dnsOverQUIC: addresses = preset.doqEndpoints.map(\.displayAddress)
            }
            if !addresses.isEmpty { rows.append(addresses.joined(separator: ", ")) }
        }
        return rows.map(\.lavaLocalized).joined(separator: "\n")
    }
}
