import CoreGraphics
import ImageIO
import XCTest

final class LavaLiveActivitySourceTests: XCTestCase {
    func testAppIconMascotFaceUsesLargerReadableGeometry() throws {
        let iconURL = packageRootURL
            .appendingPathComponent("LavaSecApp/AppIcon.icon/Assets/Front.png")
        let metrics = try appIconFaceMetrics(at: iconURL)

        XCTAssertEqual(metrics.imageWidth, 1024)
        XCTAssertEqual(metrics.imageHeight, 1024)
        XCTAssertGreaterThanOrEqual(metrics.faceBounds.width, 500)
        XCTAssertGreaterThanOrEqual(metrics.faceBounds.height, 220)
    }

    func testLavaGuardLooksDeclareAlternateAppIcons() throws {
        let attributes = try readSource(.lavaActivityAttributes)
        // The look → app-icon sync (and the personalizer seam) lives on
        // CustomizationController since the Phase D5 customization peel.
        let customizationController = try readSource(.customizationController)
        let project = try readSource(.xcodeProject)
        let iconNames = [
            "AppIconFireOpal",
            "AppIconAmethyst",
            "AppIconObsidian",
            "AppIconCherryQuartz",
            "AppIconEmerald",
            "AppIconKiwiCreme",
            "AppIconAquamarine"
        ]

        XCTAssertTrue(attributes.contains("var alternateAppIconName: String?"))
        XCTAssertTrue(attributes.contains("iOS owns Dark/Tinted rendering from the user's Home Screen icon appearance."))
        XCTAssertTrue(attributes.contains("case .original:\n            nil"))
        XCTAssertTrue(attributes.contains("case .fireOpal:\n            \"AppIconFireOpal\""))
        XCTAssertTrue(attributes.contains("case .purpleObsidian:\n            \"AppIconAmethyst\""))
        XCTAssertTrue(attributes.contains("case .obsidian:\n            \"AppIconObsidian\""))
        XCTAssertTrue(attributes.contains("case .cherryQuartz:\n            \"AppIconCherryQuartz\""))
        XCTAssertTrue(attributes.contains("case .emerald:\n            \"AppIconEmerald\""))
        XCTAssertTrue(attributes.contains("case .kiwiCreme:\n            \"AppIconKiwiCreme\""))
        XCTAssertTrue(attributes.contains("case .aquamarine:\n            \"AppIconAquamarine\""))

        XCTAssertTrue(customizationController.contains("private func syncAppIcon(to look: GuardianShieldStyle)"))
        XCTAssertTrue(customizationController.contains("iconPersonalizer.supportsAppIconPersonalization"))
        XCTAssertTrue(customizationController.contains("iconPersonalizer.currentAppIconName"))
        XCTAssertTrue(customizationController.contains("let targetIconName = updatesAppIconWithLavaGuard ? look.alternateAppIconName : nil"))
        XCTAssertTrue(customizationController.contains("iconPersonalizer.setAppIcon(targetIconName)"))
        XCTAssertTrue(customizationController.contains("syncAppIcon(to: look)"))
        // The keep-open picker can queue several Guard selections; icon changes serialize behind the
        // previous one (setAlternateIconName is async + not cancellation-aware) so they apply in
        // order and the last pick wins, instead of racing to a mismatched launcher icon (Codex P2 on #402).
        XCTAssertTrue(customizationController.contains("private var iconSyncTask: Task<Void, Never>?"))
        // Serialization ORDER, not just presence: capture the OLD task BEFORE assigning the new one, and
        // await that captured OLD handle inside the new task — so each icon sync waits for its
        // predecessor (submission order wins). A regression that captured the NEW task (after the
        // assignment) into `previousSync` would still contain all three strings yet self-await and
        // serialize nothing, so pin the relative positions (OCR review on lavasec-ios#69).
        let capturePreviousIndex = try XCTUnwrap(customizationController.range(of: "let previousSync = iconSyncTask")?.lowerBound)
        let assignNewIndex = try XCTUnwrap(customizationController.range(of: "iconSyncTask = Task {")?.lowerBound)
        let awaitPreviousIndex = try XCTUnwrap(customizationController.range(of: "_ = await previousSync?.value")?.lowerBound)
        XCTAssertLessThan(capturePreviousIndex, assignNewIndex)
        XCTAssertLessThan(assignNewIndex, awaitPreviousIndex)

        let alternateIconSetting = "ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES = \"\(iconNames.joined(separator: " "))\";"
        XCTAssertEqual(project.components(separatedBy: alternateIconSetting).count - 1, 3)
        XCTAssertTrue(project.contains("folder.iconcomposer.icon"))

        let appURL = packageRootURL.appendingPathComponent("LavaSecApp")
        for iconName in iconNames {
            let iconPackageURL = appURL.appendingPathComponent("\(iconName).icon")
            let iconJSONURL = iconPackageURL.appendingPathComponent("icon.json")
            guard FileManager.default.fileExists(atPath: iconJSONURL.path) else {
                XCTFail("\(iconName) must have Icon Composer metadata")
                continue
            }

            let iconJSON = try String(contentsOf: iconJSONURL, encoding: .utf8)
            XCTAssertTrue(iconJSON.contains("\"supported-platforms\""))
            XCTAssertTrue(iconJSON.contains("\"fill-specializations\""))
            XCTAssertTrue(iconJSON.contains("\"appearance\" : \"dark\""))
            XCTAssertTrue(iconJSON.contains("\"translucency\""))
            if iconName == "AppIconKiwiCreme" {
                XCTAssertTrue(iconJSON.contains("display-p3:0.91000,0.84000,0.72000,1.00000"))
            }

            let frontLayerURL = iconPackageURL.appendingPathComponent("Assets/Front.png")
            guard FileManager.default.fileExists(atPath: frontLayerURL.path) else {
                XCTFail("\(iconName) must include a transparent front layer")
                continue
            }
            let metrics = try appIconFaceMetrics(at: frontLayerURL)
            XCTAssertEqual(metrics.imageWidth, 1024)
            XCTAssertEqual(metrics.imageHeight, 1024)
            XCTAssertGreaterThanOrEqual(metrics.faceBounds.width, 500)
            XCTAssertGreaterThanOrEqual(metrics.faceBounds.height, 220)
        }
    }

    func testAlternateAppIconsUseSystemRenderableSeedArtwork() throws {
        let iconNames = [
            "AppIcon",
            "AppIconFireOpal",
            "AppIconAmethyst",
            "AppIconObsidian",
            "AppIconCherryQuartz",
            "AppIconEmerald",
            "AppIconKiwiCreme",
            "AppIconAquamarine"
        ]
        let appURL = packageRootURL.appendingPathComponent("LavaSecApp")

        for iconName in iconNames {
            let frontLayerURL = appURL
                .appendingPathComponent("\(iconName).icon")
                .appendingPathComponent("Assets/Front.png")
            let metrics = try appIconLayerAlphaMetrics(at: frontLayerURL)

            XCTAssertGreaterThan(
                metrics.transparentPixelRatio,
                0.75,
                "\(iconName) should leave most pixels transparent so iOS can render Dark/Tinted icon appearances"
            )
            XCTAssertGreaterThan(
                metrics.opaquePixelRatio,
                0.01,
                "\(iconName) should still include visible mascot face artwork"
            )
        }
    }

    func testCustomizationSettingsRouteAppearsInRNYourLava() throws {
        let settings = try readSource(.settingsView)
        let routeBlock = try sourceBlock(
            in: settings,
            startingAt: "enum SettingsRoute: Hashable",
            endingBefore: "struct NativeDNSSettingsDestinationView: View"
        )
        let rootBlock = try sourceBlock(
            in: readSource(.reactNativeSettingsScreens),
            startingAt: "<SettingsGroup title=\"Your Lava\">",
            endingBefore: "</SettingsGroup>"
        )

        XCTAssertTrue(routeBlock.contains("case customization"))
        XCTAssertTrue(routeBlock.contains("case .customization:"))
        XCTAssertTrue(routeBlock.contains("return .requires(.appSettings)"))
        XCTAssertTrue(rootBlock.contains("icon=\"slider.horizontal.3\" title=\"Customization\""))
        XCTAssertTrue(rootBlock.contains("nav.navigate('Customization')"))
    }

    func testLiveActivitiesToggleIsGatedToSupportedDeviceClasses() throws {
        let appViewModel = try readAppViewModelSource()
        // The toggle/load clamp lives on CustomizationController (Phase D5 peel); the
        // device-class gate itself stays a hub read (it owns the presenter), and the
        // controller reaches it through the bridge.
        let customizationController = try readSource(.customizationController)
        let controller = try readSource(.lavaLiveActivityController)

        XCTAssertTrue(controller.contains("import UIKit"))
        XCTAssertTrue(controller.contains("var canOfferLiveActivities: Bool"))
        XCTAssertTrue(controller.contains("static func canOfferLiveActivities(for userInterfaceIdiom: UIUserInterfaceIdiom) -> Bool"))
        XCTAssertTrue(controller.contains("case .phone, .pad:"))
        XCTAssertTrue(controller.contains("guard canOfferLiveActivities,"))

        XCTAssertTrue(appViewModel.contains("var canOfferLiveActivities: Bool"))
        XCTAssertTrue(appViewModel.contains("liveActivityController.canOfferLiveActivities"))
        // Every controller-side read of the gate delegates to the hub's one witness.
        XCTAssertTrue(customizationController.contains("hub.canOfferLiveActivities"))
        XCTAssertTrue(customizationController.contains("guard canOfferLiveActivities else"))
        XCTAssertTrue(customizationController.contains("let canEnableLiveActivities = canOfferLiveActivities && isEnabled"))
        XCTAssertTrue(customizationController.contains("usesLiveActivities = canOfferLiveActivities && persistedUsesLiveActivities"))

        XCTAssertTrue((try readSource(.reactNativeAppBridge)).contains("c.canOfferLiveActivities"))
    }

    func testAppearanceAndLiveActivityPreferencesPersistInAppGroupDefaults() throws {
        // The preference cluster (models, @Published, keys, setters, load) lives on
        // CustomizationController since the Phase D5 peel; the hub keeps only the
        // LavaGuard PROGRESS value + key (the accrual engine writes them).
        let appViewModel = try readAppViewModelSource()
        let customizationController = try readSource(.customizationController)
        let appGroup = try readSource(.appGroup)
        let rootView = try readSource(.rootView)
        let persistLookBlock = try sourceBlock(
            in: customizationController,
            startingAt: "private func persistLavaGuardLook(_ look: GuardianShieldStyle)",
            endingBefore: "private func syncAppIcon(to look: GuardianShieldStyle)"
        )

        XCTAssertTrue(customizationController.contains("enum LavaAppearancePreference: String, CaseIterable, Identifiable"))
        XCTAssertTrue(customizationController.contains("case light"))
        XCTAssertTrue(customizationController.contains("case dark"))
        XCTAssertTrue(customizationController.contains("case system"))
        XCTAssertTrue(customizationController.contains("@Published private(set) var appearancePreference: LavaAppearancePreference = .system"))
        XCTAssertTrue(customizationController.contains("@Published private(set) var usesLiveActivities = false"))
        XCTAssertTrue(customizationController.contains("@Published private(set) var usesLavaHaptics = true"))
        XCTAssertTrue(customizationController.contains("private let appearancePreferences: AppearancePreferencesService"))
        XCTAssertTrue(customizationController.contains("private let usesLiveActivitiesDefaultsKeyName = \"lavasec.customization.liveActivities\""))
        XCTAssertTrue(customizationController.contains("private let usesLavaHapticsDefaultsKey = ProtectionHapticFeedback.preferenceDefaultsKeyName"))
        XCTAssertTrue(customizationController.contains("func setUsesLavaHaptics(_ isEnabled: Bool)"))
        XCTAssertTrue(customizationController.contains("defaults.set(isEnabled, forKey: usesLavaHapticsDefaultsKey)"))
        XCTAssertTrue(customizationController.contains("usesLavaHaptics = defaults.object(forKey: usesLavaHapticsDefaultsKey) as? Bool ?? true"))
        XCTAssertTrue(customizationController.contains("@Published private(set) var lavaGuardLook: GuardianShieldStyle = .original"))
        XCTAssertTrue(appViewModel.contains("@Published var lavaGuardProgress = LavaGuardProgress()"))
        XCTAssertTrue(customizationController.contains("@Published private(set) var updatesAppIconWithLavaGuard = true"))
        XCTAssertTrue(appGroup.contains("customizationLavaGuardLookDefaultsKeyName = \"lavasec.customization.lavaGuardLook\""))
        XCTAssertTrue(customizationController.contains("private let lavaGuardLookDefaultsKey = LavaSecAppGroup.customizationLavaGuardLookDefaultsKeyName"))
        XCTAssertTrue(customizationController.contains("private let updatesAppIconWithLavaGuardDefaultsKeyName = \"lavasec.customization.updatesAppIconWithLavaGuard\""))
        XCTAssertTrue(appViewModel.contains("let lavaGuardProgressDefaultsKeyName = \"lavasec.customization.lavaGuardProgress\""))
        XCTAssertTrue(customizationController.contains("appearancePreferences.setPreference(preference.nativePreference)"))
        XCTAssertTrue(customizationController.contains("private func persistLavaGuardLook(_ look: GuardianShieldStyle)"))
        XCTAssertTrue(persistLookBlock.contains("defaults.set(look.rawValue, forKey: lavaGuardLookDefaultsKey)"))
        XCTAssertTrue(persistLookBlock.contains("appGroupDefaults.set(look.rawValue, forKey: lavaGuardLookDefaultsKey)"))
        XCTAssertFalse(persistLookBlock.contains("appGroupDefaults.synchronize()"))
        XCTAssertTrue(customizationController.contains("persistLavaGuardLook(look)"))
        XCTAssertTrue(customizationController.contains("func setLavaGuardLook(_ look: GuardianShieldStyle)"))
        XCTAssertTrue(customizationController.contains("guard isLavaGuardLookSelectable(look) else"))
        XCTAssertTrue(customizationController.contains("func lavaGuardAvailability(for look: GuardianShieldStyle) -> LavaGuardAvailability"))
        XCTAssertTrue(customizationController.contains("LavaGuardAvailabilityPolicy.isAvailable("))
        XCTAssertTrue(customizationController.contains("let showsProgressDetail = look.lavaGuardID == nextLavaGuardProgressDetailGuardID"))
        XCTAssertTrue(customizationController.contains("private var nextLavaGuardProgressDetailGuardID: String?"))
        XCTAssertTrue(customizationController.contains("for goal in LavaGuardProgressPolicy.unlockGoals"))
        XCTAssertTrue(customizationController.contains("func setUpdatesAppIconWithLavaGuard(_ isEnabled: Bool)"))
        XCTAssertTrue(customizationController.contains("defaults.set(isEnabled, forKey: updatesAppIconWithLavaGuardDefaultsKeyName)"))
        XCTAssertTrue(customizationController.contains("syncAppIcon(to: lavaGuardLook)"))
        XCTAssertTrue(appViewModel.contains("reconcileLiveActivity()"))
        XCTAssertTrue(customizationController.contains("hub.reconcileLiveActivity()"))
        XCTAssertTrue(customizationController.contains("defaults.set(canEnableLiveActivities, forKey: usesLiveActivitiesDefaultsKeyName)"))
        XCTAssertTrue(customizationController.contains("var preferredColorScheme: ColorScheme?"))
        XCTAssertTrue(rootView.contains(".preferredColorScheme(customization.preferredColorScheme)"))
    }

    func testMascotShieldStyleAddsNamedLooksWithoutDuplicatingEmotions() throws {
        let sharedMascot = try readSource(.softShieldGuardian)
        let attributes = try readSource(.lavaActivityAttributes)
        let rootView = try readSource(.rootView)
        let settings = try [
            readSource(.customizationSettingsView),
            readSource(.upgradeSettingsView),
            readSource(.bugReportSettingsView),
        ].joined(separator: "\n")

        XCTAssertTrue(attributes.contains("enum GuardianShieldStyle: String, CaseIterable, Identifiable, Codable, Hashable, Sendable"))
        XCTAssertTrue(attributes.contains("case original"))
        XCTAssertTrue(attributes.contains("case fireOpal = \"emberObsidian\""))
        XCTAssertTrue(attributes.contains("case purpleObsidian"))
        XCTAssertTrue(attributes.contains("case obsidian"))
        XCTAssertTrue(attributes.contains("case cherryQuartz = \"strawberryObsidian\""))
        XCTAssertTrue(attributes.contains("case emerald"))
        XCTAssertTrue(attributes.contains("\"Original\""))
        XCTAssertTrue(attributes.contains("\"Fire Opal\""))
        XCTAssertFalse(attributes.contains("\"Mahogany Obsidian\""))
        XCTAssertTrue(attributes.contains("\"Amethyst\""))
        XCTAssertTrue(attributes.contains("\"Obsidian\""))
        XCTAssertTrue(attributes.contains("\"Cherry Quartz\""))
        XCTAssertTrue(attributes.contains("\"Emerald\""))
        XCTAssertTrue(settings.contains("\"A Lava a day keeps bad domains away.\""))
        XCTAssertTrue(settings.contains("\"Always check the link first.\""))
        XCTAssertTrue(settings.contains("\"Block it once. Browse in peace.\""))
        XCTAssertTrue(settings.contains("\"Sign in where you meant to sign in.\""))
        XCTAssertTrue(settings.contains("\"Giveaways should not ask for secrets.\""))
        XCTAssertTrue(settings.contains("\"Make me your web-surfing buddy!\""))
        XCTAssertFalse(sharedMascot.contains("enum GuardianShieldStyle"))
        XCTAssertTrue(sharedMascot.contains("let shieldStyle: GuardianShieldStyle"))
        XCTAssertTrue(sharedMascot.contains("shieldStyle: GuardianShieldStyle = .original"))
        XCTAssertTrue(sharedMascot.contains("case .original:\n            originalShieldBody(frame)"))
        XCTAssertTrue(sharedMascot.contains("LavaGuardianShieldShape()\n                .fill(LavaGuardianStyle.guardianSleepGray)"))
        XCTAssertTrue(sharedMascot.contains("LavaGuardianShieldShape()\n                .fill(guardianGradient)"))
        XCTAssertFalse(sharedMascot.contains("Image(systemName: \"shield.fill\")"))
        XCTAssertTrue(sharedMascot.contains("private struct ObsidianShieldBody: View"))
        XCTAssertTrue(sharedMascot.contains("private struct ObsidianShieldPalette"))
        XCTAssertTrue(sharedMascot.contains("private enum ObsidianShieldColorway"))
        XCTAssertTrue(sharedMascot.contains("ObsidianShieldBody(wakeAmount: keepsColorWhenSleeping ? 1 : frame.shieldWakeAmount, style: shieldStyle)"))
        XCTAssertTrue(sharedMascot.contains("ObsidianShieldLayer(palette: ObsidianShieldPalette(wakeAmount: wakeAmount, style: style))"))
        XCTAssertTrue(sharedMascot.contains("private enum ObsidianSleepingPalette"))
        XCTAssertTrue(sharedMascot.contains("static let innerTop = LavaGuardianColorStop(red: 0.73, green: 0.76, blue: 0.74)"))
        XCTAssertTrue(sharedMascot.contains("case cherryQuartz"))
        XCTAssertTrue(sharedMascot.contains("case emerald"))
        XCTAssertTrue(sharedMascot.contains("Color(red: 1.00, green: 0.58, blue: 0.78)"))
        XCTAssertTrue(sharedMascot.contains("Color(red: 0.16, green: 0.47, blue: 0.34)"))
        XCTAssertTrue(sharedMascot.contains("LavaGuardianColorStop(red: 1.00, green: 0.84, blue: 0.92)"))
        XCTAssertTrue(sharedMascot.contains("LavaGuardianColorStop(red: 1.00, green: 0.62, blue: 0.80)"))
        XCTAssertTrue(sharedMascot.contains("LavaGuardianColorStop(red: 0.86, green: 0.32, blue: 0.56)"))
        XCTAssertTrue(sharedMascot.contains("LavaGuardianColorStop(red: 0.45, green: 0.86, blue: 0.63)"))
        XCTAssertTrue(sharedMascot.contains("case purple"))
        XCTAssertTrue(sharedMascot.contains("case neutral"))
        XCTAssertTrue(sharedMascot.contains("private struct LavaGuardianColorStop"))
        XCTAssertTrue(sharedMascot.contains("func color(blendingTo awake: LavaGuardianColorStop, wakeAmount: Double) -> Color"))
        XCTAssertTrue(sharedMascot.contains("private enum ObsidianShieldGeometry"))
        XCTAssertTrue(sharedMascot.contains("static let innerShieldScale: CGFloat = 0.91"))
        XCTAssertTrue(sharedMascot.contains("LavaGuardianShieldShape()\n                .fill(palette.innerGradient)"))
        XCTAssertTrue(sharedMascot.contains("LavaGuardianShieldRimShape(innerScale: ObsidianShieldGeometry.innerShieldScale)"))
        XCTAssertTrue(sharedMascot.contains(".fill(style: FillStyle(eoFill: true))"))
        XCTAssertTrue(sharedMascot.contains(".compositingGroup()"))
        XCTAssertFalse(sharedMascot.contains("ObsidianShieldLayer(palette: .sleeping)"))
        XCTAssertFalse(sharedMascot.contains("ObsidianShieldLayer(palette: .awake)"))
        XCTAssertFalse(sharedMascot.contains(".opacity(wakeAmount)"))
        XCTAssertFalse(sharedMascot.contains("EmberObsidianShieldBody(palette: .sleeping)\n                .opacity(1 - frame.shieldWakeAmount)"))
        XCTAssertFalse(sharedMascot.contains("LavaGuardianShieldShape(scaleX: 0.91, scaleY: 0.91)\n                .fill(palette.innerGradient)"))
        XCTAssertTrue(sharedMascot.contains("private struct LavaGuardianShieldRimShape: Shape"))
        XCTAssertTrue(sharedMascot.contains("private struct LavaGuardianShellFacet: Shape"))
        XCTAssertTrue(sharedMascot.contains("case warmSide"))
        XCTAssertTrue(sharedMascot.contains("GuardianMascotAnimationPlan"))
        XCTAssertFalse(sharedMascot.contains("case plusAwake"))
        XCTAssertFalse(sharedMascot.contains("case plusConcerned"))
        XCTAssertFalse(sharedMascot.contains("case plusGrateful"))

        XCTAssertTrue(settings.contains("shieldStyle: customization.lavaGuardLook"))
        XCTAssertTrue((try readSource(.reactNativeAppBridge)).contains("lavaGuardAvailability(for:"))
        XCTAssertTrue(settings.contains("case .cherryQuartz:"))
        XCTAssertTrue(settings.contains("case .emerald:"))
        XCTAssertTrue(settings.contains("\"Giveaways should not ask for secrets.\""))
        XCTAssertTrue(settings.contains("\"Make me your web-surfing buddy!\""))
        XCTAssertTrue(try readSource(.reactNativeReviewNavigation).contains("name: 'shield.fill'"))
        XCTAssertFalse(rootView.contains("LavaTabGuardianIcon()"))
        XCTAssertFalse(rootView.contains("private struct LavaTabGuardianIcon: View"))
        XCTAssertFalse(rootView.contains("TabView(selection: guardedRootTabSelection)"))
        // Canary: the negative pins above key on these identifiers - if a rename removes
        // one from the pinned source, those pins pass vacuously. Fail here instead, then
        // re-anchor both sides to the new name.
        XCTAssertTrue(sharedMascot.contains("GuardianShieldStyle"))
    }

    func testKiwiCremeGuardLookAddsOnlyColorSchemeAndLine() throws {
        let sharedMascot = try readSource(.softShieldGuardian)
        let attributes = try readSource(.lavaActivityAttributes)
        let settings = try readSource(.customizationSettingsView)
        let faceBlock = try sourceBlock(
            in: sharedMascot,
            startingAt: "private func face(_ frame: GuardianMascotFrame) -> some View",
            endingBefore: "private var faceColor: Color"
        )
        let shieldBodyBlock = try sourceBlock(
            in: sharedMascot,
            startingAt: "private func shieldBody(_ frame: GuardianMascotFrame) -> some View",
            endingBefore: "private func originalShieldBody"
        )

        XCTAssertTrue(attributes.contains("case kiwiCreme"))
        XCTAssertTrue(attributes.contains("\"Kiwi Crème\""))
        XCTAssertTrue(settings.contains("case .kiwiCreme:"))
        XCTAssertTrue(settings.contains("\"Hey I'm no rock but I take security paw-sonally. U know what I mean?\""))
        XCTAssertTrue(sharedMascot.contains("case kiwiCreme"))
        XCTAssertTrue(sharedMascot.contains("case .kiwiCreme:"))
        XCTAssertTrue(sharedMascot.contains("static let kiwiCremeCanonicalColorRGB: RGB = (0.91, 0.84, 0.72)"))
        XCTAssertTrue(sharedMascot.contains("static let kiwiCremeSupportBrownRGB: RGB = (0.46, 0.39, 0.32)"))
        XCTAssertTrue(sharedMascot.contains("LavaGuardianStyle.kiwiCremeGlyph"))
        XCTAssertTrue(shieldBodyBlock.contains(".kiwiCreme"))
        XCTAssertFalse(faceBlock.contains("kiwiCreme"))
    }

    func testLiveActivitySharedModelAndActionRequestsUseAppGroupCommandPath() throws {
        let attributes = try readSource(.lavaActivityAttributes)
        let actionRequest = try readSource(.lavaLiveActivityActionRequest)
        let intents = try readSource(.lavaLiveActivityIntents)
        let commandService = try readSource(.lavaProtectionCommandService)
        let widget = try readSource(.lavaSecWidget)

        XCTAssertTrue(attributes.contains("import ActivityKit"))
        XCTAssertTrue(attributes.contains("struct LavaActivityAttributes: ActivityAttributes"))
        XCTAssertTrue(attributes.contains("enum ProtectionState: String, Codable, Hashable, Sendable"))
        XCTAssertTrue(attributes.contains("case on"))
        XCTAssertTrue(attributes.contains("case paused"))
        XCTAssertTrue(attributes.contains("var guardianState: GuardianMascotState"))
        XCTAssertTrue(widget.contains("func statusSymbolName(for protectionState:"))
        XCTAssertTrue(attributes.contains("var pauseRequiresAuthentication: Bool"))
        XCTAssertTrue(attributes.contains("var shieldStyle: GuardianShieldStyle"))
        XCTAssertTrue(attributes.contains("decodeIfPresent(GuardianShieldStyle.self, forKey: .shieldStyle) ?? .original"))
        // The configured pause length rides along in the content state, defaulting
        // through the shared policy when an older payload omits it.
        XCTAssertTrue(attributes.contains("var pauseMinutes: Int"))
        XCTAssertTrue(attributes.contains("decodeIfPresent(Int.self, forKey: .pauseMinutes)"))
        XCTAssertTrue(attributes.contains("?? LiveActivityPausePreference.defaultMinutes"))
        XCTAssertTrue(widget.contains("\"checkmark\""))
        XCTAssertTrue(widget.contains("\"pause.fill\""))
        XCTAssertFalse(widget.contains("\"checkmark.circle.fill\""))
        XCTAssertFalse(widget.contains("\"pause.circle.fill\""))

        XCTAssertTrue(actionRequest.contains("enum LavaLiveActivityActionRequest: String, Codable, Sendable"))
        XCTAssertTrue(actionRequest.contains("case pauseFiveMinutes = \"pause-5-minutes\""))
        XCTAssertTrue(actionRequest.contains("case pauseTenMinutes = \"pause-10-minutes\""))
        XCTAssertTrue(actionRequest.contains("case pauseFifteenMinutes = \"pause-15-minutes\""))
        XCTAssertTrue(actionRequest.contains("case pauseConfigured = \"pause-configured\""))
        XCTAssertTrue(actionRequest.contains("case resume"))
        XCTAssertFalse(actionRequest.contains("case turnOff"))
        XCTAssertFalse(actionRequest.contains("pendingRequestDefaultsKey"))
        XCTAssertFalse(actionRequest.contains("actionNonceDefaultsKey"))
        XCTAssertFalse(actionRequest.contains("static func actionURL"))
        XCTAssertFalse(actionRequest.contains("static func pendingRequest("))

        XCTAssertTrue(intents.contains("struct PauseLavaProtectionIntent: AppIntent, LiveActivityIntent"))
        XCTAssertTrue(intents.contains("struct PauseLavaProtectionFiveMinutesIntent: AppIntent, LiveActivityIntent"))
        XCTAssertTrue(intents.contains("struct PauseLavaProtectionTenMinutesIntent: AppIntent, LiveActivityIntent"))
        XCTAssertTrue(intents.contains("struct AuthenticatedPauseLavaProtectionFiveMinutesIntent: AppIntent, LiveActivityIntent"))
        XCTAssertTrue(intents.contains("struct AuthenticatedPauseLavaProtectionTenMinutesIntent: AppIntent, LiveActivityIntent"))
        XCTAssertTrue(intents.contains("struct ResumeLavaProtectionIntent: AppIntent, LiveActivityIntent"))
        XCTAssertTrue(intents.contains("nonisolated(unsafe) public static var isDiscoverable = false"))
        XCTAssertTrue(intents.contains("nonisolated(unsafe) public static var authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication"))
        XCTAssertTrue(intents.contains(".requiresLocalDeviceAuthentication"))
        XCTAssertFalse(intents.contains("openAppWhenRun = true"))
        XCTAssertFalse(intents.contains("struct TurnOffLavaProtectionIntent"))
        XCTAssertTrue(intents.contains("try await LavaProtectionCommandService.perform(.pauseConfigured)"))
        XCTAssertTrue(intents.contains("try await LavaProtectionCommandService.perform(.pauseFiveMinutes)"))
        XCTAssertTrue(intents.contains("try await LavaProtectionCommandService.perform(.pauseTenMinutes)"))
        XCTAssertTrue(intents.contains("try await LavaProtectionCommandService.perform(.resume)"))
        XCTAssertFalse(intents.contains("LavaLiveActivityActionRequest.storePendingRequest"))

        XCTAssertTrue(commandService.contains("enum LavaProtectionCommandService"))
        XCTAssertTrue(commandService.contains("LavaSecAppGroup.sharedDefaults"))
        XCTAssertTrue(
            commandService.contains("ProtectionPauseStore(") && commandService.contains("ProtectionSessionStore("),
            "Pause/resume command state must flow through the LavaSecKit stores, not inline key access."
        )
        XCTAssertTrue(commandService.contains("pauseStore.pause(for: duration, requestedSessionID: sessionID, commandID: commandID)"))
        XCTAssertTrue(commandService.contains("pauseStore.resume(requestedSessionID: sessionID, commandID: commandID)"))
        XCTAssertTrue(
            commandService.contains("SecurityProtectedSurfaceStorage.isProtected(.protectionPause, defaults: defaults,\n            projectionURL: LavaSecAppGroup.securityGateProjectionURL)"),
            "Auth-protected pause denial must stay enforced in the command service."
        )
        XCTAssertFalse(
            commandService.contains("CFNotificationCenterPostNotification"),
            "Pause/resume no longer post a Darwin signal; pause state reaches the tunnel via the reload-protection-pause provider message."
        )
        // #364 follow-up: a pause STARTED from the Live Activity / Dynamic Island runs through this
        // service (not AppViewModel), so it must ALSO poke the tunnel to (re)arm its expiry timer —
        // otherwise the "Protection resumed" banner (posted only by that timer) never fires for a
        // closed-app intent pause. Pin the notify send and its wiring into perform().
        XCTAssertTrue(
            commandService.contains("private static func notifyTunnelPauseStateChanged() async"),
            "The command service must notify the tunnel of pause-state changes so the resume timer arms for intent-initiated pauses."
        )
        XCTAssertTrue(
            commandService.contains("await notifyTunnelPauseStateChanged()"),
            "perform() must call notifyTunnelPauseStateChanged() after applying a pause/resume command."
        )
        XCTAssertTrue(
            commandService.contains("kind: LavaSecAppGroup.reloadProtectionPauseMessage")
                && commandService.contains("session.sendProviderMessage(messageData)"),
            "The notify must send the reload-protection-pause provider message to the running tunnel session."
        )
        // Must target the CONNECTED session, not `.first`: a stale/legacy Lava profile can list a
        // disconnected duplicate ahead of the active tunnel, and `.first` would skip the notify on
        // those devices (Codex). Scan for the live provider session instead.
        XCTAssertTrue(
            commandService.contains(".first { $0.status == .connected }"),
            "The notify must scan for the connected provider session, not just the first manager."
        )
        XCTAssertFalse(
            commandService.contains("(managers ?? []).first?.connection as? NETunnelProviderSession"),
            "Reading only the first manager's connection re-opens the stale-duplicate gap; scan for the connected one."
        )
        // The notify is best-effort but must not fail SILENTLY: a load/send failure or a no-connected-session
        // miss (the fix degrading back to the original bug) has to be recordable in a field report. Pin the
        // ship-safe breadcrumbs (OCR #365 follow-up) so a regression to an empty catch is caught here.
        XCTAssertTrue(
            commandService.contains("event: \"notify-pause-load-error\"")
                && commandService.contains("event: \"notify-pause-send-error\"")
                && commandService.contains("event: \"notify-pause-no-connected-session\""),
            "Notify failure/miss paths must leave ship-safe LavaSecDeviceDebugLog breadcrumbs, not be swallowed."
        )
        XCTAssertFalse(commandService.contains("passThroughPreparedSnapshot"))
        XCTAssertFalse(commandService.contains("PreparedFilterSnapshotIdentity.make(configuration: passThroughConfiguration, catalog: nil)"))
        XCTAssertTrue(commandService.contains("Activity<LavaActivityAttributes>.activities"))
        XCTAssertTrue(commandService.contains("private static func persistedShieldStyle(defaults: UserDefaults) -> GuardianShieldStyle"))
        XCTAssertTrue(commandService.contains("LavaSecAppGroup.customizationLavaGuardLookDefaultsKeyName"))
        XCTAssertTrue(commandService.contains("shieldStyle: persistedShieldStyle(defaults: defaults)"))

        // `.pauseConfigured` resolves the user-chosen length from the shared
        // policy, and the published content state carries it for the button label.
        XCTAssertTrue(commandService.contains("case .pauseFiveMinutes, .pauseTenMinutes, .pauseFifteenMinutes, .pauseConfigured:"))
        XCTAssertTrue(commandService.contains("guard let duration = resolvedPauseDuration(for: request, defaults: defaults) else"))
        XCTAssertTrue(commandService.contains("LiveActivityPausePreference.duration(forMinutes: persistedPauseMinutes(defaults: defaults))"))
        XCTAssertTrue(commandService.contains("LiveActivityPausePreference.minutes(from: ProtectionUserDefaultsStorage(defaults: defaults))"))
        XCTAssertTrue(commandService.contains("pauseMinutes: persistedPauseMinutes(defaults: defaults)"))
    }

    func testDynamicIslandModelsOnPausedAndTransientRestartingOnly() throws {
        let attributes = try readSource(.lavaActivityAttributes)
        let widget = try readSource(.lavaSecWidget)
        let appViewModel = try readAppViewModelSource()

        // ProtectionState models the two states the surface can keep honest while
        // suspended (on/paused) plus `restarting`, a transient set and cleared
        // entirely within a user-initiated Restart command. The ambient connectivity
        // states stay removed — they changed while the app could not push.
        XCTAssertTrue(attributes.contains("case on"))
        XCTAssertTrue(attributes.contains("case paused"))
        XCTAssertTrue(attributes.contains("case restarting"))
        XCTAssertFalse(attributes.contains("case reconnecting"))
        XCTAssertFalse(attributes.contains("case needsReconnect"))
        XCTAssertFalse(attributes.contains("case networkUnavailable"))

        // The ambient alarm glyphs/titles stay gone. The spinner glyph is back, but
        // only for the transient restarting feedback.
        XCTAssertFalse(widget.contains("\"exclamationmark.triangle.fill\""))
        XCTAssertFalse(widget.contains("\"wifi.slash\""))
        XCTAssertFalse(widget.contains("Lava Security needs to reconnect"))
        XCTAssertFalse(widget.contains("Waiting for network"))
        XCTAssertTrue(widget.contains("\"checkmark\""))
        XCTAssertTrue(widget.contains("\"pause.fill\""))
        XCTAssertTrue(widget.contains("\"arrow.triangle.2.circlepath\""))
        XCTAssertTrue(widget.contains("\"widget.state.restartingTitle\""))

        // The status mapping still only ever emits on/paused/nil — restarting is
        // pushed by the Restart command, never derived from connectivity status.
        let mappingBlock = try sourceBlock(
            in: appViewModel,
            startingAt: "private func liveActivityProtectionState",
            endingBefore: "func turnOffProtection()"
        )
        XCTAssertTrue(mappingBlock.contains("if isProtectionTemporarilyPaused {\n            return .paused\n        }"))
        XCTAssertTrue(mappingBlock.contains("return .on"))
        XCTAssertFalse(mappingBlock.contains("return .needsReconnect"))
        XCTAssertFalse(mappingBlock.contains("return .reconnecting"))
        XCTAssertFalse(mappingBlock.contains("return .networkUnavailable"))

        // restarting is emitted only while a Restart is in flight (a user action),
        // never derived from connectivity — and gated BEFORE the vpnStatus guard so
        // the activity isn't ended while the restart bounces the tunnel's status.
        XCTAssertTrue(mappingBlock.contains("if restartInFlightDeadline != nil {\n            return .restarting\n        }"))
        let restartingIdx = try XCTUnwrap(mappingBlock.range(of: "return .restarting")?.lowerBound)
        let vpnGuardIdx = try XCTUnwrap(mappingBlock.range(of: "guard vpnStatus == .connected")?.lowerBound)
        XCTAssertLessThan(restartingIdx, vpnGuardIdx)

        // An in-flight activity an older build encoded with a now-removed state
        // must still decode (resolving to .on) instead of failing.
        XCTAssertTrue(
            attributes.contains("(try? container.decode(ProtectionState.self, forKey: .protectionState)) ?? .on")
        )
        // No canaries for the `case needsReconnect` / `case networkUnavailable` pins: those
        // are REMOVAL pins (the states must stay deleted), so the identifiers are expected
        // to be dead in this source — only a comment mentions them today, and pinning a
        // comment would fail on a harmless rewording. The decode-compat behavior they
        // protect is anchored by the `?? .on` fallback assertion above.
    }

    func testDynamicIslandActionLayoutIsPausePrimaryWithSecondaryRestart() throws {
        let widget = try readSource(.lavaSecWidget)
        let intents = try readSource(.lavaLiveActivityIntents)
        let appViewModel = try readAppViewModelSource()

        let actionBlock = try sourceBlock(
            in: widget,
            startingAt: "// Action row.",
            endingBefore: ".frame(maxWidth: .infinity, alignment: .leading)"
        )
        let onIdx = try XCTUnwrap(actionBlock.range(of: "case .on:")?.lowerBound)
        let pausedIdx = try XCTUnwrap(actionBlock.range(of: "case .paused:")?.lowerBound)
        let restartingIdx = try XCTUnwrap(actionBlock.range(of: "case .restarting:")?.lowerBound)
        // GUARDED, NOT ASSERTED. Both `actionBlock[onIdx..<pausedIdx]` and
        // `actionBlock[pausedIdx..<restartingIdx]` below are built from independently-searched
        // indices, and `XCTAssertLessThan` is non-fatal — so reordering these switch cases traps
        // and kills the xctest process, taking the whole bundle's results with it rather than
        // failing this one test (Codex P2, PR #605).
        guard onIdx < pausedIdx, pausedIdx < restartingIdx else {
            return XCTFail("Action-row cases must stay in .on, .paused, .restarting order.")
        }

        // On: Pause is primary (takes the row), Restart recedes to a secondary icon;
        // when Pause is auth-locked the lone Restart is promoted to a labelled button.
        let onBlock = String(actionBlock[onIdx..<pausedIdx])
        XCTAssertTrue(onBlock.contains("if !state.pauseRequiresAuthentication"))
        // Pause draws the duration-only short title plus a separate full-phrase accessibility
        // label (rationale on pauseButtonTitle / pauseButtonAccessibilityLabel in the widget).
        XCTAssertTrue(onBlock.contains("pauseButton("))
        XCTAssertTrue(onBlock.contains("title: pauseButtonTitle(forMinutes: state.pauseMinutes, languageCode: languageCode)"))
        XCTAssertTrue(onBlock.contains("accessibilityLabel: pauseButtonAccessibilityLabel(forMinutes: state.pauseMinutes, languageCode: languageCode)"))
        XCTAssertTrue(onBlock.contains("restartIconButton"))
        XCTAssertTrue(onBlock.contains("restartLabeledButton"))

        // Paused: only Resume. Restarting: no action (the title carries status).
        let pausedBlock = String(actionBlock[pausedIdx..<restartingIdx])
        XCTAssertTrue(pausedBlock.contains("resumeButton"))
        XCTAssertFalse(pausedBlock.contains("restart"), "Paused must not surface Restart.")
        XCTAssertTrue(actionBlock[restartingIdx...].contains("EmptyView()"))

        // Pause/Resume keep the prominent green tint; both Restart variants are the
        // muted secondary grey and reuse the reconnect command via an icon + label.
        XCTAssertTrue(widget.contains(".tint(LavaLiveActivityStyle.lavaGreen)"))
        XCTAssertTrue(widget.contains(".tint(LavaLiveActivityStyle.lavaSecondaryGray)"))
        XCTAssertTrue(widget.contains("Image(systemName: \"arrow.clockwise\")"))
        XCTAssertTrue(widget.contains(".accessibilityLabel(LavaCoreStrings.localized(\"widget.action.restart\", languageCode: languageCode))"))
        XCTAssertTrue(widget.contains("Button(intent: ReconnectLavaProtectionIntent())"))
        XCTAssertTrue(widget.contains("restartActivityActionLabel(LavaCoreStrings.localized(\"widget.action.restart\", languageCode: languageCode))"))
        XCTAssertTrue(widget.contains("Button(intent: ResumeLavaProtectionIntent())"))
        XCTAssertFalse(widget.contains("liveActivityActionLabel(\"Reconnect\")"))

        XCTAssertTrue(intents.contains("struct ReconnectLavaProtectionIntent"))
        XCTAssertTrue(intents.contains("\"Restart Lava Protection\""))
        XCTAssertTrue(intents.contains("LavaProtectionCommandService.perform(.reconnect)"))
        XCTAssertTrue(appViewModel.contains("case .reconnect:\n            reconnectProtection()"))
        // Canary: the negative pins above key on these identifiers - if a rename removes
        // one from the pinned source, those pins pass vacuously. Fail here instead, then
        // re-anchor both sides to the new name.
        XCTAssertTrue(widget.contains("liveActivityActionLabel"))
    }

    func testLiveActivityRestartPerformsRealStopThenStart() throws {
        let commandService = try readSource(.lavaProtectionCommandService)

        // Restart is now offered while the tunnel is already connected, so a bare
        // start would be a no-op. performReconnect must stop, wait, then start.
        let reconnectBlock = try sourceBlock(
            in: commandService,
            startingAt: "private static func performReconnect()",
            endingBefore: "private static let reconnectStopWaitTimeout"
        )
        let stopIndex = try XCTUnwrap(reconnectBlock.range(of: "stopVPNTunnel()")?.lowerBound)
        let waitIndex = try XCTUnwrap(reconnectBlock.range(of: "waitForTunnelToStop(")?.lowerBound)
        let startIndex = try XCTUnwrap(reconnectBlock.range(of: "startVPNTunnel()")?.lowerBound)
        let reconnectWaitIndex = try XCTUnwrap(reconnectBlock.range(of: "waitForTunnelToReconnect(")?.lowerBound)
        XCTAssertLessThan(stopIndex, waitIndex, "Restart must stop the tunnel before waiting.")
        XCTAssertLessThan(waitIndex, startIndex, "Restart must wait for the stop before starting.")
        // After starting, wait for the tunnel to settle so the post-start grace
        // window doesn't end the activity on a successful restart.
        XCTAssertLessThan(startIndex, reconnectWaitIndex, "Restart must wait for reconnect after starting.")

        let markerIndex = try XCTUnwrap(
            reconnectBlock.range(of: "ChainedStartupFailureMarker.beginExplicitRetry(")?.lowerBound
        )
        XCTAssertLessThan(markerIndex, stopIndex, "Restart must advance the marker before stopping.")
        XCTAssertTrue(reconnectBlock.contains("LavaSecAppGroup.chainedStartupFailureMarkerURL"))
        XCTAssertTrue(reconnectBlock.contains("storageURL: markerURL"))
        XCTAssertTrue(reconnectBlock.contains("LavaSecAppGroup.chainedStartupFailureMarkerLockURL"))
        XCTAssertTrue(commandService.contains("private static func waitForTunnelToReconnect(timeout: TimeInterval) async"))

        // On-demand must NOT be disabled here — a background-woken intent could
        // leave protection un-armed if its window expired before re-enabling it.
        XCTAssertFalse(reconnectBlock.contains("isOnDemandEnabled = false"))
        XCTAssertFalse(reconnectBlock.contains("disableOnDemand"))

        // The explicit start is gated on a confirmed stop; the wait reports a Bool.
        XCTAssertTrue(commandService.contains("private static func waitForTunnelToStop(timeout: TimeInterval) async throws -> Bool"))
        XCTAssertTrue(commandService.contains("case .disconnected, .invalid, nil:"))
        XCTAssertTrue(reconnectBlock.contains("if try await waitForTunnelToStop("))

        // A slow/wedged stop must not log a phantom restart: on timeout it either
        // credits an on-demand reconnect (real bounce) or surfaces the failure.
        XCTAssertTrue(reconnectBlock.contains("reconnect-restarted-by-ondemand"))
        XCTAssertTrue(reconnectBlock.contains("throw RestartError.stopTimedOut"))

        // The on-demand credit branch must ALSO settle to .connected before
        // returning (a pending .connecting/.reasserting handoff would otherwise be
        // sampled by the restore and end the activity on a successful restart), so
        // both the explicit-start and on-demand paths wait for reconnect.
        let reconnectWaits = reconnectBlock.components(separatedBy: "waitForTunnelToReconnect(").count - 1
        XCTAssertGreaterThanOrEqual(
            reconnectWaits,
            2,
            "Both the explicit-start and on-demand restart paths must settle to .connected before returning."
        )
    }

    func testLiveActivityRestartShowsTransientRestartingFeedback() throws {
        let commandService = try readSource(.lavaProtectionCommandService)

        XCTAssertTrue(commandService.contains("private static let restartingStaleWindow: TimeInterval"))

        let performBlock = try sourceBlock(
            in: commandService,
            startingAt: "private static func performReconnect()",
            endingBefore: "private static func restoreLiveActivityAfterRestart()"
        )
        // Claim the in-flight slot first (rejects double-taps), then show "restarting"
        // before the work begins. The claim returns the exact deadline it stored so
        // the slot can be released by compare-and-set (a stale restart can't clear a
        // newer tap's lease).
        XCTAssertTrue(performBlock.contains("guard let claimedRestart = try await claimRestartInFlight(window: Self.restartingStaleWindow) else"))
        XCTAssertFalse(
            performBlock.contains("let now = Date()"),
            "Production restart claims must sample time only after acquiring the cross-process lock."
        )
        XCTAssertTrue(performBlock.contains("reconnect-already-in-flight"))
        let claimIdx = try XCTUnwrap(performBlock.range(of: "claimRestartInFlight(window:")?.lowerBound)
        let restartingIdx = try XCTUnwrap(performBlock.range(of: "protectionState: .restarting")?.lowerBound)
        let runIdx = try XCTUnwrap(
            performBlock.range(of: "runTunnelRestart(lifecycleLease: claimedRestart.lifecycleLease)")?.lowerBound
        )
        XCTAssertLessThan(claimIdx, restartingIdx, "The in-flight slot must be claimed before showing restarting.")
        XCTAssertLessThan(restartingIdx, runIdx, "Restarting feedback must show before the restart work starts.")

        // The deadline travels in resumeDate so the widget self-advances .restarting
        // → .on on its own clock (it can't be left stranded by a killed window).
        XCTAssertTrue(performBlock.contains("resumeDate: claimedRestart.deadline"))

        // Both exit paths settle the exact deadline/token pair before releasing the fence and
        // restore via the status-derived helper — NOT an unconditional .on push (a failed restart
        // must not claim On). Restore runs ONLY when we still owned the pair, so a stale restart
        // that lost its token cannot clobber a successor's state.
        XCTAssertTrue(performBlock.contains("let didOwnRestart = await finishRestartInFlight(claimedRestart)"))
        let clears = performBlock.components(separatedBy: "await finishRestartInFlight(claimedRestart)").count - 1
        XCTAssertEqual(clears, 2, "Success and failure must each settle their exact deadline/token pair.")
        let restores = performBlock.components(separatedBy: "restoreLiveActivityAfterRestart()").count - 1
        XCTAssertEqual(restores, 2, "Both exit paths must restore via the status-derived helper.")
        let guardedRestores = performBlock.components(separatedBy: "if didOwnRestart {").count - 1
        XCTAssertEqual(guardedRestores, 2, "Each restore must be gated on still owning the lease.")
        XCTAssertTrue(
            performBlock.contains("leaseRenewal.cancel()"),
            "The restart must stop the competing renewal task before exact-token cleanup."
        )
        XCTAssertTrue(
            performBlock.contains("claimedRestart.mutationFence.release()"),
            "The kernel fence must survive every suspension through the restart's final tunnel mutation."
        )
        XCTAssertFalse(performBlock.contains("updateLiveActivities(protectionState: .on"))

        // restoreLiveActivityAfterRestart re-derives from the real tunnel status and
        // ends the activity (never claims On) when the tunnel is down.
        let restoreBlock = try sourceBlock(
            in: commandService,
            startingAt: "private static func restoreLiveActivityAfterRestart()",
            endingBefore: "private static func endLiveActivities()"
        )
        // A pause that landed during the restart is honored before any On push.
        let pauseIdx = try XCTUnwrap(restoreBlock.range(of: "pauseStore.currentPauseState()")?.lowerBound)
        let onIdx = try XCTUnwrap(restoreBlock.range(of: "protectionState: .on")?.lowerBound)
        XCTAssertLessThan(pauseIdx, onIdx, "An active pause must be honored before falling back to On.")
        XCTAssertTrue(restoreBlock.contains("protectionState: .paused, resumeDate: pauseState.pausedUntil"))
        // Only a CONFIRMED .connected publishes On; connecting/reasserting/down all
        // end the activity rather than asserting a permanent (uncorrectable) On.
        XCTAssertTrue(restoreBlock.contains("case .connected:"))
        XCTAssertFalse(restoreBlock.contains("case .connected, .connecting, .reasserting:"))
        XCTAssertTrue(restoreBlock.contains("updateLiveActivities(protectionState: .on, resumeDate: nil)"))
        XCTAssertTrue(restoreBlock.contains("await endLiveActivities()"))
        XCTAssertTrue(commandService.contains("await activity.end(nil, dismissalPolicy: .immediate)"))

        // The in-flight slot is an auto-expiring shared deadline read by the app's
        // status reconcile (isRestartInFlight) so the two never fight. The claim
        // returns its deadline and the clear is a compare-and-set keyed on that exact
        // value, so an older expired-but-unwinding restart can't delete a newer tap's
        // lease (which would drop the newer restart's `.restarting` guard).
        XCTAssertTrue(commandService.contains("async throws -> RestartInFlightClaim?"))
        XCTAssertTrue(commandService.contains("private static func finishRestartInFlight(_ claim: RestartInFlightClaim) async -> Bool"))
        XCTAssertTrue(commandService.contains("if stored == deadline.timeIntervalSinceReferenceDate"))
        XCTAssertTrue(commandService.contains("store.release(lifecycleLease)"))
        XCTAssertTrue(
            commandService.contains("return clearedDeadline && releasedLease"),
            "An expired restart must not restore Live Activity state after a newer lifecycle owner took over."
        )
        XCTAssertTrue(commandService.contains("LavaSecAppGroup.protectionRestartInFlightUntilDefaultsKeyName"))
        XCTAssertTrue(commandService.contains("LavaProtectionCommandFileLock.withExclusiveLock"))

        // The app's reconcile path carries the same deadline as resumeDate when
        // restarting, so the widget self-clear is consistent across both push paths.
        let appViewModel = try readAppViewModelSource()
        XCTAssertTrue(appViewModel.contains("var isRestartInFlight: Bool"))
        XCTAssertTrue(appViewModel.contains("private var restartInFlightDeadline: Date?"))
        XCTAssertTrue(appViewModel.contains("protectionState == .restarting ? restartDeadline : temporaryProtectionPauseUntil"))

        // The widget resolves BOTH transient states to On via its own clock.
        XCTAssertTrue(try readSource(.lavaActivityAttributes).contains("case .paused, .restarting:"))

        // The controller must PRESERVE the deadline for .restarting (not null it like
        // .on), or the reconcile-path republish would strip the widget's self-clear.
        let controller = try readSource(.lavaLiveActivityController)
        XCTAssertTrue(controller.contains("case .restarting:\n            publishedResumeDate = resumeDate"))
        XCTAssertTrue(controller.contains("case .on:\n            publishedResumeDate = nil"))
        XCTAssertTrue(controller.contains("ActivityContent(state: state, staleDate: publishedResumeDate)"))
    }

    func testLiveActivityRestartClaimsAndRenewsSharedLifecycleLease() throws {
        let commandService = try readSource(.lavaProtectionCommandService)
        let perform = try sourceBlock(
            in: commandService,
            startingAt: "private static func performReconnect()",
            endingBefore: "private static func restoreLiveActivityAfterRestart()"
        )

        XCTAssertTrue(perform.contains("claimedRestart.lifecycleLease"))
        XCTAssertTrue(perform.contains("startProtectionLifecycleLeaseRenewal"))
        XCTAssertTrue(perform.contains("runTunnelRestart(lifecycleLease: claimedRestart.lifecycleLease)"))
        XCTAssertTrue(commandService.contains("ProtectionLifecycleLeaseStore("))
        XCTAssertTrue(commandService.contains("claimExplicitRestart("))
        XCTAssertTrue(commandService.contains("claimAutomaticRestore("))
        XCTAssertTrue(commandService.contains("expectedExternalRestartGeneration:"))
        XCTAssertTrue(commandService.contains("store.release(lease)"))
        XCTAssertTrue(commandService.contains("store.renew(lease, leaseDuration:"))
        XCTAssertTrue(commandService.contains("ProtectionFileKeyValueStorage("))
        XCTAssertTrue(commandService.contains("persistIfNeeded()"))
        XCTAssertTrue(commandService.contains("withRequiredExclusiveLock"))
        XCTAssertFalse(
            commandService.contains("clearProtectionSessionIfNoLiveLifecycleSuccessor"),
            "Lifecycle-file ownership cannot make a cross-process UserDefaults session CAS fresh or atomic."
        )
        let lifecycleTransaction = try sourceBlock(
            in: commandService,
            startingAt: "private static func withProtectionLifecycleTransaction",
            endingBefore: "// commandID threads"
        )
        XCTAssertFalse(lifecycleTransaction.contains("ProtectionUserDefaultsStorage"))
        let lockIndex = try XCTUnwrap(lifecycleTransaction.range(of: "withRequiredExclusiveLock")?.lowerBound)
        let clockIndex = try XCTUnwrap(lifecycleTransaction.range(of: "let transactionNow = now ?? Date()")?.lowerBound)
        XCTAssertLessThan(
            lockIndex,
            clockIndex,
            "Production lifecycle transactions must sample time after nonblocking lock acquisition succeeds."
        )
        XCTAssertTrue(lifecycleTransaction.contains("clock: LavaProtectionCommandClock(now: transactionNow)"))

        // The restart deadline remains a separate UI transient. It is checked in the same short
        // file-locked claim, but the lifecycle lease has its own token/CAS and expiry state.
        XCTAssertTrue(commandService.contains("protectionRestartInFlightUntilDefaultsKeyName"))
        XCTAssertTrue(commandService.contains("RestartInFlightClaim"))

        let restartClaim = try sourceBlock(
            in: commandService,
            startingAt: "private static func claimRestartInFlight(",
            endingBefore: "/// Clears this Restart's exact UI deadline"
        )
        let fenceIndex = try XCTUnwrap(restartClaim.range(of: "acquireProtectionLifecycleMutationFence(wait: false)")?.lowerBound)
        let transactionIndex = try XCTUnwrap(restartClaim.range(of: "withProtectionLifecycleTransaction")?.lowerBound)
        XCTAssertLessThan(fenceIndex, transactionIndex)
        XCTAssertTrue(restartClaim.contains("mutationFence: mutationFence"))

        let restart = try sourceBlock(
            in: commandService,
            startingAt: "private static func runTunnelRestart(",
            endingBefore: "private static let reconnectStopWaitTimeout"
        )
        let stop = try XCTUnwrap(restart.range(of: "connection.stopVPNTunnel()")?.lowerBound)
        let start = try XCTUnwrap(restart.range(of: "connection.startVPNTunnel()")?.lowerBound)
        let firstRenewal = try XCTUnwrap(
            restart.range(of: "renewProtectionLifecycleLeaseWithRetry(lifecycleLease)")
        )
        let secondRenewal = try XCTUnwrap(
            restart.range(
                of: "renewProtectionLifecycleLeaseWithRetry(lifecycleLease)",
                range: firstRenewal.upperBound..<restart.endIndex
            )
        )
        XCTAssertLessThan(firstRenewal.lowerBound, stop)
        XCTAssertLessThan(secondRenewal.lowerBound, start)
    }

    func testRequiredLifecycleStateLockFailsClosedWithoutBlockingMainActor() throws {
        let commandService = try readSource(.lavaProtectionCommandService)
        XCTAssertTrue(commandService.contains("ProtectionLifecycleStateTransaction.withRequiredExclusiveLock"))
        XCTAssertTrue(commandService.contains("ProtectionLifecycleStateTransactionError.missingContainer"))

        let strictCapture = try sourceBlock(
            in: commandService,
            startingAt: "static func captureExternalRestartGeneration(",
            endingBefore: "static func claimAutomaticRestoreLease("
        )
        XCTAssertTrue(strictCapture.contains("try withProtectionLifecycleTransaction"))
        XCTAssertFalse(strictCapture.contains("try? withProtectionLifecycleTransaction"))

        let optionalCurrent = try sourceBlock(
            in: commandService,
            startingAt: "static func currentExternalRestartGeneration(",
            endingBefore: "/// Strict generation capture"
        )
        XCTAssertTrue(optionalCurrent.contains("(try? withProtectionLifecycleTransaction"))
        XCTAssertTrue(optionalCurrent.contains("}) ?? nil"))

        let optionalClaim = try sourceBlock(
            in: commandService,
            startingAt: "static func claimAutomaticRestoreLease(",
            endingBefore: "@discardableResult\n    static func renewProtectionLifecycleLease("
        )
        XCTAssertTrue(optionalClaim.contains("(try? withProtectionLifecycleTransaction"))
        XCTAssertTrue(optionalClaim.contains("}) ?? nil"))

        let booleanRenew = try sourceBlock(
            in: commandService,
            startingAt: "static func renewProtectionLifecycleLease(",
            endingBefore: "@discardableResult\n    static func releaseProtectionLifecycleLease("
        )
        XCTAssertTrue(booleanRenew.contains("(try? withProtectionLifecycleTransaction"))
        XCTAssertTrue(booleanRenew.contains("}) ?? false"))

        let booleanRelease = try sourceBlock(
            in: commandService,
            startingAt: "static func releaseProtectionLifecycleLease(",
            endingBefore: "static func startProtectionLifecycleLeaseRenewal("
        )
        XCTAssertTrue(booleanRelease.contains(") async -> Bool"))
        XCTAssertTrue(booleanRelease.contains("ProtectionLifecycleStateTransaction.retryingBusy"))
        XCTAssertTrue(booleanRelease.contains("}) ?? false"))
    }

    func testLiveActivityPauseActionsAreHiddenAndDeniedWhenPauseRequiresAuthentication() throws {
        let widget = try readSource(.lavaSecWidget)
        let commandService = try readSource(.lavaProtectionCommandService)

        let onStateBlock = try sourceBlock(
            in: widget,
            startingAt: "if !state.pauseRequiresAuthentication",
            endingBefore: "case .paused:"
        )
        XCTAssertTrue(onStateBlock.contains("if !state.pauseRequiresAuthentication"))
        // Single configured-length Pause button, gated behind the same auth check. Its visible
        // title is duration-only; the full pause-for-minutes phrase rides the separate
        // accessibility label (rationale on pauseButtonTitle / pauseButtonAccessibilityLabel).
        XCTAssertTrue(onStateBlock.contains("pauseButton("))
        XCTAssertTrue(onStateBlock.contains("title: pauseButtonTitle(forMinutes: state.pauseMinutes, languageCode: languageCode)"))
        XCTAssertTrue(onStateBlock.contains("accessibilityLabel: pauseButtonAccessibilityLabel(forMinutes: state.pauseMinutes, languageCode: languageCode)"))
        XCTAssertFalse(onStateBlock.contains("pauseFiveMinutesButton(\"5 min\")"))
        XCTAssertFalse(onStateBlock.contains("pauseTenMinutesButton(\"10 min\")"))
        XCTAssertFalse(widget.contains("AuthenticatedPauseLavaProtectionFiveMinutesIntent"))
        XCTAssertFalse(widget.contains("AuthenticatedPauseLavaProtectionTenMinutesIntent"))

        let pauseBlock = try sourceBlock(
            in: commandService,
            startingAt: "private static func pauseProtection",
            endingBefore: "private static func resumeProtection"
        )
        let authGuardIndex = try XCTUnwrap(pauseBlock.range(of: "SecurityProtectedSurfaceStorage.isProtected")?.lowerBound)
        let writePauseIndex = try XCTUnwrap(pauseBlock.range(of: "pauseStore.pause(")?.lowerBound)
        XCTAssertLessThan(
            authGuardIndex,
            writePauseIndex,
            "Auth-protected pause denial must be checked before any pause state is written."
        )
        XCTAssertTrue(pauseBlock.contains("pause-denied-auth-required"))
        XCTAssertTrue(pauseBlock.contains("currentActivityOutcome(pauseStore: pauseStore, reason: \"pause-denied-auth-required\")"))
        XCTAssertTrue(commandService.contains("private static func refreshLiveActivitiesFromSharedPauseState(defaults: UserDefaults) async"))
        XCTAssertTrue(commandService.contains("await updateLiveActivities(protectionState: .paused, resumeDate: pauseState.pausedUntil)"))
        XCTAssertTrue(commandService.contains("await updateLiveActivities(protectionState: .on, resumeDate: nil)"))
    }

    func testLiveActivityPauseCommandIsBoundToActiveVPNSession() throws {
        let commandService = try readSource(.lavaProtectionCommandService)
        let appGroup = try readSource(.appGroup)
        let pauseBlock = try sourceBlock(
            in: commandService,
            startingAt: "private static func pauseProtection",
            endingBefore: "private static func resumeProtection"
        )
        let resumeBlock = try sourceBlock(
            in: commandService,
            startingAt: "private static func resumeProtection",
            endingBefore: "private static func refreshLiveActivitiesFromSharedPauseState"
        )
        let refreshBlock = try sourceBlock(
            in: commandService,
            startingAt: "private static func refreshLiveActivitiesFromSharedPauseState",
            endingBefore: "private static func currentActivityOutcome"
        )

        XCTAssertTrue(appGroup.contains("protectionActiveSessionIDDefaultsKey"))
        XCTAssertTrue(appGroup.contains("protectionTemporaryPauseSessionIDDefaultsKey"))

        // Session binding (active-session requirement, stale-session rejection,
        // session-bound pause keys) is enforced by ProtectionPauseStore and
        // covered behaviorally in ProtectionPauseStoreTests; here we pin that the
        // command service routes through the store and denies before writing.
        let sessionGuardIndex = try XCTUnwrap(pauseBlock.range(of: "sessionStore.activeSessionID()")?.lowerBound)
        let writePauseIndex = try XCTUnwrap(pauseBlock.range(of: "pauseStore.pause(")?.lowerBound)
        XCTAssertLessThan(
            sessionGuardIndex,
            writePauseIndex,
            "A Live Activity pause command must not write pause state when no active VPN session exists."
        )
        XCTAssertTrue(pauseBlock.contains("pause-denied-no-active-session"))
        XCTAssertTrue(pauseBlock.contains("pauseStore.pause(for: duration, requestedSessionID: sessionID, commandID: commandID)"))
        XCTAssertTrue(resumeBlock.contains("pauseStore.resume(requestedSessionID: sessionID, commandID: commandID)"))
        XCTAssertTrue(refreshBlock.contains("pauseStore.currentPauseState()"))
    }

    func testLiveActivityWidgetRendersExpiredPauseAsOnWithoutProcessUpdate() throws {
        let widget = try readSource(.lavaSecWidget)
        let expandedViewBlock = try sourceBlock(
            in: widget,
            startingAt: "private struct LavaLiveActivityExpandedView: View",
            endingBefore: "private enum LavaLiveActivityStyle"
        )

        XCTAssertTrue(widget.contains("TimelineView(.periodic"))
        XCTAssertTrue(widget.contains("effectiveProtectionState(now: timeline.date)"))
        XCTAssertTrue(try readSource(.lavaActivityAttributes).contains("resumeDate <= now"))
        XCTAssertTrue(try readSource(.lavaActivityAttributes).contains("return .on"))
        XCTAssertTrue(widget.contains("LavaLiveActivityStatusGlyphView(state: context.state"))
        XCTAssertTrue(expandedViewBlock.contains("let protectionState = state.effectiveProtectionState(now: timeline.date)"))
        XCTAssertTrue(expandedViewBlock.contains("switch protectionState"))
        XCTAssertFalse(
            expandedViewBlock.contains("switch state.protectionState"),
            "Expanded Dynamic Island controls should render from the deadline-adjusted state, not stale ActivityKit state."
        )
    }

    func testLiveActivityControllerStartsUpdatesEndsAndPublishesPauseAuthState() throws {
        let controller = try readSource(.lavaLiveActivityController)
        let appViewModel = try readAppViewModelSource()
        // The hub's reconcile reads the three preferences off the Phase D5 controller.
        let customizationController = try readSource(.customizationController)

        XCTAssertTrue(controller.contains("import ActivityKit"))
        XCTAssertTrue(controller.contains("ActivityAuthorizationInfo()"))
        XCTAssertTrue(controller.contains("activityEnablementUpdates"))
        XCTAssertTrue(controller.contains("Activity<LavaActivityAttributes>.request"))
        XCTAssertTrue(controller.contains("ActivityContent(state:"))
        XCTAssertTrue(controller.contains("await activity.update("))
        XCTAssertTrue(controller.contains("await activity.end("))
        XCTAssertTrue(controller.contains("dismissalPolicy: .immediate"))
        XCTAssertTrue(controller.contains("shieldStyle: GuardianShieldStyle"))
        XCTAssertTrue(controller.contains("shieldStyle: shieldStyle"))
        XCTAssertTrue(controller.contains("pauseRequiresAuthentication: Bool"))
        XCTAssertTrue(controller.contains("pauseRequiresAuthentication: pauseRequiresAuthentication"))

        XCTAssertTrue(appViewModel.contains("let liveActivityController: AmbientProtectionPresenter"))
        XCTAssertTrue(appViewModel.contains("liveActivityController = services.ambientProtection"))
        XCTAssertTrue(try readSource(.appPlatformServices).contains("ambientProtection: LavaLiveActivityController()"))
        XCTAssertTrue(appViewModel.contains("reconcileLiveActivity()"))
        XCTAssertTrue(customizationController.contains("hub.reconcileLiveActivity()"))
        XCTAssertTrue(appViewModel.contains("shieldStyle: customization.lavaGuardLook"))
        XCTAssertTrue(appViewModel.contains("performLiveActivityActionRequest(_ request: LavaLiveActivityActionRequest)"))
        XCTAssertTrue(appViewModel.contains("SecurityProtectedSurfaceStorage.isProtected(\n                    .protectionPause"))
        XCTAssertTrue(appViewModel.contains("pauseProtectionTemporarily(for: .fiveMinutes)"))
        XCTAssertTrue(appViewModel.contains("pauseProtectionTemporarily(for: .tenMinutes)"))

        let actionRequestBlock = try sourceBlock(
            in: appViewModel,
            startingAt: "func performLiveActivityActionRequest(_ request: LavaLiveActivityActionRequest)",
            endingBefore: "private func liveActivityProtectionState"
        )
        XCTAssertFalse(actionRequestBlock.contains("turnOffProtection()"))
        // Canary: the negative pins above key on these identifiers - if a rename removes
        // one from the pinned source, those pins pass vacuously. Fail here instead, then
        // re-anchor both sides to the new name.
        XCTAssertTrue(appViewModel.contains("turnOffProtection"))
    }

    func testLiveActivityRefreshRespectsSharedTemporaryPauseBeforePublishingStatus() throws {
        let controller = try readSource(.lavaLiveActivityController)
        let appViewModel = try readAppViewModelSource()

        XCTAssertTrue(controller.contains("private func effectiveProtectionState("))
        XCTAssertTrue(controller.contains("UserDefaults(suiteName: LavaSecAppGroup.identifier)"))
        XCTAssertFalse(
            controller.contains("defaults.synchronize()"),
            "cfprefsd keeps app-group suites coherent across processes; synchronize() on the reconcile path was measured idle churn"
        )
        XCTAssertTrue(
            controller.contains("pauseStore.currentPauseState()"),
            "The controller must read session-bound pause state through ProtectionPauseStore."
        )
        XCTAssertTrue(controller.contains("return .paused"))

        let reconcileBlock = try sourceBlock(
            in: appViewModel,
            startingAt: "func reconcileLiveActivity()",
            endingBefore: "func performLiveActivityActionRequest(_ request: LavaLiveActivityActionRequest)"
        )
        XCTAssertTrue(reconcileBlock.contains("loadTemporaryProtectionPause()"))
        XCTAssertTrue(reconcileBlock.contains("scheduleTemporaryProtectionResume()"))
    }

    func testLiveActivityDoesNotRenderStalePauseWhenProtectionStateIsUnavailable() throws {
        let controller = try readSource(.lavaLiveActivityController)
        let appViewModel = try readAppViewModelSource()

        let liveActivityProtectionStateBlock = try sourceBlock(
            in: appViewModel,
            startingAt: "private func liveActivityProtectionState",
            endingBefore: "func turnOffProtection()"
        )
        let connectedGuardIndex = try XCTUnwrap(
            liveActivityProtectionStateBlock.range(of: "guard vpnStatus == .connected else")?.lowerBound
        )
        let pausedIndex = try XCTUnwrap(
            liveActivityProtectionStateBlock.range(of: "if isProtectionTemporarilyPaused")?.lowerBound
        )
        XCTAssertLessThan(
            connectedGuardIndex,
            pausedIndex,
            "A stale pause timestamp from the app group must not show Resume after reinstall when VPN state is unavailable."
        )

        let controllerReconcileBlock = try sourceBlock(
            in: controller,
            startingAt: "func reconcile(",
            endingBefore: "private func effectiveProtectionState("
        )
        XCTAssertTrue(controllerReconcileBlock.contains("let requestedProtectionState = protectionState"))
        XCTAssertFalse(controllerReconcileBlock.contains("protectionState ?? (activePauseUntil == nil ? nil : .paused)"))

        // UR-25: a system-ended activity (e.g. lifetime cap reached overnight) must not be
        // adopted and updated (a no-op) — only an updatable activity is reused; otherwise a
        // fresh one is requested so the Dynamic Island reappears on the next reconcile.
        XCTAssertFalse(controllerReconcileBlock.contains("currentActivity ?? Activity<LavaActivityAttributes>.activities.first {"))
        XCTAssertTrue(controllerReconcileBlock.contains("currentActivity.flatMap { Self.isAdoptable($0) ? $0 : nil }"))
        XCTAssertTrue(controllerReconcileBlock.contains("Activity<LavaActivityAttributes>.activities.first(where: Self.isAdoptable)"))
        XCTAssertTrue(controllerReconcileBlock.contains("private static func isAdoptable(_ activity: Activity<LavaActivityAttributes>) -> Bool"))
        XCTAssertTrue(controllerReconcileBlock.contains("case .active, .stale:"))
    }

    func testCoordinatorSkipsAPausedUpdateWhosePauseHasVanished() throws {
        // A detached `.paused` Live Activity update must not apply after the pause it announced
        // was resumed / expired / sanity-cap discarded (a backward clock step between pause() and
        // the detached update). The discard mints no revision, so the revision guard alone lets
        // it through — the coordinator must positively re-verify the pause still exists, or a
        // stale `.paused` strands the Dynamic Island paused after the ON reconcile (UX-2, Codex #208).
        let commandService = try readSource(.lavaProtectionCommandService)
        let updateBlock = try sourceBlock(
            in: commandService,
            startingAt: "private static func updateLiveActivitiesIfCurrent(",
            endingBefore: "private static func updateLiveActivities("
        )
        XCTAssertTrue(
            updateBlock.contains("update.protectionState == .paused"),
            "the guard must special-case a .paused update"
        )
        XCTAssertTrue(
            updateBlock.contains("pauseStore.currentPauseState()) == nil"),
            "a .paused update whose pause no longer exists must be skipped, not just gated on revision"
        )
    }

    func testLiveActivityDoesNotExposeURLActionsOrAnUnusedRootMutationPath() throws {
        let rootView = try readSource(.rootView)
        let securityPolicy = try readSource(.securityAccessPolicy)
        let securityController = try readSource(.securityController)
        let actionRequest = try readSource(.lavaLiveActivityActionRequest)

        XCTAssertTrue(securityPolicy.contains("enum SecurityProtectedSurfaceStorage"))
        XCTAssertTrue(securityPolicy.contains("public static let defaultsKeyName = \"securityProtectedSurfaces\""))
        XCTAssertTrue(securityPolicy.contains("case protectionPause"))
        XCTAssertTrue(securityController.contains("SecurityProtectedSurfaceStorage.loadProtectedSurfaces(from: defaults, projectionURL: securityGateProjectionURL)"))
        XCTAssertTrue(securityController.contains("SecurityProtectedSurfaceStorage.saveProtectedSurfaces(protectedSurfaces, to: defaults,\n            projectionURL: securityGateProjectionURL)"))

        XCTAssertFalse(rootView.contains("handleLiveActivityActionURL"))
        XCTAssertFalse(rootView.contains("LavaLiveActivityActionRequest.pendingRequest(from: url)"))
        XCTAssertFalse(rootView.contains("handlePendingLiveActivityActionRequestIfNeeded()"))
        XCTAssertFalse(rootView.contains("private func performLiveActivityActionRequest("))
        XCTAssertFalse(rootView.contains("LavaLiveActivityActionRequest.rotateActionNonce()"))
        XCTAssertFalse(actionRequest.contains("components.scheme = \"lavasecurity\""))
        XCTAssertFalse(actionRequest.contains("components.host = actionHost"))
        XCTAssertFalse(actionRequest.contains("components.path = actionPath"))
        // Canary: the negative pins above key on these identifiers - if a rename removes
        // one from the pinned source, those pins pass vacuously. Fail here instead, then
        // re-anchor both sides to the new name.
        XCTAssertTrue(actionRequest.contains("enum LavaLiveActivityActionRequest"))
    }

    func testWidgetTargetAndDynamicIslandUseMascotExpressionsAndSFGlyphs() throws {
        let project = try readSource(.xcodeProject)
        let widget = try readSource(.lavaSecWidget)
        let sharedMascot = try readSource(.softShieldGuardian)

        XCTAssertTrue(project.contains("LavaSecWidget.appex"))
        XCTAssertTrue(project.contains("LavaSecWidget.swift in Sources"))
        XCTAssertTrue(project.contains("SoftShieldGuardian.swift in Sources"))
        XCTAssertTrue(project.contains("LavaActivityAttributes.swift in Sources"))
        XCTAssertTrue(project.contains("PRODUCT_BUNDLE_IDENTIFIER = com.lavasec.app.widget"))
        XCTAssertTrue(project.contains("PRODUCT_BUNDLE_IDENTIFIER = com.lavasec.dev.qa.widget"))
        // Restored to Xcode's default const-value-protocols list (the project had overridden it with a
        // narrower set that dropped EntityQuery/DynamicOptionsProvider, breaking AppEntity-query metadata
        // export — LAV-100 Phase 4) while preserving the project-added LiveActivityIntent. Still bare
        // names (not the AppIntents.-qualified form asserted-against below).
        XCTAssertTrue(project.contains("SWIFT_EMIT_CONST_VALUE_PROTOCOLS = \"AppIntent LiveActivityIntent EntityQuery AppEntity TransientEntity AppEnum AppShortcutProviding AppShortcutsProvider AnyResolverProviding AppIntentsPackage DynamicOptionsProvider _IntentValueRepresentable _AssistantIntentsProvider _GenerativeFunctionExtractable IntentValueQuery Resolver\""))
        XCTAssertFalse(project.contains("SWIFT_EMIT_CONST_VALUE_PROTOCOLS = \"AppIntents.AppIntent AppIntents.LiveActivityIntent"))

        XCTAssertTrue(sharedMascot.contains("struct SoftShieldGuardian: View"))
        XCTAssertTrue(sharedMascot.contains("GuardianMascotState"))
        XCTAssertTrue(sharedMascot.contains("GuardianMascotAnimationPlan"))
        XCTAssertFalse(widget.contains("app icon"))

        XCTAssertTrue(widget.contains("ActivityConfiguration(for: LavaActivityAttributes.self)"))
        XCTAssertTrue(widget.contains("DynamicIsland"))
        XCTAssertTrue(widget.contains("LavaLiveActivityCompactGuardianView(state: context.state)"))
        XCTAssertTrue(widget.contains("SoftShieldGuardian(\n                size: 22"))
        XCTAssertTrue(widget.contains("minimumFeatureScale: 0.42"))
        XCTAssertTrue(widget.contains("shieldStyle: state.shieldStyle"))
        XCTAssertTrue(sharedMascot.contains("LavaGuardianShieldShape()"))
        XCTAssertFalse(sharedMascot.contains("Image(systemName: \"shield.fill\")"))
        XCTAssertFalse(sharedMascot.contains("private struct GuardianShieldShape: Shape"))
        XCTAssertTrue(sharedMascot.contains("max(3 * minimumFeatureScale, size * 0.038)"))
        XCTAssertTrue(sharedMascot.contains("minimumFeatureScale: CGFloat = 1"))
        XCTAssertTrue(widget.contains("SoftShieldGuardian(\n                    size: 76"))
        XCTAssertTrue(widget.contains("effectiveProtectionState(now: timeline.date)"))
        XCTAssertTrue(widget.contains("protectionState.guardianState"))
        // The compact guardian (compactLeading) now carries a VoiceOver label, like the trailing glyph.
        XCTAssertTrue(widget.contains(".accessibilityLabel(Self.accessibilityLabel(for: protectionState, languageCode: languageCode))"))
        XCTAssertTrue(widget.contains("Image(systemName: statusSymbolName(for: protectionState))"))
        XCTAssertTrue(widget.contains(".font(.system(size: fontSize, weight: .semibold))"))
        XCTAssertFalse(widget.contains(".font(.system(size: fontSize, weight: .bold))"))
        XCTAssertTrue(widget.contains("LavaLiveActivityStatusGlyphView(state: context.state, fontSize: LavaIconSize.control)"))
        XCTAssertTrue(widget.contains("LavaLiveActivityStatusGlyphView(state: context.state, fontSize: LavaIconSize.small)"))
        XCTAssertTrue(widget.contains(".foregroundStyle(state.shieldStyle.dynamicIslandStatusGlyphColor)"))
        XCTAssertFalse(widget.contains("statusGlyphColor(for shieldStyle: GuardianShieldStyle)"))
        XCTAssertTrue(sharedMascot.contains("var dynamicIslandStatusGlyphColor: Color"))
        XCTAssertTrue(sharedMascot.contains("case .original, .fireOpal:"))
        XCTAssertTrue(sharedMascot.contains("case .purpleObsidian:"))
        XCTAssertTrue(sharedMascot.contains("case .obsidian:"))
        XCTAssertTrue(sharedMascot.contains("case .cherryQuartz:"))
        XCTAssertTrue(sharedMascot.contains("case .emerald:"))
        XCTAssertTrue(sharedMascot.contains("lavaOrange"))
        XCTAssertTrue(sharedMascot.contains("purpleObsidianGlyph"))
        XCTAssertTrue(sharedMascot.contains("obsidianGlyph"))
        XCTAssertTrue(sharedMascot.contains("cherryQuartzGlyph"))
        XCTAssertTrue(sharedMascot.contains("emeraldGlyph"))
        XCTAssertTrue(sharedMascot.contains("light: (0.78, 0.32, 0.58)"))
        XCTAssertTrue(sharedMascot.contains("dark: (1.00, 0.82, 0.90)"))
        XCTAssertTrue(sharedMascot.contains("light: (0.16, 0.47, 0.34)"))
        XCTAssertTrue(sharedMascot.contains("dark: (0.45, 0.86, 0.63)"))
        XCTAssertTrue(widget.contains("LavaLiveActivityStyle.lavaGreen"))
        XCTAssertTrue(widget.contains("LavaCoreStrings.localized(\"widget.state.on\", languageCode: languageCode)"))
        XCTAssertTrue(widget.contains("LavaCoreStrings.localized(\"widget.state.paused\", languageCode: languageCode)"))
        XCTAssertTrue(widget.contains(".controlSize(.regular)"))
        XCTAssertTrue(widget.contains(".tint(LavaLiveActivityStyle.lavaGreen)"))
        XCTAssertTrue(widget.contains("static let expandedMascotContentSpacing: CGFloat = 12"))
        XCTAssertTrue(widget.contains("static let expandedActionButtonSpacing: CGFloat = 12"))
        XCTAssertTrue(widget.contains("static let expandedActionFontSize: CGFloat = 16"))
        XCTAssertTrue(widget.contains("static let expandedActionSymbolFontSize: CGFloat = 15"))
        XCTAssertTrue(widget.contains("static let expandedActionLabelSpacing: CGFloat = 8"))
        XCTAssertTrue(widget.contains("HStack(alignment: .center, spacing: LavaLiveActivityStyle.expandedMascotContentSpacing)"))
        // The two actions sit side by side in a two-up HStack (pause/resume + restart).
        XCTAssertTrue(widget.contains("HStack(spacing: LavaLiveActivityStyle.expandedActionButtonSpacing)"))
        XCTAssertTrue(widget.contains("HStack(spacing: LavaLiveActivityStyle.expandedActionLabelSpacing)"))
        // Both action labels flex to fill their half of the row rather than pinning
        // to a fixed width; the old fixed-width button constants were removed.
        XCTAssertFalse(widget.contains("expandedResumeButtonWidth"))
        XCTAssertFalse(widget.contains("expandedActionButtonWidth"))
        XCTAssertTrue(widget.contains(".frame(maxWidth: .infinity)"))
        XCTAssertTrue(widget.contains(".buttonBorderShape(.roundedRectangle(radius: LavaLiveActivityStyle.expandedActionButtonCornerRadius))"))
        XCTAssertEqual(
            widget.components(separatedBy: "size: LavaLiveActivityStyle.expandedActionFontSize").count - 1,
            3
        )
        XCTAssertTrue(widget.contains(".activitySystemActionForegroundColor(LavaLiveActivityStyle.lavaGreen)"))
        XCTAssertTrue(widget.contains(".activityBackgroundTint(LavaLiveActivityStyle.lockScreenBackgroundTint)"))
        XCTAssertTrue(widget.contains(".keylineTint(context.state.shieldStyle.dynamicIslandStatusGlyphColor.opacity(0.55))"))
        XCTAssertTrue(widget.contains("static let lockScreenBackgroundTint = Color("))
        XCTAssertFalse(widget.contains("secondarySystemGroupedBackground"))
        XCTAssertFalse(widget.contains("Label {"))
        XCTAssertTrue(widget.contains("Image(systemName: \"pause.fill\")"))
        XCTAssertTrue(widget.contains("size: LavaLiveActivityStyle.expandedActionSymbolFontSize"))
        XCTAssertTrue(widget.contains(".padding(.horizontal, 8)"))
        XCTAssertTrue(widget.contains(".padding(.vertical, 4)"))
        XCTAssertFalse(widget.contains(".padding(.horizontal, 14)"))
        XCTAssertFalse(widget.contains(".padding(.vertical, 8)"))
        XCTAssertFalse(widget.contains(".frame(minWidth: 108, minHeight: 36)"))
        XCTAssertFalse(widget.contains(".buttonStyle(.plain)"))
        XCTAssertFalse(widget.contains("LavaLiveActivityStyle.buttonFill"))
        XCTAssertFalse(widget.contains("LavaLiveActivityStyle.buttonForeground"))
        XCTAssertFalse(widget.contains("Text(\"Pause for\")"))
        // A single configured-length Pause button replaces the fixed 5/10-min pair.
        XCTAssertFalse(widget.contains("pauseFiveMinutesButton(\"5 min\")"))
        XCTAssertFalse(widget.contains("pauseTenMinutesButton(\"10 min\")"))
        XCTAssertTrue(widget.contains("title: pauseButtonTitle(forMinutes: state.pauseMinutes, languageCode: languageCode)"))
        XCTAssertTrue(widget.contains("accessibilityLabel: pauseButtonAccessibilityLabel(forMinutes: state.pauseMinutes, languageCode: languageCode)"))
        // Visible label draws the duration-only SHORT key (ja value carries its load-bearing
        // space — see the ja catalog and LavaCoreStringsTests); the full pause-for-minutes
        // phrase rides the separate accessibility label so VoiceOver names the action
        // (Codex on #437). Rationale on pauseButtonTitle / pauseButtonAccessibilityLabel.
        XCTAssertTrue(widget.contains("LavaCoreStrings.localizedFormat(\"widget.action.pauseForMinutesShort\", languageCode: languageCode, minutes)"))
        XCTAssertTrue(widget.contains("LavaCoreStrings.localizedFormat(\"widget.action.pauseForMinutes\", languageCode: languageCode, minutes)"))
        XCTAssertTrue(widget.contains("Button(intent: ResumeLavaProtectionIntent())"))
        XCTAssertTrue(widget.contains("if !state.pauseRequiresAuthentication"))
        XCTAssertTrue(widget.contains("Button(intent: PauseLavaProtectionIntent(activityID: activityID))"))
        XCTAssertFalse(widget.contains("Button(intent: AuthenticatedPauseLavaProtectionFiveMinutesIntent())"))
        XCTAssertFalse(widget.contains("Button(intent: PauseLavaProtectionFiveMinutesIntent())"))
        XCTAssertFalse(widget.contains("Button(intent: AuthenticatedPauseLavaProtectionTenMinutesIntent())"))
        XCTAssertFalse(widget.contains("Button(intent: PauseLavaProtectionTenMinutesIntent())"))
        XCTAssertFalse(widget.contains("Link(destination: url)"))
        XCTAssertFalse(widget.contains("LavaLiveActivityActionRequest.actionURL"))
        XCTAssertFalse(widget.contains("Button(\"Turn off\""))
        // No canary for the `private struct GuardianShieldShape: Shape` pin: that is the
        // OLD pre-shared type name (the live shared type is LavaGuardianShieldShape, which
        // contains it as a substring), so it is a REMOVAL pin - the name must stay dead.
        XCTAssertTrue(project.contains("LavaLiveActivityActionRequest"))
    }

    func testLiveActivityPrivacyRedactionKeepsOnlyMascotShieldVisible() throws {
        let widget = try readSource(.lavaSecWidget)
        let sharedMascot = try readSource(.softShieldGuardian)

        XCTAssertTrue(sharedMascot.contains("@Environment(\\.redactionReasons) private var redactionReasons"))
        XCTAssertTrue(sharedMascot.contains("maskExpressionWhenPrivacyRedacted: Bool = false"))
        XCTAssertTrue(sharedMascot.contains("keepsShieldVisibleWhenRedacted: Bool = false"))
        XCTAssertTrue(sharedMascot.contains("if shouldShowExpression {\n                face(frame)\n                    .privacySensitive(maskExpressionWhenPrivacyRedacted)\n            }"))
        XCTAssertTrue(sharedMascot.contains("!maskExpressionWhenPrivacyRedacted || redactionReasons.isEmpty"))
        XCTAssertTrue(sharedMascot.contains(".unredacted()"))

        XCTAssertTrue(widget.contains("maskExpressionWhenPrivacyRedacted: true,\n                keepsShieldVisibleWhenRedacted: true"))
        XCTAssertTrue(widget.contains("maskExpressionWhenPrivacyRedacted: true,\n                    keepsShieldVisibleWhenRedacted: true"))
        XCTAssertFalse(widget.contains("Text(expandedTitle(for: protectionState, languageCode: languageCode))\n                        .unredacted()"))
        XCTAssertFalse(widget.contains("liveActivityActionLabel(\"Resume\")\n                                .unredacted()"))
        XCTAssertFalse(widget.contains("pauseActivityActionLabel(title)\n                .unredacted()"))
        // Canary: the negative pins above key on these identifiers - if a rename removes
        // one from the pinned source, those pins pass vacuously. Fail here instead, then
        // re-anchor both sides to the new name.
        XCTAssertTrue(widget.contains("expandedTitle"))
        XCTAssertTrue(widget.contains("protectionState"))
        XCTAssertTrue(widget.contains("liveActivityActionLabel"))
        XCTAssertTrue(widget.contains("pauseActivityActionLabel"))
    }

    func testLiveActivityCommandServiceLogsIntentExecutionForDeviceDebugging() throws {
        let commandService = try readSource(.lavaProtectionCommandService)

        XCTAssertTrue(commandService.contains("LavaSecDeviceDebugLog.append(component: \"live-activity-intent\""))
        XCTAssertTrue(commandService.contains("log(\"perform-begin\""))
        XCTAssertTrue(commandService.contains("log(\"perform-finished\""))
        XCTAssertTrue(commandService.contains("log(\"perform-error\""))
        XCTAssertTrue(commandService.contains("log(\"activity-update-begin\""))
        XCTAssertTrue(commandService.contains("log(\"activity-update-finished\""))
    }

    func testLiveActivityCommandServiceSerializesSharedStateAndDoesNotBlockOnActivityKit() throws {
        let commandService = try readSource(.lavaProtectionCommandService)
        let performBlock = try sourceBlock(
            in: commandService,
            startingAt: "static func perform(",
            endingBefore: "private static func applyCommand"
        )
        let mutationBlock = try sourceBlock(
            in: commandService,
            startingAt: "private static func applyCommand",
            endingBefore: "private static func pauseProtection"
        )

        XCTAssertTrue(commandService.contains("private static let commandCoordinator = LavaProtectionCommandCoordinator()"))
        XCTAssertTrue(commandService.contains("private static let liveActivityUpdateCoordinator = LavaProtectionLiveActivityUpdateCoordinator()"))
        XCTAssertTrue(commandService.contains("private actor LavaProtectionCommandCoordinator"))
        XCTAssertTrue(commandService.contains("private enum LavaProtectionCommandFileLock"))
        XCTAssertTrue(commandService.contains("flock(lockFileDescriptor, LOCK_EX)"))
        XCTAssertTrue(performBlock.contains("try await commandCoordinator.perform(request, now: now, commandID: commandID)"))
        XCTAssertTrue(mutationBlock.contains("try LavaProtectionCommandFileLock.withExclusiveLock"))
        XCTAssertTrue(performBlock.contains("await liveActivityUpdateCoordinator.schedule"))
        XCTAssertFalse(performBlock.contains("await updateLiveActivities("))
        // Canary: the negative pins above key on these identifiers - if a rename removes
        // one from the pinned source, those pins pass vacuously. Fail here instead, then
        // re-anchor both sides to the new name.
        XCTAssertTrue(commandService.contains("updateLiveActivities"))
    }

    func testDynamicIslandReconcilesOnTunnelHealthChangeAndTunnelNudgesForegroundApp() throws {
        let appViewModel = try readAppViewModelSource()
        let tunnel = try readPacketTunnelProviderSource()
        let signal = try readSource(.tunnelHealthSignal)
        let observer = try readSource(.darwinNotificationObserver)

        // Part A: the app reconciles the Live Activity whenever tunnel-health
        // content changes — NEVPNStatus stays `.connected` through a reconnect.
        let refreshHealthBlock = try sourceBlock(
            in: appViewModel,
            startingAt: "func refreshTunnelHealth(force: Bool = false)",
            endingBefore: "static let tunnelHealthFlushMinimumInterval"
        )
        XCTAssertTrue(refreshHealthBlock.contains("let previousHealth = tunnelHealth"))
        XCTAssertTrue(refreshHealthBlock.contains("if snapshot != previousHealth {"))
        XCTAssertTrue(refreshHealthBlock.contains("reconcileLiveActivity()"))

        // Part B: the shared Darwin channel + a notifier the tunnel can post with.
        XCTAssertTrue(signal.contains("enum TunnelHealthSignal"))
        XCTAssertTrue(signal.contains("com.lavasec.protection.tunnel-health-changed"))
        XCTAssertTrue(signal.contains("struct DarwinProtectionSignalNotifier: ProtectionSignalNotifier"))
        XCTAssertTrue(signal.contains("CFNotificationCenterPostNotification"))

        // The tunnel only POSTS the nudge (via the core notifier) when the
        // connectivity-relevant assessment changes; it must never re-add the
        // dormant, deliberately-removed extension-side Darwin observer.
        XCTAssertTrue(tunnel.contains("func signalAppIfConnectivityStateChanged"))
        XCTAssertTrue(tunnel.contains("ProtectionConnectivityPolicy.assessment("))
        XCTAssertTrue(tunnel.contains("connectivitySignalNotifier.postNotification(named: TunnelHealthSignal.darwinNotificationName)"))
        XCTAssertTrue(tunnel.contains("signalAppIfConnectivityStateChanged()"))
        XCTAssertFalse(tunnel.contains("CFNotificationCenterAddObserver"))

        // The foreground app observes the nudge and pulls fresh health over the
        // reliable provider-message channel.
        XCTAssertTrue(observer.contains("CFNotificationCenterAddObserver"))
        XCTAssertTrue(observer.contains("CFNotificationCenterGetDarwinNotifyCenter"))
        XCTAssertTrue(appViewModel.contains("DarwinNotificationObserver("))
        XCTAssertTrue(appViewModel.contains("name: TunnelHealthSignal.darwinNotificationName"))
        XCTAssertTrue(appViewModel.contains("func handleTunnelHealthNudge()"))

        let nudgeBlock = try sourceBlock(
            in: appViewModel,
            startingAt: "func handleTunnelHealthNudge()",
            endingBefore: "func performLiveActivityActionRequest(_ request: LavaLiveActivityActionRequest)"
        )
        XCTAssertTrue(nudgeBlock.contains("await self.requestTunnelHealthFlush()"))
        XCTAssertTrue(nudgeBlock.contains("self.refreshTunnelHealth(force: true)"))
    }

    private struct AppIconFaceMetrics {
        let imageWidth: Int
        let imageHeight: Int
        let faceBounds: CGRect
    }

    private struct AppIconLayerAlphaMetrics {
        let transparentPixelRatio: Double
        let opaquePixelRatio: Double
    }

    private func appIconLayerAlphaMetrics(at url: URL) throws -> AppIconLayerAlphaMetrics {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let width = image.width
        let height = image.height
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        let context = try XCTUnwrap(
            CGContext(
                data: &pixels,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: bitmapInfo
            )
        )

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var transparentPixels = 0
        var opaquePixels = 0
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bytesPerRow + x * bytesPerPixel
                let alpha = pixels[offset + 3]
                if alpha <= 12 {
                    transparentPixels += 1
                } else if alpha >= 200 {
                    opaquePixels += 1
                }
            }
        }

        let totalPixels = Double(width * height)
        return AppIconLayerAlphaMetrics(
            transparentPixelRatio: Double(transparentPixels) / totalPixels,
            opaquePixelRatio: Double(opaquePixels) / totalPixels
        )
    }

    private func appIconFaceMetrics(at url: URL) throws -> AppIconFaceMetrics {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let width = image.width
        let height = image.height
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        let context = try XCTUnwrap(
            CGContext(
                data: &pixels,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: bitmapInfo
            )
        )

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var minX = width
        var minY = height
        var maxX = -1
        var maxY = -1

        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bytesPerRow + x * bytesPerPixel
                let red = pixels[offset]
                let green = pixels[offset + 1]
                let blue = pixels[offset + 2]
                guard red >= 245, green >= 238, blue >= 225 else {
                    continue
                }

                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }

        XCTAssertGreaterThanOrEqual(maxX, minX)
        XCTAssertGreaterThanOrEqual(maxY, minY)

        return AppIconFaceMetrics(
            imageWidth: width,
            imageHeight: height,
            faceBounds: CGRect(
                x: minX,
                y: minY,
                width: maxX - minX + 1,
                height: maxY - minY + 1
            )
        )
    }

    private func rgbSample(
        in pixels: [UInt8],
        bytesPerRow: Int,
        bytesPerPixel: Int,
        x: Int,
        y: Int
    ) -> (red: UInt8, green: UInt8, blue: UInt8) {
        let offset = y * bytesPerRow + x * bytesPerPixel
        return (pixels[offset], pixels[offset + 1], pixels[offset + 2])
    }

    func testLiveActivityStringsResolveThroughTheLanguagePin() throws {
        let widget = try readSource(.lavaSecWidget)
        // The widget process resolves its bundle to the SYSTEM language and never inherits
        // the app's per-app override, so every user-visible string must resolve through the
        // shared LavaNotificationLanguage pin — read PER RENDER inside each TimelineView
        // tick so a stuck-English activity self-heals within ~1 s of the pin becoming
        // readable after first unlock, with no widget-process restart (incident plan
        // Phase 3; the pre-unlock locked suite reads as nil and falls back to ambient).
        // Pair each pin read to its TimelineView surface, not just the global totals: a
        // refactor that hoists a `pinnedCode` read out of its `TimelineView` body (to a
        // computed property or a build-time constant) would keep the counts at 3/3 yet lose
        // the per-tick self-heal — the exact regression this pin exists to catch (OCR follow-up
        // on the 1.2.4 sync). Each rendering view must read the pin AFTER opening its periodic
        // TimelineView.
        let renderViews = [
            ("private struct LavaLiveActivityCompactGuardianView: View {", "private struct LavaLiveActivityStatusGlyphView"),
            ("private struct LavaLiveActivityStatusGlyphView: View {", "private struct LavaLiveActivityLockScreenView"),
            ("private struct LavaLiveActivityExpandedView: View {", "private enum LavaLiveActivityStyle"),
        ]
        for (start, end) in renderViews {
            let viewBlock = try sourceBlock(in: widget, startingAt: start, endingBefore: end)
            let timelineIdx = try XCTUnwrap(
                viewBlock.range(of: "TimelineView(.periodic")?.lowerBound,
                "\(start) must render on a periodic TimelineView."
            )
            let pinIdx = try XCTUnwrap(
                viewBlock.range(of: "LavaNotificationLanguage.pinnedCode(in: LavaSecAppGroup.sharedDefaults)")?.lowerBound,
                "\(start) must read the language pin per render."
            )
            XCTAssertLessThan(timelineIdx, pinIdx,
                              "The per-render pin read must sit INSIDE the TimelineView body (after it opens), not hoisted above it.")
        }
        // Global totals still move together: exactly three surfaces, three per-render reads.
        XCTAssertEqual(
            sourceOccurrenceCount(
                of: "LavaNotificationLanguage.pinnedCode(in: LavaSecAppGroup.sharedDefaults)",
                in: widget
            ),
            3,
            "Each of the three TimelineView-rendering views must read the pin per tick."
        )
        XCTAssertEqual(
            sourceOccurrenceCount(of: "TimelineView(.periodic", in: widget), 3,
            "A new TimelineView surface must adopt its own per-render pin read — keep these counts moving together."
        )
        // Every localized call must carry the pin: 14 plain lookups + the one format call.
        XCTAssertEqual(
            sourceOccurrenceCount(of: "LavaCoreStrings.localized(\"", in: widget), 14,
            "All plain widget string lookups are accounted for."
        )
        XCTAssertEqual(
            sourceOccurrenceCount(of: "\", languageCode: languageCode)", in: widget), 14,
            "Every plain lookup must pass the per-render pin — an ambient call renders the system language."
        )
        XCTAssertTrue(
            widget.contains("LavaCoreStrings.localizedFormat(\"widget.action.pauseForMinutesShort\", languageCode: languageCode, minutes)"),
            "The visible-title format lookup must pass the per-render pin too."
        )
        XCTAssertTrue(
            widget.contains("LavaCoreStrings.localizedFormat(\"widget.action.pauseForMinutes\", languageCode: languageCode, minutes)"),
            "The accessibility-label format lookup must pass the per-render pin too."
        )
    }
}
