import XCTest

final class AppServicesAPIAccessPolicySourceTests: XCTestCase {
    func testNarrowedFamiliesUseAuditedAccess() throws {
        try assertBackupConfigurationPayloadPolicy()
        try assertBackupEnvelopeStorePolicy()
        try assertBackupPasswordPolicy()
        try assertBugReportPolicy()
        try assertLocalLogArchivePolicy()
        try assertOnboardingPolicy()
        try assertRageShakePolicy()
        try assertSupabasePolicy()
        try assertLegalNoticePolicy()
        try assertZeroKnowledgeEnvelopePolicy()
    }

    func testClientWritableFieldsUseReadOnlyPublicSetters() throws {
        let bugReportSource = try readSource(.bugReportBundle)
        let context = try sourceBlock(
            in: bugReportSource,
            startingAt: "struct BugReportContext: Equatable, Codable, Sendable {",
            endingBefore: "    public init("
        )
        for declaration in [
            "public private(set) var issueType: BugReportIssueType",
            "public private(set) var affectedSite: String",
            "public private(set) var details: String",
            "public private(set) var contactEmail: String?",
            "public private(set) var includeDiagnostics: Bool",
        ] {
            XCTAssertTrue(context.contains(declaration), "missing read-only setter: \(declaration)")
            XCTAssertFalse(
                context.contains(declaration.replacingOccurrences(of: "public private(set)", with: "public")))
        }

        let archiveSource = try readSource(.localLogExportArchive)
        let metadata = try sourceBlock(
            in: archiveSource,
            startingAt: "struct LocalLogExportMetadata: Equatable, Sendable {",
            endingBefore: "    public init("
        )
        for declaration in [
            "public private(set) var appVersion: String?",
            "public private(set) var build: String?",
            "public private(set) var sourceRevision: String?",
            "public private(set) var osVersion: String?",
            "public private(set) var deviceFamily: String?",
            "public private(set) var locale: String?",
            "public private(set) var catalogVersion: String?",
        ] {
            XCTAssertTrue(metadata.contains(declaration), "missing read-only setter: \(declaration)")
            XCTAssertFalse(
                metadata.contains(declaration.replacingOccurrences(of: "public private(set)", with: "public"))
            )
        }
    }

    func testPublicBoundaryTrapsRemainPublic() throws {
        let configuration = try readSource(.backupConfigurationPayload)
        XCTAssertTrue(
            configuration.contains("public struct BackupConfigurationPayload: Codable, Equatable, Sendable"))
        XCTAssertTrue(configuration.contains("schemaVersion: Int = 1"))

        let store = try readSource(.backupEnvelopeStore)
        XCTAssertTrue(store.contains("public protocol BackupEnvelopeStorage: Sendable"))
        XCTAssertTrue(
            store.contains("public struct BackupEnvelopeUserDefaultsStorage: BackupEnvelopeStorage"))
        XCTAssertTrue(
            store.contains(
                "public init(storage: any BackupEnvelopeStorage = BackupEnvelopeUserDefaultsStorage())"
            )
        )

        let bugReport = try readSource(.bugReportBundle)
        XCTAssertTrue(bugReport.contains("public enum BugReportIssueType: String"))
        XCTAssertTrue(bugReport.contains("public struct BugReportBundle: Sendable"))
        XCTAssertTrue(bugReport.contains("public func makeRequestBody() -> [String: Any]"))

        let auth = try readSource(.supabaseIDTokenAuth)
        XCTAssertTrue(auth.contains("public struct SupabaseIDTokenAuthSession: Codable, Equatable, Sendable"))
        XCTAssertTrue(auth.contains("public static func decodeSession(data: Data, response: URLResponse)"))

        let envelope = try readSource(.zeroKnowledgeBackupEnvelope)
        XCTAssertTrue(envelope.contains("public enum ZeroKnowledgeBackupKeySlotKind: String, Codable"))
        XCTAssertTrue(envelope.contains("public static let currentSchemaVersion = 1"))
        XCTAssertTrue(envelope.contains("public static let currentEnvelopeVersion = 1"))
        XCTAssertTrue(envelope.contains("public static let defaultPasswordIterations = 210_000"))
        XCTAssertTrue(envelope.contains("public static func make("))
        XCTAssertTrue(envelope.contains("public static func makePasswordless("))
        XCTAssertTrue(envelope.contains("public static func makeWithPRF("))

        let facadeRepresentative = try readSource(.encryptedBackupState)
        XCTAssertTrue(facadeRepresentative.contains("public enum EncryptedBackupState: Equatable, Sendable"))
    }

    private func assertBackupConfigurationPayloadPolicy() throws {
        let source = try readSource(.backupConfigurationPayload)
        let payload = try sourceBlock(
            in: source,
            startingAt: "struct BackupConfigurationPayload: Codable, Equatable, Sendable {",
            endingBefore: "    private enum CodingKeys"
        )
        assertNarrowed(
            "package static let currentSupportedSchemaVersion = 1",
            from: "public static let currentSupportedSchemaVersion = 1",
            in: payload
        )
    }

    private func assertBackupEnvelopeStorePolicy() throws {
        let source = try readSource(.backupEnvelopeStore)
        let store = try sourceBlock(
            in: source,
            startingAt: "struct BackupEnvelopeStore: Sendable {"
        )
        for pair in [
            ("package enum Keys {", "public enum Keys {"),
            ("package static let envelope =", "public static let envelope ="),
            ("package static let lastUploadedAt =", "public static let lastUploadedAt ="),
            (
                "package static let reservedOverheadBytes = 1_024",
                "public static let reservedOverheadBytes = 1_024"
            ),
            (
                "package func recordUpload(at uploadedAt: Date)",
                "public func recordUpload(at uploadedAt: Date)"
            ),
            ("package func lastUploadedAt() -> Date?", "public func lastUploadedAt() -> Date?"),
        ] {
            assertNarrowed(pair.0, from: pair.1, in: store)
        }
    }

    private func assertBackupPasswordPolicy() throws {
        let source = try readSource(.backupPasswordPolicy)
        XCTAssertFalse(source.contains("public "), "the audited password-policy graph is package-only")
        for declaration in [
            "package enum BackupPasswordRequirementID",
            "package struct BackupPasswordRequirement",
            "package let id: BackupPasswordRequirementID",
            "package let label: String",
            "package let isSatisfied: Bool",
            "package init(id: BackupPasswordRequirementID, label: String, isSatisfied: Bool)",
            "package struct BackupPasswordValidationResult",
            "package let requirements: [BackupPasswordRequirement]",
            "package init(requirements: [BackupPasswordRequirement])",
            "package var isValid: Bool",
            "package enum BackupPasswordPolicy",
            "package static func validate(",
        ] {
            XCTAssertTrue(source.contains(declaration), "missing package declaration: \(declaration)")
        }
        XCTAssertEqual(
            explicitDeclarationCount(with: "package", in: source),
            12,
            "the complete password-policy graph must keep exactly 12 explicit package declarations"
        )
    }

    private func assertBugReportPolicy() throws {
        let source = try readSource(.bugReportBundle)
        let issueKind = try sourceBlock(
            in: source,
            startingAt: "enum BugReportIssueKind: String, Codable, Sendable {",
            endingBefore: "enum BugReportIssueType: String"
        )
        assertNarrowed(
            "package enum BugReportIssueKind: String, Codable, Sendable",
            from: "public enum BugReportIssueKind: String, Codable, Sendable",
            in: source
        )
        for enumCase in ["case bug", "case suggestion", "case other"] {
            XCTAssertTrue(issueKind.contains(enumCase))
        }

        let issueType = try sourceBlock(
            in: source,
            startingAt: "enum BugReportIssueType: String",
            endingBefore: "enum BugReportInputLimits"
        )
        assertNarrowed(
            "package var kind: BugReportIssueKind",
            from: "public var kind: BugReportIssueKind",
            in: issueType
        )

        let incidentSummary = try sourceBlock(
            in: source,
            startingAt: "package struct BugReportIncidentSummary: Equatable, Sendable {",
            endingBefore: "\npublic struct BugReportBundle: Sendable {"
        )
        XCTAssertFalse(
            incidentSummary.contains("public "), "the complete incident summary graph is package-only")
        for declaration in [
            "package struct BugReportIncidentSummary: Equatable, Sendable",
            "package static let maxSelfReconnectTimes = 20",
            "package let selfReconnectTimes: [Date]",
            "package let lastFailureReason: String?",
            "package let consecutiveUpstreamFailureCount: Int",
            "package let consecutiveDNSSmokeProbeFailureCount: Int",
            "package let consecutiveRejectedSmokeResponseCount: Int",
            "package let lastUpstreamFailureAt: Date?",
            "package let lastUpstreamSuccessAt: Date?",
            "package let lastPrimaryUpstreamSuccessAt: Date?",
            "package let lastEncryptedFallbackSuccessAt: Date?",
            "package let lastDNSSmokeProbeAt: Date?",
            "package let lastDNSSmokeProbeSucceeded: Bool?",
            "package let lastNetworkChangeAt: Date?",
            "package let networkChangeCount: Int",
            "package let lastResolverRuntimeResetAt: Date?",
            "package let lastResolverRuntimeResetReason: String?",
            "package let resolverRuntimeResetCount: Int",
            "package let lastResolverIdentityChangeAt: Date?",
            "package let failClosedServedQueryCount: Int",
            "package let lastFailClosedAt: Date?",
            "package let lastFailClosedReason: String?",
            "package let lastFocusSwitch: FocusSwitchDiagnosticRecord?",
            "package let selfReconnectGap: SelfReconnectGapRecord?",
            "package let hasRecentSelfReconnectGap: Bool",
            "package let recentIncidents: [IncidentLedgerRecord]",
            "package let hasRecentLedgerIncident: Bool",
            "package let hasRecentFocusSwitch: Bool",
            "package init(",
            "package var selfReconnectCount: Int",
            "package var lastSelfReconnectAt: Date?",
            "package var hasContent: Bool",
            "package var dictionary: [String: Any]",
        ] {
            XCTAssertTrue(
                incidentSummary.contains(declaration),
                "missing package declaration: \(declaration)"
            )
        }
        XCTAssertEqual(
            explicitDeclarationCount(with: "package", in: incidentSummary),
            33,
            "the complete incident-summary graph must keep exactly 33 explicit package declarations"
        )

        let bundle = try sourceBlock(
            in: source,
            startingAt: "struct BugReportBundle: Sendable {",
            endingBefore: "enum BugReportSubmissionBundlePolicy"
        )
        assertNarrowed(
            "package var incident: BugReportIncidentSummary",
            from: "public var incident: BugReportIncidentSummary",
            in: bundle
        )
    }

    private func assertLocalLogArchivePolicy() throws {
        let source = try readSource(.localLogExportArchive)
        let error = try sourceBlock(
            in: source,
            startingAt: "enum LocalLogExportArchiveError: Error, Equatable {"
        )
        assertNarrowed(
            "internal enum LocalLogExportArchiveError: Error, Equatable",
            from: "public enum LocalLogExportArchiveError: Error, Equatable",
            in: source
        )
        XCTAssertTrue(error.contains("case archiveTooLarge"))
    }

    private func assertOnboardingPolicy() throws {
        let source = try readSource(.onboardingAnimation)
        let plan = try sourceBlock(
            in: source,
            startingAt: "enum OnboardingFeatureTransitionPlan {",
            endingBefore: "enum OnboardingLavaWaveTimeline"
        )
        for name in [
            "initialHeroTopSpacer",
            "finalHeroTopSpacer",
            "initialHeroHeight",
            "finalHeroHeight",
            "initialHeroPanelOffsetY",
            "finalHeroPanelOffsetY",
            "initialFeatureRowsOffsetY",
            "finalFeatureRowsOffsetY",
            "featureRowsTopOffset",
        ] {
            XCTAssertTrue(plan.contains("package static let \(name) ="), "missing package geometry: \(name)")
            XCTAssertFalse(plan.contains("public static let \(name) ="), "public geometry remains: \(name)")
        }
    }

    private func assertRageShakePolicy() throws {
        let source = try readSource(.rageShakeQA)
        let mode = try sourceBlock(
            in: source,
            startingAt: "enum RageShakeMode: Equatable, Sendable {",
            endingBefore: "enum RageShakeRouter"
        )
        assertNarrowed(
            "package enum RageShakeMode: Equatable, Sendable",
            from: "public enum RageShakeMode: Equatable, Sendable",
            in: source
        )
        XCTAssertTrue(mode.contains("case normalUser"))
        XCTAssertTrue(mode.contains("case admin"))

        let router = try sourceBlock(
            in: source,
            startingAt: "enum RageShakeRouter {",
            endingBefore: "enum RageShakeActivationPolicy"
        )
        assertNarrowed(
            "package static func destination(for mode: RageShakeMode)",
            from: "public static func destination(for mode: RageShakeMode)",
            in: router
        )
    }

    private func assertSupabasePolicy() throws {
        let source = try readSource(.supabaseIDTokenAuth)
        let error = try sourceBlock(
            in: source,
            startingAt: "enum SupabaseIDTokenAuthError: Error, Equatable, LocalizedError {",
            endingBefore: "enum SupabaseIDTokenAuth {"
        )
        assertNarrowed(
            "package enum SupabaseIDTokenAuthError: Error, Equatable, LocalizedError",
            from: "public enum SupabaseIDTokenAuthError: Error, Equatable, LocalizedError",
            in: source
        )
        for enumCase in ["case invalidEndpoint", "case invalidResponse", "case requestFailed("] {
            XCTAssertTrue(error.contains(enumCase), "missing Supabase error case: \(enumCase)")
        }
        assertNarrowed(
            "package var errorDescription: String?",
            from: "public var errorDescription: String?",
            in: error
        )
    }

    private func assertLegalNoticePolicy() throws {
        let source = try readSource(.thirdPartyLegalNotice)
        let notices = try sourceBlock(
            in: source,
            startingAt: "enum ThirdPartyLegalNotices {"
        )
        assertNarrowed(
            "package static let all: [ThirdPartyLegalNotice]",
            from: "public static let all: [ThirdPartyLegalNotice]",
            in: notices
        )
        assertNarrowed(
            "package static func notice(id: String) -> ThirdPartyLegalNotice?",
            from: "public static func notice(id: String) -> ThirdPartyLegalNotice?",
            in: notices
        )
    }

    private func assertZeroKnowledgeEnvelopePolicy() throws {
        let source = try readSource(.zeroKnowledgeBackupEnvelope)
        let error = try sourceBlock(
            in: source,
            startingAt: "enum ZeroKnowledgeBackupEnvelopeError: Error, Equatable, Sendable {",
            endingBefore: "enum ZeroKnowledgeBackupKeySlotKind"
        )
        assertNarrowed(
            "package enum ZeroKnowledgeBackupEnvelopeError: Error, Equatable, Sendable",
            from: "public enum ZeroKnowledgeBackupEnvelopeError: Error, Equatable, Sendable",
            in: source
        )
        for enumCase in [
            "case invalidBase64",
            "case invalidCiphertext",
            "case keyDerivationFailed(Int32)",
            "case missingKeySlot",
            "case missingServerRecoveryShare",
            "case randomBytesFailed(Int32)",
            "case unsupportedKeyDerivationFunction(String)",
            "case unsupportedEnvelopeVersion(Int)",
        ] {
            XCTAssertTrue(error.contains(enumCase), "missing envelope error case: \(enumCase)")
        }

        let envelope = try sourceBlock(
            in: source,
            startingAt: "struct ZeroKnowledgeBackupEnvelope: Codable, Equatable, Sendable {"
        )
        for pair in [
            (
                "package static let testingPasswordIterations = 8",
                "public static let testingPasswordIterations = 8"
            ),
            ("package static func makeForTesting(", "public static func makeForTesting("),
            (
                "package static func makePasswordlessForTesting(",
                "public static func makePasswordlessForTesting("
            ),
            ("package static func makeWithPRFForTesting(", "public static func makeWithPRFForTesting("),
        ] {
            assertNarrowed(pair.0, from: pair.1, in: envelope)
        }
    }

    private func assertNarrowed(
        _ required: String,
        from former: String,
        in source: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            source.contains(required), "expected narrowed declaration: \(required)", file: file, line: line)
        XCTAssertFalse(
            source.contains(former), "former public declaration remains: \(former)", file: file, line: line)
    }

    private func explicitDeclarationCount(with access: String, in source: String) -> Int {
        source.split(whereSeparator: \.isNewline).count { line in
            line.trimmingCharacters(in: .whitespaces).hasPrefix("\(access) ")
        }
    }
}
