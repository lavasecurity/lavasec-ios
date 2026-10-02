import XCTest

final class NerdStatsFreshnessSourceTests: XCTestCase {
    func testVisibleStatsCaptureIsReadOnlyAndQueueConfined() throws {
        let provider = try readPacketTunnelProviderSource()
        let read = try sourceBlock(in: provider,
            startingAt: "case LavaSecAppGroup.readTunnelHealthMessage:",
            endingBefore: "case LavaSecAppGroup.readProtectionStatusMessage:")
        XCTAssertTrue(read.contains("dnsStateQueue.async"))
        XCTAssertTrue(read.contains("self.tunnelLifecycleIsActive"))
        XCTAssertTrue(read.contains("var sample = self.health"))
        XCTAssertTrue(read.contains("sample.updatedAt = Date()"))
        XCTAssertTrue(read.contains("snapshotCounters()"))
        XCTAssertTrue(read.contains("JSONEncoder().encode(sample)"))
        for mutation in ["persistHealth", "flushSuppressed", "refreshConfiguration", "scheduleResolverSmokeProbe", "self.health ="] {
            XCTAssertFalse(read.contains(mutation), mutation)
        }
    }

    func testHandshakeReplyIsFencedToItsInitiatingSessionAndConfiguration() throws {
        let source = try readAppViewModelSource()
        let query = try sourceBlock(in: source,
            startingAt: "func queryChainedHandshakeObservation(",
            endingBefore: "var catalogCacheURL")
        let capturedDate = try XCTUnwrap(query.range(of: "let connectedAt = session.connectedDate")?.lowerBound)
        let capturedConfiguration = try XCTUnwrap(query.range(of: "let expectedConfiguration = configuration")?.lowerBound)
        let suspension = try XCTUnwrap(query.range(of: "let result = await withCheckedContinuation")?.lowerBound)
        let fence = try XCTUnwrap(query.range(of: "guard !Task.isCancelled, tunnelManager?.connection === session")?.lowerBound)
        let accepted = try XCTUnwrap(query.range(of: "return result")?.lowerBound)
        XCTAssertLessThan(capturedDate, suspension)
        XCTAssertLessThan(capturedConfiguration, suspension)
        XCTAssertLessThan(suspension, fence)
        XCTAssertLessThan(fence, accepted)
        XCTAssertTrue(query.contains("session.connectedDate == connectedAt"))
        XCTAssertTrue(query.contains("configuration == expectedConfiguration else {"))
    }

    func testRNStatsRendererFencesTheWholeCaptureAcrossAwaits() throws {
        let source = try readAppViewModelSource()
        let capture = try sourceBlock(in: source, startingAt: "func sampleTunnelStats()", endingBefore: "func listSummary(")
        let identity = try XCTUnwrap(capture.range(of: "let connection = tunnelManager?.connection")?.lowerBound)
        let health = try XCTUnwrap(capture.range(of: "await sampleTunnelHealthForStats()")?.lowerBound)
        let handshake = try XCTUnwrap(capture.range(of: "await queryChainedHandshakeStatus()")?.lowerBound)
        let validation = try XCTUnwrap(capture.range(of: "guard !Task.isCancelled, tunnelManager?.connection === connection")?.lowerBound)
        XCTAssertLessThan(identity, health)
        XCTAssertLessThan(health, handshake)
        XCTAssertLessThan(handshake, validation)
        XCTAssertTrue(capture.contains("connection?.connectedDate == connectedAt"))
        XCTAssertTrue(capture.contains("configuration == expectedConfiguration"))
        XCTAssertTrue(capture.contains("return (false, nil)"))
        let bridge = try readSource(.reactNativeAppQueries)
        XCTAssertTrue(bridge.contains("let sample = await model.sampleTunnelStats()"))
    }

    func testStatsAcquisitionCoalescesAndRejectsAReplacedConnection() throws {
        let source = try readAppViewModelSource()
        let sampling = try sourceBlock(in: source, startingAt: "func sampleTunnelHealthForStats()", endingBefore: "func listSummary(")
        XCTAssertTrue(sampling.contains("if let task = visibleStatsSamplingTask { return await task.value }"))
        XCTAssertTrue(sampling.contains("tunnelManager?.connection === session"))
        XCTAssertTrue(sampling.contains("session.connectedDate == connectedAt"))
        XCTAssertTrue(sampling.contains("configuration == expectedConfiguration"))
        XCTAssertTrue(sampling.contains("UIApplication.shared.applicationState == .active"))
        XCTAssertFalse(sampling.contains("requestTunnelHealthFlush"))
        XCTAssertFalse(sampling.contains("startVPNTunnel"))
    }
}
