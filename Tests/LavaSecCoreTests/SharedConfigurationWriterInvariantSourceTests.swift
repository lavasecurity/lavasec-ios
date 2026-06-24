import XCTest

/// Structural invariant guarding the shared `app-configuration.json` against the
/// config-clobber race that forced the daily background catalog refresh out of 1.0
/// (removal commit 0e15882, #65; tracked for post-1.0 reintroduction in LAV-90).
///
/// A cross-process lock gives mutual exclusion but NOT recency — it can make a
/// clobber atomic, not prevent it — so the real fix is structural: `configuration`
/// has exactly one owner, the `@MainActor` `AppViewModel`, written by exactly two
/// functions (`persistSharedState` and `persistConfigurationOnly`). When the
/// background refresh returns (LAV-90 Phase 2) it must publish artifacts/catalog
/// cache only and MUST NOT add a third configuration writer, or the config-clobber
/// race reopens. This test fails loudly if a new write site appears or the owner
/// leaves the main actor.
final class SharedConfigurationWriterInvariantSourceTests: XCTestCase {
    func testConfigurationIsWrittenOnlyByTheTwoMainActorPublishers() throws {
        let source = try Self.source(named: "AppViewModel.swift", in: "LavaSecApp")

        // The single owner of the shared configuration file must stay main-actor
        // confined, so no background-constructed model can race a foreground save.
        XCTAssertTrue(
            source.contains("@MainActor\nfinal class AppViewModel: ObservableObject {"),
            "AppViewModel must remain @MainActor so configuration writes cannot run off the main actor (LAV-90 config-clobber)."
        )

        // Exactly two physical writes of the configuration file may exist anywhere
        // in the model. A third site is precisely the config-clobber regression
        // this test exists to catch.
        let writeMarker = "write(to: configurationURL"
        XCTAssertEqual(
            source.components(separatedBy: writeMarker).count - 1, 2,
            "configuration must be written by exactly two functions; a new write site risks config-clobber (LAV-90)."
        )

        // And both of those writes must live in the two recognized publishers.
        let persistSharedState = try Self.sourceBlock(
            in: source,
            startingAt: "private func persistSharedState(",
            endingBefore: "private func persistConfigurationOnly("
        )
        XCTAssertEqual(
            persistSharedState.components(separatedBy: writeMarker).count - 1, 1,
            "persistSharedState must contain exactly one configuration write."
        )

        let persistConfigurationOnly = try Self.sourceBlock(
            in: source,
            startingAt: "private func persistConfigurationOnly(",
            endingBefore: "private func uploadEncryptedBackup("
        )
        XCTAssertEqual(
            persistConfigurationOnly.components(separatedBy: writeMarker).count - 1, 1,
            "persistConfigurationOnly must contain exactly one configuration write."
        )
    }

    // MARK: - Source introspection helpers

    private static func source(named fileName: String, in directoryName: String) throws -> String {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let packageRootURL = testFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = packageRootURL
            .appendingPathComponent(directoryName)
            .appendingPathComponent(fileName)

        return try String(contentsOf: sourceURL, encoding: .utf8)
    }

    private static func sourceBlock(
        in source: String,
        startingAt startMarker: String,
        endingBefore endMarker: String
    ) throws -> String {
        let start = try XCTUnwrap(source.range(of: startMarker)?.lowerBound)
        let suffix = source[start...]
        let end = try XCTUnwrap(suffix.range(of: endMarker)?.lowerBound)

        return String(suffix[..<end])
    }
}
