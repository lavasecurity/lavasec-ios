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
    case catalogAuthorizationFixture = "docs/testing/fixtures/catalog-v1.json"
    case qaMetricKitCollector = "LavaSecApp/QAMetricKitCollector.swift"
    // MARK: Documentation contracts
    case invariants = "docs/invariants.md"
    case dnsTierScaffold = "docs/architecture/dns-tiers.md"
    case dnsPatchRouteDiscovery = "Sources/LavaSecDNS/DNSPatchRouteDiscovery.swift"

    // MARK: React Native production app and fixture host
    case reactNativeReviewProject = "ReactNative/ios/project.json"
    case reactNativeAppFlows = "ReactNative/native-app/LavaAppFlows.swift"
    case reactNativeAppSettings = "ReactNative/native-app/LavaAppSettings.swift"
    case reactNativeAppFilters = "ReactNative/native-app/LavaAppFilters.swift"
    case reactNativeAppReadCache = "ReactNative/app/read-cache.ts"
    case reactNativeAppQueries = "ReactNative/native-app/LavaAppQueries.swift"
    case reactNativeAppGuard = "ReactNative/native-app/LavaAppGuard.swift"
    case reactNativeFilterScreens = "ReactNative/review/FilterScreens.tsx"
    case reactNativeActivityScreen = "ReactNative/review/ActivityScreen.tsx"
    case reactNativeGuardScreen = "ReactNative/review/screens.tsx"
    case reactNativeAppBridge = "ReactNative/native-app/LavaAppBridge.swift"
    case reactNativeActivityDateBridge = "ReactNative/ios/LavaSecUIReview/ActivityDateBridge.swift"
    case reactNativeReviewModule = "ReactNative/ios/LavaSecUIReview/LavaReviewModule.mm"
    case reactNativeReferenceContent = "ReactNative/ios/LavaSecUIReview/ReviewReferenceContent.swift"
    case reactNativeAppHost = "ReactNative/native-app/LavaAppHost.swift"
    case reactNativeSettingsScreens = "ReactNative/review/SettingsScreens.tsx"
    case reactNativeReviewNavigation = "ReactNative/review/LavaUIReview.tsx"

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
    case activityViewController = "LavaSecApp/ActivityViewController.swift"
    // `AppViewModel` is ONE class across these files (stored state in the core file, one
    // `// MARK:` concern per `AppViewModel/` extension). Pins read it through
    // `readAppViewModelSource()` — every file, in class order — never one file alone, which
    // would let an absence pin pass on a fraction of the class.
    case appPlatformServices = "LavaSecApp/LavaAppPlatformServices.swift"
    case protectionUserNotificationController = "LavaSecApp/ProtectionUserNotificationController.swift"
    case protectionHapticFeedback = "LavaSecApp/ProtectionHapticFeedback.swift"
    case appViewModelCore = "LavaSecApp/AppViewModel.swift"
    case appViewModelFilterRulesBudget = "LavaSecApp/AppViewModel/AppViewModel+FilterRulesBudget.swift"
    case appViewModelFilterEditingDrafts = "LavaSecApp/AppViewModel/AppViewModel+FilterEditingDrafts.swift"
    case appViewModelFilterDraftApply = "LavaSecApp/AppViewModel/AppViewModel+FilterDraftApply.swift"
    case appViewModelFilterLibrary = "LavaSecApp/AppViewModel/AppViewModel+FilterLibrary.swift"
    case appViewModelFilterSwitching = "LavaSecApp/AppViewModel/AppViewModel+FilterSwitching.swift"
    case appViewModelShareableFilters = "LavaSecApp/AppViewModel/AppViewModel+ShareableFilters.swift"
    case appViewModelProtectionPause = "LavaSecApp/AppViewModel/AppViewModel+ProtectionPause.swift"
    case appViewModelLiveActivity = "LavaSecApp/AppViewModel/AppViewModel+LiveActivity.swift"
    case appViewModelOnboarding = "LavaSecApp/AppViewModel/AppViewModel+Onboarding.swift"
    case appViewModelResolverSettings = "LavaSecApp/AppViewModel/AppViewModel+ResolverSettings.swift"
    case appViewModelQATooling = "LavaSecApp/AppViewModel/AppViewModel+QATooling.swift"
    case appViewModelChainedDNSFallback = "LavaSecApp/AppViewModel/AppViewModel+ChainedDNSFallback.swift"
    case appViewModelLocalLogExport = "LavaSecApp/AppViewModel/AppViewModel+LocalLogExport.swift"
    case appViewModelReportSurfaces = "LavaSecApp/AppViewModel/AppViewModel+ReportSurfaces.swift"
    case appViewModelDiagnostics = "LavaSecApp/AppViewModel/AppViewModel+Diagnostics.swift"
    case appViewModelCatalogSync = "LavaSecApp/AppViewModel/AppViewModel+CatalogSync.swift"
    case appViewModelWarmArtifacts = "LavaSecApp/AppViewModel/AppViewModel+WarmArtifacts.swift"
    case appViewModelProtectionLifecycle = "LavaSecApp/AppViewModel/AppViewModel+ProtectionLifecycle.swift"
    case appViewModelChainedConnectLifecycle = "LavaSecApp/AppViewModel/AppViewModel+ChainedConnectLifecycle.swift"
    case appViewModelReviewPrompt = "LavaSecApp/AppViewModel/AppViewModel+ReviewPrompt.swift"
    case appViewModelLavaGuardProgress = "LavaSecApp/AppViewModel/AppViewModel+LavaGuardProgress.swift"
    case appViewModelFocusAutoSwitch = "LavaSecApp/AppViewModel/AppViewModel+FocusAutoSwitch.swift"
    case appViewModelPersistence = "LavaSecApp/AppViewModel/AppViewModel+Persistence.swift"
    case appViewModelSudoku = "LavaSecApp/AppViewModel/AppViewModel+Sudoku.swift"
    case appViewModelTunnelHealth = "LavaSecApp/AppViewModel/AppViewModel+TunnelHealth.swift"
    case appViewModelSupport = "LavaSecApp/AppViewModel/AppViewModelSupport.swift"
    case appViewModelHubBridges = "LavaSecApp/AppViewModel/AppViewModel+HubBridges.swift"
    case appBundledLibraryNotices = "LavaSecApp/THIRD-PARTY-NOTICES.txt"
    case backupController = "LavaSecApp/BackupController.swift"
    case backupKeychainStore = "LavaSecApp/BackupKeychainStore.swift"
    case backupPasskeyCoordinator = "LavaSecApp/BackupPasskeyCoordinator.swift"
    case backupRestoreView = "LavaSecApp/BackupRestoreView.swift"
    case backupSetupView = "LavaSecApp/BackupSetupView.swift"
    case backupSyncService = "LavaSecApp/BackupSyncService.swift"
    case blocklistPickerView = "LavaSecApp/BlocklistPickerView.swift"
    case bugReportSettingsView = "LavaSecApp/BugReportSettingsView.swift"
    case filterDraftController = "LavaSecApp/FilterDraftController.swift"
    case filterLibraryController = "LavaSecApp/FilterLibraryController.swift"
    case catalogController = "LavaSecApp/CatalogController.swift"
    case customizationController = "LavaSecApp/CustomizationController.swift"
    case customizationSettingsView = "LavaSecApp/CustomizationSettingsView.swift"
    case darwinNotificationObserver = "LavaSecApp/DarwinNotificationObserver.swift"
    case developerPreviewViews = "LavaSecApp/DeveloperPreviewViews.swift"
    case diagnosticsController = "LavaSecApp/DiagnosticsController.swift"
    case diagnosticsDateControls = "LavaSecApp/DiagnosticsDateControls.swift"
    case diagnosticsLocalLogSupport = "LavaSecApp/DiagnosticsLocalLogSupport.swift"
    case diagnosticsNetworkActivity = "LavaSecApp/DiagnosticsNetworkActivity.swift"
    case dnsResolverSettingsView = "LavaSecApp/DNSResolverSettingsView.swift"
    case filterLibraryView = "LavaSecApp/FilterLibraryView.swift"
    case filterReviewFlowView = "LavaSecApp/FilterReviewFlowView.swift"
    case filterSharedViews = "LavaSecApp/FilterSharedViews.swift"
    case infoPlistStringsCatalog = "LavaSecApp/InfoPlist.xcstrings"
    case lavaComponents = "LavaSecApp/LavaDesignSystem/LavaComponents.swift"
    case lavaCondensedList = "LavaSecApp/LavaDesignSystem/LavaCondensedList.swift"
    case lavaIcon = "LavaSecApp/LavaDesignSystem/LavaIcon.swift"
    case lavaLiveActivityController = "LavaSecApp/LavaLiveActivityController.swift"
    case lavaScaffold = "LavaSecApp/LavaDesignSystem/LavaScaffold.swift"
    case lavaSelectableRow = "LavaSecApp/LavaDesignSystem/LavaSelectableRow.swift"
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
    case sudokuEasterEggView = "LavaSecApp/SudokuEasterEggView.swift"
    // Deliberately NOT a member of `readSettingsSourceAggregate()` — like `adminQAView`, this
    // page is compile-gated in full, and folding it into the aggregate would make the
    // production tier/subpage contracts read gated source as if it shipped.
    case vpnChainingSettingsView = "LavaSecApp/VPNChainingSettingsView.swift"
    case shareableFilterCard = "LavaSecApp/ShareableFilterCard.swift"
    case shareableFilterImageDecoder = "LavaSecApp/ShareableFilterImageDecoder.swift"
    case shareableFiltersUI = "LavaSecApp/ShareableFiltersUI.swift"
    // App-target (App Shortcuts register from the app bundle, not the extension).
    case protectionShortcuts = "LavaSecApp/ProtectionShortcuts.swift"
    case switchFilterShortcut = "LavaSecApp/SwitchFilterShortcut.swift"
    case temporaryProtectionPauseController = "LavaSecApp/TemporaryProtectionPauseController.swift"
    case upgradeSettingsView = "LavaSecApp/UpgradeSettingsView.swift"

    // MARK: LavaSecTunnel
    // `PacketTunnelProvider` is ONE class across these files (stored state in the core file,
    // one `// MARK:` concern per `Provider/` extension). Pins read it through
    // `readPacketTunnelProviderSource()` — every file, in class order — never one file alone,
    // which would let an absence pin pass on a fraction of the class.
    case packetTunnelProviderCore = "LavaSecTunnel/PacketTunnelProvider.swift"
    case packetTunnelProviderLifecycle = "LavaSecTunnel/Provider/PacketTunnelProvider+Lifecycle.swift"
    case packetTunnelProviderAppMessaging = "LavaSecTunnel/Provider/PacketTunnelProvider+AppMessaging.swift"
    case packetTunnelProviderPacketLoop = "LavaSecTunnel/Provider/PacketTunnelProvider+PacketLoop.swift"
    case packetTunnelProviderUpstreamForwarding = "LavaSecTunnel/Provider/PacketTunnelProvider+UpstreamForwarding.swift"
    case packetTunnelProviderResolverTransports = "LavaSecTunnel/Provider/PacketTunnelProvider+ResolverTransports.swift"
    case packetTunnelProviderEncryptedBootstrap = "LavaSecTunnel/Provider/PacketTunnelProvider+EncryptedBootstrap.swift"
    case packetTunnelProviderBootstrapBroker = "LavaSecTunnel/Provider/PacketTunnelProvider+BootstrapBroker.swift"
    case packetTunnelProviderFocusConfigPoll = "LavaSecTunnel/Provider/PacketTunnelProvider+FocusConfigPoll.swift"
    case packetTunnelProviderRecoveryProbes = "LavaSecTunnel/Provider/PacketTunnelProvider+RecoveryProbes.swift"
    case packetTunnelProviderDeviceDNSCapture = "LavaSecTunnel/Provider/PacketTunnelProvider+DeviceDNSCapture.swift"
    case packetTunnelProviderSmokeProbes = "LavaSecTunnel/Provider/PacketTunnelProvider+SmokeProbes.swift"
    case packetTunnelProviderNetworkPath = "LavaSecTunnel/Provider/PacketTunnelProvider+NetworkPath.swift"
    case packetTunnelProviderStartupState = "LavaSecTunnel/Provider/PacketTunnelProvider+StartupState.swift"
    case packetTunnelProviderBootRecovery = "LavaSecTunnel/Provider/PacketTunnelProvider+BootRecovery.swift"
    case packetTunnelProviderTransientBootstrapWait = "LavaSecTunnel/Provider/PacketTunnelProvider+TransientBootstrapWait.swift"
    case packetTunnelProviderDiagnostics = "LavaSecTunnel/Provider/PacketTunnelProvider+Diagnostics.swift"
    case packetTunnelProviderNotifications = "LavaSecTunnel/Provider/PacketTunnelProvider+Notifications.swift"
    case packetTunnelProviderSelfReconnect = "LavaSecTunnel/Provider/PacketTunnelProvider+SelfReconnect.swift"
    case packetTunnelProviderConfiguration = "LavaSecTunnel/Provider/PacketTunnelProvider+Configuration.swift"
    case packetTunnelProviderSnapshotReload = "LavaSecTunnel/Provider/PacketTunnelProvider+SnapshotReload.swift"
    case packetTunnelProviderProtectionPause = "LavaSecTunnel/Provider/PacketTunnelProvider+ProtectionPause.swift"
    case packetTunnelProviderResidentSnapshot = "LavaSecTunnel/Provider/PacketTunnelProvider+ResidentSnapshot.swift"
    case packetTunnelProviderFilterDecision = "LavaSecTunnel/Provider/PacketTunnelProvider+FilterDecision.swift"
    case packetTunnelProviderSnapshotCompile = "LavaSecTunnel/Provider/PacketTunnelProvider+SnapshotCompile.swift"
    case packetTunnelProviderChainedDataPath = "LavaSecTunnel/Provider/PacketTunnelProvider+ChainedDataPath.swift"
    case chainedTunnelRuntime = "LavaSecTunnel/Provider/ChainedTunnelRuntime.swift"
    case packetTunnelProviderChainedSeamHost = "LavaSecTunnel/Provider/PacketTunnelProvider+ChainedSeamHost.swift"
    case tunnelProviderSupportTypes = "LavaSecTunnel/Provider/TunnelProviderSupportTypes.swift"
    case tunnelEntitlements = "LavaSecTunnel/LavaSecTunnel.entitlements"
    case tunnelInfoPlist = "LavaSecTunnel/Info.plist"

    // MARK: LavaSecWidget
    case lavaSecWidget = "LavaSecWidget/LavaSecWidget.swift"
    case widgetEntitlements = "LavaSecWidget/LavaSecWidget.entitlements"

    // MARK: LavaSecIntents
    case focusFilterIntent = "LavaSecIntents/FocusFilterIntent.swift"
    case intentsEntitlements = "LavaSecIntents/LavaSecIntents.entitlements"
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
    case dnsHealthAuthority = "Sources/LavaSecKit/DNSHealthAuthority.swift"
    case chainedResolverEgress = "Sources/LavaSecChainedUpstream/ChainedResolverEgress.swift"
    case chainedConnectLifecyclePolicy = "Sources/LavaSecKit/ChainedConnectLifecyclePolicy.swift"
    case chainedHandshakeStatus = "Sources/LavaSecKit/ChainedHandshakeStatus.swift"
    case wireGuardCoreABIBindings = "Sources/LavaSecChainedUpstream/WireGuardEngineABI.swift"
    case appConfiguration = "Sources/LavaSecKit/AppConfiguration.swift"
    case sudokuGameState = "Sources/LavaSecKit/SudokuGameState.swift"
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
    case chainedTransportDiagnosticsRecorder = "Sources/LavaSecChainedUpstream/ChainedTransportDiagnosticsRecorder.swift"
    // Registered for ONE assertion that cannot be behavioural: the borrowed-packet overload's
    // one-copy strategy leaves state byte-for-byte identical to the two-copy path, so no return
    // value or counter can tell them apart (sweep, PR #623).
    case chainedPacketQueue = "Sources/LavaSecChainedUpstream/ChainedPacketQueue.swift"
    case compactFilterSnapshot = "Sources/LavaSecFilterPipeline/CompactFilterSnapshot.swift"
    case customBlocklistSource = "Sources/LavaSecKit/CustomBlocklistSource.swift"
    case deviceLogObservationOrder = "Sources/LavaSecKit/DeviceLogObservationOrder.swift"
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
    case protectionLifecycleMutationFence = "Sources/LavaSecKit/ProtectionLifecycleMutationFence.swift"
    case protectionRestoreIntentStore = "Sources/LavaSecKit/ProtectionRestoreIntentStore.swift"
    case protectionStoreSupport = "Sources/LavaSecKit/ProtectionStoreSupport.swift"
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

    // MARK: Vendored WireGuard engine (outside every Swift target)
    // The ABI header is bound by @_silgen_name; the manifest, lock, upstream source header,
    // and license text are the provenance and attribution record pinned by the engine tests.
    case wireGuardCoreHeader = "ThirdParty/wireguard-core/include/lavasec_wireguard_core.h"
    case wireGuardCoreVendoredManifest = "ThirdParty/wireguard-core/boringtun/Cargo.toml"
    case wireGuardCoreLock = "ThirdParty/wireguard-core/Cargo.lock"
    case wireGuardCoreNoticesIndex = "ThirdParty/wireguard-core/third-party-notices-index.json"
    case wireGuardCoreNotices = "ThirdParty/wireguard-core/THIRD-PARTY-NOTICES.txt"
    case buildWireGuardCoreScript = "scripts/build-wireguard-core.sh"
    case generateWireGuardCoreNoticesScript = "scripts/generate-wireguard-core-notices.mjs"
    case wireGuardCoreFFI = "ThirdParty/wireguard-core/src/lib.rs"
    case wireGuardCoreVendoredLib = "ThirdParty/wireguard-core/boringtun/src/lib.rs"
    case wireGuardCoreVendoredNoise = "ThirdParty/wireguard-core/boringtun/src/noise/mod.rs"
    case wireGuardCoreVendoredTimers = "ThirdParty/wireguard-core/boringtun/src/noise/timers.rs"
    case wireGuardCoreVendoredClock =
        "ThirdParty/wireguard-core/boringtun/src/sleepyinstant/unix.rs"
    case boringTunLicenseText = "ThirdParty/wireguard-core/LICENSE-boringtun.txt"

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

extension SourceFile {
    /// Every file of the `PacketTunnelProvider` class, in class order: the core file (stored
    /// state) first, then each `Provider/` extension in the order its `// MARK:` section had in
    /// the former single file, then the file-scope support types. Order matters: cross-concern
    /// pins anchor a block's start in one section and its end in the next.
    /// pinned: SourceFileRegistryTests.testEveryTunnelProviderFileOnDiskIsInTheAggregate
    /// pinned: SourceFileRegistryTests.testTheAggregateKeepsTheClassInSectionOrder
    static let packetTunnelProviderSources: [SourceFile] = [
        .packetTunnelProviderCore,
        .packetTunnelProviderLifecycle,
        .packetTunnelProviderAppMessaging,
        .packetTunnelProviderPacketLoop,
        .packetTunnelProviderUpstreamForwarding,
        .packetTunnelProviderResolverTransports,
        .packetTunnelProviderEncryptedBootstrap,
        .packetTunnelProviderBootstrapBroker,
        .packetTunnelProviderFocusConfigPoll,
        .packetTunnelProviderRecoveryProbes,
        .packetTunnelProviderDeviceDNSCapture,
        .packetTunnelProviderSmokeProbes,
        .packetTunnelProviderNetworkPath,
        .packetTunnelProviderStartupState,
        .packetTunnelProviderBootRecovery,
        .packetTunnelProviderTransientBootstrapWait,
        .packetTunnelProviderDiagnostics,
        .packetTunnelProviderNotifications,
        .packetTunnelProviderSelfReconnect,
        .packetTunnelProviderConfiguration,
        .packetTunnelProviderSnapshotReload,
        .packetTunnelProviderProtectionPause,
        .packetTunnelProviderResidentSnapshot,
        .packetTunnelProviderFilterDecision,
        .packetTunnelProviderSnapshotCompile,
        .packetTunnelProviderChainedDataPath,
        .chainedTunnelRuntime,
        .packetTunnelProviderChainedSeamHost,
        .tunnelProviderSupportTypes,
    ]
}

/// The whole `PacketTunnelProvider` class as one text, for pins whose anchors span concerns
/// and for pins that assert a construct is ABSENT from the provider — an absence pin has to
/// scan every file of the class or it proves nothing.
func readPacketTunnelProviderSource() throws -> String {
    try SourceFile.packetTunnelProviderSources.map(readSource).joined(separator: "\n")
}

extension SourceFile {
    /// Every file of the `AppViewModel` class, in class order: the core file (stored state)
    /// first, then concern extensions, file-scope support types, and hub-bridge conformances.
    /// Order matters: cross-concern pins anchor a block's start in one section and its end in
    /// the next.
    /// pinned: SourceFileRegistryTests.testEveryAppViewModelFileOnDiskIsInTheAggregate
    static let appViewModelSources: [SourceFile] = [
        .appViewModelCore,
        .appViewModelFilterRulesBudget,
        .appViewModelFilterEditingDrafts,
        .appViewModelFilterDraftApply,
        .appViewModelFilterLibrary,
        .appViewModelFilterSwitching,
        .appViewModelShareableFilters,
        .appViewModelProtectionPause,
        .appViewModelLiveActivity,
        .appViewModelOnboarding,
        .appViewModelResolverSettings,
        .appViewModelQATooling,
        .appViewModelChainedDNSFallback,
        .appViewModelLocalLogExport,
        .appViewModelReportSurfaces,
        .appViewModelDiagnostics,
        .appViewModelCatalogSync,
        .appViewModelWarmArtifacts,
        .appViewModelProtectionLifecycle,
        .appViewModelChainedConnectLifecycle,
        .appViewModelReviewPrompt,
        .appViewModelLavaGuardProgress,
        .appViewModelFocusAutoSwitch,
        .appViewModelPersistence,
        .appViewModelSudoku,
        .appViewModelTunnelHealth,
        .appViewModelSupport,
        .appViewModelHubBridges,
    ]
}

/// The whole `AppViewModel` class as one text, for pins whose anchors span concerns and for
/// pins that assert a construct is ABSENT from the view model — an absence pin has to scan
/// every file of the class or it proves nothing.
func readAppViewModelSource() throws -> String {
    try SourceFile.appViewModelSources.map(readSource).joined(separator: "\n")
}

/// Reassembles the Filters feature sources for contracts that intentionally span the
/// shell and multiple extracted domains. Declaration-specific tests should read the
/// owning source directly so a move cannot silently weaken their boundary.
func readFiltersSourceAggregate() throws -> String {
    try [
        readSource(.reactNativeFilterScreens),
        readSource(.filterLibraryView),
        readSource(.reactNativeAppFilters),
        readSource(.filterSharedViews),
        readSource(.reactNativeAppFlows),
        readSource(.blocklistPickerView),
    ].joined(separator: "\n")
}

/// Reassembles the Diagnostics feature sources for contracts that intentionally span
/// the overview shell and multiple extracted local-log domains.
func readDiagnosticsSourceAggregate() throws -> String {
    try [
        readSource(.reactNativeActivityScreen),
        readSource(.diagnosticsDateControls),
        readSource(.diagnosticsLocalLogSupport),
        readSource(.diagnosticsNetworkActivity),
        readSource(.reactNativeAppQueries),
        readSource(.reactNativeAppQueries),
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

/// The same source with `//` comment lines removed, for pins that assert a construct is ABSENT.
///
/// A bare `contains` over raw source cannot tell a call from prose about a call. This codebase's
/// comment culture makes that collide constantly: a `XCTAssertFalse(block.contains("syncCatalog"))`
/// pin — meaning "this path performs no sync" — went red on a comment that explained *why* the path
/// performs no sync, by naming `syncCatalogIfStale()` (PR #646). The pin was right, the code was
/// right, and the comment was the thing that broke it, which is the wrong lesson to hand the next
/// person: the fix is not to write vaguer comments.
///
/// Only whole-line `//` comments are stripped — not trailing comments or `/* */` — because that is
/// enough for the absent-construct case and the naive block-comment handling that would cover the
/// rest is a worse trade than a pin occasionally reading a trailing comment.
func sourceWithoutCommentLines(_ source: String) -> String {
    source
        .split(separator: "\n", omittingEmptySubsequences: false)
        .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        .joined(separator: "\n")
}

/// Counts exact, non-overlapping source anchors without relying on file-private test helpers.
func sourceOccurrenceCount(of needle: String, in source: String) -> Int {
    source.components(separatedBy: needle).count - 1
}

/// `source` with whole-line comments removed, for pins that forbid a construct.
///
/// This codebase deliberately names the thing a comment forbids ("deliberately not
/// `UIImage(data:)`"), so an `XCTAssertFalse(source.contains(...))` pin will match
/// the very rationale explaining the ban and fail on correct code. Stripping the
/// prose lets such a pin mean what it says.
///
/// Only lines whose first non-whitespace characters are `//` are dropped — that is
/// where this codebase puts rationale. Trailing comments are deliberately left in
/// place: `//` also appears inside string literals such as `https://…`, and cutting
/// at the first occurrence would corrupt real code. A pin that must ignore a
/// trailing comment should anchor on something narrower instead.
func sourceExcludingComments(_ source: String) -> String {
    source
        .components(separatedBy: .newlines)
        .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        .joined(separator: "\n")
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

/// `source` with every comment and string literal blanked to spaces, newlines kept.
///
/// 🔴 The reason this exists rather than a cleverer regex. Matching declarations on raw text cuts
/// both ways: it misses nothing, and it reports everything — including
/// `"extension PacketTunnelProvider"` written inside a rationale comment, which this codebase does
/// routinely (Codex, PR #651). Four rounds of widening the pattern chased false NEGATIVES; the
/// widened pattern then had a false POSITIVE problem, and no single regex settles both.
///
/// Blanking first settles both at once. What is left is code, so trivia between tokens is plain
/// whitespace again and the matchers get simpler rather than more clever.
///
/// Handles what Swift actually has: NESTED block comments (`/* /* */ */` is one comment, and a
/// non-nesting scanner stops at the first `*/` and leaves a stray `*/` behind — Kilo, PR #651),
/// line comments, multi-line string literals, escapes, and raw strings of any hash depth, whose
/// escape is `\#` and whose terminator carries the same hashes.
///
/// Lengths are preserved so byte offsets still line up with the original.
func sourceOutsideCommentsAndStrings(_ source: String) -> String {
    // 🔴 Over UTF-8 BYTES, blanking in place. The first version walked `[Character]` and appended to
    // a new String, which is correct and far too slow: grapheme breaking made the AppViewModel
    // whole-tree scan (2.2 MB across 102 files) take over four minutes, against ~53 s before. Every
    // delimiter this needs — `/ * " # \ ( )` and newline — is ASCII, and a UTF-8 continuation byte
    // can never be mistaken for one, so bytes are safe here as well as fast.
    //
    // 🔴 A STACK, not a special case per construct. Swift nests these: a string may contain an
    // interpolation, which is code, which may contain another string, which may interpolate again.
    // Two earlier drafts tried to shortcut it — one blanked `\(` as a plain escape, the other
    // skipped to a matching `)` while counting parens blind to nested literals, so `"\(")")"` ended
    // the literal at the wrong quote (Kilo and Codex, PR #651). Once a literal ends early the REAL
    // code after it reads as a string, which is how a genuine extension becomes invisible.
    //
    // Interpolated expressions are kept as CODE, deliberately: they execute, so a mutating call
    // inside one is a real write the AppViewModel predicate has to see (Codex, PR #652).
    var bytes = Array(source.utf8)
    let count = bytes.count
    let slash = UInt8(ascii: "/"), star = UInt8(ascii: "*"), quote = UInt8(ascii: "\"")
    let hash = UInt8(ascii: "#"), backslash = UInt8(ascii: "\\")
    let newline = UInt8(ascii: "\n"), space = UInt8(ascii: " ")
    // Canonicalize Swift's CR / CRLF line endings without moving any byte offsets. All comment,
    // literal and statement-boundary paths then share the same newline rule and line numbering.
    for offset in bytes.indices where bytes[offset] == UInt8(ascii: "\r") {
        bytes[offset] = offset + 1 < count && bytes[offset + 1] == newline ? space : newline
    }
    let openParen = UInt8(ascii: "("), closeParen = UInt8(ascii: ")")
    var index = 0
    var previousTokenEndsExpression = false
    var previousTokenEnd = 0
    var previousTokenIsOperator = false
    let identifierScalar = try! NSRegularExpression(pattern: "^" + sourceIdentifierCharacter + "$")
    let operatorScalar = try! NSRegularExpression(pattern: "^" + sourceOperatorCharacter + "$")

    /// A string literal being scanned, and how deep its interpolation runs.
    struct Literal {
        let hashes: Int
        let delimiter: Int
        /// Open parens of the interpolation being scanned; nil while inside the literal's text.
        var interpolationDepth: Int?
    }
    var literals: [Literal] = []

    func byte(_ offset: Int) -> UInt8 {
        let target = index + offset
        return target < count ? bytes[target] : 0
    }
    /// Blank `length` bytes, keeping newlines so line numbers survive.
    func blank(_ length: Int) {
        let step = max(1, min(length, count - index))
        for offset in 0..<step where bytes[index + offset] != newline { bytes[index + offset] = space }
        index += step
    }
    /// Whether a string literal opens here; if so, its hash depth and quote-run length.
    func literalOpening() -> (hashes: Int, delimiter: Int)? {
        var hashes = 0
        while byte(hashes) == hash { hashes += 1 }
        guard byte(hashes) == quote else { return nil }
        let multiline = byte(hashes + 1) == quote && byte(hashes + 2) == quote
        return (hashes, multiline ? 3 : 1)
    }

    while index < count {
        // Inside a literal's TEXT: blank until an interpolation opens or the literal terminates.
        if let literal = literals.last, literal.interpolationDepth == nil {
            // `\(` opens an interpolation; a raw literal spells it `\#(` at its own hash depth, and
            // a shorter hash run is ordinary content rather than an escape (Codex, PR #651).
            if bytes[index] == backslash {
                var following = 0
                while following < literal.hashes, byte(1 + following) == hash { following += 1 }
                if following == literal.hashes {
                    if byte(1 + literal.hashes) == openParen {
                        blank(2 + literal.hashes)
                        literals[literals.count - 1].interpolationDepth = 0
                        previousTokenEndsExpression = false
                        continue
                    }
                    blank(2 + literal.hashes) // an ordinary escape consumes what follows
                    continue
                }
            }
            if bytes[index] == quote {
                var quotes = 0
                while quotes < literal.delimiter, byte(quotes) == quote { quotes += 1 }
                if quotes == literal.delimiter {
                    var closing = 0
                    while closing < literal.hashes, byte(literal.delimiter + closing) == hash {
                        closing += 1
                    }
                    if closing == literal.hashes {
                        blank(literal.delimiter + literal.hashes)
                        literals.removeLast()
                        previousTokenEndsExpression = true
                        previousTokenEnd = index
                        continue
                    }
                }
            }
            blank(1)
            continue
        }

        // Code — the top level, or an interpolated expression. Block comments NEST: `/* /* */ */`
        // is one comment, and stopping at the first `*/` leaves a stray `*/` as apparent code.
        if bytes[index] == slash, byte(1) == star {
            var depth = 0
            while index < count {
                if bytes[index] == slash, byte(1) == star { depth += 1; blank(2); continue }
                if bytes[index] == star, byte(1) == slash {
                    depth -= 1
                    blank(2)
                    if depth == 0 { break }
                    continue
                }
                if bytes[index] == newline {
                    previousTokenEndsExpression = false
                    previousTokenIsOperator = false
                }
                blank(1)
            }
            continue
        }
        if bytes[index] == slash, byte(1) == slash {
            while index < count, bytes[index] != newline { blank(1) }
            continue
        }
        // Swift REGEX LITERALS. `/extension PacketTunnelProvider/` is a valid literal whose payload
        // is not code, and leaving it as code makes the scan report an extension that does not
        // exist — a build-blocking false positive (Codex, PR #651).
        //
        // Bare `/…/` is ambiguous with division. A preceding expression-ending token rules out
        // a literal (`4/2`, `value/2`, `value[0]/2`); a literal's contents may not begin or end with
        // whitespace. `a / b` is arithmetic because the content would start with a space; `w/2 //
        // note` is arithmetic because the candidate's content would END with one.
        //
        // Two earlier attempts got this wrong in opposite directions. Requiring only that the
        // content not begin with a space let `w/2 // note` close on the comment's first slash,
        // erasing `2 /` and leaving the comment text standing as CODE. Bailing whenever the
        // scanned `/` was followed by `/` or `*` then discarded a REAL literal whose terminator
        // abuts a comment (Kilo, PR #651). The end-whitespace rule handles both without a special
        // case: the comment's slash is preceded by a space, so it is not a terminator and the
        // candidate simply fails.
        // Keep token context separately from the blanked bytes: a closing string literal and
        // a value followed by a comment still end an expression after their text becomes spaces.
        if bytes[index] == slash, !previousTokenEndsExpression,
           byte(1) != space, byte(1) != UInt8(ascii: "\t"), byte(1) != newline, byte(1) != slash,
           byte(1) != star, byte(1) != 0 {
            var lookahead = 1
            var closes = false
            var previousWasEscapedWhitespace = false
            while index + lookahead < count, bytes[index + lookahead] != newline {
                if bytes[index + lookahead] == backslash {
                    previousWasEscapedWhitespace = index + lookahead + 1 < count
                        && [space, UInt8(ascii: "\t")].contains(bytes[index + lookahead + 1])
                    lookahead += 2
                    continue
                }
                if bytes[index + lookahead] == slash {
                    let previous = bytes[index + lookahead - 1]
                    if (previous == space || previous == UInt8(ascii: "\t")),
                       !previousWasEscapedWhitespace { break }
                    closes = true
                    break
                }
                previousWasEscapedWhitespace = false
                lookahead += 1
            }
            if closes {
                blank(lookahead + 1)
                previousTokenEndsExpression = true
                previousTokenEnd = index
                continue
            }
        }
        // Extended regex literals `#/…/#`, which may span lines and need no ambiguity rule.
        var regexHashes = 0
        while byte(regexHashes) == hash { regexHashes += 1 }
        if regexHashes > 0, byte(regexHashes) == slash {
            blank(regexHashes + 1)
            while index < count {
                // An escape consumes what follows, so `\/#` is regex CONTENT rather than the
                // terminator (Codex, PR #651).
                if bytes[index] == backslash { blank(2); continue }
                if bytes[index] == slash {
                    var closing = 0
                    while closing < regexHashes, byte(1 + closing) == hash { closing += 1 }
                    if closing == regexHashes { blank(1 + regexHashes); break }
                }
                blank(1)
            }
            previousTokenEndsExpression = true
            previousTokenEnd = index
            continue
        }
        if let opening = literalOpening() {
            blank(opening.hashes + opening.delimiter)
            literals.append(
                Literal(hashes: opening.hashes, delimiter: opening.delimiter, interpolationDepth: nil))
            continue
        }
        // Track the interpolation's parens so its closing one returns us to the literal's text.
        if var depth = literals.last?.interpolationDepth {
            if bytes[index] == openParen { depth += 1 }
            if bytes[index] == closeParen {
                if depth == 0 {
                    blank(1)
                    literals[literals.count - 1].interpolationDepth = nil
                    continue
                }
                depth -= 1
            }
            literals[literals.count - 1].interpolationDepth = depth
        }
        // Only expression context is needed, not a parser: identifiers/numbers and closing
        // delimiters finish operands; assignment/argument delimiters begin them. A postfix !/ ?
        // keeps its operand's context, including `try!` whose operand has not started yet.
        func scalarByteCount(at offset: Int) -> Int {
            let value = bytes[offset]
            return value < 0x80 ? 1 : value < 0xE0 ? 2 : value < 0xF0 ? 3 : 4
        }
        func wordByteCount(at offset: Int) -> Int {
            let value = bytes[offset]
            if value < 0x80 {
                return (48...57).contains(value) || (65...90).contains(value)
                    || (97...122).contains(value) || value == UInt8(ascii: "_")
                    || value == UInt8(ascii: "`") ? 1 : 0
            }
            let length = scalarByteCount(at: offset)
            guard offset + length <= count else { return 0 }
            let scalar = String(decoding: bytes[offset..<(offset + length)], as: UTF8.self)
            let range = NSRange(scalar.startIndex..., in: scalar)
            // Combining marks may continue either identifiers or operators; retain their token.
            if previousTokenIsOperator, previousTokenEnd == offset,
               operatorScalar.firstMatch(in: scalar, range: range) != nil { return 0 }
            return identifierScalar.firstMatch(in: scalar, range: range) != nil ? length : 0
        }
        if wordByteCount(at: index) > 0 {
            let start = index
            repeat { index += wordByteCount(at: index) } while index < count && wordByteCount(at: index) > 0
            let token = String(decoding: bytes[start..<index], as: UTF8.self)
            let followsMemberDot = previousTokenEnd > 0 && bytes[previousTokenEnd - 1] == UInt8(ascii: ".")
            let isUnspacedYieldOperand = token == "yield" && byte(0) == slash
            previousTokenEndsExpression = followsMemberDot || isUnspacedYieldOperand
                || !["return", "throw", "try", "await", "case", "yield", "in",
                     "switch", "if", "guard", "while", "for", "where", "catch"].contains(token)
            previousTokenEnd = index
            previousTokenIsOperator = false
            continue
        }
        if bytes[index] >= 0x80 {
            // A non-identifier scalar is an operator here, never an expression-ending word.
            index += scalarByteCount(at: index)
            previousTokenEndsExpression = false
            previousTokenIsOperator = true
            previousTokenEnd = index
            continue
        }
        switch bytes[index] {
        case closeParen, UInt8(ascii: "]"), UInt8(ascii: "}"):
            previousTokenEndsExpression = true
        case UInt8(ascii: "!"):
            // Force unwraps may chain for nested optionals: value!! still ends an expression.
            previousTokenEndsExpression = previousTokenEndsExpression && previousTokenEnd == index
        case UInt8(ascii: "?"):
            // An adjacent postfix ? preserves an operand. Spaced ternary ? and ?? start a new
            // operand, which may itself be a regex literal.
            previousTokenEndsExpression = previousTokenEndsExpression
                && previousTokenEnd == index && byte(1) != bytes[index]
        case newline:
            // A prefix-position slash can start a new statement. A continued binary division
            // still has trailing operator whitespace, which the regex opener rejects above.
            previousTokenEndsExpression = false
            previousTokenIsOperator = false
        case space, UInt8(ascii: "\t"), UInt8(ascii: "\r"):
            break
        default:
            previousTokenEndsExpression = false
        }
        if ![space, newline, UInt8(ascii: "\t"), UInt8(ascii: "\r")].contains(bytes[index]) {
            previousTokenEnd = index + 1
            previousTokenIsOperator = Array("=+-*/%<>&|^~.!?".utf8).contains(bytes[index])
        }
        index += 1
    }
    return String(decoding: bytes, as: UTF8.self)
}

/// Swift operator scalars, shared by token context and the AppViewModel operator boundary.
let sourceOperatorCharacter = #"[-=+*/%<>&|^~.!?\u00A1-\u00A7\u00A9\u00AB\u00AC\u00AE\u00B0-\u00B1\u00B6\u00BB\u00BF\u00D7\u00F7\u2016-\u2017\u2020-\u2027\u2030-\u203E\u2041-\u2053\u2055-\u205E\u2190-\u23FF\u2500-\u2775\u2794-\u2BFF\u2E00-\u2E7F\u3001-\u3003\u3008-\u3020\u3030\u0300-\u036F\u1DC0-\u1DFF\u20D0-\u20FF\uFE00-\uFE0F\uFE20-\uFE2F\x{E0100}-\x{E01EF}]"#

/// Swift's identifier ranges, including symbols and supplementary-plane scalars. Unicode
/// categories alone miss legal aliases or consume operators such as `=` and `<` as identifiers.
/// https://docs.swift.org/swift-book/ReferenceManual/LexicalStructure.html#Identifiers
let sourceIdentifierHead = #"[A-Za-z_\x{00A8}\x{00AA}\x{00AD}\x{00AF}\x{00B2}-\x{00B5}\x{00B7}-\x{00BA}"#
    + #"\x{00BC}-\x{00BE}\x{00C0}-\x{00D6}\x{00D8}-\x{00F6}\x{00F8}-\x{02FF}\x{0370}-\x{167F}"#
    + #"\x{1681}-\x{180D}\x{180F}-\x{1DBF}\x{1E00}-\x{1FFF}\x{200B}-\x{200D}\x{202A}-\x{202E}"#
    + #"\x{203F}-\x{2040}\x{2054}\x{2060}-\x{20CF}\x{2100}-\x{218F}\x{2460}-\x{24FF}"#
    + #"\x{2776}-\x{2793}\x{2C00}-\x{2DFF}\x{2E80}-\x{2FFF}\x{3004}-\x{3007}\x{3021}-\x{302F}"#
    + #"\x{3031}-\x{D7FF}\x{F900}-\x{FD3D}\x{FD40}-\x{FDCF}\x{FDF0}-\x{FE1F}\x{FE30}-\x{FE44}"#
    + #"\x{FE47}-\x{FFFD}"#
    + (1...14).map { #"\x{"# + String($0 * 0x10000, radix: 16) + #"}-\x{"#
        + String($0 * 0x10000 + 0xFFFD, radix: 16) + "}" }.joined() + "]"
let sourceIdentifierCharacter = "(?:" + sourceIdentifierHead
    + #"|[0-9\x{0300}-\x{036F}\x{1DC0}-\x{1DFF}\x{20D0}-\x{20FF}\x{FE20}-\x{FE2F}])"#

/// The name an extension in `source` extends the class under, given the module-wide alias set
/// `names`, or nil if it declares none.
///
/// Runs on code only, so trivia between `extension` and the name — a comment on either side, a
/// newline, several spaces — is just whitespace by the time this looks.
///
/// The lookahead excludes `.` as well as identifier characters: `extension PacketTunnelProvider.Nested`
/// extends the NESTED TYPE and adds nothing to the class, which is the same rule the alias
/// resolution already applies to `typealias Inner = X.Something` (Kilo, PR #651).
func extensionNameExtending(_ names: Set<String>, in source: String) -> String? {
    let code = sourceOutsideCommentsAndStrings(source)
    for name in names.sorted() {
        // Backticks are an IDENTIFIER ESCAPE, so ``extension `PacketTunnelProvider` {}`` declares
        // the same extension (Codex, PR #651). The closing one is optional in the pattern rather
        // than paired with the opening one: an unbalanced spelling is not valid Swift, so the
        // looser form costs nothing and keeps the lookahead readable.
        // Qualifying components may precede the name: `enum Namespace { typealias Hidden = … }`
        // makes `extension Namespace.Hidden` a valid extension of the class (Codex, PR #651). The
        // name must be the LAST component, which is the same rule the alias resolution applies —
        // `extension PacketTunnelProvider.Nested` extends the nested type, not the class.
        let qualifier = #"(?:`?"# + sourceIdentifierHead + sourceIdentifierCharacter + #"*`?\s*\.\s*)*"#
        let pattern = #"\bextension\s+"# + qualifier + #"`?"#
            + NSRegularExpression.escapedPattern(for: name)
            + #"`?(?!"# + sourceIdentifierCharacter + #"|\.)"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
        let range = NSRange(code.startIndex..., in: code)
        if !expression.matches(in: code, range: range).isEmpty { return name }
    }
    return nil
}

/// Every name that `extension <name>` would extend `className` under, across `sources` taken
/// TOGETHER: the class itself plus every `typealias` that reaches it, however many hops.
///
/// 🔴 Across the whole set, not file by file. A `typealias` is MODULE-scoped, so `A.swift` can
/// declare `typealias Hidden = PacketTunnelProvider` while `B.swift` declares `extension Hidden`,
/// and analysing B alone never sees the binding (Codex, PR #651). Every compiled source of the
/// target contributes aliases; each file is then checked against the union.
///
/// Deliberately conservative about scope: aliases of these two protected classes must have
/// unambiguous names across the target. A nested alias sharing an unrelated type's leaf name
/// also flags that type's extension. Rename the alias or extend the concrete class directly;
/// reproducing Swift's type lookup here would make this maintenance guard a second compiler.
/// The corpus pins this restriction so a future change cannot silently narrow it (PR #659).
///
/// Resolved to a FIXED POINT, so a chain (`Deeper = Hidden = Provider = the class`) is followed to
/// the end rather than one hop. Alias targets are compared by `resolves(_:in:)`, which accepts a
/// MODULE QUALIFIER (`LavaSecTunnel.PacketTunnelProvider`) and rejects a nested type
/// (`PacketTunnelProvider.Something`, whose leaf is not a known name). An earlier version of this
/// sentence said targets were matched EXACTLY, which qualifier support falsified (Kilo, PR #651).
func classNamesExtending(_ className: String, inAnyOf sources: [String]) -> Set<String> {
    // Backticks are an identifier escape here as well as on `extension` — ``typealias `Hidden` =
    // `PacketTunnelProvider` `` is the same declaration (Codex, PR #651). They are stripped from
    // the captures below so the names compare equal to their unescaped spellings.
    let identifier = #"`?"# + sourceIdentifierHead + sourceIdentifierCharacter + #"*`?"#
    // `typealias Hidden = (PacketTunnelProvider)` is valid, and parentheses around a target are
    // meaningless to the type — requiring an identifier straight after `=` recorded no alias at all
    // (Codex, PR #651).
    let declaration = #"\btypealias\s+("# + identifier + #")"#
    let targetPattern = #"^\s*=\s*\(*\s*("# + identifier
        + #"(?:\s*\.\s*"# + identifier + #")*)"#
    // 🔴 A SET of targets per alias, not one. Conditional compilation gives the same module-scoped
    // name different targets in different branches — `#if DEBUG` mapping `Hidden` to the class and
    // `#else` mapping it elsewhere — and a dictionary keeps only whichever the scan saw last, so
    // the class-bound branch could be silently dropped (Codex, PR #651). Every branch is scanned
    // because `#if` is not evaluated, so every target must be kept.
    var aliases: [String: Set<String>] = [:]
    guard let expression = try? NSRegularExpression(pattern: declaration),
          let targetExpression = try? NSRegularExpression(pattern: targetPattern) else { return [className] }
    for source in sources {
        let code = sourceOutsideCommentsAndStrings(source)
        let range = NSRange(code.startIndex..., in: code)
        for match in expression.matches(in: code, range: range) {
            guard let alias = Range(match.range(at: 1), in: code) else { continue }
            var remainder = code[alias.upperBound...].drop(while: { $0.isWhitespace })
            // Generic clauses can nest and span lines. Count balanced delimiters instead of
            // growing a regex per nesting depth; an arrow's `>` is part of a function type.
            if remainder.first == "<" {
                var depth = 0
                var previous: Character?
                var end: String.Index?
                for index in remainder.indices {
                    let character = remainder[index]
                    if character == "<" { depth += 1 }
                    if character == ">", previous != "-" { depth -= 1 }
                    if depth == 0 { end = remainder.index(after: index); break }
                    previous = character
                }
                guard let end else { continue }
                remainder = remainder[end...]
            }
            let targetText = String(remainder)
            guard let targetMatch = targetExpression.firstMatch(
                in: targetText, range: NSRange(targetText.startIndex..., in: targetText)),
                  let target = Range(targetMatch.range(at: 1), in: targetText) else { continue }
            let name = String(code[alias]).replacingOccurrences(of: "`", with: "")
            let targetName = targetText[target].filter { !$0.isWhitespace && $0 != "`" }
            aliases[name, default: []].insert(targetName)
        }
    }

    /// Whether `target` names something in `names`, allowing a MODULE qualifier.
    ///
    /// `typealias Hidden = LavaSecTunnel.PacketTunnelProvider` is the class (Codex, PR #651), while
    /// `typealias Inner = PacketTunnelProvider.Something` is a nested type and is not — and that
    /// falls out for free, because `Something` is not a known name.
    ///
    /// A first draft also required the qualifier NOT to be a known name, to tell a module from an
    /// enclosing type. Mutation-testing showed that branch never fires: it changes the answer only
    /// for a nested type whose LEAF name collides with a known alias, which no real code writes. It
    /// is gone rather than carried as an untested branch. The residual is that such a collision
    /// would be treated as the class — a false failure, which is loud and the safe direction here.
    func resolves(_ target: String, in names: Set<String>) -> Bool {
        if names.contains(target) { return true }
        let parts = target.split(separator: ".").map(String.init)
        return parts.count == 2 && names.contains(parts[1])
    }

    var names: Set<String> = [className]
    var reachedFixedPoint = false
    while !reachedFixedPoint {
        reachedFixedPoint = true
        for (alias, targets) in aliases
        where !names.contains(alias) && targets.contains(where: { resolves($0, in: names) }) {
            names.insert(alias)
            reachedFixedPoint = false
        }
    }
    return names
}

/// The Swift source paths `project.yml` compiles into `target`, in declaration order.
///
/// Hand-rolled rather than a YAML dependency: the manifest lists one `- path:` per file under a
/// two-space-indented target key, and the tests already read this file as text.
///
/// Returns Swift sources only — targets also list `Info.plist`, `.c` files and entitlements, none
/// of which can carry an `extension`. Throws rather than returning empty, because every caller
/// uses this to decide what to scan: a silently empty list is a silently vacuous test. That is not
/// hypothetical here — `LavaSec` appears twice in the manifest, once as a target and once as a
/// scheme, and the scheme block parses to no paths at all.
func targetSourcePaths(_ target: String) throws -> [String] {
    let manifest = try readSource(.projectYAML)
    let lines = manifest.components(separatedBy: .newlines)
    guard let start = lines.firstIndex(where: { $0 == "  \(target):" }) else {
        throw SourceIntrospectionFailure(description: """
            project.yml has no `  \(target):` target. Either the target was renamed — update the \
            caller in the same commit — or the manifest's indentation changed, which would make \
            the caller's walk silently scan nothing.
            """)
    }
    var paths: [String] = []
    for line in lines[(start + 1)...] {
        // The next two-space-indented key ends the target's block.
        if line.hasPrefix("  "), !line.hasPrefix("   "), line.hasSuffix(":") { break }
        guard let range = line.range(of: "- path: ") else { continue }
        paths.append(String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces))
    }
    let swiftPaths = paths.filter { $0.hasSuffix(".swift") }
    guard !swiftPaths.isEmpty else {
        throw SourceIntrospectionFailure(description: """
            project.yml's `  \(target):` block lists no Swift sources. The manifest's shape \
            changed, or this matched a scheme rather than the target — either way the caller's \
            scan would cover nothing.
            """)
    }
    return swiftPaths
}

/// The `// MARK: -` section headers of `source`, in order, as whole lines.
///
/// Whole LINES, so a header quoted inside a rationale comment is not counted — this codebase
/// quotes constructs routinely, and a substring scan makes every such comment a tripwire
/// (Kilo, PR #651).
func sectionHeaderLines(in source: String) -> [String] {
    source
        .components(separatedBy: .newlines)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { $0.hasPrefix("// MARK: - ") }
}

// MARK: - Registry self-check

final class SourceFileRegistryTests: XCTestCase {
    /// The aggregate's ORDER, which is the half of the contract the set comparison cannot see.
    ///
    /// Pins anchor a block's start in one section and its end in the next, so a reordered registry
    /// would not fail the completeness check above — it would silently hand those pins a different
    /// span. Reordering the `// MARK:` sections is a deliberate act; this makes it a visible one.
    func testTheAggregateKeepsTheClassInSectionOrder() throws {
        let expected = [
        "// MARK: - Completion & helper types",
        "// MARK: - Stored state declared beside its concern before the file split",
        "// MARK: - Tunnel lifecycle (start / stop / wake)",
        "// MARK: - App messaging (IPC)",
        "// MARK: - Packet read loop & DNS request handling",
        "// MARK: - Upstream forwarding & resolution pipeline",
        "// MARK: - Resolver runtime & transports (device / plain / DoH / DoT / DoQ)",
        "// MARK: - Encrypted-resolver bootstrap (endpoint hostname resolution)",
        "// MARK: - Bootstrap host resolution broker (breaks the fail-closed deadlock)",
        "// MARK: - Focus filter switch config poll (LAV-100 Phase 4 P4d)",
        "// MARK: - Fallback recovery & wedge recovery probes",
        "// MARK: - Device-DNS capture",
        "// MARK: - Smoke probe scheduling & result application",
        "// MARK: - Health reset & network path monitoring",
        "// MARK: - Startup shared state & bootstrap snapshot",
        "// MARK: - VPN recovery after first unlock (LAV-124)",
        "// MARK: - Transient bootstrap DNS wait",
        "// MARK: - Diagnostics & upstream health recording",
        "// MARK: - Canonical tier evidence and repair dispatch",
        "// MARK: - Protection notifications & network activity log",
        "// MARK: - Self-reconnect & guarded teardown",
        "// MARK: - Device DNS tier repair",
        "// MARK: - Configuration & device-DNS state accessors",
        "// MARK: - Snapshot reload orchestration",
        "// MARK: - Temporary protection pause / resume",
        "// MARK: - Resident snapshot state & DNS runtime resets",
        "// MARK: - Filter decision",
        "// MARK: - Snapshot compile, artifact stores & fast-resume",
        "// MARK: - Chained data path construction (S8.8b)",
        "// MARK: - Chained runtime types (S8.8b)",
        "// MARK: - Chained tunnel seam host (S8.8b)",
        "// MARK: - Private DNS wire, socket & factory types",
        ]
        // Compared against the HEADER LINES, not the raw text.
        //
        // Two reasons, both found by review (Kilo, PR #651). A substring scan counts quotations:
        // `PacketTunnelProvider+BootstrapBroker.swift` already embeds a retired header inside a
        // rationale comment, and the first comment to quote a LIVE one would fail this test for no
        // reason. And exact equality — rather than "in order" plus a per-header count — ties this
        // list to the file registry: 29 registered files carry exactly these 30 headers, so a file
        // added to `packetTunnelProviderSources` without a header here, or with an unlisted one,
        // fails instead of silently landing outside the order check while cross-section pins keep
        // reading spans that include it.
        let source = try readPacketTunnelProviderSource()
        XCTAssertEqual(
            sectionHeaderLines(in: source), expected,
            """
            the provider's // MARK: sections no longer match this list, in this order. A cross-section \
            pin now reads a different span. If you added or moved a section, update `expected` in the \
            same commit and re-check the pins that anchor across it.
            """
        )

        // Every registered file contributes at least one of them, named individually so a headerless
        // file is an actionable failure rather than a 29-element array diff.
        for sourceFile in SourceFile.packetTunnelProviderSources {
            let text = try readSource(sourceFile)
            XCTAssertFalse(
                sectionHeaderLines(in: text).isEmpty,
                """
                \(sourceFile.rawValue) is registered but declares no `// MARK: -` section header, so \
                its position in the class is invisible to the order check above.
                """
            )
        }
    }

    /// A view-model file missing from `appViewModelSources` would be invisible to every absence
    /// pin on the class, so every `.swift` under `LavaSecApp/AppViewModel/` plus the core file must
    /// equal the registered list exactly.
    func testEveryAppViewModelFileOnDiskIsInTheAggregate() throws {
        let registered = Set(SourceFile.appViewModelSources.map(\.rawValue))
        // The core file must be REGISTERED, not merely present on disk. Asserting only that the
        // file exists would let it drop out of the aggregate while this test stayed green, and
        // every absence pin would then miss the class declaration and all of its stored state.
        XCTAssertTrue(
            registered.contains("LavaSecApp/AppViewModel.swift"),
            "the aggregate must include the core file, or the pins read the class without its state"
        )
        // EVERY app-target source root, not just LavaSecApp/: the `LavaSec` target also compiles
        // several `Shared/` files (project.yml), so an `extension AppViewModel` could legally live
        // there and would otherwise be invisible to the aggregate and to every pin reading it.
        //
        // The roots are still listed here — the walk is RECURSIVE and deliberately broader than the
        // compiled set, since a file can be added to a directory and to the target in separate
        // commits — but the list is now CHECKED against project.yml rather than trusted. A source
        // directory added to any target that compiles the class, and not covered by a root here,
        // fails below instead of falling outside every check (the same gap Kilo found on the tunnel
        // side, PR #651).
        let walkedRoots = ["LavaSecApp", "Shared", "LavaSecWidget", "LavaSecIntents"]
        for target in ["LavaSec", "LavaSecWidget", "LavaSecIntents"] {
            for compiled in try targetSourcePaths(target) {
                let directory = (compiled as NSString).deletingLastPathComponent
                XCTAssertTrue(
                    walkedRoots.contains(where: { directory == $0 || directory.hasPrefix($0 + "/") }),
                    """
                    project.yml compiles \(compiled) into \(target), but no root in \(walkedRoots) \
                    covers it — an `extension AppViewModel` there is invisible to every pin.
                    """
                )
            }
        }
        var onDisk: Set<String> = []
        var sources: [(relative: String, text: String)] = []
        for root in walkedRoots {
            let rootURL = packageRootURL.appendingPathComponent(root)
            let enumerator = try XCTUnwrap(
                FileManager.default.enumerator(at: rootURL, includingPropertiesForKeys: nil))
            while let url = enumerator.nextObject() as? URL {
                guard url.pathExtension == "swift" else { continue }
                let relative = root + "/" + url.path.dropFirst(rootURL.path.count + 1)
                onDisk.insert(relative)
                sources.append((relative, try String(contentsOf: url, encoding: .utf8)))
            }
        }

        // Aliases first, over EVERY walked file including the registered ones — a `typealias` is
        // module-scoped, so the binding and the extension it enables can sit in different files
        // (Codex, PR #651). Only then is each unregistered file checked against the union.
        //
        // The matcher is the tunnel side's: comment- and string-blanked, chains resolved to a fixed point,
        // and every declaration form including `extension AppViewModel: SomeProtocol` — which this
        // class's own files use constantly and a space-terminated needle misses (Kilo, PR #652).
        let appViewModelNames = classNamesExtending("AppViewModel", inAnyOf: sources.map(\.text))
        for (relative, text) in sources where !registered.contains(relative) {
            let extended = extensionNameExtending(appViewModelNames, in: text)
            XCTAssertNil(
                extended,
                """
                \(relative) extends AppViewModel (as `\(extended ?? "")`) but is not in \
                appViewModelSources, so it is invisible to every pin that reads the class \
                as one text.
                """
            )
        }
        XCTAssertEqual(
            onDisk.filter { $0.hasPrefix("LavaSecApp/AppViewModel/") },
            registered.subtracting(["LavaSecApp/AppViewModel.swift"])
        )
        XCTAssertEqual(
            SourceFile.appViewModelSources.count,
            Set(SourceFile.appViewModelSources).count,
            "a file listed twice would be scanned twice and could double an occurrence count")
    }


    /// The same contract for `AppViewModel`, which had none — its 27 files were pinned for
    /// completeness but never for ORDER, so a reordered `appViewModelSources` would have handed
    /// every cross-section pin a different span with nothing failing. The tunnel side has carried
    /// this check since its split; the app side is the half that was missing.
    func testTheAggregateKeepsTheAppViewModelInSectionOrder() throws {
        let expected = [
            "// MARK: - Stored state declared beside its concern before the file split",
            "// MARK: - Filter-rules budget",
            "// MARK: - Filter editing drafts",
            "// MARK: - Filter draft preparation & apply",
            "// MARK: - Multi-filter library",
            "// MARK: - Filter switching",
            "// MARK: - Shareable filters",
            "// MARK: - Temporary protection pause",
            "// MARK: - Live Activity",
            "// MARK: - Onboarding",
            "// MARK: - Resolver settings",
            "// MARK: - QA / admin tooling",
            "// MARK: - Chained DNS fallback (T1)",
            "// MARK: - Diagnostics & local log export",
            "// MARK: - Report surfaces refresh",
            "// MARK: - Diagnostic context & event logging",
            "// MARK: - Blocklist catalog sync",
            "// MARK: - Warm artifact preparation & publish",
            "// MARK: - Protection toggle & VPN lifecycle",
            "// MARK: - Chained-connect lifecycle",
            "// MARK: - App Store review prompting",
            "// MARK: - LavaGuard progress",
            "// MARK: - Focus auto-switch coordination (LAV-100 Phase 3)",
            "// MARK: - Shared-state persistence funnels",
            "// MARK: - Sudoku easter egg persistence",
            "// MARK: - Tunnel health & messaging",
            "// MARK: - App view model support types",
            "// MARK: - Catalog sync bridge",
            "// MARK: - Backup hub bridge",
            "// MARK: - LavaSecurity+ hub bridge",
            "// MARK: - Account hub bridge",
            "// MARK: - Diagnostics hub bridge",
            "// MARK: - Customization hub bridge",
            "// MARK: - Library presentation bridge",
        ]
        let source = try readAppViewModelSource()
        XCTAssertEqual(
            sectionHeaderLines(in: source), expected,
            """
            AppViewModel's // MARK: sections no longer match this list, in this order. A \
            cross-section pin now reads a different span. If you added or moved a section, update \
            `expected` in the same commit and re-check the pins that anchor across it.
            """
        )
        for sourceFile in SourceFile.appViewModelSources {
            XCTAssertFalse(
                sectionHeaderLines(in: try readSource(sourceFile)).isEmpty,
                """
                \(sourceFile.rawValue) is registered but declares no `// MARK: -` section header, \
                so its position in the class is invisible to the order check above.
                """
            )
        }
    }

    /// A provider file missing from `packetTunnelProviderSources` would be invisible to every
    /// absence pin on the class, so the set on disk must equal the registered list exactly.
    func testEveryTunnelProviderFileOnDiskIsInTheAggregate() throws {
        let root = packageRootURL.appendingPathComponent("LavaSecTunnel")
        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var onDisk: Set<String> = []
        while let url = enumerator.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            onDisk.insert("LavaSecTunnel/" + url.path.dropFirst(root.path.count + 1))
        }
        XCTAssertEqual(onDisk, Set(SourceFile.packetTunnelProviderSources.map(\.rawValue)))
        // A file that declares part of the class but lives OUTSIDE `LavaSecTunnel/` would pass the
        // check above (it only walks that directory) while shrinking the aggregate every pin reads.
        //
        // The other directories are DERIVED from the tunnel target in `project.yml`, not asserted in
        // prose. The prose said "`Shared/` is the other directory compiled into the tunnel target",
        // which was true and untied: a third source directory added to the target would have fallen
        // outside every check here (Kilo, PR #651). Deriving it means the target's own manifest
        // decides what gets scanned.
        let compiled = try targetSourcePaths("LavaSecTunnel")
        // Aliases come from EVERY compiled source, registered ones included, because a `typealias`
        // in one file binds a name that any other file may extend (Codex, PR #651).
        let providerNames = classNamesExtending(
            "PacketTunnelProvider",
            inAnyOf: try compiled.map {
                try String(contentsOf: packageRootURL.appendingPathComponent($0), encoding: .utf8)
            }
        )
        XCTAssertEqual(
            Set(compiled.filter { $0.hasPrefix("LavaSecTunnel/") }),
            Set(SourceFile.packetTunnelProviderSources.map(\.rawValue)),
            """
            project.yml compiles a different set of LavaSecTunnel/ files into the tunnel than the \
            registry lists. A file compiled but unregistered is invisible to every pin on the class.
            """
        )
        for relativePath in compiled where !relativePath.hasPrefix("LavaSecTunnel/") {
            let url = packageRootURL.appendingPathComponent(relativePath)
            let text = try String(contentsOf: url, encoding: .utf8)
            let extended = extensionNameExtending(providerNames, in: text)
            XCTAssertNil(
                extended,
                """
                \(relativePath) extends PacketTunnelProvider (as `\(extended ?? "")`) from outside \
                LavaSecTunnel/, so it is invisible to packetTunnelProviderSources and to every pin \
                that reads the class.
                """
            )
        }

        XCTAssertEqual(
            SourceFile.packetTunnelProviderSources.count,
            Set(SourceFile.packetTunnelProviderSources).count,
            "a file listed twice would be scanned twice and could double an occurrence count")
    }

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

/// Removes full-line `//` and `///` comments from a source slice.
/// Use for positive and negative wiring assertions: rationale can otherwise create either a
/// false pass or a false failure (PR #625). This is not a Swift parser; inline/block comments
/// and string literals remain, so anchor behavioral pins to the owning function and statements.
func sourceCodeOnly(_ slice: String) -> String {
    slice
        .split(separator: "\n", omittingEmptySubsequences: false)
        .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        .joined(separator: "\n")
}
