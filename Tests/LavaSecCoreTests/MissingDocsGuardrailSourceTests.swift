import Foundation
import XCTest

final class MissingDocsGuardrailSourceTests: XCTestCase {
    func testStrictGuardrailUsesDedicatedPackageModuleConfiguration() throws {
        let configuration = try readSource(.swiftLintMissingDocsConfiguration)
        let includedBlock = try sourceBlock(
            in: configuration,
            startingAt: "included:\n",
            endingBefore: "excluded:\n"
        )
        XCTAssertEqual(
            yamlList(in: includedBlock),
            [
                "Sources/LavaSecKit",
                "Sources/LavaSecNetworking",
                "Sources/LavaSecDNS",
                "Sources/LavaSecFilterPipeline",
                "Sources/LavaSecPresentation",
                "Sources/LavaSecAppServices",
                // Not a layer: the chained-upstream engine wrapper sits beside them and is
                // outside the façade, but its public API is package API and carries the same
                // documentation obligation (plan D4).
                "Sources/LavaSecChainedUpstream",
            ],
            "the missing-doc ratchet must lint exactly the real package source modules"
        )

        let excludedBlock = try sourceBlock(
            in: configuration,
            startingAt: "excluded:\n",
            endingBefore: "opt_in_rules:\n"
        )
        XCTAssertEqual(
            yamlList(in: excludedBlock),
            ["Sources/LavaSecKit/Generated/DefaultCatalog+Generated.swift"],
            "only the generated catalog source may remain excluded"
        )
        let missingDocsBlock = try sourceBlock(
            in: configuration,
            startingAt: "missing_docs:\n"
        )
        XCTAssertTrue(missingDocsBlock.contains("  excludes_extensions: true"))
        XCTAssertTrue(missingDocsBlock.contains("  excludes_inherited_types: true"))
        XCTAssertTrue(missingDocsBlock.contains("  warning: [open, public]"))
        XCTAssertTrue(missingDocsBlock.contains("  excludes_trivial_init: false"))
        XCTAssertTrue(
            missingDocsBlock.contains("  evaluate_effective_access_control_level: false")
        )

        let workflow = try readSource(.iosWorkflow)
        let baselineRatchetStep = try sourceBlock(
            in: workflow,
            startingAt: "      - name: Check missing-doc baseline does not grow\n",
            endingBefore: "      - name: SwiftLint (warning-only)\n"
        )
        for environment in [
            "EVENT: ${{ github.event_name }}",
            "PR_BASE: ${{ github.event.pull_request.base.sha }}",
            "PR_HEAD: ${{ github.event.pull_request.head.sha }}",
            "PUSH_BASE: ${{ github.event.before }}",
            "PUSH_HEAD: ${{ github.sha }}",
        ] {
            XCTAssertTrue(baselineRatchetStep.contains(environment))
        }
        XCTAssertTrue(
            sourceContainsInOrder(
                [
                    "case \"$EVENT\" in",
                    "pull_request)",
                    "base=\"$PR_BASE\"",
                    "head=\"$PR_HEAD\"",
                    "push)",
                    "base=\"$PUSH_BASE\"",
                    "head=\"$PUSH_HEAD\"",
                    "*)",
                    "node scripts/check-missing-docs-baseline.mjs",
                    "exit 0",
                    "if [ -z \"$base\" ] || [ \"$base\" = \"0000000000000000000000000000000000000000\" ]; then",
                    "node scripts/check-missing-docs-baseline.mjs --base \"$base\" --head \"$head\"",
                ],
                in: baselineRatchetStep
            ),
            "PRs and pushes must compare committed ranges; manual events validate the checked-out tree."
        )

        let guardrailStep = try sourceBlock(
            in: workflow,
            startingAt: "      - name: SwiftLint missing-doc regressions (blocking)\n",
            endingBefore: "      - name: Merge-up contamination guard\n"
        )
        let args = try XCTUnwrap(
            guardrailStep.split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first { $0.hasPrefix("args: ") }
        )
        XCTAssertEqual(
            args,
            "args: swiftlint lint --config .swiftlint-missing-docs.yml --strict "
                + "--only-rule missing_docs --baseline .swiftlint-missing-docs-baseline.json "
                + "--reporter github-actions-logging",
            "the blocking lane must select the dedicated config without a positional Sources path"
        )

        // Scope these pins to the jobs that carry them: a global `contains` over the
        // whole workflow is satisfied by any occurrence anywhere and does not pin the
        // ios-simulator-build predicate or the trusted-branch admission (Kilo, PR #780).
        let repoChecksJob = try sourceBlock(
            in: workflow,
            startingAt: "  repo-checks:\n",
            endingBefore: "  swift-package-tests:\n"
        )
        XCTAssertTrue(repoChecksJob.contains("- name: Require trusted branch for native validation"))
        XCTAssertTrue(
            repoChecksJob.contains(
                "github.event.pull_request.head.repo.full_name != github.repository "
                    + "|| github.event.pull_request.user.login == 'dependabot[bot]'"
            ),
            "fork and dependency-bot PRs must be refused before native validation"
        )
        XCTAssertFalse(workflow.contains("vars.IOS_CI_MAC_RUNNER"))
        let packageTestJob = try sourceBlock(
            in: workflow,
            startingAt: "  swift-package-tests:\n",
            endingBefore: "  ios-simulator-build:\n"
        )
        // `!cancelled()` keeps the fail-safe (a failed `changes` prerequisite must not
        // skip this required context); the draft term keeps a WIP PR from queueing Mac
        // runs — `ready_for_review` re-triggers it (PR #784).
        XCTAssertTrue(
            packageTestJob.contains(
                "if: ${{ !cancelled() && github.event.pull_request.draft != true "
                    + "&& (github.repository != 'lavasecurity/lavasec-ios-internal' || github.event_name != 'pull_request' || "
                    + "(github.event.pull_request.head.repo.full_name == github.repository "
                    + "&& github.event.pull_request.user.login != 'dependabot[bot]')) }}"
            )
        )
        XCTAssertTrue(
            packageTestJob.contains(
                "github.event.pull_request.head.repo.full_name == github.repository"
            ),
            "only trusted same-repository events may execute code on owned Macs"
        )
        XCTAssertTrue(packageTestJob.contains(
            "runs-on: ${{ (github.repository == 'lavasecurity/lavasec-ios-internal' "
                + "&& (github.event_name != 'pull_request' || "
                + "(github.event.pull_request.head.repo.full_name == github.repository "
                + "&& github.event.pull_request.user.login != 'dependabot[bot]'))) "
                + "&& fromJSON('[\"self-hosted\",\"macOS\"]') || fromJSON('[\"macos-26\"]') }}"
        ), "owned runner selection must be private and trusted; public/fork lanes stay hosted")
        XCTAssertTrue(repoChecksJob.contains(
            "if: ${{ github.repository == 'lavasecurity/lavasec-ios-internal' && github.event_name == 'pull_request'"
        ), "private admission policy must not reject public hosted contributors")
        XCTAssertTrue(
            sourceContainsInOrder(
                [
                    "- name: Check Swift package boundary before build",
                    "run: python3 scripts/check-swift-package-boundary.py",
                    "- name: Test LavaSecCore",
                    "cmd=(swift test --package-path .",
                ],
                in: packageTestJob
            ),
            "the complete SwiftPM graph must be validated before plugins or sources can build"
        )

        let simulatorBuildJob = try sourceBlock(
            in: workflow,
            startingAt: "  ios-simulator-build:\n"
        )
        XCTAssertTrue(
            simulatorBuildJob.contains(
                "github.repository == 'lavasecurity/lavasec-ios' "
                    + "&& github.event.pull_request.draft != true }}"
            ),
            "the hosted simulator build runs for public PRs and skips drafts"
        )
        XCTAssertTrue(simulatorBuildJob.contains("runs-on: macos-26"))
    }

    private func yamlList(in block: String) -> [String] {
        block.split(separator: "\n").compactMap { line in
            let entry = line.trimmingCharacters(in: .whitespaces)
            guard entry.hasPrefix("- ") else { return nil }
            return String(entry.dropFirst(2))
        }
    }
}
