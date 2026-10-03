import Darwin
import Foundation
import Security

/// The raw item backend for the device-local eligibility store: an upserting byte store
/// addressed by account.
///
/// A protocol for the same reason ``ChainedUpstreamKeyItemStore`` is one: the live
/// `SecItem*` round-trip is not exercisable in host unit tests, so behavior is tested
/// against an in-memory conformer and the production conformer pins its query attributes
/// instead.
public protocol ChainedDeviceStateItemStore: Sendable {
    /// Upsert: the eligibility values are mutable state, unlike the generation-addressed
    /// key items whose add-only contract exists to make torn rotations unrepresentable.
    func save(_ data: Data, account: String) throws
    /// The stored bytes, or `nil` when no item exists. `nil` is a trustworthy "never set"
    /// only when the access group is right — see ``GenericKeychainStore/accessGroup``.
    func load(account: String) throws -> Data?
    /// Removes the item; absent is success.
    func delete(account: String) throws
    /// Runs one lifecycle-evidence transition without allowing another app or tunnel process to
    /// interleave Keychain operations inside it.
    func withExclusiveLifecycleEvidenceAccess<T>(
        _ operation: () throws -> T
    ) throws -> T
}

/// Why a device-state item operation failed.
public enum ChainedDeviceStateStoreFailure: Error, Equatable, Sendable {
    /// The Keychain refused the operation. `errSecInteractionNotAllowed` here is the
    /// pre-first-unlock boot; everything else is unexpected but handled the same way —
    /// as unavailability, never as a value.
    case keychainRefused(OSStatus)
    /// The lifecycle-evidence lock file could not be opened; the value is `errno`.
    case coordinationOpenFailed(Int32)
    /// The lifecycle-evidence lock file could not be assigned its required protection class.
    case coordinationProtectionFailed
    /// The lifecycle-evidence lock remained owned past the short startup bound.
    case coordinationBusy
    /// The lifecycle-evidence kernel lock failed for a reason other than contention.
    case coordinationLockFailed(Int32)
}

/// The production backend: generic passwords in the shared access group, under a service
/// of their own.
///
/// A SEPARATE service from ``ChainedUpstreamSecretNaming/keychainService``, deliberately:
/// the rotation store enumerates its service's accounts to sweep orphaned key items, and
/// however careful its prefix filter is, mutable eligibility state has no business inside
/// an enumeration whose purpose is deletion. Different service, no interaction.
public struct ChainedDeviceStateKeychainItemStore: ChainedDeviceStateItemStore {
    /// The `kSecAttrService` namespace for the device-local eligibility items.
    public static let keychainService = "com.lavasec.chained-device-state"

    private let keychain: GenericKeychainStore<ChainedDeviceStateStoreFailure>
    private let lifecycleEvidenceLockURL: URL

    /// - Parameters:
    ///   - accessGroup: The team-qualified shared group, from
    ///     ``ChainedUpstreamKeychainAccessGroup/resolved(_:)``. No default: an item written
    ///     to the app's per-bundle group is invisible to the tunnel, and absence there reads
    ///     as "never set".
    ///   - lifecycleEvidenceLockURL: An identity-namespaced App Group file whose advisory lock
    ///     serializes proof publication with marker consumption across both processes.
    public init(accessGroup: String, lifecycleEvidenceLockURL: URL) {
        self.lifecycleEvidenceLockURL = lifecycleEvidenceLockURL
        self.keychain = GenericKeychainStore(
            service: Self.keychainService,
            accessGroup: accessGroup,
            // The same class as the WireGuard key, and for the same two reasons: a
            // Connect-On-Demand start with the screen locked must be able to read it
            // (`WhenUnlocked` would collapse chained mode to DNS-only on every lock), and
            // a restore to another device must NOT carry it (the override is a property of
            // ONE device's hardware; the exclusion is evidence about ONE device's
            // behaviour — `ChainedAvailabilityPolicy` says both explicitly). Founder
            // decision 2026-07-30: the pre-first-unlock read this class refuses costs
            // nothing, because chained mode cannot start pre-unlock anyway — the private
            // key shares this class and the configuration file is Class C.
            accessibility: .afterFirstUnlockThisDeviceOnly,
            unexpectedItemData: .keychainRefused(errSecDecode),
            unhandledStatus: ChainedDeviceStateStoreFailure.keychainRefused
        )
    }

    public func save(_ data: Data, account: String) throws {
        try keychain.saveData(data, account: account)
    }

    public func load(account: String) throws -> Data? {
        try keychain.loadData(account: account)
    }

    public func delete(account: String) throws {
        try keychain.delete(account: account)
    }

    public func withExclusiveLifecycleEvidenceAccess<T>(
        _ operation: () throws -> T
    ) throws -> T {
        try ChainedLifecycleEvidenceFileLock.withExclusiveAccess(
            at: lifecycleEvidenceLockURL, operation)
    }

    /// The add query, for the test that pins the class and the group — the live round-trip
    /// is not exercisable in host unit tests, and these attributes are the
    /// security-sensitive part.
    func addQuery(account: String, data: Data) -> [String: Any] {
        keychain.addQuery(account: account, data: data)
    }
}

/// The lock is deliberately short and bounded: a suspended process must never wedge a replacement
/// provider at startup. Process-local exclusion is also required because Darwin `flock` ownership
/// through separately opened descriptors does not reliably exclude two threads in one process.
///
/// Scope note: this guards Keychain evidence only. `ChainedStartupFailureMarker` deliberately runs
/// on its own lock — a timed-out `SecItem*` worker can still be sitting inside THIS lock when the
/// caller has already given up, and the terminal startup marker has to become durable before the
/// provider cancels (PR #636).
private enum ChainedLifecycleEvidenceFileLock {
    private static let inProcessLock = NSLock()
    private static let lockWaitSeconds: TimeInterval = 0.25
    private static let retryDelayMicroseconds: useconds_t = 5_000

    static func withExclusiveAccess<T>(
        at lockURL: URL,
        _ operation: () throws -> T
    ) throws -> T {
        guard inProcessLock.lock(before: Date(timeIntervalSinceNow: lockWaitSeconds)) else {
            throw ChainedDeviceStateStoreFailure.coordinationBusy
        }
        defer { inProcessLock.unlock() }

        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, mode_t(S_IRUSR | S_IWUSR))
        guard descriptor >= 0 else {
            throw ChainedDeviceStateStoreFailure.coordinationOpenFailed(errno)
        }
        defer { close(descriptor) }

        guard SharedStateFileProtection.applyControlPlaneProtection(at: lockURL) else {
            throw ChainedDeviceStateStoreFailure.coordinationProtectionFailed
        }

        let deadline = Date(timeIntervalSinceNow: lockWaitSeconds)
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            let errorCode = errno
            guard errorCode == EWOULDBLOCK || errorCode == EAGAIN else {
                throw ChainedDeviceStateStoreFailure.coordinationLockFailed(errorCode)
            }
            guard Date() < deadline else {
                throw ChainedDeviceStateStoreFailure.coordinationBusy
            }
            usleep(retryDelayMicroseconds)
        }
        defer { flock(descriptor, LOCK_UN) }
        return try operation()
    }
}

/// Device-local chained eligibility plus lifecycle evidence for the startup crash-loop breaker.
///
/// Plan: lavasec-infra `plans/backlog/2026-07-27-vpn-upstream-phase-3-data-path-plan.md`
/// (S8.11b). This is the producer `TunnelDataPathLatch`'s `experimentalOverrideEnabled`
/// and `hasStartupCrashLoopTripped` terms have never had.
///
/// ## Unreadable is not false, and the type makes the difference unrepresentable
///
/// Reads answer with ``ReadOutcome``, never a bare value. If unavailability were reported
/// as defaults, a pre-first-unlock boot on a sub-floor opted-in device would read the
/// override as "off", the latch would refuse `.insufficientMemory`, and the app's
/// `ChainedAvailabilityPolicy.reconcile` — for which `insufficientMemory` revokes the
/// stored preference — would permanently clear `chainedUpstreamEnabled` and present the
/// clearing as the user's own choice. Same argument as
/// `ChainedUpstreamReadiness.Refusal.storeUnavailable`; same argument as
/// `TunnelDataPathLatch.Refusal.configurationUnreadable`.
///
/// ## What ABSENT means, per item
///
/// - Override absent: the user never opted this device in — genuinely `false`.
/// - Breaker state absent: no same-build pre-forwarding exit streak — `.clean`.
/// - Marker absent: no prior chained lifecycle needs classification — clear.
/// - Surrender reason absent from the record: chained mode never gave up, or the user
///   reset it — clear.
///
/// Absence is only trustworthy with the right access group, which is why the production
/// backend refuses to default it.
public struct ChainedDeviceEligibilityStore: Sendable {
    /// One coherent reading of all the items.
    public struct Snapshot: Equatable, Sendable {
        /// The device-local opt-in for sub-floor hardware.
        public let experimentalOverrideEnabled: Bool
        /// The startup crash-loop state, normalized by the policy's decoding.
        public let backoffState: ChainedStartupCrashLoopPolicy.State
        /// Whether a previous chained lifecycle started without its evidence being settled.
        public let uncleanTerminationMarkerIsSet: Bool
        /// The exact extension build that set the active marker. A missing value means the
        /// marker came from the legacy scheme and cannot establish a same-build crash loop.
        public let activeSessionBuildIdentity: String?
        /// A per-provider-lifecycle nonce. It fences delayed forwarding callbacks from a retired
        /// process even when the replacement is the exact same build.
        public let activeSessionLifecycleID: String?
        /// Whether that marked lifecycle delivered an inbound packet through the chained peer.
        /// Once true, a missing teardown is ordinary provider lifecycle churn, not startup failure.
        public let activeSessionWasProvenHealthy: Bool
        /// Why chained mode surrendered, when it has and the user has not reset it — `nil`
        /// otherwise (C4). A `ChainedReconnectPolicy.Surrender` log identifier, never user
        /// copy.
        ///
        /// The REASON rather than a Bool, so the notice and the device log can say WHY
        /// chained mode gave up without a second stored item to disagree with this one.
        ///
        /// Read out of the snapshot, never written back from it: the transitions that
        /// own the suppression write their own intent, and every other record writer re-reads
        /// the live record inside the shared lifecycle transaction.
        public let surrenderReasonLogValue: String?

        /// Whether chained mode surrendered and no explicit Guard start has cleared it (C4).
        ///
        /// Persisted by the tunnel BEFORE the surrender's restart, so a crash between the
        /// two cannot re-enter the mode the notice said turned itself off; cleared only by
        /// the next explicit Guard start.
        public var isSurrenderSuppressed: Bool { surrenderReasonLogValue != nil }

        // NO DEFAULT on the surrender field, deliberately: the provider reconstructs this
        // snapshot after consuming termination evidence, and a defaulted `nil` would let
        // that site compile while silently DROPPING a set suppression — the latch would
        // re-enter the mode the notice said turned itself off.
        public init(
            experimentalOverrideEnabled: Bool,
            backoffState: ChainedStartupCrashLoopPolicy.State,
            uncleanTerminationMarkerIsSet: Bool,
            surrenderReasonLogValue: String?,
            activeSessionBuildIdentity: String? = nil,
            activeSessionLifecycleID: String? = nil,
            activeSessionWasProvenHealthy: Bool = false
        ) {
            self.experimentalOverrideEnabled = experimentalOverrideEnabled
            self.backoffState = backoffState
            self.uncleanTerminationMarkerIsSet = uncleanTerminationMarkerIsSet
            self.surrenderReasonLogValue = surrenderReasonLogValue
            self.activeSessionBuildIdentity = activeSessionBuildIdentity
            self.activeSessionLifecycleID = activeSessionLifecycleID
            self.activeSessionWasProvenHealthy = activeSessionWasProvenHealthy
        }
    }

    /// What a read produced. A partial reading is not offered: the latch consumes all
    /// three terms in one decision, and a snapshot with one term guessed is the lie the
    /// outcome type exists to prevent.
    public enum ReadOutcome: Equatable, Sendable {
        case snapshot(Snapshot)
        /// The store could not be read. Transient on a pre-first-unlock boot; the payload
        /// is a stable log identifier, never user copy.
        case unavailable(String)
    }

    static let overrideAccount = "experimental-override"
    // Legacy account name is persisted on shipped devices; changing it would orphan state.
    static let terminationRecordAccount = "jetsam-termination-record"
    static let forwardingProofAccountPrefix = "forwarding-proof-"

    static func forwardingProofAccount(lifecycleID: String) -> String {
        forwardingProofAccountPrefix + lifecycleID
    }

    /// The backoff state, the session marker, AND the surrender suppression — ONE record
    /// in ONE item.
    ///
    /// One item because every transition that touches either of the first two touches
    /// both, and two items mean a kill or a failed second write can land between them: a
    /// marker cleared whose streak reset never persisted leaves stale strikes that a
    /// later, non-consecutive crash compounds into a premature exclusion (Codex, PR #499).
    /// A single `SecItemUpdate` is the atomicity boundary — whichever whole record last
    /// landed is the state, and no interruption can produce a mixture.
    ///
    /// The SURRENDER (C4) started as its own item, on the argument that no surrender
    /// transition touches the other two — and that argument was falsified twice in one
    /// review: the surrender must settle the marker (or its crash window turns a
    /// controlled surrender into a jetsam strike), the Reset must recognize residue, and a
    /// Connect-On-Demand launch overlapping a Reset could read the OLD record beside the
    /// NEW suppression item — reconstructing a marker-set-and-unsuppressed state that
    /// never existed and striking a healthy device (Codex, PR #505). Two compensating
    /// ordering fixes later, the honest conclusion is the store's own doctrine: states
    /// that must be read and written together live in one record, where the tear is
    /// unrepresentable rather than compensated for. The surrender transition now settles
    /// the marker IN THE SAME WRITE that sets the suppression, so the residue state cannot
    /// be produced at all.
    ///
    /// `surrenderReasonLogValue` is optional and decodes as absent from records written
    /// before it existed. A structurally corrupt record still resets whole to `.clean` —
    /// which now also reads "not suppressed". For the backoff that direction is argued
    /// below; for the surrender it is accepted: the state is reachable only by blob
    /// corruption of a Keychain item (not by any crash ordering, which the single write
    /// removed), and the alternative — unavailability — would wedge chained mode behind a
    /// permanently unreadable blob wearing a transient refusal.
    struct TerminationRecord: Equatable, Codable {
        static let currentCrashLoopSchemaVersion = 1

        var backoffState: ChainedStartupCrashLoopPolicy.State
        var uncleanTerminationMarkerIsSet: Bool
        var surrenderReasonLogValue: String?
        /// Schema 0 is the former "every missing teardown is jetsam" interpretation. Its
        /// counters/exclusions are not valid evidence for the same-build pre-forwarding breaker.
        var crashLoopSchemaVersion: Int
        var activeSessionBuildIdentity: String?
        var activeSessionLifecycleID: String?
        var activeSessionWasProvenHealthy: Bool
        /// Wall-clock epochs (seconds) of recent HANDS-FREE surrender auto-recoveries, the
        /// rolling window `ChainedSurrenderAutoRecoveryPolicy` bounds so a persistently-dead
        /// chain on a flapping path cannot recover→surrender→recover forever. Rides in the
        /// termination record because the recovery clears the surrender and records the attempt
        /// in ONE write — the same atomicity the surrender and marker share.
        var autoRecoveryEpochs: [Double]

        /// Memberwise, with `autoRecoveryEpochs` defaulted so the existing three-argument call
        /// sites (which never touch the recovery window) compile unchanged.
        init(
            backoffState: ChainedStartupCrashLoopPolicy.State,
            uncleanTerminationMarkerIsSet: Bool,
            surrenderReasonLogValue: String?,
            autoRecoveryEpochs: [Double] = [],
            crashLoopSchemaVersion: Int = Self.currentCrashLoopSchemaVersion,
            activeSessionBuildIdentity: String? = nil,
            activeSessionLifecycleID: String? = nil,
            activeSessionWasProvenHealthy: Bool = false
        ) {
            self.backoffState = backoffState
            self.uncleanTerminationMarkerIsSet = uncleanTerminationMarkerIsSet
            self.surrenderReasonLogValue = surrenderReasonLogValue
            self.autoRecoveryEpochs = autoRecoveryEpochs
            self.crashLoopSchemaVersion = crashLoopSchemaVersion
            self.activeSessionBuildIdentity = activeSessionBuildIdentity
            self.activeSessionLifecycleID = activeSessionLifecycleID
            self.activeSessionWasProvenHealthy = activeSessionWasProvenHealthy
        }

        /// Decode-tolerant: records written before `autoRecoveryEpochs` existed carry no such
        /// key, and a Swift stored default does NOT make synthesized `Decodable` tolerant of a
        /// missing key — it emits `decode` and throws `keyNotFound` (Codex, PR #558). Decode it
        /// explicitly, defaulting to the empty window.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.backoffState = try c.decode(
                ChainedStartupCrashLoopPolicy.State.self, forKey: .backoffState)
            self.uncleanTerminationMarkerIsSet = try c.decode(
                Bool.self, forKey: .uncleanTerminationMarkerIsSet)
            self.surrenderReasonLogValue = try c.decodeIfPresent(
                String.self, forKey: .surrenderReasonLogValue)
            self.autoRecoveryEpochs = try c.decodeIfPresent(
                [Double].self, forKey: .autoRecoveryEpochs) ?? []
            self.crashLoopSchemaVersion = try c.decodeIfPresent(
                Int.self, forKey: .crashLoopSchemaVersion) ?? 0
            self.activeSessionBuildIdentity = try c.decodeIfPresent(
                String.self, forKey: .activeSessionBuildIdentity)
            self.activeSessionLifecycleID = try c.decodeIfPresent(
                String.self, forKey: .activeSessionLifecycleID)
            self.activeSessionWasProvenHealthy = try c.decodeIfPresent(
                Bool.self, forKey: .activeSessionWasProvenHealthy) ?? false
        }

        static let clean = TerminationRecord(
            backoffState: .clean, uncleanTerminationMarkerIsSet: false,
            surrenderReasonLogValue: nil)
    }

    private let items: any ChainedDeviceStateItemStore

    public init(items: any ChainedDeviceStateItemStore) {
        self.items = items
    }

    /// Reads all three items coherently.
    public func read() -> ReadOutcome {
        do {
            let override: Bool
            if let data = try items.load(account: Self.overrideAccount) {
                // A malformed override byte is UNAVAILABILITY, not a value. Guessing
                // `false` here is the preference-clearing path the type-level doc walks;
                // guessing `true` claims an opt-in the user never made. Both guesses are
                // worse than a transient refusal.
                guard let flag = Self.decodeFlag(data) else {
                    return .unavailable("override-malformed")
                }
                override = flag
            } else {
                override = false
            }

            let record: TerminationRecord
            if let data = try items.load(account: Self.terminationRecordAccount) {
                // A structurally corrupt record resets to `.clean`, DELIBERATELY the
                // opposite of the override's treatment, because the failure directions
                // differ: garbage-as-a-value for the override destroys a user preference
                // irreversibly, while garbage-as-clean for the backoff merely re-opens a
                // safety net that re-closes by itself — a genuinely thrashing device
                // re-excludes in three strikes. Treating it as unavailability instead
                // would wedge chained mode behind a permanently unreadable blob wearing a
                // transient refusal. Out-of-RANGE counts are already normalized by the
                // policy's own decoding (#498); only broken JSON reaches this branch.
                record = (try? JSONDecoder().decode(TerminationRecord.self, from: data))
                    ?? .clean
            } else {
                record = .clean
            }

            // Generation-addressed instead of embedded in the mutable marker record. A retired
            // provider can finish this write after a replacement lifecycle has installed its own
            // marker; writing the old lifecycle's account cannot overwrite or bless the new one.
            let generationForwardingProof: Bool
            if record.uncleanTerminationMarkerIsSet,
                let lifecycleID = record.activeSessionLifecycleID
            {
                generationForwardingProof = try items.load(
                    account: Self.forwardingProofAccount(lifecycleID: lifecycleID)) != nil
            } else {
                generationForwardingProof = false
            }

            // The legacy state counted every missing teardown as a memory termination. It cannot
            // be translated into the new same-build/pre-forwarding evidence, so counters and the
            // sticky exclusion migrate to clean. A legacy marker stays visible for one consume;
            // its missing build identity classifies it as lifecycle churn and clears it.
            let migratedBackoffState = record.crashLoopSchemaVersion
                < TerminationRecord.currentCrashLoopSchemaVersion
                ? ChainedStartupCrashLoopPolicy.State.clean
                : record.backoffState
            return .snapshot(
                Snapshot(
                    experimentalOverrideEnabled: override,
                    backoffState: migratedBackoffState,
                    uncleanTerminationMarkerIsSet: record.uncleanTerminationMarkerIsSet,
                    surrenderReasonLogValue: record.surrenderReasonLogValue,
                    activeSessionBuildIdentity: record.activeSessionBuildIdentity,
                    activeSessionLifecycleID: record.activeSessionLifecycleID,
                    // The embedded bit was written by the first build of this migration. Keep it
                    // readable, but new proof writes never mutate the shared lifecycle record.
                    activeSessionWasProvenHealthy:
                        record.activeSessionWasProvenHealthy || generationForwardingProof
                ))
        } catch {
            return .unavailable("keychain-unavailable")
        }
    }

    /// Records that a chained lifecycle is starting. A later forwarding proof or teardown
    /// classifies it; if neither happens, the next start sees only an unknown hard exit.
    ///
    /// The caller treats a throw as "do not run chained": a session that cannot write its
    /// marker is a session the breaker cannot classify, and on a device where the write
    /// fails every time, letting it run would defeat that loop protection entirely. A current
    /// marker or live suppression means this startup was superseded after its snapshot; returning
    /// `false` makes that stale continuation fail closed instead of ignoring the newer verdict.
    @discardableResult
    public func markChainedSessionStarted(
        from snapshot: Snapshot, buildIdentity: String, lifecycleID: String
    ) throws -> Bool {
        try items.withExclusiveLifecycleEvidenceAccess {
            let current = try storedRecord() ?? .clean
            guard !current.uncleanTerminationMarkerIsSet else { return false }
            let currentBackoffState = current.crashLoopSchemaVersion
                < TerminationRecord.currentCrashLoopSchemaVersion
                ? ChainedStartupCrashLoopPolicy.State.clean
                : current.backoffState
            // The caller's eligibility snapshot predates this transaction. A peer can trip the
            // breaker or persist surrender after that read but before marker installation, so the
            // live record must still authorize chained mode at the write boundary.
            guard !currentBackoffState.hasTripped,
                current.surrenderReasonLogValue == nil
            else { return false }
            // UUIDs make collision fantastically unlikely; deleting first also makes the invariant
            // structural if a caller deliberately reuses one in a test or damaged persisted state.
            try items.delete(account: Self.forwardingProofAccount(lifecycleID: lifecycleID))
            try writeRecord(
                TerminationRecord(
                    // Re-read every shared field under the lifecycle transaction. The caller's
                    // snapshot cannot write a backoff or suppression that changed after its read.
                    backoffState: currentBackoffState,
                    uncleanTerminationMarkerIsSet: true,
                    surrenderReasonLogValue: current.surrenderReasonLogValue,
                    autoRecoveryEpochs: current.autoRecoveryEpochs,
                    activeSessionBuildIdentity: buildIdentity,
                    activeSessionLifecycleID: lifecycleID,
                    activeSessionWasProvenHealthy: false))
            return true
        }
    }

    /// Records the first real forwarding proof in a lifecycle-addressed item. It deliberately
    /// never rewrites the shared marker record: a delayed callback from a retired provider may
    /// overlap a replacement lifecycle, and a read/modify/write of that record could otherwise
    /// overwrite the replacement marker with the retired lifecycle's healthy bit.
    @discardableResult
    public func markChainedSessionProvenHealthy(
        buildIdentity: String, lifecycleID: String,
        isStillWanted: () -> Bool = { true }
    ) throws -> Bool {
        try items.withExclusiveLifecycleEvidenceAccess {
            let proofAccount = Self.forwardingProofAccount(lifecycleID: lifecycleID)
            guard try items.load(account: proofAccount) == nil else { return false }
            // A bounded caller may have timed out while the lifecycle transaction or proof read
            // was blocked. Stand down immediately before the generation-addressed mutation when
            // the caller abandoned during either of those earlier operations.
            guard isStillWanted() else { return false }
            try items.save(Data([1]), account: proofAccount)
            guard let record = try storedRecord(),
                record.uncleanTerminationMarkerIsSet,
                record.activeSessionBuildIdentity == buildIdentity,
                record.activeSessionLifecycleID == lifecycleID,
                !record.activeSessionWasProvenHealthy
            else {
                // The marker moved before or during this write. This old generation's proof cannot
                // affect the replacement, and removing it avoids an orphan if providers overlap.
                try? items.delete(account: proofAccount)
                return false
            }
            return true
        }
    }

    /// Settles the termination evidence at teardown, in ONE write: the marker clears on
    /// every shape, and the streak resets only when a session that actually ran stopped
    /// through its own funnel — a failed or cancelled start is not evidence the device
    /// coped, so its strikes survive.
    /// - Parameter owningLifecycleID: the lifecycle ID captured by this provider when its
    ///   marker was installed. It must not come from a fresh shared-store read at teardown,
    ///   because that read may already describe a replacement provider.
    /// - Parameter isStillWanted: consulted between this transition's own Keychain READ and
    ///   its write, for callers that bound the whole operation. The read, lifecycle fence,
    ///   abandonment check, and write all run inside the shared transaction. Defaults to
    ///   always-wanted for the unbounded callers.
    @discardableResult
    public func settleTermination(
        owningLifecycleID: String?,
        sessionRanAndStoppedCleanly: Bool,
        isStillWanted: () -> Bool = { true }
    ) throws -> Bool {
        try items.withExclusiveLifecycleEvidenceAccess {
            let current = try storedRecord() ?? .clean
            // A retired provider may finish teardown after its replacement installed a marker.
            // The expected ID is captured from this provider's latch, never adopted from a fresh
            // shared-store read that could already describe the replacement.
            guard current.uncleanTerminationMarkerIsSet
                    == (owningLifecycleID != nil),
                current.activeSessionLifecycleID == owningLifecycleID
            else { return false }
            guard isStillWanted() else { return false }
            let settled = sessionRanAndStoppedCleanly
                ? ChainedStartupCrashLoopPolicy.cleanTeardownObserved(in: current.backoffState)
                : current.backoffState
            try writeRecord(
                TerminationRecord(
                    backoffState: settled,
                    uncleanTerminationMarkerIsSet: false,
                    surrenderReasonLogValue: current.surrenderReasonLogValue,
                    autoRecoveryEpochs: current.autoRecoveryEpochs))
            deleteForwardingProofIfPresent(lifecycleID: current.activeSessionLifecycleID)
            return true
        }
    }

    /// Sets the device-local opt-in. App-side (Settings); the tunnel never writes it.
    public func setExperimentalOverrideEnabled(_ enabled: Bool) throws {
        try items.save(Data([enabled ? 1 : 0]), account: Self.overrideAccount)
    }

    /// Persists a backoff state on its own while carrying every other field from the live
    /// record under the shared lifecycle transaction. No snapshot argument: a stale caller
    /// cannot erase a marker or restore a suppression that another process just changed.
    public func saveBackoffState(_ state: ChainedStartupCrashLoopPolicy.State) throws {
        try items.withExclusiveLifecycleEvidenceAccess {
            let current = try storedRecord() ?? .clean
            var updated = current
            updated.backoffState = state
            updated.crashLoopSchemaVersion = TerminationRecord.currentCrashLoopSchemaVersion
            try writeRecord(updated)
        }
    }

    /// Consumes a stale marker found at start. Only a same-build lifecycle that never proved
    /// forwarding advances the breaker; build replacement, legacy state, and proven-forwarding
    /// lifecycle churn clear the streak. The classification and marker clear land in one write.
    ///
    /// Atomic BY REPRESENTATION rather than by ordering: the earlier two-item shape had
    /// to choose which half a kill between the writes would corrupt (a lost strike versus
    /// a double count), and review found a third corruption on the clean-stop path — a
    /// cleared marker whose streak reset never landed, compounding non-consecutive
    /// crashes into a premature exclusion (Codex, PR #499). With both halves in one
    /// record there is no between: an interrupted transition changes nothing, and the
    /// same death is counted exactly once whenever the write finally lands.
    public func consumeUncleanTerminationEvidence(
        from snapshot: Snapshot, currentBuildIdentity: String
    ) throws -> Snapshot {
        try items.withExclusiveLifecycleEvidenceAccess {
            // Re-read the record and its generation-addressed proof inside the same bounded
            // transition as the consume write. Proof publication and replacement-marker install
            // and every record writer take this coordination too, so neither can land between
            // classification and clear. Always return the live record: explicit recovery may
            // have cleared a stale suppression after the provider captured `snapshot`.
            var record = try storedRecord() ?? .clean
            guard snapshot.uncleanTerminationMarkerIsSet,
                record.uncleanTerminationMarkerIsSet,
                record.activeSessionLifecycleID == snapshot.activeSessionLifecycleID
            else {
                return try liveSnapshot(
                    from: record,
                    experimentalOverrideEnabled: snapshot.experimentalOverrideEnabled)
            }
            let generationForwardingProof: Bool
            if let lifecycleID = record.activeSessionLifecycleID {
                generationForwardingProof = try items.load(
                    account: Self.forwardingProofAccount(lifecycleID: lifecycleID)) != nil
            } else {
                generationForwardingProof = false
            }
            let advanced: ChainedStartupCrashLoopPolicy.State
            if record.activeSessionBuildIdentity == currentBuildIdentity,
                !record.activeSessionWasProvenHealthy,
                !generationForwardingProof
            {
                advanced = ChainedStartupCrashLoopPolicy.unprovenExitDetected(
                    in: record.backoffState)
            } else {
                // Build replacement, a legacy marker, or a lifecycle that already forwarded is not
                // evidence of a startup crash loop. It also breaks any preceding unproven streak.
                advanced = .clean
            }
            record.backoffState = advanced
            record.uncleanTerminationMarkerIsSet = false
            record.crashLoopSchemaVersion = TerminationRecord.currentCrashLoopSchemaVersion
            record.activeSessionBuildIdentity = nil
            record.activeSessionLifecycleID = nil
            record.activeSessionWasProvenHealthy = false
            try writeRecord(record)
            deleteForwardingProofIfPresent(lifecycleID: snapshot.activeSessionLifecycleID)
            return try liveSnapshot(
                from: record,
                experimentalOverrideEnabled: snapshot.experimentalOverrideEnabled)
        }
    }

    /// A deliberate Guard start is the recovery boundary. It clears every persisted suppression
    /// that could make the next start ignore the saved chaining setting. The tunnel exclusively
    /// owns lifecycle markers: recovery preserves whichever marker is current, so it cannot erase
    /// evidence for an already-running provider; a replacement provider consumes a stale marker
    /// before installing its own. Automatic Connect-On-Demand starts never call this transition.
    public func prepareForExplicitGuardStart() throws {
        try items.withExclusiveLifecycleEvidenceAccess {
            // Re-read under the same transaction as marker install. Reset only the app-owned
            // recovery latches around the record; the marker generation and its forwarding proof
            // remain tunnel-owned. If a provider installed first, this write carries its marker.
            // If it installs second, it sees this reset record and installs afterward.
            let current = try storedRecord() ?? .clean
            var recovered = current
            recovered.backoffState = .clean
            recovered.surrenderReasonLogValue = nil
            recovered.autoRecoveryEpochs = []
            recovered.crashLoopSchemaVersion = TerminationRecord.currentCrashLoopSchemaVersion
            guard recovered != current else { return }
            try writeRecord(recovered)
        }
    }

    /// Persists the surrender suppression AND settles the session marker, in ONE write
    /// (C4). Tunnel-side, and it must land BEFORE the restart that follows a surrender: a
    /// crash between the two must wake into a latch that still refuses chained, or the
    /// blackhole the surrender ended comes back wearing a fresh session.
    ///
    /// The single write is what makes the crash window benign. The two-item shape needed a
    /// second write to settle the marker, and a kill between them left a set marker beside
    /// a set suppression — which the next launch counted as a jetsam death, so repeated
    /// surrender/Reset cycles could exclude a device that never jetsammed. Here the marker
    /// settles in the same `SecItemUpdate` that records the surrender: the session is
    /// ending through a controlled transition, and no interruption can separate the two
    /// facts (Codex, PR #505 rounds 1–2). The streak is deliberately untouched — a
    /// surrender is evidence of neither coping nor thrashing.
    ///
    /// A throw or `false` return is treated as "restart anyway, and log loudly": a suppression
    /// that could not persist is strictly better honoured for one lifecycle (the driver's own
    /// `hasSurrendered` latch) than not at all, and refusing to restart would leave the
    /// claimed default route with no data path — the state C4 exists to end.
    @discardableResult
    public func recordChainedSurrender(
        owningLifecycleID: String?, reasonLogValue: String,
        isStillWanted: () -> Bool = { true }
    ) throws -> Bool {
        try items.withExclusiveLifecycleEvidenceAccess {
            // Preserve the auto-recovery window from the live record: a surrender that follows a
            // hands-free recovery must keep the spent attempts on the clock. The lifecycle fence
            // also prevents a retired provider from clearing its replacement's marker.
            let current = try storedRecord() ?? .clean
            guard current.uncleanTerminationMarkerIsSet
                    == (owningLifecycleID != nil),
                current.activeSessionLifecycleID == owningLifecycleID
            else { return false }
            guard isStillWanted() else { return false }
            try writeRecord(
                TerminationRecord(
                    backoffState: current.backoffState,
                    uncleanTerminationMarkerIsSet: false,
                    surrenderReasonLogValue: reasonLogValue,
                    autoRecoveryEpochs: current.autoRecoveryEpochs))
            deleteForwardingProofIfPresent(lifecycleID: current.activeSessionLifecycleID)
            return true
        }
    }

    /// QA fixture repair: ONE write clears every standing suppression — the
    /// surrender AND the jetsam backoff, count and exclusion alike, via
    /// ``ChainedStartupCrashLoopPolicy/explicitRetryRequested(from:)`` — so the next latch resolution
    /// may select chained again. It is not exposed as a product control.
    ///
    /// One control, deliberately, not one per suppression. The two suppressions present to
    /// the user identically — chained mode stopped and stays off — and a Reset that cleared
    /// only the surrender would leave an excluded device exactly where it started: a dead
    /// control wearing a live one's label. The backoff goes through `explicitRetryRequested`, whose
    /// own doc argues the full-tolerance restore — a re-enable that kept the counter at its
    /// threshold would re-exclude on the very next unclean termination, one strike instead
    /// of three.
    ///
    /// The unclean-termination MARKER is preserved, not cleared: it is evidence of a death
    /// that already happened, not a suppression, and a Reset racing a live chained session
    /// must not erase the crash the safety net is mid-way through witnessing. A pending
    /// marker after a Reset costs exactly one strike against the freshly restored
    /// tolerance — the honest reading of "that death still counts".
    ///
    /// Reads and writes the record inside the same app/tunnel lifecycle transaction rather
    /// than trusting a caller's snapshot. A concurrent teardown, surrender, recovery, or
    /// marker install therefore orders wholly before or wholly after this repair.
    public func userResetChainedSuppressions() throws {
        try items.withExclusiveLifecycleEvidenceAccess {
            let record = try storedRecord() ?? .clean
            // Also fires on a non-empty auto-recovery window with nothing else standing: after a
            // successful hands-free recovery the record is surrender=nil + backoff=clean + spent
            // epochs, and a Reset must clear that budget too.
            guard record.surrenderReasonLogValue != nil
                || record.backoffState != .clean
                || !record.autoRecoveryEpochs.isEmpty
            else {
                return
            }
            try writeRecord(
                TerminationRecord(
                    backoffState: ChainedStartupCrashLoopPolicy.explicitRetryRequested(
                        from: record.backoffState),
                    uncleanTerminationMarkerIsSet: record.uncleanTerminationMarkerIsSet,
                    surrenderReasonLogValue: nil,
                    activeSessionBuildIdentity: record.activeSessionBuildIdentity,
                    activeSessionLifecycleID: record.activeSessionLifecycleID,
                    activeSessionWasProvenHealthy: record.activeSessionWasProvenHealthy))
        }
    }

    /// The user's own re-enable clears a STANDING SURRENDER — and only the surrender.
    ///
    /// A surrender is a transient verdict: the chain forwarded nothing for longer than the
    /// blackhole budget on SOME path, so the tunnel fell back to DNS-only. When the user
    /// themselves turns protection on again, that is a fresh, deliberate "try chained now" — a
    /// stronger and more recent signal than a surrender left over from a network that may be
    /// long gone (the field evidence: a phone carried through roams and sleep/wake surrenders on
    /// `budgetExhausted` and then sits DNS-only until a manual Reset, which is not the paid
    /// experience). So the standing surrender is cleared here and the next latch may select
    /// chained again, without the user having to find the explicit Reset control.
    ///
    /// It clears the surrender ALONE, deliberately unlike ``userResetChainedSuppressions()``:
    /// the jetsam backoff is a device-HEALTH exclusion (repeated unclean terminations under the
    /// ~50 MB `INV-MEM-1` ceiling), not a network verdict, and a casual protection toggle must
    /// not reset the memory safety net for every user — that override stays with the explicit
    /// Reset, whose `explicitRetryRequested` restores full tolerance on a conscious choice. A device that
    /// is jetsam-excluded therefore stays DNS-only through a plain re-enable (the honest
    /// outcome: it cannot run chained), which is exactly what the Reset exists to override.
    ///
    /// A no-op when no surrender stands. The shared transaction orders this transition with
    /// tunnel-side marker and surrender writes. The marker and backoff are carried through
    /// untouched; the hands-free auto-recovery window is RESET (a deliberate user retry is a
    /// fresh start, so it gets a fresh recovery budget).
    /// pinned: ChainedDeviceEligibilityStoreTests.testAUserReEnableClearsTheSurrenderButKeepsTheBackoff
    public func clearStandingSurrenderOnUserReEnable() throws {
        try items.withExclusiveLifecycleEvidenceAccess {
            // Fires on a non-empty window with NO standing surrender too: after a successful
            // hands-free recovery the record is `surrender=nil` but `epochs=[spent]`, and a user
            // turn-on must clear that spent budget.
            guard let record = try storedRecord(),
                record.surrenderReasonLogValue != nil || !record.autoRecoveryEpochs.isEmpty
            else { return }
            try writeRecord(
                TerminationRecord(
                    backoffState: record.backoffState,
                    uncleanTerminationMarkerIsSet: record.uncleanTerminationMarkerIsSet,
                    surrenderReasonLogValue: nil,
                    autoRecoveryEpochs: [],
                    activeSessionBuildIdentity: record.activeSessionBuildIdentity,
                    activeSessionLifecycleID: record.activeSessionLifecycleID,
                    activeSessionWasProvenHealthy: record.activeSessionWasProvenHealthy))
        }
    }

    /// The recorded epochs of recent HANDS-FREE surrender auto-recoveries, for the caller (the
    /// tunnel's path-change handler) to feed ``ChainedSurrenderAutoRecoveryPolicy`` when a
    /// satisfied path returns while surrendered. Empty when no record or none recorded.
    public func readAutoRecoveryEpochs() throws -> [Double] {
        (try storedRecord())?.autoRecoveryEpochs ?? []
    }

    /// The decision a hands-free auto-recovery attempt reached — enough for the caller to log honestly.
    public enum AutoRecoveryOutcome: Equatable, Sendable {
        /// Proceed to restart the tunnel: either a recoverable surrender was just cleared, or the
        /// store surrender was already gone (an aborted recovery) and a plain restart finishes it.
        case restart
        /// The surrender is a fault a network change cannot clear — leave it standing.
        case declinedNonTransient
        /// The rolling-window cap is spent — leave it standing until an epoch ages out or the user acts.
        case declinedCapExhausted
        /// No stored record, or the lifecycle/path fence was lost at write time — do nothing.
        case declinedUnavailable
    }

    /// Decides and (when it clears) records a hands-free auto-recovery, in ONE store read.
    ///
    /// The ORDER matters (Codex, PR #569): the ALREADY-CLEARED case is handled BEFORE the cap, so an
    /// aborted FINAL recovery — which left the store surrender cleared while the live latch still
    /// reads `.chainedSurrendered` — completes with a plain restart even though the window is spent
    /// (it records no new attempt, so there is no cap to apply). Then the reason gate (only a
    /// network-transient `budgetExhausted` is recovered), then the rolling-window cap, then the
    /// write. The whole decision lives here so the cap can never pre-empt the already-cleared
    /// restart, and so the epochs are read and pruned against the same snapshot they are written from.
    ///
    /// `isStillWanted` is re-checked after the read and before the write — the read is a Keychain
    /// round-trip, and this mutates the SHARED surrender flag, so a stale task must not clear a NEWER
    /// lifecycle's surrender (Codex, PR #569). The backoff and marker are carried through.
    /// pinned: ChainedDeviceEligibilityStoreTests.testAnAutoRecoveryClearsTheSurrenderAndRecordsTheAttempt
    public func recordSurrenderAutoRecovery(
        nowEpoch: Double,
        onlyIfAlreadyCleared: Bool = false,
        isRecoverableReason: (String) -> Bool = { _ in true },
        isStillWanted: () -> Bool = { true }
    ) throws -> AutoRecoveryOutcome {
        try items.withExclusiveLifecycleEvidenceAccess {
            guard let record = try storedRecord() else { return .declinedUnavailable }
            guard let reason = record.surrenderReasonLogValue else {
                // Already cleared (an aborted recovery / Reset) while the live latch still reads
                // surrendered: nothing to clear, no budget to spend, no cap — a plain restart finishes it.
                return .restart
            }
            // A "complete-only" attempt — a NEW lifecycle's initial satisfied update finishing a
            // handoff that the previous lifecycle's recovery cleared but could not restart — must NOT
            // clear a STANDING surrender, only finish one already cleared (handled above).
            guard !onlyIfAlreadyCleared else { return .declinedUnavailable }
            guard isRecoverableReason(reason) else { return .declinedNonTransient }
            let decision = ChainedSurrenderAutoRecoveryPolicy.evaluate(
                recentEpochs: record.autoRecoveryEpochs, nowEpoch: nowEpoch)
            guard decision.mayRecover else { return .declinedCapExhausted }
            guard isStillWanted() else { return .declinedUnavailable }
            try writeRecord(
                TerminationRecord(
                    backoffState: record.backoffState,
                    uncleanTerminationMarkerIsSet: record.uncleanTerminationMarkerIsSet,
                    surrenderReasonLogValue: nil,
                    autoRecoveryEpochs: decision.prunedWindow,
                    activeSessionBuildIdentity: record.activeSessionBuildIdentity,
                    activeSessionLifecycleID: record.activeSessionLifecycleID,
                    activeSessionWasProvenHealthy: record.activeSessionWasProvenHealthy))
            return .restart
        }
    }

    /// Reconstructs the complete decision snapshot from the record that won the lifecycle
    /// transaction. This is intentionally used by marker consumption instead of combining its
    /// live backoff result with suppression fields from the provider's earlier read.
    private func liveSnapshot(
        from record: TerminationRecord,
        experimentalOverrideEnabled: Bool
    ) throws -> Snapshot {
        let generationForwardingProof: Bool
        if record.uncleanTerminationMarkerIsSet,
            let lifecycleID = record.activeSessionLifecycleID
        {
            generationForwardingProof = try items.load(
                account: Self.forwardingProofAccount(lifecycleID: lifecycleID)) != nil
        } else {
            generationForwardingProof = false
        }
        let migratedBackoffState = record.crashLoopSchemaVersion
            < TerminationRecord.currentCrashLoopSchemaVersion
            ? ChainedStartupCrashLoopPolicy.State.clean
            : record.backoffState
        return Snapshot(
            experimentalOverrideEnabled: experimentalOverrideEnabled,
            backoffState: migratedBackoffState,
            uncleanTerminationMarkerIsSet: record.uncleanTerminationMarkerIsSet,
            surrenderReasonLogValue: record.surrenderReasonLogValue,
            activeSessionBuildIdentity: record.activeSessionBuildIdentity,
            activeSessionLifecycleID: record.activeSessionLifecycleID,
            activeSessionWasProvenHealthy:
                record.activeSessionWasProvenHealthy || generationForwardingProof)
    }

    /// The stored termination record, independent of any caller's snapshot — the source both
    /// the suppression and the auto-recovery window are preserved from.
    private func storedRecord() throws -> TerminationRecord? {
        guard let data = try items.load(account: Self.terminationRecordAccount) else { return nil }
        return try? JSONDecoder().decode(TerminationRecord.self, from: data)
    }

    private func writeRecord(_ record: TerminationRecord) throws {
        try items.save(
            try JSONEncoder().encode(record), account: Self.terminationRecordAccount)
    }

    private func deleteForwardingProofIfPresent(lifecycleID: String?) {
        guard let lifecycleID else { return }
        try? items.delete(account: Self.forwardingProofAccount(lifecycleID: lifecycleID))
    }

    private static func decodeFlag(_ data: Data) -> Bool? {
        guard data.count == 1 else { return nil }
        switch data[data.startIndex] {
        case 0: return false
        case 1: return true
        default: return nil
        }
    }
}
