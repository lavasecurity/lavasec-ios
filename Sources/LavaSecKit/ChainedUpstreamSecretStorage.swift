import CryptoKit
import Foundation
import Security

/// Which build identity's chained-upstream records a store addresses.
///
/// The KEY half is already separated: `project.yml` scopes `LAVA_KEYCHAIN_SHARING_GROUP` per
/// build configuration, so a QA build's items land in `com.lavasec.dev.qa.chained-upstream`
/// and a production build's in `com.lavasec.app.chained-upstream`, and neither can see the
/// other's.
///
/// The FILE half has no entitlement to ride on. Both identities carry the SAME
/// `group.com.lavasec` App Group — that entitlement is not config-scoped, and making it so
/// would move every other shared file too — so without this the two builds would share one
/// `chained-upstream.json`. The failure that produces is silent and asymmetric, which is why
/// it is worth a type rather than a convention: a QA rotation replaces the generation the
/// PRODUCTION tunnel reads, while its key lands in the QA-only access group, so production
/// looks for `upstream-key/<QA generation>` in a group that does not have it, finds nothing,
/// and reports `Refusal.noPrivateKeyStored` — "re-enter your key" — until the user
/// reconfigures. The reverse happens on the next production rotation. Both builds are
/// installable side by side on one device precisely because their bundle IDs differ, so this
/// is the ordinary internal-testing arrangement, not an exotic one.
public enum ChainedUpstreamStoreIdentity: String, Sendable, Equatable, CaseIterable {
    /// The `com.lavasec.app*` identity: App Store, TestFlight, and local Debug builds, which
    /// share one identity because Debug signs as the production bundle ID.
    case production
    /// The `com.lavasec.dev.qa*` identity — the QA build configuration, never distributed
    /// publicly.
    case qa
}

/// Names, framing, and the generation policy for the chained-upstream secret store.
///
/// Plan: lavasec-infra `plans/2026-07-22-vpn-upstream-chaining-implementation-plan.md`
/// (Phase 4). Registry: `INV-CHAIN-4`, `INV-PERSIST-1`, `INV-PERSIST-2`.
///
/// ## Why this vocabulary lives in LavaSecKit
///
/// The TUNNEL reads and the APP writes, and they are separate processes with separate
/// module graphs: the app must not link `LavaSecChainedUpstream` (that would pull the
/// boringtun xcframework into the app binary — the prohibition in `Package.swift` and
/// `docs/architecture/module-boundaries.md`), and `LavaSecKit` cannot import
/// `LavaSecChainedUpstream` because the dependency runs the other way. So the only module
/// both processes link is this one, and a format implemented twice is the divergence hazard
/// `ChainedUpstreamReadiness` already names about the small-order table: a security-critical
/// constant maintained in two places can diverge, and the divergence presents as one layer
/// accepting what the other refuses.
///
/// The WRITE half therefore also ships in the tunnel's binary. That is a real cost and it
/// buys less than it looks: iOS has no read-only membership of a keychain access group, so a
/// tunnel holding the group can already add and delete items in it through `Security`
/// directly, whatever Swift symbols are linked. The boundary that actually constrains the
/// tunnel is the entitlement, not this type's visibility. What the placement does buy is one
/// implementation of the framing.
public enum ChainedUpstreamSecretNaming {
    /// The committed configuration half, in the shared App Group container.
    ///
    /// A FILE and not a Keychain item, and the split is product-motivated rather than
    /// incidental — see ``ChainedUpstreamSecretStoreFailure`` and `INV-CHAIN-4`. Class C (the
    /// iOS app-group default), deliberately: it names the server a user routes all traffic
    /// through, so it belongs with the privacy stores rather than the Class-None control
    /// plane (`INV-PERSIST-2`). Nothing is lost, because chained mode cannot start before
    /// first unlock anyway — the key is `AfterFirstUnlockThisDeviceOnly`.
    ///
    /// Takes the identity because the FILE half has no entitlement to ride on — see
    /// ``ChainedUpstreamStoreIdentity``. There is deliberately no un-namespaced constant: a
    /// caller that could name the file without naming an identity is a caller that can write
    /// a QA record into the production slot.
    /// pinned: ChainedUpstreamSecretStorageTests.testTheQAIdentityAddressesDifferentFilesThanProduction
    public static func configurationFilename(
        for identity: ChainedUpstreamStoreIdentity
    ) -> String {
        "chained-upstream\(suffix(for: identity)).json"
    }

    /// Advisory cross-process lock serializing WRITERS only.
    ///
    /// Readers never take it. Blocking a packet tunnel on a lock a killed app process holds
    /// is a hang, and the reader has no need: the commit protocol leaves a consistent pair at
    /// every instant, and `consistentSnapshot`'s bounded retry covers the rest.
    ///
    /// Namespaced with the file it guards. A shared lock over per-identity files would be
    /// merely wasteful; a per-identity lock over a shared file would be unsound, and keeping
    /// the two names derived from one identity makes the second shape unwritable.
    public static func writeLockFilename(for identity: ChainedUpstreamStoreIdentity) -> String {
        "chained-upstream-write\(suffix(for: identity)).lock"
    }

    /// Empty for production, so the App Store build's records keep the names they were
    /// designed with and only the internal identity moves.
    private static func suffix(for identity: ChainedUpstreamStoreIdentity) -> String {
        switch identity {
        case .production: return ""
        case .qa: return ".\(identity.rawValue)"
        }
    }

    /// `kSecAttrService` for every key item this store owns.
    public static let keychainService = "com.lavasec.chained-upstream"

    /// Account prefix for the generation-addressed key items.
    public static let keyAccountPrefix = "upstream-key/"

    /// The key item's account for a generation.
    ///
    /// The generation IS the account name, which is what makes the key half unforgeably
    /// bound to its stamp: account and value land in ONE `SecItemAdd`, so they cannot
    /// disagree. A generation held in a separate attribute, or in a sidecar, would be a
    /// second thing to write and therefore a second thing to tear.
    public static func keyAccount(for generation: UInt64) -> String {
        "\(keyAccountPrefix)\(String(generation, radix: 16))"
    }

    /// The generation an account name addresses, or `nil` if it is not one of ours.
    ///
    /// Round-trip-strict: only lowercase hex with no padding parses, so
    /// ``keyAccount(for:)`` has exactly one spelling per generation and a sweep cannot be
    /// tricked into treating `upstream-key/0A` as a different item from `upstream-key/a`.
    public static func generation(fromKeyAccount account: String) -> UInt64? {
        guard account.hasPrefix(keyAccountPrefix) else { return nil }
        let digits = String(account.dropFirst(keyAccountPrefix.count))
        guard let value = UInt64(digits, radix: 16), keyAccount(for: value) == account
        else { return nil }
        return value
    }

    /// The key accounts that are NOT the committed generation.
    ///
    /// A pure function taking the committed generation as an ARGUMENT rather than reading it,
    /// because a sweep that re-derives its own target is the interleave that deletes the live
    /// key: a launch sweep holding a stale generation, running after a rotation committed,
    /// would delete the new key and leave a configuration whose key is gone — reported as
    /// `.noPrivateKeyStored` forever and indistinguishable from the migrated-device flow.
    /// The callers that must supply it are the ones holding the writer lock.
    /// pinned: ChainedUpstreamSecretStorageTests.testTheSweepNeverNamesTheCommittedGeneration
    public static func orphanedKeyAccounts(
        in accounts: [String], committed generation: UInt64
    ) -> [String] {
        accounts.filter { account in
            guard let addressed = self.generation(fromKeyAccount: account) else { return false }
            return addressed != generation
        }
    }
}

/// Why a chained-upstream store operation could not complete.
///
/// Log/diagnostic identifiers, never user copy, and never any part of the secret. The
/// unreadable/unusable split is load-bearing: one is "retry later" and one never gets better
/// on its own, and collapsing them is how a permanently wedged install reports a transient
/// fault forever.
public enum ChainedUpstreamSecretStoreFailure: Error, Equatable, Sendable {
    /// The configuration file EXISTS but its content could not be read — Data Protection
    /// before first unlock, or transient I/O. `INV-PERSIST-1`: never reported as absent, and
    /// nothing is written or deleted while it holds. Carries only the coarse NSError
    /// domain+code breadcrumb `SharedStateFileReader` produces, never a path.
    case configurationUnreadable(String)
    /// The configuration file was READ and is not usable: not JSON, an unknown schema, a
    /// generation of `0`, or a payload `ChainedUpstreamConfiguration.init(from:)` refuses.
    ///
    /// That last case is reachable without any corruption: the validator has tightened twice
    /// already (the `isPlausiblePrefix` rewrites and the leading-zero rule), so an app update
    /// can turn a configuration that was valid when written into one that no longer decodes.
    /// It is a distinct case because the recovery is distinct — re-enter the configuration —
    /// and because reporting it as "the store refused to answer" would describe a permanent
    /// wedge as a locked device.
    case configurationUnusable
    /// The Keychain returned a status this store does not handle. The `OSStatus` is carried
    /// because `errSecMissingEntitlement` (-34018) — a build whose signature does not
    /// authorize the shared access group — is otherwise indistinguishable from a locked
    /// device, and that is the exact fault the on-device verification of this slice looks for.
    case keychainRefused(OSStatus)
    /// The CSPRNG refused, or every drawn generation collided with the reserved or committed
    /// value. Nothing is written: a rotation with no fresh stamp is not a rotation.
    case entropyUnavailable
    /// The private key is not exactly 32 bytes.
    case malformedPrivateKey
    /// A pre-shared key was supplied but is not exactly 32 bytes.
    ///
    /// Only a LENGTH failure, deliberately: WireGuard treats an all-zero PSK as "no PSK", so —
    /// unlike ``unusablePrivateKey`` — there is no zero-key case here. The engine
    /// (`WireGuardSession.init`) enforces the same width at the FFI boundary; refusing at this
    /// write boundary means a bad PSK never reaches a latch evaluation as a handshake that
    /// silently never completes.
    case malformedPresharedKey
    /// The private key is the all-zero key, which is what an unfilled config template holds.
    case unusablePrivateKey
    /// The supplied private key derives the configuration's PEER public key — the user pasted
    /// the server's config instead of their own. Otherwise this presents as a handshake
    /// timeout, indistinguishable from an unreachable peer.
    case privateKeyBelongsToThePeer
    /// The shared keychain access group is not resolvable in this build, so the item would
    /// land in a group the other process cannot see. Refused rather than defaulted — see
    /// ``ChainedUpstreamKeychainAccessGroup``.
    case accessGroupUnavailable
    /// Writer-vs-writer exclusion could not be established, so NOTHING was written or
    /// deleted.
    ///
    /// Retry-later, like ``configurationUnreadable(_:)`` and unlike
    /// ``configurationUnusable``: the advisory lock file is Class C, so the one way to see
    /// this in the field is a container the process cannot open — a device that has not been
    /// unlocked since boot, or a full disk. The alternative to reporting it is running the
    /// commit protocol's deletes unserialized, which is durable and unrecoverable, so this
    /// case is the fail-closed half of `INV-CHAIN-4`.
    case writerExclusionUnavailable
}

/// One rotation: a configuration and the key that belongs to it.
///
/// There is deliberately NO way to express half of one, and that is the whole answer to the
/// plan's C6 obligation. C6 asks that one rotation stamp the SAME generation on both halves;
/// a store offering `saveConfiguration` and `savePrivateKey` separately makes per-item
/// generations something a caller has to remember not to produce. Requiring both halves at
/// the single mutator makes it something a caller CANNOT produce.
///
/// Validation happens here, at the WRITE boundary, for the same reason
/// `ChainedUpstreamConfiguration.init` validates there: a bad key stored is a bad key refused
/// at every latch evaluation for the life of the install, with no path back to the user who
/// could fix it.
public struct ChainedUpstreamRotation: Sendable {
    /// The entry's secrets travel in the same atomic Keychain item as the exit's secrets.
    public let precedingRotations: [ChainedUpstreamRotation]
    public let configuration: ChainedUpstreamConfiguration
    public let privateKey: Data
    /// The optional WireGuard pre-shared key, a secret like ``privateKey`` and carried the same
    /// way: never in the plaintext ``ChainedUpstreamConfiguration``, persisted alongside the
    /// private key in the one secret item, and handed to the engine's session. `nil` when the
    /// staged `.conf` carried no `PresharedKey` line — the common case, and WireGuard's own
    /// "no PSK".
    public let presharedKey: Data?

    /// - Parameter presharedKey: the optional 32-byte pre-shared key. Defaults to `nil`, which
    ///   keeps every caller that predates PSK support compiling unchanged.
    /// - Throws: ``ChainedUpstreamSecretStoreFailure/malformedPrivateKey``,
    ///   ``ChainedUpstreamSecretStoreFailure/unusablePrivateKey``,
    ///   ``ChainedUpstreamSecretStoreFailure/malformedPresharedKey``, or
    ///   ``ChainedUpstreamSecretStoreFailure/privateKeyBelongsToThePeer``.
    public init(
        configuration: ChainedUpstreamConfiguration,
        privateKey: Data,
        presharedKey: Data? = nil,
        precedingRotations: [ChainedUpstreamRotation] = []
    ) throws {
        guard precedingRotations.count == configuration.precedingHops.count,
              zip(precedingRotations, configuration.precedingHops).allSatisfy({ $0.configuration == $1 }) else {
            throw WireGuardChainFailure.missingSecret
        }
        self.precedingRotations = precedingRotations
        guard privateKey.count == ChainedUpstreamConfiguration.privateKeyByteCount else {
            throw ChainedUpstreamSecretStoreFailure.malformedPrivateKey
        }
        guard privateKey.contains(where: { $0 != 0 }) else {
            throw ChainedUpstreamSecretStoreFailure.unusablePrivateKey
        }
        // LENGTH ONLY, and no zero-key refusal — WireGuard treats an all-zero PSK as "no PSK",
        // so matching the engine means the sole property this boundary can enforce is the
        // width. `nil` skips the check entirely; a present-but-wrong-length value is refused
        // here rather than surfacing later as a handshake that never completes.
        if let presharedKey {
            guard presharedKey.count == ChainedUpstreamConfiguration.presharedKeyByteCount else {
                throw ChainedUpstreamSecretStoreFailure.malformedPresharedKey
            }
        }
        // Compared over DECODED BYTES, never over the base64 text. Base64 of 32 bytes has
        // slack in its final character, so several spellings decode identically — a string
        // comparison is bypassable by re-pasting the same key differently, which is the exact
        // lesson `peerKeyFingerprint` already records.
        //
        // X25519 clamps, so this catches the swap whichever spelling of the private key the
        // user pasted: two keys differing only in the clamped bits derive one public key.
        if let peer = Data(base64Encoded: configuration.peerPublicKey),
           peer.count == ChainedUpstreamConfiguration.publicKeyByteCount,
           let derived = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKey)
               .publicKey.rawRepresentation,
           derived == peer {
            throw ChainedUpstreamSecretStoreFailure.privateKeyBelongsToThePeer
        }
        self.configuration = configuration
        self.privateKey = privateKey
        self.presharedKey = presharedKey
    }
}

/// Draws the value that identifies a rotation.
///
/// FRESHLY DRAWN per rotation, never derived from the previous one. A monotonic counter — the
/// scheme `ChainedUpstreamStoreGeneration`'s doc comment used to bless — has to read the
/// previous value, and the previous value can be GONE: a restored backup, a migrated device,
/// or a user who deleted the key all leave the store without it. The counter then re-issues a
/// number an existing half already carries, the equality comparison agrees, and a session is
/// built from an unrelated pair. A commit timestamp fails the same way on clock rollback and
/// on two rotations inside one tick.
///
/// What this type can ENFORCE is narrower than "unpredictable", and the difference is stated
/// rather than implied: it refuses `0` (the reserved sentinel that a defaulted or zero-filled
/// decode produces) and it refuses the generation currently committed. Whether the entropy
/// source is a CSPRNG is a property of the injected closure and is NOT testable from here —
/// a counter injected in its place satisfies both refusals. The production default is
/// `SecRandomCopyBytes`; nothing in the suite proves that, and no comment here claims it does.
public struct ChainedUpstreamGenerationMint: Sendable {
    /// Fills `count` bytes, or throws.
    public typealias Entropy = @Sendable (Int) throws -> Data

    private let entropy: Entropy

    public init(entropy: @escaping Entropy = ChainedUpstreamGenerationMint.systemEntropy) {
        self.entropy = entropy
    }

    /// `SecRandomCopyBytes`, matching the nonce path in `AccountAuthService`.
    public static let systemEntropy: Entropy = { count in
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else {
            throw ChainedUpstreamSecretStoreFailure.entropyUnavailable
        }
        return Data(bytes)
    }

    /// A generation that is neither `0` nor `committed`.
    ///
    /// Bounded retries: an entropy source that keeps producing a refused value is a broken
    /// entropy source, and looping forever inside a foreground save is a hang. Exhausting the
    /// attempts throws, so a rotation never proceeds with a stamp it could not freshly draw.
    /// - Throws: ``ChainedUpstreamSecretStoreFailure/entropyUnavailable``.
    public func mint(excluding committed: UInt64?, attempts: Int = 8) throws -> UInt64 {
        for _ in 0..<max(1, attempts) {
            let bytes = try entropy(8)
            guard bytes.count == 8 else {
                throw ChainedUpstreamSecretStoreFailure.entropyUnavailable
            }
            var value: UInt64 = 0
            for byte in bytes { value = (value << 8) | UInt64(byte) }
            if value == 0 { continue }
            if let committed, value == committed { continue }
            return value
        }
        throw ChainedUpstreamSecretStoreFailure.entropyUnavailable
    }
}

/// Resolves the shared keychain access group from a build-injected string.
///
/// The group must be TEAM-QUALIFIED (`<AppIdentifierPrefix>.<group>`), and the prefix is not
/// knowable from source: it arrives through `Info.plist` build-setting expansion of
/// `$(DEVELOPMENT_TEAM)`, which is EMPTY in the tracked `Config/Lava.xcconfig` so that no team
/// ID lives in the repo. An empty team expands to a syntactically fine, semantically garbage
/// string (`".com.lavasec.app.chained-upstream"`), and a store built on that is constructible,
/// answers every read with `errSecParam`, and reports `.storeUnavailable` forever on every
/// unsigned or local build.
///
/// So the fail-closed check has to be on the SHAPE of the resolved value, not on the presence
/// of a string. `nil` means "this build cannot share keychain items" — the store is then
/// unconstructible, which is the correct outcome: a silent fall-back to the per-bundle default
/// group would put the app's write somewhere the tunnel cannot see it, and that presents as
/// "you never configured this" with no error anywhere.
/// pinned: ChainedUpstreamSecretStorageTests.testAnUnsignedBuildResolvesNoAccessGroup
public enum ChainedUpstreamKeychainAccessGroup {
    /// The usable group, or `nil`.
    public static func resolved(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // An unexpanded build setting. Xcode leaves `$(NAME)` verbatim when the setting does
        // not exist at all, which is a typo in project.yml rather than a missing team — and a
        // literal `$(...)` reaching `kSecAttrAccessGroup` is a group nothing is entitled to.
        guard !trimmed.contains("$(") else { return nil }
        // The empty-DEVELOPMENT_TEAM case: `$(DEVELOPMENT_TEAM).suffix` → `.suffix`.
        guard !trimmed.hasPrefix(".") else { return nil }
        // A team prefix and a suffix, both non-empty.
        guard let separator = trimmed.firstIndex(of: "."),
              trimmed.index(after: separator) < trimmed.endIndex
        else { return nil }
        return trimmed
    }
}
