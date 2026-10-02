import Darwin
import Foundation
import SwiftUI
import UIKit
@preconcurrency import CoreHaptics
@preconcurrency import NetworkExtension
@preconcurrency import UserNotifications
import LavaSecKit
import LavaSecFilterPipeline
import LavaSecAppServices
#if DEBUG || LAVA_QA_TOOLS
@preconcurrency import WebKit
#endif

// One concern of `AppViewModel`, split out of the former single-file view model.
// Stored state (`@Published` and otherwise) lives in LavaSecApp/AppViewModel.swift (extensions
// cannot declare stored properties); every file under AppViewModel/ is one `// MARK:` section.

extension AppViewModel {
    // MARK: - QA / admin tooling

    // PRODUCTION behaviour, deliberately OUTSIDE the QA block below.
    //
    // It lived inside it — next to `resetChainedSuppressionsForQA`, which IS a QA affordance —
    // while its only caller sits ungated in `enableProtection`. Debug and QA both define a
    // compilation condition the block tests, so both compiled; plain Release defines neither,
    // dropped the declaration, kept the call, and failed to build. That is the App Store
    // configuration (PR #579).

    /// Makes a USER-initiated Guard start a clean recovery boundary. Automatic restores and
    /// Connect-On-Demand starts do not call this: only the explicit on action clears a surrender,
    /// and a pre-forwarding crash-loop trip. Tunnel lifecycle evidence is preserved for the
    /// current or replacement provider to own.
    /// pinned: ChainedUpstreamStagingWiringSourceTests.testAUserTurnOnResetsChainedSuppressionsWithoutErasingTunnelEvidence
    func prepareChainedStateForExplicitGuardStart() throws {
        // Advance the provider's cross-process terminal-marker revision before this new explicit
        // attempt. A retired provider that is still unwinding a surrender can therefore not
        // recreate its old marker after this clear. The eligibility-store reset below remains
        // the authority for the chained suppression itself.
        //
        // This THROWS rather than logging on: the provider hard-gates `startTunnel` on the same
        // marker, so a start attempted after a failed advance is refused with certainty, and the
        // user's one advertised recovery action ("turn Guard on to retry") would fail silently
        // for a transient lock hiccup. Surfacing it lets them retry a second later and actually
        // succeed. The Keychain reset below stays best-effort by contrast — the provider redoes
        // it from the marker's explicit-retry handoff bit.
        guard let markerURL = LavaSecAppGroup.chainedStartupFailureMarkerURL else {
            logVPNDebugEvent("chained-explicit-start-marker-url-missing")
            throw ChainedExplicitRetryPreparationFailure.markerUnavailable
        }
        do {
            _ = try ChainedStartupFailureMarker.beginExplicitRetry(
                storageURL: markerURL,
                lockURL: LavaSecAppGroup.chainedStartupFailureMarkerLockURL)
        } catch {
            logVPNDebugEvent(
                "chained-explicit-start-marker-advance-failed",
                details: errorIdentityDetails(error))
            throw ChainedExplicitRetryPreparationFailure.markerAdvanceFailed
        }
        guard let group = LavaSecAppGroup.chainedUpstreamKeychainAccessGroup,
            let lockURL = LavaSecAppGroup.chainedLifecycleEvidenceLockURL
        else { return }
        let store = ChainedDeviceEligibilityStore(
            items: ChainedDeviceStateKeychainItemStore(
                accessGroup: group, lifecycleEvidenceLockURL: lockURL))
        do {
            try store.prepareForExplicitGuardStart()
        } catch {
            logVPNDebugEvent("chained-explicit-start-prepare-failed", details: ["error": "\(error)"])
        }
    }

    #if DEBUG || LAVA_QA_TOOLS
    func applyHostedQAProbeSet() {
        configuration.qaProbeSet = .hosted
        vpnMessage = "Hosted QA probes are active."
        vpnMessageIsError = false
        persistFilterChanges()
    }

    func applyCustomQAProbeSet() {
        do {
            configuration.qaProbeSet = try QADomainProbeSet(suffix: qaProbeSuffixDraft)
            vpnMessage = "Custom QA probes are active."
            vpnMessageIsError = false
            persistFilterChanges()
        } catch {
            vpnMessage = "Could not apply QA probes: \(error.localizedDescription)"
            vpnMessageIsError = true
        }
    }

    func clearQAProbeSet() {
        configuration.qaProbeSet = nil
        vpnMessage = "QA probes cleared."
        vpnMessageIsError = false
        persistFilterChanges()
    }

    func setQAPlanMode(isPaid: Bool) {
        configuration.isPaid = isPaid
        adminQAStatusMessage = isPaid ? "Paid state is active." : "Free state is active."
        vpnMessageIsError = false
        persistFilterChanges()
    }

    /// QA-gated "put the filter selection back to the shipped default", and — just as
    /// importantly — RECORD what it was.
    ///
    /// The wedge this exists for, measured on chimmy across a 5-hour log: ONE enabled source
    /// that can never be fetched (an upstream that started 404ing, or a list that outgrew the
    /// 45 MB per-source cap in `BlocklistParseResourceBudget.default`) makes the whole
    /// snapshot prepare throw. The artifact is therefore never rewritten, so the stored
    /// artifact's summary never gains that source's key, so `coversEnabledBlocklists` stays
    /// false forever — and the tunnel serves fail-closed block-all with no path back. The
    /// device recorded 183 `loadSnapshot-cache-compile-error` rows and never once adopted an
    /// artifact.
    ///
    /// The logging half is not decoration. `launch-snapshot-reconcile-failed` carries an error
    /// domain and code and deliberately nothing else (see `errorIdentityDetails`), so on a
    /// wedged device there is no way to learn WHICH source is the one that cannot load —
    /// diagnosing it the first time meant measuring all 34 catalog URLs from a laptop. Catalog
    /// source IDs are our own published identifiers, so recording them costs no privacy;
    /// custom sources are reduced to a COUNT, because their identifiers belong to the user.
    func resetFiltersToRecommendedDefaultsForQA() {
        // Before first unlock the persisted pair can be unreadable, so `configuration` in memory
        // is a placeholder, not the user's real state (INV-PERSIST-1 sets
        // `sharedStateUnavailableAtLoad`). Resetting the placeholder would be wrong AND futile —
        // protected-data recovery reloads the real config at unlock and overwrites it. Skip
        // rather than pretend, and tell the operator to relaunch unlocked. (Codex, #531.)
        guard !sharedStateUnavailableAtLoad else {
            logVPNDebugEvent("qa-filters-reset-deferred", details: [
                "reason": "shared state unreadable at load (launched before first unlock)",
            ])
            adminQAStatusMessage = "Filter reset skipped: unlock the device and relaunch."
            return
        }

        // Record what was there BEFORE the reset, with custom-list IDs redacted. An enabled ID
        // that belongs to a custom source is the user's identifier, so keep only the catalog
        // IDs (our own published ones) and reduce customs to a count — matching this method's
        // doc, which the previous body contradicted by logging the raw `enabledBlocklistIDs`.
        // (Codex, #531.)
        let customIDs = Set(configuration.customBlocklists.map(\.id))
        let previousCatalogEnabled = configuration.enabledBlocklistIDs
            .filter { !customIDs.contains($0) }.sorted().joined(separator: ",")
        // Only ENABLED customs can cause the wedge this diagnoses — a saved-but-disabled custom
        // list is not in the selection. Count enabled customs (id present in
        // `enabledBlocklistIDs`), matching `enabledCustomBlocklistCount` elsewhere, not the full
        // saved count. (Codex, #531.)
        let previousEnabledCustomCount = configuration.customBlocklists
            .filter { configuration.enabledBlocklistIDs.contains($0.id) }.count

        // Reset the blocklist SELECTION only — which is exactly what un-wedges the device (an
        // enabled source that can't be fetched) — via the shared `selectOnboardingBlocklists`.
        // That sets the selection to the shipped catalog defaults, REBUILDS the block rules,
        // persists, and fetches any default not yet cached, while LEAVING the user's saved
        // filters and manual allow/block domains untouched. Setting the selection to the
        // catalog defaults drops any wedged CUSTOM source from the active set (its saved
        // definition is preserved, just disabled), which also clears a custom-caused wedge.
        //
        // Not `restoreFiltersToDefault()`: that reseeds the WHOLE library and clears the active
        // filter's manual domains — more than this argument's job, and more than its name says.
        // (Codex, #531.)
        selectOnboardingBlocklists(DefaultCatalog.recommendedDefaultSourceIDs)

        // The selection is reset in memory synchronously above; the durable write runs in the
        // unawaited Task `selectOnboardingBlocklists` -> `persistFilterChanges()` starts, so this
        // records the reset as APPLIED-AND-PERSISTING, not confirmed on disk. The diagnostic
        // value (what was enabled BEFORE) is captured accurately either way, and a persist
        // failure surfaces through that Task's own `vpnMessage` error path. (Codex, #531.)
        logVPNDebugEvent("qa-filters-reset-applied", details: [
            "previousCatalogEnabled": previousCatalogEnabled,
            "previousEnabledCustomCount": "\(previousEnabledCustomCount)",
            "persistence": "async",
        ])
        adminQAStatusMessage = "Blocklist selection reset to defaults; persisting."
    }

    /// QA-only repair hook retained for automated fixtures. Product recovery is the ordinary
    /// explicit Guard start, which uses `prepareForExplicitGuardStart`; no reset control is shown.
    func resetChainedSuppressionsForQA() {
        guard let group = LavaSecAppGroup.chainedUpstreamKeychainAccessGroup,
            let lockURL = LavaSecAppGroup.chainedLifecycleEvidenceLockURL
        else {
            adminQAStatusMessage = "Chained reset unavailable: no shared state access."
            return
        }
        let store = ChainedDeviceEligibilityStore(
            items: ChainedDeviceStateKeychainItemStore(
                accessGroup: group, lifecycleEvidenceLockURL: lockURL))
        do {
            try store.userResetChainedSuppressions()
            adminQAStatusMessage = "Chained test state cleared."
        } catch {
            adminQAStatusMessage = "Chained reset failed: \(error)"
        }
    }


    /// Everything the VPN-chaining settings surface needs to say WHY the data path is what
    /// it is, rather than only what the user asked for.
    ///
    /// This exists because the preference and the outcome are three separable things —
    /// the toggle, the stored upstream, and device eligibility — and a surface showing only
    /// the toggle is actively misleading. Two live examples from S9 device work: staging
    /// sets `chainedUpstreamEnabled = true` itself, yet
    /// `reconcileChainedUpstreamAfterEligibilityChange` can turn it straight back off with
    /// no visible trace; and the tunnel latched `dns-only / chaining-disabled` while an
    /// upstream sat correctly stored, which from the old QA sheet was indistinguishable
    /// from a staging failure.
    struct ChainedUpstreamSurfaceStatus {
        /// The user's stored PREFERENCE. Not the outcome — the tunnel latches separately.
        var chainingEnabled: Bool
        /// Non-nil when the device cannot chain regardless of the toggle.
        var ineligibility: ChainedAvailability.Ineligibility?
        /// Key-free description of the stored upstream, or nil when nothing is stored.
        var storedConfigurationSummary: String?
        /// Metadata for the saved row and local DNS settings table, never key material.
        var storedConfigurationSavedAt: Date?
        var storedConfigurationDNSAddresses: [String]?
        var storedConfigurationIsSplitTunnel: Bool?
        /// `resolverSelectionFingerprint` of the CURRENTLY STORED upstream, or nil when nothing is
        /// stored or the store could not be read.
        ///
        /// Compared against the fingerprint the live session published, so replacing the
        /// configuration mid-session is recognised as a pending change even when the chosen
        /// fallback addresses are untouched. Nil means UNKNOWN, never "unchanged" — a locked
        /// Keychain must not be rendered as agreement (Codex, PR #575).
        var storedConfigurationSelectionFingerprint: String?
        /// The GENERATION of the currently stored upstream, or nil when nothing is stored or the
        /// store could not be read.
        ///
        /// The other half of "is the live session running what is stored". The fingerprint above
        /// answers whether the SELECTION changed; this answers whether the ROTATION did — the
        /// case where the user replaces the endpoint and keys and every existing surface reports
        /// agreement, because `resolverSelectionFingerprint` is unmoved by design.
        ///
        /// Nil means UNKNOWN, never "unchanged", on the same rule as the fingerprint beside it:
        /// a locked Keychain is not agreement.
        var storedConfigurationGeneration: UInt64?
        var storedConfigurationRows: [ChainedUpstreamConfiguration] = []
        /// True when a configuration is stored but its private key is not — the migration
        /// shape a cross-device restore produces, which reads as `noPrivateKeyStored`.
        var hasConfigurationWithoutKey: Bool
        /// Why the store could not be consulted at all. Distinct from "nothing stored":
        /// an unreadable store must never be rendered as an empty one.
        var storeUnavailableReason: String?
        /// Why the DEVICE-LOCAL eligibility state could not be read — a separate store, and
        /// a separate failure, from `storeUnavailableReason`.
        ///
        /// 🔴 Two reasons this is its own field rather than being folded into the one above.
        ///
        /// It means something different. `storeUnavailableReason` is rendered to the user as
        /// "your saved configuration couldn't be read — load the file again", which is the
        /// wrong instruction and the wrong culprit when what failed is the eligibility item.
        /// `ChainedDeviceEligibilityStore` returns `.unavailable("override-malformed")` for a
        /// corrupt one-byte item — a DURABLE condition — and on such a device the
        /// configuration file and its key both read perfectly, so the page would have told
        /// the user to re-import a file that is fine, forever.
        ///
        /// And eligibility being UNKNOWN is not the same as being INELIGIBLE. When this is
        /// set, `ineligibility` is left nil because nothing was learned — so every consumer
        /// has to consult this FIRST, exactly as `TunnelDataPathLatch.resolve` evaluates its
        /// `deviceLocalStateIsUnavailable` term before it evaluates eligibility at all.
        var deviceEligibilityUnavailableReason: String?
        /// Chained mode surrendered and the user has not reset it (C4).
        ///
        /// Modelled separately from `ineligibility` because the LATCH treats it separately:
        /// `TunnelDataPathLatch.resolve` takes `isSurrenderSuppressed` as its own term, after
        /// eligibility. A surrendered device is ELIGIBLE and still starts DNS-only, so
        /// folding this into `ineligibility` would misreport the reason and the remedy —
        /// surrender is cleared by the user's Reset, not by buying Plus or changing devices.
        var isSurrenderSuppressed: Bool
    }

    /// Reads the live chained state. Deliberately re-reads the store on each call rather
    /// than caching: the tunnel, the QA surface and a restore can all change it underneath
    /// the app, and a stale "configured" badge is the failure this surface exists to end.
    var chainedUpstreamSurfaceStatus: ChainedUpstreamSurfaceStatus {
        var status = ChainedUpstreamSurfaceStatus(
            chainingEnabled: configuration.chainedUpstreamEnabled,
            ineligibility: nil,
            storedConfigurationSummary: nil,
            storedConfigurationSelectionFingerprint: nil,
            storedConfigurationGeneration: nil,
            hasConfigurationWithoutKey: false,
            storeUnavailableReason: nil,
            deviceEligibilityUnavailableReason: nil,
            isSurrenderSuppressed: false)

        guard let containerURL = LavaSecAppGroup.containerURL,
            let group = LavaSecAppGroup.chainedUpstreamKeychainAccessGroup,
            let lifecycleEvidenceLockURL = LavaSecAppGroup.chainedLifecycleEvidenceLockURL
        else {
            status.storeUnavailableReason = "No app group or keychain access group."
            // Same rule as the `.unavailable` branch below: with no keychain group there is
            // no device-local state to read, so eligibility is UNKNOWN rather than clear.
            status.deviceEligibilityUnavailableReason = "no-keychain-group"
            return status
        }

        // The DEVICE-LOCAL terms, read rather than assumed. Passing literal `false` for the
        // override and the exclusion — as this did — makes the page disagree with the latch
        // in both directions, and the two disagreements have opposite signs:
        //
        //   override ON  -> page says "not enough memory" and greys the toggle, on a device
        //                   that chains perfectly well.
        //   excluded     -> page says Eligible and offers a live toggle, on a device whose
        //                   next start is DNS-only. This is the one that cost a build cycle
        //                   on chimmy: the settings page read healthy while the latch was
        //                   refusing with `device-startup-crash-loop`.
        //
        // 🔴 An UNREADABLE store is not "false, false". A Keychain read is transiently
        // unanswerable before first unlock, and guessing there would either grey out a
        // healthy device or promise a suspended one. It reports unavailability instead —
        // the same distinction `TunnelDataPathLatch`'s `deviceStateUnavailable` refusal
        // draws, and the reason `ReadOutcome` has no partial case.
        //
        // NOTE the deliberate asymmetry with `reconcileChainedUpstreamAfterEligibilityChange`,
        // which passes literal `false` ON PURPOSE (see its comment): that path CLEARS the
        // user's stored preference, so it must never act on a suspension. This path only
        // DESCRIBES, so it must never hide one.
        let eligibilityStore = ChainedDeviceEligibilityStore(
            items: ChainedDeviceStateKeychainItemStore(
                accessGroup: group,
                lifecycleEvidenceLockURL: lifecycleEvidenceLockURL))
        switch eligibilityStore.read() {
        case .snapshot(let snapshot):
            status.ineligibility = ChainedAvailability.ineligibilityReason(
                hasLavaSecurityPlus: configuration.hasLavaSecurityPlus,
                physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
                experimentalOverrideEnabled: snapshot.experimentalOverrideEnabled,
                hasStartupCrashLoopTripped: snapshot.backoffState.hasTripped)
            status.isSurrenderSuppressed = snapshot.isSurrenderSuppressed
        case .unavailable(let reason):
            // 🔴 NO GUESS HERE, and an earlier draft of this very change got it wrong: it
            // called `ineligibilityReason` with `false, false` two paragraphs after the
            // comment forbidding exactly that, which left `ineligibility` nil on an
            // unreadable store — and every consumer reads a nil `ineligibility` as ELIGIBLE,
            // so the toggle stayed live and the page reproduced both failure directions the
            // comment above enumerates.
            //
            // `ineligibility` stays nil because NOTHING WAS LEARNED, and the unknown is
            // reported in its own field that consumers check first.
            status.deviceEligibilityUnavailableReason = reason
        }
        // The SAME both-halves check staging and clearing make. A build whose identity and
        // keychain group disagree would otherwise read the WRONG store and report another
        // identity's configuration as this one's.
        let identity = LavaSecAppGroup.chainedUpstreamStoreIdentity
        guard ChainedUpstreamStoreIdentity.identity(forKeychainGroup: group) == identity else {
            status.storeUnavailableReason =
                "The build's identity and keychain group disagree."
            return status
        }

        let store = ChainedUpstreamKeychainStore(
            containerURL: containerURL,
            identity: identity,
            keyItems: ChainedUpstreamKeychainKeyItemStore(accessGroup: group))
        do {
            guard let record = try store.loadStoredConfigurationRecord() else {
                return status
            }
            let stored = record.configuration
            let storedGeneration = record.generation
            status.storedConfigurationSavedAt = record.savedAt
            status.storedConfigurationRows = stored.orderedHops
            let active = try stored.activeConfiguration
            status.storedConfigurationDNSAddresses = active?.stackDNSAddresses ?? []
            status.storedConfigurationIsSplitTunnel = active.map { !$0.containsFullTunnel } ?? true
            // Already returned by the store, and discarded here until now. A non-secret opaque
            // identifier — compared for equality, never ordered — so unlike the summary and the
            // fingerprint below it needs no redaction argument.
            status.storedConfigurationGeneration = storedGeneration
            // `redactedSummary` — never the raw configuration. The private key is not in
            // this type at all, but the endpoint and client address still describe the
            // user's upstream, and this string can end up in a screenshot.
            status.storedConfigurationSummary = stored.redactedSummary
            // Freshness compares only a fingerprint. The separate DNS-address projection
            // above is for the local Nerd Stats settings table; it is never health telemetry
            // or a key-bearing configuration preview.
            status.storedConfigurationSelectionFingerprint = active?.resolverSelectionFingerprint
            let material = try store.loadStoredKeyMaterial()
            status.hasConfigurationWithoutKey = material == nil
            if let material {
                guard material.generation == storedGeneration else {
                    status.storeUnavailableReason = "Configuration changed while reading. Try again."
                    return status
                }
                // Use the same key validation as a save, without exposing any secret to UI.
                _ = try ChainedUpstreamRotation(configuration: try stored.withoutEntryHop(), privateKey: material.privateKey,
                                               presharedKey: material.presharedKey)
                if let entry = stored.precedingHops.first {
                    guard let keys = try store.loadStoredEntryKeyMaterial(), keys.generation == storedGeneration else {
                        status.hasConfigurationWithoutKey = true
                        return status
                    }
                    _ = try ChainedUpstreamRotation(configuration: entry, privateKey: keys.privateKey, presharedKey: keys.presharedKey)
                }
            }
        } catch {
            // Do not clobber an eligibility-store reason already recorded above. When the
            // Keychain is locked BOTH reads fail, and the first one is the more actionable
            // of the two — it is the term the latch refuses on.
            if status.storeUnavailableReason == nil {
                status.storeUnavailableReason = error.localizedDescription
            }
        }
        return status
    }

    /// The chained state behind a surface that has ALREADY read the status.
    ///
    /// A caller holding a snapshot must use this rather than the computed property below: each
    /// `chainedUpstreamSurfaceStatus` read opens the configuration store and hits the Keychain on
    /// the main actor, and can wait up to 250 ms for the lifecycle lock. A second read during the
    /// same body pass pays that twice AND reopens the divergence this consolidation exists to
    /// close, because the tunnel or a restore can move the stores between the two reads — the
    /// toggle and its detail line would then render from different snapshots (Codex, PR #637).
    func chainedOperationalState(
        from status: ChainedUpstreamSurfaceStatus
    ) -> ChainedOperationalState {
        ChainedOperationalState.resolve(chainedSurfaceInputs(from: status))
    }

    func chainedSurfaceInputs(from status: ChainedUpstreamSurfaceStatus) -> ChainedSurfaceInputs {
        ChainedSurfaceInputs(
            hasEntitlement: configuration.hasLavaSecurityPlus,
            preferenceEnabled: status.chainingEnabled,
            deviceStateIsUnreadable: status.deviceEligibilityUnavailableReason != nil,
            ineligibility: status.ineligibility,
            isSurrenderSuppressed: status.isSurrenderSuppressed,
            storeIsUnreadable: status.storeUnavailableReason != nil,
            hasStoredConfiguration: status.storedConfigurationSummary != nil,
            storedConfigurationIsMissingKey: status.hasConfigurationWithoutKey)
    }

    func canEnableChainedUpstream(from status: ChainedUpstreamSurfaceStatus) -> Bool {
        ChainedSetupPolicy.canEnable(
            setupEnabled: configuration.wireGuardSetupEnabled,
            inputs: chainedSurfaceInputs(from: status))
    }

    /// Closing setup commits OFF in the same configuration write. Credentials are retained;
    /// only an actual routing change schedules the existing buffered reconnect.
    func setWireGuardSetupEnabled(_ enabled: Bool) {
        guard !isStagingChainedUpstreamForQA else { return }
        guard configuration.wireGuardSetupEnabled != enabled else { return }
        let wasSetupEnabled = configuration.wireGuardSetupEnabled
        let wasChainedEnabled = configuration.chainedUpstreamEnabled
        configuration.setWireGuardSetupEnabled(enabled)
        do {
            try persistConfigurationOnly()
            if !enabled { clearChainedConfigurationStartIssue() }
            if wasChainedEnabled != configuration.chainedUpstreamEnabled {
                requestChainedSettingsApply()
            }
        } catch {
            configuration.wireGuardSetupEnabled = wasSetupEnabled
            configuration.chainedUpstreamEnabled = wasChainedEnabled
            vpnMessage = error.localizedDescription
            vpnMessageIsError = true
        }
    }

    func clearChainedConfigurationStartIssue() {
        if (chainedConfigurationStartIssue.map { vpnMessage == $0.message.lavaLocalized } ?? false)
            || (!configuration.chainedUpstreamEnabled && vpnMessage == Self.chainedStartupFailureMessage.lavaLocalized) {
            vpnMessage = nil
            vpnMessageIsError = false
        }
        chainedConfigurationStartIssue = nil
    }

    /// Missing credentials are a setup problem, not a failed forwarding attempt. Keep the
    /// saved request on a read failure; explicit OFF is the only DNS-only recovery choice.
    func validateChainedConfigurationForStart() -> Bool {
        // A fresh start/reconnect supersedes the previous apply result. Clear it here,
        // before awaiting the new attempt, never at completion where it could erase a
        // newer settings failure published during the connection.
        chainedSettingsApplyError = nil
        guard configuration.chainedUpstreamEnabled else {
            clearChainedConfigurationStartIssue()
            return true
        }
        let issue = ChainedSetupPolicy.configurationIssue(
            chainedSurfaceInputs(from: chainedUpstreamSurfaceStatus))
        chainedConfigurationStartIssue = issue
        guard let issue else { return true }
        vpnMessage = issue.message.lavaLocalized
        vpnMessageIsError = true
        return false
    }

    /// The chained state for a caller that does NOT already hold a status snapshot.
    ///
    /// ONE cheap term is settled here, from `configuration` alone: entitlement, which is the
    /// resolver's own first guard, so returning early is not a shortcut around the policy but its
    /// cheap path. `chainedUpstreamSurfaceStatus` re-reads the store and hits the Keychain on
    /// every call, on the main actor, during render — so this is worth having for the account
    /// that cannot chain at all.
    ///
    /// THE PREFERENCE USED TO SHORT-CIRCUIT HERE TOO, and it cannot: since the resolver puts the
    /// conditions that DISABLE the toggle above the preference, answering `.preferenceOff` without
    /// the snapshot would be a different answer from the one the policy gives — the divergence
    /// this consolidation exists to remove, reintroduced in the helper meant to serve it (Codex,
    /// PR #637).
    var chainedOperationalState: ChainedOperationalState {
        guard configuration.hasLavaSecurityPlus else { return .notEntitled }
        return chainedOperationalState(from: chainedUpstreamSurfaceStatus)
    }

    /// One-line summary for the Settings row.
    ///
    /// Pure rendering: the DECISION lives in `ChainedOperationalState`/`ChainedSurfaceSummary`,
    /// where it has real behavioural tests instead of source pins, and where the toggle's detail
    /// line reads the same answer. The two used to run separate tables in different orders — the
    /// row tested the preference early, the detail line tested it late — so a preference that was
    /// off with a stale surrender recorded read "Off" here and "Guard stopped because VPN chaining
    /// could not keep forwarding" there.
    ///
    /// The leading token is the USER'S SETTING, never Lava's operational state, and that is now
    /// structural rather than remembered: only `.settingOff` can render the disabled token, and it
    /// is reachable from exactly one state.
    /// pinned: ChainedSurfaceStateTests.testTheSummaryNeverContradictsTheUsersSetting
    var vpnChainingSummaryText: String {
        switch ChainedSurfaceSummary(chainedOperationalState) {
        case .unavailable(.notEntitled): return "Needs Lava Security Plus"
        case .unavailable(.unsupportedDevice): return "Not available on this device"
        case .unavailable(.deviceStateUnreadable): return "Unavailable — device state unreadable"
        case .unavailable(.startupFailed): return "Unavailable — startup failed"
        case .settingOff: return "Off"
        case .settingOn(nil): return "On"
        case .settingOn(.upstreamStoppedForwarding): return "On — upstream stopped forwarding"
        case .settingOn(.storeUnreadable): return "On — stored upstream unreadable"
        case .settingOn(.noUpstreamConfigured): return "On — no upstream configured"
        case .settingOn(.upstreamKeyMissing): return "On — private key missing"
        }
    }

    /// Cable-driven QA setup, so a device run needs no taps.
    ///
    /// The point of a QA build is that it can be automated; until now every chained-upstream
    /// step needed a human on the phone, which made an S9 device pass a manual ritual and
    /// made a wrong step indistinguishable from a defect. These read launch arguments, which
    /// Foundation folds into `UserDefaults.standard`, so `devicectl device process launch`
    /// can drive them:
    ///
    ///     xcrun devicectl device process launch --device <udid> com.lavasec.dev.qa \
    ///       -LavaQAForcePaidPlan YES \
    ///       -LavaQAChainedUpstreamFile Library/qa-chained-upstream.conf \
    ///       -LavaQAEnableChaining YES
    ///
    /// The `.conf` is read from a path RELATIVE TO THE APP GROUP CONTAINER, because
    /// `devicectl` can write into that container's `Library/` subtree — so the whole flow
    /// (push a config, enable, start) is drivable from the Mac.
    ///
    /// Every override is QA-gated and no-ops unless its argument is present, so an ordinary
    /// QA launch behaves exactly as before.
    func applyQALaunchOverrides() async {
        let defaults = UserDefaults.standard
        // Unconditional, so "nothing happened" is distinguishable from "the arguments never
        // arrived" — every branch below is conditional, and silence from all four is the
        // same shape as argv not reaching the process at all.
        logVPNDebugEvent("qa-launch-overrides-checked", details: [
            "argCount": "\(ProcessInfo.processInfo.arguments.count)",
            "sawPaidPlan": "\(defaults.object(forKey: "LavaQAForcePaidPlan") != nil)",
            "sawConfFile": "\(defaults.object(forKey: "LavaQAChainedUpstreamFile") != nil)",
            "sawEnable": "\(defaults.object(forKey: "LavaQAEnableChaining") != nil)",
            // Every conditional branch below needs a field here or the log stops doing its
            // one job: a launch passing ONLY this argument would otherwise report all the
            // others false — the exact "argv never arrived" shape this line disambiguates.
            "sawReset": "\(defaults.object(forKey: "LavaQAResetChainedSuppressions") != nil)",
            "sawResetFilters": "\(defaults.object(forKey: "LavaQAResetFilters") != nil)",
            "sawEnableSourceIDs": "\(defaults.object(forKey: "LavaQAEnableSourceIDs") != nil)",
            "sawEgressDemand": "\(defaults.object(forKey: "LavaQAEgressDemandSeconds") != nil)",
            "sawEgressDemandHost": "\(defaults.object(forKey: "LavaQAEgressDemandHost") != nil)",
            "sawIncludeAllNetworks": "\(defaults.object(forKey: "LavaQAIncludeAllNetworks") != nil)",
            "sawBrowserProbe": "\(defaults.object(forKey: "LavaQABrowserProbe") != nil)",
        ])

        // FIRST, because everything below it is worthless on a device whose filter selection
        // cannot produce an artifact: chaining latches, the tunnel comes up, and every query
        // is still answered block-all because the snapshot never compiled. This is the one
        // override that can take a wedged device back to a state the pipeline can satisfy.
        //
        // Ordering caveat, stated rather than papered over: this runs in its own `Task`, so it
        // does not strictly precede the launch reconcile started elsewhere in `init`. It does
        // not need to — `persistFilterChanges()` republishes, and the fail-closed reconcile
        // retry ladder (20/60/180s) re-attempts after it lands. A reset that arrives second
        // costs one ladder rung, not the run.
        if defaults.bool(forKey: "LavaQAResetFilters") {
            resetFiltersToRecommendedDefaultsForQA()
            logVPNDebugEvent("qa-launch-override", details: ["override": "reset-filters"])
        }

        // Entitlement. A locally built QA app has no App Store receipt, so
        // `entitlement.isActive` is false and every Plus-gated surface — including chaining —
        // is unreachable. This is a build artifact, not the product's behaviour.
        // Through `persistPaidPlanFlag`, not a direct write: that is the one entry point that
        // also runs the tier reconcile, so the limits and the flag cannot disagree.
        if defaults.bool(forKey: "LavaQAForcePaidPlan"), !configuration.hasLavaSecurityPlus {
            do {
                try persistPaidPlanFlag(true)
                logVPNDebugEvent("qa-launch-override", details: ["override": "paid-plan"])
            } catch {
                logVPNDebugEvent("qa-launch-override", details: [
                    "override": "paid-plan",
                    "error": "\(error)",
                ])
            }
        }

        // A specific catalog selection, to drive a target compiled rule count for the S9
        // memory/energy cells (e.g. ~2M) that no user-facing default reaches. Comma-separated
        // catalog source IDs; routes through the SAME onboarding path a user pick uses, so the
        // launch/staleness sync fetches + compiles them and #539's follow-up-sync applies.
        // AFTER the paid-plan override so the 2M tier cap is already active before the selection
        // is sized against it. This replaces the whole catalog selection (custom blocklists are
        // dropped) — exactly what the isolated-filter cells want. No-op on an absent/empty value.
        if let requestedCSV = defaults.string(forKey: "LavaQAEnableSourceIDs") {
            let requestedIDs = Set(
                requestedCSV
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            )
            // Before first unlock, loadPersistedConfiguration marks the config a PLACEHOLDER
            // (sharedStateUnavailableAtLoad); mutating + persisting the selection then would
            // overwrite the real (still-unreadable) config. Skip it in that window. This override
            // is NOT replayed at unlock — reloadSharedStateIfBlockedByDataProtection reloads the
            // catalog + reconciles the tunnel but does not re-run applyQALaunchOverrides (nor does
            // resetFiltersToRecommendedDefaultsForQA's identical guard) — so a QA run needing the
            // selection must be launched on an UNLOCKED device (the normal devicectl flow, where
            // sharedStateUnavailableAtLoad is false). The `deferred` log field makes a pre-unlock
            // miss visible so the operator relaunches; coupling QA overrides into the production
            // data-protection unlock path to auto-replay them is not worth it for QA-only tooling.
            // (Codex P2, #541.)
            let deferredForLockedState = sharedStateUnavailableAtLoad
            if !requestedIDs.isEmpty, !deferredForLockedState {
                selectOnboardingBlocklists(requestedIDs)
                // selectOnboardingBlocklists no-ops when the selection is UNCHANGED, which skips
                // its missing-source follow-up. A QA relaunch with the same IDs after an
                // interrupted download (killed / lost connectivity mid-compile) must still retry
                // the uncached sources — the staleness sync won't, it gates on catalog-metadata
                // age, not source-cache presence. Request it explicitly; it no-ops when nothing is
                // missing and coalesces via the #539 follow-up logic when a sync is in flight.
                // (Codex P2, #541.)
                startOnboardingBlocklistSyncIfNeeded(for: requestedIDs)
            }
            logVPNDebugEvent("qa-launch-override", details: [
                "override": "enable-source-ids",
                "requested": "\(requestedIDs.count)",
                "deferred": deferredForLockedState ? "shared-state-unavailable" : "false",
                "ids": requestedIDs.sorted().joined(separator: ","),
            ])
        }

        // BEFORE staging and enabling. This hidden launch fixture removes stale breaker/surrender
        // state from scripted QA setup. Production recovery happens on an explicit Guard start.
        if defaults.bool(forKey: "LavaQAResetChainedSuppressions") {
            resetChainedSuppressionsForQA()
            logVPNDebugEvent("qa-launch-override", details: ["override": "reset-chained-suppressions"])
        }

        if let relativePath = defaults.string(forKey: "LavaQAChainedUpstreamFile"),
            let containerURL = LavaSecAppGroup.containerURL
        {
            let url = containerURL.appendingPathComponent(relativePath)
            if let conf = try? String(contentsOf: url, encoding: .utf8) {
                let staged = await stageChainedUpstreamForQA(conf: conf)
                // Carry the refusal text: staging has a dozen distinct refusals and
                // "staged: false" alone sends you guessing at all of them.
                logVPNDebugEvent("qa-launch-override", details: [
                    "override": "stage-chained-upstream",
                    "staged": staged ? "true" : "false",
                    "detail": staged ? "" : (adminQAStatusMessage ?? "no message"),
                    "confBytes": "\(conf.utf8.count)",
                ])
            } else {
                logVPNDebugEvent("qa-launch-override", details: [
                    "override": "stage-chained-upstream",
                    "staged": "false",
                    "error": "unreadable:\(relativePath)",
                ])
            }
        }

        // Applied LAST: staging enables chaining itself, and eligibility reconciliation can
        // clear it. Setting it here means the final persisted value is the requested one.
        if defaults.object(forKey: "LavaQAEnableChaining") != nil {
            let enable = defaults.bool(forKey: "LavaQAEnableChaining")
            if configuration.chainedUpstreamEnabled != enable {
                setChainedUpstreamEnabled(enable)
            }
            logVPNDebugEvent("qa-launch-override", details: [
                "override": "enable-chaining",
                "requested": enable ? "true" : "false",
                "effective": configuration.chainedUpstreamEnabled ? "true" : "false",
            ])
        }

        var qaRoutingProfileChanged = false
        if defaults.object(forKey: "LavaQADNSOnlyDefaultRoutes") != nil {
            let enabled = defaults.bool(forKey: "LavaQADNSOnlyDefaultRoutes")
            defaults.set(enabled, forKey: "LavaQADNSOnlyDefaultRoutesEnabled")
            qaRoutingProfileChanged = true
            logVPNDebugEvent("qa-launch-override", details: [
                "override": "dns-only-default-routes", "enabled": String(enabled),
            ])
        }
        if defaults.object(forKey: "LavaQADNSOnlyIPv6") != nil {
            let enabled = defaults.bool(forKey: "LavaQADNSOnlyIPv6")
            defaults.set(enabled, forKey: "LavaQADNSOnlyIPv6Enabled")
            qaRoutingProfileChanged = true
            logVPNDebugEvent("qa-launch-override", details: [
                "override": "dns-only-ipv6", "enabled": String(enabled),
            ])
        }
        if let mode = defaults.string(forKey: "LavaQABlockAddressMode"),
           ["unspecified", "loopback", "nxdomain", "nodata", "cloudflare"].contains(mode) {
            defaults.set(mode, forKey: "LavaQADNSBlockAddressMode")
            qaRoutingProfileChanged = true
            logVPNDebugEvent("qa-launch-override", details: [
                "override": "dns-block-address-mode", "mode": mode,
            ])
        }
        // Bounded host-route comparison; the imported peer and filtering rules are untouched.
        // "none" restores the normal route plan; on/off changes only enforcement for the A/B.
        if let raw = defaults.string(forKey: "LavaQACaptureDNS") {
            let addresses = raw == "none" ? [] : raw.split(separator: ",").map(String.init)
            let claimable = DNSCaptureFloorMembership.claimableResolverAddresses(addresses)
            let validated = DNSCaptureFloor.hostRoutes(forResolverAddresses: claimable)
            if addresses.count <= 8, validated.count == Set(addresses).count {
                defaults.set(addresses, forKey: "LavaQACapturedDNSResolvers")
                let enforcement = defaults.string(forKey: "LavaQACaptureDNSEnforcement") ?? "on"
                defaults.set(enforcement == "off" ? "off" : "on", forKey: "LavaQADNSRouteEnforcement")
                qaRoutingProfileChanged = true
                logVPNDebugEvent("qa-launch-override", details: [
                    "override": "capture-dns-routes", "count": String(addresses.count),
                    "enforcement": enforcement == "off" ? "off" : "on",
                ])
            }
        }

        // Keep the experiment across probe relaunches, but never enable it for a path without
        // general forwarding. Explicit NO also provides a cable-driven recovery from lockdown.
        if defaults.object(forKey: "LavaQAIncludeAllNetworks") != nil {
            let requested = defaults.bool(forKey: "LavaQAIncludeAllNetworks")
            let accepted = !requested || DNSRouteEnforcementPolicy.shouldIncludeAllNetworks(
                requested: requested,
                chainedUpstreamEnabled: configuration.chainedUpstreamEnabled,
                routingPolicy: storedChainedRoutingPolicyForEnforcement)
            if accepted {
                defaults.set(requested, forKey: "LavaQAFullTunnelLockdownEnabled")
                qaRoutingProfileChanged = true
            }
            logVPNDebugEvent("qa-launch-override", details: [
                "override": "include-all-networks", "requested": String(requested),
                "accepted": String(accepted), "effective": String(shouldIncludeAllNetworksForQA),
            ])
        }

        if qaRoutingProfileChanged { await applyQARoutingProfile() }

        if defaults.bool(forKey: "LavaQAAuditVPNProfiles") {
            await logQAVPNProfileAudit(reason: "launch-request")
        }
        emitQAConsoleReadbackIfRequested()

        // This lab operates only on Lava's app-owned DNS preferences. A Safari-installed
        // profile is deliberately not inferred from a button tap or a resolver observation.
        if ProcessInfo.processInfo.arguments.contains("-LavaQAManagedDNS"),
           let action = defaults.string(forKey: "LavaQAManagedDNS"),
           ["audit", "install", "remove"].contains(action) {
            await runQAManagedDNS(action: action)
        }

        // Explicit launch argument only: never persist or auto-start the local TLS lab.
        if ProcessInfo.processInfo.arguments.contains("-LavaQALocalDNSBridgeSeconds") {
            let seconds = min(max(defaults.integer(forKey: "LavaQALocalDNSBridgeSeconds"), 0), 180)
            if seconds > 0 {
                Task { [weak self] in await self?.runQALocalDNSBridge(seconds: seconds) }
            }
        }

        // URLSession does not necessarily exercise WebKit's Connectivity Assist fallback.
        // This explicit, bounded QA probe uses fresh website storage per navigation, observes
        // only main-document response metadata, and never changes Guard or routing settings.
        if defaults.bool(forKey: "LavaQABrowserProbe") {
            Task { [weak self] in
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
                await self?.runQABrowserConnectivityProbe()
            }
        }

        // Observe ordinary request behavior through transitions; never wait for the VPN
        // to reconnect between attempts, or the probe would miss the window under test.
        let transitionSeconds = min(max(defaults.integer(forKey: "LavaQATransitionProbeSeconds"), 0), 900)
        if transitionSeconds > 0 {
            let delay = min(max(defaults.object(forKey: "LavaQATransitionProbeDelaySeconds") == nil
                ? 15 : defaults.integer(forKey: "LavaQATransitionProbeDelaySeconds"), 0), 60)
            Task { [weak self] in
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                await self?.runQATransitionProbe(seconds: transitionSeconds)
            }
        }

        // Sustained non-DNS demand for a device test of the egress-dead surrender arm, which needs
        // the user to keep asking for general traffic while forwarding is dead — something no
        // headless browser can supply. Applied AFTER enable-chaining so the tunnel is the one
        // carrying it; the loop runs in its own Task so it does not hold up launch.
        if defaults.object(forKey: "LavaQAEgressDemandSeconds") != nil {
            let seconds = min(max(defaults.integer(forKey: "LavaQAEgressDemandSeconds"), 0), 600)
            // 🔴 The demand host MUST differ from the tunnel's configured DNS resolver. The runner
            // excludes resolver-sourced bytes from `forwardedNonDNSByteCount` (PR #558 — a chain
            // that only answers its own resolver must not false-confirm "Protected"), so demand
            // aimed at the resolver IP is dropped from the forwarding count and a HEALTHY chain then
            // reads as egress-dead. Override with `-LavaQAEgressDemandHost <ip>` per test conf.
            let host = defaults.string(forKey: "LavaQAEgressDemandHost") ?? "8.8.8.8"
            // Device-tool relaunch can terminate the old provider too. Let a reproduction
            // wait for the replacement before its first lookup; otherwise the probe tests
            // the reconnect gap and seeds system DNS caches before filtering is ready.
            let delaySeconds = min(max(defaults.integer(forKey: "LavaQAEgressDemandDelaySeconds"), 0), 60)
            if seconds > 0 {
                Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(delaySeconds)) } catch { return }
                    await self?.runQAEgressDemand(seconds: seconds, host: host)
                }
            }
            logVPNDebugEvent("qa-launch-override", details: [
                "override": "egress-demand", "seconds": "\(seconds)", "host": host,
                "delaySeconds": "\(delaySeconds)",
            ])
        }
    }

    /// Opt-in, bounded console readback when USB file transfers stall. Only routing/probe
    /// events are exported, from the last 2 MiB of each existing log; no preferences or keys.
    private func emitQAConsoleReadbackIfRequested() {
        guard UserDefaults.standard.bool(forKey: "LavaQAConsoleReadback"),
              let container = LavaSecAppGroup.containerURL else { return }
        let events: Set<String> = [
            "route-enforcement-started", "setTunnelNetworkSettings-begin", "startTunnel-ready",
            "dns-block-address-mode", "qa-vpn-profile-state", "qa-vpn-profile-audit",
            "qa-transition-probe-begin", "qa-transition-probe-result",
            "qa-transition-probe-done", "qa-transition-probe-skipped",
            "qa-local-dns-ready", "qa-local-dns-stopped", "qa-local-dns-query",
            "qa-local-dns-response", "qa-local-dns-listener-failed", "qa-local-dns-skipped",
            "qa-local-dns-client-ready", "qa-local-dns-client-failed", "qa-local-dns-timeout",
            "qa-local-dns-query-rejected", "qa-local-dns-upstream-invalid", "qa-local-dns-upstream-failed",
            "qa-local-dns-selftest-result",
        ]
        for name in [LavaSecAppGroup.vpnDebugLogRotatedFilename, LavaSecAppGroup.vpnDebugLogFilename] {
            guard let handle = try? FileHandle(forReadingFrom: container.appendingPathComponent(name)) else { continue }
            defer { try? handle.close() }
            guard let size = try? handle.seekToEnd() else { continue }
            let start = size > 2 * 1024 * 1024 ? size - 2 * 1024 * 1024 : 0
            do {
                try handle.seek(toOffset: start)
                let data = try handle.read(upToCount: 2 * 1024 * 1024) ?? Data()
                for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
                    guard let row = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: String],
                          let event = row["event"], events.contains(event) else { continue }
                    // Direct writes keep output available even when the QA process stays alive.
                    try FileHandle.standardOutput.write(contentsOf: Data(("LAVA_QA_READBACK " + line + "\n").utf8))
                }
            } catch {
                // Console availability must never change protection or prevent app launch.
                continue
            }
        }
    }

    /// Compares app-owned DNS settings with the signed-profile contract without changing Guard.
    /// Mutations are explicit QA launch actions and require Guard to remain stopped.
    private func runQAManagedDNS(action: String) async {
        let manager = NEDNSSettingsManager.shared()
        let mutates = action != "audit"
        if mutates {
            await refreshProtectionStatus(force: true)
            guard !userProtectionIntent.isEnabled,
                  vpnStatus == .disconnected || vpnStatus == .invalid,
                  protectionActionOrchestrator.claim(.reconnect) else {
                logVPNDebugEvent("qa-managed-dns-refused", details: ["reason": "guard-must-be-off"])
                return
            }
        }
        defer { if mutates { protectionActionOrchestrator.release(.reconnect) } }
        do {
            try await manager.loadFromPreferences()
            let contract = try DNSPatchContract.bundled()
            if action == "install" {
                let settings = NEDNSOverTLSSettings(servers: contract.serverAddresses)
                settings.serverName = contract.serverName
                if #available(iOS 26.0, *) { settings.allowFailover = false }
                manager.dnsSettings = settings
                manager.onDemandRules = [NEOnDemandRuleConnect()]
                manager.localizedDescription = "Lava — DNS Patch (App-managed Test)"
                try await manager.saveToPreferences()
            } else if action == "remove" {
                try await manager.removeFromPreferences()
            }
            try await manager.loadFromPreferences()
            let settings = manager.dnsSettings as? NEDNSOverTLSSettings
            let matches = settings?.serverName == contract.serverName
                && settings?.servers == contract.serverAddresses
                && (settings?.matchDomains?.isEmpty ?? true)
            logVPNDebugEvent("qa-managed-dns-state", details: [
                "reason": action,
                "enabled": String(manager.isEnabled),
                "count": manager.dnsSettings == nil ? "0" : "1",
                "status": matches ? "matches-contract" : "absent-or-different",
            ])
        } catch {
            logVPNDebugEvent("qa-managed-dns-failed", details: [
                "reason": action, "error": String(describing: error),
            ])
        }
    }

    /// Reads all saved Lava profiles without changing them, for controlled-update validation.
    /// Logs policy and lifecycle state only; peer configuration and credentials are omitted.
    func logQAVPNProfileAudit(reason: String) async {
        do {
            let managers = try await vpnLifecycleController.matchingManagers()
            logVPNDebugEvent("qa-vpn-profile-audit", details: [
                "reason": reason, "count": String(managers.count),
            ])
            for (index, manager) in managers.enumerated() {
                let provider = manager.protocolConfiguration as? NETunnelProviderProtocol
                logVPNDebugEvent("qa-vpn-profile-state", details: [
                    "reason": reason, "index": String(index),
                    "onDemandEnabled": String(manager.isOnDemandEnabled),
                    "includeAllNetworks": provider.map { String($0.includeAllNetworks) } ?? "unknown",
                    "enforceRoutes": provider.map { String($0.enforceRoutes) } ?? "unknown",
                    "vpnStatus": vpnStatusDebugDescription(manager.connection.status),
                ])
            }
        } catch {
            logVPNDebugEvent("qa-vpn-profile-audit-failed", details: [
                "reason": reason, "error": String(describing: error),
            ])
        }
    }

    /// Applies an explicit QA comparison even when a stale strict profile cannot connect.
    /// Uses the ordinary cross-process reconnect fence; never manufactures ON intent.
    private func applyQARoutingProfile() async {
        await refreshProtectionStatus(force: true)
        guard hasCompletedOnboarding, userProtectionIntent.isEnabled,
              let container = LavaSecAppGroup.containerURL,
              let generation = try? LavaProtectionCommandService.captureExternalRestartGeneration() else { return }
        let revision = userProtectionIntent.revision
        for _ in 0..<100 where protectionActionOrchestrator.isActionInFlight {
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
        }
        guard userProtectionIntent.isEnabled, userProtectionIntent.revision == revision,
              protectionActionOrchestrator.claim(.reconnect) else { return }
        defer { protectionActionOrchestrator.release(.reconnect) }
        await reconnectProtectionNow(
            playsOutcomeHaptic: false,
            continueIfCurrent: { [weak self] in
                guard let self, !Task.isCancelled, self.userProtectionIntent.isEnabled,
                      self.userProtectionIntent.revision == revision,
                      (try? LavaProtectionCommandService.captureExternalRestartGeneration()) == generation
                else { return false }
                return ProtectionRestoreIntentStore.read(containerURL: container)
                    .resolvedIntent(fallingBackTo: self.userProtectionIntent.isEnabled)
            },
            requiresActiveSession: false)
    }

    /// Drives sustained GENERAL (non-DNS) demand through the chained tunnel for `seconds`, so a
    /// device test can exercise the egress-dead surrender arm without a human browsing.
    ///
    /// Fetches `host` (pass a LITERAL IP so no DNS lookup precedes it) every couple of seconds: the
    /// request itself is the non-DNS forwarding demand, the first one brings the tunnel up on demand,
    /// and each tick is logged so the capture shows the demand next to the driver's
    /// `egressDeadOutageCount`. The gaps stay well under the driver's demand-continuity window, and
    /// whether the fetch SUCCEEDS is irrelevant to the arm — even a dropped request has already
    /// emitted the outbound SYN the obliging-non-DNS-send signal keys on, which is the whole point
    /// once forwarding is dead. `host` MUST NOT be the tunnel's configured DNS resolver (see the
    /// caller) or the forwarding it produces is excluded from the count and the arm mis-reads dead.
    func runQAEgressDemand(seconds: Int, host: String) async {
        let deadline = Date().addingTimeInterval(TimeInterval(seconds))
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 4
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.urlCache = nil
        let session = URLSession(configuration: config)
        guard let url = URL(string: "https://\(host)/") else {
            logVPNDebugEvent("qa-egress-demand-done", details: ["ticks": "0", "err": "bad-host:\(host)"])
            return
        }
        var tick = 0
        while Date() < deadline {
            tick += 1
            var ok = false
            var bytes = 0
            var errText = ""
            do {
                let (data, response) = try await session.data(from: url)
                bytes = data.count
                ok = (response as? HTTPURLResponse)?.statusCode == 200
            } catch {
                errText = String("\(error)".prefix(60))
            }
            logVPNDebugEvent("qa-egress-demand-tick", details: [
                "tick": "\(tick)", "ok": "\(ok)", "bytes": "\(bytes)", "host": host, "err": errText,
            ])
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        logVPNDebugEvent("qa-egress-demand-done", details: ["ticks": "\(tick)"])
    }

    /// Bounded concurrent HTTP probes. Fresh sessions avoid intentional connection reuse;
    /// they do not flush system DNS caches, so fresh lookup coverage still needs capture.
    private func runQATransitionProbe(seconds: Int) async {
        guard userProtectionIntent.isEnabled else {
            logVPNDebugEvent("qa-transition-probe-skipped", details: ["reason": "guard-intent-off"])
            return
        }
        let runID = UUID().uuidString
        if let suffix = UserDefaults.standard.string(forKey: "LavaQAQualificationSuffix") {
            guard let fixture = try? QADomainProbeSet(suffix: suffix),
                  fixture.blockedDomain.utf8.count <= 220, fixture.allowedDomain.utf8.count <= 220,
                  currentSnapshot().decision(for: "qualification-control." + fixture.blockedDomain).action == .block,
                  currentSnapshot().decision(for: "qualification-control." + fixture.allowedDomain).action == .allow else {
                logVPNDebugEvent("qa-transition-probe-skipped", details: ["reason": "controlled-fixture-resident-rules"])
                return
            }
            // The operator provisions wildcard DNS/HTTPS and the real selected rules.
            // This path never inserts QA-only rules or replaces routing preferences.
            let deadline = ProcessInfo.processInfo.systemUptime + Double(seconds)
            logVPNDebugEvent("qa-transition-probe-begin", details: ["runID": runID, "seconds": String(seconds), "fixture": "controlled", "startedUptime": String(ProcessInfo.processInfo.systemUptime)])
            async let blocked: Void = runQATransitionHost(host: fixture.blockedDomain, runID: runID, deadline: deadline, uniqueNames: true)
            async let allowed: Void = runQATransitionHost(host: fixture.allowedDomain, runID: runID, deadline: deadline, uniqueNames: true)
            async let shared: Void = runQATransitionHost(host: fixture.blockedDomain, runID: runID, deadline: deadline, sharedSession: true)
            async let sharedAllowed: Void = runQATransitionHost(host: fixture.allowedDomain, runID: runID, deadline: deadline, sharedSession: true)
            _ = await (blocked, allowed, shared, sharedAllowed)
            logVPNDebugEvent("qa-transition-probe-done", details: ["runID": runID, "completedUptime": String(ProcessInfo.processInfo.systemUptime)])
            return
        }
        let snapshot = currentSnapshot()
        let oracleAction = snapshot.decision(for: "www.oracle.com").action
        let linkedinAction = snapshot.decision(for: "www.linkedin.com").action
        let ianaAction = snapshot.decision(for: "www.iana.org").action
        guard oracleAction == .block, linkedinAction == .block, ianaAction == .allow else {
            logVPNDebugEvent("qa-transition-probe-skipped", details: [
                "reason": "filter-preconditions", "oracleAction": oracleAction.rawValue,
                "linkedinAction": linkedinAction.rawValue, "ianaAction": ianaAction.rawValue,
            ])
            return
        }
        let deadline = ProcessInfo.processInfo.systemUptime + Double(seconds)
        logVPNDebugEvent("qa-transition-probe-begin", details: ["runID": runID, "seconds": String(seconds)])
        let fault = UserDefaults.standard.string(forKey: "LavaQATransitionFault")
        let faultTask = Task { [weak self] in
            guard seconds >= 90, let fault,
                  fault == "peer-blackout" || fault == "reconnect" else { return }
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            guard let self, self.userProtectionIntent.isEnabled,
                  UIApplication.shared.applicationState == .active,
                  let profile = self.tunnelManager?.protocolConfiguration as? NETunnelProviderProtocol,
                  !profile.includeAllNetworks,
                  self.tunnelManager?.connection.status == .connected else { return }
            self.logVPNDebugEvent("qa-transition-fault-request", details: ["runID": runID, "fault": fault])
            if fault == "peer-blackout" {
                await self.sendTunnelMessage("qa-peer-blackout-20s")
            } else {
                await self.reconnectProtectionNow(
                    playsOutcomeHaptic: false,
                    continueIfCurrent: { self.userProtectionIntent.isEnabled },
                    requiresActiveSession: true)
            }
            self.logVPNDebugEvent("qa-transition-fault-request-done", details: ["runID": runID, "fault": fault])
        }
        defer { faultTask.cancel() }
        async let oracle: Void = runQATransitionHost(host: "www.oracle.com", runID: runID, deadline: deadline)
        async let linkedin: Void = runQATransitionHost(host: "www.linkedin.com", runID: runID, deadline: deadline)
        async let allowed: Void = runQATransitionHost(host: "www.iana.org", runID: runID, deadline: deadline)
        // Separate shared-session controls run concurrently for the same window.
        // This permits reuse; task metrics, not session identity, describe it.
        async let sharedBlocked: Void = runQATransitionHost(host: "www.oracle.com", runID: runID, deadline: deadline, sharedSession: true)
        async let sharedAllowed: Void = runQATransitionHost(host: "www.iana.org", runID: runID, deadline: deadline, sharedSession: true)
        _ = await (oracle, linkedin, allowed, sharedBlocked, sharedAllowed)
        logVPNDebugEvent("qa-transition-probe-done", details: ["runID": runID])
        emitQAConsoleReadbackIfRequested()
    }

    /// Any HTTP response, including a redirect or rejection, proves remote reachability.
    /// HEAD requests omit page bodies, and redirects/cookies/credentials are not followed.
    private func runQATransitionHost(host: String, runID: String, deadline: TimeInterval, sharedSession: Bool = false, uniqueNames: Bool = false) async {
        var attempt = 0
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 4
        configuration.timeoutIntervalForResource = 4
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        let retainedSession = sharedSession ? URLSession(configuration: configuration) : nil
        defer { retainedSession?.invalidateAndCancel() }
        while !Task.isCancelled, userProtectionIntent.isEnabled,
              ProcessInfo.processInfo.systemUptime < deadline {
            attempt += 1
            let probeHost = uniqueNames ? "\(runID.replacingOccurrences(of: "-", with: "").prefix(12).lowercased())-\(attempt).\(host)" : host
            let session = retainedSession ?? URLSession(configuration: configuration)
            let observer = QATransitionNoRedirectDelegate()
            let started = ProcessInfo.processInfo.systemUptime
            var details = ["runID": runID, "host": probeHost, "attempt": String(attempt),
                           "vpnBefore": vpnStatusDebugDescription(vpnStatus),
                           "appBefore": String(UIApplication.shared.applicationState.rawValue),
                           "sessionKind": sharedSession ? "shared" : "fresh", "uniqueName": String(uniqueNames), "startedUptime": String(started)]
            logVPNDebugEvent("qa-transition-probe-attempt", details: details)
            do {
                var request = URLRequest(url: URL(string: "https://\(probeHost)/")!)
                request.httpMethod = "HEAD"
                let (_, response) = try await session.data(for: request, delegate: observer)
                details["outcome"] = response is HTTPURLResponse ? "http-response" : "non-http-response"
                details["httpStatus"] = (response as? HTTPURLResponse).map { String($0.statusCode) } ?? "nil"
                details["responseHost"] = response.url?.host ?? "nil"
            } catch {
                let error = error as NSError
                details["outcome"] = "request-error"
                details["errorDomain"] = error.domain
                details["errorCode"] = String(error.code)
            }
            if retainedSession == nil { session.invalidateAndCancel() }
            details.merge(observer.evidence.logFields) { _, observed in observed }
            details["completedUptime"] = String(ProcessInfo.processInfo.systemUptime)
            details["durationMs"] = String(Int((ProcessInfo.processInfo.systemUptime - started) * 1_000))
            details["vpnAfter"] = vpnStatusDebugDescription(vpnStatus)
            details["appAfter"] = String(UIApplication.shared.applicationState.rawValue)
            logVPNDebugEvent("qa-transition-probe-result", details: details)
            do { try await Task.sleep(for: .seconds(1)) } catch { break }
        }
    }

    /// Exercises browser-engine DNS after the existing tunnel connects, without assuming
    /// fresh website storage clears system DNS caches. Packet capture remains necessary.
    private func runQALocalDNSBridge(seconds: Int) async {
        guard await waitForProtectionToConnectForDebugProbe(timeout: 12),
              UIApplication.shared.applicationState == .active,
              !shouldIncludeAllNetworksForQA else {
            logVPNDebugEvent("qa-local-dns-skipped", details: ["reason": "requires-active-ordinary-tunnel"])
            return
        }
        let oldIdleTimer = UIApplication.shared.isIdleTimerDisabled
        do {
            let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                appropriateFor: nil, create: false)
            let identity = try Data(contentsOf: documents.appendingPathComponent("lava-local-dns-lab.p12"))
            let bridge = try QALocalDNSBridge(identityData: identity) { [weak self] event, details in
                Task { @MainActor in self?.logVPNDebugEvent(event, details: details) }
            }
            UIApplication.shared.isIdleTimerDisabled = true
            bridge.start(seconds: seconds)
            if let root = try? Data(contentsOf: documents.appendingPathComponent("lava-local-dns-lab-root.der")) {
                bridge.selfTest(certificateData: root)
            }
            defer {
                bridge.stop()
                UIApplication.shared.isIdleTimerDisabled = oldIdleTimer
                emitQAConsoleReadbackIfRequested()
            }
            // Stop as soon as the app backgrounds; do not imply a background service.
            for _ in 0..<seconds {
                try await Task.sleep(for: .seconds(1))
                if UIApplication.shared.applicationState != .active { break }
            }
        } catch {
            UIApplication.shared.isIdleTimerDisabled = oldIdleTimer
            logVPNDebugEvent("qa-local-dns-skipped", details: ["reason": "\(error)"])
        }
    }

    private func runQABrowserConnectivityProbe() async {
        guard await waitForProtectionToConnectForDebugProbe(timeout: 12),
              UIApplication.shared.applicationState == .active,
              let window = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .flatMap(\.windows).first(where: \.isKeyWindow) else {
            logVPNDebugEvent("qa-browser-probe-skipped", details: ["reason": "no-active-connected-session"])
            return
        }
        for host in ["www.iana.org", "www.oracle.com", "www.linkedin.com", "www.iana.org"] {
            guard !Task.isCancelled, UIApplication.shared.applicationState == .active else { break }
            logVPNDebugEvent("qa-browser-probe-begin", details: ["host": host])
            let probe = QABrowserConnectivityProbe()
            let result = await probe.run(host: host, in: window)
            logVPNDebugEvent("qa-browser-probe-result", details: result)
        }
        logVPNDebugEvent("qa-browser-probe-done")
    }

    /// Persists the chaining PREFERENCE.
    ///
    /// The data path is latched at start (`TunnelDataPathLatch`), so a successful save
    /// schedules a buffered reconnect for an active Guard. The reload keeps the running
    /// session's view current while the latest settings settle.
    func setChainedUpstreamEnabled(_ enabled: Bool) {
        guard !isStagingChainedUpstreamForQA else { return }
        guard configuration.chainedUpstreamEnabled != enabled else { return }
        if enabled {
            let status = chainedUpstreamSurfaceStatus
            guard canEnableChainedUpstream(from: status) else {
                vpnMessage = (ChainedSetupPolicy.configurationIssue(chainedSurfaceInputs(from: status))?.message
                    ?? "VPN chaining isn't available. Review its settings.").lavaLocalized
                vpnMessageIsError = true
                return
            }
        }
        configuration.chainedUpstreamEnabled = enabled
        do {
            try persistConfigurationOnly()
            clearChainedConfigurationStartIssue()
            requestChainedSettingsApply()
            Task {
                await self.sendTunnelMessage(LavaSecAppGroup.reloadConfigurationMessage)
            }
        } catch {
            // Roll the in-memory value back so the toggle cannot show a preference that was
            // never stored — the exact divergence that made `chaining-disabled` unreadable
            // from the app side during S9.
            configuration.chainedUpstreamEnabled = !enabled
            vpnMessage = error.localizedDescription
            vpnMessageIsError = true
        }
    }
    #endif

    func recordDemo(domain: String) {
        let snapshot = currentSnapshot()
        let decision = snapshot.decision(for: domain)
        // The store lives on the diagnostics controller since the Phase D4 peel; the
        // hub still writes it directly (hub→controller is the allowed direction).
        reports.diagnostics.record(
            domain: domain,
            decision: decision,
            keepFilteringCounts: configuration.keepFilteringCounts,
            keepDomainHistory: configuration.keepDomainDiagnostics
        )
    }

    #if DEBUG || LAVA_QA_TOOLS
    static var isVPNDebugProbeRequested: Bool {
        let processInfo = ProcessInfo.processInfo
        return processInfo.arguments.contains("--lava-debug-vpn")
            || processInfo.environment["LAVA_DEBUG_VPN"] == "1"
    }

    func runVPNStartupDebugProbe() async {
        // The probe drives enable/reconnect itself; holding the claim keeps the
        // UI disabled and scheduled resumes out, exactly like a user action.
        let claimedProbeAction = protectionActionOrchestrator.claim(.turnOn)
        defer {
            if claimedProbeAction {
                protectionActionOrchestrator.release(.turnOn)
            }
        }

        logVPNDebugEvent("probe-begin", details: [
            "bundleIdentifier": Bundle.main.bundleIdentifier ?? "unknown",
            "arguments": ProcessInfo.processInfo.arguments.joined(separator: " ")
        ])

        await refreshProtectionStatus(force: true)
        logVPNDebugEvent("probe-after-refresh", details: [
            "vpnStatus": vpnStatusDebugDescription(vpnStatus),
            "isVPNConfigurationInstalled": "\(isVPNConfigurationInstalled)"
        ])

        if Self.isLiveDNSSmokeTestRequested {
            logVPNDebugEvent("probe-live-dns-smoke-force-reconnect", details: [
                "vpnStatus": vpnStatusDebugDescription(vpnStatus)
            ])
            await reconnectProtectionNow(playsOutcomeHaptic: false)
            if Self.isVPNLifecycleSmokeTestRequested {
                await runVPNLifecycleSmokeProbe()
            }
            logVPNDebugEvent("probe-finished", details: [
                "vpnStatus": vpnStatusDebugDescription(vpnStatus),
                "isVPNConfigurationInstalled": "\(isVPNConfigurationInstalled)",
                "vpnMessage": vpnMessage ?? "nil",
                "vpnMessageIsError": "\(vpnMessageIsError)"
            ])
            return
        }

        if isProtectionEnabledStatus(vpnStatus) {
            logVPNDebugEvent("probe-reconnect-existing-tunnel", details: [
                "vpnStatus": vpnStatusDebugDescription(vpnStatus)
            ])
            await reconnectProtectionNow(playsOutcomeHaptic: false)
        } else {
            await enableProtection(logUserAction: false, playsOutcomeHaptic: false)
        }

        if Self.isVPNLifecycleSmokeTestRequested {
            await runVPNLifecycleSmokeProbe()
        }

        logVPNDebugEvent("probe-finished", details: [
            "vpnStatus": vpnStatusDebugDescription(vpnStatus),
            "isVPNConfigurationInstalled": "\(isVPNConfigurationInstalled)",
            "vpnMessage": vpnMessage ?? "nil",
            "vpnMessageIsError": "\(vpnMessageIsError)"
        ])
    }

    private func runVPNLifecycleSmokeProbe() async {
        logVPNDebugEvent("probe-lifecycle-begin", details: [
            "vpnStatus": vpnStatusDebugDescription(vpnStatus)
        ])

        await refreshProtectionStatus(force: true)
        guard await waitForProtectionToConnectForDebugProbe() else {
            logVPNDebugEvent("probe-lifecycle-skipped", details: [
                "vpnStatus": vpnStatusDebugDescription(vpnStatus)
            ])
            return
        }

        do {
            try await LavaProtectionCommandService.perform(.pauseFiveMinutes)
            // Drive the tunnel exactly the way production does. The command
            // service only writes shared defaults and posts the pause Darwin
            // signal, but the packet-tunnel's CFNotificationCenter observer is
            // not a reliable standalone trigger — on device it stays dormant
            // until a provider message wakes the extension's run loop (the app
            // never relies on the snapshot Darwin observer either, always using
            // sendProviderMessage). Without this send the tunnel never runs
            // refreshProtectionPauseStateOnly, so `pause-state-refreshed` never
            // lands and the lifecycle gate's required event is missing. Mirrors
            // pauseProtectionTemporarily.
            await notifyTunnelProtectionPauseUpdated()
            try await Task.sleep(nanoseconds: 1_000_000_000)
            loadTemporaryProtectionPause()
            logVPNDebugEvent("probe-lifecycle-after-pause", details: [
                "isProtectionTemporarilyPaused": "\(isProtectionTemporarilyPaused)",
                "pauseUntil": temporaryProtectionPauseUntil.map { SharedDateFormatting.iso8601.string(from: $0) } ?? "nil",
                "vpnStatus": vpnStatusDebugDescription(vpnStatus)
            ])

            try await LavaProtectionCommandService.perform(.pauseTenMinutes)
            await notifyTunnelProtectionPauseUpdated()
            try await Task.sleep(nanoseconds: 300_000_000)
            try await LavaProtectionCommandService.perform(.resume)
            try await LavaProtectionCommandService.perform(.resume)
            await notifyTunnelProtectionPauseUpdated()
            try await Task.sleep(nanoseconds: 1_000_000_000)
            loadTemporaryProtectionPause()
            await refreshProtectionStatus(force: true)
            logVPNDebugEvent("probe-lifecycle-after-resume", details: [
                "isProtectionTemporarilyPaused": "\(isProtectionTemporarilyPaused)",
                "pauseUntil": temporaryProtectionPauseUntil.map { SharedDateFormatting.iso8601.string(from: $0) } ?? "nil",
                "vpnStatus": vpnStatusDebugDescription(vpnStatus)
            ])
        } catch {
            logVPNDebugEvent("probe-lifecycle-error", details: errorDebugDetails(error))
        }
    }

    private func waitForProtectionToConnectForDebugProbe(timeout: TimeInterval = 8) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while vpnStatus != .connected, Date() < deadline {
            updateProtectionStatusFromCachedManager()
            if vpnStatus == .connected {
                return true
            }

            await refreshProtectionStatus(force: true)
            if vpnStatus == .connected {
                return true
            }

            try? await Task.sleep(nanoseconds: 250_000_000)
        }

        return vpnStatus == .connected
    }

    #endif

}

#if DEBUG || LAVA_QA_TOOLS
/// Preserve the first response as reachability evidence; never navigate a redirect target.
private final class QATransitionNoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var captured = HTTPProbeConnectionEvidence(reusedConnections: nil)
    var evidence: HTTPProbeConnectionEvidence { lock.withLock { captured } }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        let sanitized = HTTPProbeConnectionEvidence(
            reusedConnections: metrics.transactionMetrics.map(\.isReusedConnection),
            protocols: metrics.transactionMetrics.map(\.networkProtocolName))
        lock.withLock { captured = sanitized }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Short-lived browser navigation. A real HTTP response is reachability evidence even when
/// its status is not 200; errors/timeouts alone do not prove DNS containment. No page body,
/// cookies, credentials, or persistent browsing data are collected.
@MainActor
private final class QABrowserConnectivityProbe: NSObject, WKNavigationDelegate {
    private var webView: WKWebView?
    private var continuation: CheckedContinuation<[String: String], Never>?
    private var timeoutTask: Task<Void, Never>?
    private var host = ""

    func run(host: String, in parent: UIView) async -> [String: String] {
        self.host = host
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: parent.bounds, configuration: configuration)
        view.isUserInteractionEnabled = false
        view.navigationDelegate = self
        parent.addSubview(view)
        webView = view
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            timeoutTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
                self?.finish(["outcome": "timeout"])
            }
            // Hosts are the fixed public test set above, not user-supplied URLs.
            guard let url = URL(string: "https://\(host)/?lava_dns_probe=\(UUID().uuidString)") else {
                finish(["outcome": "invalid-test-url"])
                return
            }
            view.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
                                 timeoutInterval: 12))
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        guard navigationResponse.isForMainFrame else { decisionHandler(.allow); return }
        let response = navigationResponse.response as? HTTPURLResponse
        finish(["outcome": "main-document-response",
                "responseHost": navigationResponse.response.url?.host ?? "nil",
                "httpStatus": response.map { String($0.statusCode) } ?? "nil"])
        decisionHandler(.cancel)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) { fail(error) }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!,
                 withError error: Error) { fail(error) }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        finish(["outcome": "web-process-terminated"])
    }

    private func fail(_ error: Error) {
        let error = error as NSError
        finish(["outcome": "navigation-error", "errorDomain": error.domain,
                "errorCode": String(error.code)])
    }

    private func finish(_ result: [String: String]) {
        guard let continuation else { return }
        self.continuation = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        webView?.navigationDelegate = nil
        webView?.stopLoading()
        webView?.removeFromSuperview()
        webView = nil
        continuation.resume(returning: result.merging(["host": host]) { first, _ in first })
    }
}
#endif
