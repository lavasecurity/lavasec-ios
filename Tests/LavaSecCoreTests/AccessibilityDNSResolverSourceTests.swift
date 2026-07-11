import XCTest

/// Source guardrails for the DNS Resolver provider-selection accessibility slice (plan WS-S).
/// These pin the accessibility modifiers AS TEXT because the app target sits outside the SPM
/// test target (same regime as the other `*SourceTests`). They assert presence/structure and
/// ordering only for the markers this slice added — runtime VoiceOver focus order and spoken
/// output are covered by the plan's device-QA gates, not here.
final class AccessibilityDNSResolverSourceTests: XCTestCase {

    /// The primary provider picker inside `DNSResolverSettingsView` — the "DNS Providers"
    /// section (uniquely identified by its footer) up to the custom-resolver editor.
    private func providerPickerSource() throws -> String {
        try sourceBlock(
            in: try readSource(.dnsResolverSettingsView),
            startingAt: "LavaSectionGroup(\"DNS Providers\", footer: \"A provider answers",
            endingBefore: "if showsCustomResolverOptions"
        )
    }

    func testPresetProviderRowExposesNameLabelAndAddressValue() throws {
        let block = try providerPickerSource()
        XCTAssertTrue(
            block.contains(".accessibilityLabel(preset.displayName.lavaLocalized)"),
            "Each preset provider row must lead with the provider name as its VoiceOver label."
        )
        XCTAssertTrue(
            block.contains(".accessibilityValue(metadata(for: preset).lavaLocalized)"),
            "Each preset provider row must carry its transport-address summary as the VoiceOver value."
        )
    }

    func testCustomResolverRowExposesNameLabelAndMetadataValue() throws {
        let block = try providerPickerSource()
        XCTAssertTrue(
            block.contains(".accessibilityLabel(\"Custom DNS\".lavaLocalized)"),
            "The Custom DNS row must lead with a stable 'Custom DNS' VoiceOver label."
        )
        XCTAssertTrue(
            block.contains(".accessibilityValue(customResolverMetadata.lavaLocalized)"),
            "The Custom DNS row must carry its address/status summary as the VoiceOver value."
        )
    }

    /// Within each row the label must precede the value, and the preset provider rows must come
    /// before the trailing Custom DNS row — the same top-to-bottom order the picker renders.
    func testProviderRowAccessibilityOrdering() throws {
        let block = try providerPickerSource()

        let presetLabel = try XCTUnwrap(block.range(of: ".accessibilityLabel(preset.displayName.lavaLocalized)"))
        let presetValue = try XCTUnwrap(block.range(of: ".accessibilityValue(metadata(for: preset).lavaLocalized)"))
        let customLabel = try XCTUnwrap(block.range(of: ".accessibilityLabel(\"Custom DNS\".lavaLocalized)"))
        let customValue = try XCTUnwrap(block.range(of: ".accessibilityValue(customResolverMetadata.lavaLocalized)"))

        XCTAssertTrue(
            presetLabel.lowerBound < presetValue.lowerBound,
            "The preset row's accessibility label must be declared before its value."
        )
        XCTAssertTrue(
            presetValue.lowerBound < customLabel.lowerBound,
            "The preset provider rows must precede the trailing Custom DNS row."
        )
        XCTAssertTrue(
            customLabel.lowerBound < customValue.lowerBound,
            "The Custom DNS row's accessibility label must be declared before its value."
        )
    }
}
