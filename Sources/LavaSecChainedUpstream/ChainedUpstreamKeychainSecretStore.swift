import Foundation
import LavaSecKit

/// The production ``ChainedUpstreamSecretStore``.
///
/// A retroactive conformance rather than a type of its own, and the placement is forced
/// rather than chosen. The mechanism lives in `LavaSecKit` because the APP writes and cannot
/// link this module (it would drag the boringtun xcframework into the app binary — the
/// prohibition in `Package.swift`), while the protocol lives here because the TUNNEL reads and
/// is this module's one approved consumer. Conforming a foreign type to a local protocol is
/// the one direction that needs no dependency in either graph, which is the confirmation the
/// split is right: `python3 scripts/check-swift-package-boundary.py` sees no change.
///
/// The generation is `UInt64` on the Kit side because Kit cannot name
/// ``ChainedUpstreamStoreGeneration`` — the dependency runs the other way. This adapter is
/// where the two vocabularies meet, and it is the only place they do.
extension ChainedUpstreamKeychainStore: ChainedUpstreamSecretStore {
    public func loadConfiguration() throws
        -> (ChainedUpstreamConfiguration, ChainedUpstreamStoreGeneration)?
    {
        guard let record = try loadStoredConfigurationRecord(),
              let active = try record.configuration.activeConfiguration else { return nil }
        return (active, ChainedUpstreamStoreGeneration(record.generation))
    }

    /// The key material — private key, optional PSK — and the generation it was FETCHED UNDER.
    ///
    /// The key item is addressed BY generation, so it carries no stamp of its own to report —
    /// the account name is the stamp, written in the same `SecItemAdd` as the value, which is
    /// what makes it unforgeable. What this returns is therefore the committed generation the
    /// lookup used, which is the honest answer and the one that makes
    /// ``ChainedUpstreamSecretStore/consistentSnapshot(attempts:)`` converge: a rotation
    /// landing between the caller's configuration read and this one shows up as a mismatch
    /// the retry resolves, rather than as a stale key wearing a current number. The PSK rides
    /// in the same item, so it is fetched under the same generation with no extra read.
    public func loadPrivateKey() throws
        -> (privateKey: Data, presharedKey: Data?, generation: ChainedUpstreamStoreGeneration)?
    {
        try loadActiveKeyMaterial().map {
            ($0.privateKey, $0.presharedKey, ChainedUpstreamStoreGeneration($0.generation))
        }
    }
}
