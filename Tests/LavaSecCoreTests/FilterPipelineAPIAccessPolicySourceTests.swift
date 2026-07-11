import XCTest

final class FilterPipelineAPIAccessPolicySourceTests: XCTestCase {
    func testRepresentativeDeclarationsUseAuditedAccess() throws {
        let expectations: [(family: String, file: SourceFile, required: String, former: String)] = [
            (
                "index/catalog/parser",
                .blocklistCatalogRepository,
                "internal static let maximumCatalogBytes",
                "public static let maximumCatalogBytes"
            ),
            (
                "index/catalog/parser",
                .blocklistCatalogSync,
                "package static let maximumBlocklistBytes",
                "public static let maximumBlocklistBytes"
            ),
            (
                "index/catalog/parser",
                .blocklistParser,
                "package enum BlocklistParsingRules",
                "public enum BlocklistParsingRules"
            ),
            (
                "compact/artifacts/cache",
                .compactFilterSnapshot,
                "package enum CompactFilterSnapshotError",
                "public enum CompactFilterSnapshotError"
            ),
            (
                "compact/artifacts/cache",
                .filterArtifactStore,
                "package enum FilterArtifactKind",
                "public enum FilterArtifactKind"
            ),
            (
                "compact/artifacts/cache",
                .filterSnapshotMemoryBudget,
                "package static let baselineMegabytes",
                "public static let baselineMegabytes"
            ),
            (
                "compact/artifacts/cache",
                .ruleSetCache,
                "package struct Entry",
                "public struct Entry"
            ),
            (
                "preparation/focus/headless",
                .filterSnapshotPreparationService,
                "internal static func blocklistSourceRuleCounts(",
                "public static func blocklistSourceRuleCounts("
            ),
            (
                "preparation/focus/headless",
                .focusFilterSwitchCoordination,
                "package init(targetFilterID: String, requestedAt: Date)",
                "public init(targetFilterID: String, requestedAt: Date)"
            ),
            (
                "preparation/focus/headless",
                .headlessFocusFilterSwitchEngine,
                "internal let containerURL: URL",
                "public let containerURL: URL"
            ),
            (
                "preparation/focus/headless",
                .knownBlocklistURLMatcher,
                "internal static func catalogSourceID(for rawURL: String)",
                "public static func catalogSourceID(for rawURL: String)"
            ),
            (
                "reuse/loading",
                .preparedFilterSnapshot,
                "package func matches(identity expectedIdentity: PreparedFilterSnapshotIdentity)",
                "public func matches(identity expectedIdentity: PreparedFilterSnapshotIdentity)"
            ),
            (
                "reuse/loading",
                .warmFilterSnapshotLoader,
                "package static func reusableSnapshotForSwitch(",
                "public static func reusableSnapshotForSwitch("
            ),
        ]

        XCTAssertEqual(Set(expectations.map(\.family)).count, 4)

        for expectation in expectations {
            let source = try readSource(expectation.file)
            XCTAssertTrue(
                source.contains(expectation.required),
                "\(expectation.family): expected \(expectation.required) in \(expectation.file.rawValue)"
            )
            XCTAssertFalse(
                source.contains(expectation.former),
                "\(expectation.family): former public spelling remains in \(expectation.file.rawValue)"
            )
        }
    }

    func testWarmIndexAndReplacementGateSettersStayReadOnlyToClients() throws {
        let warmIndex = try readSource(.backgroundWarmIndex)
        XCTAssertTrue(warmIndex.contains("package private(set) var schemaVersion: Int"))
        XCTAssertFalse(warmIndex.contains("public var schemaVersion: Int"))
        XCTAssertTrue(warmIndex.contains("public private(set) var entries: [String: BackgroundWarmIndexEntry]"))
        XCTAssertFalse(warmIndex.contains("public var entries: [String: BackgroundWarmIndexEntry]"))

        let replacementGate = try readSource(.exclusiveReplacementGate)
        XCTAssertTrue(replacementGate.contains("public private(set) var epoch: Int"))
        XCTAssertTrue(
            replacementGate.contains("public private(set) var currentOwnerOwnsPreparationCover: Bool")
        )
    }

    func testPublicBoundaryTrapsRemainPublic() throws {
        let parser = try readSource(.blocklistParser)
        XCTAssertTrue(parser.contains("public struct BlocklistParser: Sendable"))
        XCTAssertTrue(parser.contains("public enum BlocklistFormat: String, Codable, Sendable"))

        let catalogSync = try readSource(.blocklistCatalogSync)
        XCTAssertTrue(catalogSync.contains("public typealias BlocklistCatalogDataFetcher"))
        XCTAssertTrue(catalogSync.contains("public struct BlocklistParseResourceBudget: Sendable"))
        XCTAssertTrue(catalogSync.contains("public static let `default` = BlocklistParseResourceBudget("))

        let compact = try readSource(.compactFilterSnapshot)
        XCTAssertTrue(compact.contains("public let resolver: DNSResolverPreset"))
        XCTAssertTrue(compact.contains("package let summary: PreparedFilterSnapshotSummary"))
        XCTAssertTrue(compact.contains("public var tierBudgetRuleCount: Int?"))

        let prepared = try readSource(.preparedFilterSnapshot)
        XCTAssertTrue(prepared.contains("public init(from decoder: Decoder) throws"))

        let headless = try readSource(.headlessFocusFilterSwitchEngine)
        XCTAssertTrue(headless.contains("public struct Environment"))
        XCTAssertTrue(headless.contains("public init(\n            containerURL: URL"))

        let versionedStore = try readSource(.filterArtifactStoreVersioned)
        XCTAssertTrue(versionedStore.contains("public static let defaultArtifactsDirectoryName"))
        XCTAssertTrue(versionedStore.contains("public static let defaultArtifactPointerFilename"))

        let artifactStore = try readSource(.filterArtifactStore)
        XCTAssertTrue(artifactStore.contains("public let directoryURL: URL"))

        let knownURLMigration = try readSource(.knownBlocklistURLMatcher)
        let filterLibraryExtension = try sourceBlock(
            in: knownURLMigration,
            startingAt: "public extension FilterLibrary {"
        )
        XCTAssertTrue(
            filterLibraryExtension.contains(
                "\n    func migratingKnownCustomBlocklistsToCatalogSources() -> FilterLibrary"
            )
        )
        for narrowerAccess in ["internal", "package", "private", "fileprivate"] {
            XCTAssertFalse(
                filterLibraryExtension.contains(
                    "\n    \(narrowerAccess) func migratingKnownCustomBlocklistsToCatalogSources() -> FilterLibrary"
                )
            )
        }
    }
}
