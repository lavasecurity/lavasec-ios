import XCTest
import LavaSecAppServices

/// Cross-target wiring; grant, ciphertext and race behavior is executable in service tests.
final class PresentationCacheBoundarySourceTests: XCTestCase {
    func testOwnedBiometricPromptPublishesDisplayMetadataSynchronouslyWithoutGrantingReads() throws {
        let controller = try readSource(.securityController)
        XCTAssertTrue(controller.contains("@Published private(set) var isBiometricAuthenticationInProgress = false"))
        let evaluation = try sourceBlock(in: controller, startingAt: "private func evaluateBiometrics(", endingBefore: "private func requestPasscode(")
        let marksPrompt = try XCTUnwrap(evaluation.range(of: "isBiometricAuthenticationInProgress = true"))
        let beginsSystemPrompt = try XCTUnwrap(evaluation.range(of: "context.evaluatePolicy("))
        XCTAssertLessThan(marksPrompt.lowerBound, beginsSystemPrompt.lowerBound)
        let bridge = try readSource(.reactNativeAppBridge)
        let prompt = try sourceBlock(in: bridge, startingAt: "security.$isBiometricAuthenticationInProgress.removeDuplicates().sink", endingBefore: "model.account.objectWillChange.sink")
        XCTAssertTrue(prompt.contains("MainActor.assumeIsolated"))
        XCTAssertFalse(prompt.contains("Task {"), "The incoming @Published value must precede the system's inactive notification.")
        let incoming = try XCTUnwrap(prompt.range(of: "self?.presentationAuthenticationInProgress = inProgress"))
        let publication = try XCTUnwrap(prompt.range(of: "self?.publish()"))
        XCTAssertLessThan(incoming.lowerBound, publication.lowerBound, "Compose the incoming value rather than @Published's old willSet property value.")
        let continuity = try sourceBlock(in: bridge, startingAt: "private var authenticationInProgressForPresentation: Bool", endingBefore: "@objc func snapshot()")
        XCTAssertTrue(continuity.contains("UIApplication.shared.applicationState != .background"))
        XCTAssertTrue(continuity.contains("security.hasCurrentAuthorization(for: .appUnlock)"))
        XCTAssertTrue(continuity.contains("security.passcodeAuthenticationRequest == nil"))
        let snapshot = try sourceBlock(in: bridge, startingAt: "@objc func snapshot()", endingBefore: "@objc func command(")
        XCTAssertEqual(snapshot.components(separatedBy: "\"authenticationInProgress\": authenticationInProgressForPresentation").count - 1, 2)
        let queries = try readSource(.reactNativeAppQueries)
        let authority = try sourceBlock(in: queries, startingAt: "func canReadPresentation(", endingBefore: "var presentationClearRevision:")
        XCTAssertTrue(authority.contains("UIApplication.shared.applicationState == .active"))
        XCTAssertTrue(authority.contains("security.hasCurrentAuthorization(for: surface)"))
        XCTAssertFalse(authority.contains("authenticationInProgress"), "Display metadata must never authorize native reads.")
    }

    func testHardPrivacyBoundariesRetireAuthenticationDisplayAndPublishOnlyOpaqueOwnership() throws {
        let bridge = try readSource(.reactNativeAppBridge)
        let boundary = try sourceBlock(in: bridge, startingAt: "private func publishPrivacyBoundary()", endingBefore: "@objc func observe(")
        XCTAssertTrue(boundary.contains("\"authenticationInProgress\": false"))
        XCTAssertTrue(boundary.contains("\"presentationRevoked\": true"))
        XCTAssertTrue(boundary.contains("\"security\": [\"ownerRevision\": presentationOwnerRevision.revision("))
        XCTAssertFalse(boundary.contains("snapshot()"))
        for notification in ["UIApplication.didEnterBackgroundNotification", "UIApplication.protectedDataWillBecomeUnavailableNotification"] {
            let start = try XCTUnwrap(bridge.range(of: notification))
            let tail = String(bridge[start.lowerBound...])
            let end = try XCTUnwrap(tail.range(of: ".store(in: &subscriptions)"))
            let owner = tail[..<end.lowerBound]
            XCTAssertTrue(owner.contains("MainActor.assumeIsolated"))
            XCTAssertTrue(owner.contains("presentationCache.invalidate()"))
            XCTAssertTrue(owner.contains("publishPrivacyBoundary()"))
            XCTAssertFalse(owner.contains("Task {"))
        }
        let blocked = try sourceBlock(in: bridge, startingAt: "guard canReadPresentation(.appUnlock) else", endingBefore: "let m = model, c = model.customization")
        XCTAssertTrue(blocked.contains("\"presentationRevoked\": UIApplication.shared.applicationState == .background || !security.hasCurrentAuthorization(for: .appUnlock)"))
        XCTAssertTrue(blocked.contains("\"security\": [\"ownerRevision\": presentationOwnerRevision.revision("))
        XCTAssertFalse(blocked.contains("\"session\""))
        XCTAssertFalse(blocked.contains("\"filters\""))
    }

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
            let owner = tail[..<end.lowerBound]
            XCTAssertTrue(owner.contains("presentationCache.invalidate()"))
            XCTAssertTrue(owner.contains("MainActor.assumeIsolated"))
            XCTAssertFalse(owner.contains("Task {"), "Retirement must precede deferred bridge delivery: " + boundary)
        }
        XCTAssertEqual(bridge.components(separatedBy: "security.$viewAuthenticationRevision").count - 1, 1)
        let securityOwner = try sourceBlock(in: bridge,
            startingAt: "security.$viewAuthenticationRevision.removeDuplicates().dropFirst().sink",
            endingBefore: "NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)")
        XCTAssertTrue(securityOwner.contains("shareCardSecurityChanged(revision: revision)"))
        XCTAssertTrue(securityOwner.contains("presentationCache.invalidate()"))
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
