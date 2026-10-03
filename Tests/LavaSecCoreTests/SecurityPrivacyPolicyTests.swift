import XCTest
@testable import LavaSecKit

final class SecurityPrivacyPolicyTests: XCTestCase {
    private func cover(
        _ availability: SecurityAuthenticationAvailability,
        _ surfaces: Set<SecurityProtectedSurface> = [],
        gatesAvailable: Bool = true,
        protectedDataAvailable: Bool = true
    ) -> Bool {
        SecurityPrivacyPolicy.requiresBackgroundCover(
            authenticationAvailability: availability,
            protectedSurfaces: surfaces,
            gatesAreAvailable: gatesAvailable,
            protectedDataIsAvailable: protectedDataAvailable
        )
    }

    func testConfirmedNoCredentialDoesNotCoverTheInactiveScreen() {
        XCTAssertFalse(cover(.absent))
    }

    func testCredentialSetupWithoutSelectedSurfacesDoesNotOptIntoConcealment() {
        XCTAssertFalse(cover(.available))
    }

    func testEverySelectedSurfaceConcealsItsAlreadyVisibleContent() {
        for surface in SecurityProtectedSurface.allCases {
            XCTAssertTrue(cover(.available, [surface]), surface.rawValue)
        }
    }

    func testConfirmedCredentialRemovalRetiresOldChoices() {
        XCTAssertFalse(cover(.absent, Set(SecurityProtectedSurface.allCases)))
    }

    func testUnreadableCredentialsAreNotAnOffChoice() {
        XCTAssertTrue(cover(.unavailable))
        XCTAssertTrue(cover(.unavailable, [.appUnlock]))
    }

    func testFailedGatePublicationKeepsEveryCredentialStateCovered() {
        for availability in [SecurityAuthenticationAvailability.absent, .available, .unavailable] {
            XCTAssertTrue(cover(availability, gatesAvailable: false))
        }
    }

    func testProtectedDataAvailabilityDoesNotOptConfirmedOffIntoConcealment() {
        for availability in [SecurityAuthenticationAvailability.absent, .available] {
            for dataAvailable in [true, false] {
                XCTAssertFalse(cover(availability, protectedDataAvailable: dataAvailable))
            }
        }
    }

    func testSelectedAndUnknownSecurityRemainCoveredAcrossProtectedDataLoss() {
        for dataAvailable in [true, false] {
            for surface in SecurityProtectedSurface.allCases {
                XCTAssertTrue(cover(.available, [surface], protectedDataAvailable: dataAvailable))
            }
            XCTAssertTrue(cover(.unavailable, protectedDataAvailable: dataAvailable))
            for availability in [SecurityAuthenticationAvailability.absent, .available, .unavailable] {
                XCTAssertTrue(cover(availability, gatesAvailable: false, protectedDataAvailable: dataAvailable))
            }
        }
    }

    func testLastSettingAndAvailabilityTransitionsUseTheCurrentChoice() {
        XCTAssertFalse(cover(.available))
        XCTAssertTrue(cover(.available, [.activityViewing]))
        XCTAssertTrue(cover(.available, [.activityViewing, .appUnlock]))
        XCTAssertTrue(cover(.available, [.appUnlock]))
        XCTAssertFalse(cover(.available))
        XCTAssertTrue(cover(.unavailable))
        XCTAssertFalse(cover(.available))
        XCTAssertFalse(cover(.absent))
    }

    func testPreLockAndUnlockKeepTheCurrentConcealmentChoice() {
        XCTAssertFalse(cover(.available))
        XCTAssertFalse(cover(.available, protectedDataAvailable: false))
        XCTAssertFalse(cover(.available))
        XCTAssertTrue(cover(.available, [.activityViewing], protectedDataAvailable: false))
        XCTAssertTrue(cover(.available, [.activityViewing]))
    }

    func testRevealedPrivateDraftKeepsItsAppearanceAcrossAllOffInactivity() {
        for active in [true, false] {
            XCTAssertFalse(SecurityPrivacyPolicy.requiresPrivateDraftCover(
                isRevealed: true, applicationIsActive: active, backgroundCoverRequired: false))
        }
    }

    func testUnrevealedPrivateDraftDoesNotBecomeVisibleThroughTheAllOffChoice() {
        for active in [true, false] {
            for backgroundCover in [true, false] {
                XCTAssertTrue(SecurityPrivacyPolicy.requiresPrivateDraftCover(
                    isRevealed: false, applicationIsActive: active, backgroundCoverRequired: backgroundCover))
            }
        }
    }

    func testPhoneLockPreservesOnlyAnExplicitlyRevealedConfirmedOffDraft() {
        let off = cover(.available, protectedDataAvailable: false)
        XCTAssertFalse(SecurityPrivacyPolicy.requiresPrivateDraftCover(
            isRevealed: true, applicationIsActive: false, backgroundCoverRequired: off))
        XCTAssertTrue(SecurityPrivacyPolicy.requiresPrivateDraftCover(
            isRevealed: false, applicationIsActive: false, backgroundCoverRequired: off))
    }

    func testSelectedProtectionOverridesThePriorAllOffDraftAppearance() {
        XCTAssertFalse(SecurityPrivacyPolicy.requiresPrivateDraftCover(
            isRevealed: true, applicationIsActive: false, backgroundCoverRequired: false))
        XCTAssertTrue(SecurityPrivacyPolicy.requiresPrivateDraftCover(
            isRevealed: true, applicationIsActive: false, backgroundCoverRequired: true))
        XCTAssertTrue(SecurityPrivacyPolicy.requiresPrivateDraftCover(
            isRevealed: false, applicationIsActive: true, backgroundCoverRequired: false))
    }
}
