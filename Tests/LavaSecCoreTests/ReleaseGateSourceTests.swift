import XCTest

final class ReleaseGateSourceTests: XCTestCase {
    func testPhoneQASurfacesAreCompileGatedOutOfRelease() throws {
        let adminQA = try Self.source("LavaSecApp/AdminQAView.swift")
        let settings = try Self.source("LavaSecApp/SettingsView.swift")
        let root = try Self.source("LavaSecApp/RootView.swift")
        let viewModel = try Self.source("LavaSecApp/AppViewModel.swift")
        let rageShakeQA = try Self.source("Sources/LavaSecCore/RageShakeQA.swift")

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

        let rageShakeGate = try Self.sourceBlock(
            in: viewModel,
            startingAt: "var canOpenPhoneQAFromRageShake: Bool",
            endingBefore: "func handleRageShake()"
        )
        XCTAssertTrue(rageShakeGate.contains("#if DEBUG || LAVA_QA_TOOLS"))
        XCTAssertTrue(rageShakeGate.contains("return isAccountDeveloper"))
        XCTAssertTrue(rageShakeGate.contains("#else"))
        XCTAssertTrue(rageShakeGate.contains("return false"))

        XCTAssertTrue(rageShakeQA.contains("""
            #if DEBUG || LAVA_QA_TOOLS
            case phoneQA
            #endif
        """))
        XCTAssertTrue(rageShakeQA.contains("""
        #if DEBUG || LAVA_QA_TOOLS
        public enum AdminQAActionSection
        """))
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

        let adminQACommandBlock = try Self.sourceBlock(
            in: viewModel,
            startingAt: "#if DEBUG || LAVA_QA_TOOLS\n    func applyHostedQAProbeSet()",
            endingBefore: "func clearDiagnostics()"
        )
        XCTAssertTrue(adminQACommandBlock.contains("func applyAdminQAAction(_ action: AdminQAAction)"))
        XCTAssertTrue(adminQACommandBlock.contains("func applyAdminQAVPNProfileAction(_ action: AdminQAVPNProfileAction) async"))
        XCTAssertTrue(adminQACommandBlock.contains("#endif"))
    }

    func testReleaseBuildSettingsUseExplicitReleaseCompilationCondition() throws {
        let project = try Self.source("LavaSec.xcodeproj/project.pbxproj")
        let releaseConfigurationIDs = [
            "1A000001000000000000B002 /* Release */",
            "1A000001000000000000B102 /* Release */",
            "1A000001000000000000B202 /* Release */",
            "1A000003000000000000B302 /* Release */",
            "1A0000080000000000B002 /* Release */",
        ]
        let productionDebugConfigurationIDs = [
            "1A000001000000000000B001 /* Debug */",
            "1A000001000000000000B101 /* Debug */",
            "1A000001000000000000B201 /* Debug */",
            "1A000003000000000000B301 /* Debug */",
            "1A0000080000000000B001 /* Debug */",
        ]

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
        let appConfiguration = try Self.source("Sources/LavaSecCore/AppConfiguration.swift")
        let filterSnapshot = try Self.source("Sources/LavaSecCore/FilterSnapshot.swift")

        let decodeBlock = try Self.sourceBlock(
            in: appConfiguration,
            startingAt: "isPaid = try container.decodeIfPresent(Bool.self, forKey: .isPaid)",
            endingBefore: "customBlocklists = try container.decodeIfPresent"
        )
        XCTAssertTrue(decodeBlock.contains("#if DEBUG || LAVA_QA_TOOLS"))
        XCTAssertTrue(decodeBlock.contains("qaProbeSet = try container.decodeIfPresent(QADomainProbeSet.self, forKey: .qaProbeSet)"))
        XCTAssertTrue(decodeBlock.contains("#else"))
        XCTAssertTrue(decodeBlock.contains("qaProbeSet = nil"))

        let qaApplyBlock = try Self.sourceBlock(
            in: filterSnapshot,
            startingAt: "public func applyingQAProbeSet(_ probeSet: QADomainProbeSet?) -> FilterSnapshot",
            endingBefore: "public extension AppConfiguration"
        )
        XCTAssertTrue(qaApplyBlock.contains("#if DEBUG || LAVA_QA_TOOLS"))
        XCTAssertTrue(qaApplyBlock.contains("#else"))
        XCTAssertTrue(qaApplyBlock.contains("return self"))
    }

    private static func source(_ relativePath: String) throws -> String {
        let sourceURL = packageRootURL.appendingPathComponent(relativePath)
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }

    private static var packageRootURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static func sourceBlock(
        in source: String,
        startingAt startMarker: String,
        endingBefore endMarker: String
    ) throws -> String {
        let start = try XCTUnwrap(source.range(of: startMarker)?.lowerBound)
        let suffix = source[start...]
        let end = try XCTUnwrap(suffix.range(of: endMarker)?.lowerBound)
        return String(suffix[..<end])
    }

    private static func buildConfigurationBlock(in project: String, identifier: String) throws -> String {
        let startMarker = "\(identifier) = {"
        let start = try XCTUnwrap(project.range(of: startMarker)?.lowerBound)
        let suffix = project[start...]
        let end = try XCTUnwrap(suffix.range(of: "\n\t\t};")?.upperBound)
        return String(suffix[..<end])
    }
}
