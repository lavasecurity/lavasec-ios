import XCTest

final class LavaActionButtonSourceTests: XCTestCase {
    func testEveryFullWidthRoleDelegatesThroughNativeButtonToTheSharedBody() throws {
        let scaffold = try readSource(.lavaScaffold)
        let components = try readSource(.lavaComponents)
        let wrappers = [
            (try sourceBlock(in: scaffold, startingAt: "struct LavaStandaloneActionButtonStyle:",
                             endingBefore: "struct LavaCondensedRowButtonStyle:"), "primary"),
            (try sourceBlock(in: components, startingAt: "struct LavaPanelActionButtonStyle:",
                             endingBefore: "struct LavaSecondaryActionButtonStyle:"), "panel"),
            (try sourceBlock(in: components, startingAt: "struct LavaSecondaryActionButtonStyle:",
                             endingBefore: "struct LavaToggleRow:"), "secondary")
        ]
        for (wrapper, role) in wrappers {
            XCTAssertTrue(wrapper.contains(": PrimitiveButtonStyle"), role)
            XCTAssertTrue(wrapper.contains("LavaFullWidthActionPrimitiveStyle(role: .\(role)"), role)
            XCTAssertTrue(wrapper.contains(".makeBody(configuration: configuration)"), role)
            for duplicate in [".font(", ".padding(", ".frame(", ".background", ".foregroundStyle", ".scaleEffect", "@Environment"] {
                XCTAssertFalse(wrapper.contains(duplicate), "\(role) must delegate \(duplicate) to the installed shared body.")
            }
        }
        XCTAssertTrue(wrappers[1].0.contains("cornerRadius: cornerRadius"), "Existing optional panel geometry remains compatible.")
        let primitive = try sourceBlock(in: scaffold,
                                        startingAt: "struct LavaFullWidthActionPrimitiveStyle:",
                                        endingBefore: "private struct LavaFullWidthActionVisualStyle:")
        XCTAssertTrue(primitive.contains("Button(configuration)"), "The shared owner must retain the native button configuration.")
        XCTAssertTrue(primitive.contains(".buttonStyle(LavaFullWidthActionVisualStyle(role: role, cornerRadius: cornerRadius))"))
        let visual = try sourceBlock(in: scaffold,
                                     startingAt: "private struct LavaFullWidthActionVisualStyle:",
                                     endingBefore: "struct LavaStandaloneActionButtonStyle:")
        XCTAssertTrue(visual.contains(": ButtonStyle"))
        XCTAssertTrue(visual.contains("LavaFullWidthActionButtonBody(role: role, isPressed: configuration.isPressed"))
        XCTAssertTrue(visual.contains("cornerRadius: cornerRadius, label: configuration.label"))
    }

    func testSharedBodyOwnsNativeEnvironmentAndContentGrowingGeometry() throws {
        let body = try sourceBlock(in: try readSource(.lavaScaffold),
                                   startingAt: "struct LavaFullWidthActionButtonBody<",
                                   endingBefore: "struct LavaFullWidthActionPrimitiveStyle:")
        XCTAssertTrue(body.contains("@Environment(\\.isEnabled) private var isEnabled"))
        XCTAssertTrue(body.contains("@Environment(\\.accessibilityReduceMotion) private var reduceMotion"))
        XCTAssertTrue(body.contains("LavaFullWidthActionState(role: role, isEnabled: isEnabled, isPressed: isPressed)"))
        XCTAssertTrue(body.contains(".font(LavaTypography.actionLabel)"))
        XCTAssertTrue(body.contains(".fixedSize(horizontal: false, vertical: true)"))
        XCTAssertTrue(body.contains(".padding(.horizontal, LavaRowHeight.horizontalInset)"))
        XCTAssertTrue(body.contains(".padding(.vertical, LavaRowHeight.verticalInset)"))
        XCTAssertTrue(body.contains(".frame(minHeight: LavaSurface.actionButtonHeight)"))
        XCTAssertTrue(body.contains(".animation(LavaFlowTransition.incidental(.easeOut(duration: 0.12), reduceMotion: reduceMotion), value: state.isPressed)"))
        for truncation in [".lineLimit(", ".minimumScaleFactor(", ".frame(height:", ".clipped("] {
            XCTAssertFalse(body.contains(truncation), "Every action role must grow for wrapped translations and large text.")
        }
    }
}
