import CryptoKit
import Foundation
import Security
import XCTest

@testable import LavaSecKit

/// The pure half of the chained-upstream secret store: naming, the sweep predicate, the
/// generation mint, the access-group resolver, and the write-boundary validation.
///
/// Policy logic, so every assertion here is behavioural — no source pins (CLAUDE.md test
/// conventions).
final class ChainedUpstreamSecretStorageTests: XCTestCase {
    private typealias Naming = ChainedUpstreamSecretNaming
    private typealias Failure = ChainedUpstreamSecretStoreFailure

    func testKeychainRecoveryDistinguishesUnlockBuildRepairAndReimport() {
        let unlock = LavaCoreStrings.localized("Lava couldn't access the saved WireGuard keys. Unlock your device and try again.")
        let repairBuild = LavaCoreStrings.localized("This build can't save a WireGuard configuration. Update Lava and try again.")
        let reimport = LavaCoreStrings.localized("The saved WireGuard configuration is no longer usable. Import it again.")
        let retry = LavaCoreStrings.localized("Lava couldn't save the WireGuard configuration. Try again in a moment.")
        let recoveries: [(OSStatus, String)] = [
            (errSecInteractionNotAllowed, unlock),
            (errSecMissingEntitlement, repairBuild),
            (errSecDecode, reimport),
            (errSecNotAvailable, retry),
            (errSecAuthFailed, retry),
            (-12345, retry),
        ]
        for (status, expected) in recoveries {
            let failure = Failure.keychainRefused(status)
            XCTAssertEqual(failure.localizedDescription, expected)
            XCTAssertEqual(ChainedUpstreamStagingRefusal.rotationRefused(failure).localizedDescription, expected,
                           "The import/save path must carry the same useful recovery as the secret store.")
            XCTAssertFalse(failure.localizedDescription.contains(String(status)), "The Keychain status remains diagnostic data.")
            if status != errSecInteractionNotAllowed {
                XCTAssertNotEqual(failure.localizedDescription, unlock, "Unlocking cannot repair this failure: \(status).")
            }
        }
        XCTAssertEqual(Failure.accessGroupUnavailable.localizedDescription, repairBuild)
        XCTAssertNotEqual(Failure.accessGroupUnavailable.localizedDescription, unlock)
    }

    // MARK: - Naming

    func testAKeyAccountRoundTripsAndOnlyInItsCanonicalSpelling() {
        for generation in [UInt64(1), 10, 0xDEADBEEF, UInt64.max] {
            let account = Naming.keyAccount(for: generation)
            XCTAssertEqual(Naming.generation(fromKeyAccount: account), generation)
        }
        // One spelling per generation. Without the round-trip check, `upstream-key/0A` and
        // `upstream-key/00a` would both parse to 10 while naming items the writer never
        // created — so a sweep could believe an account is the committed one and leave a real
        // orphan behind, or believe the committed one is foreign and leave it alone forever.
        XCTAssertNil(Naming.generation(fromKeyAccount: "upstream-key/0A"))
        XCTAssertNil(Naming.generation(fromKeyAccount: "upstream-key/00a"))
        XCTAssertNil(Naming.generation(fromKeyAccount: "upstream-key/"))
        XCTAssertNil(Naming.generation(fromKeyAccount: "upstream-key/zz"))
        XCTAssertNil(Naming.generation(fromKeyAccount: "device-secret"))
        XCTAssertNil(Naming.generation(fromKeyAccount: "supabase-session"))
    }

    func testTheQAIdentityAddressesDifferentFilesThanProduction() {
        // The key half is separated by its config-scoped access group; the file half has no
        // entitlement to ride on, because `group.com.lavasec` is the SAME in both builds. Both
        // names have to move together — a namespaced configuration under a shared lock would
        // serialize writers that cannot conflict, and a namespaced lock over a shared
        // configuration would serialize nothing while looking as if it did.
        XCTAssertNotEqual(
            Naming.configurationFilename(for: .qa),
            Naming.configurationFilename(for: .production))
        XCTAssertNotEqual(
            Naming.writeLockFilename(for: .qa), Naming.writeLockFilename(for: .production))

        // Production keeps the names it was designed with, so only the internal identity moves
        // and nothing already committed by an App Store build has to be migrated.
        XCTAssertEqual(Naming.configurationFilename(for: .production), "chained-upstream.json")
        XCTAssertEqual(
            Naming.writeLockFilename(for: .production), "chained-upstream-write.lock")

        // Distinct across the whole enumeration, not just this pair: an identity added later
        // whose name collided would reintroduce exactly this defect silently.
        let configurations = ChainedUpstreamStoreIdentity.allCases.map {
            Naming.configurationFilename(for: $0)
        }
        let locks = ChainedUpstreamStoreIdentity.allCases.map { Naming.writeLockFilename(for: $0) }
        XCTAssertEqual(Set(configurations).count, ChainedUpstreamStoreIdentity.allCases.count)
        XCTAssertEqual(Set(locks).count, ChainedUpstreamStoreIdentity.allCases.count)
        XCTAssertTrue(Set(configurations).isDisjoint(with: Set(locks)))
    }

    // MARK: - The sweep predicate

    func testTheSweepNeverNamesTheCommittedGeneration() {
        let accounts = [
            Naming.keyAccount(for: 1),
            Naming.keyAccount(for: 2),
            Naming.keyAccount(for: 3),
            "device-secret",
        ]
        let orphans = Naming.orphanedKeyAccounts(in: accounts, committed: 2)

        XCTAssertFalse(
            orphans.contains(Naming.keyAccount(for: 2)),
            "the committed key must never be swept — deleting it leaves a configuration whose "
                + "key is gone, which is indistinguishable from a migrated device")
        XCTAssertEqual(Set(orphans), [Naming.keyAccount(for: 1), Naming.keyAccount(for: 3)])
        // Foreign accounts are not ours to delete. The service is dedicated today; the filter
        // is what keeps that from being an assumption a later shared service falsifies.
        XCTAssertFalse(orphans.contains("device-secret"))
    }

    func testASweepOverAGenerationThatIsNotPresentStillSparesNothingItOwns() {
        // The launch case: a rotation was killed before its key add, so the committed
        // generation has no item. Everything else is still an orphan.
        let accounts = [Naming.keyAccount(for: 7), Naming.keyAccount(for: 8)]
        XCTAssertEqual(
            Set(Naming.orphanedKeyAccounts(in: accounts, committed: 9)), Set(accounts))
    }

    // MARK: - The mint

    private func mint(feeding values: [UInt64]) -> ChainedUpstreamGenerationMint {
        let box = Box(values)
        return ChainedUpstreamGenerationMint { _ in
            guard let next = box.take() else {
                throw Failure.entropyUnavailable
            }
            return Data((0..<8).reversed().map { UInt8(truncatingIfNeeded: next >> (8 * $0)) })
        }
    }

    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [UInt64]
        init(_ values: [UInt64]) { self.values = values }
        func take() -> UInt64? {
            lock.lock()
            defer { lock.unlock() }
            return values.isEmpty ? nil : values.removeFirst()
        }
    }

    func testTheReservedZeroGenerationIsNeverMinted() throws {
        // `0` is the value a defaulted or zero-filled decode produces, so it is the one value
        // two independently damaged halves could both carry and compare equal on.
        XCTAssertEqual(try mint(feeding: [0, 0, 42]).mint(excluding: nil), 42)
    }

    func testTheCommittedGenerationIsNeverReissued() throws {
        // The anti-reuse property, and the only part of "never reused across rotations" this
        // suite can actually enforce: a stamp that repeats over DIFFERENT content makes the
        // equality comparison agree with an unrelated pair.
        XCTAssertEqual(try mint(feeding: [99, 99, 7]).mint(excluding: 99), 7)
    }

    func testAMintThatCannotDrawAFreshValueRefusesRatherThanReusing() {
        // Bounded: an entropy source that keeps producing a refused value is broken, and
        // looping forever inside a foreground save is a hang. Refusing means no rotation
        // proceeds with a stamp it could not freshly draw.
        XCTAssertThrowsError(try mint(feeding: [5, 5, 5, 5]).mint(excluding: 5, attempts: 3)) {
            XCTAssertEqual($0 as? Failure, .entropyUnavailable)
        }
    }

    func testEntropyFailurePropagatesRatherThanFallingBackToAValue() {
        let mint = ChainedUpstreamGenerationMint { _ in throw Failure.entropyUnavailable }
        XCTAssertThrowsError(try mint.mint(excluding: nil)) {
            XCTAssertEqual($0 as? Failure, .entropyUnavailable)
        }
    }

    func testAShortEntropyDrawIsRefusedRatherThanPaddedToAGeneration() {
        // A 2-byte draw widened to 64 bits is a 16-bit generation wearing a 64-bit type.
        let mint = ChainedUpstreamGenerationMint { _ in Data([0x01, 0x02]) }
        XCTAssertThrowsError(try mint.mint(excluding: nil)) {
            XCTAssertEqual($0 as? Failure, .entropyUnavailable)
        }
    }

    // MARK: - Access-group resolution

    func testAnUnsignedBuildResolvesNoAccessGroup() {
        // `Config/Lava.xcconfig` ships `DEVELOPMENT_TEAM =` empty so no team ID lives in the
        // repo, so `$(DEVELOPMENT_TEAM).com.lavasec.app.chained-upstream` expands to a
        // syntactically fine, semantically garbage string. A store built on it is
        // constructible, answers every read with errSecParam, and reports the feature
        // permanently unavailable with no diagnosis.
        XCTAssertNil(ChainedUpstreamKeychainAccessGroup.resolved(".com.lavasec.app.chained-upstream"))
        XCTAssertNil(ChainedUpstreamKeychainAccessGroup.resolved(nil))
        XCTAssertNil(ChainedUpstreamKeychainAccessGroup.resolved(""))
        XCTAssertNil(ChainedUpstreamKeychainAccessGroup.resolved("   "))
        // An unexpanded setting: a typo in project.yml, not a missing team.
        XCTAssertNil(
            ChainedUpstreamKeychainAccessGroup.resolved("$(LAVA_KEYCHAIN_SHARING_GROUP_ID)"))
        // No suffix at all, and a trailing dot with nothing after it.
        XCTAssertNil(ChainedUpstreamKeychainAccessGroup.resolved("ABCDE12345"))
        XCTAssertNil(ChainedUpstreamKeychainAccessGroup.resolved("ABCDE12345."))
    }

    func testASignedBuildResolvesTheTeamQualifiedGroup() {
        XCTAssertEqual(
            ChainedUpstreamKeychainAccessGroup.resolved("ABCDE12345.com.lavasec.app.chained-upstream"),
            "ABCDE12345.com.lavasec.app.chained-upstream")
        XCTAssertEqual(
            ChainedUpstreamKeychainAccessGroup.resolved(" ABCDE12345.com.lavasec.dev.qa.chained-upstream\n"),
            "ABCDE12345.com.lavasec.dev.qa.chained-upstream")
    }

    // MARK: - The write boundary

    private func configuration(
        peerPublicKey: String = Data(1...32).base64EncodedString()
    ) throws -> ChainedUpstreamConfiguration {
        try ChainedUpstreamConfiguration(
            endpointHost: "203.0.113.9", endpointPort: 51820, peerPublicKey: peerPublicKey,
            clientAddress: "10.64.0.5", allowedIPs: ["0.0.0.0/0"], persistentKeepaliveSeconds: 25)
    }

    func testAKeyThatIsNotThirtyTwoBytesIsRefusedAtTheWriteBoundary() throws {
        // Refused where the user can still fix it. Stored, it would be refused at every latch
        // evaluation for the life of the install instead.
        let configuration = try configuration()
        for length in [0, 1, 31, 33, 64] {
            XCTAssertThrowsError(
                try ChainedUpstreamRotation(
                    configuration: configuration,
                    privateKey: Data(repeating: 0x7F, count: length)), "\(length) bytes"
            ) { XCTAssertEqual($0 as? Failure, .malformedPrivateKey) }
        }
    }

    func testTheAllZeroKeyIsRefused() throws {
        XCTAssertThrowsError(
            try ChainedUpstreamRotation(
                configuration: try configuration(),
                privateKey: Data(repeating: 0, count: 32))
        ) { XCTAssertEqual($0 as? Failure, .unusablePrivateKey) }
    }

    func testTheServersOwnPrivateKeyIsRefusedInEverySpellingOfThePeerKey() throws {
        // The user pasted the SERVER's config instead of the client's. Stored, it presents as
        // a handshake timeout — indistinguishable from an unreachable peer — so it spends the
        // whole outage budget blaming the network.
        let secret = Curve25519.KeyAgreement.PrivateKey()
        let peer = secret.publicKey.rawRepresentation

        // Compared over DECODED BYTES. Base64 of 32 bytes has slack in its final character, so
        // several spellings decode identically and a string comparison is bypassable by
        // re-pasting the same key differently — the lesson `peerKeyFingerprint` already
        // records. Both spellings below decode to the same 32 bytes.
        var spellings = [peer.base64EncodedString()]
        let respelled = respellingTheFinalCharacter(of: peer.base64EncodedString())
        if let respelled { spellings.append(respelled) }
        XCTAssertEqual(spellings.count, 2, "the re-spelled peer key fixture was not produced")

        for spelling in spellings {
            XCTAssertEqual(Data(base64Encoded: spelling), peer, "fixture must decode identically")
            XCTAssertThrowsError(
                try ChainedUpstreamRotation(
                    configuration: try configuration(peerPublicKey: spelling),
                    privateKey: secret.rawRepresentation), spelling
            ) { XCTAssertEqual($0 as? Failure, .privateKeyBelongsToThePeer) }
        }
    }

    func testAnOrdinaryClientKeyIsAccepted() throws {
        // The other direction: a false refusal here locks a user out of the feature.
        let secret = Curve25519.KeyAgreement.PrivateKey()
        let rotation = try ChainedUpstreamRotation(
            configuration: try configuration(), privateKey: secret.rawRepresentation)
        XCTAssertEqual(rotation.privateKey, secret.rawRepresentation)
    }

    /// Another base64 spelling of the same 32 bytes.
    ///
    /// 32 bytes encode to 43 significant characters plus one `=`, and the 43rd carries only
    /// the final 4 bits — its low 2 bits are padding the decoder discards, so three other
    /// values of that character decode to the identical key. That slack is exactly why
    /// `peerKeyFingerprint` hashes the decoded bytes rather than the text, and why a
    /// self-peer check comparing strings would be bypassable by a re-paste.
    private func respellingTheFinalCharacter(of base64: String) -> String? {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")
        var characters = Array(base64)
        guard let lastSignificant = characters.lastIndex(where: { $0 != "=" }) else { return nil }
        let original = characters[lastSignificant]
        for candidate in alphabet where candidate != original {
            characters[lastSignificant] = candidate
            let spelling = String(characters)
            if Data(base64Encoded: spelling) == Data(base64Encoded: base64) {
                return spelling
            }
        }
        return nil
    }
}
