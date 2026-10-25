import XCTest

final class ProtectionLifecycleExecutionSourceTests: XCTestCase {
    func testAppInstallsExecutionTimeBeforeStartingServices() throws {
        let source = try readSource(.lavaSecApp)
        let app = try sourceBlock(in: source, startingAt: "struct LavaSecApp: App {", endingBefore: "var body: some Scene")
        let install = try XCTUnwrap(app.range(of: "LavaProtectionLifecycleBackgroundExecution.install()")?.lowerBound)
        let shortcuts = try XCTUnwrap(app.range(of: "LavaShortcuts.updateAppShortcutParameters()")?.lowerBound)
        XCTAssertLessThan(install, shortcuts)
        let adapter = try sourceBlock(in: source,
            startingAt: "private enum LavaProtectionLifecycleBackgroundExecution", endingBefore: "private enum LavaBackgroundTaskScheduling")
        XCTAssertTrue(adapter.contains("ProtectionLifecycleExecution.beginBackgroundExecution ="))
        XCTAssertTrue(adapter.contains("UIApplication.shared.beginBackgroundTask"))
        XCTAssertTrue(adapter.contains("guard identifier != .invalid else { return nil }"))
        XCTAssertTrue(adapter.contains("MainActor.assumeIsolated { expire() }"))
        XCTAssertTrue(adapter.contains("return { UIApplication.shared.endBackgroundTask(identifier) }"))
    }

    func testDirectRestartAlsoObtainsExecutionTimeBeforeTakingItsRawFence() throws {
        let service = try readSource(.lavaProtectionCommandService)
        let restart = try sourceBlock(in: service,
            startingAt: "private static func performReconnect() async throws", endingBefore: "/// Re-derives the honest post-restart state")
        XCTAssertTrue(restart.contains("try await ProtectionLifecycleExecution.run"))
        XCTAssertTrue(restart.contains("try await performReconnectWithExecutionTime()"))
        XCTAssertTrue(restart.contains("try await claimRestartInFlight("))
    }
}
