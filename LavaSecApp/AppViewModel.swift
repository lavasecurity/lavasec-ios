import Darwin
import Foundation
import Combine
import SwiftUI
import UIKit
@preconcurrency import NetworkExtension
import LavaSecKit
import LavaSecFilterPipeline
import LavaSecAppServices
import LavaSecPresentation

extension NETunnelProviderManager: @retroactive @unchecked Sendable {}

// FilterEditDraft, DomainDraftResult, and the pure draft-mutation editor live in
// LavaSecKit (FilterEditDraft.swift) so the mutation logic is unit-tested.

enum ProtectionPauseDuration: CaseIterable, Identifiable {
    case fiveMinutes
    case tenMinutes
    case fifteenMinutes

    var id: Self {
        self
    }

    var duration: TimeInterval {
        switch self {
        case .fiveMinutes:
            5 * 60
        case .tenMinutes:
            10 * 60
        case .fifteenMinutes:
            15 * 60
        }
    }

    var protectionCommandRequest: LavaLiveActivityActionRequest {
        switch self {
        case .fiveMinutes:
            .pauseFiveMinutes
        case .tenMinutes:
            .pauseTenMinutes
        case .fifteenMinutes:
            .pauseFifteenMinutes
        }
    }

    var label: String {
        switch self {
        case .fiveMinutes:
            "For 5 minutes"
        case .tenMinutes:
            "For 10 minutes"
        case .fifteenMinutes:
            "For 15 minutes"
        }
    }
}

// LavaAppearancePreference, LavaTextSize, and LavaGuardAvailability moved to
// CustomizationController.swift with the Phase D5 customization peel (they are
// customization-only models; the controller file is their single consumer's home).

// BugReportSendState and the bug-report submit types (BugReportSubmitResponse,
// BugReportSubmissionError, BugReportRateLimitedError, AppAttestHeaders,
// AppAttestClient) moved to DiagnosticsController.swift with the Phase D4
// diagnostics/bug-report peel — the controller owns the send state machine and
// the attested submit end to end.

// LavaSecurityPlusEntitlementSyncClient (+ its request/error types) moved to
// LavaSecurityPlusController.swift with the Phase D2 billing peel — the controller
// owns the server entitlement sync end to end.

// EncryptedBackupState lives in LavaSecAppServices (EncryptedBackupState.swift); the whole
// encrypted-backup feature (EncryptedBackupError, passkey setup, upload/restore, the
// automatic-backup debounce) now lives in BackupController.swift (Phase D1 backup peel) —
// this hub keeps only the BackupHubBridging conformance in AppViewModel+HubBridges.swift.

@MainActor
final class FilterPreparationProgressPresenter {
    private let policy: FilterPreparationPresentationPolicy
    // A silent (coverless) switch — a programmatic Focus reconcile apply — renders nothing, so the
    // phase-visibility holds are pure dead time that only keep the previous filter active longer.
    // When no cover is presented, `present`/`holdCurrentPhaseIfNeeded` short-circuit their sleeps
    // (the setState closure is already a no-op on that path), so a Focus automation applies without
    // any UI-only delay. (Codex #44 P2)
    private let presentsCover: Bool
    private var currentPhase: FilterPreparationPhase?
    private var phaseStartedAt: Date?

    init(
        policy: FilterPreparationPresentationPolicy = FilterPreparationPresentationPolicy(),
        presentsCover: Bool = true
    ) {
        self.policy = policy
        self.presentsCover = presentsCover
    }

    func present(
        _ update: FilterPreparationProgressUpdate,
        setState: (FilterPreparationState) -> Void
    ) async {
        // No cover on screen (silent Focus apply): nothing to hold, so don't sleep. currentPhase/
        // phaseStartedAt exist only to pace the cover, so leaving them untouched is inert here.
        guard presentsCover else { return }

        let holdDuration = policy.holdDurationBeforePresenting(
            currentPhase: currentPhase,
            phaseStartedAt: phaseStartedAt,
            nextPhase: update.phase
        )

        guard await sleep(for: holdDuration) else {
            return
        }

        if currentPhase != update.phase {
            currentPhase = update.phase
            phaseStartedAt = Date()
        } else if phaseStartedAt == nil {
            phaseStartedAt = Date()
        }

        setState(.preparing(
            progress: FilterPreparationPresentationPolicy.equalStepsProgress(phase: update.phase, rawProgress: update.progress),
            message: FilterPreparationPresentation.message(for: update.phase)
        ))
    }

    func holdCurrentPhaseIfNeeded() async {
        // Same rationale as `present`: a coverless silent apply has no phase to hold on screen.
        guard presentsCover, phaseStartedAt != nil
        else {
            return
        }

        let holdDuration = remainingCurrentPhaseHoldDuration()
        _ = await sleep(for: holdDuration)
    }

    private func sleep(for duration: TimeInterval) async -> Bool {
        guard duration > 0 else {
            return !Task.isCancelled
        }

        let nanoseconds = UInt64((duration * 1_000_000_000).rounded(.up))
        do {
            try await Task.sleep(nanoseconds: nanoseconds)
            return !Task.isCancelled
        } catch {
            return false
        }
    }

    private func remainingCurrentPhaseHoldDuration(now: Date = Date()) -> TimeInterval {
        guard let phaseStartedAt else {
            return 0
        }

        return max(0, policy.minimumPhaseDuration - now.timeIntervalSince(phaseStartedAt))
    }
}

// `ReusablePreparedFilterSnapshot` lives in LavaSecFilterPipeline (LAV-100 Phase 4) so the foreground
// switch and the headless Focus engine share one warm-reuse value type + validation core
// (see WarmFilterSnapshotLoader).

final class ProtectionStopNotificationWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var observer: NSObjectProtocol?
    private var continuation: CheckedContinuation<Bool, Never>?
    private var didResume = false

    func wait(timeout: TimeInterval) async -> Bool {
        guard timeout > 0 else {
            return false
        }

        return await withCheckedContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()

            let observer = NotificationCenter.default.addObserver(
                forName: .NEVPNStatusDidChange,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.finish(observedStatusChange: true)
            }

            var shouldRemoveObserver = false
            lock.lock()
            if didResume {
                shouldRemoveObserver = true
            } else {
                self.observer = observer
            }
            lock.unlock()

            if shouldRemoveObserver {
                NotificationCenter.default.removeObserver(observer)
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.finish(observedStatusChange: false)
            }
        }
    }

    private func finish(observedStatusChange: Bool) {
        let observerToRemove: NSObjectProtocol?
        let continuationToResume: CheckedContinuation<Bool, Never>?

        lock.lock()
        guard !didResume else {
            lock.unlock()
            return
        }

        didResume = true
        observerToRemove = observer
        continuationToResume = continuation
        observer = nil
        continuation = nil
        lock.unlock()

        if let observerToRemove {
            NotificationCenter.default.removeObserver(observerToRemove)
        }
        continuationToResume?.resume(returning: observedStatusChange)
    }
}

@MainActor
final class AppViewModel: ObservableObject {
    static let vpnPermissionPromptMessage = "If iOS asks to add a VPN configuration, tap Allow."
    static let protectionStopWaitTimeout: TimeInterval = 3
    static let protectionStartWaitTimeout: TimeInterval = 15
    static let protectionRestartStopWaitTimeout: TimeInterval = 15
    private static let protectionStopStatusRefreshInterval: TimeInterval = 0.5
    static let providerMessageAckTimeout: TimeInterval = 3

    static let supportsDNSOverQUICRuntime = true

    #if DEBUG || LAVA_QA_TOOLS
    static let liveDNSSmokeTestLaunchArgument = "-lava-live-dns-smoke-test"
    static let liveDNSSmokeResolverPresetIDLaunchArgument = "-lava-live-dns-smoke-resolver-preset-id"
    static let liveDNSSmokeCustomResolverLaunchArgument = "-lava-live-dns-smoke-custom-resolver"
    static let vpnLifecycleSmokeTestLaunchArgument = "-lava-vpn-lifecycle-smoke-test"

    static var isLiveDNSSmokeTestRequested: Bool {
        ProcessInfo.processInfo.arguments.contains(liveDNSSmokeTestLaunchArgument)
    }

    static var isVPNLifecycleSmokeTestRequested: Bool {
        ProcessInfo.processInfo.arguments.contains(vpnLifecycleSmokeTestLaunchArgument)
    }

    private static var liveDNSSmokeResolverPresetIDOverride: String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let argumentIndex = arguments.firstIndex(of: liveDNSSmokeResolverPresetIDLaunchArgument) else {
            return nil
        }

        let valueIndex = arguments.index(after: argumentIndex)
        guard valueIndex < arguments.endIndex else {
            return nil
        }

        let resolverPresetID = arguments[valueIndex]
        guard DNSResolverPreset.allPresets.contains(where: { $0.id == resolverPresetID }) else {
            return nil
        }

        return resolverPresetID
    }

    private static var liveDNSSmokeCustomResolverOverride: String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let argumentIndex = arguments.firstIndex(of: liveDNSSmokeCustomResolverLaunchArgument) else {
            return nil
        }

        let valueIndex = arguments.index(after: argumentIndex)
        guard valueIndex < arguments.endIndex else {
            return nil
        }

        let rawValue = arguments[valueIndex]
        guard DNSResolverPreset.customValidationMessage(
            rawValue: rawValue,
            supportsDNSOverQUIC: supportsDNSOverQUICRuntime
        ) == nil else {
            return nil
        }

        return rawValue
    }
    #endif

    private static func formatCatalogDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.timeZone = .autoupdatingCurrent
        formatter.setLocalizedDateFormatFromTemplate("yMMMdjmmz")
        return formatter.string(from: date)
    }

    private static func formatRelativeCatalogAge(_ age: TimeInterval, maxFreshnessAge: TimeInterval) -> String {
        let age = max(0, age)

        guard age < maxFreshnessAge else {
            return "more than a week".lavaLocalized
        }

        if age < 60 {
            return "Now".lavaLocalized
        }

        // Locale-correct relative time (handles each locale's unit + plural rules,
        // instead of hardcoded English "minute(s)/hour(s)/day(s) ago").
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(fromTimeInterval: -age)
    }

    @Published var configuration = AppConfiguration.lavaAppInitialDefaults
    // The hosted filters + which one is active (multi-filter library). Source of truth
    // for the SET of filters and the active selection; the active filter's four
    // filter-scoped fields are mirrored write-through into `configuration`, so the
    // ~25 existing readers of `configuration.enabledBlocklistIDs` et al. are untouched.
    // At library size 1 this is byte-for-byte today's single-filter behaviour.
    @Published var library = FilterLibrary(migratingLegacy: AppConfiguration())
    // The background catalog-refresh runs on a HEADLESS instance whose
    // loadPersistedConfiguration() must stay read-only — the migration write is gated on
    // this so a bg refresh can't overwrite a foreground-created library (read→write race).
    let isHeadless: Bool
    // True when the most recent loadOrMigrateFilterLibrary() had to REJECT the on-disk
    // library and reseed the three defaults (pre-upgrade/old-schema library, or one that lost
    // a two-file write race). The reseed mirrors Balanced into `configuration` in memory but
    // persists it only in the foreground, so a headless background publish must NOT build from
    // this state — it would flip published artifacts to Balanced while the on-disk config (and
    // its generation) still describes the pre-upgrade filter. The background publish path
    // consults this to abort until the foreground migration lands.
    var didReseedFilterLibraryOnLastLoad = false
    // True when the launch load found shared state EXISTING but UNREADABLE — Data Protection
    // before the first post-reboot unlock, or a transient I/O failure (INV-PERSIST-1,
    // pinned: RebootFirstUnlockGuardSourceTests.testLaunchLoadClassifiesReadsAndNeverPersistsAnUnreadableReseed).
    // While set, the in-memory configuration +
    // library are a placeholder, not the user's state: every persist funnel refuses to write
    // (the writer's own unreadable fence would also throw pre-unlock, but this guard stays
    // correct AFTER unlock makes the files writable again while the placeholder is still
    // resident — the delayed-clobber half of the 2026-07-14 wipe). Cleared by re-running
    // loadPersistedConfiguration once protected data becomes available / on foreground.
    var sharedStateUnavailableAtLoad = false
    // INV-PERSIST-1 also applies to Class-C preferences when the Class-None control
    // plane is already readable. Recover these independently of the shared-state flag.
    // pinned: ProtectedPreferenceRecoverySourceTests.testLaunchUnlockAndForegroundUseTheSameRecovery
    var protectedPreferenceRecovery = ProtectedPreferenceRecovery()
    // True while the in-memory library ORIGINATED from a launch-time reseed over an absent,
    // corrupt, or unreadable store. A seeded library is then recovery scaffolding, not user
    // intent, so BackupController suppresses the debounced automatic backup and its
    // pre-upload local re-seal while this is set — auto-uploading a reseed would overwrite
    // the user's last good server backup with a wipe (incident plan latent-3), while the
    // stale local envelope keeps preserving that last good state for a manual upload.
    // Deliberately NOT set when the reseed replaces a readable, invariant-valid old-schema /
    // lost-write-race library, NOR for the pre-library build's legacy upgrade (absent
    // library beside a readable, decoded config): both are the designed upgrade migration,
    // and suppressing there froze every later edit out of the envelope for users onboarding
    // never reruns for (Codex P2 rounds 2 + 7 on #376). PERSISTED
    // recovery reseeds (absent/corrupt) also stamp a durable marker so the suppression
    // survives relaunches — the reseed lands on disk as a valid current-schema library the
    // next launch would otherwise happily accept and lift (Codex P1). Cleared when the
    // library becomes user-authoritative again: a completed backup restore, the explicit
    // restore-to-default, the onboarding seed, or — for the never-persisted unreadable
    // placeholder — the recovery reload accepting the user's real file. Staying suppressed
    // until one of those explicit recoveries is the deliberate stance: the remote envelope
    // holds the user's last good library, and only a user action may supersede it. Manual
    // Back Up Now stays available and uploads the PRESERVED (pre-reseed) envelope, which is
    // exactly what it should preserve. Distinct from didReseedFilterLibraryOnLastLoad, whose
    // background-publish semantics must not change with these clears.
    var libraryOriginatesFromLaunchReseed = false
    // Durable companion to libraryOriginatesFromLaunchReseed (Codex P1 on #376): a CORRUPT
    // (or absent) store's reseed is PERSISTED as a valid current-schema library, so on the
    // next launch the accept branch would otherwise lift the in-memory suppression and let
    // an automatic backup upload the seeded defaults over the user's last good server copy.
    // The durable marker is a Class-None FILE (ReseedSuppressionMarkerStore) in the shared
    // container — readable AND durably writable pre-first-unlock in lockstep with the
    // Class-None library it guards (INV-PERSIST-2), which a Class-C UserDefaults marker could
    // not be — and it clears exactly where the in-memory flag clears for user-authoritative
    // reasons. This constant is the PRE-1.2.5 legacy Class-C defaults key, kept only as a read
    // fallback (migrated forward to the file) and cleared belt-and-braces. Deliberately NOT set
    // for the unreadable case: that placeholder is never persisted, and the recovery reload's
    // accept of the user's REAL library must lift the suppression — a durable marker would
    // wrongly outlive it.
    // pinned: RebootFirstUnlockGuardSourceTests.testAcceptedLibraryHonorsDurableFileMarker
    //
    // ACCEPTED RESIDUAL (Codex P2 round 10 on #376, deliberate disposition): a hard kill
    // after a restore's pair lands but before its post-persist marker drop leaves the
    // suppression stuck on the freshly restored library until the next user-authoritative
    // action. The inverse ordering (drop before the pair write) would instead reopen the
    // DESTRUCTIVE window — an unmarked seeded library that auto-backup can upload over the
    // user's last good server copy — when the kill lands before the pair does and the
    // pre-restore store was a marked reseed. A two-store commit cannot be atomic; between a
    // recoverable conservative freeze (manual upload still carries the restore-time
    // envelope; re-running the restore clears it) and a data-destroying clobber, the freeze
    // is the only defensible side.
    private static let recoveryReseedBackupSuppressionKeyName = "lavasec.backup.recoveryReseedSuppression"

    /// Stamp the durable recovery-reseed suppression marker and set the in-memory flag. Returns
    /// whether the marker is CONFIRMED on disk — the caller must NOT persist the reseed library
    /// unless it is, since a durable seeded library with no durable marker is read `.absentConfirmed`
    /// next launch and lets automatic backup clobber the user's server envelope (Codex P1 on #385).
    func markLibraryOriginatesFromPersistedRecoveryReseed() -> Bool {
        libraryOriginatesFromLaunchReseed = true
        // Stamp the DURABLE marker as a Class-None file (ReseedSuppressionMarkerStore): the stamp
        // must land ON DISK before the reseed persist's library-first write, and INV-PERSIST-2
        // made the library Class-None, so the marker must be durably writable pre-first-unlock
        // too. The old `UserDefaults.standard` marker could not — a Class-C write cannot land
        // while locked, and `synchronize()` is a no-op on modern iOS, so its "crash barrier" never
        // existed (Kilo/OCR follow-up on the 1.2.4 sync). A Class-None file's atomic write is
        // durable pre-unlock, matching the library it guards.
        guard let containerURL = LavaSecAppGroup.containerURL else { return false }
        return ReseedSuppressionMarkerStore.mark(containerURL: containerURL)
    }

    func clearLibraryOriginatesFromLaunchReseed() {
        libraryOriginatesFromLaunchReseed = false
        // Drop BOTH markers when the library becomes user-authoritative again. Remove the flaky
        // legacy Class-C key FIRST, then durably clear the Class-None file marker: an interruption in
        // between leaves the durable file marker present, and the next readable launch's isMarked
        // branch consumes the legacy key against it — so the common interrupted case self-heals. The
        // file-marker remove is a durable filesystem op (unlike the unflushed `UserDefaults` remove a
        // hard kill could lose), so a restore's suppression-lift itself persists.
        //
        // ACCEPTED RESIDUAL (Codex P2 on #385, deliberate disposition): the legacy `removeObject` is
        // best-effort — `UserDefaults` has no durable-flush barrier (`synchronize()` is a no-op, the
        // reason the marker itself moved to a Class-None file). So a hard kill that lands after the
        // durable file-marker clear but before the legacy remove flushes can leave the legacy key set
        // with no file marker; the next launch migrates it back (`reseedSuppressionMarkerState`) and
        // re-suppresses automatic backup over the just-cleared library. This is IRREDUCIBLE with a
        // best-effort legacy key and no atomic multi-marker commit, and it fails SAFE — recoverable
        // over-suppression (manual backup still works; any later user-authoritative action clears it
        // again), never a server-envelope clobber. It is also rare: the isMarked-branch and
        // migrate-forward consumes remove the legacy key on essentially every readable launch, so it
        // is almost never still present at a clear. Fully closing it would mean recording the
        // decision (suppressed/cleared) in a single atomic Class-None file rather than an existence
        // marker + best-effort legacy key — deferred as a larger change (1.2.5 is unshipped and this
        // residual cannot lose data).
        UserDefaults.standard.removeObject(forKey: Self.recoveryReseedBackupSuppressionKeyName)
        if let containerURL = LavaSecAppGroup.containerURL {
            if !ReseedSuppressionMarkerStore.clear(containerURL: containerURL) {
                // The durable clear FAILED — the marker is still on disk, so the next launch reads
                // `.present` and re-suppresses. Keep the in-memory flag consistent with that reality
                // rather than reporting the suppression lifted this session while the durable marker
                // outlives it (mirrors mark()'s confirmed-on-disk gate — OCR P1 on the 1.2.5 sync).
                // Fail-safe: recoverable over-suppression (manual backup still works; any later
                // user-authoritative action retries the clear), never a server-envelope clobber.
                libraryOriginatesFromLaunchReseed = true
            }
        }
    }

    /// Three-state read of the durable reseed-suppression marker. The two DEFINITE outcomes must
    /// stay distinct from "cannot tell yet" so a pre-first-unlock accept never lifts the suppression
    /// on an UNMIGRATED pre-1.2.5 device (Codex P1 on #385).
    enum ReseedSuppressionMarkerState {
        /// The durable Class-None file marker exists — this library is a recovery reseed; suppress.
        case present
        /// The file marker is absent AND a legacy marker was definitively ruled out (protected data
        /// was readable, so the Class-C store gave a trustworthy answer) — user-authoritative; lift.
        case absentConfirmed
        /// The file marker is absent but the pre-1.2.5 legacy `UserDefaults` marker is UNREADABLE
        /// (Class-C, locked). A device upgrading mid-suppression may still carry it unmigrated, so
        /// the state cannot be determined until protected data is available — the caller must freeze
        /// conservatively rather than lift on the spurious locked `false`.
        case absentUnconfirmed
    }

    /// Read the durable reseed-suppression marker. The Class-None file marker is readable before
    /// first unlock; when it is absent, the pre-1.2.5 legacy `UserDefaults` marker is consulted ONLY
    /// while protected data is readable (a locked Class-C read is a spurious `false`) and migrated
    /// forward to the durable file — the legacy key is consumed ONLY after the file marker is
    /// confirmed on disk (`mark()` true), so a failed app-group write keeps it for retry rather than
    /// stranding the accepted reseed with no durable marker (Codex P1 on #385). A locked read with no
    /// file marker returns `.absentUnconfirmed` so the accept path freezes instead of clearing the
    /// suppression on an upgrading device whose legacy marker has not migrated yet (Codex P1 on #385
    /// — the 1.2.4→1.2.5 upgrade-transition case). When the file marker is already present the legacy
    /// key is consumed too (while readable), so a migration interrupted between its mark and consume
    /// cannot leave a stale key that a later reset migrates back (Codex P2 on #385).
    func reseedSuppressionMarkerState() -> ReseedSuppressionMarkerState {
        guard let containerURL = LavaSecAppGroup.containerURL else { return .absentConfirmed }
        if ReseedSuppressionMarkerStore.isMarked(containerURL: containerURL) {
            // The durable file marker is authoritative. Clear any LEFTOVER legacy Class-C key —
            // e.g. a prior migration killed AFTER mark() but before its consume left both set — so
            // it can never be migrated back after a later reset durably clears the file marker
            // (Codex P2 on #385). Only while readable (a locked Class-C remove can't land); a no-op
            // when the key is already absent (the 1.2.5-native case).
            if UIApplication.shared.isProtectedDataAvailable {
                UserDefaults.standard.removeObject(forKey: Self.recoveryReseedBackupSuppressionKeyName)
            }
            return .present
        }
        guard UIApplication.shared.isProtectedDataAvailable else {
            return .absentUnconfirmed
        }
        if UserDefaults.standard.bool(forKey: Self.recoveryReseedBackupSuppressionKeyName) {
            // Migrate the legacy Class-C marker forward to the durable file, then CONSUME it — but
            // ONLY once the file marker is CONFIRMED on disk (`mark()` returns true). If the write
            // failed (app-group I/O / ENOSPC), KEEP the legacy key so the next launch retries:
            // deleting it on a failed mark would leave NO durable marker for the already-accepted
            // reseed library, and a relaunch would then lift the suppression and clobber the user's
            // last good backup (Codex P1 on #385). Consuming only after a confirmed mark also closes
            // the resurrection window (Codex P2 on #385) — the consume runs only here, while
            // protected data is readable, so the Class-C remove can land. Either way THIS session is
            // suppressed (.present): the legacy key said so.
            if ReseedSuppressionMarkerStore.mark(containerURL: containerURL) {
                UserDefaults.standard.removeObject(forKey: Self.recoveryReseedBackupSuppressionKeyName)
            }
            return .present
        }
        return .absentConfirmed
    }

    /// Whether a pre-unlock accept froze the reseed suppression because it could not read the
    /// legacy marker (`ReseedSuppressionMarkerState.absentUnconfirmed`). Re-derived — and cleared —
    /// once protected data is available (`confirmReseedSuppressionAfterUnlock`). Never persisted: a
    /// fresh launch re-evaluates from the markers.
    var reseedSuppressionAwaitingUnlockConfirmation = false

    /// Re-derive a reseed suppression that an accepted-library launch FROZE because the legacy
    /// Class-C marker was unreadable pre-first-unlock (the 1.2.4→1.2.5 upgrade-transition case,
    /// Codex P1 on #385). No-op unless such a freeze is pending and protected data is now readable;
    /// then the marker state is definitive (the file marker, or the now-readable legacy store
    /// migrated forward), so the suppression is set to its true value. Wired to the same first-unlock
    /// notification + foreground re-check as `reloadSharedStateIfBlockedByDataProtection`, since an
    /// accepted (readable) library never sets `sharedStateUnavailableAtLoad` and so never triggers
    /// that reload.
    /// - pinned: RebootFirstUnlockGuardSourceTests.testAcceptedLibraryHonorsDurableFileMarker
    func confirmReseedSuppressionAfterUnlock() {
        guard reseedSuppressionAwaitingUnlockConfirmation else { return }
        guard UIApplication.shared.isProtectedDataAvailable else { return }
        reseedSuppressionAwaitingUnlockConfirmation = false
        switch reseedSuppressionMarkerState() {
        case .present:
            libraryOriginatesFromLaunchReseed = true
        case .absentConfirmed:
            libraryOriginatesFromLaunchReseed = false
        case .absentUnconfirmed:
            // Unreachable: protected data is available here, so the read is always definitive. Keep
            // the conservative suppression if the platform ever regressed this guarantee.
            break
        }
    }

    // Re-runs the blocked launch load at first unlock (see sharedStateUnavailableAtLoad).
    private var protectedDataAvailableObserver: NSObjectProtocol?
    // Whether init was asked to manage VPN state (false for previews/tests). Stored so the
    // first-unlock recovery can rerun the launch tail it skipped (Codex P1 round 5 on #376).
    let loadsVPNState: Bool
    // Whether the last launch load READ AND DECODED app-configuration.json. Distinguishes
    // the pre-library build's legacy upgrade (config present, library file never existed —
    // the designed migration, no backup suppression) from a genuine fresh install (both
    // absent) in loadOrMigrateFilterLibrary (Codex P2 round 7 on #376).
    var configurationLoadedFromDisk = false
    // Sole owner of draft editing and preparation presentation.
    private(set) lazy var filterDrafts = FilterDraftController(context: self)
    // Transitional observation for remaining hub projections. Filter screens also
    // observe the owner directly; remove this forward when 1E retires those projections.
    private var filterDraftObservation: AnyCancellable?
    // Retains the switch target so "Try Again" retries the accepted kind of operation.
    var pendingSwitchFilterID: String? {
        get { filterDrafts.pendingSwitchFilterID }
        set { filterDrafts.pendingSwitchFilterID = newValue }
    }
    // Serializes EVERY wholesale config+library replacement — a filter switch, a backup restore,
    // a shared-config import, AND a My-filter draft apply — against one another. Each replacer
    // claims a token before its first await and re-checks it (1) before committing, (2) before its
    // post-persist side-effect tail, and (3) before any rollback; a newer claim supersedes an
    // older one, so the older bails instead of clobbering. persistSharedState ends in an artifact
    // actor-hop await, so re-check (2) is what stops a superseded loser's tail (applyCatalogSyncResult
    // rebuilds derived rule caches against the LIVE configuration) from desyncing caches vs the
    // newer owner's config and serializing wrong rules on the next persist. Main-actor only, so the
    // read-modify-write in begin() is not racy.
    var configurationReplacementGate = ExclusiveReplacementGate()
    // Whether the CURRENT preparation failure can be retried. A switch whose target was deleted
    // or frozen mid-prepare is a dead end (retrying re-fails), so it surfaces a non-retryable
    // failure; ordinary transient failures stay retryable.
    var filterPreparationFailureIsRetryable: Bool {
        get { filterDrafts.preparationFailureIsRetryable }
        set { filterDrafts.preparationFailureIsRetryable = newValue }
    }
    @Published var networkActivityLog = NetworkActivityLog()
    @Published var allowlistDraft = ""
    #if DEBUG || LAVA_QA_TOOLS
    @Published var qaProbeSuffixDraft = ""
    /// QA leak-rig (#8): the target resolver IP the operator arms the DNS leak canary against.
    @Published var leakCanaryResolverIPDraft = ""
    #endif
    @Published var lastAllowlistMessage: String?
    // Compatibility projections for native transactions while operation ownership
    // migrates in 1D. The controller is the sole stored draft/presentation owner.
    var filterEditTargetID: String? {
        get { filterDrafts.detailTargetID }
        set { filterDrafts.retarget(id: newValue, activeFilterID: activeFilterID) }
    }
    var filterPreparationState: FilterPreparationState {
        get { filterDrafts.preparationState }
        set { filterDrafts.preparationState = newValue }
    }
    var isFilterPreparationScreenPresented: Bool {
        get { filterDrafts.isPreparationPresented }
        set { filterDrafts.isPreparationPresented = newValue }
    }
    var filterPreparationOrigin: FilterReviewOrigin {
        get { filterDrafts.preparationOrigin }
        set { filterDrafts.preparationOrigin = newValue }
    }
    #if DEBUG || LAVA_QA_TOOLS
    @Published var adminQAStatusMessage: String?
    #endif
    // QA-only: the Device QA menu is gated solely by the build flag at its call
    // sites (the account-developer runtime probe / qa_developers allowlist was
    // retired). Kept a plain constant rather than a build-flag #if so the
    // internal-only flag never lands in tracked source (contamination guard);
    // every read of it is already compile-gated, so the value is never observed
    // in a public build.
    let isAccountDeveloper = true
    @Published var vpnStatus: NEVPNStatus = .invalid
    @Published var isVPNConfigurationInstalled = false
    @Published private(set) var isConfiguringVPN = false
    @Published var tunnelHealth = TunnelHealthSnapshot()
    @Published var chainedConfigurationStartIssue: ChainedConfigurationIssue?
    @Published var vpnMessage: String?
    @Published var vpnMessageIsError = false
    /// Projection of ``chainedConnectLifecycleState`` while the reducer is awaiting live-mode or
    /// forwarding evidence. It is never an independently mutated lifecycle authority.
    @Published var chainedProjection = ChainedConnectLifecyclePolicy.Projection()
    var chainedConnectEstablishing: Bool { chainedProjection.claim == .establishing }

    /// Projection of the reducer's unconfirmed claim. The tunnel stays up and monitored: an idle
    /// split tunnel may legitimately carry no non-DNS traffic until the user creates demand.
    var chainedForwardingUnconfirmed: Bool { chainedProjection.claim == .unconfirmed }
    var chainedSetupReady: Bool { chainedProjection.setupReady }
    /// Missing IPC after a prior proof is observation uncertainty, not a new user start.
    var chainedStatusChecking: Bool { chainedProjection.claim == .checking }
    var chainedSamplingConnection: UInt64?
    var chainedObservationLifetime = ChainedObservationLifetime()
    var chainedObservationActive: Bool { chainedObservationLifetime.isActive }
    var chainedApplicationLifecycleObservers = Set<AnyCancellable>()
    var chainedHandshakeQuerySequence: UInt64 = 0
    var chainedObservationDeadlineTask: Task<Void, Never>?
    var chainedObservationDeadlineGeneration: UInt64 = 0
    var chainedProjectionRevision: UInt64 = 0
    /// Discloses a degraded chained start (the tunnel is filtering DNS-only under a recorded
    /// refusal). Never a reason to turn protection off: the marker only informs the surface.
    /// Updated from ``updateProtectionStatus(from:)``'s already-read observation, so the Guard
    /// panel does not open the marker file on render.
    @Published var chainedStartupFailureNotice: String?
    var chainedForegroundEntryPrefetch = ChainedForegroundEntryPrefetch()
    var chainedForegroundEntryTask: Task<Void, Never>?
    var chainedForegroundEntrySession: NETunnelProviderSession?
    var chainedForegroundEntryMutationIdentity: ChainedLifecycleMutationIdentity?

    /// Reducer-owned notice lane. Lifecycle transitions never write or clear the shared
    /// ``vpnMessage``, so an unrelated app error cannot be lost to a reconnect or late promotion.
    var chainedLifecycleNotice: String? {
        if case .visible = chainedProjection.notice { return "Couldn't establish the VPN connection".lavaLocalized }
        return nil
    }

    /// Sole app-side authority for the chained-connect claim, sampling identity, arm token, and
    /// vanish notice. The published values above are projections updated after every reduction.
    var chainedConnectLifecycleState = ChainedConnectLifecyclePolicy.State()

    /// The reducer-tokened Connect-On-Demand arm. The handle preserves predecessor/drain ordering;
    /// the ID lets task completion clear only its own handle when a newer connection replaced it.
    var chainedOnDemandArmTask: Task<Void, Never>?
    var chainedOnDemandArmID: UInt64?
    /// True while a disable path is tearing protection down — from before the arm drain until
    /// after the on-demand disable has landed.
    ///
    /// A LATCH, not a one-time cancel, and the difference is what the first two attempts missed.
    /// Draining the arms says nothing about the thing that MAKES arms, so the drain first
    /// cancelled the establishment gate — but that cancel is a moment, and this method suspends:
    /// while the drain awaits a task the main actor is free, so a `.connected → .reasserting →
    /// .connected` transition runs the status observer and starts a NEW gate after the cancel.
    /// That gate then succeeds while the disable is suspended on its own save, passes its guards
    /// (`protectionEnabled` and `vpnStatus` are still true until the disable lands), and re-arms
    /// the profile behind the turn-off (Codex P1, PR #602, second round).
    ///
    /// AND IT REPLACES THE GATE CANCEL RATHER THAN JOINING IT. Cancelling the gate from the drain
    /// also cleared `chainedConnectEstablishing`, which the gate's own fail-closed shutdown kept
    /// ASSERTED so the surface never reverted to "Protected" over a dead chain. The drain ran
    /// inside that shutdown, so the cancel was undoing the presentation it was supposed to leave
    /// alone (Codex P2, PR #602). Suppressing the two PRODUCERS instead touches no presentation
    /// state at all. That shutdown is gone as of PR #629 — the gate no longer turns anything off —
    /// but the reasoning holds for every other teardown that drains, which is all of them.
    ///
    /// A DEPTH, NOT A FLAG, because teardowns nest. The gate's own shutdown used to bypass the
    /// orchestrator once its claim attempts were exhausted and start a SECOND `disableProtection()`
    /// while a slow turn-off or reconnect was still running. With a Bool, both set the same value
    /// and whichever finished first cleared it — reopening both producers while the other disable
    /// was still suspended, which is the very race this closes (Codex P2, PR #602). Counting makes
    /// the latch hold until the LAST teardown leaves. PR #629 removed that particular second
    /// teardown; nesting still arises from the reconnect and turn-off paths, so the depth stays.
    ///
    /// Balanced by `defer` at the scope that entered it, so no early return, throw or cancellation
    /// can strand it — a stuck latch would silently stop Connect-On-Demand ever arming again,
    /// which is a worse failure than the race it closes. `@MainActor`-confined, so the
    /// increment/decrement pair needs no atomicity beyond that.
    /// pinned: ProtectionOnDemandSourceTests.testTeardownDepthEdgesSuspendTheReducerBeforeAnyAwait
    var protectionTeardownDepth = 0
    var isTearingDownProtection: Bool { protectionTeardownDepth > 0 }
    // One-shot signal that a review anchor was earned. RootView observes it and, once the scene is
    // active, issues the native `requestReview` (which iOS may or may not display) and records the
    // budget spend via `markReviewRequestPresented`. Stays armed while the app is not active so a
    // request armed from an async path off-screen is never dropped-yet-charged. The eligibility
    // decision lives in ReviewPromptPolicy — this holds only the fire signal.
    // Design: lavasec-infra/plans/2026-07-16-app-store-review-prompt-plan.md
    @Published var pendingReviewRequest = false
    @Published var temporaryProtectionPauseUntil: Date?
    // The customization-preference @Published state (appearance, text size, LavaGuard
    // look, app icon, Live-Activities toggle + pause length, the haptics toggle, and the
    // Customization → Notifications mirrors) lives on `customization`
    // (CustomizationController) since the Phase D5 customization peel — same pattern as
    // the D1–D4 controllers below. `lavaGuardProgress` stays HERE: the usage-accrual
    // engine (synchronizeLavaGuardProgress) and the diagnostics-driven refresh write it,
    // and the controller only reads it through the bridge for availability rows.
    @Published var lavaGuardProgress = LavaGuardProgress()
    // The hidden Sudoku easter egg's resumable board. Persisted under the same `keepLavaGuardProgress`
    // local-log toggle as the usage progress above: while on, an in-progress game is saved and resumed
    // (and a solved board is replaced by a fresh one on next entry); turning the toggle off clears it.
    // The puzzle engine + Codable state live in LavaSecKit; this hub owns only the load/persist/clear
    // orchestration, mirroring `lavaGuardProgress` directly below.
    @Published var sudokuGameState: SudokuGameState?
    @Published var catalogStatusMessage = "Filter will update from Lava Security's source catalog."
    @Published var catalogStatusIsError = false
    @Published var catalogVersion: String?
    @Published var catalogGeneratedAt: Date?
    @Published var compiledRuleCount = 0
    @Published var protectedRuleCount = 0
    @Published var compiledBlocklistRuleCount = 0
    // The backup @Published state (encryptedBackupState, isBackingUpNow,
    // isBackupMaintenanceInProgress, isAutomaticBackupEnabled) lives on `backup`
    // (BackupController), which views observe as its own environment object.
    // The LavaSecurity+ billing @Published state (offers, product-load / entitlement-check /
    // purchase flags, expiry, paywall messages) lives on `plus` (LavaSecurityPlusController)
    // since the Phase D2 billing peel — same pattern.
    // The account @Published state (auth state, per-provider sign-in progress, status
    // messages, deletion progress) lives on `account` (AccountController) since the
    // Phase D3 account peel — same pattern.
    // The diagnostics @Published state (the DiagnosticsStore, the rage-shake
    // destination/confirmation, the bug-report draft + send state) lives on `reports`
    // (DiagnosticsController) since the Phase D4 diagnostics/bug-report peel — same
    // pattern. The hub still writes `reports.diagnostics` from its own uptime/demo
    // paths (see the property's comment there).

    var blockRules = DomainRuleSet()
    var threatGuardrail = DomainRuleSet()
    var cachedBlockRuleSets: [String: DomainRuleSet] = [:]
    var localCustomRuleCounts: [String: LocalFilterRuleCount] = [:]
    /// True while a warm (instant) switch has published the target filter but its background per-source
    /// cache rehydration (`rehydrateRuleSetCachesAfterWarmSwitch`) hasn't completed — so
    /// `cachedBlockRuleSets` still describes the PREVIOUS filter. Per-source caches are keyed by source
    /// id and filter-independent, so they never hold WRONG rules — but they OMIT the target filter's
    /// sources the previous filter didn't have, so an in-place edit that rebuilds `blockRules` from
    /// them and re-publishes would publish an UNDER-COVERING snapshot for the target filter (Codex
    /// #133). In-place edits therefore defer while this is set. Set in the warm-switch branch; cleared
    /// by `applyCatalogSyncResult` — the chokepoint every FRESH-cache load funnels through (the warm
    /// rehydration, a cold switch / import / draft-apply, or any catalog sync) — and explicitly by
    /// `restoreFiltersToDefault` (which supersedes the warm switch and drives its own coverage). A
    /// superseding path that does NOT refresh the caches (backup restore; a failed switch's rollback)
    /// correctly leaves it set — the caches really are stale for the now-active filter — and it
    /// self-heals on the next fresh-cache load (it's in-memory, so it also resets each launch). (The
    /// multi-filter UI edits via drafts today, so this guards a latent path + the deferred
    /// in-place-edit follow-up.)
    var hasPendingWarmSwitchCacheRehydration = false
    var catalogSourcesByID: [String: CatalogBlocklistSource] = [:]
    /// Separate publication snapshot for new imports; installed-list caches never grant availability.
    @Published var sharedImportCatalogSourcesByID: [String: CatalogBlocklistSource]?

    /// Summed entry counts of the catalog's `guardrails[]` sources, or 0 when no catalog is loaded.
    ///
    /// Held SEPARATELY from `catalogSourcesByID` rather than merged into it: that map is the app's
    /// picker inventory (`availableSourceIDs`, the per-list entry counts, the enabled-source lookups),
    /// and guardrails are a distinct tier the user never selects — folding them in would put them in
    /// front of the user. This exists only so `estimatedRuleCount` can size the guardrail work every
    /// compile does (PR #646).
    var catalogGuardrailEntryCount = 0

    var currentCatalog: BlocklistCatalog?
    var tunnelManager: NETunnelProviderManager?
    private var vpnStatusObserver: NSObjectProtocol?
    private var tunnelHealthNudgeObserver: DarwinNotificationObserver?
    // Foreground-only: the headless Focus warm-switch posts this Darwin nudge after recording a
    // deferred switch so the foreground reconciles the pending-switch marker promptly (LAV-100 P3).
    private var focusPendingSwitchObserver: DarwinNotificationObserver?
    // Re-entrancy guard for reconcilePendingFilterSwitch — onAppear, scene .active, and the Darwin
    // nudge can all fire it, and overlapping runs would launch duplicate switchToFilter attempts.
    // These two flags are unsynchronized Bools BY DESIGN: the guard's correctness relies on every
    // access being @MainActor-confined (this class is @MainActor; the Darwin observer hops via
    // `Task { @MainActor in … }` before touching reconcile). A future off-actor read/write of either
    // flag would silently break the serialization (review P3-4).
    var isReconcilingPendingFilterSwitch = false
    // Set when a wake trigger arrives while a reconcile is in flight, so the in-flight run loops once
    // more — a newer marker recorded during a (possibly slow cold-compile) apply isn't stranded until
    // the next scene-phase event.
    var pendingReconcileRerun = false
    // Coalesces the non-active warm pass: it is triggered on BOTH onAppear and scene .active (and after a
    // catalog apply), which can overlap; a concurrent second pass would redundantly re-scan + double-compile
    // the same cold filters. @MainActor-confined, like the reconcile flags above.
    var isReconcilingWarmNonActiveFilters = false
    // Set when a warm-reconcile trigger arrives while one is already in flight, so the in-flight run loops
    // once more instead of DROPPING the new trigger. The trigger that matters is a catalog apply landing
    // mid-pass: the in-flight pass may have already judged tokens against the OLD catalog (or discarded a
    // compile when its recheck saw the move), so without a rerun the non-active filters can stay cold/stale —
    // and a closed-app Focus switch to them defers-to-cold instead of landing warm, defeating the
    // warm-after-install/catalog goal this serves (Codex P2). Mirrors `pendingReconcileRerun`.
    var pendingWarmReconcileRerun = false
    // True while a genuine USER-initiated switchToFilter (stampsForegroundSwitch == true) is in flight, from
    // entry until it commits-or-fails. The Focus reconcile reads this and DEFERS rather than applying a marker
    // via its own switchToFilter, which would begin a newer replacement epoch and make the user's in-flight
    // switch bail as superseded — letting an OLDER Focus request win over the user's newer manual choice. The
    // stamp (lastForegroundSwitch) can't cover this: it lands only AFTER the manual switch succeeds, so it is
    // still nil/old while the switch is preparing (Codex round-18). @MainActor-confined, like the reconcile flags.
    var isForegroundManualSwitchInFlight = false
    // (The foreground-active scene flag + its 60s heartbeat were REMOVED 2026-06-29 — the headless switch is
    // state-agnostic now, so nothing reads a foreground-active hint. See HeadlessFocusFilterSwitchEngine.)
    private let vpnConfigurationName = LavaTunnelConfigurationIdentity.currentDisplayName
    let protectionStatusRefreshInterval: TimeInterval = 8
    let catalogSyncFreshnessInterval: TimeInterval = 7 * 24 * 60 * 60
    private let activeProtectionSessionIDDefaultsKey = LavaSecAppGroup.protectionActiveSessionIDDefaultsKey
    // The customization-preference defaults keys moved to CustomizationController with
    // their setters (Phase D5); only the progress key stays with the hub-owned accrual.
    let lavaGuardProgressDefaultsKeyName = "lavasec.customization.lavaGuardProgress"
    // Same UserDefaults as `lavaGuardProgress`: the easter egg rides the local-log toggle, so its
    // key lives beside the progress key and clears alongside it.
    let sudokuGameStateDefaultsKeyName = "lavasec.easterEgg.sudoku"
    let defaults = UserDefaults.standard
    let appGroupDefaults = LavaSecAppGroup.sharedDefaults
    // Single source of truth for session and pause state, shared with the
    // tunnel and the intents process via the same app-group keys.
    lazy var protectionSessionStore = ProtectionSessionStore(
        storage: ProtectionUserDefaultsStorage(defaults: appGroupDefaults),
        lock: ProtectionNSLock()
    )
    // The temporary-pause state machine (store + resume timer + legacy mirror
    // cleanup) lives in TemporaryProtectionPauseController; AppViewModel keeps the
    // @Published mirror and the pause/resume orchestration.
    lazy var pauseController = TemporaryProtectionPauseController(appGroupDefaults: appGroupDefaults)
    // Explicit user direction for automatic restores. Unlike configuration.protectionEnabled, status
    // observation never rewrites this value. The revision invalidates work captured before a newer
    // accepted turn-off/toggle/reconnect (including a same-direction reconnect).
    var userProtectionIntent = ProtectionRestoreIntentState(isEnabled: false)
    @Published var chainedSettingsApplyState = ProtectionSettingsApplyState()
    @Published var chainedSettingsApplyError: String?
    var chainedSettingsApplyTask: Task<Void, Never>?
    // Single-flight gate for protection actions; isConfiguringVPN is the
    // published UI mirror and has no other writers.
    private var protectionActionPresentation = ProtectionActionPresentation()
    lazy var protectionActionOrchestrator = ProtectionActionOrchestrator { [weak self] kind in
        guard let self else { return }
        let currentTitle = self.protectionButtonTitle
        self.protectionActionPresentation.update(action: kind, currentTitle: currentTitle)
        self.isConfiguringVPN = kind != nil
    }
    /// Uses the tunnel's narrowly scoped resolver fallback when fail-closed DNS prevents recovery.
    func makeBootstrapAwareCatalogDataFetcher() -> BlocklistCatalogDataFetcher {
        BlocklistCatalogSynchronizer.bootstrapAwareDataFetcher { [weak self] hostname in
            await self?.resolveBootstrapHostThroughTunnel(hostname)
        }
    }

    lazy var filterSnapshotPreparationService: FilterSnapshotPreparationService? =
        catalogCacheURL.map { cacheURL in
            // The bootstrap-aware fetcher is what lets a fail-closed device repair itself. Its
            // ladder only engages on `URLError.cannotFindHost` — the sinkhole shape — so in
            // every ordinary run this is byte-for-byte the default fetch path.
            FilterSnapshotPreparationService(
                cacheDirectoryURL: cacheURL,
                dataFetcher: makeBootstrapAwareCatalogDataFetcher())
        }

    /// Bridges the package's `BootstrapAddressBroker` to the live tunnel session.
    ///
    /// Returns `nil` — "no help available" — whenever there is no running session, which is the
    /// ordinary case. The tunnel refuses the request unless it is genuinely fail-closed, so
    /// this cannot become a general-purpose resolver even if it were called elsewhere.
    private func resolveBootstrapHostThroughTunnel(
        _ hostname: String
    ) async -> (ipv4: [String], ipv6: [String])? {
        #if targetEnvironment(simulator)
        return nil
        #else
        guard let session = tunnelManager?.connection as? NETunnelProviderSession,
            isProtectionEnabledStatus(session.status),
            let resolution = await BootstrapHostResolveBroker.resolve(
                hostname: hostname, session: session),
            !resolution.isEmpty
        else {
            return nil
        }
        logVPNDebugEvent("bootstrap-broker-used", details: [
            "ipv4Count": "\(resolution.ipv4.count)",
            "ipv6Count": "\(resolution.ipv6.count)",
        ])
        return (ipv4: resolution.ipv4, ipv6: resolution.ipv6)
        #endif
    }
    var didAttemptDNSRouteEnforcementMigration = false
    lazy var vpnLifecycleController = VPNLifecycleController(
        repository: NETunnelManagerRepository(
            providerBundleIdentifier: tunnelProviderBundleIdentifier,
            configurationName: vpnConfigurationName,
            dnsPatchEnabled: { [weak self] in self?.configuration.dnsPatchEnabled ?? false },
            enforcesDNSRoutes: { [weak self] in self?.shouldEnforceDNSRoutes ?? false },
            includesAllNetworks: { [weak self] in self?.shouldIncludeAllNetworksForQA ?? false }
        ),
        statusWaiter: ProtectionStatusChangeWaiter(),
        expectedProviderBundleIdentifier: tunnelProviderBundleIdentifier,
        waitPolicy: .init(statusPollInterval: Self.protectionStopStatusRefreshInterval),
        emitEvent: { [weak self] event, details in
            #if DEBUG || LAVA_QA_TOOLS
            self?.logVPNDebugEvent(event, details: details)
            #endif
        }
    )
    // CatalogController owns only single-flight/cancellation and sync-specific presentation.
    // The whole publication/recovery/protection transaction remains in this hub through the
    // one-method bridge. Lazy construction wires the weak bridge after self is initialized;
    // headless background-refresh instances use the same ownership path.
    private(set) lazy var catalog = CatalogController(hub: self)
    // The account/sign-in feature (the Apple/Google sign-in flows, sign-out, deletion,
    // the account presentation state, and ownership of AccountAuthService — the ONE
    // canonical Supabase identity) lives in AccountController (Phase D3, same plan).
    // Cross-feature reactions stay hub-orchestrated through the AccountHubBridging
    // conformance in AppViewModel+HubBridges.swift, and the backup/plus bridges reach the
    // session by delegating through this controller. Lazy so `self` is fully
    // initialized when the bridge is wired; on the HEADLESS instances (background
    // catalog refresh) nothing touches it — the pre-peel hub constructed
    // AccountAuthService eagerly in init, but that init is a pure keychain-session
    // read, so deferring construction to first use changes no behavior there.
    private(set) lazy var account = AccountController(hub: self)
    // The encrypted-backup feature (envelope persistence, crypto orchestration, passkey
    // setup, upload/restore, the automatic-backup debounce) lives in BackupController
    // (Phase D1, lavasec-infra plans/2026-07-07-ios-modularization-scaffolding-plan.md).
    // The hub stays the owner of the library / replacement gate — the controller reaches
    // them, and the AccountController-owned session (Phase D3), only through the
    // BackupHubBridging conformance in AppViewModel+HubBridges.swift. Lazy so `self` is fully
    // initialized when the bridge is wired; on the HEADLESS instances (background catalog
    // refresh) nothing touches it — those paths never persist shared state — matching the
    // pre-peel always-present-but-never-loaded backup fields.
    private(set) lazy var backup = BackupController(
        hub: self,
        supabaseConfiguration: account.supabaseConfiguration
    )
    // The LavaSecurity+ billing/paywall feature (the local LavaSecurityPlusStore's
    // product + entitlement boundary, purchase/restore, the server entitlement sync)
    // lives in LavaSecurityPlusController (Phase D2, same plan). The hub stays the
    // owner of the configuration/paid flag and the Supabase session — the controller
    // reaches them only through the LavaSecurityPlusHubBridging conformance in
    // AppViewModel+HubBridges.swift. Lazy so `self` is fully initialized when the bridge is
    // wired; on the HEADLESS instances (background catalog refresh) nothing touches
    // it — `plus.startLavaSecurityPlusStore()` is gated behind `!headless` below, so
    // the entitlement listener (→ persistConfigurationOnly) never installs there.
    private(set) lazy var plus = LavaSecurityPlusController(hub: self)
    // The diagnostics + bug-report/rage-shake feature (the DiagnosticsStore read/prune
    // lifecycle, local-log clears, keep-flags, bug-report draft/send, rage-shake
    // routing) lives in DiagnosticsController (Phase D4, same plan). The hub stays the
    // owner of the configuration, tunnel messaging, VPN status, network-activity log,
    // and LavaGuard progress — the controller reaches them only through the
    // DiagnosticsHubBridging conformance in AppViewModel+HubBridges.swift, while the hub's
    // own uptime/demo paths keep writing `reports.diagnostics` directly (hub→controller
    // is the allowed direction). Lazy so `self` is fully initialized when the bridge is
    // wired; construction is side-effect free (an empty DiagnosticsStore + value
    // defaults), and on the HEADLESS instances (background catalog refresh) nothing
    // touches it — matching the pre-peel always-present-but-never-refreshed
    // diagnostics fields.
    private(set) lazy var reports = DiagnosticsController(hub: self)
    // The customization-preference feature (appearance, text size, LavaGuard look +
    // app icon + the icon personalizer seam, Live-Activities toggle/pause length,
    // haptics toggle, notification-category mirrors, and the launch preference load)
    // lives in CustomizationController (Phase D5, same plan). The hub stays the owner
    // of the configuration (Plus flag / unlock ledger / keep-progress), the LavaGuard
    // progress accrual, the Live Activity reconcile machinery, and the protection-
    // outcome haptic play path — the controller reaches them only through the
    // CustomizationHubBridging conformance in AppViewModel+HubBridges.swift. Lazy so `self`
    // is fully initialized when the bridge is wired; construction is side-effect free
    // (value defaults only), and on the HEADLESS instances (background catalog refresh)
    // nothing touches it — `customization.loadCustomizationPreferences()` is gated
    // behind `!headless` below, so the load-time app-group writes (persistLavaGuardLook
    // / syncAppIcon / the Live-Activities clamp) never run there, matching the pre-peel
    // gating of loadCustomizationPreferences.
    private(set) lazy var customization = CustomizationController(hub: self)
    let protectionUserNotifications: any ProtectionNotificationPresenting
    let liveActivityController: AmbientProtectionPresenter
    let protectionStatusRefreshCoordinator = ProtectionStatusRefreshCoordinator()
    var lastProtectionStatusRefresh: Date?
    var awaitsProtectionOnHaptic = false
    /// Persistent reducer-scoped runtime sampler. It starts with an immediate observation, polls at
    /// establishment cadence until the first claim resolves, then continues at the lower monitoring
    /// cadence so runner loss, generation replacement, and counter reset can revoke confirmation.
    var chainedLifecycleSamplingTask: Task<Void, Never>?

    /// Cross-process identity captured synchronously for one reducer connection. Delayed arm and
    /// initial-resolution work must still match this connection, sticky user-intent revision, and
    /// direct-Restart generation after acquiring the shared mutation fence.
    struct ChainedLifecycleMutationIdentity: Equatable {
        let connection: UInt64
        let protectionIntentRevision: UInt64
        let externalRestartGeneration: ProtectionExternalRestartGenerationSnapshot?
    }

    var chainedLifecycleMutationIdentity: ChainedLifecycleMutationIdentity?
    // The diagnostics read gate + deferred-prune flag moved to DiagnosticsController
    // with the store's refresh lifecycle (Phase D4 peel).
    var tunnelHealthReadGate = FileModificationReadGate()
    var networkActivityLogReadGate = FileModificationReadGate()

    @Published var sourceStates: [String: SourceSyncState] = [
        DefaultCatalog.blockListProjectBasic.id: .pendingSourceUpdate,
        DefaultCatalog.blockListProjectPhishing.id: .pendingSourceUpdate,
        DefaultCatalog.blockListProjectScam.id: .pendingSourceUpdate,
        DefaultCatalog.blockListProjectRansomware.id: .pendingSourceUpdate,
        DefaultCatalog.phishingDatabaseActive.id: .pendingSourceUpdate,
        DefaultCatalog.hageziMultiLight.id: .pendingSourceUpdate,
        DefaultCatalog.hageziMultiNormal.id: .pendingSourceUpdate,
        DefaultCatalog.hageziMultiProMini.id: .pendingSourceUpdate,
        DefaultCatalog.hageziMultiPro.id: .pendingSourceUpdate,
        DefaultCatalog.oisdSmall.id: .pendingSourceUpdate
    ]

    init(loadVPNState: Bool = true, headless: Bool = false, platformServices: LavaAppPlatformServices? = nil) {
        let services = platformServices ?? .live()
        protectionUserNotifications = services.protectionNotifications
        liveActivityController = services.ambientProtection

        isHeadless = headless
        loadsVPNState = loadVPNState
        if loadVPNState && !headless { startObservingChainedApplicationLifecycle() }
        filterDraftObservation = filterDrafts.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }

        loadPersistedConfiguration()
        recoverUserProtectionIntentFromDurableState()
        #if DEBUG || LAVA_QA_TOOLS
        applyLiveDNSSmokeTestConfigurationIfRequested()
        // Here, NOT in a view's `onAppear`. `devicectl device process launch` can start the
        // app without a foreground scene — on a locked device it stays backgrounded and no
        // SwiftUI view ever appears — so a UI-hosted hook silently does nothing and looks
        // exactly like the arguments not arriving. Model startup runs either way.
        // Skipped for headless instances (the background catalog refresh builds one).
        if !headless {
            Task { @MainActor in await self.applyQALaunchOverrides() }
        }
        #endif
        // The background catalog refresh runs on a HEADLESS instance and must install no
        // side-effecting init work. Beyond loadPersistedConfiguration() above (a pure
        // read), every call here either writes shared state or schedules work that does,
        // any of which could clobber state the foreground/intents process owns:
        //   • plus.startLavaSecurityPlusStore  — entitlement listener → persistConfigurationOnly
        //     (via the LavaSecurityPlusHubBridging paid-plan persist)
        //   • customization.loadCustomizationPreferences — persistLavaGuardLook / syncAppIcon /
        //     defaults.set (app-group)
        //   • loadTemporaryProtectionPause      — pauseController.onPauseCleared() removes the app-group
        //     pause keys, so a bg refresh seeing no pause would clear one the foreground just wrote
        //     (read→cleanup race)
        //   • scheduleTemporaryProtectionResume — resumes protection
        //   • live-activity authorization observer — reconcile churn
        // Protected preference loading also waits for first unlock: customization and
        // a confirmed backup deletion can write preferences; missing progress is provisional.
        // The headless sync/publish path re-reads live config and depends on none of these.
        if !headless {
            plus.startLavaSecurityPlusStore()
            loadProtectedPreferencesIfAvailable()
            loadTemporaryProtectionPause()
            scheduleTemporaryProtectionResume()
            // One-shot disk maintenance: superseded parsed-rules version trees. A parser
            // bump orphans the whole previous tree and nothing else deletes it (up to
            // 2 entries x ~40 MB per large source). Foreground app only — the headless
            // bg-refresh instance installs no side-effecting init work (see the comment
            // above), and the extension deliberately avoids maintenance IO. Detached
            // utility task so init never blocks on disk.
            if let sweepCacheURL = catalogCacheURL {
                Task.detached(priority: .utility) {
                    RuleSetCache(cacheDirectoryURL: sweepCacheURL).sweepSupersededVersionTrees()
                }
            }
            liveActivityController.startObservingAuthorizationChanges { [weak self] _ in
                self?.reconcileLiveActivity()
            }
            // A headless Focus switch that deferred (app was active) posts this nudge so the
            // foreground applies the pending-switch marker promptly, rather than waiting for the
            // next scene-phase reconcile. Delivered to the foreground app only (the headless poster
            // runs in this same app's background process), so it is the correct channel here.
            focusPendingSwitchObserver = DarwinNotificationObserver(
                name: FocusFilterSwitchSignal.darwinNotificationName
            ) { [weak self] in
                Task { @MainActor in
                    await self?.reconcilePendingFilterSwitch()
                }
            }
            // INV-PERSIST-1 recovery: a process launched between reboot and first unlock
            // (prewarm) reads the Class-C-protected shared pair as existing-but-unreadable;
            // this notification fires at first unlock — the exact moment the content becomes
            // readable — so the blocked launch load re-runs against the user's real files.
            // The reload itself is guarded (no-op unless the load was blocked), and
            // setAppForegroundActive re-checks on every foreground as a belt-and-braces
            // catch for a notification delivered before this observer registered.
            protectedDataAvailableObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.protectedDataDidBecomeAvailableNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.reloadSharedStateIfBlockedByDataProtection()
                    self?.loadProtectedPreferencesIfAvailable()
                    if UIApplication.shared.isProtectedDataAvailable {
                        self?.backup.refreshUnavailableBackupStateAfterUnlock()
                    }
                    // Also lift an upgrade-transition suppression freeze now that the legacy
                    // marker is readable (Codex P1 on #385); an accepted library never sets
                    // sharedStateUnavailableAtLoad, so the reload above is a no-op for it.
                    self?.confirmReseedSuppressionAfterUnlock()
                }
            }
        }

        if loadVPNState {
            Task {
                if !hasCompletedOnboarding {
                    // Onboarding is not finished, so the user has not chosen to
                    // enable protection. Tear down any inherited VPN config (a
                    // reinstall over an existing profile, or a stale on-demand
                    // config iOS kept after a delete) FIRST — before any
                    // network-bound catalog work — so a fail-closed cold tunnel
                    // that iOS already brought up cannot linger mid-onboarding
                    // (block traffic / show filters red). (See the method.)
                    //
                    // INV-PERSIST-1 sibling guard (pinned: RebootFirstUnlockGuardSourceTests.testOnboardingNeutralizeIsGatedOnProtectedDataAvailability):
                    // hasCompletedOnboarding reads UserDefaults.standard, which is ALSO
                    // Data-Protection-locked between reboot and first unlock — a prewarmed
                    // launch can read `false` here for a fully onboarded user, and the
                    // neutralize below would then STOP and REMOVE their real VPN profile.
                    // Only trust a "not onboarded" read taken while protected data is
                    // actually readable. Residual: a genuine fresh install prewarmed
                    // pre-unlock skips this one-shot neutralize (the rare
                    // reinstall-over-profile lingering-tunnel cosmetic it prevents), which
                    // is the right side of the trade against uninstalling live protection.
                    if UIApplication.shared.isProtectedDataAvailable {
                        await neutralizeInheritedProtectionDuringOnboarding()
                    }
                }
                await loadCachedCatalogIfAvailable()
                await syncCatalogIfStale()
                if hasCompletedOnboarding {
                    // Connect-On-Demand may have already brought the tunnel up cold
                    // at launch; make sure it has a usable snapshot (see the method).
                    await reconcileTunnelSnapshotAfterLaunch()
                }
            }

            #if targetEnvironment(simulator)
            vpnMessage = "VPN testing requires a physical device."
            vpnMessageIsError = false
            #else
            vpnStatusObserver = NotificationCenter.default.addObserver(
                forName: .NEVPNStatusDidChange,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    guard let self else {
                        return
                    }

                    // The notification already carries the change: read the
                    // cached manager's live connection instead of forcing a
                    // manager reload. loadAllFromPreferences itself re-posts
                    // NEVPNStatusDidChange, so a forced refresh here fed a
                    // self-sustaining storm (measured ~370 events/s on device,
                    // the source of the 134% CPU heat regression).
                    if self.tunnelManager != nil {
                        self.updateProtectionStatusFromCachedManager()
                    } else {
                        await self.refreshProtectionStatus(force: true)
                    }
                }
            }

            // The tunnel posts this Darwin nudge when its connectivity-relevant
            // health changes (reconnecting / network lost / needs-reconnect).
            // NEVPNStatus stays `.connected` through those, so without the nudge
            // the Dynamic Island only caught up on the next status poll. Pull the
            // fresh health over the reliable provider-message channel in response
            // (UR-6).
            tunnelHealthNudgeObserver = DarwinNotificationObserver(
                name: TunnelHealthSignal.darwinNotificationName
            ) { [weak self] in
                Task { @MainActor in
                    self?.handleTunnelHealthNudge()
                }
            }

            Task {
                await refreshProtectionStatus(force: true)
                await resumeTemporaryProtectionIfExpired()
            }
            #endif

            #if DEBUG
            logVPNDebugEvent("app-init", details: [
                "bundleIdentifier": Bundle.main.bundleIdentifier ?? "unknown",
                "arguments": ProcessInfo.processInfo.arguments.joined(separator: " ")
            ])

            if Self.isVPNDebugProbeRequested {
                Task { [weak self] in
                    await self?.runVPNStartupDebugProbe()
                }
            }
            #endif
        }
    }

    deinit {
        // backup (BackupController) cancels its own automatic-backup task in its deinit;
        // pauseController cancels its own resume timer in its deinit; plus's
        // LavaSecurityPlusStore cancels its Transaction.updates task in ITS deinit.
        // The block-based protectedDataAvailableObserver is deliberately NOT removed here (OCR
        // flagged the token as unremoved on the 1.2.4 sync): it captures [weak self], so once
        // this @MainActor singleton deallocates the block just fires as a harmless no-op, and
        // reading the non-Sendable `NSObjectProtocol` token from this nonisolated deinit does
        // not compile under Swift 6 strict concurrency anyway (confirmed by the app-compile
        // gate). The weak capture IS the cleanup. focusPendingSwitchObserver is a
        // DarwinNotificationObserver that unregisters in its own deinit.
        Task { @MainActor [liveActivityController] in
            liveActivityController.stopObservingAuthorizationChanges()
        }
    }

    #if DEBUG || LAVA_QA_TOOLS
    private func applyLiveDNSSmokeTestConfigurationIfRequested() {
        guard Self.isLiveDNSSmokeTestRequested else {
            return
        }

        configuration.enabledBlocklistIDs = []
        configuration.allowedDomains = []
        configuration.blockedDomains = []
        configuration.customBlocklists = []
        configuration.qaProbeSet = .hosted
        if let customResolverAddress = Self.liveDNSSmokeCustomResolverOverride {
            configuration.resolverPresetID = DNSResolverPreset.customID
            configuration.customResolverAddress = customResolverAddress
        } else {
            let liveDNSSmokeResolverPresetID = Self.liveDNSSmokeResolverPresetIDOverride ?? DNSResolverPreset.google.id
            configuration.resolverPresetID = liveDNSSmokeResolverPresetID
            configuration.customResolverAddress = nil
        }

        configuration.customResolverSecondaryAddress = nil
        configuration.customResolverName = nil
        configuration.fallbackToDeviceDNS = true
        configuration.keepFilteringCounts = true
        configuration.keepDomainDiagnostics = true
        configuration.keepNetworkActivity = true
        rebuildEnabledBlockRules()
        try? persistConfigurationOnly()
        vpnMessage = "Live DNS smoke probes are active."
        vpnMessageIsError = false
        adminQAStatusMessage = "Live DNS smoke probes are active."
        logVPNDebugEvent("live-dns-smoke-configuration-persisted", details: [
            "resolverPresetID": configuration.resolverPresetID,
            "customResolverAddress": configuration.customResolverAddress ?? "nil",
            "resolverTransport": configuration.resolverPreset.transport.rawValue
        ])
    }
    #endif

    // The LavaSecurity+ paywall & billing feature (product/offer loading, entitlement
    // refresh, purchase/restore, the store lifecycle + server entitlement sync) lives
    // in LavaSecurityPlusController.swift (Phase D2 billing peel) — this hub keeps only
    // the LavaSecurityPlusHubBridging conformance in AppViewModel+HubBridges.swift.

    // The customization-preferences feature (the `MARK: - Customization preferences`
    // region — appearance/text-size/LavaGuard-look/icon/Live-Activities/haptics setters,
    // the availability derivations, customizationSummaryText/preferredColorScheme, and
    // the preference load + notification-category toggles) lives in
    // CustomizationController.swift (Phase D5 customization peel) — this hub keeps only
    // the CustomizationHubBridging conformance in AppViewModel+HubBridges.swift.

    var canOfferLiveActivities: Bool {
        liveActivityController.canOfferLiveActivities
    }

    /// The tunnel is DOWN (`.disconnected`) but Connect-On-Demand is confirmed armed, so iOS will
    /// bring it back on its own once a network path returns (e.g. leaving an elevator). This is NOT a
    /// fully-off state — the user did not turn protection off — so the surface must read "Reconnecting",
    /// never the fully-off "Turn On". Without this the transient-but-armed drop mapped to the `default`
    /// (Protection Off) branch and showed a [Turn On] button while a self-reconnect was pending.
    /// A terminal chained start refusal is the exception. A network-recoverable surrender
    /// keeps its armed reconnect because the provider can continue filtering in DNS-only mode. The marker
    /// is cleared only by an explicit Guard start/reconnect or a successful provider start.
    /// A marker read can be transiently unavailable while another process is replacing the
    /// control-plane file. That is a fail-closed condition for automatic restore, but it is
    /// deliberately NOT a confirmed terminal refusal: projecting OFF and recording user intent
    /// before the reason is actually readable would disarm a healthy on-demand profile because
    /// of a short lock/read hiccup.
    var chainedStartupFailureMarkerObservation: ChainedStartupFailureMarker.Observation {
        guard let markerURL = LavaSecAppGroup.chainedStartupFailureMarkerURL else {
            return .unavailable
        }
        return ChainedStartupFailureMarker.observation(
            from: markerURL,
            lockURL: LavaSecAppGroup.chainedStartupFailureMarkerLockURL)
    }

    var isAwaitingOnDemandReconnect: Bool {
        // The CHEAP term first, and not as an optimisation — the same rule
        // `vpnChainingSummaryText` states for its own row. This property feeds
        // `protectionStatusText`, the status icon and the mascot state, so it is read on
        // ordinary SwiftUI body passes, and the marker read below opens an App Group file
        // under a bounded `flock`, on the main actor. Paying that per render would both
        // stutter the surface and contend for the very lock `startTunnel` must take to read
        // its start gate — and losing that 0.25s wait makes the provider REFUSE to start.
        // The two terms are ANDed either way, so ordering changes cost, never the answer.
        guard ProtectionLifecyclePolicy.isAwaitingOnDemandReconnect(
            status: vpnStatus.protectionLifecycleStatus,
            onDemandConfirmedEnabled: Self.isOnDemandConfirmedEnabled()
        ) else {
            return false
        }
        // A recoverable surrender or unavailable read cannot retire an armed reconnect.
        // Automatic restore keeps its separate fail-closed marker gate.
        return chainedStartupFailureMarkerObservation.terminalReason == nil
    }

    /// The unconfirmed surface speaks only where the connected surface would otherwise read as
    /// "all good". See `yieldsToUnconfirmedChainedForwarding` for why it must not outrank a real
    /// report — it has no deadline, and on an idle split tunnel it is the steady state.
    /// pinned: ChainedConnectFlowSourceTests.testTheUnconfirmedSurfaceYieldsToARealConnectivityReport
    private var showsChainedForwardingUnconfirmed: Bool {
        guard chainedForwardingUnconfirmed else { return false }
        guard vpnStatus == .connected else { return false }
        return protectionConnectivityAssessment.severity.yieldsToUnconfirmedChainedForwarding
    }

    var protectionStatus: ProtectionStatus {
        ProtectionStatus.resolve(
            lifecycle: vpnStatus.protectionLifecycleStatus,
            pauseUntil: temporaryProtectionPauseUntil,
            chainedEstablishing: chainedConnectEstablishing,
            observationUnavailable: chainedStatusChecking,
            forwardingUnconfirmed: chainedForwardingUnconfirmed,
            chainedFailure: chainedStartupFailureNotice != nil,
            setupReady: chainedSetupReady && !guardPanelMessageIsError,
            runtimeCondition: chainedProjection.runtimeCondition,
            awaitingOnDemandReconnect: isAwaitingOnDemandReconnect,
            connectivity: chainedProjection.ownsHealth
                ? chainedProjection.connectivity : protectionConnectivityAssessment.severity
        )
    }

    var protectionTitle: String {
        guardStatusPresentation.title
    }

    var guardStatusPresentation: GuardStatusPresentation {
        GuardStatusPresentation(status: protectionStatus,
            hasErrorNotice: guardPanelMessageIsError && !guardNetworkUnavailableOverridesNotice,
            offersDeviceDNSRecapture: offersManualDeviceDNSTierRecapture)
    }

    private var offersManualDeviceDNSTierRecapture: Bool {
        guard let profile = tunnelManager?.protocolConfiguration as? NETunnelProviderProtocol,
              !profile.includeAllNetworks, tunnelHealth.networkPathIsSatisfied,
              tunnelHealth.dnsTierHealth.contains(where: {
                  $0.resolverKind == .device && $0.recoveryStatus == .throttled
              }) else { return false }
        let physicalEgressPermitted: Bool
        if configuration.chainedUpstreamEnabled {
            physicalEgressPermitted = configuration.chainedTierOneFallbackEnabled
                && storedChainedRoutingPolicyForEnforcement == .splitTunnel
        } else {
            physicalEgressPermitted = true
        }
        return tunnelHealth.dnsTierHealth.contains { tier in
            tier.permitsManualDeviceDNSRecapture(
                in: configuration, healthUpdatedAt: tunnelHealth.updatedAt,
                connectedAt: tunnelManager?.connection.connectedDate,
                isConnected: vpnStatus == .connected && tunnelManager?.connection.status == .connected,
                guardEnabled: userProtectionIntent.isEnabled,
                physicalEgressPermitted: physicalEgressPermitted)
        }
    }

    private var guardNetworkUnavailableOverridesNotice: Bool {
        guard case .connected(.networkUnavailable) = protectionStatus else { return false }
        return guardPanelMessageSelection?.isChainedFailureMarker ?? true
    }

    var protectionSubtitle: String {
        let notice = guardPanelMessageSelection
        // A current lost network outranks only an earlier chained-start marker. Keep a
        // newer setup, settings, or VPN operation error visible during the outage.
        if guardNetworkUnavailableOverridesNotice {
            return ProtectionConnectivityPresentation.subtitle(for: .networkUnavailable)
        }
        if let notice { return notice.message }
        switch protectionStatus {
        case .paused:
            return "Lava will try to resume at %@.".lavaLocalizedFormat(formattedTemporaryProtectionResumeTime)
        case .establishing:
            return Self.chainedEstablishingMessage.lavaLocalized
        case .tunnelReady:
            return "Waiting for traffic to confirm VPN forwarding."
        case .vpnUnconfirmed:
            return Self.chainedForwardingUnconfirmedMessage
        case .chainingFailed:
            return Self.chainedStartupFailureMessage
        case .connected(let severity):
            return ProtectionConnectivityPresentation.subtitle(for: severity)
        case .turningOn:
            return "Starting local filtering."
        case .turningOff:
            return "Stopping local filtering."
        case .notInstalled:
            return "Turn on to set up protection."
        case .reconnecting:
            return "Lava will reconnect automatically."
        case .vpnRecovering:
            return "Lava is restoring VPN forwarding."
        case .off:
            return "Turn on local protection when you are ready."
        case .unavailable:
            return "Lava can't confirm whether protection is active."
        }
    }

    var protectionButtonTitle: String {
        // Tunnel status can change before the owning action finishes. Keep the
        // accepted action's label until its real release, including failure/cancellation.
        if let pendingTitle = protectionActionPresentation.pendingTitle { return pendingTitle }
        switch guardStatusPresentation.primaryAction {
        case .resume: return "Resume now"
        case .reconnect: return "Reconnect"
        case .turnOff: return "Turn off"
        case .turnOn: return "Turn on"
        }
    }

    var protectionPrimaryActionIsDisabled: Bool {
        protectionStatus == .turningOff || ProtectionLifecyclePolicy.shouldDisablePrimaryAction(
            status: vpnStatus.protectionLifecycleStatus,
            isConfiguring: isConfiguringVPN
        )
    }

    var protectionSymbolName: String {
        switch protectionStatus {
        case .paused: return "pause.circle.fill"
        case .tunnelReady, .establishing, .turningOn: return "shield.righthalf.filled"
        case .vpnUnconfirmed, .chainingFailed: return "exclamationmark.shield.fill"
        case .unavailable: return "questionmark.shield"
        case .reconnecting, .vpnRecovering: return "arrow.triangle.2.circlepath"
        case .connected(let severity):
            switch severity {
            case .healthy: return "checkmark.shield.fill"
            case .recovering: return "arrow.triangle.2.circlepath"
            case .usingDeviceDNSFallback, .usingEncryptedFallback: return "network"
            case .networkUnavailable: return "wifi.slash"
            case .dnsSlow, .needsReconnect: return "exclamationmark.shield.fill"
            }
        case .off, .notInstalled, .turningOff: return "shield"
        }
    }

    var protectionTint: Color {
        protectionTintRole.color
    }

    /// Semantic tint role for the protection surface. Portable (LavaSecKit) and
    /// resolved to a tuned, dark-mode-adaptive color via `ProtectionTintRole.color`
    /// on iOS — replaces the prior raw, non-adaptive `.green`/`.orange` returns.
    var protectionTintRole: ProtectionTintRole {
        guardStatusPresentation.tintRole
    }

    var protectionActionTone: String {
        guardStatusPresentation.actionTone.rawValue
    }

    var protectionButtonTint: Color {
        switch protectionActionTone {
        case "quiet": return LavaStyle.quietControl
        case "recovery": return LavaStyle.lavaOrangeSelectedFill
        default: return LavaStyle.safeControlGreen
        }
    }

    var protectionConnectivitySeverity: ProtectionConnectivitySeverity? {
        // A chained provider that has taken health ownership is the single live
        // authority for the path surfaces. Falling back to the persisted DNS
        // monitor here would let the hero and the flow diagram disagree during
        // the handoff between samples.
        return chainedProjection.effectiveConnectivity(fallback: protectionConnectivityAssessment.severity)
    }

    var isProtectionTemporarilyPaused: Bool {
        vpnStatus == .connected && temporaryProtectionPauseUntil != nil
    }

    var showsTemporaryProtectionPauseControls: Bool {
        vpnStatus == .connected && guardStatusPresentation.allowsPause && !isConfiguringVPN
    }

    var formattedTemporaryProtectionResumeTime: String {
        guard let temporaryProtectionPauseUntil else {
            return Date().formatted(date: .omitted, time: .shortened)
        }

        return temporaryProtectionPauseUntil.formatted(date: .omitted, time: .shortened)
    }

    var guardDNSFlowStepStatus: GuardFlowStepStatus {
        GuardStepHealthPolicy.dnsStatus(
            isProtectionActive: vpnStatus == .connected,
            configuredResolver: configuration.resolverPreset,
            health: tunnelHealth,
            connectivitySeverity: protectionConnectivitySeverity
        )
    }

    var guardDNSFlowStepDetail: String {
        guardDNSFlowStepDetailComponents.displayText
    }

    var guardDNSFlowStepDetailComponents: GuardFlowDNSDetail {
        GuardStepHealthPolicy.dnsDetailComponents(
            configuredResolver: configuration.resolverPreset,
            health: tunnelHealth,
            connectivitySeverity: protectionConnectivitySeverity
        )
    }

    var guardFilterFlowStepStatus: GuardFlowStepStatus {
        GuardStepHealthPolicy.filterStatus(
            isProtectionActive: vpnStatus == .connected,
            filtersConfigured: guardFiltersConfigured,
            hasFilterIssue: guardFiltersHaveIssue,
            filterSnapshotUsable: guardFilterSnapshotUsable,
            filterSnapshotLoadComplete: guardConfiguredBlocklistRuleSetsLoaded
        )
    }

    // The Internet and Phone endpoints bookend the protected path: green while
    // the tunnel is up, grey when protection is off so the whole flow (steps and
    // connectors) reads as inactive together.
    var guardEndpointFlowStepStatus: GuardFlowStepStatus {
        vpnStatus == .connected ? .healthy : .inactive
    }

    var protectionConnectivityAssessment: ProtectionConnectivityAssessment {
        ProtectionConnectivityPolicy.assessment(
            isConnected: vpnStatus == .connected,
            health: tunnelHealth
        )
    }

    var showsDNSProviderRecovery: Bool {
        protectionStatus == .connected(.dnsSlow)
    }

    var showsChainedConfigurationRecovery: Bool {
        configuration.chainedUpstreamEnabled && chainedConfigurationStartIssue != nil
    }

    private var guardPanelMessageSelection: (message: String, isError: Bool, isChainedFailureMarker: Bool)? {
        let permissionMessage = !isVPNConfigurationInstalled && vpnMessage == Self.vpnPermissionPromptMessage
            ? vpnMessage : nil
        let applyError = chainedSettingsApplyError.flatMap { detail -> String? in
            guard !detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return "%@: %@".lavaLocalizedFormat("Could not reconnect protection".lavaLocalized, detail)
        }
        return GuardStatusMessagePolicy.select(
            chainingEnabled: configuration.chainedUpstreamEnabled,
            setupIssue: chainedConfigurationStartIssue?.message.lavaLocalized,
            errorMessage: vpnMessageIsError ? vpnMessage : nil,
            settingsApplyError: applyError,
            lifecycleNotice: chainedLifecycleNotice ?? chainedStartupFailureNotice,
            permissionMessage: permissionMessage
        ).map { selected in
            (selected.text, selected.isError,
             selected.source == .lifecycleNotice
                && chainedLifecycleNotice == nil
                && chainedStartupFailureNotice != nil)
        }
    }

    var guardPanelMessage: String? {
        guardPanelMessageSelection?.message
    }

    var guardPanelMessageIsError: Bool {
        guardPanelMessageSelection?.isError ?? false
    }

    var enabledBlocklists: [BlocklistSource] {
        blocklists.filter { configuration.enabledBlocklistIDs.contains($0.id) }
    }

    var draftEnabledBlocklists: [BlocklistSource] {
        let enabledIDs = filterEditDraft?.enabledBlocklistIDs ?? configuration.enabledBlocklistIDs
        return blocklists.filter { enabledIDs.contains($0.id) }
    }

    var stagedBlockedDomainCount: Int {
        (filterEditDraft?.blockedDomains ?? configuration.blockedDomains).count
    }

    var stagedAllowedDomainCount: Int {
        (filterEditDraft?.allowedDomains ?? configuration.allowedDomains).count
    }

    var blocklists: [BlocklistSource] {
        DefaultCatalog.selectableCuratedSources(
            availableSourceIDs: Set(catalogSourcesByID.keys),
            enabledSourceIDs: filterDetailBaseline.enabledBlocklistIDs,
            catalogLoaded: catalogVersion != nil
        )
    }

    var blocklistsConfigured: Bool {
        !configuration.enabledBlocklistIDs.isEmpty
    }

    var customBlocklists: [CustomBlocklistSource] {
        configuration.customBlocklists
    }

    func stagedCustomBlocklistsForDisplay() -> [CustomBlocklistSource] {
        let enabledIDs = filterEditDraft?.enabledBlocklistIDs ?? configuration.enabledBlocklistIDs
        return displayedCustomBlocklists.filter { enabledIDs.contains($0.id) }
    }

    func stagedCustomBlocklistsForPicker() -> [CustomBlocklistSource] {
        displayedCustomBlocklists
    }

    func customBlocklistPickerTitle(for source: CustomBlocklistSource) -> String {
        if source.displayName == source.sourceURL.host {
            return source.sourceURL.absoluteString
        }

        return source.displayName
    }

    func customBlocklistDisplayKey(for source: CustomBlocklistSource) -> String {
        customBlocklistPickerTitle(for: source)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    func customBlocklistEntryCount(for source: CustomBlocklistSource) -> Int? {
        localBlocklistEntryCount(for: source.id, customSource: source)
    }

    func isCustomBlocklist(_ sourceID: String) -> Bool {
        displayedCustomBlocklists.contains { $0.id == sourceID }
    }

    var displayedCustomBlocklists: [CustomBlocklistSource] {
        // While editing, the draft is authoritative. It starts as a full copy of the
        // saved custom blocklists (`FilterEditDraft.init(configuration:)`) and records
        // both adds and deletes, so it already is the set to show. Merging it back with
        // `configuration` would resurrect a custom list the draft just deleted — making
        // a trash → Delete leave the row on screen. Order is preserved: the draft keeps
        // the saved order, with any new additions appended.
        if let filterEditDraft {
            return filterEditDraft.customBlocklists
        }
        return filterDetailBaseline.customBlocklists
    }

    var allowlistConfigured: Bool {
        !configuration.allowedDomains.isEmpty
    }

    private var guardFiltersConfigured: Bool {
        !configuration.enabledBlocklistIDs.isEmpty || !configuration.blockedDomains.isEmpty
    }

    private var guardFiltersHaveIssue: Bool {
        guard guardFiltersConfigured else {
            return false
        }

        if catalogStatusIsError {
            return true
        }

        if case .failed = filterPreparationState {
            return true
        }

        return false
    }

    private var guardConfiguredBlocklistRuleSetsLoaded: Bool {
        guard !configuration.enabledBlocklistIDs.isEmpty else {
            return true
        }

        return configuration.enabledBlocklistIDs.allSatisfy { sourceID in
            cachedBlockRuleSets[sourceID] != nil
        }
    }

    private var guardFilterSnapshotUsable: Bool {
        if !configuration.enabledBlocklistIDs.isEmpty {
            return compiledBlocklistRuleCount > 0
        }

        return !configuration.blockedDomains.isEmpty
    }

    var blockedFiltersSummaryText: String {
        let listCount = configuration.enabledBlocklistIDs.count
        let domainCount = configuration.blockedDomains.count
        let configurationStatus = listCount == 0 && domainCount == 0 ? "Not configured" : "Configured"
        let freshnessStatus = blocklistCatalogIsFresh ? "Up-to-date" : "Requires update"

        return "%@. %@".lavaLocalizedFormat(configurationStatus.lavaLocalized, freshnessStatus.lavaLocalized)
    }

    var allowedExceptionsSummaryText: String {
        configuration.allowedDomains.isEmpty ? "Not configured" : "Configured"
    }

    var blocklistSummaryText: String {
        listSummary(
            count: configuration.enabledBlocklistIDs.count,
            singular: "list",
            plural: "lists",
            values: configuration.enabledBlocklistIDs
                .map { blocklistName(for: $0) }
                .sorted()
        )
    }

    var allowlistSummaryText: String {
        listSummary(
            count: configuration.allowedDomains.count,
            singular: "domain",
            plural: "domains",
            values: Array(configuration.allowedDomains).sorted()
        )
    }

    var allowlistCountText: String {
        "\(configuration.allowedDomains.count)/\(configuration.limits.maxAllowedDomains)"
    }

    var blockedDomainCountText: String {
        "\(configuration.blockedDomains.count)/\(configuration.limits.maxBlockedDomains)"
    }

    var filterDraftDiff: FilterConfigurationDiff {
        filterDrafts.reviewDiff
    }

    var filterDraftHasChanges: Bool {
        !filterDraftDiff.isEmpty
    }

    var filterDraftValidationMessage: String? {
        filterDrafts.validationMessage(for: filterDrafts.review)
    }

    var filterDraftCanConfirm: Bool {
        filterDrafts.review.canConfirm
    }

    var filterDraftChangeCountText: String {
        filterDrafts.changeCountText(for: filterDrafts.reviewDiff)
    }

    // The diagnostics-derived digest text (blockRateText, activityDigestTitle,
    // activityDigestSubtitle, guardActivityRowStat) lives on `reports`
    // (DiagnosticsController) since the Phase D4 peel — it reads only the
    // controller-owned DiagnosticsStore, and views must observe the controller
    // for it to re-render.

    /// Glanceable stat under the Guard "How Lava filters" row — the number of
    /// rules currently compiled into protection. Uses `compiledRuleCount` (the
    /// same total the Filters screen headlines as "rules in effect"), so manual
    /// blocked domains count even when no curated blocklist is enabled.
    var guardFiltersRowStat: String {
        let count = compiledRuleCount
        guard count > 0 else {
            return "No filter active yet"
        }

        return count == 1
            ? "%@ rule active".lavaLocalizedFormat(count.formatted())
            : "%@ rules active".lavaLocalizedFormat(count.formatted())
    }

    var localLogsStatusText: String {
        let enabledLogNames = [
            configuration.keepFilteringCounts ? "counts".lavaLocalized : nil,
            configuration.keepDomainDiagnostics ? "domain history".lavaLocalized : nil,
            configuration.keepNetworkActivity ? "network activity".lavaLocalized : nil,
            configuration.keepLavaGuardProgress ? "Lava Guard progress".lavaLocalized : nil
        ].compactMap { $0 }
        let totalCount = 4

        let enabledCount = enabledLogNames.count
        switch enabledCount {
        case 0:
            return "All local logs off"
        case totalCount:
            return "All local logs on"
        default:
            let enabledSummary = enabledLogNames.formatted(.list(type: .and))
            let displayedSummary = enabledSummary.prefix(1).uppercased() + enabledSummary.dropFirst()
            return "%@ on".lavaLocalizedFormat(displayedSummary)
        }
    }


    var planStatusText: String {
        configuration.hasLavaSecurityPlus ? "Lava Security Plus" : "Free plan"
    }

    // The account presentation state (status/detail text, connection + per-provider
    // progress flags, sign-in action titles) lives on `account` (AccountController)
    // since the Phase D3 account peel — views observe it as its own environment object.

    var dnsResolverSummaryText: String {
        let preset = configuration.resolverPreset
        let name = LavaStrings.resolverName(preset, customName: configuration.customResolverName, short: true)
        guard configuration.resolverLadderInputs.isConfiguredFallbackEnabled
        else {
            return name
        }

        return "%@ + Fallback".lavaLocalizedFormat(name)
    }

    var supportsDNSOverQUIC: Bool {
        Self.supportsDNSOverQUICRuntime
    }

    var deviceDNSFallbackDetailText: String {
        if #available(iOS 26.0, *) {
            return "If your DNS provider keeps failing, Lava temporarily uses Device DNS for allowed requests, then switches back when it can."
        }

        return "If your DNS provider keeps failing, Lava temporarily uses Device DNS for allowed requests, then switches back when it can. On iOS 17–25 this is best effort."
    }

    var deviceDNSResolverDetailText: String {
        if #available(iOS 26.0, *) {
            return "Uses the DNS resolver from the current Wi-Fi or cellular network while Lava still filters locally."
        }

        return "Uses the DNS provider from your current Wi-Fi or cellular network. On iOS 17–25 this may not always work."
    }

    private var catalogPresentationState: CatalogPresentationState {
        return CatalogPresentationState(
            cacheAge: blocklistCatalogAge,
            maxAge: catalogSyncFreshnessInterval,
            statusIsError: catalogStatusIsError,
            sync: catalog.syncState,
            ruleCount: compiledRuleCount
        )
    }

    var filterFreshnessText: String {
        guard catalogGeneratedAt != nil else {
            return "Filter not updated yet"
        }

        return "Filter updated: %@".lavaLocalizedFormat(catalogUpdatedAtText)
    }

    var configuredBlockedDomainCountText: String {
        let count = compiledRuleCount
        switch catalogPresentationState.ruleCount {
        case .one:
            return "%@ blocked domain".lavaLocalizedFormat(count.formatted())
        case .zero, .many:
            return "%@ blocked domains".lavaLocalizedFormat(count.formatted())
        }
    }

    var configuredBlockedDomainNumberText: String {
        compiledRuleCount.formatted()
    }

    var configuredProtectedDomainNumberText: String {
        protectedRuleCount.formatted()
    }

    var configuredAllowlistExceptionNumberText: String {
        configuration.allowedDomains.count.formatted()
    }

    var configuredAllowlistExceptionCountText: String {
        let count = configuration.allowedDomains.count
        return count == 1
            ? "%@ exception configured".lavaLocalizedFormat(configuredAllowlistExceptionNumberText)
            : "%@ exceptions configured".lavaLocalizedFormat(configuredAllowlistExceptionNumberText)
    }

    var catalogVersionText: String {
        catalogVersion ?? "Not updated yet"
    }

    var catalogUpdatedAtText: String {
        guard let catalogGeneratedAt else {
            return "Not updated yet"
        }

        return Self.formatCatalogDate(catalogGeneratedAt)
    }

    var catalogUpdateDetailText: String {
        guard catalogGeneratedAt != nil else {
            return "Not updated yet"
        }

        return "Updated %@".lavaLocalizedFormat(catalogUpdatedAtText)
    }

    var blocklistCatalogIsFresh: Bool {
        switch catalogPresentationState.freshness {
        case .missing, .fresh:
            // Preserve the shipped initial-window behavior: no cache age and no error
            // remains acceptable while the first fetch is pending, even though the pure
            // state keeps `.missing` distinct from genuinely fresh catalog data.
            return true
        case .stale, .error:
            return false
        }
    }

    var blocklistCatalogFreshnessTitle: String {
        if blocklistCatalogIsFresh {
            return "Filter up to date"
        }

        return "Update recommended"
    }

    var blocklistCatalogFreshnessDescription: String {
        guard let age = blocklistCatalogAge else {
            return "Lava will fetch the source catalog before preparing the filter."
        }

        return "Last checked: %@".lavaLocalizedFormat(Self.formatRelativeCatalogAge(age, maxFreshnessAge: catalogSyncFreshnessInterval))
    }

    var blocklistCatalogFreshnessSystemImage: String {
        blocklistCatalogIsFresh ? "checkmark.circle.fill" : "arrow.clockwise.circle.fill"
    }

    var blocklistCatalogFreshnessTint: Color {
        blocklistCatalogIsFresh ? LavaStyle.safeGreen : LavaStyle.secondaryText
    }

    var catalogRefreshButtonTitle: String {
        switch catalogPresentationState.sync {
        case .syncing:
            return "Fetching from the server..."
        case .succeeded:
            return "Refreshed"
        case .idle, .failed:
            return "Refresh now"
        }
    }

    private var blocklistCatalogAge: TimeInterval? {
        guard let catalogCacheURL else {
            return nil
        }

        return BlocklistCatalogSynchronizer.cachedCatalogAge(in: catalogCacheURL)
    }

    var blocklistCatalogLastUpdatedText: String {
        guard let age = blocklistCatalogAge else {
            return "Not updated yet"
        }

        return Self.formatRelativeCatalogAge(age, maxFreshnessAge: catalogSyncFreshnessInterval)
    }

    var tunnelNetworkText: String {
        // Nerd Stats display value (UR-56 localization sweep). "Wi-Fi" is a proper
        // noun and stays verbatim; the other kinds route through the catalog.
        // The English-stable variant used for logs is TunnelNetworkKind.displayName.
        switch tunnelHealth.networkKind {
        case .unknown:
            "Unknown".lavaLocalized
        case .wifi:
            "Wi-Fi"
        case .cellular:
            "Cellular".lavaLocalized
        case .wired:
            "Wired".lavaLocalized
        case .other:
            "Other".lavaLocalized
        }
    }

    var tunnelNetworkChangeText: String {
        tunnelHealth.networkChangeCount.formatted()
    }

    var tunnelNetworkPathText: String {
        tunnelHealth.networkPathIsSatisfied ? "Available".lavaLocalized : "Lost".lavaLocalized
    }

    var tunnelResolverRuntimeResetText: String {
        tunnelHealth.resolverRuntimeResetCount.formatted()
    }

    var tunnelLastNetworkChangeText: String {
        formattedTunnelHealthDate(tunnelHealth.lastNetworkChangeAt)
    }

    var tunnelLastResolverRuntimeResetText: String {
        guard let resetAt = tunnelHealth.lastResolverRuntimeResetAt else {
            return "None yet".lavaLocalized
        }

        let reason = tunnelHealth.lastResolverRuntimeResetReason ?? "unknown"
        return "\(resetAt.formatted(date: .omitted, time: .shortened)) · \(reason)"
    }

    var tunnelLastUpstreamSuccessText: String {
        formattedTunnelHealthDate(tunnelHealth.lastUpstreamSuccessAt)
    }

    var tunnelLastUpstreamFailureText: String {
        formattedTunnelHealthDate(tunnelHealth.lastUpstreamFailureAt)
    }

    private func formattedTunnelHealthDate(_ date: Date?) -> String {
        guard let date else {
            return "None yet".lavaLocalized
        }

        return date.formatted(date: .omitted, time: .shortened)
    }

    func blocklistCatalogSubtitleText(for blocklist: BlocklistSource) -> String {
        blocklist.licenseName
    }

    /// Optional local display metadata. Never starts refresh, parsing or preparation.
    func localBlocklistEntryCount(for sourceID: String, customSource: CustomBlocklistSource? = nil) -> Int? {
        if let customSource {
            return localCustomRuleCounts[sourceID]?.count(matching: customSource)
        }
        guard let count = catalogSourcesByID[sourceID]?.entryCount, count >= 0 else { return nil }
        return count
    }

    func blocklistEntryCount(for blocklist: BlocklistSource) -> Int? {
        localBlocklistEntryCount(for: blocklist.id)
    }

    func blocklistRuleCountText(for blocklist: BlocklistSource) -> String {
        guard let count = blocklistEntryCount(for: blocklist) else {
            return catalogVersion == nil ? "Not updated yet" : "Unavailable"
        }

        return "%@ rules".lavaLocalizedFormat(count.formatted())
    }

    func blocklistMetadataText(for sourceID: String) -> String? {
        if let blocklist = blocklists.first(where: { $0.id == sourceID }) {
            return blocklistRuleCountText(for: blocklist)
        }

        guard customBlocklistSource(for: sourceID) != nil else {
            return nil
        }

        if let source = customBlocklistSource(for: sourceID),
           let count = localBlocklistEntryCount(for: sourceID, customSource: source) {
            return "%@ rules · Custom List".lavaLocalizedFormat(count.formatted())
        }

        return "Pending refresh · Custom List"
    }

    // MARK: - Stored state declared beside its concern before the file split
    //
    // Swift extensions cannot hold stored properties, so these moved here from the
    // AppViewModel/ file named in each group; their doc comments travelled with them.

    // From AppViewModel/AppViewModel+FilterRulesBudget.swift:

    /// The exact tier-budget message text this hub last put on the catalog status
    /// surface, so the plan-change reconcile can recognize (and clear) ITS OWN stale
    /// message after an upgrade resolves it — without pattern-matching status text,
    /// which would break the moment the copy or locale changes.
    var lastSurfacedTierBudgetMessage: String?

    /// Single writer for the over-budget status: every INV-TIER-1 surface (plan/restore
    /// reconcile, post-sync check, launch-reconcile catch, in-place enable revert) funnels
    /// through here so the clear-on-upgrade logic above always recognizes the message.
    /// The honest version of "the filter could not be prepared".
    ///
    /// Its own string, NOT the underlying error's: the errors that reach here name internal
    /// causes and at least one of them actively misattributes — the SSRF gate reports
    /// "Custom blocklist URLs must use a public host" when what it saw was the tunnel's own
    /// fail-closed answer. Showing that verbatim sends the user to delete a blocklist that is
    /// perfectly fine. The actionable instruction is the recovery that actually works while
    /// the repair path is DNS-starved.
    /// How many retries this process has already scheduled. Reset only by a successful
    /// reconcile, so the ladder is per-outage rather than per-attempt.
    var failClosedReconcileRetryAttempt = 0

    /// Guards against two ladders running at once — a foreground event landing while a timed
    /// retry is already pending would otherwise double the schedule.
    var isFailClosedReconcileRetryScheduled = false

    /// Monotonic generation, bumped whenever the ladder is retired.
    ///
    /// 🔴 A FLAG CANNOT DO THIS JOB, and that is the whole point. Clearing the ladder resets
    /// the counter, but a rung already sleeping 20–180s is a Task nobody holds a handle to:
    /// it wakes regardless of what the counter says, re-runs prepare + persist + notify
    /// against a device that may already be healthy, and if THAT redundant run hits a
    /// transient failure its catch re-arms the ladder on a device that had recovered.
    ///
    /// The opening needed is only this: `reconcileTunnelSnapshotAfterLaunch` has several
    /// callers (the launch task, the catalog-sync path, and the post-unlock shared-state
    /// reload), any of which can SUCCEED while a rung is still sleeping.
    ///
    /// An earlier version of this comment named a specific sequence — first reconcile fails
    /// before first unlock, unlock repairs it — and that sequence is IMPOSSIBLE: pre-unlock,
    /// `hasCompletedOnboarding` reads false out of Class-C-locked standard defaults, so the
    /// launch task skips the reconcile entirely and no rung is ever armed. The race is real;
    /// that story about it was not. Which concrete interleaving hits it in the field is NOT
    /// established, and the epoch is correct regardless — it costs one comparison and removes
    /// the whole class.
    ///
    /// A value the sleeper captured and re-compares on wake is the only thing that survives
    /// its own suspension — the same reason a quiesce window needs an epoch and not a bool.
    var failClosedReconcileRetryEpoch = 0

    // VPN settings readback and the credential-write mutex shared with QA staging.
    // Refresh the snapshot on entry/resume or profile mutation, never while rendering.
    @Published var dnsSettingsProfileStatus: ChainedUpstreamSurfaceStatus?
    var dnsSettingsPresentationRevision: UInt64 = 0
    var dnsSettingsPresentationTask: Task<Void, Never>?
    var dnsSettingsPresentationNeedsRefresh = false
    @Published var isStagingChainedUpstreamForQA = false

    // From AppViewModel/AppViewModel+ReportSurfaces.swift:

    // The tunnel already persists health on its own 30s cadence; the UI poll only
    // needs to force a flush at most that often instead of per 5s tick.
    var lastTunnelHealthFlushRequestedAt = Date.distantPast
    var visibleStatsSamplingTask: Task<Bool, Never>?

    // From AppViewModel/AppViewModel+ChainedConnectLifecycle.swift:

    /// Initial-resolution diagnostics are connection-scoped and independent of the sampler handle.
    /// Teardown suspension stops sampling but retains these counters; an outer status transition
    /// away from connected cancels them, and the reducer's initial-resolution effect completes them.
    var chainedEstablishmentProgress: (startedAt: Date, polls: Int, unknownReplies: Int)?

    // From AppViewModel/AppViewModel+ReviewPrompt.swift:

    // Caches let the status poll skip per-tick disk decodes and defaults writes;
    // both stores reconcile on real transitions (and usage accrual is window-based,
    // so a coarser cadence credits the same uptime).
    var lastObservedProtectionUptimeIsRunning: Bool?
    var lastLavaGuardUsageIsRunning: Bool?
    var lastLavaGuardUsageAccrualAt = Date.distantPast
}
