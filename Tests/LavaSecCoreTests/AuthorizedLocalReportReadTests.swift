import XCTest
@testable import LavaSecAppServices

@MainActor
final class AuthorizedLocalReportReadTests: XCTestCase {
    private enum Denied: Error { case revoked, cancelled }

    func testLocalReportAndManualRefreshFinishWhileHealthReplyRemainsSuspended() async throws {
        var healthReply: CheckedContinuation<Void, Never>?
        var healthCompleted = false
        let healthTask = Task { @MainActor in
            await withCheckedContinuation { healthReply = $0 }
            healthCompleted = true
        }
        while healthReply == nil { await Task.yield() }
        defer { healthReply?.resume() }
        var localReads = 0
        // Initial entry and explicit pull-to-refresh share the exact pipeline.
        for _ in 0..<2 {
            let counts = try await AuthorizedLocalReportRead.run(
                authorize: { 7 },
                readDiagnostics: { localReads += 1; return [701, 302] },
                compose: { $0.reduce(0, +) },
                validate: { XCTAssertEqual($0, 7) }
            )
            XCTAssertEqual(counts, 1003)
            XCTAssertFalse(healthCompleted)
        }
        XCTAssertEqual(localReads, 2)
        _ = healthTask // No elapsed time, provider reply or poll advance was needed.
    }

    func testAuthorizationCancellationNeverReadsDiagnosticsOrComposes() async {
        var read = false, composed = false
        do {
            _ = try await AuthorizedLocalReportRead.run(
                authorize: { () -> Int in throw Denied.cancelled },
                readDiagnostics: { read = true; return 1 },
                compose: { composed = true; return $0 },
                validate: { _ in }
            )
            XCTFail("Cancelled authorization must not produce a report")
        } catch {}
        XCTAssertFalse(read)
        XCTAssertFalse(composed)
    }

    func testRevocationDuringLocalReadRejectsLateResultBeforeCompose() async {
        var currentGrant = 1, composed = false
        do {
            _ = try await AuthorizedLocalReportRead.run(
                authorize: { currentGrant },
                readDiagnostics: { await Task.yield(); currentGrant = 2; return 1003 },
                compose: { composed = true; return $0 },
                validate: { guard $0 == currentGrant else { throw Denied.revoked } }
            )
            XCTFail("A revoked result must not publish")
        } catch {}
        XCTAssertFalse(composed)
    }

    func testPolicyChangeDuringCompositionRejectsDelivery() async {
        var valid = true
        do {
            _ = try await AuthorizedLocalReportRead.run(
                authorize: { 1 }, readDiagnostics: { 1003 },
                compose: { valid = false; return $0 },
                validate: { _ in guard valid else { throw Denied.revoked } }
            )
            XCTFail("Changed policy must not publish")
        } catch {}
    }
}
