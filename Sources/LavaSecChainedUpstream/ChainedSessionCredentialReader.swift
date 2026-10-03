import Foundation
import LavaSecKit

/// A credential re-read that refuses to build against a store the session no longer matches.
///
/// Everything here travels UNWRAPPED through `ChainedUpstreamSessionFactory.makeSession`, and
/// the driver's triage on an unwrapped error is the conservative one: the attempt does not
/// spend a ladder rung, the session end is `sessionCreationFailed`, and chaining surrenders
/// for the lifecycle. That is the intended severity for both cases — see each one.
public enum ChainedSessionCredentialRefusal: Error, Equatable {
    /// The store answered, but with something no session may be built from: nothing stored, a
    /// missing or malformed key, or an unusable peer key.
    ///
    /// Retrying cannot clear any of these — the input is the stored value itself, not a
    /// reading of the system taken at build time — so letting them surrender is the same
    /// triage rule `ChainedSessionBuildFailure.warrantsAnotherAttempt` states for the
    /// permanent set. The store-unavailability refusals never reach this case; they map to
    /// ``ChainedSessionBuildFailure/credentialsUnavailable`` in
    /// ``ChainedSessionCredentialReader/read(store:latchedConfiguration:)`` instead.
    case upstreamNoLongerReady(ChainedUpstreamReadiness.Refusal)

    /// The stored configuration no longer matches the one this session latched.
    ///
    /// EVERY field, not just the address. The session's inputs are captured from the
    /// LATCHED configuration and cannot be re-derived per attempt — the utun keeps the
    /// latched address, and the factory holds the latched endpoint, AllowedIPs and MTU — so
    /// accepting new key material because one field still matched would build a
    /// mixed-generation session: new keys aimed at the old endpoint, handshaking forever
    /// against a peer that moved, surrendering instead of using the configuration that was
    /// actually committed (Codex, PR #509). The address remains the sharpest instance: a
    /// rotated one emits packets whose inner source the local interface does not own —
    /// C7's failure shape, one write later.
    /// Surrendering ends that hazard immediately, and the honest cost is stated rather than
    /// wished away: the surrender's own restart lands in DNS-only under the persisted
    /// suppression, and the rotated configuration — address, routes and MTU together — is
    /// picked up on the first post-Reset lifecycle, not before. The Phase-4 config-UI slice
    /// therefore owes one behaviour (recorded here because this is the seam that creates the
    /// debt): a save that rotates the configuration of a live chained tunnel is C4's
    /// "explicit user action" and must clear the suppression in the same save
    /// (`userResetChainedSuppressions`), so the write-to-restart race cannot strand the user
    /// on a Reset button they already pressed by saving — C8's standard applies.
    case configurationRotated

    /// A stable log identifier, never user copy.
    public var logValue: String {
        switch self {
        case .upstreamNoLongerReady(let refusal):
            return "credentials-not-ready-\(refusal.rawValue)"
        case .configurationRotated:
            return "credentials-configuration-rotated"
        }
    }
}

/// The body of the provider's `readCredentials` closure, as a policy the package can test.
///
/// Called INLINE ON THE ENGINE QUEUE, once per attempt, behind the armed attempt watchdog —
/// so it must not block beyond the store's own bounded reads, and it must never touch
/// `dnsStateQueue` (`INV-QUEUE-1`; a latch read here can deadlock against a path-change hop
/// waiting on the engine queue). Everything it needs beyond the store is therefore a captured
/// immutable: the latched configuration itself.
///
/// This is where `ChainedSessionBuildFailure.credentialsUnavailable`'s documented obligation
/// is discharged (C4's "exactly one trigger" reconciliation): the store-unavailability
/// diagnoses — `storeUnavailable`, `storeKeptChanging`, and every raw
/// `ChainedUpstreamSecretStoreFailure`, which `ChainedUpstreamReadiness.evaluate` already
/// folds into `storeUnavailable` — become the TRANSIENT build failure, so a Keychain that is
/// briefly unanswerable spends a ladder rung instead of surrendering chained mode for the
/// lifecycle. Everything else travels unwrapped to surrender, per
/// ``ChainedSessionCredentialRefusal``.
public enum ChainedSessionCredentialReader {
    /// Reads the entry from the same committed generation as its enclosing chain.
    public static func readEntry(store: ChainedUpstreamKeychainStore,
                                 latchedConfiguration: ChainedUpstreamConfiguration) throws -> ChainedSessionCredentials {
        do {
            guard let record = try store.loadStoredConfigurationRecord(), try record.configuration.activeConfiguration == latchedConfiguration,
                  let entry = record.configuration.precedingHops.first else { throw ChainedSessionCredentialRefusal.configurationRotated }
            let material = try store.loadStoredEntryKeyMaterial()
            // Rotation may sweep the old item between envelope and key reads. Recheck
            // even nil before interpreting a missing key as permanent.
            // pinned: ChainedUpstreamKeychainStoreTests.testEntryReadDuringRotationIsTransientRatherThanMissingSecret
            guard let current = try store.loadStoredConfigurationRecord(), current.generation == record.generation else {
                throw ChainedSessionBuildFailure.credentialsUnavailable
            }
            guard let material else { throw ChainedSessionCredentialRefusal.upstreamNoLongerReady(.noPrivateKeyStored) }
            guard material.generation == record.generation else { throw ChainedSessionBuildFailure.credentialsUnavailable }
            guard let peer = entry.decodedPeerPublicKey else {
                throw ChainedSessionCredentialRefusal.upstreamNoLongerReady(.unusablePeerPublicKey)
            }
            _ = try ChainedUpstreamRotation(configuration: entry, privateKey: material.privateKey, presharedKey: material.presharedKey)
            return ChainedSessionCredentials(privateKey: Array(material.privateKey), peerPublicKey: Array(peer),
                presharedKey: material.presharedKey.map(Array.init), keepaliveSeconds: entry.persistentKeepaliveSeconds,
                generation: record.generation)
        } catch is ChainedUpstreamSecretStoreFailure {
            // The same retry lane as exit credentials: a temporarily locked Keychain
            // must not surrender the configured chain for the whole lifecycle.
            throw ChainedSessionBuildFailure.credentialsUnavailable
        }
    }

    /// One attempt's fresh read. Never caches; the factory scrubs what it returns.
    /// pinned: ChainedSessionCredentialReaderTests.testStoreUnavailabilityIsTheTransientBuildFailure
    /// pinned: ChainedSessionCredentialReaderTests.testARotatedConfigurationRefusesToBuild
    public static func read(
        store: ChainedUpstreamSecretStore,
        latchedConfiguration: ChainedUpstreamConfiguration
    ) throws -> ChainedSessionCredentials {
        switch ChainedUpstreamReadiness.evaluate(store: store) {
        case .notReady(let refusal):
            switch refusal {
            case .storeUnavailable, .storeKeptChanging:
                throw ChainedSessionBuildFailure.credentialsUnavailable
            case .noConfigurationStored, .noPrivateKeyStored, .malformedPrivateKey,
                .unusablePeerPublicKey, .endpointNotYetResolvable, .noUsableTunnelDNS:
                // The hostname and no-usable-DNS cases reach here only through a
                // mid-session rotation to such a config (readiness gates both out of the
                // latch) — permanent for this lifecycle, like the rest of this lane; the
                // surrender's restart refuses to re-latch it. A config problem is not a
                // transient store fault, so neither belongs in the rung-spending lane.
                throw ChainedSessionCredentialRefusal.upstreamNoLongerReady(refusal)
            }
        case .ready(let ready):
            guard ready.configuration == latchedConfiguration else {
                throw ChainedSessionCredentialRefusal.configurationRotated
            }
            // Unreachable while readiness gates the peer key ahead of this, and kept anyway:
            // a decode that starts answering differently from the validator must fail the
            // build, never hand the engine a key of the wrong length.
            guard let peerKey = ready.configuration.decodedPeerPublicKey else {
                throw ChainedSessionCredentialRefusal.upstreamNoLongerReady(
                    .unusablePeerPublicKey)
            }
            return ChainedSessionCredentials(
                privateKey: [UInt8](ready.privateKey),
                peerPublicKey: [UInt8](peerKey),
                // The engine leg — `ChainedUpstreamSessionFactory` → `WireGuardSession` — has
                // always accepted a PSK; this is the read side that finally supplies one.
                // `nil` stays `nil`, which the engine treats as "no PSK".
                presharedKey: ready.presharedKey.map { [UInt8]($0) },
                keepaliveSeconds: ready.configuration.persistentKeepaliveSeconds,
                // WHAT WAS ACCEPTED, carried out so the caller can publish it. The guard above
                // compares CONFIGURATIONS, so this can legitimately differ from the generation
                // the session latched — a key-only rotation is byte-identical configuration with
                // new key material, and it is accepted here.
                // pinned: ChainedSessionCredentialReaderTests.testAKeyOnlyRotationIsAcceptedAndReportsItsOwnGeneration
                generation: ready.generation.value)
        }
    }
}
