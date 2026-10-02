import Foundation
import XCTest

/// The cross-process wiring for the chained-upstream secret store, pinned as TEXT.
///
/// This is the sanctioned use of a source pin (CLAUDE.md test conventions): entitlement
/// plists, Info.plist keys, and `project.yml` settings are not in the SPM test target and the
/// compiler cannot see any of them. The failure they guard against is silent in the worst way
/// — a group present in one target and not the other gives `errSecItemNotFound`, which
/// `GenericKeychainStore.loadData` maps to `nil`, which reads as "you never configured this".
final class ChainedUpstreamEntitlementSourceTests: XCTestCase {
    private let sharedGroupEntry = "$(AppIdentifierPrefix)$(LAVA_KEYCHAIN_SHARING_GROUP)"
    private let ownBundleEntry = "$(AppIdentifierPrefix)$(CFBundleIdentifier)"

    func testTheAppAndTheTunnelBothDeclareTheSameSharedKeychainGroup() throws {
        for file in [SourceFile.appEntitlements, .tunnelEntitlements] {
            let entitlements = try readSource(file)
            XCTAssertTrue(
                entitlements.contains("<key>keychain-access-groups</key>"),
                "\(file.rawValue) must declare the keychain sharing entitlement — app groups do "
                    + "NOT share keychain items")
            XCTAssertTrue(
                entitlements.contains(sharedGroupEntry),
                "\(file.rawValue) must name the shared group")
        }
    }

    func testTheTargetsOwnGroupIsListedFirstSoExistingStoresDoNotMove() throws {
        // The defect this pins: when a `keychain-access-groups` entitlement is present, an
        // `SecItemAdd` that passes no `kSecAttrAccessGroup` lands in the FIRST entry of that
        // array. The app's three existing stores — the ZK backup device secret
        // (`com.lavasec.zero-knowledge-backup`), the Supabase session
        // (`com.lavasec.account-session`), and the passcode verifier
        // (`com.lavasec.app-security`) — all pass no group, so listing the shared group first
        // would silently start writing THEM into a group the tunnel appex also holds. Their
        // source would be untouched; their stored items would not.
        for file in [SourceFile.appEntitlements, .tunnelEntitlements] {
            let entitlements = try readSource(file)
            guard let ownIndex = entitlements.range(of: ownBundleEntry)?.lowerBound,
                  let sharedIndex = entitlements.range(of: sharedGroupEntry)?.lowerBound
            else {
                return XCTFail("\(file.rawValue) is missing one of the two group entries")
            }
            XCTAssertLessThan(
                ownIndex, sharedIndex,
                "\(file.rawValue): the target's own group must be the FIRST entry, or every "
                    + "un-scoped SecItemAdd in that process relocates into the shared group")
        }
    }

    func testTheWidgetAndTheIntentsExtensionAreNotEntitledToTheKey() throws {
        // Least privilege, and the reason `group.com.lavasec` is NOT reused as the keychain
        // access group: all four targets carry that app group, so reusing it would grant the
        // widget and the App Intents extension read access to a VPN private key.
        for file in [SourceFile.widgetEntitlements, .intentsEntitlements] {
            let entitlements = try readSource(file)
            XCTAssertFalse(
                entitlements.contains("keychain-access-groups"),
                "\(file.rawValue) has no use for the upstream key")
        }
    }

    func testBothProcessesReadTheSameRuntimeGroupString() throws {
        // `$(AppIdentifierPrefix)` is injected by the entitlements-processing step from the
        // provisioning profile and does NOT expand in an Info.plist, so the runtime string is
        // built from `$(DEVELOPMENT_TEAM)` instead. A build where those two differ — a legacy
        // App ID with a non-matching prefix — fails LOUDLY with errSecMissingEntitlement
        // rather than silently reading an empty store.
        for file in [SourceFile.appInfoPlist, .tunnelInfoPlist] {
            let plist = try readSource(file)
            XCTAssertTrue(plist.contains("<key>LavaKeychainSharingGroup</key>"), file.rawValue)
            XCTAssertTrue(plist.contains("$(LAVA_KEYCHAIN_SHARING_GROUP_ID)"), file.rawValue)
        }

        let project = try readSource(.projectYAML)
        XCTAssertEqual(
            project.components(separatedBy: "LAVA_KEYCHAIN_SHARING_GROUP_ID:").count - 1, 2,
            "the app and the tunnel must both define the runtime group setting")
        XCTAssertTrue(
            project.contains(
                "LAVA_KEYCHAIN_SHARING_GROUP_ID: \"$(LAVA_KEYCHAIN_SHARING_GROUP_PREFIX).$(LAVA_KEYCHAIN_SHARING_GROUP)\""))
    }

    func testTheQAIdentityGetsItsOwnGroupSoItCannotShareAProductionUpstream() throws {
        // The QA configuration signs as `com.lavasec.dev.qa*`. A single un-scoped group string
        // would let a QA build and a production build on one device share one upstream record
        // INCLUDING the private key; every other identity in this project is config-scoped.
        let project = try readSource(.projectYAML)
        XCTAssertEqual(
            project.components(
                separatedBy: "LAVA_KEYCHAIN_SHARING_GROUP: com.lavasec.dev.qa.chained-upstream"
            ).count - 1, 2,
            "both QA configurations must override the sharing group")
        XCTAssertEqual(
            project.components(
                separatedBy: "LAVA_KEYCHAIN_SHARING_GROUP: com.lavasec.app.chained-upstream"
            ).count - 1, 2)
    }

    func testTheFileHalfIsNamespacedByTheSameConfigurationAsTheKeyHalf() throws {
        // The key half's separation is an entitlement and the file half's is a filename, so
        // nothing in the compiler relates them — but they must move together, or a build ends
        // up reading one identity's configuration and looking for the other identity's key.
        //
        // What makes them one decision is that a single build CONFIGURATION drives both:
        // project.yml's QA config is the only place that overrides
        // `LAVA_KEYCHAIN_SHARING_GROUP`, and the same config is the only place that defines
        // `LAVA_QA_TOOLS`, which is the condition `Shared/AppGroup.swift` selects the identity
        // on. This pins that coincidence, which is otherwise only true by inspection.
        let project = try readSource(.projectYAML)
        XCTAssertTrue(
            project.contains("SWIFT_ACTIVE_COMPILATION_CONDITIONS: RELEASE LAVA_QA_TOOLS"),
            "the QA configuration must define LAVA_QA_TOOLS, or the identity below never "
                + "selects .qa and both builds share one configuration file")
        XCTAssertTrue(
            project.contains("SWIFT_ACTIVE_COMPILATION_CONDITIONS: DEBUG\n"),
            "the Debug configuration must NOT define LAVA_QA_TOOLS: it signs as "
                + "com.lavasec.app and inherits the production keychain group, so it has to "
                + "address the production configuration file too")

        let appGroup = try readSource(.appGroup)
        XCTAssertTrue(
            appGroup.contains("#if LAVA_QA_TOOLS"), "Shared/AppGroup.swift")
        XCTAssertTrue(
            appGroup.contains("static let chainedUpstreamStoreIdentity = "
                + "ChainedUpstreamStoreIdentity.qa"),
            "the QA build must address the QA identity")
        XCTAssertTrue(
            appGroup.contains("static let chainedUpstreamStoreIdentity = "
                + "ChainedUpstreamStoreIdentity.production"),
            "every other configuration must address the production identity")
        // Both filenames must be DERIVED from that one identity. A literal filename here is
        // the whole defect: `chained-upstream.json` written by both builds into the App Group
        // they share, while their keys sit in access groups they do not.
        for derived in [
            "ChainedUpstreamSecretNaming.configurationFilename(for: chainedUpstreamStoreIdentity)",
            "ChainedUpstreamSecretNaming.writeLockFilename(for: chainedUpstreamStoreIdentity)",
            "switch chainedUpstreamStoreIdentity",
            "chained-startup-failure-marker.json",
            "chained-startup-failure-marker.qa.json",
        ] {
            XCTAssertTrue(appGroup.contains(derived), derived)
        }
        XCTAssertTrue(
            appGroup.contains("static var chainedStartupFailureMarkerURL: URL?"),
            "the terminal marker must be addressed through the identity-scoped App Group file")
    }
}
