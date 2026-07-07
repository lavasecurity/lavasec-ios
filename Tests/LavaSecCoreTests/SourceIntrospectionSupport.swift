import Foundation
import XCTest

// MARK: - Source-introspection support
//
// The *SourceTests regime pins app/tunnel/shared source AS TEXT because those targets sit
// outside the SPM test target. Every repo file the suite reads is registered here ONCE:
// a moved or renamed file is fixed by updating a single rawValue, and
// `SourceFileRegistryTests` names the stale entry directly — instead of N per-test
// "couldn't be opened" errors scattered across the suite.
//
// Rules:
// - Test files must not hardcode repo paths or re-derive the package root via #filePath;
//   add a case here and call `readSource(_:)` (or `sourceFileURL(_:)` for binary reads).
// - Missing files and missing block markers FAIL the test — never XCTSkip — so a renamed
//   anchor cannot silently disarm the assertions that read it.

/// Repo-relative location of every file pinned by a source-introspection test.
enum SourceFile: String, CaseIterable {
    // MARK: LavaSecApp
    case accountAuthService = "LavaSecApp/AccountAuthService.swift"
    case accountSessionKeychainStore = "LavaSecApp/AccountSessionKeychainStore.swift"
    case adminQAView = "LavaSecApp/AdminQAView.swift"
    case appEntitlements = "LavaSecApp/LavaSecApp.entitlements"
    case appInfoPlist = "LavaSecApp/Info.plist"
    case appViewModel = "LavaSecApp/AppViewModel.swift"
    case backupKeychainStore = "LavaSecApp/BackupKeychainStore.swift"
    case backupPasskeyCoordinator = "LavaSecApp/BackupPasskeyCoordinator.swift"
    case backupRestoreView = "LavaSecApp/BackupRestoreView.swift"
    case backupSetupView = "LavaSecApp/BackupSetupView.swift"
    case backupSyncService = "LavaSecApp/BackupSyncService.swift"
    case darwinNotificationObserver = "LavaSecApp/DarwinNotificationObserver.swift"
    case developerPreviewViews = "LavaSecApp/DeveloperPreviewViews.swift"
    case diagnosticsView = "LavaSecApp/DiagnosticsView.swift"
    case filterReviewFlowView = "LavaSecApp/FilterReviewFlowView.swift"
    case filtersView = "LavaSecApp/FiltersView.swift"
    case guardView = "LavaSecApp/GuardView.swift"
    case infoPlistStringsCatalog = "LavaSecApp/InfoPlist.xcstrings"
    case lavaComponents = "LavaSecApp/LavaDesignSystem/LavaComponents.swift"
    case lavaCondensedList = "LavaSecApp/LavaCondensedList.swift"
    case lavaIcon = "LavaSecApp/LavaDesignSystem/LavaIcon.swift"
    case lavaLiveActivityController = "LavaSecApp/LavaLiveActivityController.swift"
    case lavaScaffold = "LavaSecApp/LavaDesignSystem/LavaScaffold.swift"
    case lavaSecApp = "LavaSecApp/LavaSecApp.swift"
    case lavaSecurityPlusStore = "LavaSecApp/LavaSecurityPlusStore.swift"
    case lavaTokens = "LavaSecApp/LavaDesignSystem/LavaTokens.swift"
    case localizableStringsCatalog = "LavaSecApp/Localizable.xcstrings"
    case onboardingFlowView = "LavaSecApp/OnboardingFlowView.swift"
    case protectionConnectivityPresentation = "LavaSecApp/ProtectionConnectivityPresentation.swift"
    case protectionPlatformSeams = "LavaSecApp/ProtectionPlatformSeams.swift"
    case rootView = "LavaSecApp/RootView.swift"
    case securityController = "LavaSecApp/SecurityController.swift"
    case settingsView = "LavaSecApp/SettingsView.swift"
    case shareableFiltersUI = "LavaSecApp/ShareableFiltersUI.swift"
    case temporaryProtectionPauseController = "LavaSecApp/TemporaryProtectionPauseController.swift"

    // MARK: LavaSecTunnel
    case packetTunnelProvider = "LavaSecTunnel/PacketTunnelProvider.swift"

    // MARK: LavaSecWidget
    case lavaSecWidget = "LavaSecWidget/LavaSecWidget.swift"

    // MARK: LavaSecIntents
    case focusFilterIntent = "LavaSecIntents/FocusFilterIntent.swift"
    case intentsInfoPlist = "LavaSecIntents/Info.plist"
    case lavaSecIntentsExtension = "LavaSecIntents/LavaSecIntentsExtension.swift"

    // MARK: Shared
    case appGroup = "Shared/AppGroup.swift"
    case focusSwitchEnvironment = "Shared/FocusSwitchEnvironment.swift"
    case lavaActivityAttributes = "Shared/LavaActivityAttributes.swift"
    case lavaLiveActivityActionRequest = "Shared/LavaLiveActivityActionRequest.swift"
    case lavaLiveActivityIntents = "Shared/LavaLiveActivityIntents.swift"
    case lavaProtectionCommandService = "Shared/LavaProtectionCommandService.swift"
    case softShieldGuardian = "Shared/SoftShieldGuardian.swift"

    // MARK: Sources/LavaSecCore
    case appConfiguration = "Sources/LavaSecKit/AppConfiguration.swift"
    case backupConfigurationPayload = "Sources/LavaSecAppServices/BackupConfigurationPayload.swift"
    case blocklistCatalogSync = "Sources/LavaSecFilterPipeline/BlocklistCatalogSync.swift"
    case dnsResponseCache = "Sources/LavaSecDNS/DNSResponseCache.swift"
    case doHTransport = "Sources/LavaSecDNS/DoHTransport.swift"
    case doQTransport = "Sources/LavaSecDNS/DoQTransport.swift"
    case doTTransport = "Sources/LavaSecDNS/DoTTransport.swift"
    case encryptedBackupState = "Sources/LavaSecAppServices/EncryptedBackupState.swift"
    case filterArtifactStoreVersioned = "Sources/LavaSecFilterPipeline/FilterArtifactStoreVersioned.swift"
    case filterSnapshot = "Sources/LavaSecKit/FilterSnapshot.swift"
    case filterSnapshotPreparationService = "Sources/LavaSecFilterPipeline/FilterSnapshotPreparationService.swift"
    case focusFilterSwitchCoordination = "Sources/LavaSecFilterPipeline/FocusFilterSwitchCoordination.swift"
    case headlessFocusFilterSwitchEngine = "Sources/LavaSecFilterPipeline/HeadlessFocusFilterSwitchEngine.swift"
    case lavaIconSize = "Sources/LavaSecKit/LavaIconSize.swift"
    case networkActivityLog = "Sources/LavaSecKit/NetworkActivityLog.swift"
    case pinnedPublicHTTPSFetcher = "Sources/LavaSecDNS/PinnedPublicHTTPSFetcher.swift"
    case protectionConnectivityPolicy = "Sources/LavaSecKit/ProtectionConnectivityPolicy.swift"
    case rageShakeQA = "Sources/LavaSecAppServices/RageShakeQA.swift"
    case resolverOrchestrator = "Sources/LavaSecDNS/ResolverOrchestrator.swift"
    case securityAccessPolicy = "Sources/LavaSecKit/SecurityAccessPolicy.swift"
    case shareableFilterConfiguration = "Sources/LavaSecKit/ShareableFilterConfiguration.swift"
    case sharedFilterStatePersistence = "Sources/LavaSecKit/SharedFilterStatePersistence.swift"
    case tunnelHealthSignal = "Sources/LavaSecKit/TunnelHealthSignal.swift"
    case tunnelSelfReconnectPolicy = "Sources/LavaSecKit/TunnelSelfReconnectPolicy.swift"
    case warmFilterSnapshotLoader = "Sources/LavaSecFilterPipeline/WarmFilterSnapshotLoader.swift"
    case zeroKnowledgeBackupEnvelope = "Sources/LavaSecAppServices/ZeroKnowledgeBackupEnvelope.swift"

    // MARK: LavaSec.xcodeproj
    case xcodeProject = "LavaSec.xcodeproj/project.pbxproj"

    // MARK: Vendored cross-platform contracts (pinned in contracts.lock)
    case incidentLedgerContract = "contracts/incident-ledger.json"

    // MARK: GitHub workflows
    case tagReleaseWorkflow = ".github/workflows/tag-release.yml"
}

extension SourceFile {
    /// Registered files that exist ONLY in the internal repo: the public export
    /// (`scripts/export-public-source.sh`) denylists internal release machinery, and the
    /// public repo runs this same test suite (byte-identical-lanes rule), so pins on these
    /// files must skip there — visibly via `XCTSkip`, never a silent pass. Where the
    /// machinery actually lives, the pin still enforces (INV-REL-1).
    var isInternalOnly: Bool {
        switch self {
        case .tagReleaseWorkflow: true
        default: false
        }
    }
}

/// True when the suite runs inside a public-export tree. Discriminator: the export script
/// denylists ITSELF, so its absence is definitional for an exported tree — it cannot rot
/// without the export changing too. In the internal repo the script exists, so internal
/// runs never skip and a renamed internal-only file still fails the registry self-check.
var isPublicExportTree: Bool {
    !FileManager.default.fileExists(
        atPath: packageRootURL.appendingPathComponent("scripts/export-public-source.sh").path
    )
}

/// Package root, derived once from this file's location (Tests/LavaSecCoreTests/…).
let packageRootURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()

/// Absolute location of a registered file. Use for non-text reads (Data, assets metadata);
/// prefer `readSource(_:)` for text.
func sourceFileURL(_ sourceFile: SourceFile) -> URL {
    packageRootURL.appendingPathComponent(sourceFile.rawValue)
}

struct SourceIntrospectionFailure: Error, CustomStringConvertible {
    let description: String
}

/// Reads a registered repo file as UTF-8 text. Pins on internal-only files (see
/// `SourceFile.isInternalOnly`) skip in a public-export tree instead of failing.
func readSource(_ sourceFile: SourceFile) throws -> String {
    do {
        return try String(contentsOf: sourceFileURL(sourceFile), encoding: .utf8)
    } catch {
        if sourceFile.isInternalOnly, isPublicExportTree {
            throw XCTSkip("""
            SourceFile.\(sourceFile) is internal-only (\(sourceFile.rawValue)) and this is \
            a public-export tree — the pin enforces in the internal repo, where the file \
            lives.
            """)
        }
        throw SourceIntrospectionFailure(description: """
        SourceFile.\(sourceFile) could not be read at \(sourceFile.rawValue) — if the file \
        moved or was renamed, update its rawValue in SourceIntrospectionSupport.swift \
        (underlying error: \(error))
        """)
    }
}

/// Extracts the block from the first occurrence of `startMarker` up to (not including) the
/// first occurrence of `endMarker` AFTER the start marker's end — an end marker can never
/// match inside the start marker text and silently yield an empty block. Omit `endingBefore`
/// to capture through end-of-file.
func sourceBlock(
    in source: String,
    startingAt startMarker: String,
    endingBefore endMarker: String? = nil,
    file: StaticString = #filePath,
    line: UInt = #line
) throws -> String {
    let start = try XCTUnwrap(
        source.range(of: startMarker),
        "start marker not found: \(startMarker)",
        file: file,
        line: line
    )
    guard let endMarker else {
        return String(source[start.lowerBound...])
    }
    let end = try XCTUnwrap(
        source.range(of: endMarker, range: start.upperBound..<source.endIndex),
        "end marker not found after \"\(startMarker)\": \(endMarker)",
        file: file,
        line: line
    )
    return String(source[start.lowerBound..<end.lowerBound])
}

// MARK: - Registry self-check

final class SourceFileRegistryTests: XCTestCase {
    /// One actionable failure naming the stale registry entry, instead of every test that
    /// reads the file failing with its own file-not-found error.
    func testEveryRegisteredSourceFileExistsOnDisk() {
        for sourceFile in SourceFile.allCases
        where !FileManager.default.fileExists(atPath: sourceFileURL(sourceFile).path) {
            // Internal-only entries legitimately don't exist in a public-export tree (the
            // export denylists internal release machinery). The internal repo still fails
            // on a stale path because the export script exists there.
            if sourceFile.isInternalOnly, isPublicExportTree { continue }
            XCTFail("""
            SourceFile.\(sourceFile) is stale: \(sourceFile.rawValue) does not exist — \
            if the file moved or was renamed, update its rawValue in \
            SourceIntrospectionSupport.swift
            """)
        }
    }
}
