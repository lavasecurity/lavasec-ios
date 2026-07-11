import XCTest

final class DNSAPIAccessPolicySourceTests: XCTestCase {
    func testCoreFlowDeviceTestsUseOnlyPublicDNSFacade() throws {
        let source = try readSource(.coreFlowDeviceTests)
        let packageOnlyReferences = [
            "question.transactionID",
            "question.recordType",
            "DNSWireMessage.transactionID(",
            "DNSWireMessage.clearingTransactionID(",
            "DNSWireMessage.isValidResponse(",
            "DNSOverHTTPSRequest.",
        ]

        for reference in packageOnlyReferences {
            XCTAssertFalse(
                source.contains(reference),
                "LavaSecUITests imports only LavaSecCore and must not reference package-only DNS API: \(reference)"
            )
        }

        XCTAssertTrue(source.contains("DNSMessage.parseQuestion(from:"))
        XCTAssertTrue(source.contains("DNSMessage.blockedResponse(for:"))
        XCTAssertTrue(source.contains("DNSWireMessage.replacingTransactionID(in:"))
    }

    func testAuditedDNSDeclarationsUseNarrowAccess() throws {
        let expectations: [(category: String, file: SourceFile, required: String, former: String)] = [
            (
                "message/wire/request/dispatch",
                .dnsMessage,
                "package let transactionID: UInt16",
                "public let transactionID: UInt16"
            ),
            (
                "message/wire/request/dispatch",
                .dnsMessage,
                "internal enum DNSMessageError",
                "public enum DNSMessageError"
            ),
            (
                "resolver plans/orchestration/transports/sockets",
                .dnsResolverRuntimePlan,
                "package let plainAddresses: [String]",
                "public let plainAddresses: [String]"
            ),
            (
                "resolver plans/orchestration/transports/sockets",
                .resolverOrchestrator,
                "internal init(_ outcome: DNSTransportOutcome)",
                "public init(_ outcome: DNSTransportOutcome)"
            ),
            (
                "resolver plans/orchestration/transports/sockets",
                .resolverOrchestrator,
                "public private(set) var transport: DNSResolverTransport",
                "public var transport: DNSResolverTransport"
            ),
            (
                "packet/cache/bootstrap/actor state",
                .ipv4UDPDNSPacket,
                "package let sourceAddress: Data",
                "public let sourceAddress: Data"
            ),
            (
                "packet/cache/bootstrap/actor state",
                .dnsResponseCache,
                "internal let resolverIdentifier: String",
                "public let resolverIdentifier: String"
            ),
        ]

        XCTAssertEqual(Set(expectations.map(\.category)).count, 3)

        for expectation in expectations {
            let source = try readSource(expectation.file)
            XCTAssertTrue(
                source.contains(expectation.required),
                "\(expectation.category): expected \(expectation.required) in \(expectation.file.rawValue)"
            )
            XCTAssertFalse(
                source.contains(expectation.former),
                "\(expectation.category): former public spelling remains in \(expectation.file.rawValue)"
            )
        }
    }

    func testResolverHealthCoordinatorIsPublicWithoutAStatelessStorageBypass() throws {
        let coordinator = try readSource(.resolverHealthCoordinator)
        let gateway = try readSource(.resolverHealthGateway)

        XCTAssertTrue(coordinator.contains("public actor ResolverHealthCoordinator"))
        XCTAssertTrue(coordinator.contains("public struct ResolverSmokeProbeToken"))
        XCTAssertTrue(coordinator.contains("fileprivate let generation: UInt64"))

        XCTAssertFalse(gateway.contains("ResolverHealthProviderEvidence"))
        XCTAssertTrue(gateway.contains("\nenum ResolverHealthGateway {"))
        XCTAssertFalse(gateway.contains("\npublic enum ResolverHealthGateway {"))
        XCTAssertFalse(gateway.contains("providerEvidence:"))
        XCTAssertTrue(gateway.contains("static func smokeProbeCompleted("))
        XCTAssertFalse(gateway.contains("public static func smokeProbeCompleted("))
    }
}
