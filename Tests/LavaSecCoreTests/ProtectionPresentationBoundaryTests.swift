import XCTest
@testable import LavaSecCore

/// Phase 4 boundary guard: the platform-agnostic core/shared layers must not own the
/// protection-connectivity user copy or its SF Symbols. User-facing title/subtitle are
/// a per-OS presentation concern (`ProtectionConnectivityPresentation`, app-side); the
/// status glyph is resolved in the widget. Stable diagnostic tokens may stay in core.
final class ProtectionPresentationBoundaryTests: XCTestCase {
    func testConnectivityCopyDoesNotOriginateInCore() throws {
        let policy = try readSource(.protectionConnectivityPolicy)
        for copy in ["Network Lost", "DNS Slow", "Reconnect Needed",
                     "Filtering happens locally", "A DNS check failed"] {
            XCTAssertFalse(policy.contains(copy), "User copy '\(copy)' still in the core policy")
        }
        XCTAssertFalse(policy.contains("let title: String"))
        XCTAssertFalse(policy.contains("let subtitle: String"))
        // A stable, locale-independent diagnostic token IS allowed in core.
        XCTAssertTrue(policy.contains("var diagnosticLabel: String"))
    }

    func testConnectivityCopyLivesAppSideAndIsExhaustive() throws {
        let pres = try readSource(.protectionConnectivityPresentation)
        for severity in ["healthy", "recovering", "usingDeviceDNSFallback",
                         "usingEncryptedFallback", "dnsSlow", "networkUnavailable", "needsReconnect"] {
            XCTAssertTrue(pres.contains("case .\(severity)"), "presentation missing severity .\(severity)")
        }
        XCTAssertTrue(pres.contains("\"No connection\""))
        XCTAssertTrue(pres.contains("Filtering happens locally on this device."))
        XCTAssertTrue(pres.contains("Filtering is on using your device's DNS."))
        XCTAssertTrue(pres.contains("Filtering is on using encrypted backup DNS."))
        XCTAssertTrue(pres.contains("A DNS check failed. Lava is retrying."))
    }

    func testSetupReadinessDoesNotClaimVPNForwardingSuccess() throws {
        let titles = try readSource(.protectionShortcuts)
        XCTAssertTrue(titles.contains("case .tunnelReady: \"Checking VPN\""))
        XCTAssertFalse(titles.contains("\"VPN setup ready\""))
        XCTAssertTrue(titles.contains("case .vpnRecovering: \"Reconnecting VPN\""))
        let viewModel = try readAppViewModelSource()
        XCTAssertTrue(viewModel.contains("Waiting for traffic to confirm VPN forwarding."))
    }

    func testErrorNoticeCannotLeaveHealthyGuardTitleProtected() throws {
        let viewModel = try readAppViewModelSource()
        let title = try sourceBlock(
            in: viewModel,
            startingAt: "var protectionTitle: String {",
            endingBefore: "var guardStatusPresentation: GuardStatusPresentation {"
        )
        XCTAssertTrue(title.contains("guardStatusPresentation.title"))
        let titles = try readSource(.protectionShortcuts)
        XCTAssertTrue(titles.contains("case .needsAttention: \"Needs attention\""))
    }

    func testCurrentErrorNoticeStaysVisibleDuringNetworkOutage() throws {
        let viewModel = try readAppViewModelSource()
        let subtitle = try sourceBlock(
            in: viewModel,
            startingAt: "var protectionSubtitle: String {",
            endingBefore: "var protectionButtonTitle: String {"
        )
        XCTAssertTrue(subtitle.contains("if guardNetworkUnavailableOverridesNotice"))
        XCTAssertTrue(subtitle.contains("if let notice { return notice.message }"))
        let presentation = try sourceBlock(
            in: viewModel,
            startingAt: "var guardStatusPresentation: GuardStatusPresentation {",
            endingBefore: "var protectionSubtitle: String {"
        )
        XCTAssertTrue(presentation.contains("guardPanelMessageSelection?.isChainedFailureMarker ?? true"))
        XCTAssertTrue(presentation.contains("hasErrorNotice: guardPanelMessageIsError && !guardNetworkUnavailableOverridesNotice"))
        let selection = try sourceBlock(
            in: viewModel,
            startingAt: "private var guardPanelMessageSelection:",
            endingBefore: "var guardPanelMessage: String? {"
        )
        XCTAssertTrue(selection.contains("selected.source == .lifecycleNotice"))
        XCTAssertTrue(selection.contains("chainedLifecycleNotice == nil"))
    }

    func testStatusGlyphsDoNotOriginateInSharedModel() throws {
        let attributes = try readSource(.lavaActivityAttributes)
        XCTAssertFalse(attributes.contains("statusSymbolName"))
        for glyph in ["\"checkmark\"", "\"pause.fill\"", "\"wifi.slash\"",
                      "\"arrow.triangle.2.circlepath\"", "\"exclamationmark.triangle.fill\""] {
            XCTAssertFalse(attributes.contains(glyph), "SF Symbol \(glyph) still in the shared model")
        }
        let widget = try readSource(.lavaSecWidget)
        XCTAssertTrue(widget.contains("func statusSymbolName(for protectionState:"))
    }

    func testViewModelTintUsesRolesNotRawColors() throws {
        // Phase 3: protectionTint resolves through ProtectionTintRole; no raw,
        // non-adaptive SwiftUI status colors leak out of the view model.
        let vm = try readAppViewModelSource()
        XCTAssertTrue(vm.contains("var protectionTintRole: ProtectionTintRole"))
        XCTAssertTrue(vm.contains("protectionTintRole.color"))
        XCTAssertFalse(vm.contains("return .green"))
        XCTAssertFalse(vm.contains("return .orange"))
        XCTAssertFalse(vm.contains("return .red"))
        let pres = try readSource(.protectionConnectivityPresentation)
        XCTAssertTrue(pres.contains("extension ProtectionTintRole"))
        XCTAssertTrue(pres.contains("var color: Color"))
    }

    func testIconSwapAndLiveActivityReachedThroughProtocols() throws {
        // Phase 6: rewrite-class iOS features are behind protocols (Android conforms natively).
        let seams = try readSource(.protectionPlatformSeams)
        XCTAssertTrue(seams.contains("protocol IconPersonalizing"))
        XCTAssertTrue(seams.contains("protocol AmbientProtectionPresenter"))
        XCTAssertTrue(seams.contains("struct UIKitIconPersonalizer: IconPersonalizing"))
        let controller = try readSource(.lavaLiveActivityController)
        XCTAssertTrue(controller.contains("final class LavaLiveActivityController: AmbientProtectionPresenter"))
        let vm = try readAppViewModelSource()
        // The icon-personalizer seam moved to CustomizationController with the icon
        // sync (Phase D5 peel); the Live Activity presenter stays hub-owned.
        let customization = try readSource(.customizationController)
        XCTAssertTrue(customization.contains("private let iconPersonalizer: IconPersonalizing"))
        XCTAssertTrue(vm.contains("let liveActivityController: AmbientProtectionPresenter"))
        // Neither the hub nor the controller calls UIKit's alternate-icon API directly.
        XCTAssertFalse(vm.contains("UIApplication.shared.setAlternateIconName"))
        XCTAssertFalse(customization.contains("UIApplication.shared.setAlternateIconName"))
        XCTAssertTrue(customization.contains("iconPersonalizer.setAppIcon"))
        // Canary: the negative pins above key on these identifiers - if a rename removes
        // one from the pinned source, those pins pass vacuously. Fail here instead, then
        // re-anchor both sides to the new name.
        XCTAssertTrue(seams.contains("setAlternateIconName"))
    }

    // MARK: - The unconfirmed-chained surface's precedence

    /// The unconfirmed surface speaks ONLY over severities that would otherwise read "all good".
    ///
    /// It exists to stop the card saying "Protected" over a chain carrying nothing — not to outrank
    /// a real report. Unlike the connect window's establishing flag it has NO deadline, and on a
    /// split tunnel with an idle tailnet it is the steady state, so an unconditional win masks the
    /// other surfaces indefinitely.
    func testTheUnconfirmedSurfaceOnlySpeaksOverAnAllGoodSeverity() {
        let allGood: [ProtectionConnectivitySeverity] =
            [.healthy]
        for severity in allGood {
            XCTAssertTrue(
                severity.yieldsToUnconfirmedChainedForwarding,
                "\(severity) reads as protected, which is exactly the claim the unconfirmed "
                    + "surface exists to withhold")
        }
    }

    /// 🔴 AND IT YIELDS TO EVERY SEVERITY THAT IS ITSELF A REPORT.
    ///
    /// `.networkUnavailable` is the sharpest: with no network no forwarded byte can ever arrive, so
    /// an unconditional unconfirmed surface would mask "Network Lost" FOREVER — and the card would
    /// contradict itself, because `protectionButtonTitle` is not masked and would offer Reconnect
    /// under a title that never mentions it (pre-push panel, PR #629).
    func testTheUnconfirmedSurfaceYieldsToEveryRealReport() {
        let reporting: [ProtectionConnectivitySeverity] =
            [.networkUnavailable, .needsReconnect, .dnsSlow, .recovering,
             .usingDeviceDNSFallback, .usingEncryptedFallback]
        for severity in reporting {
            XCTAssertFalse(
                severity.yieldsToUnconfirmedChainedForwarding,
                "\(severity) has something of its own to tell the user, and no forwarded byte is "
                    + "guaranteed to ever arrive to clear the surface masking it")
        }
    }
}
