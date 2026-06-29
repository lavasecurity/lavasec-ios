import XCTest
@testable import LavaSecCore

final class BackgroundWarmIndexTests: XCTestCase {
    private func makeTempStoreURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("bg-warm-index-\(UUID().uuidString).json")
    }

    func testLookupHelpers() {
        let synced = Date(timeIntervalSince1970: 1_000_000)
        var index = BackgroundWarmIndex()
        index.setEntry(BackgroundWarmIndexEntry(token: "tok-A", syncedAt: synced), forFilterID: "A")

        XCTAssertEqual(index.token(forFilterID: "A"), "tok-A")
        XCTAssertEqual(index.syncedAt(forFilterID: "A"), synced)
        XCTAssertNil(index.token(forFilterID: "missing"))
        XCTAssertNil(index.syncedAt(forFilterID: "missing"))
    }

    func testRetainedTokensCollectsEveryEntry() {
        var index = BackgroundWarmIndex()
        index.setEntry(BackgroundWarmIndexEntry(token: "tok-A", syncedAt: Date()), forFilterID: "A")
        index.setEntry(BackgroundWarmIndexEntry(token: "tok-B", syncedAt: Date()), forFilterID: "B")

        XCTAssertEqual(Set(index.retainedTokens()), ["tok-A", "tok-B"])
    }

    func testSetEntryOverwritesPerFilterAndRemoveDrops() {
        var index = BackgroundWarmIndex()
        index.setEntry(BackgroundWarmIndexEntry(token: "old", syncedAt: Date()), forFilterID: "A")
        index.setEntry(BackgroundWarmIndexEntry(token: "new", syncedAt: Date()), forFilterID: "A")
        XCTAssertEqual(index.entries.count, 1)
        XCTAssertEqual(index.token(forFilterID: "A"), "new")

        index.removeEntry(forFilterID: "A")
        XCTAssertNil(index.token(forFilterID: "A"))
        XCTAssertTrue(index.entries.isEmpty)
    }

    func testStoreRoundTrips() throws {
        let url = makeTempStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = BackgroundWarmIndexStore(fileURL: url)

        var index = BackgroundWarmIndex()
        index.setEntry(BackgroundWarmIndexEntry(token: "tok", syncedAt: Date(timeIntervalSince1970: 42)), forFilterID: "F")
        try store.save(index)

        let loaded = store.load()
        XCTAssertEqual(loaded, index)
        XCTAssertEqual(loaded.token(forFilterID: "F"), "tok")
    }

    func testLoadMissingFileReturnsEmptyIndex() {
        let store = BackgroundWarmIndexStore(fileURL: makeTempStoreURL())
        XCTAssertTrue(store.load().entries.isEmpty)
        XCTAssertEqual(store.load().schemaVersion, BackgroundWarmIndex.currentSchemaVersion)
    }

    func testLoadCorruptFileReturnsEmptyIndex() throws {
        let url = makeTempStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("not json".utf8).write(to: url)

        XCTAssertTrue(BackgroundWarmIndexStore(fileURL: url).load().entries.isEmpty)
    }

    func testLoadFutureSchemaReturnsEmptyIndex() throws {
        let url = makeTempStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let future = BackgroundWarmIndex(schemaVersion: BackgroundWarmIndex.currentSchemaVersion + 1, entries: [
            "A": BackgroundWarmIndexEntry(token: "tok", syncedAt: Date())
        ])
        let encoder = JSONEncoder()
        try encoder.encode(future).write(to: url)

        XCTAssertTrue(BackgroundWarmIndexStore(fileURL: url).load().entries.isEmpty)
    }

    func testSaveReplacesPriorContentsWholesale() throws {
        let url = makeTempStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = BackgroundWarmIndexStore(fileURL: url)

        var first = BackgroundWarmIndex()
        first.setEntry(BackgroundWarmIndexEntry(token: "a", syncedAt: Date()), forFilterID: "A")
        first.setEntry(BackgroundWarmIndexEntry(token: "b", syncedAt: Date()), forFilterID: "B")
        try store.save(first)

        var second = BackgroundWarmIndex()
        second.setEntry(BackgroundWarmIndexEntry(token: "c", syncedAt: Date()), forFilterID: "C")
        try store.save(second)

        let loaded = store.load()
        XCTAssertEqual(Set(loaded.entries.keys), ["C"])
        XCTAssertEqual(loaded.token(forFilterID: "C"), "c")
    }
}
