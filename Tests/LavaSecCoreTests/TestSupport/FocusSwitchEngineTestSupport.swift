import Foundation
@testable import LavaSecCore
@testable import LavaSecFilterPipeline
@testable import LavaSecKit

// Shared fixtures for driving `HeadlessFocusFilterSwitchEngine` against a seeded temp App Group
// directory — used by `HeadlessFocusFilterSwitchEngineTests` and `BackgroundPendingSwitchDrainTests`
// so the drain suite exercises the IDENTICAL warm-reuse path the engine suite validates (one
// harness, one warm-artifact stager; a change to the Environment initializer or the warm-stage flow
// lands in both suites by construction).

/// Captures the Darwin-notification names an engine run posts, cross-task safe.
final class FocusSwitchSignalSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var names: [String] = []
    func post(_ name: String) { lock.lock(); names.append(name); lock.unlock() }
    var posted: [String] { lock.lock(); defer { lock.unlock() }; return names }
}

/// A per-test engine environment over a UUID-suffixed temp dir + throwaway defaults suite.
struct FocusSwitchEngineHarness {
    let env: HeadlessFocusFilterSwitchEngine.Environment
    let defaults: UserDefaults
    /// Kept so `cleanupFocusSwitchHarness` can scrub the suite's persistent domain — UUID isolation
    /// prevents cross-test contamination, but without the scrub every harness leaks its domain for
    /// the life of the test process (lavasec-ios public review of the PR #410 promotion).
    let defaultsSuiteName: String
    let spy: FocusSwitchSignalSpy
    let dir: URL
}

/// Builds a harness with an injectable, frozen `now` (engine records/diagnostics become deterministic).
func makeFocusSwitchEngineHarness(
    prefix: String = "focus-switch",
    now: Date = Date(timeIntervalSinceReferenceDate: 10_000)
) -> FocusSwitchEngineHarness {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let defaultsSuiteName = "\(prefix)-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: defaultsSuiteName)!
    let spy = FocusSwitchSignalSpy()
    let env = HeadlessFocusFilterSwitchEngine.Environment(
        containerURL: dir,
        configurationURL: dir.appendingPathComponent("app-configuration.json"),
        filterLibraryURL: dir.appendingPathComponent("filter-library.json"),
        catalogCacheURL: dir.appendingPathComponent("catalog-cache", isDirectory: true),
        backgroundWarmIndexURL: dir.appendingPathComponent("background-warm-index.json"),
        publishLockURL: dir.appendingPathComponent("publish.lock"),
        focusSwitchLockURL: dir.appendingPathComponent("focus.lock"),
        configurationWriteLockURL: dir.appendingPathComponent("config-write.lock"),
        pendingMarkerLockURL: dir.appendingPathComponent("marker.lock"),
        snapshotFilename: "filter-snapshot.json",
        // Must match `LavaSecAppGroup.compactSnapshotFilename` (and the `FilterArtifactStore`
        // default) so the harness env names the same compact artifact `stageFocusSwitchWarmArtifact`
        // stages — a divergent name would silently bypass any future engine read through
        // `env.compactSnapshotFilename` (lavasec-ios public review of the PR #410 promotion).
        compactSnapshotFilename: "filter-snapshot.compact",
        defaults: defaults,
        catalogSyncFreshnessInterval: 7 * 24 * 60 * 60,
        now: { now },
        postSignal: { spy.post($0) },
        log: { _, _ in }
    )
    return FocusSwitchEngineHarness(
        env: env, defaults: defaults, defaultsSuiteName: defaultsSuiteName, spy: spy, dir: dir
    )
}

/// Writes a minimal valid `app-configuration.json` (generation 1, one enabled source).
func seedFocusSwitchConfiguration(_ harness: FocusSwitchEngineHarness, isPaid: Bool) {
    var config = AppConfiguration(enabledBlocklistIDs: ["s1"], customBlocklists: [], configurationGeneration: 1)
    config.isPaid = isPaid
    let data = try! JSONEncoder().encode(config)
    try! data.write(to: harness.env.configurationURL)
}

/// Writes a valid `filter-library.json` with the given filters and active id (generation 1).
func seedFocusSwitchLibrary(_ harness: FocusSwitchEngineHarness, active: String, ids: [String]) {
    let filters = ids.map { Filter(id: $0, name: $0.uppercased(), enabledBlocklistIDs: ["s1"]) }
    var lib = FilterLibrary(filters: filters, activeFilterID: active)
    lib.configurationGeneration = 1
    let data = try! JSONEncoder().encode(lib)
    try! data.write(to: harness.env.filterLibraryURL)
}

/// Removes the harness's temp dir and scrubs its throwaway defaults suite's persistent domain.
func cleanupFocusSwitchHarness(_ harness: FocusSwitchEngineHarness) {
    try? FileManager.default.removeItem(at: harness.dir)
    UserDefaults.standard.removePersistentDomain(forName: harness.defaultsSuiteName)
}

/// Build a fresh cached catalog + stage a warm artifact for `source-a`, returning the staged token +
/// a matching configuration. Mirrors FilterSnapshotPreparationServiceTests' Fixture: the payload's
/// checksum backs the catalog source's hashes, so the staged artifact passes every warm-reuse gate.
func stageFocusSwitchWarmArtifact(
    cacheDir: URL,
    containerDir: URL,
    catalogVersion: String = "test-1",
    catalogGeneratedAt: Date = Date()
) async throws -> (token: String, configuration: AppConfiguration) {
    let payload = Data("ads.example.com\ntrack.example.com\n".utf8)
    let checksum = BlocklistCatalogSynchronizer.sha256Hex(of: payload)
    let source = CatalogBlocklistSource(
        id: "source-a", name: "Source A", category: "ads", riskLevel: "low", defaultEnabled: true,
        licenseName: "MIT", attribution: "test",
        projectURL: URL(string: "https://example.com")!, sourceURL: URL(string: "https://example.com/list.txt")!,
        versionID: "source-a-v1", entryCount: 2, byteSize: payload.count, sourceHash: checksum,
        acceptedSourceHashes: [CatalogAcceptedSourceHash(sha256: checksum)], normalizedHash: checksum,
        publishedAt: Date(), redistributionMode: "allowed", parseFormat: .plainDomains,
        licenseTextURL: nil, noticeURL: nil
    )
    let catalog = BlocklistCatalog(
        schemaVersion: 2, catalogVersion: catalogVersion, generatedAt: catalogGeneratedAt,
        sources: [source], guardrails: []
    )
    let catalogDir = cacheDir.appendingPathComponent("catalog", isDirectory: true)
    try FileManager.default.createDirectory(at: catalogDir, withIntermediateDirectories: true)
    try BlocklistCatalogSynchronizer.makeJSONEncoder().encode(catalog)
        .write(to: catalogDir.appendingPathComponent("latest.json"))

    var configuration = AppConfiguration(enabledBlocklistIDs: ["source-a"])
    configuration.isPaid = true
    let service = FilterSnapshotPreparationService(
        synchronizer: BlocklistCatalogSynchronizer(
            catalogURL: URL(string: "https://example.com/catalog.json")!,
            cacheDirectoryURL: cacheDir,
            dataFetcher: { url in
                if url.lastPathComponent == "list.txt" { return payload }
                throw URLError(.cannotFindHost)
            }
        )
    )
    let prepared = try await service.prepare(
        configuration: configuration, customSources: [], catalogFreshnessMaxAge: 3_600
    )
    let pointer = try await service.stageArtifacts(
        prepared.snapshot,
        containerURL: containerDir,
        snapshotFilename: "filter-snapshot.json",
        compactSnapshotFilename: "filter-snapshot.compact"
    )
    return (pointer.token, configuration)
}

/// Write a valid 2-filter library (active `f1` empty, target `f2` carrying `targetEnabled` + `token`)
/// + the matching active configuration to the container, at a non-zero generation (no lost-write race).
func seedFocusSwitchLibraryWithWarmTarget(
    _ harness: FocusSwitchEngineHarness,
    token: String,
    targetEnabled: Set<String>
) throws {
    let f1 = Filter(id: "f1", name: "F1", enabledBlocklistIDs: [])
    let f2 = Filter(id: "f2", name: "F2", enabledBlocklistIDs: targetEnabled, lastCompiledToken: token)
    var library = FilterLibrary(filters: [f1, f2], activeFilterID: "f1")
    library.configurationGeneration = 1
    try JSONEncoder().encode(library).write(to: harness.env.filterLibraryURL)

    var config = AppConfiguration(enabledBlocklistIDs: [], configurationGeneration: 1) // mirrors active f1
    config.isPaid = true
    try JSONEncoder().encode(config).write(to: harness.env.configurationURL)
}
