import XCTest
@testable import LavaSecCore
@testable import LavaSecKit

/// REL-7: the incident-ledger row shape is hand-mirrored between this client
/// (`IncidentLedgerRecord`) and the Cloudflare worker (`sanitizeIncidentLedgerEntry`). Both
/// sides load the SAME canonical contract (vendored from lavasec-infra/contracts, pinned in
/// contracts.lock) so a divergence fails CI. This asserts the client's ACTUAL enforcement
/// — the reason pattern via `sanitizedReason`, the `Kind` set, and the row cap — matches the
/// contract's declared cases. `verifiedBy` and the row-vs-field consequence of an off-shape
/// reason are worker-enforced and covered by the worker's contract test, not here.
final class IncidentLedgerContractTests: XCTestCase {
    private struct Contract: Decodable {
        struct Reason: Decodable {
            let pattern: String
            let maxLength: Int
            let accepted: [String]
            let rejected: [String]
        }
        let reason: Reason
        let kinds: [String]
        let verifiedBy: [String]
        let maxEntries: Int
    }

    private static func loadContract() throws -> Contract {
        let data = try Data(contentsOf: sourceFileURL(.incidentLedgerContract))
        return try JSONDecoder().decode(Contract.self, from: data)
    }

    func testWriterAcceptsEveryContractAcceptedReasonVerbatim() throws {
        let contract = try Self.loadContract()
        for reason in contract.reason.accepted where !reason.isEmpty {
            XCTAssertEqual(
                IncidentLedgerRecord.sanitizedReason(reason), reason,
                "contract-accepted reason should pass sanitizedReason unchanged: \(reason)"
            )
        }
    }

    func testWriterRejectsEveryContractRejectedReason() throws {
        let contract = try Self.loadContract()
        for reason in contract.reason.rejected {
            XCTAssertNil(
                IncidentLedgerRecord.sanitizedReason(reason),
                "contract-rejected reason should be dropped by sanitizedReason: \(reason.isEmpty ? "<empty>" : reason)"
            )
        }
    }

    func testWriterHonoursTheReasonMaxLengthBoundary() throws {
        let contract = try Self.loadContract()
        let ok = String(repeating: "a", count: contract.reason.maxLength)          // exactly maxLength → accepted
        let tooLong = String(repeating: "a", count: contract.reason.maxLength + 1)  // one over → rejected
        XCTAssertEqual(IncidentLedgerRecord.sanitizedReason(ok), ok)
        XCTAssertNil(IncidentLedgerRecord.sanitizedReason(tooLong))
    }

    func testKindRawValuesMatchTheContractExactly() throws {
        let contract = try Self.loadContract()
        XCTAssertEqual(
            IncidentLedgerRecord.Kind.allCases.map(\.rawValue), contract.kinds,
            "Kind raw values must match the contract's kinds (order-sensitive) — a divergence means a row the worker accepts, or vice versa, is unrecognized on the other side."
        )
    }

    func testRowCapMatchesTheContractMaxEntries() throws {
        let contract = try Self.loadContract()
        XCTAssertEqual(IncidentLedger.maximumRecordCount, contract.maxEntries)
    }

    func testContractReasonPatternIsTheDocumentedKebabShape() throws {
        // A guard on the contract itself: the writer/worker implement this pattern by hand, so
        // pin the pattern string too — a silent edit to the contract's regex is caught here.
        let contract = try Self.loadContract()
        XCTAssertEqual(contract.reason.pattern, "^[a-z][a-z0-9-]{0,99}$")
        XCTAssertEqual(contract.reason.maxLength, 100)
    }
}
