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
    // MARK: Config
    case supportedLocalesManifest = "Config/supported-locales.json"

    // MARK: LavaSecApp
    case accountBackupSettingsView = "LavaSecApp/AccountBackupSettingsView.swift"
    case accountAuthService = "LavaSecApp/AccountAuthService.swift"
    case accountController = "LavaSecApp/AccountController.swift"
    case accountSessionKeychainStore = "LavaSecApp/AccountSessionKeychainStore.swift"
    case adminQAView = "LavaSecApp/AdminQAView.swift"
    case appEntitlements = "LavaSecApp/LavaSecApp.entitlements"
    case appInfoPlist = "LavaSecApp/Info.plist"
    case appViewModel = "LavaSecApp/AppViewModel.swift"
    case backupController = "LavaSecApp/BackupController.swift"
    case backupKeychainStore = "LavaSecApp/BackupKeychainStore.swift"
    case backupPasskeyCoordinator = "LavaSecApp/BackupPasskeyCoordinator.swift"
    case backupRestoreView = "LavaSecApp/BackupRestoreView.swift"
    case backupSetupView = "LavaSecApp/BackupSetupView.swift"
    case backupSyncService = "LavaSecApp/BackupSyncService.swift"
    case blocklistPickerView = "LavaSecApp/BlocklistPickerView.swift"
    case bugReportSettingsView = "LavaSecApp/BugReportSettingsView.swift"
    case catalogController = "LavaSecApp/CatalogController.swift"
    case customizationController = "LavaSecApp/CustomizationController.swift"
    case customizationSettingsView = "LavaSecApp/CustomizationSettingsView.swift"
    case darwinNotificationObserver = "LavaSecApp/DarwinNotificationObserver.swift"
    case developerPreviewViews = "LavaSecApp/DeveloperPreviewViews.swift"
    case diagnosticsController = "LavaSecApp/DiagnosticsController.swift"
    case diagnosticsDateControls = "LavaSecApp/DiagnosticsDateControls.swift"
    case diagnosticsDomainHistory = "LavaSecApp/DiagnosticsDomainHistory.swift"
    case diagnosticsLocalLogSupport = "LavaSecApp/DiagnosticsLocalLogSupport.swift"
    case diagnosticsNetworkActivity = "LavaSecApp/DiagnosticsNetworkActivity.swift"
    case diagnosticsTopDomains = "LavaSecApp/DiagnosticsTopDomains.swift"
    case diagnosticsView = "LavaSecApp/DiagnosticsView.swift"
    case dnsResolverSettingsView = "LavaSecApp/DNSResolverSettingsView.swift"
    case filterDomainSheets = "LavaSecApp/FilterDomainSheets.swift"
    case filterLibraryView = "LavaSecApp/FilterLibraryView.swift"
    case filterMyListView = "LavaSecApp/FilterMyListView.swift"
    case filterReviewFlowView = "LavaSecApp/FilterReviewFlowView.swift"
    case filterSharedViews = "LavaSecApp/FilterSharedViews.swift"
    case filtersView = "LavaSecApp/FiltersView.swift"
    case guardView = "LavaSecApp/GuardView.swift"
    case infoPlistStringsCatalog = "LavaSecApp/InfoPlist.xcstrings"
    case lavaComponents = "LavaSecApp/LavaDesignSystem/LavaComponents.swift"
    case lavaCondensedList = "LavaSecApp/LavaDesignSystem/LavaCondensedList.swift"
    case lavaIcon = "LavaSecApp/LavaDesignSystem/LavaIcon.swift"
    case lavaLiveActivityController = "LavaSecApp/LavaLiveActivityController.swift"
    case lavaScaffold = "LavaSecApp/LavaDesignSystem/LavaScaffold.swift"
    case lavaSecApp = "LavaSecApp/LavaSecApp.swift"
    case lavaSecurityPlusController = "LavaSecApp/LavaSecurityPlusController.swift"
    case lavaSecurityPlusStore = "LavaSecApp/LavaSecurityPlusStore.swift"
    case lavaTokens = "LavaSecApp/LavaDesignSystem/LavaTokens.swift"
    case localizableStringsCatalog = "LavaSecApp/Localizable.xcstrings"
    case legalVersionSettingsView = "LavaSecApp/LegalVersionSettingsView.swift"
    case onboardingFlowView = "LavaSecApp/OnboardingFlowView.swift"
    case protectionConnectivityPresentation = "LavaSecApp/ProtectionConnectivityPresentation.swift"
    case protectionPlatformSeams = "LavaSecApp/ProtectionPlatformSeams.swift"
    case privacySecuritySettingsView = "LavaSecApp/PrivacySecuritySettingsView.swift"
    case rootView = "LavaSecApp/RootView.swift"
    case securityController = "LavaSecApp/SecurityController.swift"
    case settingsCommon = "LavaSecApp/SettingsCommon.swift"
    case settingsView = "LavaSecApp/SettingsView.swift"
    case shareableFiltersUI = "LavaSecApp/ShareableFiltersUI.swift"
    // App-target (App Shortcuts register from the app bundle, not the extension).
    case switchFilterShortcut = "LavaSecApp/SwitchFilterShortcut.swift"
    case temporaryProtectionPauseController = "LavaSecApp/TemporaryProtectionPauseController.swift"
    case upgradeSettingsView = "LavaSecApp/UpgradeSettingsView.swift"

    // MARK: LavaSecTunnel
    case packetTunnelProvider = "LavaSecTunnel/PacketTunnelProvider.swift"

    // MARK: LavaSecWidget
    case lavaSecWidget = "LavaSecWidget/LavaSecWidget.swift"

    // MARK: LavaSecIntents
    case focusFilterIntent = "LavaSecIntents/FocusFilterIntent.swift"
    case intentsInfoPlist = "LavaSecIntents/Info.plist"
    case lavaSecIntentsExtension = "LavaSecIntents/LavaSecIntentsExtension.swift"

    // MARK: LavaSecUITests
    case coreFlowDeviceTests = "LavaSecUITests/CoreFlowDeviceTests.swift"

    // MARK: Shared
    case appGroup = "Shared/AppGroup.swift"
    case focusSwitchEnvironment = "Shared/FocusSwitchEnvironment.swift"
    // LavaFilterEntity + LavaFilterEntityQuery are shared by the app-target Switch intent and the
    // extension-target Focus intent (compiled into both), so the AppEntity has ONE record.
    case lavaFilterEntity = "Shared/LavaFilterEntity.swift"
    case lavaActivityAttributes = "Shared/LavaActivityAttributes.swift"
    case lavaLiveActivityActionRequest = "Shared/LavaLiveActivityActionRequest.swift"
    case lavaLiveActivityIntents = "Shared/LavaLiveActivityIntents.swift"
    case lavaProtectionCommandService = "Shared/LavaProtectionCommandService.swift"
    case softShieldGuardian = "Shared/SoftShieldGuardian.swift"

    // MARK: Swift package sources
    case appDeepLink = "Sources/LavaSecKit/AppDeepLink.swift"
    case appConfiguration = "Sources/LavaSecKit/AppConfiguration.swift"
    case backgroundWarmIndex = "Sources/LavaSecFilterPipeline/BackgroundWarmIndex.swift"
    case backupConfigurationPayload = "Sources/LavaSecAppServices/BackupConfigurationPayload.swift"
    case backupEnvelopeStore = "Sources/LavaSecAppServices/BackupEnvelopeStore.swift"
    case backupPasswordPolicy = "Sources/LavaSecAppServices/BackupPasswordPolicy.swift"
    case backupRecoveryPhraseUnlock = "Sources/LavaSecAppServices/BackupRecoveryPhraseUnlock.swift"
    case blocklistCatalogRepository = "Sources/LavaSecFilterPipeline/BlocklistCatalogRepository.swift"
    case blocklistCatalogSync = "Sources/LavaSecFilterPipeline/BlocklistCatalogSync.swift"
    case blocklistParser = "Sources/LavaSecFilterPipeline/BlocklistParser.swift"
    case bugReportBundle = "Sources/LavaSecAppServices/BugReportBundle.swift"
    case catalogPresentationState = "Sources/LavaSecFilterPipeline/CatalogPresentationState.swift"
    case catalogSourceModels = "Sources/LavaSecKit/CatalogSourceModels.swift"
    case compactFilterSnapshot = "Sources/LavaSecFilterPipeline/CompactFilterSnapshot.swift"
    case customBlocklistSource = "Sources/LavaSecKit/CustomBlocklistSource.swift"
    case dnsMessage = "Sources/LavaSecDNS/DNSMessage.swift"
    case dnsResponseCache = "Sources/LavaSecDNS/DNSResponseCache.swift"
    case dnsResolverRuntimePlan = "Sources/LavaSecDNS/DNSResolverRuntimePlan.swift"
    case doHTransport = "Sources/LavaSecDNS/DoHTransport.swift"
    case doQTransport = "Sources/LavaSecDNS/DoQTransport.swift"
    case doTTransport = "Sources/LavaSecDNS/DoTTransport.swift"
    case domainName = "Sources/LavaSecKit/DomainName.swift"
    case encryptedBackupState = "Sources/LavaSecAppServices/EncryptedBackupState.swift"
    case exclusiveReplacementGate = "Sources/LavaSecFilterPipeline/ExclusiveReplacementGate.swift"
    case filterArtifactStore = "Sources/LavaSecFilterPipeline/FilterArtifactStore.swift"
    case filterArtifactStoreVersioned = "Sources/LavaSecFilterPipeline/FilterArtifactStoreVersioned.swift"
    case filter = "Sources/LavaSecKit/Filter.swift"
    case filterConfigurationDiff = "Sources/LavaSecKit/FilterConfigurationDiff.swift"
    case filterSnapshot = "Sources/LavaSecKit/FilterSnapshot.swift"
    case filterSnapshotMemoryBudget = "Sources/LavaSecFilterPipeline/FilterSnapshotMemoryBudget.swift"
    case filterSnapshotPreparationService = "Sources/LavaSecFilterPipeline/FilterSnapshotPreparationService.swift"
    case focusFilterSwitchCoordination = "Sources/LavaSecFilterPipeline/FocusFilterSwitchCoordination.swift"
    case guardianMascotAnimation = "Sources/LavaSecPresentation/GuardianMascotAnimation.swift"
    case guardianMascotState = "Sources/LavaSecKit/GuardianMascotState.swift"
    case headlessFocusFilterSwitchEngine = "Sources/LavaSecFilterPipeline/HeadlessFocusFilterSwitchEngine.swift"
    case ipv4UDPDNSPacket = "Sources/LavaSecDNS/IPv4UDPDNSPacket.swift"
    case knownBlocklistURLMatcher = "Sources/LavaSecFilterPipeline/KnownBlocklistURLMatcher.swift"
    case lavaIconSize = "Sources/LavaSecKit/LavaIconSize.swift"
    case latencyTrace = "Sources/LavaSecKit/LatencyTrace.swift"
    case localLogExportArchive = "Sources/LavaSecAppServices/LocalLogExportArchive.swift"
    case localLogTimestampFormatter = "Sources/LavaSecKit/LocalLogTimestampFormatter.swift"
    case networkActivityLog = "Sources/LavaSecKit/NetworkActivityLog.swift"
    case networkEndpointValidation = "Sources/LavaSecKit/NetworkEndpointValidation.swift"
    case onboardingAnimation = "Sources/LavaSecAppServices/OnboardingAnimation.swift"
    case onboardingDefaults = "Sources/LavaSecKit/OnboardingDefaults.swift"
    case pinnedPublicHTTPSFetcher = "Sources/LavaSecNetworking/PinnedPublicHTTPSFetcher.swift"
    case preparedFilterSnapshot = "Sources/LavaSecFilterPipeline/PreparedFilterSnapshot.swift"
    case protectionConnectivityPolicy = "Sources/LavaSecKit/ProtectionConnectivityPolicy.swift"
    case rageShakeQA = "Sources/LavaSecAppServices/RageShakeQA.swift"
    case resolverHealthCoordinator = "Sources/LavaSecDNS/ResolverHealthCoordinator.swift"
    case resolverHealthGateway = "Sources/LavaSecDNS/ResolverHealthGateway.swift"
    case resolverOrchestrator = "Sources/LavaSecDNS/ResolverOrchestrator.swift"
    case ruleSetCache = "Sources/LavaSecFilterPipeline/RuleSetCache.swift"
    case securityAccessPolicy = "Sources/LavaSecKit/SecurityAccessPolicy.swift"
    case shareableFilterConfiguration = "Sources/LavaSecKit/ShareableFilterConfiguration.swift"
    case sharedFilterStatePersistence = "Sources/LavaSecKit/SharedFilterStatePersistence.swift"
    case sharedStateFileProtection = "Sources/LavaSecKit/SharedStateFileProtection.swift"
    case socketResolvers = "Sources/LavaSecDNS/SocketResolvers.swift"
    case streamingCompactSnapshotCompiler = "Sources/LavaSecFilterPipeline/StreamingCompactSnapshotCompiler.swift"
    case supabaseIDTokenAuth = "Sources/LavaSecAppServices/SupabaseIDTokenAuth.swift"
    case thirdPartyLegalNotice = "Sources/LavaSecAppServices/ThirdPartyLegalNotice.swift"
    case tunnelHealthSignal = "Sources/LavaSecKit/TunnelHealthSignal.swift"
    case tunnelSelfReconnectPolicy = "Sources/LavaSecKit/TunnelSelfReconnectPolicy.swift"
    case topDomainCounter = "Sources/LavaSecKit/TopDomainCounter.swift"
    case warmFilterSnapshotLoader = "Sources/LavaSecFilterPipeline/WarmFilterSnapshotLoader.swift"
    case zeroKnowledgeBackupEnvelope = "Sources/LavaSecAppServices/ZeroKnowledgeBackupEnvelope.swift"

    // MARK: Repository metadata and architecture guides
    case readme = "README.md"
    case claude = "CLAUDE.md"
    case package = "Package.swift"
    case projectYAML = "project.yml"
    case swiftLintMissingDocsConfiguration = ".swiftlint-missing-docs.yml"
    case moduleBoundaries = "docs/architecture/module-boundaries.md"

    // MARK: LavaSec.xcodeproj
    case xcodeProject = "LavaSec.xcodeproj/project.pbxproj"

    // MARK: Vendored cross-platform contracts (pinned in contracts.lock)
    case incidentLedgerContract = "contracts/incident-ledger.json"

    // MARK: GitHub workflows
    case iosWorkflow = ".github/workflows/ios.yml"
    case lightBuildWorkflow = ".github/workflows/light-build.yml"
    case tagReleaseWorkflow = ".github/workflows/tag-release.yml"
}

/// Repo-relative locations whose absence is itself pinned by a source-introspection test.
/// Keep these separate from `SourceFile`: registry entries above must exist, while these
/// paths deliberately must not.
enum ExpectedAbsentSourceFile: String {
    case backupPasskeyRecoveryService = "LavaSecApp/BackupPasskeyRecoveryService.swift"
    case appServicesGuardianMascotAnimation = "Sources/LavaSecAppServices/GuardianMascotAnimation.swift"
    case dnsPinnedPublicHTTPSFetcher = "Sources/LavaSecDNS/PinnedPublicHTTPSFetcher.swift"
}

extension SourceFile {
    /// Registered files that exist ONLY in the internal repo: the public export
    /// (`scripts/export-public-source.sh`) denylists internal release machinery, and the
    /// public repo runs this same test suite (byte-identical-lanes rule), so pins on these
    /// files must skip there — visibly via `XCTSkip`, never a silent pass. Where the
    /// machinery actually lives, the pin still enforces (INV-REL-1).
    var isInternalOnly: Bool {
        switch self {
        case .lightBuildWorkflow, .tagReleaseWorkflow: true
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

/// Absolute location of a file expected not to exist in the repository.
func expectedAbsentSourceFileURL(_ sourceFile: ExpectedAbsentSourceFile) -> URL {
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

/// Reassembles the Settings feature sources in route-family order for contracts that
/// intentionally span the shell and multiple extracted families.
func readSettingsSourceAggregate() throws -> String {
    try [
        readSource(.settingsView),
        readSource(.accountBackupSettingsView),
        readSource(.upgradeSettingsView),
        readSource(.customizationSettingsView),
        readSource(.dnsResolverSettingsView),
        readSource(.privacySecuritySettingsView),
        readSource(.bugReportSettingsView),
        readSource(.legalVersionSettingsView),
        readSource(.settingsCommon),
    ].joined(separator: "\n")
}

/// Reassembles the Filters feature sources for contracts that intentionally span the
/// shell and multiple extracted domains. Declaration-specific tests should read the
/// owning source directly so a move cannot silently weaken their boundary.
func readFiltersSourceAggregate() throws -> String {
    try [
        readSource(.filtersView),
        readSource(.filterLibraryView),
        readSource(.filterMyListView),
        readSource(.filterSharedViews),
        readSource(.filterDomainSheets),
        readSource(.blocklistPickerView),
    ].joined(separator: "\n")
}

/// Reassembles the Diagnostics feature sources for contracts that intentionally span
/// the overview shell and multiple extracted local-log domains.
func readDiagnosticsSourceAggregate() throws -> String {
    try [
        readSource(.diagnosticsView),
        readSource(.diagnosticsDateControls),
        readSource(.diagnosticsLocalLogSupport),
        readSource(.diagnosticsNetworkActivity),
        readSource(.diagnosticsDomainHistory),
        readSource(.diagnosticsTopDomains),
    ].joined(separator: "\n")
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

/// Counts exact, non-overlapping source anchors without relying on file-private test helpers.
func sourceOccurrenceCount(of needle: String, in source: String) -> Int {
    source.components(separatedBy: needle).count - 1
}

/// Whether every exact source anchor occurs after the previous one.
func sourceContainsInOrder(_ needles: [String], in source: String) -> Bool {
    var searchRange = source.startIndex..<source.endIndex
    for needle in needles {
        guard let range = source.range(of: needle, range: searchRange) else {
            return false
        }
        searchRange = range.upperBound..<source.endIndex
    }
    return true
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
