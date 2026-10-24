import XCTest
@testable import LavaSecKit

final class SecurityPrivacyPolicyTests: XCTestCase {
    func testPrivateDraftDisplayRetentionRequiresAnAcceptedRevealedCurrentOffVisit() {
        let cases: [(accepted: Bool, current: Bool, covered: Bool, retained: Bool)] = [
            (false, false, false, false), (false, false, true, false),
            (false, true, false, false), (false, true, true, false),
            (true, false, false, false), (true, false, true, false),
            (true, true, false, true), (true, true, true, false),
        ]
        for sample in cases {
            XCTAssertEqual(SecurityPrivacyPolicy.canRetainAcceptedPrivateDraftDisplay(
                hasAcceptedRevealedDisplay: sample.accepted, ownerIsCurrent: sample.current,
                backgroundCoverRequired: sample.covered), sample.retained, "\(sample)")
        }
    }

    func testAnOffMarkerCannotReviveAConcealedOrReplacedPrivateDraftDisplay() {
        var accepted = true
        XCTAssertTrue(SecurityPrivacyPolicy.canRetainAcceptedPrivateDraftDisplay(
            hasAcceptedRevealedDisplay: accepted, ownerIsCurrent: true, backgroundCoverRequired: false))
        accepted = false // A concealment boundary or visit replacement retires the painted frame.
        XCTAssertFalse(SecurityPrivacyPolicy.canRetainAcceptedPrivateDraftDisplay(
            hasAcceptedRevealedDisplay: accepted, ownerIsCurrent: true, backgroundCoverRequired: false))
        XCTAssertFalse(SecurityPrivacyPolicy.canRetainAcceptedPrivateDraftDisplay(
            hasAcceptedRevealedDisplay: true, ownerIsCurrent: false, backgroundCoverRequired: false))
    }

    func testOnlyTheSavedAppUnlockChoiceControlsTheGlobalCover() {
        XCTAssertFalse(SecurityPrivacyPolicy.requiresBackgroundCover(appUnlockIsSelected: false))
        XCTAssertTrue(SecurityPrivacyPolicy.requiresBackgroundCover(appUnlockIsSelected: true))
        XCTAssertTrue(SecurityPrivacyPolicy.requiresBackgroundCover(appUnlockIsSelected: nil),
                      "An unreadable cold-launch choice cannot be assumed OFF")
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
        let off = SecurityPrivacyPolicy.requiresBackgroundCover(appUnlockIsSelected: false)
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
