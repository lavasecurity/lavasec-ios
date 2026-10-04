import XCTest

final class ReleaseGateSourceTests: XCTestCase {
    func testMetricKitRequiresQAWithoutDebug() throws {
        let collector = try readSource(.qaMetricKitCollector)
        XCTAssertTrue(collector.hasPrefix("#if LAVA_QA_TOOLS\n"))
        XCTAssertTrue(collector.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("#endif"))
        XCTAssertEqual(collector.components(separatedBy: "#if ").count, 2)
        XCTAssertEqual(collector.components(separatedBy: "#endif").count, 2)
        XCTAssertFalse(collector.contains("#else"))
        XCTAssertTrue(collector.contains("private final class QAMetricKitSubscriber: NSObject"))
        let app = try readSource(.lavaSecApp)
        XCTAssertTrue(app.contains("#if LAVA_QA_TOOLS\n        QAMetricKitCollector.start()\n        #endif"))
        XCTAssertTrue(collector.contains("Bundle.main.bundleIdentifier == \"com.lavasec.dev.qa\""))
    }

    func testReleaseVPNMetadataReportsTheSavedConfigurationAndPreference() throws {
        let source = try sourceBlock(in: try readSource(.reactNativeAppQueries),
            startingAt: "private func vpnTier()", endingBefore: "func resolverMetadata(")
        XCTAssertTrue(source.contains("let status = model.chainedUpstreamSurfaceStatus"))
        XCTAssertTrue(source.contains("status.chainingEnabled"))
        XCTAssertTrue(source.contains("status.storedConfigurationDNSAddresses"))
        XCTAssertTrue(source.contains("status.hasConfigurationWithoutKey"))
        XCTAssertFalse(source.contains("#if DEBUG || LAVA_QA_TOOLS"))
    }

    func testInternalRCTagWorkflowChecksTagAgainstMarketingVersionBeforeDispatch() throws {
        let workflow = try readSource(.tagReleaseWorkflow)
        let guardBlock = try sourceBlock(
            in: workflow,
            startingAt: "- name: Guard — RC tag must match MARKETING_VERSION and prod floor",
            endingBefore: "- name: Trigger lavasec-runner builds for"
        )

        XCTAssertTrue(workflow.contains("uses: actions/checkout@v4"))
        XCTAssertTrue(guardBlock.contains("Config/Lava.xcconfig"))
        XCTAssertTrue(guardBlock.contains("MARKETING_VERSION"))
        XCTAssertTrue(guardBlock.contains("declared_version"))
        XCTAssertTrue(guardBlock.contains("[ \"$rc_base\" != \"$declared_version\" ]"))
        XCTAssertFalse(guardBlock.contains("gh workflow run release.yml"))
    }

    func testLightBuildWorkflowGuardsMarketingVersionAheadOfLatestPublicRelease() throws {
        let workflow = try readSource(.lightBuildWorkflow)
        // Bounded, NOT read to EOF. `version-guard` stopped being the last job when
        // `main-red-alarm` was added below it, and an unbounded block would quietly widen every
        // assertion here to cover two jobs — the negatives especially, which would then fail on
        // a string the OTHER job is entitled to contain.
        let jobBlock = try sourceBlock(
            in: workflow, startingAt: "  version-guard:", endingBefore: "  main-red-alarm:")

        XCTAssertTrue(jobBlock.contains("uses: actions/checkout@v7"))
        // Unlike app-compile, this job must run on every PR unconditionally: no `needs:
        // changes` docs-only short-circuit, and no owned-hardware runner (LIGHT_BUILD_RUNNER
        // selects the mac VM) — it's Linux-only, so it can run for fork PRs too.
        XCTAssertFalse(jobBlock.contains("needs: changes"))
        XCTAssertFalse(jobBlock.contains("docs_only"))
        XCTAssertFalse(jobBlock.contains("LIGHT_BUILD_RUNNER"))

        let guardBlock = try sourceBlock(
            in: jobBlock,
            startingAt: "- name: Guard — MARKETING_VERSION ahead of latest public release"
        )
        XCTAssertTrue(guardBlock.contains("Config/Lava.xcconfig"))
        XCTAssertTrue(guardBlock.contains("MARKETING_VERSION"))
        XCTAssertTrue(guardBlock.contains("declared_version"))
        XCTAssertTrue(guardBlock.contains("lavasec-ios.git"))
        XCTAssertTrue(guardBlock.contains("[ \"$lowest\" = \"$declared_version\" ]"))
        // A real `git ls-remote` failure (network/DNS/GitHub outage) must fail CLOSED, not
        // be swallowed by the same fallback that covers the benign "no public tags yet"
        // case — otherwise the gate reports green without ever comparing MARKETING_VERSION.
        XCTAssertTrue(guardBlock.contains("if ! tags=\"$(git ls-remote"))
        XCTAssertTrue(guardBlock.contains("failing closed"))
    }

    /// The device/Release compile is deliberately gated off regular PRs, so `main` is the only
    /// place it reports — and on 2026-08-18 it reported red at the merge that broke it and
    /// stayed red for seven days because nothing watched. This pins the half that was missing.
    func testLightBuildAlarmsOnARedMainAndClearsOnlyOnAnUnambiguousGreen() throws {
        let workflow = try readSource(.lightBuildWorkflow)
        // Reads to EOF: `main-red-alarm` is the last job in the file. Anything added after it
        // must re-bound this the way `version-guard` above had to be re-bounded.
        let jobBlock = try sourceBlock(in: workflow, startingAt: "  main-red-alarm:")

        // `push`-only. A context reported on a pull request is the shape that deadlocked the
        // android-controller required check, and this job has no business gating a PR at all.
        // The whole `if:` line, not its parts. Both halves are stated in the comment directly
        // above them in the workflow, so a `contains("always()")` is satisfied by the PROSE and
        // survives the very edit it exists to catch — verified: swapping the real condition to
        // `failure()` left that assertion green. `always()`, not `failure()`, because the job
        // must also run on green to CLOSE the alarm.
        XCTAssertTrue(
            jobBlock.contains("if: ${{ always() && github.event_name == 'push' }}"))
        XCTAssertTrue(jobBlock.contains("needs: [changes, app-compile, wireguard-core-drift, version-guard]"))
        XCTAssertTrue(jobBlock.contains("group: light-build-main-alarm"))
        XCTAssertTrue(jobBlock.contains("cancel-in-progress: false"))
        XCTAssertTrue(jobBlock.contains("Select the current main build result"))
        XCTAssertTrue(jobBlock.contains("if: ${{ steps.relevant.outputs.current == 'true' }}"))

        // Issue mutations stay explicitly scoped; checkout is for current-source comparison.
        XCTAssertTrue(jobBlock.contains("GH_REPO: ${{ github.repository }}"))

        // Job-scoped write, so the jobs running repo code on the self-hosted runner keep
        // read-only credentials. A workflow-level `issues: write` would hand it to all of them.
        let permissionsBlock = try sourceBlock(
            in: jobBlock, startingAt: "    permissions:", endingBefore: "    runs-on:")
        XCTAssertTrue(permissionsBlock.contains("issues: write"))

        // De-duplication is by LABEL, not by title search: `gh issue list --search` reads
        // GitHub's search index, which lags writes and would open one duplicate per red push
        // during exactly the burst the de-duplication exists for.
        XCTAssertTrue(jobBlock.contains("--label \"$label\""))
        XCTAssertFalse(jobBlock.contains("in:title"))

        // Clearing requires every dependency to have SUCCEEDED. `skipped` and `cancelled` must
        // leave a standing alarm alone, as must documentation-only or unknown classification.
        // Executable ordering/health regressions live in light-build-push.test.mjs.
        XCTAssertTrue(jobBlock.contains("[ \"$DOCS_ONLY\" = false ] || all_succeeded=0"))
        XCTAssertTrue(jobBlock.contains("[ \"$result\" = \"success\" ] || all_succeeded=0"))
        XCTAssertTrue(jobBlock.contains("if [ \"$all_succeeded\" -ne 1 ]; then"))
        XCTAssertTrue(jobBlock.contains("gh issue close"))
    }

    func testInternalRCTagWorkflowRoutesNativeAndReactNativeBuilds() throws {
        let workflow = try readSource(.tagReleaseWorkflow)
        let dispatchBlock = try sourceBlock(
            in: workflow,
            startingAt: "- name: Trigger lavasec-runner builds for",
            endingBefore: nil
        )

        let executableLines = dispatchBlock
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("#") }
        var commands: [String] = []
        var lineIndex = 0

        while lineIndex < executableLines.count {
            guard executableLines[lineIndex].hasPrefix("gh workflow run ") else {
                lineIndex += 1
                continue
            }

            var commandParts: [String] = []
            repeat {
                let line = executableLines[lineIndex]
                let continues = line.hasSuffix("\\")
                commandParts.append(
                    String(continues ? line.dropLast() : line[...])
                        .trimmingCharacters(in: .whitespaces)
                )
                lineIndex += 1
                if !continues { break }
            } while lineIndex < executableLines.count

            commands.append(commandParts.joined(separator: " "))
        }

        // The executable shell regressions check which command is actually sent.
        // Keep the output-driven wait matrix bound to those selected lanes.
        XCTAssertTrue(dispatchBlock.contains("lanes=(qa)"))
        XCTAssertTrue(dispatchBlock.contains("if [ \"${#lanes[@]}\" -eq 2 ]; then"))
        XCTAssertTrue(workflow.contains("lane: ${{ fromJSON(needs.dispatch.outputs.lanes) }}"))
        XCTAssertTrue(workflow.contains("needs: dispatch"))
        XCTAssertTrue(workflow.contains("fail-fast: false"))
        XCTAssertTrue(workflow.contains("run: node scripts/wait-rc-build.mjs"))
        XCTAssertEqual(commands.count, 2)
        XCTAssertEqual(
            commands.first { $0.hasPrefix("gh workflow run release.yml ") },
            "gh workflow run release.yml --repo lavasecurity/lavasec-runner --ref main -f channel=internal -f ui=\"$ui\" -f tag=\"${GITHUB_REF_NAME}\" -f dry_run=false > \"$RUNNER_TEMP/release-url\""
        )
        XCTAssertEqual(
            commands.first { $0.hasPrefix("gh workflow run release-qa.yml ") },
            "gh workflow run release-qa.yml --repo lavasecurity/lavasec-runner --ref main -f ref=\"${GITHUB_REF_NAME}\" -f ui=\"$ui\" -f dry_run=false > \"$RUNNER_TEMP/qa-url\""
        )
    }

    func testPhoneQASurfacesAreCompileGatedOutOfRelease() throws {
        let adminQA = try readSource(.adminQAView)
        let settings = try readSource(.settingsView)
        let root = try readSource(.rootView)
        let viewModel = try readAppViewModelSource()
        // The rage-shake routing lives on DiagnosticsController since the Phase D4 peel.
        let diagnosticsController = try readSource(.diagnosticsController)
        let rageShakeQA = try readSource(.rageShakeQA)

        XCTAssertTrue(
            adminQA.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#if DEBUG || LAVA_QA_TOOLS"),
            "Device QA views should not be compiled into Release."
        )
        XCTAssertTrue(
            adminQA.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("#endif"),
            "The Admin QA file should close its Release compile gate explicitly."
        )

        // Device QA stays gated; VPN chaining is a shipping settings destination.
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
        XCTAssertTrue(try readSource(.reactNativeSettingsScreens).contains("live?.qaTools&&<Row intent=\"page\" icon=\"hammer\" title=\"Device QA\""))
        XCTAssertTrue(settings.contains("""
        #if DEBUG || LAVA_QA_TOOLS
        struct PhoneQASettingsView: View {
        """))

        XCTAssertTrue(root.contains("""
        #if DEBUG || LAVA_QA_TOOLS
                    case .phoneQA:
        """))
        XCTAssertTrue((try readSource(.reactNativeAppFlows)).contains("#if DEBUG || LAVA_QA_TOOLS"))
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
        XCTAssertTrue(viewModel.contains("#if DEBUG || LAVA_QA_TOOLS\n    @Published var adminQAStatusMessage"))
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
