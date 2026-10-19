import XCTest

final class NativeFlowTextMetricsSourceTests: XCTestCase {
    func testNativeProjectionUsesPublicSemanticFontMetricsAtTheExistingPreferredSize() throws {
        let source = try readSource(.reactNativeAppPresentation)
        XCTAssertTrue(source.contains("UITraitCollection(preferredContentSizeCategory: preferredContentSize)"))
        XCTAssertTrue(source.contains("UIFont.preferredFont(forTextStyle: style, compatibleWith: traits)"))
        XCTAssertTrue(source.contains("\"fontSize\": font.pointSize, \"lineHeight\": font.lineHeight, \"leading\": font.leading"))
        XCTAssertTrue(source.contains("\"nativeTextMetrics\": nativeTextMetrics"))
        XCTAssertFalse(source.contains("UIHostingController"))
    }

    func testOnlyMigratedIOSSemanticParagraphsConsumeLeadingAndExplicitMetricsRemainOwnedByTheCaller() throws {
        let source = try readSource(.reactNativePresentation)
        XCTAssertTrue(source.contains("Platform.OS==='ios'&&metrics==='nativeFlow'&&props.allowFontScaling!==false"))
        XCTAssertTrue(source.contains("style.lineHeight!==undefined||style.fontFamily||style.fontStyle==='italic'"))
        XCTAssertTrue(source.contains("metric.lineHeight+metric.leading"))
        XCTAssertTrue(source.contains("Math.ceil(metric.lineHeight/nativeScale*actualScale*PixelRatio.get())/PixelRatio.get()"))
        XCTAssertTrue(source.contains("props.lineBreakStrategyIOS===undefined"))
        let form = try readSource(.reactNativeFormScaffold)
        XCTAssertTrue(form.contains("useContext(WindowMetricsContext)==='nativeFlow'&&Platform.OS==='ios'"))
        XCTAssertTrue(form.contains("nativeFlow?{}:{lineHeight:metrics.lineHeight,marginVertical:-metrics.leading*scale}"))
    }
}
