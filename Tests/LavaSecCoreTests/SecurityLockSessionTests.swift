import XCTest
@testable import LavaSecKit

final class SecurityLockSessionTests: XCTestCase {
    func testFreshSessionHasNoImplicitSurfaceAuthorization() {
        let session = SecurityLockSession()
        XCTAssertFalse(session.appUnlocked)
        XCTAssertFalse(session.credentialAuthorized)
        XCTAssertTrue(session.surfaces.isEmpty)
        XCTAssertFalse(session.hasSuspendedVisit)
    }

    func testOneUnlockRestoresOnlyThePreviouslyAuthorizedVisit() {
        var session = SecurityLockSession()
        XCTAssertTrue(session.authorize(.activityViewing, ticket: session.ticket()))
        session.suspend()
        XCTAssertFalse(session.appUnlocked)
        XCTAssertTrue(session.surfaces.isEmpty, "Suspended identity grants no locked read authority")
        session.enterForeground()
        XCTAssertTrue(session.authorize(.appUnlock, ticket: session.ticket(appUnlock: true)))
        XCTAssertTrue(session.appUnlocked)
        XCTAssertEqual(session.surfaces, [.activityViewing])
        XCTAssertFalse(session.surfaces.contains(.filterEditing))
        XCTAssertFalse(session.credentialAuthorized)
        XCTAssertFalse(session.hasSuspendedVisit)
    }

    func testSettingsAndItsOpenCredentialScreenResumeTogether() {
        var session = SecurityLockSession()
        session.authorize(.appSettings, ticket: session.ticket())
        session.authorize(nil, ticket: session.ticket())
        session.suspend()
        XCTAssertFalse(session.credentialAuthorized)
        session.enterForeground()
        session.authorize(.appUnlock, ticket: session.ticket(appUnlock: true))
        XCTAssertEqual(session.surfaces, [.appSettings])
        XCTAssertTrue(session.credentialAuthorized)
        session.endViewTurn()
        XCTAssertFalse(session.credentialAuthorized)
        XCTAssertTrue(session.surfaces.isEmpty)
        XCTAssertTrue(session.appUnlocked, "Leaving a page does not relock the entire app")
    }

    func testRepeatedBoundaryReportsDoNotLoseTheSuspendedVisit() {
        var session = SecurityLockSession()
        session.authorize(.filterEditing, ticket: session.ticket())
        session.suspend()
        let revision = session.viewRevision
        session.suspend()
        XCTAssertEqual(session.viewRevision, revision)
        session.enterForeground()
        session.authorize(.appUnlock, ticket: session.ticket(appUnlock: true))
        XCTAssertEqual(session.surfaces, [.filterEditing])
    }

    func testBackgroundingAgainAfterCancellationPreservesTheOriginalVisitIntent() {
        var session = SecurityLockSession()
        session.authorize(.activityViewing, ticket: session.ticket())
        session.authorize(nil, ticket: session.ticket())
        session.suspend()
        session.enterForeground()
        XCTAssertTrue(session.claimAutomaticUnlock())
        // Cancel without granting anything, then leave the still-locked app.
        session.suspend()
        session.enterForeground()
        XCTAssertTrue(session.claimAutomaticUnlock())
        session.authorize(.appUnlock, ticket: session.ticket(appUnlock: true))
        XCTAssertEqual(session.surfaces, [.activityViewing])
        XCTAssertTrue(session.credentialAuthorized)
    }

    func testFaceIDActivationAndCancellationCannotStartAnAutomaticSecondPrompt() {
        var session = SecurityLockSession()
        XCTAssertTrue(session.claimAutomaticUnlock())
        session.enterForeground() // Face ID became inactive then active; no background.
        XCTAssertFalse(session.claimAutomaticUnlock())
        XCTAssertFalse(session.appUnlocked)
        XCTAssertTrue(session.authorize(.appUnlock, ticket: session.ticket(appUnlock: true)), "Explicit Retry can still succeed")
        session.suspend()
        XCTAssertFalse(session.claimAutomaticUnlock())
        session.enterForeground()
        XCTAssertTrue(session.claimAutomaticUnlock(), "A real new foreground session gets one attempt")
    }

    func testOldBiometricAndPasscodeCompletionsCannotUnlockANewForeground() {
        var session = SecurityLockSession()
        let appTicket = session.ticket(appUnlock: true), viewTicket = session.ticket()
        session.suspend()
        XCTAssertFalse(session.authorize(.appUnlock, ticket: appTicket))
        session.enterForeground()
        XCTAssertFalse(session.authorize(.appUnlock, ticket: appTicket))
        XCTAssertFalse(session.authorize(nil, ticket: viewTicket))
        XCTAssertFalse(session.appUnlocked)
        XCTAssertTrue(session.surfaces.isEmpty)
    }

    func testLeavingTheSuspendedVisitWhileUnlockingCannotRestoreIt() {
        var session = SecurityLockSession()
        session.authorize(.activityViewing, ticket: session.ticket())
        session.suspend()
        session.enterForeground()
        let appTicket = session.ticket(appUnlock: true)
        session.endViewTurn()
        XCTAssertTrue(session.authorize(.appUnlock, ticket: appTicket))
        XCTAssertTrue(session.surfaces.isEmpty)
    }

    func testCredentialOrOwnerResetDiscardsResumeIntentAndPendingUnlock() {
        var session = SecurityLockSession()
        session.authorize(nil, ticket: session.ticket())
        session.suspend()
        session.enterForeground()
        let old = session.ticket(appUnlock: true)
        session.reset()
        XCTAssertFalse(session.authorize(.appUnlock, ticket: old))
        session.authorize(.appUnlock, ticket: session.ticket(appUnlock: true))
        XCTAssertFalse(session.credentialAuthorized)
    }

    func testProtectionActionsDoNotCreateAResumeLockOnGuard() {
        var session = SecurityLockSession()
        session.authorize(.protectionControl, ticket: session.ticket())
        session.authorize(.protectionPause, ticket: session.ticket())
        session.suspend()
        XCTAssertFalse(session.hasSuspendedVisit)
        session.enterForeground()
        session.authorize(.appUnlock, ticket: session.ticket(appUnlock: true))
        XCTAssertTrue(session.surfaces.isEmpty)
    }

    func testPolicyChangeKeepsTheCurrentCredentialVisitButRevokesReaders() {
        var session = SecurityLockSession()
        let old = session.ticket()
        session.authorize(nil, ticket: old)
        session.authorize(.appSettings, ticket: old)
        session.endViewTurn(preservingCredentials: true)
        XCTAssertFalse(session.contains(old))
        XCTAssertTrue(session.credentialAuthorized)
        XCTAssertTrue(session.surfaces.isEmpty)
        session.suspend()
        session.enterForeground()
        session.authorize(.appUnlock, ticket: session.ticket(appUnlock: true))
        XCTAssertTrue(session.credentialAuthorized)
    }

    func testEnablingAppUnlockAppliesOnNextBackground() {
        var session = SecurityLockSession()
        session.setAppUnlockEnabled(true)
        session.endViewTurn()
        XCTAssertTrue(session.appUnlocked)
        session.suspend()
        XCTAssertFalse(session.appUnlocked)
    }

    func testTicketCannotBeAppliedToADifferentKindOfAuthorization() {
        var session = SecurityLockSession()
        XCTAssertFalse(session.authorize(.appUnlock, ticket: session.ticket()))
        XCTAssertFalse(session.authorize(.activityViewing, ticket: session.ticket(appUnlock: true)))
        XCTAssertFalse(session.authorize(nil, ticket: session.ticket(appUnlock: true)))
        XCTAssertFalse(session.appUnlocked)
        XCTAssertTrue(session.surfaces.isEmpty)
        XCTAssertFalse(session.credentialAuthorized)
    }
}
