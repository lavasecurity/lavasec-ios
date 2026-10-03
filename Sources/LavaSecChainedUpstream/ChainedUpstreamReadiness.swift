import CryptoKit
import Foundation
import LavaSecKit

/// Identifies the WRITE that produced a stored value.
///
/// Not a revision counter, and the difference is the whole contract. A counter advanced by
/// "any write" says nothing about whether two halves belong together: with per-item counters,
/// the configuration and the key can carry unrelated numbers that never agree, and chained
/// mode is then permanently unready. With a store-wide counter, a write that lands between two
/// reads changes the number for BOTH — which detects the tear, but only because every write
/// invalidates every read.
///
/// The contract is narrower and it is what a Keychain-backed conformer can actually provide:
/// one rotation stamps the SAME value on both halves, and a half-written rotation is never
/// observable with both halves carrying the new stamp. Equality of stamps therefore means the
/// two values came from one logical write.
///
/// A conformer whose two halves can carry stamps from different writes is not a valid
/// conformer, and no amount of retrying inside ``ChainedUpstreamSecretStore/consistentSnapshot``
/// can rescue it — the comparison would be agreeing with a lie. That is the obligation the
/// protocol places on Phase 4, stated here because it is not enforceable from this side.
///
/// Compared only for equality, never for order.
///
/// This used to add "so a conformer may use any value it can stamp atomically: a monotonic
/// counter, a rotation UUID's hash, a commit timestamp." Two of those three are unsafe and the
/// production conformer uses none of them. A counter has to READ the previous value, and the
/// previous value can be gone — a restored backup, a migrated device, or a deleted key all
/// leave the store without it — so the counter re-issues a number an existing half already
/// carries and the equality comparison agrees with a lie. A timestamp fails the same way on
/// clock rollback and on two rotations inside one tick. The obligation is therefore narrower
/// than "stamped atomically": the value must not be REUSED across rotations, including after
/// the store has lost its previous contents. `ChainedUpstreamGenerationMint`
/// (`Sources/LavaSecKit/ChainedUpstreamSecretStorage.swift`) draws a fresh 64-bit value per
/// rotation and refuses both `0` and the currently committed value.
public struct ChainedUpstreamStoreGeneration: Equatable, Sendable {
    public let value: UInt64
    public init(_ value: UInt64) { self.value = value }
}

/// Reads the stored upstream configuration and its secret.
///
/// ## Why this is a protocol
///
/// Phase 3 needs a configuration to exercise the data path; Phase 4 owns Settings and the real
/// Keychain surface. The founder's constraint on that split is that swapping in the real store
/// must be easy, so the boundary is a protocol with the Phase-3 implementation as one
/// conformer rather than a concrete type the session machine reaches into. Phase 4 substitutes
/// a conformer and no call site moves.
///
/// The SHAPE is dictated by what the caller needs, not by what Keychain offers. A protocol
/// mirroring `SecItemCopyMatching` would leak the storage mechanism into the packet loop and
/// make the substitution exactly as hard as not having a protocol at all.
///
/// Throwing is deliberate rather than returning optionals: "no configuration stored" and "the
/// Keychain refused" are different facts, and a tunnel that treats a locked device as an
/// absent configuration would silently drop the user to DNS-only and call it a preference.
///
/// ## Why two reads and not one
///
/// An earlier version required a single `loadSnapshot()` returning both, on the reasoning that
/// one call cannot tear. It cannot tear at the SWIFT boundary, which is not where the tearing
/// happens: Phase 4 stores the configuration in the privacy store and the key in a separate
/// Keychain item, so that one method still performs two underlying reads and a rotation
/// between them still yields a configuration from one generation with a key from the next. A
/// call boundary is not a transaction, and the shape hid that rather than solving it.
///
/// So the two reads are explicit, each reports the generation it observed, and detecting the
/// tear is this protocol's job rather than each conformer's — see `consistentSnapshot()`. A
/// conformer only has to report generations honestly, which is the smallest obligation that
/// can work and the only part a Keychain-backed implementation is actually able to do.
///
/// It also makes a state the old shape could not express representable: a configuration whose
/// key is missing, which is what a restored device or an independently deleted Keychain item
/// looks like. Under `loadSnapshot()` that had to be reported as "no configuration", so
/// ``ChainedUpstreamReadiness/Refusal/noPrivateKeyStored`` was unreachable — a refusal the
/// planned re-enter-key flow depends on being able to tell apart.
public protocol ChainedUpstreamSecretStore: Sendable {
    /// The stored configuration, and the generation it was read at. `nil` if none is stored.
    func loadConfiguration() throws -> (ChainedUpstreamConfiguration, ChainedUpstreamStoreGeneration)?
    /// The stored private key, its optional pre-shared key, and the generation they were READ
    /// AT — which for a conformer that addresses the key BY generation means the generation the
    /// lookup used, not a stamp carried on the key itself.
    ///
    /// The PSK rides WITH the private key because both are the secret half of one rotation and
    /// the production conformer keeps them in one Keychain item: reading them together is what
    /// lets a single generation stamp both, exactly as it does the private key. `nil` for the
    /// PSK is ordinary (WireGuard's own "no PSK"); `nil` for the whole tuple means no key is
    /// stored.
    ///
    /// Stated because the production conformer addresses by generation:
    /// `ChainedUpstreamKeychainStore` names the key item by the committed generation, so the
    /// account name IS the stamp and there is no second value that could disagree with it.
    /// Reporting the generation it fetched under is what makes ``consistentSnapshot(attempts:)``
    /// converge — a rotation landing between the two reads shows up as a mismatch the retry
    /// resolves, rather than as a stale key wearing a current number.
    func loadPrivateKey() throws
        -> (privateKey: Data, presharedKey: Data?, generation: ChainedUpstreamStoreGeneration)?
}

/// A configuration and its key material, proven to come from the same generation.
public struct ChainedUpstreamStoredSnapshot: Sendable {
    public let configuration: ChainedUpstreamConfiguration
    public let privateKey: Data
    /// The optional pre-shared key read from the same generation as ``privateKey``. `nil` is
    /// ordinary — WireGuard's own "no PSK".
    public let presharedKey: Data?
    /// The generation both halves were read at.
    ///
    /// CARRIED, not just proven. This type's own summary line says the halves are "proven to
    /// come from the same generation" — and until now `consistentSnapshot` established exactly
    /// that and then dropped the number, so the one value that identifies WHICH rotation a
    /// session is running died two hops before anything could publish it. Nothing downstream
    /// could tell two valid upstreams apart, which is the root cause behind every finding on
    /// the closed PR #607.
    ///
    /// NON-SECRET, and that is what makes publishing it safe: an opaque identifier naming a
    /// rotation, carrying no key material, no endpoint and no address. It may travel in a
    /// health snapshot and a bug report; ``privateKey`` and ``presharedKey`` beside it may not.
    ///
    /// AN IDENTITY, NOT AN ORDER. `ChainedUpstreamGenerationMint.mint` draws it from eight random
    /// bytes, excluding only `0` and the committed value, so a later rotation is as likely to be
    /// numerically smaller as larger. Compare for equality; never for recency (Codex P3, PR #613).
    public let generation: ChainedUpstreamStoreGeneration

    public init(
        configuration: ChainedUpstreamConfiguration,
        privateKey: Data,
        presharedKey: Data? = nil,
        generation: ChainedUpstreamStoreGeneration
    ) {
        self.configuration = configuration
        self.privateKey = privateKey
        self.presharedKey = presharedKey
        self.generation = generation
    }
}

/// What reading both halves produced.
public enum ChainedUpstreamStoreRead: Sendable {
    /// Both halves, read at the same generation.
    case consistent(ChainedUpstreamStoredSnapshot)
    /// Nothing is stored at all.
    case nothingStored
    /// A configuration exists but its key does not.
    case configurationWithoutKey
    /// The two halves kept disagreeing about their generation.
    case keptChangingUnderneath
}

extension ChainedUpstreamSecretStore {
    /// Reads both halves and returns them only if they came from the same generation.
    ///
    /// Commit-and-retry, because a rotation is a race and not an error: read both, compare the
    /// generations, and read again if they differ. Bounded, because retrying forever inside a
    /// packet tunnel is a hang rather than a safeguard, and a store that changes under three
    /// consecutive reads is not a store this tunnel can build a session from — reporting that
    /// beats guessing which half was current.
    ///
    /// This lives in the protocol extension so every conformer gets it, rather than being an
    /// obligation each one has to remember. A contract in prose is exactly what the previous
    /// shape had, and it is the recurring defect class in this feature.
    public func consistentSnapshot(attempts: Int = 3) throws -> ChainedUpstreamStoreRead {
        for _ in 0..<max(1, attempts) {
            guard let (configuration, configurationGeneration) = try loadConfiguration() else {
                return .nothingStored
            }
            guard let (key, presharedKey, keyGeneration) = try loadPrivateKey() else {
                // Re-read the configuration before believing it. Otherwise a rotation that
                // removes and rewrites the key between the two reads reports a missing key,
                // and the caller sends the user to re-enter a key that is present.
                guard let (_, recheck) = try loadConfiguration(), recheck == configurationGeneration
                else { continue }
                return .configurationWithoutKey
            }
            guard configurationGeneration == keyGeneration else { continue }
            return .consistent(
                ChainedUpstreamStoredSnapshot(
                    configuration: configuration, privateKey: key, presharedKey: presharedKey,
                    // Either generation would do — the guard above is what makes them the same
                    // value — and naming the configuration's is deliberate: it is the half the
                    // loop re-reads on the missing-key path, so it is the one a reader can
                    // trace to a specific read.
                    generation: configurationGeneration))
        }
        return .keptChangingUnderneath
    }
}

/// Whether chained mode may claim the default route.
///
/// Plan: lavasec-infra `plans/backlog/2026-07-27-vpn-upstream-phase-3-data-path-plan.md` (S7).
///
/// Fills `TunnelDataPathLatch.resolve`'s `readyUpstream` parameter — the half of
/// `INV-CHAIN-1` that had no producer from Phase 2 until the S8.11b wiring made this its
/// producer at the latch.
///
/// The question it answers is narrow on purpose: is there a configuration we can actually run
/// RIGHT NOW. Not "did the user turn this on", which the latch asks separately, and not "will
/// the handshake succeed", which nothing can know before trying. A tunnel that claims
/// `0.0.0.0/0` on the strength of a preference and then discovers it has no key is a blackhole
/// the user did not consent to.
public enum ChainedUpstreamReadiness {
    /// Why the upstream cannot be used.
    public enum Refusal: String, Equatable, Sendable, CaseIterable {
        /// Nothing has been configured.
        case noConfigurationStored
        /// A configuration exists but its secret does not, so no session can be built.
        case noPrivateKeyStored
        /// The private key is not 32 bytes.
        case malformedPrivateKey
        /// The PEER's public key cannot yield a usable handshake: it is one of Curve25519's
        /// small-order points (the INPUT-form check, `isSmallOrderPoint`), OR it produces an
        /// all-zero Diffie-Hellman shared secret against our own private key (the OUTPUT-form
        /// check, RFC 7748 §6.1). Both mean a tunnel that would claim `0.0.0.0/0` with
        /// predictable handshake key material, so both fail closed to this one refusal.
        case unusablePeerPublicKey
        /// The store refused to answer. Distinct from "nothing stored", because a locked
        /// device is not a preference — treating it as one would silently drop the user to
        /// DNS-only and present it as their own choice.
        case storeUnavailable
        /// The configuration and its key kept disagreeing about which generation they came
        /// from. Distinct from `storeUnavailable`: the store answered every time, it simply
        /// never held still, and a session built from a mismatched pair fails as a handshake
        /// timeout — indistinguishable from an unreachable peer, so it spends the whole outage
        /// budget blaming the network for a torn read.
        case storeKeptChanging
        /// The endpoint is a hostname, and no production resolution executor exists yet
        /// (the plan's S1). INTERIM, removed when S1 lands.
        ///
        /// Refused HERE, not only at the provider's construction, because "usable means
        /// semantically usable" (the plan's S7): a hostname config that latched would
        /// downgrade at construction on EVERY start — a per-start marker write whose
        /// crash window can accrue phantom jetsam strikes for sessions that never ran,
        /// three of which are an exclusion only the user's Reset clears. A config that
        /// can never build a session must never latch. Persistent PER CONFIGURATION,
        /// not transient: the recovery is an IP-literal endpoint, until S1.
        case endpointNotYetResolvable
        /// No `DNS =` entry survives selection (S6): the config either carries none or
        /// carries only entries the tunnel cannot use as a resolver.
        ///
        /// While chained is latched, the config's own resolvers are the SOLE DNS egress —
        /// the ladder and every physical-interface transport are suspended — so a config
        /// with no usable entry serves NO DNS at all: the tunnel would claim `0.0.0.0/0`
        /// and answer every query fail-closed, indefinitely. "Works for packets, resolves
        /// nothing" is a blackhole the user did not consent to, the same argument this
        /// type's header makes for the missing key. Persistent PER CONFIGURATION: the
        /// recovery is a config whose `DNS =` line the tunnel can use.
        case noUsableTunnelDNS
    }

    /// The result of asking the store.
    /// Everything a session needs, carried together because both were just validated.
    ///
    /// Returning only the configuration made the caller re-read the secret store to build a
    /// session, which means a second read that can fail differently — a device that locks
    /// between the readiness check and the session build would authorize the default route and
    /// then be unable to construct the session, which is the blackhole this policy exists to
    /// prevent, reintroduced by the shape of its own result.
    public struct Ready: Sendable {
        public let configuration: ChainedUpstreamConfiguration

        /// The validated secret.
        ///
        /// A plain property, and the honesty here matters more than the API did. This was a
        /// consuming `takePrivateKey()` documented as handing the key over exactly once and
        /// clearing it. `Ready` is a copyable value: copy it — or copy the `Readiness` holding
        /// it — and each copy carries its own optional, so each can "take" the key. Clearing
        /// one releases that copy's reference to the same copy-on-write buffer; it neither
        /// clears the others nor zeroes anything, and the returned `Data` necessarily outlives
        /// the call in the caller's hands.
        ///
        /// So the guarantee was never deliverable by a value type, and a method that promises
        /// single consumption while providing none is worse than a property: it invites
        /// callers to skip the care they would otherwise take. Enforcing it would need a
        /// noncopyable type or shared consumption state, plus a zeroizable buffer — none of
        /// which `Data` provides — and that belongs with Phase 4's real Keychain handling
        /// rather than being mimed here.
        ///
        /// What actually bounds the key's lifetime is the CALLER's scope. Build the session
        /// and drop the `Ready`; do not retain it, log it, or send it across an isolation
        /// boundary.
        public let privateKey: Data

        /// The optional pre-shared key, validated from the same generation as ``privateKey``
        /// and carried the same way — a secret bound to the caller's scope, never logged and
        /// never compared. `nil` is WireGuard's own "no PSK", the common case. Handed to the
        /// engine's session by `ChainedSessionCredentialReader`; the same lifetime rule as
        /// ``privateKey`` applies (build the session and drop the `Ready`).
        public let presharedKey: Data?

        /// Which stored rotation this readiness was decided against.
        ///
        /// The one part of `Ready` that is safe to keep after the secrets are dropped, and the
        /// reason it is here: the provider latches a data path from this verdict and needs to
        /// publish WHICH upstream it latched, but the type's own lifetime rule above is "build
        /// the session and drop the `Ready`". A non-secret opaque identifier can outlive that
        /// scope; the
        /// two keys beside it cannot.
        public let generation: ChainedUpstreamStoreGeneration

        init(
            configuration: ChainedUpstreamConfiguration,
            privateKey: Data,
            presharedKey: Data? = nil,
            generation: ChainedUpstreamStoreGeneration
        ) {
            self.configuration = configuration
            self.privateKey = privateKey
            self.presharedKey = presharedKey
            self.generation = generation
        }
    }

    public enum Readiness: Sendable, Equatable {
        case ready(Ready)
        case notReady(Refusal)

        /// Equality ignores the secret, which is not comparable and should not be — but it does
        /// compare the GENERATION, and it has to since the generation arrived.
        ///
        /// Configuration alone is not identity any more. A rotation can leave the configuration
        /// byte-identical and replace only the key material, which is precisely the rotation this
        /// field was published to make visible: comparing configuration alone would answer "same
        /// readiness" for two verdicts decided against different rotations, in the one type whose
        /// job is now to tell them apart.
        public static func == (lhs: Self, rhs: Self) -> Bool {
            switch (lhs, rhs) {
            case (.ready(let l), .ready(let r)):
                return l.configuration == r.configuration && l.generation == r.generation
            case (.notReady(let l), .notReady(let r)):
                return l == r
            default:
                return false
            }
        }
    }

    /// X25519 keys are 32 bytes, secret and public alike.
    ///
    /// DERIVED, not a second literal. The write boundary
    /// (`ChainedUpstreamRotation.init`, in LavaSecKit) enforces the same length and cannot
    /// name anything in this module, so without this the constant would exist twice — the
    /// "security-critical constant maintained in two places can diverge" hazard this file
    /// already records about the small-order table, in a length check where the divergence
    /// presents as one layer storing a key the other refuses.
    public static let privateKeyByteCount = ChainedUpstreamConfiguration.privateKeyByteCount

    /// Reads the store and decides.
    public static func evaluate(store: ChainedUpstreamSecretStore) -> Readiness {
        let read: ChainedUpstreamStoreRead
        do {
            read = try store.consistentSnapshot()
        } catch {
            return .notReady(.storeUnavailable)
        }

        let snapshot: ChainedUpstreamStoredSnapshot
        switch read {
        case .nothingStored:
            return .notReady(.noConfigurationStored)
        case .configurationWithoutKey:
            return .notReady(.noPrivateKeyStored)
        case .keptChangingUnderneath:
            return .notReady(.storeKeptChanging)
        case .consistent(let consistent):
            snapshot = consistent
        }

        let configuration = snapshot.configuration
        let key = snapshot.privateKey
        guard key.count == privateKeyByteCount else { return .notReady(.malformedPrivateKey) }
        // UNREACHABLE TODAY, and kept anyway. Being precise about which, because the previous
        // version of this comment called it "the last gate" and justified it with a threat
        // that does not exist — it claimed a decodable path could produce an unvalidated
        // configuration, and `init(from:)` revalidates.
        //
        // Both construction paths validate: the throwing initializer and `init(from:)`, pinned
        // by `ChainedUpstreamConfigurationTests.testDecodingRevalidates` and
        // `testASmallOrderPeerKeyIsRefusedAtConstruction`. So nothing can reach here with a bad
        // key, and dropping this guard fails no test — which is a fact about coverage, not a
        // licence to call it verified.
        //
        // It stays because the cost of the two errors is not symmetric: a redundant check costs
        // a comparison, and a missing one costs a tunnel that claims `0.0.0.0/0` with
        // predictable handshake key material. If a future construction path skips validation,
        // this fails closed instead of open.
        //
        // Delegated to the configuration type rather than duplicated. This file used to carry
        // its own copy of the small-order table — a security-critical constant maintained in
        // two places can diverge, and the divergence presents as one layer accepting a key the
        // other refuses, silently, depending on which path constructed the value.
        //
        // Length is part of it: `isSmallOrderPoint` returns false for anything that is not 32
        // bytes, so without the count check a short or long key would pass this guard.
        guard let peer = Data(base64Encoded: configuration.peerPublicKey),
              peer.count == ChainedUpstreamConfiguration.publicKeyByteCount,
              !ChainedUpstreamConfiguration.isSmallOrderPoint(peer)
        else {
            return .notReady(.unusablePeerPublicKey)
        }
        // RFC 7748 §6.1 OUTPUT-form backstop to the small-order INPUT table above. The table is
        // an input blacklist — 7 canonical small-order u-coordinates plus their high-bit twins —
        // and against a spec-correct decoder (which masks bit 255 before reducing mod p) it is
        // already complete: every 32-byte encoding whose decoded value is small-order is in it.
        // This complements it from the other side by COMPUTING the DH with our own private key —
        // the material the input check never had — and refusing an all-zero shared secret. It
        // catches the one thing an input blacklist structurally cannot: a non-canonical encoding a
        // future or third-party decoder might reduce differently, which would still force a
        // predictable all-zero handshake secret. Unreachable today for the same reason the
        // small-order guard above is (both construction paths already validate), and kept for the
        // same asymmetry: a redundant scalar-mult per readiness evaluation costs microseconds; a
        // missing one costs a tunnel that claims `0.0.0.0/0` with a known-zero session key. The
        // private key is loaded here (`key`), so this is the only layer that can do it — the
        // value-type `init` that carries the small-order check has no key to agree against
        // (Slice 3, plan 2026-08-17).
        // pinned: ChainedUpstreamReadinessTests.testAComputedAllZeroSharedSecretIsRefused
        guard Self.peerPublicKeyIsContributory(ourPrivateKey: key, peerPublicKey: peer) else {
            return .notReady(.unusablePeerPublicKey)
        }
        // S1 interim (see the Refusal case): a hostname endpoint has no resolution
        // executor yet, so a config carrying one can never build a session — it must not
        // latch. `ChainedEndpointAddress` is the same literal parse the provider's
        // construction uses, so the two gates cannot drift.
        guard
            ChainedEndpointAddress(
                literal: configuration.endpointHost, port: configuration.endpointPort) != nil
        else {
            return .notReady(.endpointNotYetResolvable)
        }
        // S6: the config's resolvers are the sole chained DNS egress, so a config none of
        // whose `DNS =` entries survives selection must not latch — see the Refusal case.
        // The SAME selection the transport consumes decides here, so the two cannot drift:
        // an entry readiness accepted is an entry the executor will query.
        guard !ChainedTunnelResolverSelection.selectedResolvers(from: configuration).isEmpty
        else {
            return .notReady(.noUsableTunnelDNS)
        }
        // The PSK is carried through UNVALIDATED beyond the write-boundary length check the
        // secret store already applied: it is a symmetric secret with no public counterpart to
        // check against and no small-order structure, so there is nothing for readiness to
        // refuse. `nil` (no PSK) is the ordinary case.
        return .ready(
            Ready(
                configuration: configuration, privateKey: key,
                presharedKey: snapshot.presharedKey, generation: snapshot.generation))
    }

    /// RFC 7748 §6.1: whether the peer key yields a CONTRIBUTORY X25519 Diffie-Hellman with our
    /// private key — a non-zero shared secret. A low-order / non-contributory peer point forces an
    /// all-zero secret and a predictable session key, so it is not usable.
    ///
    /// Fail closed on every uncertainty: any CryptoKit error building either key or computing the
    /// agreement returns `false` (unusable). Some CryptoKit versions reject the low-order result by
    /// throwing rather than returning zero; both land here as `false`. Static and pure so it is unit
    /// tested directly against the enumerated small-order encodings, which the full readiness path
    /// refuses one layer earlier at the input table.
    static func peerPublicKeyIsContributory(ourPrivateKey: Data, peerPublicKey: Data) -> Bool {
        guard
            let privateKey = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: ourPrivateKey),
            let peerKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPublicKey),
            let sharedSecret = try? privateKey.sharedSecretFromKeyAgreement(with: peerKey)
        else {
            return false
        }
        let isAllZero = sharedSecret.withUnsafeBytes { bytes in bytes.allSatisfy { $0 == 0 } }
        return !isAllZero
    }

}

extension ChainedUpstreamReadiness.Readiness {
    /// Whether chained mode may claim the default route.
    public var isReady: Bool {
        switch self {
        case .ready:
            return true
        case .notReady:
            return false
        }
    }

    /// Stable identifier for device logs. Never user copy, and never any part of the secret.
    public var logValue: String {
        switch self {
        case .ready:
            return "upstream-ready"
        case .notReady(let refusal):
            return "upstream-not-ready-\(refusal.rawValue)"
        }
    }
}
