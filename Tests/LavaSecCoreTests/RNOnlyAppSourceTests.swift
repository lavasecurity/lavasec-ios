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

    func testRetainedNativeFlowsKeepTheirRequestAndAuthenticationOwners() throws {
        let flows = try readSource(.reactNativeAppFlows)
        for retained in ["ImportFiltersFlow(", "AccountSheet()", "BackupSetupView()", "BackupRestoreView()",
                         "SecurityPasscodeSetupView()", "DNSResolverSettingsView(", "BundledLibraryNoticesView()"] {
            XCTAssertTrue(flows.contains(retained), retained)
        }
        XCTAssertTrue(flows.contains("completion: flow.importCompletion"))
        XCTAssertTrue(flows.contains("requireFreshAuthentication(for: .filterEditing"))
        let root = try readSource(.rootView)
        XCTAssertTrue(root.contains("let presentation = importDeepLinkSheetItem.wrappedValue"))
        XCTAssertTrue(root.contains("importCompletion: presentation.completion"))
        XCTAssertTrue(root.contains("(security.isAppUnlockBlockingUI || security.isAppUnlockPrivacyMaskVisible) ? nil : importDeepLinkPresentation"))
    }

    func testPrivateCompileLaneBuildsRNForEveryConfiguration() throws {
        let workflow = try readSource(.lightBuildWorkflow)
        XCTAssertTrue(workflow.contains("prepare-full-app.sh"))
        XCTAssertEqual(workflow.components(separatedBy: "-workspace ReactNative/native-app/LavaSecRN.xcworkspace").count - 1, 3)
        XCTAssertTrue(workflow.contains("-D LAVA_QA_TOOLS -D LAVA_REACT_NATIVE"))
        XCTAssertFalse(workflow.contains("-project LavaSec.xcodeproj"))
    }
}
