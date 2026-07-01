import XCTest
@testable import LavaSecCore

// Source-level guards for the bug-report submit hardening (App Attest headers +
// friendly rate-limit copy). These live in LavaSecApp (the Xcode app target,
// not built by `swift test`), so we assert on the source text — the same pattern
// as SettingsFeedbackSourceTests.
final class BugReportAttestSourceTests: XCTestCase {
    func testSubmitAttachesAppAttestHeadersAndFriendlyRateLimitCopy() throws {
        let source = try Self.appViewModelSource()
        // Covers submitBugReport plus its attestation helpers (acquireAppAttestation,
        // fetchAppAttestChallenge) — they all sit before startLavaSecurityPlusStore — so
        // every assertion below is scoped to the submit-and-attest surface, not the whole file.
        let submitAndAttestBlock = try Self.block(
            in: source,
            startingAt: "private func submitBugReport(",
            endingBefore: "private func startLavaSecurityPlusStore"
        )

        // App Attest is acquired once (bound to a hash of the exact request body — replay
        // hardening) and applied to each endpoint attempt.
        XCTAssertTrue(submitAndAttestBlock.contains("let bodyHash = Data(SHA256.hash(data: data))"))
        XCTAssertTrue(submitAndAttestBlock.contains("await Self.acquireAppAttestation(bodyHash: bodyHash)"))
        XCTAssertTrue(submitAndAttestBlock.contains("attestation?.apply(to: &request)"))
        // A 429 maps to a friendly, actionable message, not the raw HTTP dump.
        XCTAssertTrue(submitAndAttestBlock.contains("httpResponse.statusCode == 429"))
        XCTAssertTrue(submitAndAttestBlock.contains("Please wait a moment and try again."))
        // A 429 is terminal — rethrown via a dedicated catch, not failed over to
        // the fallback endpoint.
        XCTAssertTrue(submitAndAttestBlock.contains("throw BugReportRateLimitedError()"))
        XCTAssertTrue(submitAndAttestBlock.contains("catch is BugReportRateLimitedError"))
        // The challenge is fetched from the attest-challenge endpoint (scoped to the block).
        XCTAssertTrue(submitAndAttestBlock.contains("appendingPathComponent(\"attest-challenge\")"))
        // Best-effort attestation is latency-bounded so a slow challenge endpoint
        // cannot hang the submit.
        XCTAssertTrue(submitAndAttestBlock.contains("request.timeoutInterval = appAttestChallengeTimeout"))
    }

    func testAppAttestClientUsesDeviceCheckAndDegradesGracefully() throws {
        let source = try Self.appViewModelSource()
        let clientBlock = try Self.block(
            in: source,
            startingAt: "private enum AppAttestClient",
            // Bound the block to the enum itself — the comment on the line right after its
            // closing brace. Without this the block ran to EOF, making the fail-open assertion
            // below match any of the ~60 file-wide `return nil` occurrences (meaningless).
            endingBefore: "// EncryptedBackupState moved to LavaSecCore"
        )

        XCTAssertTrue(clientBlock.contains("DCAppAttestService.shared"))
        XCTAssertTrue(clientBlock.contains("service.isSupported"))
        XCTAssertTrue(clientBlock.contains("generateKey()"))
        XCTAssertTrue(clientBlock.contains("attestKey(keyId, clientDataHash: clientDataHash)"))
        // Replay hardening: clientDataHash = SHA256( utf8(challenge) ‖ bodyHash ), where
        // bodyHash = SHA256(request body). Must stay byte-identical to the server recompute
        // in backend/worker/src/app-attest.ts, so pin the exact construction here.
        XCTAssertTrue(clientBlock.contains("var clientData = Data(challenge.utf8)"))
        XCTAssertTrue(clientBlock.contains("clientData.append(bodyHash)"))
        XCTAssertTrue(clientBlock.contains("SHA256.hash(data: clientData)"))
        // Both fail-open paths are present: unsupported hardware (Simulator / no Secure
        // Enclave) and any thrown error during key-gen/attestation. The caller then submits
        // unattested. Assert the two guards plus a count of exactly two `return nil` in the
        // tightly-bounded enum — so deleting either fail-open path fails the test, without a
        // brittle whitespace-exact multi-line match that a re-indent would break.
        XCTAssertTrue(clientBlock.contains("guard service.isSupported else {"))
        XCTAssertTrue(clientBlock.contains("} catch {"))
        XCTAssertEqual(clientBlock.components(separatedBy: "return nil").count - 1, 2,
                       "AppAttestClient should have exactly two fail-open `return nil` paths")
    }

    // MARK: - helpers

    private static func appViewModelSource() throws -> String {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let packageRootURL = testFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = packageRootURL
            .appendingPathComponent("LavaSecApp")
            .appendingPathComponent("AppViewModel.swift")
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }

    private static func block(
        in source: String,
        startingAt startMarker: String,
        endingBefore endMarker: String
    ) throws -> String {
        let start = try XCTUnwrap(source.range(of: startMarker)?.lowerBound)
        let suffix = source[start...]
        guard endMarker != "*** end ***" else {
            return String(suffix)
        }
        let end = try XCTUnwrap(suffix.range(of: endMarker)?.lowerBound)
        return String(suffix[..<end])
    }
}
