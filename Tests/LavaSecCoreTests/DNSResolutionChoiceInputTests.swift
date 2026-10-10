import XCTest
import LavaSecAppServices
import LavaSecKit

final class DNSResolutionChoiceInputTests: XCTestCase {
    func testLocalizedDefaultNeverBecomesAnAuthoredNameAfterEditingAndSaving() throws {
        let choice: [String: Any] = [
            "id": DNSResolverPreset.customID, "name": "自訂 DNS", "sourceName": "",
            "primary": "https://dns.example/dns-query", "secondary": "", "isEnabled": true,
        ]
        let selection = try DNSResolutionChoiceInput.selection(from: choice)
        XCTAssertEqual(selection.name, "", "The custom editor must receive the empty authored field.")
        var configuration = AppConfiguration()
        try configuration.applyDNSResolutionSelections([selection, .init(id: DNSResolverPreset.device.id)], allowsCustom: true)
        let restored = try JSONDecoder().decode(AppConfiguration.self, from: JSONEncoder().encode(configuration))
        XCTAssertEqual(restored.customResolverName, "")
        XCTAssertEqual(restored.dnsResolutionSelections.first?.name, "")
        XCTAssertFalse(restored.dnsResolutionSelections.map(\.name).contains("自訂 DNS"))
    }

    func testSourceIdentityWinsEvenWhenItMatchesAnAppLocalizationKey() throws {
        for name in ["Save", "Custom DNS", "自訂 DNS", "  My resolver  "] {
            let selection = try DNSResolutionChoiceInput.selection(from: [
                "id": DNSResolverPreset.customID, "name": "A display label", "sourceName": name,
                "primary": "https://dns.example/dns-query", "isEnabled": false,
            ])
            XCTAssertEqual(selection.name, name)
            XCTAssertFalse(selection.isEnabled)
        }
    }

    func testOlderChoicePayloadKeepsItsOriginalSavedNameAndDefaults() throws {
        let selection = try DNSResolutionChoiceInput.selection(from: [
            "id": DNSResolverPreset.customID, "name": "Legacy resolver", "primary": "8.8.8.8",
        ])
        XCTAssertEqual(selection.name, "Legacy resolver")
        XCTAssertEqual(selection.secondary, "")
        XCTAssertTrue(selection.isEnabled)
        XCTAssertEqual(try DNSResolutionChoiceInput.selection(from: ["id": DNSResolverPreset.device.id]).name, "")
    }

    func testMalformedSourceNameCannotSilentlyBecomeTheDisplayLabel() {
        XCTAssertThrowsError(try DNSResolutionChoiceInput.selection(from: [
            "id": DNSResolverPreset.customID, "name": "自訂 DNS", "sourceName": 123,
        ]))
    }

    func testNativeChoiceProjectionAndBothEditorInputsKeepTheRawName() throws {
        let source = try String(contentsOf: packageRootURL.appendingPathComponent("ReactNative/native-app/LavaAppSettings.swift"), encoding: .utf8)
        let projection = try sourceBlock(in: source, startingAt: "func dnsChoice(", endingBefore: "func dnsResolverDisplayName(")
        XCTAssertTrue(projection.contains("\"sourceName\": selection.name"))
        let tierSave = try sourceBlock(in: source, startingAt: "func saveDNSTiers(", endingBefore: "func toggleDNSTier(")
        let customEditor = try sourceBlock(in: source, startingAt: "func editCustomDNSDraft(", endingBefore: "func customDNSState(")
        for input in [tierSave, customEditor] {
            XCTAssertTrue(input.contains("DNSResolutionChoiceInput.selection(from: $0)"))
            XCTAssertFalse(input.contains("JSONDecoder().decode"))
        }
    }
}
