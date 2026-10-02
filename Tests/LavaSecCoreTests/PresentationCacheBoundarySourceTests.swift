import XCTest
import LavaSecAppServices

/// Cross-target wiring; grant, ciphertext and race behavior is executable in service tests.
final class PresentationCacheBoundarySourceTests: XCTestCase {
    func testNativeDisplayScopeUsesOpaqueOwnershipAndDestructiveSourceBoundaries() throws {
        let bridge = try readSource(.reactNativeAppBridge)
        XCTAssertTrue(bridge.contains("presentationOwnerRevision.revision(for: m.account.accountAuthState.connections.all.map { $0.session.userID })"))
        XCTAssertTrue(bridge.contains("model.$library.removeDuplicates().sink"))
        XCTAssertTrue(bridge.contains("presentationLibraryRevision.revision(for: library)"))
        let libraryOwner = try sourceBlock(in: bridge, startingAt: "model.$library.removeDuplicates().sink", endingBefore: "security.$viewAuthenticationRevision")
        XCTAssertTrue(libraryOwner.contains("if current != self.presentationLibraryDisplayRevision"))
        XCTAssertTrue(libraryOwner.contains("presentationSourceGeneration &+= 1"))
        XCTAssertTrue(libraryOwner.contains("presentationCache.invalidate()"))
        XCTAssertTrue(bridge.contains("\"displayClearRevision\": \"\\(presentationDisplayClearGeneration):\\(presentationClearRevision)"))
        let settings = try readSource(.reactNativeAppSettings)
        let clears = try sourceBlock(in: settings, startingAt: "func clearLogs(", endingBefore: "extension LavaAppBridge")
        for target in ["filteringCounts", "domainHistory", "networkActivity", "lavaGuardProgress", "all"] {
            XCTAssertTrue(clears.contains("case ." + target + ":"))
        }
        XCTAssertTrue(clears.contains("presentationDisplayClearGeneration &+= 1"))
    }

    func testEveryNativeQueryDeclaresAStoragePolicyAndFinalBridgeDeliveryValidates() throws {
        let source = try readSource(.reactNativeAppQueries)
        let body = try sourceBlock(in: source, startingAt: "private func freshQuery(", endingBefore: "func setActivityVisibility(")
        let regex = try NSRegularExpression(pattern: #"\"([a-z]+\.(?:query|stage))\""#)
        let queries = Set(regex.matches(in: body, range: NSRange(body.startIndex..<body.endIndex, in: body)).compactMap { match -> String? in
            guard let range = Range(match.range(at: 1), in: body) else { return nil }
            return String(body[range])
        })
        XCTAssertEqual(queries, Set(PresentationReadPolicy.allCases.map(\.rawValue)))
        XCTAssertTrue(source.contains("guard let policy = PresentationReadPolicy(rawValue: name) else"))
        let bridge = try readSource(.reactNativeAppBridge)
        let delivery = try sourceBlock(in: bridge, startingAt: "@objc func command(", endingBefore: "func perform(")
        XCTAssertTrue(delivery.contains("try privateRead.validate()"))
        XCTAssertTrue(delivery.contains("result = privateRead.value"))
    }
    func testLifecycleAndAccountOwnersInvalidateTheOnlyNativeCache() throws {
        let bridge = try readSource(.reactNativeAppBridge)
        for boundary in ["security.$viewAuthenticationRevision", "model.account.objectWillChange.sink", "UIApplication.willResignActiveNotification", "UIApplication.protectedDataWillBecomeUnavailableNotification"] {
            let start = try XCTUnwrap(bridge.range(of: boundary))
            let tail = String(bridge[start.lowerBound...])
            let end = try XCTUnwrap(tail.range(of: ".store(in: &subscriptions)"))
            XCTAssertTrue(tail[..<end.lowerBound].contains("presentationCache.invalidate()"))
        }
        let js = try readSource(.reactNativeAppReadCache)
        XCTAssertFalse(js.contains("QueryClient"))
        XCTAssertTrue(js.contains("boolean { return false; }"))
    }
    func testQualificationProbesRequireResidentRulesAndCollectActualMetrics() throws {
        let source = try readSource(.appViewModelQATooling)
        let probes = try sourceBlock(in: source, startingAt: "private func runQATransitionProbe(", endingBefore: "private func runQALocalDNSBridge(")
        XCTAssertTrue(probes.contains("controlled-fixture-resident-rules"))
        XCTAssertFalse(probes.contains("applyingQAProbeSet"))
        XCTAssertTrue(probes.contains("uniqueNames: true"))
        XCTAssertTrue(probes.contains("sharedSession: true"))
        XCTAssertTrue(probes.contains("session.data(for: request, delegate: observer)"))
        XCTAssertTrue(source.contains("didFinishCollecting metrics: URLSessionTaskMetrics"))
        XCTAssertTrue(source.contains("metrics.transactionMetrics.map(\\.isReusedConnection)"))
    }
}
