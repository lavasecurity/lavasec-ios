import XCTest

final class KitAPIAccessPolicySourceTests: XCTestCase {
    private struct AccessExpectation {
        let source: SourceFile
        let required: String
        let formerPublic: String
        let wrongNarrowed: String
    }

    private struct SetterExpectation {
        let source: SourceFile
        let required: String
        let formerPublic: String
    }

    func testReconciledLedgerArithmetic() {
        XCTAssertEqual(packageExpectations.count, 34)
        XCTAssertEqual(packageCaseGroups.flatMap(\.cases).count, 7)
        XCTAssertEqual(internalExpectations.count, 8)
        XCTAssertEqual(internalCaseGroups.flatMap(\.cases).count, 10)
        XCTAssertEqual(privateSetterExpectations.count, 12)
        XCTAssertEqual(packageSetterExpectations.count, 1)
    }

    func testDeclarationMatcherIgnoresCommentedDeclarations() {
        let source = """
            /// package struct DocumentedOnly {}
            private struct Actual {} // internal let InlineOnly: Int
            /*
            public enum BlockCommentOnly {}
            */
            public struct Visible {}
            """

        XCTAssertFalse(containsDeclaration("package struct DocumentedOnly", in: source))
        XCTAssertFalse(containsDeclaration("internal let InlineOnly: Int", in: source))
        XCTAssertFalse(containsDeclaration("public enum BlockCommentOnly", in: source))
        XCTAssertTrue(containsDeclaration("public struct Visible", in: source))
    }

    func testAuditedDeclarationsUseExactNarrowedAccess() throws {
        for expectation in packageExpectations + internalExpectations {
            let source = try readCode(expectation.source)
            let normalizedSource = removingWhitespace(from: source)
            XCTAssertTrue(
                normalizedSource.contains(removingWhitespace(from: expectation.required)),
                "missing exact narrowed declaration: \(expectation.required)"
            )
            XCTAssertFalse(
                normalizedSource.contains(removingWhitespace(from: expectation.formerPublic)),
                "former public declaration remains: \(expectation.formerPublic)"
            )
            XCTAssertFalse(
                normalizedSource.contains(removingWhitespace(from: expectation.wrongNarrowed)),
                "declaration uses the wrong narrowed access: \(expectation.wrongNarrowed)"
            )
        }

        for group in packageCaseGroups + internalCaseGroups {
            let source = try readCode(group.source)
            let block = try sourceBlock(
                in: source,
                startingAt: group.startMarker,
                endingBefore: group.endMarker
            )
            for enumCase in group.cases {
                XCTAssertEqual(
                    block.components(separatedBy: enumCase).count - 1,
                    1,
                    "expected one inherited-access case \(enumCase) in \(group.startMarker)"
                )
            }
        }
    }

    func testPercentileInitializerIsInternalRatherThanPackage() throws {
        let source = try readCode(.latencyTrace)
        let block = try sourceBlock(
            in: source,
            startingAt: "struct LatencyDurationPercentiles: Equatable, Sendable {",
            endingBefore: "enum LatencyEventAggregation {"
        )
        XCTAssertTrue(
            block.contains(
                "internal init(count: Int, p50Milliseconds: TimeInterval, p95Milliseconds: TimeInterval)"
            )
        )
        XCTAssertFalse(
            block.contains(
                "package init(count: Int, p50Milliseconds: TimeInterval, p95Milliseconds: TimeInterval)"
            )
        )
        XCTAssertFalse(
            block.contains(
                "public init(count: Int, p50Milliseconds: TimeInterval, p95Milliseconds: TimeInterval)"
            )
        )
    }

    func testAuditedSettersUseExactRestrictedAccess() throws {
        for expectation in privateSetterExpectations + packageSetterExpectations {
            let source = try readCode(expectation.source)
            XCTAssertTrue(
                source.contains(expectation.required),
                "missing restricted setter: \(expectation.required)"
            )
            XCTAssertFalse(
                source.contains(expectation.formerPublic),
                "unrestricted public setter remains: \(expectation.formerPublic)"
            )
        }
    }

    func testRequiredClientBoundaryRemainsPublic() throws {
        let deepLinks = try readCode(.appDeepLink)
        for declaration in [
            "public enum LavaImportDeepLinkEntry: String, Equatable, Sendable",
            "public enum LavaSettingsDeepLink: Equatable, Sendable",
            "public enum LavaAppDeepLink: Equatable, Sendable",
            "public init?(url: URL)",
        ] {
            XCTAssertTrue(deepLinks.contains(declaration), "missing public deep-link trap: \(declaration)")
        }

        let catalog = try readCode(.catalogSourceModels)
        XCTAssertTrue(
            catalog.contains("public enum CatalogParseFormat: String, Codable, Sendable")
        )
        for enumCase in ["case auto", "case plainDomains", "case hosts", "case adblock", "case dnsmasq"] {
            XCTAssertTrue(catalog.contains(enumCase), "missing persisted catalog-format case: \(enumCase)")
        }

        let customSource = try readCode(.customBlocklistSource)
        for declaration in [
            "public struct CustomBlocklistSource: Identifiable, Hashable, Codable, Sendable",
            "public let id: String",
            "public let sourceURL: URL",
            "public init(",
            "public var cacheIdentity: String",
        ] {
            XCTAssertTrue(
                customSource.contains(declaration), "missing public custom-source trap: \(declaration)")
        }

        let domainName = try readCode(.domainName)
        for declaration in [
            "public struct DomainName: Hashable, Codable, Sendable, CustomStringConvertible",
            "public let value: String",
            "public init(_ rawValue: String) throws",
            "public var description: String",
            "public static func normalize(_ rawValue: String) throws -> String",
        ] {
            XCTAssertTrue(domainName.contains(declaration), "missing public domain trap: \(declaration)")
        }

        let latency = try readCode(.latencyTrace)
        let trace = try sourceBlock(
            in: latency,
            startingAt: "public final class LatencyTrace: @unchecked Sendable {",
            endingBefore: "public final class LatencySpan: @unchecked Sendable {"
        )
        for declaration in [
            "public protocol LatencyClock: Sendable",
            "public protocol LatencyEventSink: Sendable",
            "clock: any LatencyClock = SystemLatencyClock()",
            "sink: any LatencyEventSink = NoopLatencyEventSink()",
        ] {
            XCTAssertTrue(latency.contains(declaration), "missing public latency trap: \(declaration)")
        }
        XCTAssertTrue(trace.contains("public init("))

        let onboarding = try readCode(.onboardingDefaults)
        XCTAssertTrue(
            onboarding.contains("public enum OnboardingProtectionLevel: String, CaseIterable, Sendable"))
        XCTAssertTrue(onboarding.contains("public extension AppConfiguration"))

        let filter = try readCode(.filter)
        for declaration in [
            "public var name: String",
            "public var enabledBlocklistIDs: Set<String>",
            "public var customBlocklists: [CustomBlocklistSource]",
            "public var blockedDomains: Set<String>",
            "public var allowedDomains: Set<String>",
            "public var lastCompiledToken: String?",
        ] {
            XCTAssertTrue(filter.contains(declaration), "missing writable public Filter trap: \(declaration)")
        }

        let shareable = try readCode(.shareableFilterConfiguration)
        for declaration in [
            "public struct ShareableFilterConfiguration: Equatable, Sendable",
            "public static let currentSchemaVersion = 1",
            "public init(",
            "public init(from decoder: Decoder) throws",
            "public func encode(to encoder: Encoder) throws",
            "public enum ShareableFilterConfigurationCodeError: Error, Equatable, Sendable",
        ] {
            XCTAssertTrue(shareable.contains(declaration), "missing public share-code trap: \(declaration)")
        }
    }

    private var packageExpectations: [AccessExpectation] {
        [
            package(.appDeepLink, "enum DeepLinkEffect: CaseIterable, Sendable {"),
            package(.appDeepLink, "var effect: DeepLinkEffect {"),
            package(
                .catalogSourceModels,
                "typealias CatalogParseFormat = CatalogBlocklistSource.CatalogParseFormat"),
            package(.latencyTrace, "struct LatencyDurationPercentiles: Equatable, Sendable {"),
            package(.latencyTrace, "let count: Int"),
            package(.latencyTrace, "let p50Milliseconds: TimeInterval"),
            package(.latencyTrace, "let p95Milliseconds: TimeInterval"),
            package(.latencyTrace, "enum LatencyEventAggregation {"),
            package(.latencyTrace, "static func completedDurationPercentiles("),
            package(.localLogTimestampFormatter, "enum LocalLogTimestampFormatter {"),
            package(.localLogTimestampFormatter, "static func string(from timestamp: Date) -> String {"),
            package(
                .localLogTimestampFormatter,
                "static func string(from timestamp: Date, uses24HourClock: Bool) -> String {"
            ),
            package(
                .networkEndpointValidation,
                "enum NetworkEndpointValidationError: LocalizedError, Equatable, Sendable {"),
            package(.networkEndpointValidation, "var errorDescription: String? {"),
            package(.networkEndpointValidation, "enum NetworkEndpointValidator {"),
            package(.networkEndpointValidation, "static func validatePublicSourceURL(_ url: URL) throws {"),
            package(
                .networkEndpointValidation,
                "static func dnsResolverAddresses(from value: String) -> (ipv4: [String], ipv6: [String])? {"
            ),
            package(
                .networkEndpointValidation,
                "static func isPublicResolvedIPv4(octets: [UInt8]) -> Bool {"
            ),
            package(
                .networkEndpointValidation,
                "static func isPublicResolvedIPv6(bytes: [UInt8]) -> Bool {"
            ),
            package(.onboardingDefaults, "struct OnboardingDefaultsSummary: Equatable, Sendable {"),
            package(.onboardingDefaults, "let blocklistText: String"),
            package(.onboardingDefaults, "let resolverText: String"),
            package(.onboardingDefaults, "let deviceDNSFallbackText: String"),
            package(.onboardingDefaults, "let localLoggingText: String"),
            package(.onboardingDefaults, "let accountText: String"),
            package(
                .onboardingDefaults,
                "init(configuration: AppConfiguration, "
                    + "catalog: [BlocklistSource] = DefaultCatalog.curatedSources) {"
            ),
            package(.topDomainCounter, "struct TopDomainCounter: Equatable, Codable, Sendable {"),
            package(.topDomainCounter, "static let defaultCapacity = 256"),
            package(.topDomainCounter, "init(capacity: Int = TopDomainCounter.defaultCapacity) {"),
            package(.topDomainCounter, "init(from decoder: Decoder) throws {"),
            package(.topDomainCounter, "func encode(to encoder: Encoder) throws {"),
            package(.topDomainCounter, "var isEmpty: Bool {"),
            package(.topDomainCounter, "func counts() -> [String: Int] {"),
            package(.topDomainCounter, "mutating func record(_ domain: String) {"),
        ]
    }

    private var internalExpectations: [AccessExpectation] {
        [
            internalAccess(
                .customBlocklistSource, "enum CustomBlocklistSourceError: LocalizedError, Equatable {"),
            internalAccess(.customBlocklistSource, "var errorDescription: String? {"),
            internalAccess(
                .domainName, "enum DomainValidationError: Error, Equatable, LocalizedError, Sendable {"),
            internalAccess(.domainName, "var errorDescription: String? {"),
            internalAccess(
                .latencyTrace,
                "init(count: Int, p50Milliseconds: TimeInterval, p95Milliseconds: TimeInterval) {"
            ),
            internalAccess(.latencyTrace, "enum LatencyDetailRedactor {"),
            internalAccess(.latencyTrace, "static let redactedValue = \"[redacted]\""),
            internalAccess(
                .latencyTrace,
                "static func redactedDetails(_ details: [String: String]) -> [String: String] {"),
        ]
    }

    private var packageCaseGroups:
        [(source: SourceFile, startMarker: String, endMarker: String, cases: [String])]
    {
        [
            (
                .appDeepLink,
                "enum DeepLinkEffect: CaseIterable, Sendable {",
                "enum LavaImportDeepLinkEntry",
                ["case navigate", "case stage"]
            ),
            (
                .networkEndpointValidation,
                "enum NetworkEndpointValidationError: LocalizedError, Equatable, Sendable {",
                "enum NetworkEndpointValidator",
                [
                    "case credentialsNotAllowed",
                    "case localhostNotAllowed",
                    "case privateNetworkNotAllowed",
                    "case unusableResolverAddress",
                    "case invalidResolverHost",
                ]
            ),
        ]
    }

    private var internalCaseGroups:
        [(source: SourceFile, startMarker: String, endMarker: String, cases: [String])]
    {
        [
            (
                .customBlocklistSource,
                "enum CustomBlocklistSourceError: LocalizedError, Equatable {",
                "struct CustomBlocklistSource",
                [
                    "case invalidURL",
                    "case unsupportedScheme",
                    "case missingHost",
                    "case privateNetworkHost",
                    "case credentialsNotAllowed",
                ]
            ),
            (
                .domainName,
                "enum DomainValidationError: Error, Equatable, LocalizedError, Sendable {",
                "struct DomainName",
                [
                    "case empty",
                    "case tooLong",
                    "case needsAtLeastTwoLabels",
                    "case invalidLabel(String)",
                    "case ipAddressNotAllowed",
                ]
            ),
        ]
    }

    private var privateSetterExpectations: [SetterExpectation] {
        [
            privateSetter(.customBlocklistSource, "var displayName: String"),
            privateSetter(
                .customBlocklistSource, "var parseFormat: CatalogBlocklistSource.CatalogParseFormat"),
            privateSetter(.customBlocklistSource, "var createdAt: Date"),
            privateSetter(.filterConfigurationDiff, "var enabledBlocklistIDs: Set<String>"),
            privateSetter(.filterConfigurationDiff, "var blockedDomains: Set<String>"),
            privateSetter(.filterConfigurationDiff, "var allowedDomains: Set<String>"),
            privateSetter(.filter, "var createdAt: Date"),
            privateSetter(.filter, "var lastSyncedAt: Date?"),
            privateSetter(.shareableFilterConfiguration, "var schemaVersion: Int"),
            privateSetter(.shareableFilterConfiguration, "var enabledBlocklistIDs: Set<String>"),
            privateSetter(.shareableFilterConfiguration, "var blockedDomains: Set<String>"),
            privateSetter(.shareableFilterConfiguration, "var customBlocklists: [CustomBlocklistSource]"),
        ]
    }

    private var packageSetterExpectations: [SetterExpectation] {
        [
            SetterExpectation(
                source: .customBlocklistSource,
                required: "public package(set) var lastAcceptedHash: String?",
                formerPublic: "public var lastAcceptedHash: String?"
            )
        ]
    }

    private func package(_ source: SourceFile, _ declaration: String) -> AccessExpectation {
        AccessExpectation(
            source: source,
            required: "package \(declaration)",
            formerPublic: "public \(declaration)",
            wrongNarrowed: "internal \(declaration)"
        )
    }

    private func internalAccess(_ source: SourceFile, _ declaration: String) -> AccessExpectation {
        AccessExpectation(
            source: source,
            required: "internal \(declaration)",
            formerPublic: "public \(declaration)",
            wrongNarrowed: "package \(declaration)"
        )
    }

    private func privateSetter(_ source: SourceFile, _ declaration: String) -> SetterExpectation {
        SetterExpectation(
            source: source,
            required: "public private(set) \(declaration)",
            formerPublic: "public \(declaration)"
        )
    }

    private func removingWhitespace(from value: String) -> String {
        value.filter { !$0.isWhitespace }
    }

    private func containsDeclaration(_ declaration: String, in source: String) -> Bool {
        removingWhitespace(from: strippingComments(from: source))
            .contains(removingWhitespace(from: declaration))
    }

    private func readCode(_ sourceFile: SourceFile) throws -> String {
        strippingComments(from: try readSource(sourceFile))
    }

    private func strippingComments(from source: String) -> String {
        var result = ""
        var index = source.startIndex
        var lineComment = false
        var blockCommentDepth = 0
        var stringDelimiterLength = 0
        var escaped = false

        func hasPrefix(_ prefix: String, at index: String.Index) -> Bool {
            source[index...].hasPrefix(prefix)
        }

        func advance(_ count: Int) {
            for _ in 0..<count {
                index = source.index(after: index)
            }
        }

        while index < source.endIndex {
            let character = source[index]

            if lineComment {
                if character == "\n" {
                    lineComment = false
                    result.append(character)
                }
                advance(1)
                continue
            }

            if blockCommentDepth > 0 {
                if hasPrefix("/*", at: index) {
                    blockCommentDepth += 1
                    advance(2)
                } else if hasPrefix("*/", at: index) {
                    blockCommentDepth -= 1
                    advance(2)
                } else {
                    if character == "\n" {
                        result.append(character)
                    }
                    advance(1)
                }
                continue
            }

            if stringDelimiterLength > 0 {
                let delimiter = stringDelimiterLength == 3 ? "\"\"\"" : "\""
                if !escaped, hasPrefix(delimiter, at: index) {
                    result.append(contentsOf: delimiter)
                    advance(stringDelimiterLength)
                    stringDelimiterLength = 0
                    continue
                }

                result.append(character)
                if stringDelimiterLength == 1 {
                    if escaped {
                        escaped = false
                    } else if character == "\\" {
                        escaped = true
                    }
                }
                advance(1)
                continue
            }

            if hasPrefix("//", at: index) {
                lineComment = true
                advance(2)
            } else if hasPrefix("/*", at: index) {
                blockCommentDepth = 1
                advance(2)
            } else if hasPrefix("\"\"\"", at: index) {
                stringDelimiterLength = 3
                result.append(contentsOf: "\"\"\"")
                advance(3)
            } else if character == "\"" {
                stringDelimiterLength = 1
                escaped = false
                result.append(character)
                advance(1)
            } else {
                result.append(character)
                advance(1)
            }
        }

        return result
    }
}
