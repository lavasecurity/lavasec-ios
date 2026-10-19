import XCTest

/// The app has one navigation owner. Native components/services still ship in its graph.
final class RNOnlyAppSourceTests: XCTestCase {
    func testNativeNavigationHostUsesThePhysicalHorizontalViewport() throws {
        let root = try readSource(.rootView)
        let presentation = try sourceBlock(in: root, startingAt: "private var rootPresentation: some View", endingBefore: "private func forwardReactExternalFlows()")
        XCTAssertTrue(presentation.contains("LavaAppHost().ignoresSafeArea(.all, edges: .bottom)"))
        XCTAssertTrue(presentation.contains(".ignoresSafeArea(.container, edges: .horizontal)"))
        XCTAssertFalse(presentation.contains("edges: .all"), "Portrait top and keyboard regions retain their existing owners.")
        let host = try readSource(.reactNativeAppHost)
        let mount = try sourceBlock(in: host, startingAt: "private func mountReactRoot()", endingBefore: "private func updateNativeFlow()")
        XCTAssertTrue(mount.contains("root.leadingAnchor.constraint(equalTo: view.leadingAnchor)"))
        XCTAssertTrue(mount.contains("root.trailingAnchor.constraint(equalTo: view.trailingAnchor)"))
        XCTAssertFalse(mount.contains("safeAreaLayoutGuide"), "Only content is inset; the native header host fills its allocated viewport.")
    }

    func testAllOffNativeBootstrapWaitsForAnAuthorizedProjectionBeforeCreatingReact() throws {
        let host = try readSource(.reactNativeAppHost)
        let mount = try sourceBlock(in: host, startingAt: "private func mountReactRoot()", endingBefore: "private func updateNativeFlow()")
        let readiness = try XCTUnwrap(mount.range(of: "guard bridge.security.backgroundPrivacyCoverRequired || bridge.canReadPresentation(.appUnlock) else { return }"))
        let factory = try XCTUnwrap(mount.range(of: "RCTReactNativeFactory(delegate:"))
        XCTAssertLessThan(readiness.lowerBound, factory.lowerBound)
        XCTAssertTrue(mount.contains("LavaAppReactSurface(factory: factory"))
        let surface = try sourceBlock(in: host, startingAt: "private final class LavaAppReactSurface", endingBefore: "private final class LavaAppReactDelegate")
        XCTAssertTrue(surface.contains("properties[\"initialSnapshot\"] = bridge.snapshot()"))
        XCTAssertTrue(surface.contains("bridge.mountPresentation(presentationID)"))
        XCTAssertTrue(host.contains("UIApplication.didBecomeActiveNotification, UIApplication.protectedDataDidBecomeAvailableNotification"))
    }

    func testTheAppCannotBuildTheRetiredShell() throws {
        let root = try readSource(.rootView)
        XCTAssertTrue(root.contains("#if !LAVA_REACT_NATIVE"))
        XCTAssertTrue(root.contains("#error(\"Build ReactNative/native-app/LavaSecRN.xcworkspace"))
        XCTAssertTrue(root.contains("LavaAppHost()"))
        for retired in ["nativeTabs", "TabView(", "SettingsRouteDestinationView", "nativePresentation<Item>"] {
            XCTAssertFalse(root.contains(retired), retired)
        }
        let manifest = try readSource(.projectYAML)
        for retired in ["LavaSecApp/GuardView.swift", "LavaSecApp/FiltersView.swift",
                        "LavaSecApp/DiagnosticsView.swift", "LavaSecApp/FilterMyListView.swift",
                        "LavaSecApp/FilterDomainSheets.swift", "LavaSecApp/DiagnosticsDomainHistory.swift",
                        "LavaSecApp/DiagnosticsTopDomains.swift", "LavaSecApp/LavaDesignSystem/LavaGuardMaterial.swift"] {
            XCTAssertFalse(manifest.contains(retired), retired)
        }
    }

    func testMigratedFlowsUseReactPresentationAndRetainNativeAuthority() throws {
        let flows = try readSource(.reactNativeAppFlows)
        for name in ["account", "backupSetup", "backupRestore", "passcode", "import", "importCode", "importScan", "deepLinkImport"] {
            XCTAssertTrue(flows.contains("\"\(name)\""), name)
        }
        XCTAssertTrue(flows.contains("accountBackupProjection(flow)"))
        XCTAssertTrue(flows.contains("importProjection(flow)"))
        XCTAssertTrue(try readSource(.reactNativeAppImport).contains("requireFreshAuthentication(for: .filterEditing"))
        XCTAssertTrue(try readSource(.reactNativeAppPasscode).contains("security.completePasscodeAuthentication(requestID: id, code: code)"))
        let root = try readSource(.rootView)
        XCTAssertTrue(root.contains("let presentation = importDeepLinkSheetItem.wrappedValue"))
        XCTAssertTrue(root.contains("importCompletion: presentation.completion"))
        XCTAssertTrue(root.contains("(security.isAppUnlockBlockingUI || security.isAppUnlockPrivacyMaskVisible) ? nil : importDeepLinkPresentation"))
    }

    func testRetiredPresentationFilesCannotReturnThroughAppOrTestMembership() throws {
        let retired = [
            "LavaSecApp/OnboardingFlowView.swift",
            "LavaSecApp/LavaDesignSystem/LavaIcon.swift",
            "LavaSecApp/SudokuEasterEggView.swift",
            "Sources/LavaSecAppServices/OnboardingAnimation.swift",
            "Sources/LavaSecKit/SudokuNotesGridLayout.swift",
        ]
        let manifest = try readSource(.projectYAML)
        let project = try readSource(.xcodeProject)
        let registered = Set(SourceFile.allCases.map(\.rawValue))
        for path in retired {
            XCTAssertFalse(FileManager.default.fileExists(atPath: packageRootURL.appendingPathComponent(path).path), path)
            XCTAssertFalse(manifest.contains(path), path)
            XCTAssertFalse(project.contains(URL(fileURLWithPath: path).lastPathComponent), path)
            XCTAssertFalse(registered.contains(path), "Tests must inspect the live RN owner: \(path)")
        }
    }

    func testReactOwnedFlowsHaveNoDuplicateNativeRenderBranches() throws {
        let flows = try readSource(.reactNativeAppFlows)
        let native = try sourceBlock(in: flows, startingAt: "@ViewBuilder private func flowContent", endingBefore: "default: EmptyView()")
        for name in ["createFilter", "renameFilter", "deleteFilters", "automation", "licenses", "feedback", "vpnConfiguration", "account", "backupSetup", "backupRestore", "passcode", "import", "importCode", "importScan", "deepLinkImport", "customDNS", "customBlocklist", "phoneQA", "phoneQASheet"] {
            XCTAssertFalse(native.contains("case \"\(name)\""), "\(name) must use its shared RN foreground surface")
        }
        XCTAssertTrue(flows.contains("LavaAppForegroundContent(id: flow.id.uuidString)"))
    }

    func testNativeCompileGraphDoesNotRetainReplacedScaffolds() throws {
        let retired = [
            "LavaOnboardingView", "LavaOnboardingHandoff", "SudokuEasterEggView",
            "ShareableFilterCard", "CreateFilterSheet", "RenameFilterSheet",
            "DiffGroup", "FilterReviewChangeRow", "LavaTableRow", "LavaIconRole",
            "DeleteFiltersConfirmationSheet", "BugReportSheetView", "BundledLibraryNoticesView",
            "UpgradeSettingsView", "LavaPlusUpgradeDestination", "UpgradeLegalFooter", "UpgradeThankYouView", "UpgradeEntitlementCheckingView", "UpgradePlanComparisonValue", "UpgradePlanComparisonView", "UpgradePlanOfferRow",
            "FilterPreparationScreen", "PreparationTickerTitle", "DomainRejectPanel", "ImportFiltersFlow", "ImportPreviewView", "ImportCodeEntryView", "ImportMethodChooserView", "ImportReplacementReviewView", "ImportChooseReplaceTargetView", "ImportApplyingView", "AccountSheet", "BackupSetupView", "BackupRestoreView", "SecurityPasscodeSetupView", "SecurityPasscodeAuthenticationView", "PhoneQAView", "PhoneQASheetView", "PhoneQASettingsView", "LavaDNSPatchContent", "LavaCustomDNSDraftView", "BringYourOwnListView", "DNSResolverSettingsView", "VPNChainingSettingsView", "VPNChainingConfigurationEditor", "AutoSwitchHowToContent",
            "LavaPrimaryTabScreenContent", "LavaSetupChoiceRow", "LavaSetupPermissionIllustration",
            "LavaSettingsControlLabel", "LavaPrimaryExplainer", "LavaExplainerVariants", "LavaCyclingExamplePill",
        ]
        var paths = Set(try targetSourcePaths("LavaSec"))
        // The RN generator appends adapters to the base manifest. Scan their
        // source tree too, including fixtures, without walking dependencies or
        // generated projects. A duplicate there is just as distracting as one
        // in the base target and must not escape this retirement boundary.
        let reactRoot = packageRootURL.appendingPathComponent("ReactNative")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: reactRoot, includingPropertiesForKeys: nil, options: .skipsHiddenFiles))
        while let file = files.nextObject() as? URL {
            if ["node_modules", "Pods", "build"].contains(file.lastPathComponent)
                || ["xcodeproj", "xcworkspace"].contains(file.pathExtension) {
                files.skipDescendants()
                continue
            }
            if file.pathExtension == "swift" {
                paths.insert(String(file.path.dropFirst(packageRootURL.path.count + 1)))
            }
        }
        for path in paths.sorted() {
            let source = sourceCodeOnly(try String(contentsOf: packageRootURL.appendingPathComponent(path), encoding: .utf8))
            for name in retired {
                let declaration = "\\b(?:struct|class|enum)\\s+\(name)\\b"
                XCTAssertNil(source.range(of: declaration, options: .regularExpression), "\(path) reintroduces retired presentation \(name)")
            }
        }
    }

    func testPrivateCompileLaneBuildsRNForEveryConfiguration() throws {
        let workflow = try readSource(.lightBuildWorkflow)
        XCTAssertTrue(workflow.contains("prepare-full-app.sh"))
        XCTAssertEqual(workflow.components(separatedBy: "-workspace ReactNative/native-app/LavaSecRN.xcworkspace").count - 1, 3)
        XCTAssertTrue(workflow.contains("-D LAVA_QA_TOOLS -D LAVA_REACT_NATIVE"))
        XCTAssertFalse(workflow.contains("-project LavaSec.xcodeproj"))
    }

    func testDistributionCatalogsUseSpaceOptimizationWithoutDroppingIconVariants() throws {
        let project = try readSource(.xcodeProject)
        XCTAssertEqual(project.components(separatedBy: "ASSETCATALOG_COMPILER_OPTIMIZATION = space;").count - 1, 2,
                       "Release and QA optimize their catalog storage; Debug keeps the default.")
        let manifest = try readSource(.projectYAML)
        for name in ["AppIconFireOpal", "AppIconAmethyst", "AppIconObsidian", "AppIconCherryQuartz", "AppIconEmerald", "AppIconKiwiCreme", "AppIconAquamarine"] {
            XCTAssertTrue(manifest.contains("LavaSecApp/\(name).icon"), name)
        }
        XCTAssertTrue(manifest.contains("ASSETCATALOG_COMPILER_INCLUDE_ALL_APPICON_ASSETS: \"NO\""))
    }
}
