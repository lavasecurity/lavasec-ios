import Foundation
import Combine
import UIKit
@preconcurrency import NetworkExtension
import LavaSecKit
import LavaSecAppServices
import LavaSecPresentation

@MainActor
@objc(LavaAppBridge)
final class LavaAppBridge: NSObject, ObservableObject {
    @objc static let shared = LavaAppBridge()
    var model: AppViewModel { LavaProtectionShortcutRuntime.shared.viewModel }
    var security: SecurityController { LavaProtectionShortcutRuntime.shared.security }
    @Published var exporting = false
    private var buildingLogExport = false
    var logExportError = ""
    var exportDocument: LocalLogExportDocument?
    var exportFilename = "Lava-logs.zip"
    // Keep explicit key-cleanup retry available after a partial deletion.
    var wireGuardCleanupPending = false
    var wireGuardDraft: ChainedUpstreamEditDraft?
    var updatingSecuritySurface = false
    var reviewedFilter: ReviewedFilter?
    var filterEditAuthenticationInFlight = false
    var filterPresentationEpoch = 0
    let shareCardAuthority = LavaShareCardAuthority()
    var shareCardForegroundEpoch: UInt64 = 0
    var shareCardModuleEpoch: UInt64 = 0
    var standaloneDomainReviews: [String: StandaloneDomainReview] = [:]
    @Published var flow: LavaAppNativeFlow?
    @Published var feedbackDraftIsDirty = false
    let presentationCache = SecurePresentationCache()
    var presentationSourceGeneration: UInt64 = 0
    private var presentationOwnerRevision = PresentationOwnerRevision()
    private var presentationLibraryRevision = PresentationLibraryRevision()
    private var presentationLibraryDisplayRevision = "0"
    var presentationDisplayClearGeneration: UInt64 = 0
    private var subscriptions = Set<AnyCancellable>()
    private var observers: [UUID: (String) -> Void] = [:]
    private var revision = 0
    private var navigationSerial = 0
    private var navigation: [String: Any]?
    var guardRampTask: Task<Void, Never>?
    var activityDwellTask: Task<Void, Never>?
    var activityDwellToken: String?
    private var refreshTask: Task<Void, Never>?
    lazy var libraryEditor = FilterLibraryController(hub: model)
    private var publishQueued = false
    var dnsPatchProviderID: String {
        UserDefaults.standard.string(forKey: DNSPatchProviderCatalog.preferenceKey) ?? DNSPatchProviderCatalog.defaultID
    }
    var dnsPatchProvider: DNSResolverPreset? {
        DNSPatchProviderCatalog.choices.first { $0.id == dnsPatchProviderID } ?? DNSPatchProviderCatalog.providers.first { $0.id == dnsPatchProviderID }?.dnsOverTLSVariant
    }
    @Published var pushedCustomEntry: LavaAppNativeFlow?
    var dnsPickerCustomChoice: DNSResolutionSelection?
    var dnsPickerCustomToken: String?
    @Published var dnsPatchState = "checking"
    var dnsPatchConfigurationExists: Bool?
    @Published var dnsPatchBusy = false
    var dnsPatchRefreshPending = false

    func attach() {
        guard subscriptions.isEmpty else { return }
        #if DEBUG || LAVA_QA_TOOLS
        if ProcessInfo.processInfo.arguments.contains("-LavaQAResetDiscoveries") {
            for item in LavaDiscovery.allCases { UserDefaults.standard.removeObject(forKey: item.seenKey) }
        }
        #endif
        PrivateImportFiles.purgeExpired()
        #if DEBUG && targetEnvironment(simulator)
        // Each native UI journey declares its plan so a previous paid fixture
        // cannot leak persisted entitlement into a later free-plan scenario.
        if let plan = ProcessInfo.processInfo.environment["LAVA_UI_TEST_PLAN"], ["free", "paid"].contains(plan) {
            try? model.persistPaidPlanFlag(plan == "paid")
        }
        // Exercise the real picker/controller/icon path with an earned-unlock
        // ledger in the private test simulator. Never compiled into QA/device builds.
        // Render the manual-selection state on the iOS 26 simulator without
        // saving a real DNS configuration. Never compiled into device builds.
        if ProcessInfo.processInfo.environment["LAVA_UI_TEST_DNS_PATCH"] == "1" {
            dnsPatchState = "disabled"
            dnsPatchConfigurationExists = true
        }
        if ProcessInfo.processInfo.environment["LAVA_UI_TEST_GUARD_PICKER"] == "1" {
            for goal in LavaGuardProgressPolicy.unlockGoals {
                model.configuration.lavaGuardUnlocks.unlock(guardID: goal.guardID, unlockedAt: Date())
            }
            model.customization.setUpdatesAppIconWithLavaGuard(false)
            model.customization.setLavaGuardLook(.original)
        }
        #endif
        let publishers = [model.objectWillChange, model.account.objectWillChange,
            model.backup.objectWillChange, model.plus.objectWillChange, model.reports.objectWillChange,
            model.customization.objectWillChange, model.filterDrafts.objectWillChange,
            model.catalog.objectWillChange, security.objectWillChange, libraryEditor.objectWillChange]
        for publisher in publishers {
            publisher.sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.queuePublish() }
            }.store(in: &subscriptions)
        }
        // These publishers carry the new authority values synchronously, before
        // deferred snapshot delivery. Changed-then-restored content cannot revive
        // a previously mounted export token.
        model.$library.sink { [weak self] in self?.shareCardContentChanged($0) }.store(in: &subscriptions)
        security.$isAppUnlockBlockingUI.sink { [weak self] in self?.shareCardPrivacyChanged(isBlocked: $0) }.store(in: &subscriptions)
        security.$isAppUnlockPrivacyMaskVisible.sink { [weak self] in self?.shareCardPrivacyChanged(isBlocked: $0) }.store(in: &subscriptions)
        security.$isAuthenticationUnavailable.sink { [weak self] in self?.shareCardPrivacyChanged(isBlocked: $0) }.store(in: &subscriptions)
        security.$passcodeAuthenticationRequest.sink { [weak self] in self?.shareCardPrivacyChanged(isBlocked: $0 != nil) }.store(in: &subscriptions)
        model.account.objectWillChange.sink { [weak self] _ in
            MainActor.assumeIsolated {
                self?.presentationSourceGeneration &+= 1
                self?.shareCardPrivacyChanged(isBlocked: true)
                self?.presentationCache.invalidate()
            }
        }.store(in: &subscriptions)
        model.$library.removeDuplicates().sink { [weak self] library in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Hash actual library writes once, rather than serializing private
                // rules on every diagnostics/status projection.
                let current = self.presentationLibraryRevision.revision(for: library)
                if current != self.presentationLibraryDisplayRevision {
                    self.presentationLibraryDisplayRevision = current
                    self.presentationSourceGeneration &+= 1
                    self.presentationCache.invalidate()
                }
            }
        }.store(in: &subscriptions)
        security.$viewAuthenticationRevision.removeDuplicates().dropFirst().sink { [weak self] revision in
            MainActor.assumeIsolated {
                self?.shareCardSecurityChanged(revision: revision)
                self?.presentationCache.invalidate()
            }
        }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification).sink { [weak self] _ in
            MainActor.assumeIsolated { self?.presentationCache.invalidate() }
        }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: UIApplication.protectedDataWillBecomeUnavailableNotification).sink { [weak self] _ in
            MainActor.assumeIsolated {
                self?.security.protectedDataWillBecomeUnavailable()
                self?.shareCardPrivacyChanged(isBlocked: true)
                self?.presentationCache.invalidate()
                self?.publishPrivacyBoundary()
            }
        }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: UIApplication.protectedDataDidBecomeAvailableNotification).sink { [weak self] _ in
            MainActor.assumeIsolated {
                self?.security.protectedDataDidBecomeAvailable()
                self?.publish()
            }
        }.store(in: &subscriptions)
        refreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                if UIApplication.shared.applicationState == .active, let self {
                    model.reports.refreshDiagnostics()
                    await model.refreshProtectionStatus()
                    await model.sampleTunnelHealth()
                }
                try? await Task.sleep(for: .seconds(5))
            }
        }
        NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification).sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.stopGuardRamp() }
        }.store(in: &subscriptions)
        // UIKit posts foreground retirement on the main thread. Revoke before a
        // deferred React callback can capture a previously authorized surface.
        NotificationCenter.default.addObserver(self, selector: #selector(shareCardForegroundEnded),
            name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification).sink { [weak self] _ in
            // Restore the current authorized projection before asynchronous DNS
            // refresh work. snapshot() still withholds fields while Lava is locked.
            MainActor.assumeIsolated { self?.publish() }
            Task { @MainActor [weak self] in
                self?.model.refreshDNSSettingsPresentation()
                await self?.refreshManagedDNSPatch()
            }
        }.store(in: &subscriptions)
        model.$isStagingChainedUpstreamForQA.removeDuplicates().dropFirst().sink { [weak self] staging in
            guard !staging else { return }
            Task { @MainActor [weak self] in self?.model.refreshDNSSettingsPresentation() }
        }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: .NEDNSSettingsConfigurationDidChange).sink { [weak self] _ in
            Task { @MainActor [weak self] in await self?.refreshManagedDNSPatch() }
        }.store(in: &subscriptions)
        Task {
            model.refreshDNSSettingsPresentation()
            await refreshManagedDNSPatch()
        }
        Task { await model.plus.loadLavaSecurityPlusProducts() }
    }

    private func queuePublish() {
        guard !publishQueued else { return }
        publishQueued = true
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            publishQueued = false
            publish()
        }
    }
    func publish() {
        revision += 1
        let value = snapshot()
        for observer in observers.values { observer(value) }
    }
    private func publishPrivacyBoundary() {
        // Protected-data loss is announced before UIKit flips its availability
        // bit. Revoke reads without composing fields; conceal only when policy
        // requires it. An off marker cannot publish or recreate a display frame.
        revision += 1
        let value = json(["schema": 1, "fullApp": true, "revision": revision,
                          "presentationBlocked": true, "backgroundPrivacyCoverRequired": security.backgroundPrivacyCoverRequired])
        for observer in observers.values { observer(value) }
    }
    @objc func observe(_ callback: @escaping (String) -> Void) -> String {
        attach()
        let id = UUID(); observers[id] = callback
        return id.uuidString
    }
    @objc func removeObserver(_ token: String) { if let id = UUID(uuidString: token) { observers[id] = nil } }

    @objc func snapshot() -> String {
        // Direct snapshot calls are readers too. A locked/inactive caller gets no
        // private projection, rather than trusting JavaScript to discard fields.
        guard canReadPresentation(.appUnlock) else {
            return json(["schema": 1, "fullApp": true, "revision": revision, "presentationBlocked": true,
                         "backgroundPrivacyCoverRequired": security.backgroundPrivacyCoverRequired])
        }
        let m = model, c = model.customization
        let primary = m.configuration.resolverPreset
        let resolver = primary.id == DNSResolverPreset.device.id ? m.configuration.fallbackResolverPreset : primary
        let baseline = m.filterDetailBaseline
        let draft = m.filterEditDraft
        // Public coarse counts only. Never derive a Guard chart from protected domain history.
        let today = m.reports.diagnostics.dailySummary(on: Date())
        let selectedID = m.filterEditTargetID ?? m.activeFilterID
        let plusOffers = UpgradeSettingsView.displayedOffers(for: m.plus)
        let offerRows: [[String: String]] = plusOffers.map { offer in
            let commitment = offer.plan.kind == .yearlyPaidMonthly ? offer.commitmentDisplayPrice : nil
            return ["id": offer.id, "title": offer.title, "subtitle": UpgradeSettingsView.planPitch(for: offer),
                    "price": offer.displayPrice, "commitmentPrice": commitment.map { "%@ total".lavaLocalizedFormat($0) } ?? ""]
        }
        let backupEnablement = m.backup.enablementPresentation(
            isSetupOrRestorePresented: flow.map { ["backupSetup", "backupRestore"].contains($0.name) } ?? false
        )
        let backupNeedsAttention: Bool
        if case .failed = m.backup.encryptedBackupState { backupNeedsAttention = true } else { backupNeedsAttention = false }
        var value: [String: Any] = [
            "schema": 1, "revision": revision, "fullApp": true,
            "backgroundPrivacyCoverRequired": security.backgroundPrivacyCoverRequired,
            "onboarding": LavaOnboardingHandoff.shared.snapshot,
            "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            "sourceRevision": VersionInfo.sourceRevision,
            "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
            "protection": ["projectionRevision": m.chainedProjectionRevision, "title": m.protectionTitle.lavaLocalized, "subtitle": m.protectionSubtitle.lavaLocalized,
                "materialIntent": m.guardStatusPresentation.materialIntent.rawValue,
                "actionTone": m.protectionActionTone,
                "action": m.protectionButtonTitle.lavaLocalized, "disabled": m.protectionPrimaryActionIsDisabled,
                "configuring": m.isConfiguringVPN, "quiet": m.protectionButtonTint == LavaStyle.quietControl, "pauseOptions": ProtectionPauseDuration.allCases.map { ["minutes": Int($0.duration / 60), "title": $0.label] as [String: Any] },
                "status": m.vpnStatus.rawValue, "paused": m.isProtectionTemporarilyPaused,
                "canPause": m.showsTemporaryProtectionPauseControls, "needsVPNSetup": m.showsChainedConfigurationRecovery,
                "needsDNSProviderChange": m.showsDNSProviderRecovery,
                "mood": guardMood(), "rules": m.protectedRuleCount, "activity": m.reports.guardActivityRowStat.lavaLocalized,
                "today": ["countsEnabled": m.configuration.keepFilteringCounts,
                          "allowed": m.configuration.keepFilteringCounts ? today.allowedCount : 0,
                          "blocked": m.configuration.keepFilteringCounts ? today.blockedCount : 0]],
            "account": ["signedIn": m.account.isAccountSignedIn, "status": m.account.accountStatusText.lavaLocalized,
                "detail": m.account.accountStatusDetailText.lavaLocalized,
                "appleTitle": m.account.appleSignInActionTitle.lavaLocalized, "googleTitle": m.account.googleSignInActionTitle.lavaLocalized,
                "appleConnected": m.account.isAppleAccountConnected, "googleConnected": m.account.isGoogleAccountConnected,
                "appleBusy": m.account.isAppleSignInInProgress, "googleBusy": m.account.isGoogleSignInInProgress,
                "busy": m.account.isAccountSignInInProgress, "message": m.account.accountAuthMessage ?? ""],
            "backup": ["enablement": [
                    "state": backupEnablement.state.rawValue, "value": backupEnablement.value as Any? ?? NSNull(),
                    "canEnable": backupEnablement.canEnable, "canDisable": backupEnablement.canDisable,
                    "canBackUp": backupEnablement.canBackUp, "canRestore": backupEnablement.canRestore,
                    "canChangeAutomatic": backupEnablement.canChangeAutomatic, "canRetryDeletion": backupEnablement.canRetryDeletion
                ], "configured": m.backup.isEncryptedBackupConfigured, "title": m.backup.encryptedBackupInfoTitle.lavaLocalized,
                "summary": m.backup.encryptedBackupSummaryText.lavaLocalized,
                "detail": m.backup.encryptedBackupState.displayText(isAccountSignedIn: m.account.isAccountSignedIn).detail.lavaLocalized,
                "remoteStatus": m.backup.backupStatusSubtitle,
                "remoteAvailable": m.backup.remoteBackupAvailable,
                "statusUnavailable": m.backup.remoteBackupStatusUnavailable,
                "needsAttention": backupNeedsAttention, "deletionPending": m.backup.requiresBackupDeletionRetry, "automatic": m.backup.isAutomaticBackupEnabled,
                "backingUp": m.backup.isBackingUpNow, "busy": m.backup.isBackingUpNow || m.backup.isBackupMaintenanceInProgress],
            "plus": ["enabled": m.configuration.hasLavaSecurityPlus, "busy": m.plus.isPurchasingLavaSecurityPlus,
                "checking": !m.plus.hasCheckedLavaSecurityPlusEntitlements || m.plus.isRefreshingLavaSecurityPlusEntitlements,
                "showsYearlyPaidMonthly": plusOffers.contains { $0.plan.kind == .yearlyPaidMonthly },
                "expiration": m.plus.lavaSecurityPlusExpiresAt.map { "Expiration: %@".lavaLocalizedFormat($0.formatted(date: .abbreviated, time: .omitted)) } ?? "",
                "message": m.plus.lavaSecurityPlusMessage ?? "", "offers": offerRows],
            "look": c.lavaGuardLook.rawValue,
            "session": [
                "filter": m.filter(id: selectedID)?.name ?? "", "filterID": selectedID,
                "activeFilter": m.filter(id: m.activeFilterID)?.name ?? "", "activeFilterID": m.activeFilterID,
                "editing": draft != nil,
                "blocklists": (draft?.enabledBlocklistIDs ?? baseline.enabledBlocklistIDs).sorted(),
                "savedBlocklists": baseline.enabledBlocklistIDs.sorted(),
                "logs": ["Filtering Counts": m.configuration.keepFilteringCounts, "Domain logs": m.configuration.keepDomainDiagnostics,
                    "Network activity": m.configuration.keepNetworkActivity, "Lava Guard Progress": m.configuration.keepLavaGuardProgress],
                "notifications": ["Filter changes": c.notifiesFilterChanges, "Filter couldn't switch": c.notifiesFilterCouldNotApply,
                    "Protection resumed": c.notifiesProtectionResumed, "Connection updates": c.notifiesConnectivity],
                "deviceDNS": primary.id == DNSResolverPreset.device.id,
                "fallback": primary.id == DNSResolverPreset.device.id ? m.configuration.usesEncryptedDeviceDNSFallback : m.configuration.fallbackToDeviceDNS,
                "provider": resolver.settingsBasePreset.displayName, "transport": transportLabel(resolver.transport),
                "matchTextSize": c.textSizeMatchesSystem, "textSize": LavaTextSize.allCases.firstIndex(of: c.textSize) ?? 3,
                "haptics": c.usesLavaHaptics, "liveActivities": c.usesLiveActivities, "matchIcon": c.updatesAppIconWithLavaGuard,
                "passcode": security.isPasscodeEnabled, "biometrics": security.isBiometricEnabled,
                "protectedActions": Dictionary(uniqueKeysWithValues: Self.surfaces.map { ($0.key, security.isProtected($0.value)) })
            ],
            "draft": ["blocked": (draft?.blockedDomains ?? baseline.blockedDomains).sorted(), "allowed": (draft?.allowedDomains ?? baseline.allowedDomains).sorted()],
            "savedDraft": ["blocked": baseline.blockedDomains.sorted(), "allowed": baseline.allowedDomains.sorted()],
            "libraryEditing": ["active": libraryEditor.isEditing, "hasChanges": libraryEditor.hasChanges, "deletions": libraryEditor.stagedDeletions.sorted()],
            "filters": libraryEditor.filters.map { filter -> [String: Any] in
                let count = m.filterRuleCount(for: filter).formatted()
                let shareable = m.isFilterShareable(filter)
                let rules = "%@ rules".lavaLocalizedFormat(count)
                let shareSummary = ShareableFilterConfiguration(filter: filter).containsPrivateSourceParameters
                    ? "Use public source URLs without private parameters before sharing.".lavaLocalized
                    : ShareableFilterConfiguration(filter: filter).isEmpty ? "Nothing to share".lavaLocalized : shareable ? rules
                    : "%1$@ · %2$@".lavaLocalizedFormat(rules, "Too big to share".lavaLocalized)
                return ["id": filter.id, "name": filter.name, "emoji": filter.emoji, "frozen": m.isFilterFrozen(filter.id), "count": count,
                    "empty": filter.isEmpty, "lists": filter.enabledBlocklistIDs.sorted(),
                    "blockedDomainCount": filter.blockedDomains.count, "allowedExceptionCount": filter.allowedDomains.count,
                    "shareable": shareable, "shareSummary": shareSummary]
            },
        ]
        #if (DEBUG || LAVA_QA_TOOLS) && targetEnvironment(simulator)
        if ProcessInfo.processInfo.environment["LAVA_UI_TEST_DELAY_QUERIES"] == "1" {
            value["traceQueries"] = true
        }
        #endif
        if let created = m.filterDrafts.sessions.newFilter {
            value["newFilter"] = ["id": created.id, "name": created.name, "emoji": created.emoji,
                "frozen": false, "count": m.filterRuleCount(for: created).formatted(),
                "lists": created.enabledBlocklistIDs.sorted(), "shareable": false, "shareSummary": ""] as [String: Any]
        }
        let detail = m.filter(id: selectedID)
        let active = selectedID == m.activeFilterID
        value["filterStatus"] = ["title": (detail?.isEmpty == true ? (active ? "Blocks nothing — not protected" : "Blocks nothing") : active ? m.blocklistCatalogFreshnessTitle : "Not in effect").lavaLocalized,
            "icon": detail?.isEmpty == true ? "exclamationmark.shield.fill" : active ? m.blocklistCatalogFreshnessSystemImage : "pause.circle",
            "label": active ? "rules in effect" : "rules", "warning": detail?.isEmpty == true || active && !m.blocklistCatalogIsFresh]
        value["filterPreparationPresented"] = m.isFilterPreparationScreenPresented
        value["filterEditing"] = ["canSave": m.filterDraftHasChanges, "reviewCanConfirm": m.filterDrafts.review.canConfirm, "validation": m.filterDraftValidationMessage ?? "", "refreshing": m.catalog.isSyncInFlight,
            "lists": m.stagedBlocklistIDsForDisplay().map { id in
                ["id": id, "pending": m.isBlocklistPendingRemoval(id), "undo": m.isBlocklistPendingRemoval(id) || (m.isBlocklistNewInDraft(id) && !m.isCustomBlocklist(id))] as [String: Any]
            },
            "blocked": m.stagedBlockedDomainsForDisplay().map { ["id": $0, "pending": m.isBlockedDomainPendingRemoval($0), "undo": m.isBlockedDomainPendingRemoval($0) || m.isBlockedDomainNewInDraft($0)] as [String: Any] },
            "allowed": m.stagedAllowedDomainsForDisplay().map { ["id": $0, "pending": m.isAllowedDomainPendingRemoval($0), "undo": m.isAllowedDomainPendingRemoval($0) || m.isAllowedDomainNewInDraft($0)] as [String: Any] }
        ]
        value["logExportBusy"] = buildingLogExport || exporting
        value["logExportError"] = logExportError
        value["domainHistoryCount"] = m.reports.diagnostics.recentEvents.count
        value["hasDomainHistory"] = !m.reports.diagnostics.recentEvents.isEmpty
        value["connection"] = connectionSnapshot()
        var dnsPatchAvailable = ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.environment["LAVA_UI_TEST_DNS_PATCH"] == "1" { dnsPatchAvailable = true }
        #endif
        value["dnsPatch"] = ["available": dnsPatchAvailable,
                             "state": dnsPatchState, "busy": dnsPatchBusy,
                             "provider": dnsPatchConfigurationExists == true ? dnsChoice(DNSResolutionSelection(id: dnsPatchProvider?.id ?? DNSResolverPreset.quad9UnfilteredDoT.id)) as Any : NSNull(),
                             "choices": DNSPatchProviderCatalog.choices.map { dnsChoice(DNSResolutionSelection(id: $0.id)) }]
        value["discoveries"] = Dictionary(uniqueKeysWithValues: LavaDiscovery.allCases.map {
            ($0.rawValue, $0.isAvailable(dnsPatchAvailable: dnsPatchAvailable) && !UserDefaults.standard.bool(forKey: $0.seenKey))
        })
        value["settingsSummary"] = ["dns": m.dnsResolverSummaryText.lavaLocalized,
            "privacy": m.localLogsStatusText.lavaLocalized, "security": security.securityStatusSummary.lavaLocalized]
        value["navigation"] = navigation
        value["presentation"] = presentationSnapshot()
        value["activityDates"] = ActivityDateBridge.today()
        value["security"] = ["unavailable": security.isAuthenticationUnavailable, "showBiometrics": security.shouldShowBiometricToggle,
            "hasAuthenticationMethod": security.hasAuthenticationMethod, "updatingSurface": updatingSecuritySurface,
            "canEnableBiometrics": security.canEnableBiometrics, "biometricTitle": security.biometricToggleTitle.lavaLocalized,
            "status": security.statusMessage ?? "", "readRevision": security.viewAuthenticationRevision, "sourceRevision": "\(presentationSourceGeneration):\(presentationClearRevision)",
            "ownerRevision": presentationOwnerRevision.revision(for: m.account.accountAuthState.connections.all.map { $0.session.userID }),
            "displayClearRevision": "\(presentationDisplayClearGeneration):\(presentationClearRevision):\(presentationLibraryDisplayRevision)"]
        var confirmations: [String: Any] = [:]
        let logSettings: [(String, LocalLogSetting)] = [("Filtering Counts", .filteringCounts), ("Domain logs", .domainHistory), ("Network activity", .networkActivity), ("Lava Guard Progress", .lavaGuardProgress)]
        for (label, target) in logSettings {
            confirmations["disable." + label] = ["title": target.disableTitle, "message": target.disableMessage, "action": target.disableActionTitle]
        }
        for target in [LocalLogClearTarget.filteringCounts, .domainHistory, .networkActivity, .lavaGuardProgress, .all] {
            confirmations[target.buttonTitle] = ["title": target.clearTitle, "message": target.clearMessage, "action": target.clearActionTitle]
        }
        for target in [BackupMaintenanceAction.clear, .disable] {
            confirmations[target.buttonTitle] = ["title": target.title, "message": target.message, "action": target.actionTitle]
        }
        value["confirmations"] = confirmations
        value["limits"] = encode(m.configuration.limits)
        value["guards"] = GuardianShieldStyle.allCases.map { look in
            let availability = c.lavaGuardAvailability(for: look)
            return ["id": look.rawValue, "title": availability.title(for: look).lavaLocalized,
                // Match LavaGuardLookOptionRow: quotes belong in the spotlight;
                // an unrevealed option still needs its progress/availability hint.
                "subtitle": availability.isRevealed ? "" : (availability.subtitle(for: look)?.lavaLocalized ?? ""), "selectable": availability.isSelectable,
                "description": look.settingsDescription.lavaLocalized, "tip": look.settingsTip.lavaLocalized] as [String: Any]
        }
        value["dns"] = ["editable": m.dnsSettingsPresentation.canEditDNS, "transportDetail": "IP uses standard DNS. DNS over HTTPS (DoH), TLS (DoT), and QUIC (DoQ) encrypt allowed lookups to the resolver.".lavaLocalized, "providers": DNSResolverPreset.settingsPresets.filter { $0.id != DNSResolverPreset.device.id }.map { preset in
            ["id": preset.id, "name": preset.displayName, "address": resolverMetadata(preset.resolverVariant(for: resolver.transport)),
             "selected": resolver.settingsBasePreset.id == preset.id] as [String: Any]
        }, "custom": customDNSState(), "deviceDetail": m.deviceDNSResolverDetailText, "fallbackDetail": m.deviceDNSFallbackDetailText, "customSelected": resolver.id == DNSResolverPreset.customID,
           "transports": resolver.settingsBasePreset.availableTransports.map(transportLabel),
           "choices": DNSResolverPreset.allPresets.map { dnsChoice(DNSResolutionSelection(id: $0.id)) },
           "tiers": m.configuration.dnsResolutionSelections.map(dnsChoice),
           "tiersContext": json(encode(m.configuration.dnsResolutionSelections)),
           "customDraft": (dnsPickerCustomChoice.map(dnsChoice) as Any?) ?? NSNull(), "customDraftToken": dnsPickerCustomToken ?? ""]
        let blocklistIDs = Set(m.blocklists.map(\.id) + m.displayedCustomBlocklists.map(\.id))
            .union(baseline.enabledBlocklistIDs).union(draft?.enabledBlocklistIDs ?? [])
        value["blocklistNames"] = Dictionary(uniqueKeysWithValues: blocklistIDs.map { ($0, m.blocklistName(for: $0)) })
        value["liveActivityPauseMinutes"] = c.liveActivityPauseMinutes
        value["liveActivityPause"] = ["available": c.canOfferLiveActivities, "label": c.liveActivityPauseLengthLabel, "minutes": Array(LiveActivityPausePreference.minutesRange)] as [String: Any]
        value["blocklistMetadata"] = Dictionary(uniqueKeysWithValues: blocklistIDs.map { ($0, m.blocklistMetadataText(for: $0) ?? "Waiting for source update".lavaLocalized) })
        #if DEBUG || LAVA_QA_TOOLS
        value["qaTools"] = true
        #else
        value["qaTools"] = false
        #endif
        value["vpn"] = vpnSettingsState()
        if let game = m.sudokuGameState { value["sudoku"] = ["puzzle": encode(game.puzzle), "values": game.userValues, "notes": game.notes.map { $0.sorted() }] }
        if !canReadPresentation(.activityViewing) {
            value["domainHistoryCount"] = 0; value["hasDomainHistory"] = false
        }
        if !canReadPresentation(.appSettings) {
            if var account = value["account"] as? [String: Any] { account["detail"] = ""; account["message"] = ""; value["account"] = account }
        }
        return json(value)
    }

    /// Cheap configuration projection used inside Settings' existing authorization boundary.
    /// Resolver order comes from the runtime ladder owner. VPN preference is not health;
    /// do not open its configuration store or Keychain from this frequently published snapshot.
    private func connectionSnapshot() -> [String: Any] {
        let m = model
        let ladder = m.configuration.resolverLadderInputs
        let presentation = m.dnsSettingsPresentation
        func resolver(_ preset: DNSResolverPreset) -> [String: String] {
            ["name": preset.displayName.lavaLocalized,
             // The connection overview promotes configuration, not the editor's
             // explanatory paragraph. Device DNS has no chosen endpoint/protocol.
             "detail": preset.transport == .deviceDNS ? "" : resolverMetadata(preset),
             "transport": preset.transport == .deviceDNS ? "" : transportLabel(preset.transport)]
        }
        var result: [String: Any] = [
            "dns": ["usesWireGuard": presentation.usesWireGuard, "editable": presentation.canEditDNS,
                    "primary": resolver(ladder.resolver),
                    "fallback": ladder.isConfiguredFallbackEnabled ? resolver(ladder.configuredFallbackResolver) as Any : NSNull()]
        ]
        if let filter = m.filter(id: m.activeFilterID) {
            result["filter"] = ["id": filter.id, "name": filter.name, "count": m.filterRuleCount(for: filter).formatted()]
        }
        result["vpn"] = ["eligible": true, "enabled": m.configuration.chainedUpstreamEnabled,
            "fallbackEnabled": presentation.fallbackEnabled.map { $0 as Any } ?? NSNull()]
        let storedGeneration = m.dnsSettingsProfileStatus?.storedConfigurationGeneration
        result["configurationPending"] = m.tunnelHealth.isChainedUpstreamActive && storedGeneration != nil
            && storedGeneration != m.tunnelHealth.runningChainedUpstreamGeneration
        return result
    }

    func guardMood() -> String { model.guardStatusPresentation.mascotState.rawValue }

    func requestNavigation(tab: String, screen: String) {
        let targetsGuard = tab == "GuardTab" && screen == "Guard"
        guard targetsGuard || !LavaOnboardingHandoff.shared.keepsGuardVisible else { return }
        #if !DEBUG && !LAVA_QA_TOOLS
        guard screen != "phoneQA" else { return }
        #endif
        navigationSerial += 1
        let serial = navigationSerial
        Task { @MainActor in
            do {
                // Explore uses the same app-settings gate as its in-app entry points,
                // and its prompt names the destination the link actually opens.
                if tab == "SettingsTab" || screen == "Explore" { try await authorize(.appSettings, screen == "Explore" ? "Explore" : "Open Settings", fresh: false) }
                if screen == "Security", !(await security.requireCredentialAuthentication(reason: "Open Security settings")) { return }
                if ["Activity", "Stats", "Network"].contains(screen) { try await authorize(.activityViewing, "View Activities", fresh: false) }
                guard serial == navigationSerial,
                      targetsGuard || !LavaOnboardingHandoff.shared.keepsGuardVisible else { return }
                navigation = ["serial": serial, "tab": tab, "screen": screen == "phoneQA" ? "DeviceQA" : screen == "vpnChaining" ? "VPNChaining" : screen]
                publish()
            } catch { /* Native authentication already presents cancellation/failure. */ }
        }
    }

    static let surfaces: [String: SecurityProtectedSurface] = ["App Unlock": .appUnlock, "Turn on/off Lava": .protectionControl,
        "Pause Lava": .protectionPause, "Update domains and lists": .filterEditing, "View Activities": .activityViewing, "Update App Settings": .appSettings]
    func transportLabel(_ transport: DNSResolverTransport) -> String {
        switch transport { case .deviceDNS: "IP"; case .plainDNS: "IP"; case .dnsOverHTTPS: "DoH"; case .dnsOverTLS: "DoT"; case .dnsOverQUIC: "DoQ" }
    }
    func json(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), let string = String(data: data, encoding: .utf8) else { return "{}" }
        return string
    }
    func encode<T: Encodable>(_ value: T) -> Any {
        guard let data = try? JSONEncoder().encode(value), let result = try? JSONSerialization.jsonObject(with: data) else { return NSNull() }
        return result
    }
    struct AuthorizedPresentationResult {
        let value: Any
        let validate: () throws -> Void
    }
    struct CommandError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) {
            // JS uses these two stable signals to retire an action without an alert.
            // Localize display errors only; translating a signal would change control flow.
            errorDescription = ["Authentication cancelled.", "Read access changed."].contains(message)
                ? message : message.lavaLocalized
        }
    }
    func authorize(_ surface: SecurityProtectedSurface, _ reason: String, fresh: Bool = false) async throws {
        let granted = fresh ? await security.requireFreshAuthentication(for: surface, reason: reason) : await security.requireAuthentication(for: surface, reason: reason)
        guard granted else { throw CommandError("Authentication cancelled.") }
    }
    @objc func command(_ request: String, completion: @escaping (String?, String?) -> Void) {
        Task { @MainActor in
            do {
                guard request.utf8.count <= 1_048_576, let data = request.data(using: .utf8),
                      let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let name = payload["type"] as? String else { throw CommandError("Invalid app command.") }
                // Layout acknowledgement only: never publish, invalidate reads, or touch configuration.
                if name == "onboarding.geometry" {
                    let accepted = LavaOnboardingHandoff.shared.receive(payload)
                    completion(json(["result": accepted]), nil)
                    return
                }
                var result = try await perform(name, payload)
                // Revalidate at the final synchronous bridge delivery, including
                // suspension between the query owner and this command callback.
                if let privateRead = result as? AuthorizedPresentationResult {
                    try privateRead.validate()
                    result = privateRead.value
                }
                // Haptics are an effect-only acknowledgement. Publishing and
                // serializing the whole configuration on every scrub crossing
                // adds work to both the native main thread and the React tree.
                // Real model observations keep their independent publish path.
                if name == "haptic" {
                    completion(json(["result": result]), nil)
                    return
                }
                publish()
                completion(json(["snapshot": try JSONSerialization.jsonObject(with: Data(snapshot().utf8)), "result": result]), nil)
            } catch { completion(nil, error.localizedDescription) }
        }
    }
    func perform(_ name: String, _ input: [String: Any]) async throws -> Any {
        if name == "domains.cancel" {
            if let token = input["token"] as? String { cancelStandaloneDomainReview(token) }
            return NSNull()
        }
        // Mutation starts retire existing entries and pending result tickets.
        // Independent system/model changes are also checked in the native scope.
        if !name.hasSuffix(".query") && !name.hasPrefix("navigation.") && !["haptic", "guard.gesture", "activity.visibility", "refresh"].contains(name) {
            presentationSourceGeneration &+= 1
            presentationCache.invalidate()
        }
        if name.hasSuffix(".query") || name == "domains.stage" { return try await query(name, input) }
        if name.hasPrefix("library.") { return try await libraryCommand(name, input) }
        if name.hasPrefix("filter.") { return try await filterCommand(name, input) }
        if name.hasPrefix("vpn.") { return try await vpnCommand(name, input) }
        switch name {
        case "discovery.seen":
            guard let raw = input["target"] as? String, let target = LavaDiscovery(rawValue: raw) else { throw CommandError("Unknown discovery target.") }
            // Device-local presentation only; never creates or enables DNS settings.
            UserDefaults.standard.set(true, forKey: target.seenKey)
        case "native.flow":
            guard let name = input["flow"] as? String,
                  ["account", "backupSetup", "backupRestore", "passcode", "automation", "import", "importCode", "importScan", "licenses", "feedback", "customDNS", "phoneQA"].contains(name) else { throw CommandError("Unknown native flow.") }
            #if !DEBUG && !LAVA_QA_TOOLS
            guard name != "phoneQA" else { throw CommandError("Unknown native flow.") }
            #endif
            let surface: SecurityProtectedSurface? = switch name {
            case "account", "backupSetup", "backupRestore", "customDNS", "phoneQA": .appSettings
            default: nil // Import reading, automation help, feedback and notices are read-only native routes.
            }
            if let surface { try await authorize(surface, "Open Lava settings") }
            if name == "passcode", security.isPasscodeEnabled {
                guard await security.requirePasscodeAuthentication(reason: "Turn off Security passcode") else { throw CommandError("Authentication cancelled.") }
                security.disablePasscode()
                guard !security.isPasscodeEnabled else { throw CommandError(security.statusMessage ?? "Passcode could not be removed.") }
            } else { flow = LavaAppNativeFlow(name: name) }
        case "activity.visibility": try await setActivityVisibility(input)
        case "domains.enableHistory":
            // Domain History owns this opt-in under Activity's viewing turn;
            // enabling it is not a Privacy settings mutation requiring app-settings auth.
            try await authorize(.activityViewing, "View Activities", fresh: false)
            model.reports.setKeepDomainDiagnostics(true)
        case "domains.copy":
            try await authorize(.activityViewing, "View Activities", fresh: false)
            guard let domain = input["domain"] as? String else { throw CommandError("Missing domain.") }
            UIPasteboard.general.string = domain
            ProtectionHapticFeedback.play(.selectionConfirmed)
        case "settings.set": try await setSetting(input)
        case "dns.toggle": return try await toggleDNSTier(input)
        case "dns.tiers": return try await saveDNSTiers(input)
        case "customEntry.dismiss":
            if input["id"] as? String == pushedCustomEntry?.id.uuidString { pushedCustomEntry = nil }
            return NSNull()
        case "dns.customDraft": return try await editCustomDNSDraft(input)
        case "dns.custom": return try await saveCustomDNS(input)
        case "logs.export":
            guard !buildingLogExport && !exporting else { throw CommandError("A local-log export is already in progress.") }
            buildingLogExport = true
            logExportError = ""
            publish()
            defer { buildingLogExport = false; publish() }
            try await authorize(.appSettings, "Export local logs")
            let authorizationRevision = security.viewAuthenticationRevision
            let archive = try await model.makeLocalLogExportArchive(includeDomainHistory: false)
            guard canReadPresentation(.appSettings), security.viewAuthenticationRevision == authorizationRevision else {
                throw CommandError("Read access changed.")
            }
            exportDocument = LocalLogExportDocument(data: archive.data)
            exportFilename = archive.filename
            exporting = true
        case "share.present":
            guard let id = input["id"] as? String, let filter = model.filter(id: id), model.isFilterShareable(filter) else { throw CommandError("This filter cannot be shared.") }
            guard flow == nil else { throw CommandError("Another screen is already open.") }
            flow = LavaAppNativeFlow(name: "share", filterID: id)
        case "share.card":
            try await authorize(.appUnlock, "Share filter")
            guard canReadPresentation(.appUnlock) else { throw CommandError("Read access changed.") }
            try shareMountedCard(input)
        case "share.copy":
            try await authorize(.appUnlock, "Share filter")
            guard canReadPresentation(.appUnlock) else { throw CommandError("Read access changed.") }
            guard let id = input["id"] as? String, let filter = model.filter(id: id), model.isFilterShareable(filter) else { throw CommandError("This filter cannot be shared.") }
            UIPasteboard.general.string = model.shareableFilterCode(for: filter)
            LavaFeedbackCoordinator.shared.interaction(.acknowledged, control: "share.copy")
        case "logs.clear": return try await clearLogs(input["kind"] as? String ?? "", fromActivity: input["surface"] as? String == "activityViewing")
        case "sudoku.new":
            let puzzle = await Task.detached(priority: .userInitiated) { SudokuPuzzle.generate(seed: UInt64.random(in: UInt64.min...UInt64.max)) }.value
            let state = SudokuGameState(puzzle: puzzle)
            model.persistSudokuGameState(state)
            return ["puzzle": encode(state.puzzle), "values": state.userValues, "notes": state.notes.map { $0.sorted() }]
        case "guard.gesture": try guardGesture(input["gesture"] as? String ?? "")
        case "haptic":
            if let raw = input["kind"] as? String, let semantic = LavaFeedbackSemantic(rawValue: raw),
               let control = input["controlID"] as? String {
                LavaFeedbackCoordinator.shared.interaction(semantic, control: control, value: input["value"] as? String)
                break
            }
            let kinds: [String: ProtectionHapticFeedback] = ["selection": .selectionConfirmed, "changed": .selectionChanged, "inspectionEmpty": .inspectionEmpty, "rejected": .selectionRejected, "success": .actionSucceeded]
            guard let kind = kinds[input["kind"] as? String ?? ""] else { throw CommandError("Invalid haptic.") }
            ProtectionHapticFeedback.play(kind)
        case "sudoku.save":
            guard let game = input["game"] as? [String: Any] else { throw CommandError("Invalid Sudoku game.") }
            let payload: [String: Any] = ["puzzle": game["puzzle"] ?? NSNull(), "userValues": game["values"] ?? NSNull(), "notes": game["notes"] ?? NSNull()]
            let state = try JSONDecoder().decode(SudokuGameState.self, from: JSONSerialization.data(withJSONObject: payload))
            model.persistSudokuGameState(state)
        case "account.apple", "account.google":
            try await authorize(.appSettings, "Edit Account settings")
            if name == "account.apple" { await model.account.beginSignInWithApple().value } else { await model.account.beginSignInWithGoogle().value }
        case "account.signOut":
            try await authorize(.appSettings, "Sign Out")
            model.account.signOutAccount()
        case "account.delete":
            try await authorize(.appSettings, "Delete account")
            guard await model.account.deleteAccount() else { throw CommandError(model.account.accountAuthMessage ?? "Account deletion did not complete.") }
        case "backup.refresh": await model.backup.refreshRemoteBackupStatus()
        case "backup.now": try await authorize(.appSettings, "Back up settings"); await model.backup.backUpNow()
        case "backup.disable": try await authorize(.appSettings, BackupMaintenanceAction.disable.authReason); await model.backup.disableEncryptedBackup()
        case "backup.delete": try await authorize(.appSettings, BackupMaintenanceAction.clear.authReason); await model.backup.clearEncryptedBackup()
        case "purchase.buy":
            try await authorize(.appSettings, "Upgrade to Lava Security Plus")
            guard let offer = UpgradeSettingsView.displayedOffers(for: model.plus).first(where: { $0.id == input["id"] as? String }) else { throw CommandError("This purchase is unavailable. Refresh the available plans.") }
            await model.plus.purchaseLavaSecurityPlus(offer)
        case "purchase.restore":
            try await authorize(.appSettings, "Restore Lava Security Plus")
            await model.plus.restoreLavaSecurityPlusPurchases()
        case "purchase.manage":
            try await authorize(.appSettings, "Manage Lava Security Plus")
            await UpgradeSettingsView.presentManageSubscriptions(plus: model.plus)
        case "purchase.refresh":
            model.plus.clearLavaSecurityPlusMessage()
            if !model.plus.hasCheckedLavaSecurityPlusEntitlements { await model.plus.refreshLavaSecurityPlusEntitlements() }
            if !model.configuration.hasLavaSecurityPlus, model.plus.lavaSecurityPlusOffers.isEmpty { await model.plus.loadLavaSecurityPlusProducts() }
        case "purchase.clearMessage": model.plus.clearLavaSecurityPlusMessage()
        case "reports.sample": await model.sampleReports()
        case "refresh":
            model.reports.refreshDiagnostics()
            await model.refreshProtectionStatus(force: true)
            await model.sampleTunnelHealth(force: true)
        case "protection.toggle":
            let primaryAction = model.guardStatusPresentation.primaryAction
            let capturedIntentRevision = model.userProtectionIntent.revision
            let reconnectIntent = primaryAction == .reconnect
                ? model.userProtectionIntent.makeRestoreRequest() : nil
            if primaryAction == .resume { model.resumeProtectionNow() }
            else {
                try await authorize(.protectionControl, "Change Lava protection", fresh: true)
                guard model.userProtectionIntent.revision == capturedIntentRevision else { break }
                if let reconnectIntent, !model.userProtectionIntent.allowsExplicitReconnect(reconnectIntent) { break }
                model.performProtectionPrimaryAction(primaryAction)
            }
        case "protection.pause":
            try await authorize(.protectionPause, "Pause Lava protection", fresh: true)
            let minutes = input["minutes"] as? Int ?? 5
            guard let duration = ProtectionPauseDuration.allCases.first(where: { Int($0.duration / 60) == minutes }) else { throw CommandError("Invalid pause duration.") }
            model.pauseProtectionTemporarily(for: duration)
        case "navigation.authorize":
            if input["newTurn"] as? Bool == true { security.resetViewAuthenticationTurn() }
            if input["surface"] as? String == "credentials" {
                guard await security.requireCredentialAuthentication(reason: "Open Security settings") else { throw CommandError("Authentication cancelled.") }
                return NSNull()
            }
            guard let surface = SecurityProtectedSurface(rawValue: input["surface"] as? String ?? "") else { throw CommandError("Invalid screen.") }
            try await authorize(surface, "Open Lava screen", fresh: false)
            if surface == .appSettings { model.refreshDNSSettingsPresentation() }
        case "navigation.endTurn": security.resetViewAuthenticationTurn()
        default: throw CommandError("Unknown app command: %@".lavaLocalizedFormat(name))
        }
        return NSNull()
    }
}

// Register discoveries here so arbitrary bridge input cannot write preferences.
// Keep IDs stable across releases; each surface is acknowledged independently.
private enum LavaDiscovery: String, CaseIterable {
    case ios27PatchSettings = "ios27Patch.settings"
    case ios27PatchPage = "ios27Patch.page"
    var seenKey: String { "LavaDiscovery.\(rawValue).seen" }
    func isAvailable(dnsPatchAvailable: Bool) -> Bool {
        switch self {
        case .ios27PatchSettings, .ios27PatchPage: dnsPatchAvailable
        }
    }
}
