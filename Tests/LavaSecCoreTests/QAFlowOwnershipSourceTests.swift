import XCTest

/// These pins guard the cross-runtime confidentiality/admission boundary. Visit
/// ordering itself is exercised by QAPresentationVisitLifetimeTests.
final class QAFlowOwnershipSourceTests: XCTestCase {
    func testVerificationRetainsPlainNativeToggleAnatomyAndAuthoritativeProjection() throws {
        // AdminQAView ec1b3be9:450 uses an unstyled SwiftUI Toggle; unlike
        // LavaToggleRow it inherits body text and adds no row floor or insets.
        let renderer = try readSource(.reactNativeQAFlow)
        XCTAssertTrue(renderer.contains("<FlowConsentToggle testID=\"qa.verified\""))
        XCTAssertTrue(renderer.contains("value={!!state.verified}"))
        XCTAssertTrue(renderer.contains("labelColor={port.labelColor??colors.primaryText}"))
        XCTAssertTrue(renderer.contains("disabled={!state.prepared||!state.configurationMatches}"))
        XCTAssertTrue(renderer.contains("onChange={value=>port.send({action:'verified',value})}"))
        XCTAssertFalse(renderer.contains("<Toggle title=\"I verified"))
        let adapter = try readSource(.reactNativeQAFlowAdapter)
        XCTAssertTrue(adapter.contains("labelColor:PlatformColor('label')"))
    }

    func testConfigurationSecretIsNativeAndOnlyReadinessCrossesTheProjection() throws {
        let source = try readSource(.reactNativeAppQA)
        let projection = try sourceBlock(in: source, startingAt: "func projection()", endingBefore: "func command(")
        XCTAssertTrue(projection.contains("\"hasConfiguration\": !chainedUpstreamConf.trimmingCharacters"))
        XCTAssertEqual(projection.components(separatedBy: "chainedUpstreamConf").count - 1, 1)
        XCTAssertFalse(projection.contains("\"configuration\":"))
        let editor = try sourceBlock(in: source, startingAt: "final class LavaQAConfigurationContent", endingBefore: "#endif")
        XCTAssertTrue(editor.contains("owner.chainedUpstreamConf = textView.text"))
        XCTAssertTrue(editor.contains("owner?.current == true"))
        XCTAssertTrue(editor.contains("textView.text = \"\"; textView.isHidden = true"))
        XCTAssertTrue(editor.contains("mayInteract?() == true && super.canPerformAction"))
    }

    func testCommandsRecheckVisitAndDetailAfterAuthentication() throws {
        let source = try readSource(.reactNativeAppQA)
        let command = try sourceBlock(in: source, startingAt: "func qaCommand(", endingBefore: "func presentQAMockOnboarding()")
        let authorization = try XCTUnwrap(command.range(of: "try await authorize(surface,")?.lowerBound)
        let visitCheck = try XCTUnwrap(command.range(of: "qaSession === ownerBeforeAuthentication", range: authorization..<command.endIndex)?.lowerBound)
        let detailCheck = try XCTUnwrap(command.range(of: "owner.admits(action, input: input)", range: visitCheck..<command.endIndex)?.lowerBound)
        let dispatch = try XCTUnwrap(command.range(of: "await owner.command(action, input)")?.lowerBound)
        XCTAssertLessThan(authorization, visitCheck)
        XCTAssertLessThan(visitCheck, detailCheck)
        XCTAssertLessThan(detailCheck, dispatch)
        XCTAssertTrue(command.contains("lifetime.admit(id: id, ticket: ticket)"))
        let renderer = try readSource(.reactNativeQAFlowAdapter)
        XCTAssertTrue(renderer.contains("current.detail?.id!==detail?.id"))
        XCTAssertTrue(renderer.contains("detail:detail.id"))
    }

    func testRageShakeAndSettingsRetainTheirOriginalScopesAndTeardownDoesNotAuthenticate() throws {
        let source = try readSource(.reactNativeAppQA)
        XCTAssertTrue(source.contains("flow?.name == \"phoneQASheet\" ? .appUnlock : .appSettings"))
        XCTAssertTrue(source.contains("flow?.showWelcome"))
        let command = try sourceBlock(in: source, startingAt: "func qaCommand(", endingBefore: "func presentQAMockOnboarding()")
        let cleanup = try XCTUnwrap(command.range(of: "if action == \"leave\" || action == \"close\"")?.lowerBound)
        let authorization = try XCTUnwrap(command.range(of: "try await authorize(surface,")?.lowerBound)
        XCTAssertLessThan(cleanup, authorization)
        XCTAssertTrue(command.contains("retireQASession(id: id)"))
    }

    func testQAFlowReplacesAStillMountedPushedVisitBeforeModalEntry() throws {
        let bridge = try readSource(.reactNativeAppBridge)
        let flowSetter = try sourceBlock(in: bridge, startingAt: "@Published var flow:", endingBefore: "var closingForegroundIDs")
        XCTAssertTrue(flowSetter.contains("[\"phoneQA\", \"phoneQASheet\"].contains(flow.name)"))
        XCTAssertTrue(flowSetter.contains("retireQAForNewFlow(id: flow.id.uuidString)"))
        let qa = try readSource(.reactNativeAppQA)
        XCTAssertTrue(qa.contains("LavaQAVisitAdmissions.lifetime.retireSuperseded(by: id)"))
        XCTAssertTrue(qa.contains("if let owner = qaSession, owner.id != id { owner.retire(); qaSession = nil }"))
    }
}
