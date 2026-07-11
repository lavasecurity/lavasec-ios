import XCTest

final class ReleaseGateSourceTests: XCTestCase {
    func testInternalRCTagWorkflowChecksTagAgainstMarketingVersionBeforeDispatch() throws {
        let workflow = try readSource(.tagReleaseWorkflow)
        let guardBlock = try sourceBlock(
            in: workflow,
            startingAt: "- name: Guard — RC tag must match MARKETING_VERSION and prod floor",
            endingBefore: "- name: Trigger lavasec-runner internal release"
        )

        XCTAssertTrue(workflow.contains("uses: actions/checkout@v4"))
        XCTAssertTrue(guardBlock.contains("Config/Lava.xcconfig"))
        XCTAssertTrue(guardBlock.contains("MARKETING_VERSION"))
        XCTAssertTrue(guardBlock.contains("declared_version"))
        XCTAssertTrue(guardBlock.contains("[ \"$rc_base\" != \"$declared_version\" ]"))
        XCTAssertFalse(guardBlock.contains("gh workflow run release.yml"))
    }

    func testPhoneQASurfacesAreCompileGatedOutOfRelease() throws {
        let adminQA = try readSource(.adminQAView)
        let settings = try readSource(.settingsView)
        let root = try readSource(.rootView)
        let viewModel = try readSource(.appViewModel)
        // The rage-shake routing lives on DiagnosticsController since the Phase D4 peel.
        let diagnosticsController = try readSource(.diagnosticsController)
        let rageShakeQA = try readSource(.rageShakeQA)

        XCTAssertTrue(
            adminQA.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#if DEBUG || LAVA_QA_TOOLS"),
            "Phone QA views should not be compiled into Release."
        )
        XCTAssertTrue(
            adminQA.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("#endif"),
            "The Admin QA file should close its Release compile gate explicitly."
        )

        XCTAssertTrue(settings.contains("""
        #if DEBUG || LAVA_QA_TOOLS
            case phoneQA
        #endif
        """))
        XCTAssertTrue(settings.contains("""
        #if DEBUG || LAVA_QA_TOOLS
                case .phoneQA:
                    return .requires(.appSettings)
        #endif
        """))
        XCTAssertTrue(settings.contains("#if DEBUG || LAVA_QA_TOOLS\n                if viewModel.isAccountDeveloper {"))
        XCTAssertTrue(settings.contains("""
        #if DEBUG || LAVA_QA_TOOLS
        private struct PhoneQASettingsView: View {
        """))

        XCTAssertTrue(root.contains("""
        #if DEBUG || LAVA_QA_TOOLS
                    case .phoneQA:
        """))
        XCTAssertTrue(root.contains("#endif\n            case .bugReport:"))
        XCTAssertFalse(root.contains("#else\n            case .phoneQA:"))

        let rageShakeGate = try sourceBlock(
            in: diagnosticsController,
            startingAt: "var canOpenPhoneQAFromRageShake: Bool",
            endingBefore: "func handleRageShake()"
        )
        XCTAssertTrue(rageShakeGate.contains("#if DEBUG || LAVA_QA_TOOLS"))
        // The developer gate itself (isAccountDeveloper) stays a hub constant; the
        // controller reads it through the bridge inside the same compile gate.
        XCTAssertTrue(rageShakeGate.contains("return hub.isAccountDeveloper"))
        XCTAssertTrue(rageShakeGate.contains("#else"))
        XCTAssertTrue(rageShakeGate.contains("return false"))

        let destinationBlock = try sourceBlock(
            in: rageShakeQA,
            startingAt: "public enum RageShakeDestination",
            endingBefore: "package enum RageShakeMode"
        )
        let phoneQAGate = try sourceBlock(
            in: destinationBlock,
            startingAt: "#if DEBUG || LAVA_QA_TOOLS",
            endingBefore: "#endif"
        )
        XCTAssertTrue(phoneQAGate.contains("case phoneQA"))

        let adminGatePrefix = try sourceBlock(
            in: rageShakeQA,
            startingAt: "public mutating func registerShake",
            endingBefore: "public enum AdminQAActionSection"
        )
        XCTAssertTrue(adminGatePrefix.contains("#if DEBUG || LAVA_QA_TOOLS"))
        XCTAssertFalse(adminGatePrefix.contains("#endif"))
        XCTAssertTrue(rageShakeQA.contains("""
        public enum AdminQAVPNProfileAction
        """))
        XCTAssertTrue(
            rageShakeQA.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("#endif"),
            "Admin QA action types should close inside the Debug/QA compile gate."
        )

        XCTAssertTrue(viewModel.contains("#if DEBUG || LAVA_QA_TOOLS\n    @Published var qaProbeSuffixDraft"))
        XCTAssertTrue(viewModel.contains("#if DEBUG || LAVA_QA_TOOLS\n    @Published private(set) var adminQAStatusMessage"))
        XCTAssertTrue(viewModel.contains("#if DEBUG || LAVA_QA_TOOLS\n    var qaProbeSummaryText"))

        // The Diagnostics MARK region that followed the QA section now opens with the
        // hub-side export assembly (clearDiagnostics moved to DiagnosticsController, D4).
        let adminQACommandBlock = try sourceBlock(
            in: viewModel,
            startingAt: "#if DEBUG || LAVA_QA_TOOLS\n    func applyHostedQAProbeSet()",
            endingBefore: "func makeLocalLogExportArchive"
        )
        XCTAssertTrue(adminQACommandBlock.contains("func applyAdminQAAction(_ action: AdminQAAction)"))
        XCTAssertTrue(adminQACommandBlock.contains("func applyAdminQAVPNProfileAction(_ action: AdminQAVPNProfileAction) async"))
        XCTAssertTrue(adminQACommandBlock.contains("#endif"))
        // Canary: the negative pins above key on these identifiers - if a rename removes
        // one from the pinned source, those pins pass vacuously. Fail here instead, then
        // re-anchor both sides to the new name.
        XCTAssertTrue(settings.contains("phoneQA"))
    }

    func testReleaseBuildSettingsUseExplicitReleaseCompilationCondition() throws {
        let project = try readSource(.xcodeProject)
        // The pbxproj is generated from project.yml (XcodeGen, Phase C1 of lavasec-infra
        // plans/2026-07-07-ios-modularization-scaffolding-plan.md), so configuration UUIDs
        // are deterministic hashes, not durable anchors — resolve each container's Release/
        // Debug configuration ID through its named configuration-list block instead.
        // LavaSecUITests is deliberately absent: its Release configuration defines no
        // compilation conditions (it never ships) — only these five gate RELEASE.
        let releaseGatedContainers = [
            "PBXProject \"LavaSec\"",
            "PBXNativeTarget \"LavaSec\"",
            "PBXNativeTarget \"LavaSecTunnel\"",
            "PBXNativeTarget \"LavaSecWidget\"",
            "PBXNativeTarget \"LavaSecIntents\"",
        ]
        let releaseConfigurationIDs = try releaseGatedContainers.map {
            try Self.configurationIdentifier(in: project, container: $0, configuration: "Release")
        }
        let productionDebugConfigurationIDs = try releaseGatedContainers.map {
            try Self.configurationIdentifier(in: project, container: $0, configuration: "Debug")
        }

        XCTAssertEqual(
            project.components(separatedBy: "SWIFT_ACTIVE_COMPILATION_CONDITIONS = RELEASE;").count - 1,
            5,
            "Project, app, tunnel, widget, and App Intents extension Release configurations should explicitly define RELEASE."
        )
        XCTAssertTrue(project.contains("SWIFT_ACTIVE_COMPILATION_CONDITIONS = \"DEBUG LAVA_QA_TOOLS\";"))
        XCTAssertTrue(project.contains("SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG;"))

        for configurationID in releaseConfigurationIDs {
            let releaseBlock = try Self.buildConfigurationBlock(in: project, identifier: configurationID)
            XCTAssertTrue(
                releaseBlock.contains("SWIFT_ACTIVE_COMPILATION_CONDITIONS = RELEASE;"),
                "\(configurationID) should explicitly define RELEASE."
            )
            XCTAssertFalse(releaseBlock.contains("LAVA_QA_TOOLS"))
            XCTAssertFalse(releaseBlock.contains("SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG;"))
        }

        for configurationID in productionDebugConfigurationIDs {
            let debugBlock = try Self.buildConfigurationBlock(in: project, identifier: configurationID)
            XCTAssertFalse(
                debugBlock.contains("SWIFT_ACTIVE_COMPILATION_CONDITIONS = RELEASE;"),
                "\(configurationID) must not override Debug compilation conditions with RELEASE."
            )
        }
    }

    func testReleaseFilteringIgnoresPersistedQAProbeSets() throws {
        let appConfiguration = try readSource(.appConfiguration)
        let filterSnapshot = try readSource(.filterSnapshot)

        let decodeBlock = try sourceBlock(
            in: appConfiguration,
            startingAt: "isPaid = try container.decodeIfPresent(Bool.self, forKey: .isPaid)",
            endingBefore: "customBlocklists = try container.decodeIfPresent"
        )
        XCTAssertTrue(decodeBlock.contains("#if DEBUG || LAVA_QA_TOOLS"))
        XCTAssertTrue(decodeBlock.contains("qaProbeSet = try container.decodeIfPresent(QADomainProbeSet.self, forKey: .qaProbeSet)"))
        XCTAssertTrue(decodeBlock.contains("#else"))
        XCTAssertTrue(decodeBlock.contains("qaProbeSet = nil"))

        let qaApplyBlock = try sourceBlock(
            in: filterSnapshot,
            startingAt: "public func applyingQAProbeSet(_ probeSet: QADomainProbeSet?) -> FilterSnapshot",
            endingBefore: "public extension AppConfiguration"
        )
        XCTAssertTrue(qaApplyBlock.contains("#if DEBUG || LAVA_QA_TOOLS"))
        XCTAssertTrue(qaApplyBlock.contains("#else"))
        XCTAssertTrue(qaApplyBlock.contains("return self"))
    }

    private static func buildConfigurationBlock(in project: String, identifier: String) throws -> String {
        let startMarker = "\(identifier) = {"
        let start = try XCTUnwrap(project.range(of: startMarker)?.lowerBound)
        let suffix = project[start...]
        let end = try XCTUnwrap(suffix.range(of: "\n\t\t};")?.upperBound)
        return String(suffix[..<end])
    }

    /// Resolves "UUID /* Release */"-style identifiers from a container's named
    /// XCConfigurationList block, so the assertions above survive pbxproj regeneration
    /// (`xcodegen generate` rewrites every UUID; the list comments are stable).
    private static func configurationIdentifier(
        in project: String,
        container: String,
        configuration: String
    ) throws -> String {
        let marker = "/* Build configuration list for \(container) */ = {"
        let start = try XCTUnwrap(
            project.range(of: marker)?.upperBound,
            "No configuration list found for \(container)."
        )
        let suffix = project[start...]
        let end = try XCTUnwrap(suffix.range(of: "};")?.lowerBound)
        for line in suffix[..<end].split(separator: "\n") {
            let entry = line.trimmingCharacters(in: .whitespaces)
            if entry.hasSuffix("/* \(configuration) */,") {
                return String(entry.dropLast(1))
            }
        }
        throw SourceIntrospectionFailure(
            description: "No \(configuration) configuration in the list for \(container)."
        )
    }
}
