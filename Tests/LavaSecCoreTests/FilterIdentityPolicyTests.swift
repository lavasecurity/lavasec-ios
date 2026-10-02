import XCTest
@testable import LavaSecKit

final class FilterIdentityPolicyTests: XCTestCase {
    func testIdentityDraftTracksBothFieldsAndRevertedOrCanonicallyEquivalentEdits() {
        let savedName = "Café"
        let savedEmoji = "👩🏽‍💻"
        for (name, emoji, changed) in [
            (savedName, savedEmoji, false), ("Home", savedEmoji, true),
            (savedName, "👨‍👩‍👧‍👦", true), ("Home", "🌿", true),
            ("", savedEmoji, true), (savedName, "", true),
            ("Café ", savedEmoji, true), ("Cafe\u{301}", savedEmoji, false),
        ] {
            XCTAssertEqual(FilterIdentityPolicy.hasUnsavedChanges(name: name, emoji: emoji, savedName: savedName, savedEmoji: savedEmoji), changed)
        }
        var name = "Home", emoji = "🌿"
        name = savedName
        XCTAssertTrue(FilterIdentityPolicy.hasUnsavedChanges(name: name, emoji: emoji, savedName: savedName, savedEmoji: savedEmoji))
        emoji = savedEmoji
        XCTAssertFalse(FilterIdentityPolicy.hasUnsavedChanges(name: name, emoji: emoji, savedName: savedName, savedEmoji: savedEmoji))
    }
    func testCommittedEmojiReplacesWithLastCompleteGraphemeAndPreservesInvalidInputFallback() {
        XCTAssertEqual(FilterIdentityPolicy.committedEmoji("🌿🍐", fallback: "🌿"), "🍐")
        XCTAssertEqual(FilterIdentityPolicy.committedEmoji("👨‍👩‍👧‍👦", fallback: "🍐"), "👨‍👩‍👧‍👦")
        XCTAssertEqual(FilterIdentityPolicy.committedEmoji("text", fallback: "🍐"), "🍐")
        XCTAssertEqual(FilterIdentityPolicy.committedEmoji("", fallback: "🍐"), "")
    }
    func testNamesValidateAfterUnicodeCompositionWithoutRewritingLegacyRecords() throws {
        for name in ["My filter 2", "日本語 １２", "Cafe\u{301}", "حماية", "फ़िल्टर"] {
            XCTAssertTrue(FilterIdentityPolicy.isValidName(name), name)
        }
        for name in ["", "   ", "My-filter", "Filter 🌿", "Line\nTwo", "\u{301}", "A\u{200B}B", "\nName\n"] {
            XCTAssertFalse(FilterIdentityPolicy.isValidName(name), name)
        }
        XCTAssertEqual(FilterIdentityPolicy.normalizedName("  Cafe\u{301} "), "Café")
        let legacy = try JSONDecoder().decode(Filter.self, from: Data(#"{"id":"old","name":"Dad's filter!"}"#.utf8))
        XCTAssertEqual(legacy.name, "Dad's filter!")
        XCTAssertTrue(FilterIdentityPolicy.isValidEmoji(legacy.emoji))
        XCTAssertEqual(legacy.emoji, try JSONDecoder().decode(Filter.self, from: JSONEncoder().encode(legacy)).emoji)
    }
    func testEmojiOnlyEditPreservesLegacyNameButActualRenamesRemainStrict() throws {
        for saved in ["Work / Travel", "Dad's filter!", "Cafe\u{301}!", "Work\nTravel"] {
            let resolved = try XCTUnwrap(FilterIdentityPolicy.nameForEdit(saved, savedName: saved))
            XCTAssertEqual(Array(resolved.utf8), Array(saved.utf8))
            XCTAssertNil(FilterIdentityPolicy.nameForEdit(saved + "!", savedName: saved))
            XCTAssertNil(FilterIdentityPolicy.nameForEdit("", savedName: saved))
            XCTAssertEqual(FilterIdentityPolicy.nameForEdit("  Cafe\u{301}  ", savedName: saved), "Café")
        }
        XCTAssertFalse(FilterIdentityPolicy.isValidName("Work / Travel"), "New filter names remain strict.")
        XCTAssertNil(FilterIdentityPolicy.nameForEdit("Other / Travel", savedName: "Work / Travel"))
        let stored = "Cafe\u{301}!"
        let equivalent = try XCTUnwrap(FilterIdentityPolicy.nameForEdit("Café!", savedName: stored))
        XCTAssertEqual(Array(equivalent.utf8), Array(stored.utf8))
        let filter = Filter(id: "legacy", name: "Work / Travel", emoji: "🌿")
        let library = FilterLibrary(filters: [filter, Filter(id: "other", name: "Other")], activeFilterID: filter.id)
        let access = FilterLibraryAccessPolicy(library: library, maximumFilters: 3)
        XCTAssertTrue(access.isNameAvailable(filter.name, excluding: filter.id))
        XCTAssertFalse(access.isNameAvailable("Other", excluding: filter.id))
    }

    func testExactlyOneComposedEmojiIncludingUserChosenFlagsAndModifiers() {
        for emoji in ["🌱", "⚖️", "🧰", "👨‍👩‍👧‍👦", "👩🏽‍💻", "🇯🇵", "1️⃣", "☕️"] {
            XCTAssertTrue(FilterIdentityPolicy.isValidEmoji(emoji), emoji)
        }
        for emoji in ["", "1", "A", "#", "🌱🌿", "🌱 ", "e\u{301}", "\u{200D}", "😀‍", "🏽", "🇯"] {
            XCTAssertFalse(FilterIdentityPolicy.isValidEmoji(emoji), emoji)
        }
    }
    func testIdentityStaysInPortableLibraryButV2ShareCarriesRulesAndExceptions() throws {
        let original = Filter(id:"personal", name:"Work", emoji:"👩🏽‍💻", blockedDomains:["example.com"], allowedDomains:["private.example"], lastCompiledToken:"local")
        let backup = try JSONDecoder().decode(Filter.self, from: JSONEncoder().encode(original.strippingLocalCacheState()))
        XCTAssertEqual(backup.emoji, original.emoji)
        XCTAssertNil(backup.lastCompiledToken)
        let shared = ShareableFilterConfiguration(filter:original)
        let decoded = try ShareableFilterConfiguration.decode(configurationCode:shared.encodedConfigurationCode())
        XCTAssertNil(decoded.emoji)
        let json = String(data:try JSONEncoder().encode(decoded),encoding:.utf8)!
        XCTAssertTrue(json.contains("private.example"))
        XCTAssertFalse(json.contains("Work"))
        var changed = original; changed.emoji = "🧰"; changed.name = "Home"
        XCTAssertTrue(original.hasSameFilterScopedFields(as:changed))
    }
    func testDefaultsAreStableAndValid() {
        XCTAssertEqual(Filter(name:"Core").emoji,"🌱")
        XCTAssertEqual(Filter(name:"Balanced").emoji,"🪴")
        XCTAssertEqual(Filter(name:"Extra").emoji,"💐")
        for index in 0..<100 { XCTAssertTrue(FilterIdentityPolicy.isValidEmoji(Filter(id:"id-\(index)", name:"Custom").emoji)) }
    }
    func testSetupDefaultsMatchSeededIdentityAndSavedChoicesRemainUntouched() throws {
        for (level, emoji) in zip(OnboardingProtectionLevel.allCases, ["🌱", "🪴", "💐"]) {
            XCTAssertEqual(level.emoji, emoji)
            XCTAssertEqual(level.seededFilter().emoji, emoji)
        }
        for emoji in ["🍐", "🍍", "👩🏽‍💻"] {
            let saved = Filter(name: "Balanced", emoji: emoji)
            XCTAssertEqual(try JSONDecoder().decode(Filter.self, from: JSONEncoder().encode(saved)).emoji, emoji)
        }
        XCTAssertEqual(FilterIdentityPolicy.displayName(name: "Work", emoji: "👩🏽‍💻"), "👩🏽‍💻 Work")
        XCTAssertEqual(FilterIdentityPolicy.displayName(name: "Work", emoji: ""), "Work")
        XCTAssertEqual(FilterIdentityPolicy.displayName(name: "Work", emoji: "bad"), "Work")
    }
    func testActiveV2ShareOmitsIdentityAndIncludesLiveRules() {
        var live = AppConfiguration()
        live.blockedDomains = ["live.example"]
        live.allowedDomains = ["private.example"]
        let shared = ShareableFilterConfiguration(configuration: live, emoji: "🍐")
        XCTAssertNil(shared.emoji)
        XCTAssertEqual(shared.blockedDomains, ["live.example"])
        XCTAssertEqual(shared.allowedDomains, ["private.example"])
        XCTAssertEqual(shared.enabledBlocklistIDs, live.enabledBlocklistIDs)
    }
}
