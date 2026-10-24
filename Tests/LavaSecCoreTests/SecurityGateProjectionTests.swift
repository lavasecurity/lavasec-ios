import XCTest
import LavaSecCore

final class SecurityGateProjectionTests: XCTestCase {
    private func withStore(_ body: (UserDefaults, URL) throws -> Void) throws {
        let name = "security-projection-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: dir)
        }
        try body(defaults, SecurityProtectedSurfaceStorage.projectionURL(containerURL: dir))
    }

    func testScopedGatesAndUnreadableCredentialsCannotOptIntoTheAppCover() throws {
        try withStore { defaults, url in
            XCTAssertTrue(SecurityProtectedSurfaceStorage.reconcileAuthentication(.available, in: defaults, projectionURL: url))
            for surface in SecurityProtectedSurface.allCases {
                XCTAssertTrue(SecurityProtectedSurfaceStorage.saveProtectedSurfaces([surface], to: defaults, projectionURL: url))
                for availability: SecurityAuthenticationAvailability in [.available, .unavailable, .available] {
                    XCTAssertTrue(SecurityProtectedSurfaceStorage.reconcileAuthentication(availability, in: defaults, projectionURL: url))
                    let selected = SecurityProtectedSurfaceStorage.appUnlockCoverChoice(projectionURL: url)
                    XCTAssertEqual(selected, surface == .appUnlock)
                    XCTAssertEqual(SecurityPrivacyPolicy.requiresBackgroundCover(appUnlockIsSelected: selected), surface == .appUnlock)
                    if availability == .unavailable {
                        XCTAssertEqual(SecurityProtectedSurfaceStorage.loadProtectedSurfaces(from: defaults, projectionURL: url),
                                       Set(SecurityProtectedSurface.allCases), "Access must still fail closed")
                    }
                }
            }
            XCTAssertTrue(SecurityProtectedSurfaceStorage.reconcileAuthentication(.absent, in: defaults, projectionURL: url))
            XCTAssertEqual(SecurityProtectedSurfaceStorage.appUnlockCoverChoice(projectionURL: url), false)
            try FileManager.default.removeItem(at: url)
            XCTAssertNil(SecurityProtectedSurfaceStorage.appUnlockCoverChoice(projectionURL: url))
        }
    }

    func testMalformedRepairPreservesTheSavedAppUnlockChoiceAcrossRefreshAndRelaunch() throws {
        for chosen in [false, true] {
            try withStore { defaults, url in
                XCTAssertTrue(SecurityProtectedSurfaceStorage.reconcileAuthentication(.available, in: defaults, projectionURL: url))
                let selected: Set<SecurityProtectedSurface> = chosen ? [.appUnlock, .appSettings] : [.appSettings]
                XCTAssertTrue(SecurityProtectedSurfaceStorage.saveProtectedSurfaces(selected, to: defaults, projectionURL: url))
                try Data("truncated".utf8).write(to: url)
                let conservative = Set(SecurityProtectedSurface.allCases)
                let repaired = chosen ? conservative : conservative.subtracting([.appUnlock])
                for availability: SecurityAuthenticationAvailability in [.available, .unavailable, .available] {
                    XCTAssertTrue(SecurityProtectedSurfaceStorage.reconcileAuthentication(availability, in: defaults, projectionURL: url))
                    // This reader has no controller cache, as on a fresh launch.
                    XCTAssertEqual(SecurityProtectedSurfaceStorage.appUnlockCoverChoice(projectionURL: url), chosen)
                    XCTAssertEqual(SecurityProtectedSurfaceStorage.loadProtectedSurfaces(from: defaults, projectionURL: url),
                                   availability == .unavailable ? conservative : repaired,
                                   "Unknown scoped gates stay closed; known OFF must not leave a synthetic global gate")
                }
                // Editing a different repaired gate cannot change Open Lava.
                XCTAssertTrue(SecurityProtectedSurfaceStorage.saveProtectedSurfaces(repaired.subtracting([.filterEditing]), to: defaults, projectionURL: url, appUnlockCoverChoice: chosen))
                XCTAssertEqual(SecurityProtectedSurfaceStorage.appUnlockCoverChoice(projectionURL: url), chosen)
            }
        }
    }

    func testRepairWithoutKnownConsentCannotManufactureAnExplicitOnChoice() throws {
        try withStore { defaults, url in
            try Data("truncated".utf8).write(to: url)
            for _ in 0..<3 {
                XCTAssertTrue(SecurityProtectedSurfaceStorage.reconcileAuthentication(.available, in: defaults, projectionURL: url))
                XCTAssertNil(SecurityProtectedSurfaceStorage.appUnlockCoverChoice(projectionURL: url))
                XCTAssertEqual(SecurityProtectedSurfaceStorage.loadProtectedSurfaces(from: defaults, projectionURL: url), Set(SecurityProtectedSurface.allCases))
            }
            XCTAssertTrue(SecurityProtectedSurfaceStorage.saveProtectedSurfaces(Set(SecurityProtectedSurface.allCases).subtracting([.filterEditing]), to: defaults, projectionURL: url, appUnlockCoverChoice: nil))
            XCTAssertNil(SecurityProtectedSurfaceStorage.appUnlockCoverChoice(projectionURL: url))
            XCTAssertTrue(SecurityProtectedSurfaceStorage.saveProtectedSurfaces([], to: defaults, projectionURL: url))
            XCTAssertEqual(SecurityProtectedSurfaceStorage.appUnlockCoverChoice(projectionURL: url), false)
        }
    }

    func testLegacyOffChoiceSurvivesRepairBeforeTheFirstClassifiedLaunch() throws {
        try withStore { defaults, url in
            SecurityProtectedSurfaceStorage.saveProtectedSurfaces([.appSettings], to: defaults)
            try Data("truncated".utf8).write(to: url)
            XCTAssertTrue(SecurityProtectedSurfaceStorage.reconcileAuthentication(.available, in: defaults, projectionURL: url))
            XCTAssertEqual(SecurityProtectedSurfaceStorage.appUnlockCoverChoice(projectionURL: url), false)
            XCTAssertFalse(SecurityProtectedSurfaceStorage.loadProtectedSurfaces(from: defaults, projectionURL: url).contains(.appUnlock),
                           "Known OFF must leave normal app entry usable without a global unlock prompt")
            XCTAssertTrue(SecurityProtectedSurfaceStorage.isProtected(.activityViewing, defaults: defaults, projectionURL: url))
        }
    }

    func testLegacyRepairedProjectionCannotPublishAnExplicitAppCoverChoice() throws {
        try withStore { defaults, url in
            let gates = Set(SecurityProtectedSurface.allCases)
            let record: [String: Any] = [
                "version": 1, "availability": "available", "surfaces": gates.map(\.rawValue),
                "migrated": true, "noticePending": false, "optInMigration": 2
            ]
            try JSONSerialization.data(withJSONObject: record).write(to: url)
            defaults.set(gates.map(\.rawValue), forKey: SecurityProtectedSurfaceStorage.defaultsKeyName)
            XCTAssertNil(SecurityProtectedSurfaceStorage.appUnlockCoverChoice(projectionURL: url, defaults: defaults))
            for availability: SecurityAuthenticationAvailability in [.available, .unavailable, .available] {
                XCTAssertTrue(SecurityProtectedSurfaceStorage.reconcileAuthentication(availability, in: defaults, projectionURL: url))
                XCTAssertNil(SecurityProtectedSurfaceStorage.appUnlockCoverChoice(projectionURL: url, defaults: defaults))
                XCTAssertNil(defaults.object(forKey: "securityAppUnlockCoverChoice"))
                XCTAssertEqual(SecurityProtectedSurfaceStorage.loadProtectedSurfaces(from: defaults, projectionURL: url), gates)
            }
            XCTAssertTrue(SecurityProtectedSurfaceStorage.saveProtectedSurfaces(gates.subtracting([.filterEditing]), to: defaults,
                projectionURL: url, appUnlockCoverChoice: nil))
            XCTAssertNil(SecurityProtectedSurfaceStorage.appUnlockCoverChoice(projectionURL: url, defaults: defaults))
        }
    }

    func testLegacyAppUnlockGateNeedsIndependentConsentBeforeItCanBecomeExplicitOn() throws {
        for choice: Bool? in [nil, false, true] {
            try withStore { defaults, url in
                // An older app can also edit a repaired record's unrelated gate;
                // even a subset containing appUnlock is not proof of cover consent.
                let record: [String: Any] = [
                    "version": 1, "availability": "available", "surfaces": ["appUnlock", "activityViewing"],
                    "migrated": true, "noticePending": false, "optInMigration": 2
                ]
                try JSONSerialization.data(withJSONObject: record).write(to: url)
                if let choice { defaults.set(choice, forKey: "securityAppUnlockCoverChoice") }
                XCTAssertEqual(SecurityProtectedSurfaceStorage.appUnlockCoverChoice(projectionURL: url, defaults: defaults), choice)
                XCTAssertTrue(SecurityProtectedSurfaceStorage.reconcileAuthentication(.available, in: defaults, projectionURL: url))
                XCTAssertEqual(SecurityProtectedSurfaceStorage.appUnlockCoverChoice(projectionURL: url), choice)
                XCTAssertEqual(SecurityProtectedSurfaceStorage.loadProtectedSurfaces(from: defaults, projectionURL: url),
                               choice == false ? [.activityViewing] : [.appUnlock, .activityViewing])
            }
        }
    }

    func testKnownOffRecordCannotStrandAppEntryBehindASyntheticUnlockGate() throws {
        try withStore { defaults, url in
            let scoped = Set(SecurityProtectedSurface.allCases).subtracting([.appUnlock])
            let record: [String: Any] = [
                "version": 1, "availability": "available", "surfaces": SecurityProtectedSurface.allCases.map(\.rawValue),
                "migrated": true, "noticePending": false, "optInMigration": 2, "coverConsent": "off"
            ]
            let data = try JSONSerialization.data(withJSONObject: record)
            try data.write(to: url)
            XCTAssertEqual(SecurityProtectedSurfaceStorage.appUnlockCoverChoice(projectionURL: url), false)
            XCTAssertFalse(SecurityProtectedSurfaceStorage.isProtected(.appUnlock, defaults: defaults, projectionURL: url))
            XCTAssertEqual(SecurityProtectedSurfaceStorage.loadProtectedSurfaces(from: defaults, projectionURL: url), scoped)
            XCTAssertEqual(try Data(contentsOf: url), data, "A reader must not repair or rewrite the record")
            XCTAssertTrue(SecurityProtectedSurfaceStorage.reconcileAuthentication(.available, in: defaults, projectionURL: url))
            XCTAssertEqual(SecurityProtectedSurfaceStorage.loadProtectedSurfaces(from: defaults), scoped,
                           "The writer must retire the contradictory gate in both persisted representations")
            for gate in scoped {
                XCTAssertTrue(SecurityProtectedSurfaceStorage.isProtected(gate, defaults: defaults, projectionURL: url))
            }
        }
    }

    func testCredentialPreparationClosesPreviouslyAbsentGatesBeforeTheWrite() throws {
        try withStore { defaults, url in
            SecurityProtectedSurfaceStorage.reconcileAuthentication(.absent, in: defaults)
            XCTAssertTrue(SecurityProtectedSurfaceStorage.reconcileAuthentication(.absent, in: defaults, projectionURL: url))
            XCTAssertTrue(SecurityProtectedSurfaceStorage.loadProtectedSurfaces(from: defaults, projectionURL: url).isEmpty)
            XCTAssertTrue(SecurityProtectedSurfaceStorage.prepareCredentialChange(in: defaults, projectionURL: url))
            XCTAssertEqual(SecurityProtectedSurfaceStorage.loadProtectedSurfaces(from: defaults, projectionURL: url),
                           Set(SecurityProtectedSurface.allCases))
            XCTAssertEqual(defaults.string(forKey: "securityAuthenticationAvailability"), "unavailable",
                           "A reader must not depend on the old defaults cache being updated")
            XCTAssertTrue(SecurityProtectedSurfaceStorage.reconcileAuthentication(.available, in: defaults, projectionURL: url))
            XCTAssertFalse(SecurityProtectedSurfaceStorage.hasPendingDefaultsNotice(in: defaults, projectionURL: url))
        }
    }

    func testUnavailableCredentialAfterFailedCreationKeepsGatesUntilConfirmedAbsence() throws {
        try withStore { defaults, url in
            XCTAssertTrue(SecurityProtectedSurfaceStorage.reconcileAuthentication(.absent, in: defaults, projectionURL: url))
            XCTAssertTrue(SecurityProtectedSurfaceStorage.prepareCredentialChange(in: defaults, projectionURL: url))
            XCTAssertTrue(SecurityProtectedSurfaceStorage.reconcileAuthentication(.unavailable, in: defaults, projectionURL: url))
            XCTAssertTrue(SecurityProtectedSurfaceStorage.isProtected(.filterEditing, defaults: defaults, projectionURL: url))
            XCTAssertFalse(SecurityProtectedSurfaceStorage.hasPendingDefaultsNotice(in: defaults, projectionURL: url))
            XCTAssertTrue(SecurityProtectedSurfaceStorage.reconcileAuthentication(.absent, in: defaults, projectionURL: url))
            XCTAssertTrue(SecurityProtectedSurfaceStorage.loadProtectedSurfaces(from: defaults, projectionURL: url).isEmpty)
        }
    }

    func testPublicationFailureRefusesCredentialPreparation() throws {
        try withStore { defaults, url in
            XCTAssertFalse(SecurityProtectedSurfaceStorage.prepareCredentialChange(in: defaults, projectionURL: nil))
            let unreachable = url.appendingPathComponent("missing-parent/gates.json")
            XCTAssertFalse(SecurityProtectedSurfaceStorage.prepareCredentialChange(in: defaults, projectionURL: unreachable))
            XCTAssertTrue(SecurityProtectedSurfaceStorage.isProtected(.protectionPause, defaults: defaults, projectionURL: unreachable))
        }
    }

    func testInformedOptOutAndNoticeAcknowledgementSurviveStaleDefaultsAndCredentialChanges() throws {
        try withStore { defaults, url in
            XCTAssertTrue(SecurityProtectedSurfaceStorage.reconcileAuthentication(.available, in: defaults, projectionURL: url))
            XCTAssertTrue(SecurityProtectedSurfaceStorage.saveProtectedSurfaces([.appUnlock], to: defaults, projectionURL: url))
            XCTAssertTrue(SecurityProtectedSurfaceStorage.acknowledgeDefaultsNotice(in: defaults, projectionURL: url))
            SecurityProtectedSurfaceStorage.reconcileAuthentication(.absent, in: defaults)
            XCTAssertTrue(SecurityProtectedSurfaceStorage.prepareCredentialChange(in: defaults, projectionURL: url))
            for availability: SecurityAuthenticationAvailability in [.unavailable, .available, .available] {
                XCTAssertTrue(SecurityProtectedSurfaceStorage.reconcileAuthentication(availability, in: defaults, projectionURL: url))
                XCTAssertEqual(SecurityProtectedSurfaceStorage.loadProtectedSurfaces(from: defaults, projectionURL: url), availability == .unavailable ? Set(SecurityProtectedSurface.allCases) : [.appUnlock])
                XCTAssertFalse(SecurityProtectedSurfaceStorage.hasPendingDefaultsNotice(in: defaults, projectionURL: url))
            }
        }
    }

    func testLegacyExplicitChoicesSurvivePendingNoticeAndRepeatedReconciliation() throws {
        let selections: [Set<SecurityProtectedSurface>] = [
            [], [.protectionPause], [.filterEditing], [.protectionPause, .filterEditing],
            Set(SecurityProtectedSurface.allCases)
        ]
        for choices in selections {
            try withStore { defaults, url in
                var legacyRecord: [String: Any] = [
                    "version": 1, "availability": "available",
                    "surfaces": ["protectionPause", "filterEditing"],
                    "migrated": true, "noticePending": true
                ]
                // Match the old explicit-save projection writer at app main 7bdc0ecc:
                // replace surfaces, mark migrated, leave noticePending unchanged.
                legacyRecord["surfaces"] = choices.map(\.rawValue).sorted()
                legacyRecord["migrated"] = true
                try JSONSerialization.data(withJSONObject: legacyRecord).write(to: url)

                for protectedDataIsAvailable in [false, true] {
                    XCTAssertTrue(SecurityProtectedSurfaceStorage.reconcileAuthentication(.unavailable, in: defaults,
                        projectionURL: url, protectedDataIsAvailable: protectedDataIsAvailable))
                    XCTAssertEqual(SecurityProtectedSurfaceStorage.loadProtectedSurfaces(from: defaults, projectionURL: url),
                                   Set(SecurityProtectedSurface.allCases))
                    let record = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
                    XCTAssertEqual(Set(try XCTUnwrap(record["surfaces"] as? [String])), Set(choices.map(\.rawValue)))
                    XCTAssertNil(record["optInMigration"])
                    XCTAssertEqual(record["noticePending"] as? Bool, true)
                }

                for availability: SecurityAuthenticationAvailability in [.available, .unavailable, .available] {
                    XCTAssertTrue(SecurityProtectedSurfaceStorage.reconcileAuthentication(availability, in: defaults,
                        projectionURL: url))
                    XCTAssertEqual(SecurityProtectedSurfaceStorage.loadProtectedSurfaces(from: defaults, projectionURL: url),
                                   availability == .unavailable ? Set(SecurityProtectedSurface.allCases) : choices)
                    let record = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
                    XCTAssertEqual(Set(try XCTUnwrap(record["surfaces"] as? [String])), Set(choices.map(\.rawValue)))
                    XCTAssertEqual(record["version"] as? Int, 1)
                    XCTAssertEqual(record["optInMigration"] as? Int, 2)
                    XCTAssertEqual(record["noticePending"] as? Bool, false)
                    XCTAssertEqual(SecurityProtectedSurfaceStorage.loadProtectedSurfaces(from: defaults), choices)
                }
            }
        }
    }

    func testFreshCredentialSetupLeavesAllProtectionChoicesOff() throws {
        try withStore { defaults, url in
            for availability: SecurityAuthenticationAvailability in [.available, .unavailable, .available] {
                XCTAssertTrue(SecurityProtectedSurfaceStorage.reconcileAuthentication(availability, in: defaults,
                    projectionURL: url))
                XCTAssertEqual(SecurityProtectedSurfaceStorage.loadProtectedSurfaces(from: defaults, projectionURL: url),
                               availability == .unavailable ? Set(SecurityProtectedSurface.allCases) : [])
                XCTAssertTrue(SecurityProtectedSurfaceStorage.loadProtectedSurfaces(from: defaults).isEmpty)
                XCTAssertFalse(SecurityProtectedSurfaceStorage.hasPendingDefaultsNotice(in: defaults, projectionURL: url))
            }
        }
    }

    func testMissingLegacyProvenancePreservesAmbiguousChoices() throws {
        try withStore { defaults, url in
            try Data(#"{"version":1,"availability":"available","surfaces":["protectionPause","filterEditing"],"migrated":false,"noticePending":true}"#.utf8).write(to: url)
            XCTAssertTrue(SecurityProtectedSurfaceStorage.reconcileAuthentication(.available, in: defaults, projectionURL: url))
            XCTAssertEqual(SecurityProtectedSurfaceStorage.loadProtectedSurfaces(from: defaults, projectionURL: url), [.protectionPause, .filterEditing])
        }
    }

    func testAcknowledgedLegacyChoicesRemainProtected() throws {
        try withStore { defaults, url in
            let choices: Set<SecurityProtectedSurface> = [.protectionPause, .filterEditing, .appUnlock]
            try Data(#"{"version":1,"availability":"available","surfaces":["protectionPause","filterEditing","appUnlock"],"migrated":true,"noticePending":false}"#.utf8).write(to: url)
            for availability: SecurityAuthenticationAvailability in [.available, .unavailable, .available] {
                XCTAssertTrue(SecurityProtectedSurfaceStorage.reconcileAuthentication(availability, in: defaults, projectionURL: url))
                XCTAssertEqual(SecurityProtectedSurfaceStorage.loadProtectedSurfaces(from: defaults, projectionURL: url),
                               availability == .unavailable ? Set(SecurityProtectedSurface.allCases) : choices)
                XCTAssertEqual(SecurityProtectedSurfaceStorage.loadProtectedSurfaces(from: defaults), choices)
                XCTAssertFalse(SecurityProtectedSurfaceStorage.hasPendingDefaultsNotice(in: defaults, projectionURL: url))
            }
        }
    }

    func testMissingCorruptOversizedAndUnknownVersionRecordsFailClosedWithoutRepairByReaders() throws {
        try withStore { defaults, url in
            SecurityProtectedSurfaceStorage.reconcileAuthentication(.absent, in: defaults)
            XCTAssertTrue(SecurityProtectedSurfaceStorage.isProtected(.filterEditing, defaults: defaults, projectionURL: url))
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
            for data in [Data("bad".utf8), Data(repeating: 32, count: 4097),
                         Data(#"{"version":2,"availability":"absent","surfaces":[],"migrated":false,"noticePending":false}"#.utf8)] {
                try data.write(to: url)
                XCTAssertEqual(SecurityProtectedSurfaceStorage.loadProtectedSurfaces(from: defaults, projectionURL: url),
                               Set(SecurityProtectedSurface.allCases))
                XCTAssertFalse(SecurityProtectedSurfaceStorage.prepareCredentialChange(in: defaults, projectionURL: url))
                XCTAssertEqual(try Data(contentsOf: url), data)
            }
        }
    }

    func testForegroundReconciliationRepairsMalformedRecordsConservatively() throws {
        try withStore { defaults, url in
            for availability: SecurityAuthenticationAvailability in [.available, .unavailable] {
                try Data(#"{"version":1,"availability":"available""#.utf8).write(to: url)
                XCTAssertTrue(SecurityProtectedSurfaceStorage.reconcileAuthentication(availability, in: defaults, projectionURL: url))
                XCTAssertEqual(SecurityProtectedSurfaceStorage.loadProtectedSurfaces(from: defaults, projectionURL: url),
                               Set(SecurityProtectedSurface.allCases))
                XCTAssertFalse(SecurityProtectedSurfaceStorage.hasPendingDefaultsNotice(in: defaults, projectionURL: url))
            }
        }
    }

    func testPrewarmDefersLegacyMigrationUntilProtectedDataAndCredentialReadAreAvailable() throws {
        try withStore { defaults, url in
            let choices: Set<SecurityProtectedSurface> = [.protectionPause, .filterEditing, .appUnlock]
            defaults.set(choices.map(\.rawValue), forKey: SecurityProtectedSurfaceStorage.defaultsKeyName)
            defaults.set(1, forKey: "securitySurfacesMigratedVersion")
            defaults.set(true, forKey: "securitySurfaceDefaultsNoticePending")
            for (availability, readable) in [(SecurityAuthenticationAvailability.unavailable, true), (.available, false), (.absent, false)] {
                XCTAssertFalse(SecurityProtectedSurfaceStorage.reconcileAuthentication(availability, in: defaults,
                    projectionURL: url, protectedDataIsAvailable: readable))
                XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
                XCTAssertEqual(SecurityProtectedSurfaceStorage.loadProtectedSurfaces(from: defaults), choices)
                XCTAssertEqual(defaults.integer(forKey: "securitySurfacesMigratedVersion"), 1)
                XCTAssertTrue(defaults.bool(forKey: "securitySurfaceDefaultsNoticePending"))
                XCTAssertEqual(SecurityProtectedSurfaceStorage.loadProtectedSurfaces(from: defaults, projectionURL: url),
                               Set(SecurityProtectedSurface.allCases))
            }
            XCTAssertFalse(SecurityProtectedSurfaceStorage.prepareCredentialChange(in: defaults, projectionURL: url))
            XCTAssertTrue(SecurityProtectedSurfaceStorage.reconcileAuthentication(.available, in: defaults,
                projectionURL: url, protectedDataIsAvailable: true))
            XCTAssertEqual(SecurityProtectedSurfaceStorage.loadProtectedSurfaces(from: defaults, projectionURL: url), choices)
            XCTAssertFalse(SecurityProtectedSurfaceStorage.hasPendingDefaultsNotice(in: defaults, projectionURL: url))
        }
    }

    func testConfirmedCredentialAbsenceRecoversMalformedProjectionWithoutLeavingGates() throws {
        try withStore { defaults, url in
            try Data("truncated".utf8).write(to: url)
            XCTAssertTrue(SecurityProtectedSurfaceStorage.reconcileAuthentication(.absent, in: defaults, projectionURL: url))
            XCTAssertTrue(SecurityProtectedSurfaceStorage.loadProtectedSurfaces(from: defaults, projectionURL: url).isEmpty)
            XCTAssertFalse(SecurityProtectedSurfaceStorage.hasPendingDefaultsNotice(in: defaults, projectionURL: url))
        }
    }

    func testForegroundReconciliationPreservesUnsupportedVersionsEvenWithUnknownFields() throws {
        try withStore { defaults, url in
            let data = Data(#"{"version":2,"availability":{"new":"format"}}"#.utf8)
            try data.write(to: url)
            XCTAssertFalse(SecurityProtectedSurfaceStorage.reconcileAuthentication(.available, in: defaults, projectionURL: url))
            XCTAssertEqual(try Data(contentsOf: url), data)
        }
    }

    func testLegacyChoicePersistsButSetupAfterRemovalDoesNotSeed() throws {
        try withStore { defaults, url in
            SecurityProtectedSurfaceStorage.saveProtectedSurfaces([.activityViewing], to: defaults)
            XCTAssertTrue(SecurityProtectedSurfaceStorage.reconcileAuthentication(.available, in: defaults, projectionURL: url))
            XCTAssertEqual(SecurityProtectedSurfaceStorage.loadProtectedSurfaces(from: defaults, projectionURL: url), [.activityViewing])
            XCTAssertFalse(SecurityProtectedSurfaceStorage.hasPendingDefaultsNotice(in: defaults, projectionURL: url))
            XCTAssertTrue(SecurityProtectedSurfaceStorage.reconcileAuthentication(.absent, in: defaults, projectionURL: url))
            XCTAssertTrue(SecurityProtectedSurfaceStorage.prepareCredentialChange(in: defaults, projectionURL: url))
            XCTAssertEqual(SecurityProtectedSurfaceStorage.loadProtectedSurfaces(from: defaults, projectionURL: url),
                           Set(SecurityProtectedSurface.allCases))
        }
    }
}
