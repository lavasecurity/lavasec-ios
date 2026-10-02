import XCTest
import LavaSecCore

final class SecurityProtectedSurfaceStorageTests: XCTestCase {
    private func withDefaults(_ body: (UserDefaults) -> Void) {
        let name = "security-defaults-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        body(defaults)
    }

    func testLegacyExplicitChoicesSurvivePendingNoticeAndRepeatedReconciliation() {
        let selections: [Set<SecurityProtectedSurface>] = [
            [], [.protectionPause], [.filterEditing], [.protectionPause, .filterEditing],
            Set(SecurityProtectedSurface.allCases)
        ]
        for choices in selections {
            withDefaults { defaults in
                // The pre-opt-in migration seeded this pair and set a pending notice.
                defaults.set(["protectionPause", "filterEditing"], forKey: SecurityProtectedSurfaceStorage.defaultsKeyName)
                defaults.set(true, forKey: "securitySurfaceDefaultsNoticePending")
                // Reproduce the old explicit-save writer: it replaced choices and marked
                // version 1, but did not clear the pending notice (app main at 7bdc0ecc).
                defaults.set(choices.map(\.rawValue).sorted(), forKey: SecurityProtectedSurfaceStorage.defaultsKeyName)
                defaults.set(1, forKey: "securitySurfacesMigratedVersion")

                SecurityProtectedSurfaceStorage.reconcileAuthentication(.unavailable, in: defaults)
                XCTAssertEqual(SecurityProtectedSurfaceStorage.loadProtectedSurfaces(from: defaults), choices)
                XCTAssertEqual(defaults.integer(forKey: "securitySurfacesMigratedVersion"), 1)
                XCTAssertTrue(defaults.bool(forKey: "securitySurfaceDefaultsNoticePending"))

                for availability: SecurityAuthenticationAvailability in [.available, .unavailable, .available] {
                    SecurityProtectedSurfaceStorage.reconcileAuthentication(availability, in: defaults)
                    XCTAssertEqual(SecurityProtectedSurfaceStorage.loadProtectedSurfaces(from: defaults), choices)
                    XCTAssertEqual(defaults.integer(forKey: "securitySurfacesMigratedVersion"), 2)
                    XCTAssertFalse(defaults.bool(forKey: "securitySurfaceDefaultsNoticePending"))
                }
            }
        }
    }

    func testAcknowledgedLegacyChoicesRemainProtected() {
        withDefaults { defaults in
            let choices: Set<SecurityProtectedSurface> = [.protectionPause, .filterEditing, .appUnlock]
            defaults.set(choices.map(\.rawValue), forKey: SecurityProtectedSurfaceStorage.defaultsKeyName)
            defaults.set(1, forKey: "securitySurfacesMigratedVersion")
            defaults.set(false, forKey: "securitySurfaceDefaultsNoticePending")
            for availability: SecurityAuthenticationAvailability in [.available, .unavailable, .available] {
                SecurityProtectedSurfaceStorage.reconcileAuthentication(availability, in: defaults)
                XCTAssertEqual(SecurityProtectedSurfaceStorage.loadProtectedSurfaces(from: defaults), choices)
                XCTAssertEqual(defaults.integer(forKey: "securitySurfacesMigratedVersion"), 2)
                XCTAssertFalse(defaults.bool(forKey: "securitySurfaceDefaultsNoticePending"))
            }
        }
    }

    func testFreshCredentialSetupLeavesAllProtectionChoicesOff() {
        withDefaults { defaults in
            XCTAssertTrue(SecurityProtectedSurfaceStorage.defaultSurfaces.isEmpty)
            for availability: SecurityAuthenticationAvailability in [.available, .unavailable, .available] {
                SecurityProtectedSurfaceStorage.reconcileAuthentication(availability, in: defaults)
                XCTAssertTrue(SecurityProtectedSurfaceStorage.loadProtectedSurfaces(from: defaults).isEmpty)
                XCTAssertEqual(defaults.integer(forKey: "securitySurfacesMigratedVersion"), 2)
                XCTAssertFalse(SecurityProtectedSurfaceStorage.hasPendingDefaultsNotice(in: defaults))
            }
        }
    }

    func testCompatibilityReaderDoesNotSeedChoices() {
        withDefaults { defaults in
            XCTAssertEqual(SecurityProtectedSurfaceStorage.loadProtectedSurfaces(from: defaults),
                           [])
            XCTAssertNil(defaults.object(forKey: "securitySurfacesMigratedVersion"))
            XCTAssertFalse(SecurityProtectedSurfaceStorage.hasPendingDefaultsNotice(in: defaults))
        }
    }

    func testConfirmedNoPasscodeStaysUngatedUntilFirstSetup() {
        withDefaults { defaults in
            SecurityProtectedSurfaceStorage.reconcileAuthentication(.absent, in: defaults)
            XCTAssertTrue(SecurityProtectedSurfaceStorage.loadProtectedSurfaces(from: defaults).isEmpty)
            SecurityProtectedSurfaceStorage.reconcileAuthentication(.available, in: defaults)
            XCTAssertEqual(SecurityProtectedSurfaceStorage.loadProtectedSurfaces(from: defaults),
                           [])
            XCTAssertFalse(SecurityProtectedSurfaceStorage.hasPendingDefaultsNotice(in: defaults))
        }
    }

    func testLegacyEmptyAndExistingGatesMigrateWithoutLosingChoices() {
        for legacy: [SecurityProtectedSurface] in [[], [.appUnlock, .activityViewing]] {
            withDefaults { defaults in
                defaults.set(legacy.map(\.rawValue), forKey: SecurityProtectedSurfaceStorage.defaultsKeyName)
                SecurityProtectedSurfaceStorage.reconcileAuthentication(.available, in: defaults)
                XCTAssertEqual(SecurityProtectedSurfaceStorage.loadProtectedSurfaces(from: defaults),
                               Set(legacy))
                XCTAssertFalse(SecurityProtectedSurfaceStorage.hasPendingDefaultsNotice(in: defaults))
            }
        }
    }

    func testInformedOptOutSurvivesRepeatedMigrationAndUnreadableCredential() {
        withDefaults { defaults in
            SecurityProtectedSurfaceStorage.reconcileAuthentication(.available, in: defaults)
            SecurityProtectedSurfaceStorage.saveProtectedSurfaces([], to: defaults)
            SecurityProtectedSurfaceStorage.acknowledgeDefaultsNotice(in: defaults)
            for availability: SecurityAuthenticationAvailability in [.available, .unavailable, .available] {
                SecurityProtectedSurfaceStorage.reconcileAuthentication(availability, in: defaults)
                XCTAssertTrue(SecurityProtectedSurfaceStorage.loadProtectedSurfaces(from: defaults).isEmpty)
                XCTAssertFalse(SecurityProtectedSurfaceStorage.hasPendingDefaultsNotice(in: defaults))
            }
        }
    }

    func testUnreadableCredentialPreservesChoicesWithoutRetiredNotice() {
        withDefaults { defaults in
            SecurityProtectedSurfaceStorage.reconcileAuthentication(.available, in: defaults)
            SecurityProtectedSurfaceStorage.saveProtectedSurfaces([.appUnlock, .filterEditing], to: defaults)
            SecurityProtectedSurfaceStorage.reconcileAuthentication(.unavailable, in: defaults)
            XCTAssertEqual(SecurityProtectedSurfaceStorage.loadProtectedSurfaces(from: defaults),
                           [.appUnlock, .filterEditing])
            XCTAssertFalse(SecurityProtectedSurfaceStorage.hasPendingDefaultsNotice(in: defaults))
        }
    }

    func testUnreadableLegacyCredentialDoesNotInventChoices() {
        withDefaults { defaults in
            SecurityProtectedSurfaceStorage.reconcileAuthentication(.unavailable, in: defaults)
            XCTAssertFalse(SecurityProtectedSurfaceStorage.isProtected(.protectionPause, defaults: defaults))
            XCTAssertFalse(SecurityProtectedSurfaceStorage.isProtected(.filterEditing, defaults: defaults))
            XCTAssertNil(defaults.object(forKey: "securitySurfacesMigratedVersion"))
            SecurityProtectedSurfaceStorage.reconcileAuthentication(.absent, in: defaults)
            XCTAssertFalse(SecurityProtectedSurfaceStorage.isProtected(.protectionPause, defaults: defaults))
        }
    }

    func testRetiredNoticeNeverReappearsAfterRemovalAndSetup() {
        withDefaults { defaults in
            SecurityProtectedSurfaceStorage.reconcileAuthentication(.available, in: defaults)
            SecurityProtectedSurfaceStorage.reconcileAuthentication(.available, in: defaults)
            XCTAssertFalse(SecurityProtectedSurfaceStorage.hasPendingDefaultsNotice(in: defaults))
            SecurityProtectedSurfaceStorage.acknowledgeDefaultsNotice(in: defaults)
            SecurityProtectedSurfaceStorage.reconcileAuthentication(.available, in: defaults)
            XCTAssertFalse(SecurityProtectedSurfaceStorage.hasPendingDefaultsNotice(in: defaults))
            SecurityProtectedSurfaceStorage.reconcileAuthentication(.absent, in: defaults)
            XCTAssertTrue(SecurityProtectedSurfaceStorage.loadProtectedSurfaces(from: defaults).isEmpty)
            SecurityProtectedSurfaceStorage.reconcileAuthentication(.available, in: defaults)
            XCTAssertFalse(SecurityProtectedSurfaceStorage.hasPendingDefaultsNotice(in: defaults))
        }
    }
}
