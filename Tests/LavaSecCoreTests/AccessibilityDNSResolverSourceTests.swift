import XCTest

/// The RN catalog consumes native provider names/transport metadata and keeps
/// the same ordinary row accessibility owner as the rest of the application.
final class AccessibilityDNSResolverSourceTests: XCTestCase {
    func testPresetProviderRowExposesNameLabelAndAddressValue() throws {
        let source = try readSource(.reactNativeDNSScreen)
        XCTAssertTrue(source.contains("verbatimTitle title={choice.name} metadata={choice.metadata}"))
        XCTAssertTrue(source.contains("selected={!!selected&&sameDNS(choice,selected)}"))
    }
    func testCustomResolverUsesTheSameRowAndNativeDraftOwner() throws {
        let source = try readSource(.reactNativeDNSScreen)
        XCTAssertTrue(source.contains("...(custom?[custom]:[])"))
        XCTAssertTrue(source.contains("type:'dns.customDraft',choice:custom"))
    }
    func testProviderCatalogKeepsNativeTransportOrder() throws {
        let source = try readSource(.reactNativeDNSScreen)
        XCTAssertTrue(source.contains("['Device','DoH','DoT','IP','DoQ']"))
        XCTAssertTrue(source.contains("categoryTitles="))
    }
}
