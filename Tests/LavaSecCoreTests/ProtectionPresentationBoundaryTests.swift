import XCTest

/// Phase 4 boundary guard: the platform-agnostic core/shared layers must not own the
/// protection-connectivity user copy or its SF Symbols. User-facing title/subtitle are
/// a per-OS presentation concern (`ProtectionConnectivityPresentation`, app-side); the
/// status glyph is resolved in the widget. Stable diagnostic tokens may stay in core.
final class ProtectionPresentationBoundaryTests: XCTestCase {
    func testConnectivityCopyDoesNotOriginateInCore() throws {
        let policy = try readSource(.protectionConnectivityPolicy)
        for copy in ["Network Lost", "DNS Slow", "Reconnect Needed",
                     "Filtering happens locally", "Connection changed, refreshing"] {
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
        XCTAssertTrue(pres.contains("\"Network Lost\""))
        XCTAssertTrue(pres.contains("\"Filtering happens locally on this phone\""))
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
        let vm = try readSource(.appViewModel)
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
        let vm = try readSource(.appViewModel)
        XCTAssertTrue(vm.contains("private let iconPersonalizer: IconPersonalizing"))
        XCTAssertTrue(vm.contains("private let liveActivityController: AmbientProtectionPresenter"))
        // The view model no longer calls UIKit's alternate-icon API directly.
        XCTAssertFalse(vm.contains("UIApplication.shared.setAlternateIconName"))
        XCTAssertTrue(vm.contains("iconPersonalizer.setAppIcon"))
        // Canary: the negative pins above key on these identifiers - if a rename removes
        // one from the pinned source, those pins pass vacuously. Fail here instead, then
        // re-anchor both sides to the new name.
        XCTAssertTrue(seams.contains("setAlternateIconName"))
    }
}
