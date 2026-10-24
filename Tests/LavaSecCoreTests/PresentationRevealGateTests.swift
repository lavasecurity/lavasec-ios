import XCTest
import LavaSecPresentation

final class PresentationRuntimeOwnershipTests: XCTestCase {
    private func owner(_ kind: String = "backup", _ id: String = "visit", _ instance: String = "first") -> PresentationRuntimeOwnership.Owner {
        .init(kind: kind, id: id, identity: instance)
    }
    func testPreviewRetirementCannotClearTheMainCredentialOwner() {
        var policy = PresentationRuntimeOwnership(); let main = UUID(), preview = UUID(), secret = owner()
        XCTAssertTrue(policy.register(main)); XCTAssertTrue(policy.register(preview))
        XCTAssertTrue(policy.claim(secret, runtime: main))
        XCTAssertFalse(policy.claim(secret, runtime: preview))
        XCTAssertTrue(policy.invalidate(preview).isEmpty)
        XCTAssertTrue(policy.isActive(main))
        XCTAssertEqual(policy.invalidate(main), [secret])
        XCTAssertFalse(policy.hasActiveRuntimes)
    }
    func testReplacingAnInstanceReleasesItsPriorLeaseEvenWhenTheVisitIDMatches() {
        var policy = PresentationRuntimeOwnership(); let oldRuntime = UUID(), newRuntime = UUID()
        policy.register(oldRuntime); policy.register(newRuntime)
        let old = owner(), replacement = owner("backup", "visit", "replacement")
        XCTAssertTrue(policy.claim(old, runtime: oldRuntime))
        XCTAssertTrue(policy.claim(replacement, runtime: newRuntime))
        XCTAssertTrue(policy.invalidate(oldRuntime).isEmpty)
        XCTAssertEqual(policy.invalidate(newRuntime), [replacement])
    }
    func testTheAuthenticationPresenterCanRetireItsLeaseWithoutWipingTheInitiatingRuntime() {
        var policy = PresentationRuntimeOwnership(); let initiator = UUID(), presenter = UUID()
        policy.register(initiator); policy.register(presenter)
        let account = owner(), passcode = owner("passcode", "authentication", "credential-buffer")
        policy.claim(account, runtime: initiator); policy.claim(passcode, runtime: initiator)
        XCTAssertTrue(policy.claim(passcode, runtime: presenter, presenter: true))
        XCTAssertEqual(policy.invalidate(presenter), [passcode])
        XCTAssertTrue(policy.isActive(initiator))
        XCTAssertEqual(policy.invalidate(initiator), [account])
    }
    func testAnInvalidatedRuntimeCannotReopenOrRegisterAPostAwaitOwner() {
        var policy = PresentationRuntimeOwnership(); let runtime = UUID()
        policy.register(runtime); XCTAssertTrue(policy.invalidate(runtime).isEmpty)
        XCTAssertFalse(policy.isActive(runtime))
        XCTAssertFalse(policy.register(runtime))
        XCTAssertFalse(policy.claim(owner(), runtime: runtime))
        XCTAssertFalse(policy.claim(owner("passcode"), runtime: runtime, presenter: true))
        XCTAssertTrue(policy.invalidate(runtime).isEmpty)
    }
    func testLastRuntimeDetachmentAllowsCleanupBeforeANativeEntryHasItsFirstClaim() {
        var policy = PresentationRuntimeOwnership(); let main = UUID(), security = UUID()
        policy.register(main); policy.register(security)
        // Native authentication may exist before passcode.header can claim it.
        // With another real renderer alive, its absent lease is not a global wipe.
        XCTAssertTrue(policy.invalidate(security).isEmpty)
        XCTAssertTrue(policy.hasActiveRuntimes)
        XCTAssertTrue(policy.invalidate(main).isEmpty)
        XCTAssertFalse(policy.hasActiveRuntimes)
        // A delayed header cannot recreate ownership after final teardown.
        XCTAssertFalse(policy.claim(owner("passcode", "native-authentication"), runtime: security, presenter: true))
    }
    func testLongLivedRuntimesRetainOnlyTheCurrentIdentityOfEachNativeKind() {
        var policy = PresentationRuntimeOwnership(); let runtime = UUID(); policy.register(runtime)
        for index in 0..<100 { XCTAssertTrue(policy.claim(owner("backup", "visit-\(index)", "instance-\(index)"), runtime: runtime)) }
        let qa = owner("qa"); policy.claim(qa, runtime: runtime)
        XCTAssertEqual(policy.invalidate(runtime), [owner("backup", "visit-99", "instance-99"), qa])
    }
}

final class PresentationRevealGateTests: XCTestCase {
    func testColdRootAndRetainedSheetMustBothCommit() {
        var gate = PresentationRevealGate()
        gate.mount("root"); gate.mount("sheet")
        gate.acknowledge("root", token: gate.token, authorized: true)
        XCTAssertTrue(gate.required)
        gate.acknowledge("sheet", token: gate.token, authorized: true)
        XCTAssertFalse(gate.required)
    }

    func testOldOrUnauthorizedFramesCannotRevealAfterBackground() {
        var gate = PresentationRevealGate()
        gate.mount("root")
        let old = gate.token
        gate.conceal()
        gate.acknowledge("root", token: old, authorized: true)
        gate.acknowledge("root", token: gate.token, authorized: false)
        gate.acknowledge("unknown", token: gate.token, authorized: true)
        XCTAssertTrue(gate.required)
        gate.acknowledge("root", token: gate.token, authorized: true)
        XCTAssertFalse(gate.required)
    }

    func testDismissedSheetCannotStrandOrReleaseReplacement() {
        var gate = PresentationRevealGate()
        gate.mount("root"); gate.mount("old")
        gate.acknowledge("root", token: gate.token, authorized: true)
        gate.mount("replacement"); gate.unmount("old")
        gate.acknowledge("old", token: gate.token, authorized: true)
        XCTAssertTrue(gate.required)
        gate.unmount("replacement")
        XCTAssertFalse(gate.required)
    }

    func testOrdinaryNewSheetDoesNotRelockTheApp() {
        var gate = PresentationRevealGate()
        gate.mount("root")
        gate.acknowledge("root", token: gate.token, authorized: true)
        gate.mount("sheet")
        XCTAssertFalse(gate.required)
        gate.conceal()
        gate.acknowledge("root", token: gate.token, authorized: true)
        XCTAssertTrue(gate.required)
    }

    func testEnablingAppUnlockDuringAnOffHandoffCannotCreateAnActiveSessionCover() {
        var gate = PresentationRevealGate(appCoverRequired: false)
        gate.mount("root")
        XCTAssertTrue(gate.required, "Readiness and app cover ownership are independent")
        XCTAssertFalse(gate.appCoverRequired)
        gate.conceal(appCoverRequired: false)
        let old = gate.token
        // The user enables Open Lava before this OFF frame's delayed ACK.
        // Only the next actual boundary may capture that new choice.
        XCTAssertFalse(gate.appCoverRequired)
        gate.mount("plus")
        XCTAssertFalse(gate.appCoverRequired, "Mounting a Plus renderer is not a privacy boundary")
        gate.conceal(appCoverRequired: true)
        XCTAssertTrue(gate.appCoverRequired)
        gate.acknowledge("root", token: old, authorized: true)
        XCTAssertTrue(gate.appCoverRequired)
        gate.acknowledge("root", token: gate.token, authorized: true)
        XCTAssertTrue(gate.appCoverRequired)
        gate.acknowledge("plus", token: gate.token, authorized: true)
        XCTAssertFalse(gate.appCoverRequired)
    }
}
