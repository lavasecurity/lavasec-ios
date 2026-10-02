import Foundation

/// The key-item half of the chained-upstream store, as a seam.
///
/// A protocol and not a direct `SecItem` call, because the live Keychain is not exercisable in
/// host unit tests (`GenericKeychainStoreTests` records why) and the properties that matter
/// here are BEHAVIOURAL — that an interrupted rotation leaves a consistent pair, that a sweep
/// never deletes the committed key, that "delete my key" deletes every generation. Pinning
/// query dictionaries would assert the shape of the calls and nothing about the protocol they
/// implement.
///
/// `add` is ADDITIVE, never an upsert. The commit protocol depends on a new key landing
/// WITHOUT disturbing the currently committed one; an upsert at a colliding account would
/// replace a key that a live configuration still names.
public protocol ChainedUpstreamKeyItemStore: Sendable {
    /// Store `key` at `account`. Fails if the account already holds an item.
    func add(_ key: Data, account: String) throws
    /// The bytes at `account`, or `nil` if no item exists.
    func load(account: String) throws -> Data?
    /// Remove `account`. A missing item is not an error.
    func delete(account: String) throws
    /// Every account this store holds, in no particular order.
    func accounts() throws -> [String]
}

/// The chained-upstream secret store: configuration in the shared container, key in the
/// Keychain, bound by one generation per rotation.
///
/// Plan constraint C6, and the shape is the answer to it. See `INV-CHAIN-4`.
///
/// ## Why two stores rather than one record
///
/// A single Keychain item holding both halves would make tearing impossible — and would also
/// make ``ChainedUpstreamStoreRead/configurationWithoutKey`` unreachable, because one item is
/// present or absent as a unit. That state is not a curiosity: `ThisDeviceOnly` items are
/// excluded from every backup and do not survive device migration, while an app-group file
/// does, so a migrated device legitimately holds a configuration whose key is gone. Reporting
/// that as "nothing configured" sends the user to set the feature up from scratch instead of
/// re-entering a key, which is exactly the distinction
/// `ChainedUpstreamSecretStore`'s two-read shape exists to preserve.
///
/// ## The commit protocol
///
/// ```
/// G = mint(excluding: committed)
/// 1. add the key at account keyAccount(G)          ADDITIVE — the committed pair is untouched
/// 2. atomically replace the configuration file      THE COMMIT POINT — one rename(2)
/// 3. delete every other key account                 idempotent, best-effort
/// ```
///
/// Every interruption leaves a consistent pair, so the durable torn write is UNREPRESENTABLE
/// rather than merely detectable:
///
/// | killed after | configuration | keys present   | a reader sees                 |
/// |--------------|---------------|----------------|-------------------------------|
/// | step 1       | G_old         | G_old, G_new   | consistent at G_old           |
/// | step 2       | G_new         | G_old, G_new   | consistent at G_new + orphan  |
/// | mid step 3   | G_new         | G_new (+ some) | consistent at G_new           |
///
/// That matters because the alternative is not a transient fault: a durably mismatched pair
/// would make `consistentSnapshot` report `.keptChangingUnderneath` on every evaluation for
/// the life of the install — a refusal whose own documentation says "the store answered every
/// time, it simply never held still", which would be a lie about a store holding perfectly
/// still and permanently broken.
///
/// The table above is about INTERRUPTION — one writer, killed. Concurrency is a separate
/// obligation and is carried by a separate mechanism: every public writer runs under
/// ``withWriterLock(_:)``, which refuses rather than degrading open, because the step-3 sweep
/// has a gap between the generation it reads and the deletes it performs that no ordering of
/// the three steps can close (``sweepOrphanedKeys()`` states the interleave). Neither half
/// is sufficient alone, and the claim is only as strong as the weaker of the two.
///
/// ## Isolation
///
/// A `struct` of `let`s, so `Sendable` with no annotation and no actor. Deliberately not an
/// actor: `ChainedUpstreamReadiness.evaluate` is synchronous and feeds a synchronous
/// `TunnelDataPathLatch.resolve`, and an actor would force `await` into the tunnel's latch
/// path. `SecItem*` is thread-safe and daemon-serialized, and cross-process write ordering is
/// the advisory lock's job, not an isolation domain's.
///
/// ## Memory (`INV-MEM-1`)
///
/// Nothing is cached. A readiness evaluation costs one ~300-byte JSON decode plus one 32-byte
/// Keychain copy per read attempt, once per latch evaluation — never per packet. A cached
/// record would be a resident secret in a ~50 MB process AND a stale generation, which would
/// make the tear detection agree with a value that is no longer stored.
public struct ChainedUpstreamKeychainStore: Sendable {
    /// Bumped only for a layout change the previous reader cannot parse. An unknown value is
    /// `configurationUnusable`, never "generation 0" and never a silent delete from a read
    /// path.
    static let schema = 1

    private let containerURL: URL
    private let identity: ChainedUpstreamStoreIdentity
    private let keyItems: any ChainedUpstreamKeyItemStore
    private let mint: ChainedUpstreamGenerationMint
    private let now: @Sendable () -> Date

    /// - Parameter identity: which build's records to address. NO default, deliberately: the
    ///   QA and production builds share one App Group container, so a defaulted identity is a
    ///   QA build silently rotating the production tunnel's configuration out from under it.
    ///   The app and the tunnel both pass `LavaSecAppGroup.chainedUpstreamStoreIdentity`,
    ///   which is selected by the same build configuration that scopes the access group the
    ///   `keyItems` backend was constructed with.
    public init(
        containerURL: URL,
        identity: ChainedUpstreamStoreIdentity,
        keyItems: any ChainedUpstreamKeyItemStore,
        mint: ChainedUpstreamGenerationMint = ChainedUpstreamGenerationMint(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.containerURL = containerURL
        self.identity = identity
        self.keyItems = keyItems
        self.mint = mint
        self.now = now
    }

    /// `FileManager` is not `Sendable`, so it is reached rather than stored — this type has to
    /// stay a `Sendable` struct for the tunnel's synchronous latch path. The shared instance's
    /// file operations are documented thread-safe, and the suite injects a temp `containerURL`
    /// instead of a manager.
    private var fileManager: FileManager { .default }

    /// The committed blob.
    ///
    /// `schema` and `generation` are required and NON-DEFAULTED. A `decodeIfPresent ?? 0` is
    /// how two independently damaged halves both read `0`, compare equal, and let the
    /// consistency check agree with a lie — so the absence of a default is the check.
    struct Envelope: Codable, Sendable {
        let schema: Int
        let generation: UInt64
        let configuration: ChainedUpstreamConfiguration
        // Optional for configurations committed before save dates were recorded. Keep this
        // in the same atomic envelope: a separate preference could date the wrong rotation.
        // pinned: ChainedUpstreamKeychainStoreTests.testSaveDateTravelsWithTheCommittedRotation
        var savedAt: Date? = nil
    }

    /// The non-secret configuration and its metadata, read from one committed envelope.
    public struct StoredConfiguration: Sendable {
        /// Parsed settings, without private or pre-shared key material.
        public let configuration: ChainedUpstreamConfiguration
        /// The rotation these settings belong to.
        public let generation: UInt64
        /// When this rotation was saved; nil for records predating save-date metadata.
        public let savedAt: Date?
    }

    var configurationURL: URL {
        containerURL.appendingPathComponent(
            ChainedUpstreamSecretNaming.configurationFilename(for: identity))
    }

    private var writeLockURL: URL {
        containerURL.appendingPathComponent(
            ChainedUpstreamSecretNaming.writeLockFilename(for: identity))
    }

    /// Entry secrets are available only to the runtime and atomic store mutation, never the editor.
    public func loadStoredEntryKeyMaterial() throws -> (privateKey: Data, presharedKey: Data?, generation: UInt64)? {
        guard let record = try loadStoredConfigurationRecord(), !record.configuration.precedingHops.isEmpty,
              let data = try keyItems.load(account: ChainedUpstreamSecretNaming.keyAccount(for: record.generation)),
              let chain = ChainedUpstreamKeyItemCodec.decodeChain(data) else { return nil }
        return (chain.entry.privateKey, chain.entry.presharedKey, record.generation)
    }

    /// Add, replace or rename one row under the same writer lock as the atomic chain commit.
    /// An expected generation prevents an open editor from overwriting a newer saved chain.
    @discardableResult
    public func saveHop(index: Int, name: String, replacement: ChainedUpstreamRotation?, expectedGeneration: UInt64?) throws -> UInt64 {
        try withWriterLock {
            let record = try loadStoredConfigurationRecord()
            guard record?.generation == expectedGeneration else { throw WireGuardChainFailure.changed }
            if index == 0, record?.configuration.precedingHops.isEmpty != false, let replacement {
                return try commitLocked(ChainedUpstreamRotation(configuration: replacement.configuration.named(name),
                    privateKey: replacement.privateKey, presharedKey: replacement.presharedKey))
            }
            var rotations = try storedRotations(record)
            guard index >= 0, index <= rotations.count, index < 2 else { throw WireGuardChainFailure.tooManyHops }
            let source: ChainedUpstreamRotation
            if let replacement { source = replacement }
            else if index < rotations.count { source = rotations[index] }
            else { throw WireGuardChainFailure.missingSecret }
            let named = try ChainedUpstreamRotation(configuration: source.configuration.withoutEntryHop().named(name),
                privateKey: source.privateKey, presharedKey: source.presharedKey)
            if index == rotations.count { rotations.append(named) } else { rotations[index] = named }
            return try commitLocked(composedRotation(rotations))
        }
    }

    /// Removes one of two rows atomically. Removing the final row uses removeAll instead.
    @discardableResult
    public func removeHop(index: Int, expectedGeneration: UInt64) throws -> UInt64 {
        try withWriterLock {
            let record = try loadStoredConfigurationRecord()
            guard record?.generation == expectedGeneration else { throw WireGuardChainFailure.changed }
            var rotations = try storedRotations(record)
            guard rotations.count == 2, rotations.indices.contains(index) else { throw WireGuardChainFailure.changed }
            rotations.remove(at: index)
            return try commitLocked(composedRotation(rotations))
        }
    }

    /// Commits the entire nonempty page draft in one generation, never one hop at a time.
    /// Stored keys are read only here, after Save, and only when a retained row needs them.
    @discardableResult
    public func commitEdits(_ draft: ChainedUpstreamEditDraft) throws -> UInt64 {
        try withWriterLock {
            let record = try loadStoredConfigurationRecord()
            guard record?.generation == draft.generation, !draft.resetsStorage else { throw WireGuardChainFailure.changed }
            let retained = draft.rows.contains { $0.replacement == nil }
            let stored = retained ? try storedRotations(record) : []
            let rotations = try draft.rows.map { row -> ChainedUpstreamRotation in
                let source: ChainedUpstreamRotation
                if let replacement = row.replacement { source = replacement }
                else if let index = row.originalIndex, stored.indices.contains(index) { source = stored[index] }
                else { throw WireGuardChainFailure.missingSecret }
                return try ChainedUpstreamRotation(configuration: row.configuration,
                    privateKey: source.privateKey, presharedKey: source.presharedKey)
            }
            return try commitLocked(composedRotation(rotations))
        }
    }

    private func composedRotation(_ rows: [ChainedUpstreamRotation]) throws -> ChainedUpstreamRotation {
        guard let exit = rows.last, rows.count <= 2 else { throw WireGuardChainFailure.tooManyHops }
        guard rows.count == 2 else { return exit }
        return try ChainedUpstreamRotation(configuration: exit.configuration.withEntryHop(rows[0].configuration),
            privateKey: exit.privateKey, presharedKey: exit.presharedKey, precedingRotations: [rows[0]])
    }

    private func storedRotations(_ record: StoredConfiguration?) throws -> [ChainedUpstreamRotation] {
        guard let record else { return [] }
        guard let material = try loadStoredKeyMaterial(), material.generation == record.generation else {
            throw WireGuardChainFailure.missingSecret
        }
        let exit = try ChainedUpstreamRotation(configuration: record.configuration.withoutEntryHop(),
            privateKey: material.privateKey, presharedKey: material.presharedKey)
        guard let entry = record.configuration.precedingHops.first else { return [exit] }
        guard let keys = try loadStoredEntryKeyMaterial(), keys.generation == record.generation else {
            throw WireGuardChainFailure.missingSecret
        }
        return [try ChainedUpstreamRotation(configuration: entry, privateKey: keys.privateKey, presharedKey: keys.presharedKey), exit]
    }

    // MARK: - Reads (tunnel and app; never take the writer lock)

    /// The stored configuration and the generation it is committed at, or `nil` if none is
    /// stored.
    ///
    /// - Throws: ``ChainedUpstreamSecretStoreFailure/configurationUnreadable(_:)`` when the
    ///   file exists but cannot be read (`INV-PERSIST-1` — unreadable is never absent), and
    ///   ``ChainedUpstreamSecretStoreFailure/configurationUnusable`` when it decodes to
    ///   something this build cannot run.
    public func loadStoredConfiguration() throws -> (ChainedUpstreamConfiguration, UInt64)? {
        try loadStoredConfigurationRecord().map { ($0.configuration, $0.generation) }
    }

    /// Reads settings and save metadata together, without fetching any stored key material.
    /// Uses the same absent/unreadable/unusable distinction as `loadStoredConfiguration()`.
    public func loadStoredConfigurationRecord() throws -> StoredConfiguration? {
        switch SharedStateFileReader.read(Envelope.self, from: configurationURL) {
        case .absent:
            return nil
        case .unreadable(let description):
            throw ChainedUpstreamSecretStoreFailure.configurationUnreadable(description)
        case .corrupt:
            // `SharedStateFileReader.read` decodes with `try?`, so this covers BOTH "not JSON"
            // and "`ChainedUpstreamConfiguration.init(from:)` refused it" — a validator that
            // tightened since the value was written lands here, not in `unreadable`.
            throw ChainedUpstreamSecretStoreFailure.configurationUnusable
        case .loaded(let envelope):
            guard [Self.schema, 3, 4].contains(envelope.schema), envelope.generation != 0 else {
                throw ChainedUpstreamSecretStoreFailure.configurationUnusable
            }
            return StoredConfiguration(
                configuration: envelope.configuration, generation: envelope.generation,
                savedAt: envelope.savedAt)
        }
    }

    /// The stored secret half — the private key, its optional pre-shared key, and the
    /// generation both were fetched under — or `nil` if none is stored.
    ///
    /// Both secrets live in ONE key item, encoded by ``ChainedUpstreamKeyItemCodec``, so this is
    /// the single read that recovers them together: a rotation cannot commit one without the
    /// other, and reading them apart would reintroduce the tear the one-item layout closes.
    ///
    /// The configuration read inside here is not the tear the protocol warns about: the commit
    /// point NAMES the live key, so this reports the generation the key was actually fetched
    /// at, which is honest. A rotation landing between the caller's own configuration read and
    /// this one produces a mismatch the caller's retry resolves; a sweep that removed the old
    /// account in the same window produces `nil`, which the caller's recheck branch resolves
    /// by observing that the committed generation moved.
    ///
    /// BACKWARD COMPATIBLE: a value written before PSK support — a bare 32-byte private key —
    /// decodes to `presharedKey == nil` rather than failing, so an install that rotated under
    /// the old format stays readable across the update (see ``ChainedUpstreamKeyItemCodec``).
    public func loadStoredKeyMaterial() throws
        -> (privateKey: Data, presharedKey: Data?, generation: UInt64)?
    {
        guard let (_, generation) = try loadStoredConfiguration() else { return nil }
        guard let value = try keyItems.load(
            account: ChainedUpstreamSecretNaming.keyAccount(for: generation))
        else { return nil }
        if let chain = ChainedUpstreamKeyItemCodec.decodeChain(value) {
            return (chain.exit.privateKey, chain.exit.presharedKey, generation)
        }
        let decoded = ChainedUpstreamKeyItemCodec.decode(value)
        return (decoded.privateKey, decoded.presharedKey, generation)
    }

    /// The stored private key and the generation it was fetched under, or `nil`.
    ///
    /// Last active profile's keys, selected under the same generation as its metadata.
    /// The saved last row may be disabled; never pair its keys with the active first row.
    public func loadActiveKeyMaterial() throws -> (privateKey: Data, presharedKey: Data?, generation: UInt64)? {
        guard let record = try loadStoredConfigurationRecord(),
              let index = record.configuration.orderedHops.lastIndex(where: \.isEnabled) else { return nil }
        let material = try index == record.configuration.orderedHops.count - 1
            ? loadStoredKeyMaterial() : loadStoredEntryKeyMaterial()
        guard let material else { return nil }
        guard material.generation == record.generation else { throw WireGuardChainFailure.changed }
        return material
    }

    /// A projection of ``loadStoredKeyMaterial()`` that drops the PSK, kept because the app's
    /// "is a key stored" check and the C6 generation tests only need these two — the one place
    /// that needs the PSK reads the full material through the protocol conformance.
    public func loadStoredPrivateKey() throws -> (Data, UInt64)? {
        try loadStoredKeyMaterial().map { ($0.privateKey, $0.generation) }
    }

    // MARK: - Writes (app process; each public entry point takes the writer lock)

    /// Commit a rotation. Returns the generation it landed at.
    ///
    /// - Throws: ``ChainedUpstreamSecretStoreFailure`` — and when it throws, NOTHING is
    ///   committed: the previously committed pair is intact and no reader can observe the
    ///   failed rotation, because the configuration file is the only commit point and it is
    ///   written last.
    @discardableResult
    public func commit(_ rotation: ChainedUpstreamRotation) throws -> UInt64 {
        try withWriterLock { try commitLocked(rotation) }
    }

    private func commitLocked(_ rotation: ChainedUpstreamRotation) throws -> UInt64 {
            let committed = try loadCommittedGenerationForWriting()
            let generation = try mint.mint(excluding: committed)
            let value: Data
            if let entry = rotation.precedingRotations.first {
                value = ChainedUpstreamKeyItemCodec.encodeChain(
                    exit: (rotation.privateKey, rotation.presharedKey), entry: (entry.privateKey, entry.presharedKey))
            } else {
                value = ChainedUpstreamKeyItemCodec.encode(privateKey: rotation.privateKey, presharedKey: rotation.presharedKey)
            }
            try keyItems.add(value, account: ChainedUpstreamSecretNaming.keyAccount(for: generation))
            do {
                try commitConfiguration(rotation.configuration, at: generation)
            } catch {
                // THE STAGED KEY IS REMOVED BEFORE THE FAILURE PROPAGATES. A Keychain item
                // outlives the app's container — it survives deletion of the app — so a key
                // added for a rotation that then failed to commit is not merely garbage, it is
                // key material left on the device after the save was reported as failed.
                //
                // The launch sweep is NOT a backstop for this one. On the FIRST save there is
                // no committed configuration, and `sweep` deliberately does nothing in that
                // state (it has no generation to preserve, so it cannot tell an orphan from
                // the key of a rotation about to commit). So the orphan would persist
                // indefinitely, which is the case that matters most: the very first thing a
                // user ever stores here (Codex, PR #485).
                //
                // Best-effort on the way out, and it must be: this path is already failing,
                // and replacing the caller's real error — a full container, an unwritable
                // group — with a Keychain delete error would report the wrong cause.
                try? keyItems.delete(account: ChainedUpstreamSecretNaming.keyAccount(for: generation))
                throw error
            }
            // Best-effort, and it has to be: the rotation IS committed by the line above, so a
            // failed sweep cannot fail the call without reporting a successful write as an
            // error. The orphan is harmless (no configuration names it) and the launch sweep
            // is its backstop. `removeAll` is the opposite and is strict — "delete my key" is
            // not a best-effort operation.
            try? sweep(committed: generation)
            return generation
    }

    /// Finish a garbage collection an earlier process death interrupted. Idempotent.
    ///
    /// Safe to call at app launch. It re-reads the committed generation AFTER enumerating the
    /// accounts and abandons the pass if it moved, so a sweep that started before a rotation
    /// cannot delete the key that rotation just committed.
    ///
    /// The recheck NARROWS that window; it does not close it, and saying otherwise was the
    /// defect this shape was reviewed for. Nothing is atomic between the recheck and the
    /// deletes it authorizes: a writer whose `rename(2)` lands in that gap commits generation
    /// B, and this pass — still holding B's account in a list it computed against A — deletes
    /// B's key. The result is a configuration whose key is gone at a STABLE generation, which
    /// is durable, indistinguishable from the migrated-device flow, and exactly the torn pair
    /// the commit protocol claims to make unrepresentable.
    ///
    /// So writer exclusion is the guarantee here and the recheck is the defence in depth,
    /// not the other way round: ``withWriterLock(_:)`` refuses rather than proceeding
    /// unlocked, and a sweep that cannot establish exclusion throws
    /// ``ChainedUpstreamSecretStoreFailure/writerExclusionUnavailable`` having deleted
    /// nothing. `flock` is advisory, so what makes that sufficient is that every writer of
    /// these two halves is one of this type's public entry points — with ONE carve-out,
    /// stated rather than left for a reader to discover: the S9 device-QA surface deletes
    /// key items through the key-item store directly, to reproduce on one device what a
    /// restore to another looks like (configuration present, key gone). It is compiled only
    /// under `DEBUG || LAVA_QA_TOOLS`, it runs in the app while the only other writer is the
    /// same process, and it deletes rather than committing — so it cannot tear a pair or
    /// race a sweep, which has no production caller. A production writer added outside this
    /// type would still break the argument.
    /// pinned: ChainedUpstreamKeychainStoreTests.testASweepThatRacesARotationDeletesNothing
    /// pinned: ChainedUpstreamKeychainStoreTests.testASweepRefusesRatherThanRunningWithoutWriterExclusion
    public func sweepOrphanedKeys() throws {
        try withWriterLock {
            guard let (_, generation) = try loadStoredConfiguration() else {
                // No committed configuration means no generation to preserve, and deleting
                // "everything else" would delete everything. A store with orphans and no
                // configuration is what a killed FIRST rotation leaves; `removeAll` is the
                // only operation entitled to clear it.
                //
                // REDUNDANT with the recheck below and kept for the early exit and the stated
                // intent — mutation-verified: removing this guard alone leaves
                // `testASweepWithNoCommittedConfigurationDeletesNothing` GREEN, because the
                // recheck's own `nil` case returns. The property is enforced by the pair, not
                // by this line, and saying otherwise would be a claim the suite does not back.
                return
            }
            let accounts = try keyItems.accounts()
            // pinned: ChainedUpstreamKeychainStoreTests.testASweepWithNoCommittedConfigurationDeletesNothing
            guard let (_, recheck) = try loadStoredConfiguration(), recheck == generation else {
                return
            }
            for account in ChainedUpstreamSecretNaming.orphanedKeyAccounts(
                in: accounts, committed: generation)
            {
                try keyItems.delete(account: account)
            }
        }
    }

    /// Remove the configuration and EVERY key generation.
    ///
    /// Strict, not best-effort, and it enumerates rather than deleting the committed account:
    /// an orphan left behind is a live WireGuard private key readable by every process in the
    /// access group, and Keychain items survive app deletion. The configuration file is
    /// removed FIRST so that an interruption leaves keys nothing names, rather than a
    /// configuration whose key is gone — the latter would tell the user to re-enter a key
    /// they had just asked to delete. The cost of that ordering is honest and worth naming:
    /// an interrupted removal leaves key residue that ``sweepOrphanedKeys()`` will NOT clear
    /// (it declines to sweep with no committed configuration), so the recovery is another
    /// `removeAll`.
    ///
    /// This is also why nothing in this store deletes on a launch heuristic. Keychain items
    /// outliving app deletion is a real hazard, but "the control-plane file is absent, so this
    /// must be a reinstall" is the shape of the 2026-07-14 filter-library wipe (`INV-PERSIST-1`)
    /// with a strictly worse blast radius: the key is `ThisDeviceOnly` with no sync copy and no
    /// backup copy, so a wrongly-fired delete is unrecoverable. Clearing on reinstall needs a
    /// deliberate install marker and a founder decision, not an inference.
    public func removeAll() throws { try removeAll(expectedGeneration: nil, checksGeneration: false) }

    /// Deletes the saved chain only if it still matches the page's original generation.
    public func removeAll(expectedGeneration: UInt64?) throws {
        try removeAll(expectedGeneration: expectedGeneration, checksGeneration: true)
    }

    private func removeAll(expectedGeneration: UInt64?, checksGeneration: Bool) throws {
        try withWriterLock {
            if checksGeneration, try loadStoredConfigurationRecord()?.generation != expectedGeneration {
                throw WireGuardChainFailure.changed
            }
            do {
                try fileManager.removeItem(at: configurationURL)
            } catch CocoaError.fileNoSuchFile {
                // Already absent.
            } catch let error as NSError
                where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT)
            {
                // Already absent.
            }
            for account in try keyItems.accounts()
            where ChainedUpstreamSecretNaming.generation(fromKeyAccount: account) != nil {
                try keyItems.delete(account: account)
            }
        }
    }

    // MARK: - Commit steps
    //
    // Internal and UNLOCKED so the suite can stop between them and assert what a reader sees,
    // which is the only way to test "killed mid-rotation" without shipping a failure hook in
    // production code. Every public writer takes the lock exactly once and calls these; a step
    // must never take it itself, because `flock` conflicts between two descriptors in ONE
    // process and a nested acquire would self-deadlock.

    /// Adds the secret half for `generation` as ONE key item — private key and optional PSK
    /// together, so the additive-add invariant the commit protocol depends on covers both at
    /// once and a reader never sees one without the other. `presharedKey` defaults to `nil`,
    /// which keeps the crash-point tests (`addKeyItem(_:at:)`) compiling and writes the
    /// no-PSK layout.
    func addKeyItem(_ key: Data, presharedKey: Data? = nil, at generation: UInt64) throws {
        let value = ChainedUpstreamKeyItemCodec.encode(privateKey: key, presharedKey: presharedKey)
        try keyItems.add(value, account: ChainedUpstreamSecretNaming.keyAccount(for: generation))
    }

    func commitConfiguration(
        _ configuration: ChainedUpstreamConfiguration, at generation: UInt64
    ) throws {
        // INV-PERSIST-1 writer fence: replacing a file you cannot READ means you cannot know
        // what you are destroying. The blast radius here is worse than the filter library's —
        // the key is `ThisDeviceOnly` with no sync or backup copy, so there is nothing to
        // restore from — which is why the fence is taken even though the writer is a
        // foreground app that is almost always unlocked.
        guard !SharedStateFileReader.fileExistsButIsUnreadable(at: configurationURL) else {
            throw ChainedUpstreamSecretStoreFailure.configurationUnreadable("fence")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(
            Envelope(
                schema: configuration.orderedHops.contains(where: { !$0.isEnabled }) ? 4 : (configuration.precedingHops.isEmpty ? Self.schema : 3), generation: generation, configuration: configuration,
                savedAt: now()))
        // `.atomic` only — deliberately NOT the control-plane options. This file names the
        // server a user routes all traffic through, so it stays at the iOS default Class C
        // with the other privacy stores (INV-PERSIST-2). `.atomic` is the commit point: one
        // `rename(2)`, so a reader sees the old inode or the new one and never a splice.
        try data.write(to: configurationURL, options: .atomic)
    }

    func sweep(committed generation: UInt64) throws {
        for account in ChainedUpstreamSecretNaming.orphanedKeyAccounts(
            in: try keyItems.accounts(), committed: generation)
        {
            try keyItems.delete(account: account)
        }
    }

    /// The committed generation, treating "nothing stored" and "stored but unusable" alike.
    ///
    /// A rotation over an unusable configuration must be allowed — it is the recovery for the
    /// tightened-validator wedge. It must NOT be allowed over an UNREADABLE one, which is why
    /// only `configurationUnusable` is swallowed here and the unreadable throw propagates.
    private func loadCommittedGenerationForWriting() throws -> UInt64? {
        do {
            return try loadStoredConfiguration()?.1
        } catch ChainedUpstreamSecretStoreFailure.configurationUnusable {
            return nil
        }
    }

    /// Runs `body` under writer-vs-writer exclusion, or refuses.
    ///
    /// `withRequiredExclusiveLock` and NOT the plain `withExclusiveLock` the filter-publish
    /// path uses, which returns `try body()` from both of its guards and therefore runs
    /// UNLOCKED when the lock file cannot be opened or `flock` fails. That degrade policy is
    /// defensible where it is documented — the filter artifacts have a fail-closed read-side
    /// gate, so the cost of an unlocked publish is a redundant publish — and it is not
    /// defensible here, where `body` deletes a WireGuard private key that has no backup copy
    /// and no sync copy. Blocking rather than the non-blocking `withTryExclusiveLock`,
    /// because the writer is the foreground app with the user waiting on the save: a
    /// momentarily contended lock must be waited out, not turned into a failed save.
    /// pinned: ChainedUpstreamKeychainStoreTests.testASweepRefusesRatherThanRunningWithoutWriterExclusion
    private func withWriterLock<T>(_ body: () throws -> T) throws -> T {
        guard let result = try FilterPublishLock.withRequiredExclusiveLock(at: writeLockURL, body)
        else {
            throw ChainedUpstreamSecretStoreFailure.writerExclusionUnavailable
        }
        return result
    }
}

/// Serialises the secret half of a rotation — a private key plus an optional pre-shared key —
/// into ONE Keychain value, and back.
///
/// ## Why a byte layout and not JSON
///
/// The value it produces IS the `kSecValueData` of the key item, added and read raw by
/// ``ChainedUpstreamKeyItemStore``. A JSON envelope would put base64 of secret bytes in a
/// String — a second, longer-lived heap copy of key material inside the ~50 MB NE process
/// (`INV-MEM-1`) — where a fixed byte layout is the shortest thing that carries the two
/// secrets and the presence bit.
///
/// ## The layout, and the backward-compatibility contract
///
/// ```
/// [32 bytes private key][1 byte presence flag][32 bytes PSK, only when the flag is 0x01]
/// ```
///
/// A new write is always 33 bytes (no PSK, flag `0x00`) or 65 (PSK, flag `0x01`) — every new
/// value is self-describing. The one exception is READ-ONLY: a value written before PSK
/// support is a BARE 32-byte private key with no flag, and it MUST decode to `presharedKey ==
/// nil` rather than fail, or an install that rotated under the old format reports its key as
/// unreadable across the update. That is the whole reason 32 is a recognised length here.
///
/// ``decode(_:)`` never throws and never partially trusts a value it does not recognise: an
/// unrecognised layout is handed back WHOLE as the private key so the readiness length check
/// refuses it as `.malformedPrivateKey`, rather than silently returning a 32-byte prefix with
/// a dropped PSK — a truncated-but-plausible key aimed at the wrong peer is exactly the class
/// of silent failure the write boundary exists to stop.
/// pinned: ChainedUpstreamKeychainStoreTests.testTheCodecHandsAnUnrecognisedLayoutBackWholeWithNoPreSharedKey
/// pinned: ChainedUpstreamKeychainStoreTests.testAMalformedKeyItemValueRefusesAsMalformedPrivateKeyThroughReadiness
enum ChainedUpstreamKeyItemCodec {
    private static let keyLength = ChainedUpstreamConfiguration.privateKeyByteCount
    private static let pskLength = ChainedUpstreamConfiguration.presharedKeyByteCount
    private static let absentFlag: UInt8 = 0x00
    private static let presentFlag: UInt8 = 0x01

    typealias Material = (privateKey: Data, presharedKey: Data?)
    // Versioned binary chain: magic/version, exit length, exit material, entry material.
    // Each material uses the existing 33/65-byte format, without base64 String copies.
    private static let chainHeader: [UInt8] = [0x4c, 0x57, 0x47, 0x02]
    static func encodeChain(exit: Material, entry: Material) -> Data {
        let exitBytes = encode(privateKey: exit.privateKey, presharedKey: exit.presharedKey)
        var result = Data(chainHeader + [UInt8(exitBytes.count)])
        result.append(exitBytes)
        result.append(encode(privateKey: entry.privateKey, presharedKey: entry.presharedKey))
        return result
    }
    static func decodeChain(_ data: Data) -> (exit: Material, entry: Material)? {
        guard data.count >= 5, data.prefix(4).elementsEqual(chainHeader) else { return nil }
        let exitLength = Int(data[data.startIndex + 4])
        let entryLength = data.count - 5 - exitLength
        guard [33, 65].contains(exitLength), [33, 65].contains(entryLength) else { return nil }
        let exit = decode(Data(data.dropFirst(5).prefix(exitLength)))
        let entry = decode(Data(data.dropFirst(5 + exitLength)))
        guard exit.privateKey.count == keyLength, entry.privateKey.count == keyLength else { return nil }
        return (exit, entry)
    }

    static func encode(privateKey: Data, presharedKey: Data?) -> Data {
        var value = Data(privateKey)
        if let presharedKey {
            value.append(presentFlag)
            value.append(presharedKey)
        } else {
            value.append(absentFlag)
        }
        return value
    }

    static func decode(_ value: Data) -> (privateKey: Data, presharedKey: Data?) {
        let bytes = [UInt8](value)
        // Legacy: a bare private key, written before this codec existed.
        if bytes.count == keyLength {
            return (Data(bytes), nil)
        }
        if bytes.count == keyLength + 1, bytes[keyLength] == absentFlag {
            return (Data(bytes[0..<keyLength]), nil)
        }
        if bytes.count == keyLength + 1 + pskLength, bytes[keyLength] == presentFlag {
            return (
                Data(bytes[0..<keyLength]),
                Data(bytes[(keyLength + 1)..<(keyLength + 1 + pskLength)]))
        }
        // Unrecognised: hand it back whole so the length check downstream refuses it, rather
        // than fabricating a 32-byte key from a value we do not understand.
        return (Data(bytes), nil)
    }
}
