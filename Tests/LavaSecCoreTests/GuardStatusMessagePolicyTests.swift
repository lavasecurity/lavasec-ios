import XCTest
@testable import LavaSecCore

final class GuardStatusMessagePolicyTests: XCTestCase {
    func testEmptyNoticesFallBackToTheUnderlyingState() {
        for text in [nil, "", " \n\t", "\u{00a0}"] as [String?] {
            for chainingEnabled in [false, true] {
                XCTAssertNil(GuardStatusMessagePolicy.select(
                    chainingEnabled: chainingEnabled, setupIssue: text, errorMessage: text,
                    settingsApplyError: text, lifecycleNotice: text, permissionMessage: text))
            }
        }
    }

    func testBlankHigherPriorityNoticesDoNotHideActionableDetails() {
        let detail = "  Resolver rejected the request.\nTry another provider.  "
        let result = GuardStatusMessagePolicy.select(
            chainingEnabled: true, setupIssue: " ", errorMessage: "\n",
            settingsApplyError: detail, lifecycleNotice: "Retrying", permissionMessage: "Allow VPN")
        XCTAssertEqual(result?.text, detail, "Operational detail must stay verbatim")
        XCTAssertEqual(result?.isError, true)
        XCTAssertEqual(result?.source, .settingsApplyError)
        let permission = GuardStatusMessagePolicy.select(
            chainingEnabled: false, setupIssue: nil, errorMessage: nil,
            settingsApplyError: "", lifecycleNotice: "\t", permissionMessage: "Allow VPN")
        XCTAssertEqual(permission?.text, "Allow VPN")
        XCTAssertEqual(permission?.isError, false)
        XCTAssertEqual(permission?.source, .permissionMessage)
    }

    func testEligibilityRevocationRetiresOnlyItsSetupFailure() {
        let issue = "Add a configuration"
        XCTAssertNil(GuardStatusMessagePolicy.select(
            chainingEnabled: false, setupIssue: issue, errorMessage: issue,
            settingsApplyError: nil, lifecycleNotice: nil, permissionMessage: nil))
        let unrelated = GuardStatusMessagePolicy.select(
            chainingEnabled: false, setupIssue: issue, errorMessage: "Could not save settings",
            settingsApplyError: nil, lifecycleNotice: nil, permissionMessage: nil)
        XCTAssertEqual(unrelated?.text, "Could not save settings")
        XCTAssertEqual(unrelated?.isError, true)
    }

    func testFailedDisableReconnectStaysVisibleWithChainingOff() {
        let result = GuardStatusMessagePolicy.select(
            chainingEnabled: false, setupIssue: "Missing key", errorMessage: "Missing key",
            settingsApplyError: "Could not reconnect", lifecycleNotice: nil, permissionMessage: nil)
        XCTAssertEqual(result?.text, "Could not reconnect")
        XCTAssertEqual(result?.isError, true)
    }

    func testActiveSetupIssueOutranksAGenericRetryLoop() {
        let result = GuardStatusMessagePolicy.select(
            chainingEnabled: true, setupIssue: "Load configuration", errorMessage: "Turn Guard on to retry",
            settingsApplyError: nil, lifecycleNotice: "Connection failed", permissionMessage: nil)
        XCTAssertEqual(result?.text, "Load configuration")
        XCTAssertEqual(result?.source, .setupIssue)
    }

    func testGeneralErrorsLifecycleAndPermissionKeepTheirPriorityAndMeaning() {
        let error = GuardStatusMessagePolicy.select(
            chainingEnabled: false, setupIssue: nil, errorMessage: "Save failed",
            settingsApplyError: nil, lifecycleNotice: "Connection failed", permissionMessage: "Allow VPN")
        XCTAssertEqual(error?.text, "Save failed")
        XCTAssertEqual(error?.source, .errorMessage)
        let lifecycle = GuardStatusMessagePolicy.select(
            chainingEnabled: false, setupIssue: nil, errorMessage: nil,
            settingsApplyError: nil, lifecycleNotice: "Connection failed", permissionMessage: "Allow VPN")
        XCTAssertEqual(lifecycle?.text, "Connection failed")
        XCTAssertEqual(lifecycle?.isError, true)
        XCTAssertEqual(lifecycle?.source, .lifecycleNotice)
        let permission = GuardStatusMessagePolicy.select(
            chainingEnabled: false, setupIssue: nil, errorMessage: nil,
            settingsApplyError: nil, lifecycleNotice: nil, permissionMessage: "Allow VPN")
        XCTAssertEqual(permission?.text, "Allow VPN")
        XCTAssertEqual(permission?.isError, false)
        XCTAssertNil(GuardStatusMessagePolicy.select(
            chainingEnabled: false, setupIssue: nil, errorMessage: nil,
            settingsApplyError: nil, lifecycleNotice: nil, permissionMessage: nil))
    }
}
