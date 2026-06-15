import CoreGraphics
import ImageIO
import XCTest

final class LavaLiveActivitySourceTests: XCTestCase {
    func testAppIconMascotFaceUsesLargerReadableGeometry() throws {
        let iconURL = try packageRootURL()
            .appendingPathComponent("LavaSecApp/Assets.xcassets/AppIcon.appiconset/AppIcon-1024x1024@1x.png")
        let metrics = try appIconFaceMetrics(at: iconURL)

        XCTAssertEqual(metrics.imageWidth, 1024)
        XCTAssertEqual(metrics.imageHeight, 1024)
        XCTAssertGreaterThanOrEqual(metrics.faceBounds.width, 500)
        XCTAssertGreaterThanOrEqual(metrics.faceBounds.height, 220)
    }

    func testLavaGuardLooksDeclareAlternateAppIcons() throws {
        let attributes = try readSource("Shared/LavaActivityAttributes.swift")
        let appViewModel = try readSource("LavaSecApp/AppViewModel.swift")
        let project = try readSource("LavaSec.xcodeproj/project.pbxproj")
        let iconNames = [
            "AppIconFireOpal",
            "AppIconAmethyst",
            "AppIconObsidian",
            "AppIconCherryQuartz",
            "AppIconEmerald",
            "AppIconKiwiCreme"
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

        XCTAssertTrue(appViewModel.contains("private func syncAppIcon(to look: GuardianShieldStyle)"))
        XCTAssertTrue(appViewModel.contains("UIApplication.shared.supportsAlternateIcons"))
        XCTAssertTrue(appViewModel.contains("UIApplication.shared.alternateIconName"))
        XCTAssertTrue(appViewModel.contains("let targetIconName = updatesAppIconWithLavaGuard ? look.alternateAppIconName : nil"))
        XCTAssertTrue(appViewModel.contains("UIApplication.shared.setAlternateIconName(targetIconName)"))
        XCTAssertTrue(appViewModel.contains("syncAppIcon(to: look)"))

        let alternateIconSetting = "ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES = \"\(iconNames.joined(separator: " "))\";"
        XCTAssertEqual(project.components(separatedBy: alternateIconSetting).count - 1, 3)
        XCTAssertTrue(project.contains("folder.iconcomposer.icon"))

        let appURL = try packageRootURL().appendingPathComponent("LavaSecApp")
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
            "AppIconKiwiCreme"
        ]
        let appURL = try packageRootURL().appendingPathComponent("LavaSecApp")

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

    func testCustomizationSettingsRouteAppearsBelowUpgrade() throws {
        let settings = try readSource("LavaSecApp/SettingsView.swift")
        let routeBlock = try sourceBlock(
            in: settings,
            startingAt: "enum SettingsRoute: Hashable",
            endingBefore: "private enum LavaWebLinks"
        )
        let rootBlock = try sourceBlock(
            in: settings,
            startingAt: "LavaSectionGroup(\"Your Lava\")",
            endingBefore: "LavaSectionGroup(\"Protection Choices\")"
        )

        XCTAssertTrue(routeBlock.contains("case customization"))
        XCTAssertTrue(routeBlock.contains("case .customization:"))
        XCTAssertTrue(routeBlock.contains("return .requires(.appSettings)"))
        XCTAssertTrue(rootBlock.contains("route: .customization"))
        XCTAssertTrue(rootBlock.contains("systemImage: \"slider.horizontal.3\""))
        XCTAssertTrue(rootBlock.contains("title: \"Customization\""))
        XCTAssertTrue(rootBlock.contains("summary: viewModel.customizationSummaryText"))

        let upgradeIndex = try XCTUnwrap(rootBlock.range(of: "title: \"Upgrade\"")?.lowerBound)
        let customizationIndex = try XCTUnwrap(rootBlock.range(of: "title: \"Customization\"")?.lowerBound)
        XCTAssertLessThan(upgradeIndex, customizationIndex)
    }

    func testCustomizationPageUsesApprovedCopyAndControls() throws {
        let settings = try readSource("LavaSecApp/SettingsView.swift")
        let customizationBlock = try sourceBlock(
            in: settings,
            startingAt: "private struct CustomizationSettingsView: View",
            endingBefore: "struct DNSResolverSettingsView: View"
        )

        XCTAssertTrue(customizationBlock.contains("LavaSectionGroup(\"Appearance\")"))
        XCTAssertFalse(customizationBlock.contains("LavaSectionGroup(\"Appearance & Haptics\")"))
        XCTAssertTrue(customizationBlock.contains("Picker(\"Appearance\""))
        XCTAssertTrue(customizationBlock.contains(".pickerStyle(.segmented)"))
        XCTAssertTrue(customizationBlock.contains("ForEach(LavaAppearancePreference.allCases)"))
        XCTAssertTrue(customizationBlock.contains("Text(preference.displayName.lavaLocalized)"))
        XCTAssertFalse(customizationBlock.contains("Toggle(\"Haptic Feedback\""))
        XCTAssertFalse(customizationBlock.contains("private var hapticFeedbackBinding: Binding<Bool>"))
        XCTAssertFalse(customizationBlock.contains("viewModel.configuration.playsHapticFeedback"))
        XCTAssertFalse(customizationBlock.contains("viewModel.setHapticFeedback(isEnabled)"))
        XCTAssertTrue(customizationBlock.contains("LavaSectionGroup(\"Lava Guard\")"))
        XCTAssertTrue(customizationBlock.contains("LavaGuardLookPickerRow("))
        XCTAssertTrue(customizationBlock.contains("look: viewModel.lavaGuardLook"))
        XCTAssertTrue(customizationBlock.contains("availability: viewModel.lavaGuardAvailability(for: viewModel.lavaGuardLook)"))
        XCTAssertTrue(customizationBlock.contains("Keep Lava protecting you to unlock more Guards, or [**Upgrade**](lavasecurity://settings/upgrade) to unlock them all."))
        XCTAssertTrue(customizationBlock.contains("Lava Guard progress requires local logs. [**Review Privacy & Data**](lavasecurity://settings/privacy-data)"))
        XCTAssertTrue(customizationBlock.contains("VStack(alignment: .leading, spacing: 4)"))
        let lavaGuardUnlockNoteIndex = try XCTUnwrap(customizationBlock.range(of: "Keep Lava protecting you to unlock more Guards")?.lowerBound)
        let progressPrivacyIndex = try XCTUnwrap(customizationBlock.range(of: "Lava Guard progress requires local logs")?.lowerBound)
        XCTAssertLessThan(lavaGuardUnlockNoteIndex, progressPrivacyIndex)
        XCTAssertTrue(customizationBlock.contains("if !viewModel.configuration.hasLavaSecurityPlus {"))
        XCTAssertTrue(customizationBlock.contains(".environment(\\.openURL, OpenURLAction"))
        XCTAssertTrue(customizationBlock.contains("showUpgradePage = true"))
        XCTAssertTrue(customizationBlock.contains("@State private var showPrivacyDataPage = false"))
        XCTAssertTrue(customizationBlock.contains("showPrivacyDataPage = true"))
        XCTAssertTrue(customizationBlock.contains(".navigationDestination(isPresented: $showUpgradePage)"))
        XCTAssertTrue(customizationBlock.contains("SettingsRouteDestinationView(route: .upgrade)"))
        XCTAssertTrue(customizationBlock.contains(".navigationDestination(isPresented: $showPrivacyDataPage)"))
        XCTAssertTrue(customizationBlock.contains("SettingsRouteDestinationView(route: .privacyData)"))
        XCTAssertTrue(customizationBlock.contains(".lavaQuietNoteText()"))
        XCTAssertTrue(customizationBlock.contains("LavaPlainCard {\n                    Toggle(\"Match App Icon to Lava Guard\""))
        XCTAssertTrue(customizationBlock.contains("isOn: updatesAppIconBinding"))
        XCTAssertTrue(customizationBlock.contains("viewModel.setUpdatesAppIconWithLavaGuard(isEnabled)"))
        XCTAssertTrue(customizationBlock.contains("DisclosureGroup(isExpanded: $isExpanded)"))
        XCTAssertTrue(customizationBlock.contains("ForEach(GuardianShieldStyle.allCases)"))
        XCTAssertTrue(customizationBlock.contains("viewModel.setLavaGuardLook(look)"))
        XCTAssertTrue(customizationBlock.contains("guard availability.isSelectable else"))
        XCTAssertTrue(customizationBlock.contains("withAnimation(.easeInOut(duration: 0.18))"))
        XCTAssertTrue(customizationBlock.contains("isExpanded = false"))
        XCTAssertTrue(customizationBlock.contains("private struct LavaGuardLookContent: View"))
        XCTAssertTrue(customizationBlock.contains("private struct MaskedLavaGuardIcon: View"))
        XCTAssertTrue(customizationBlock.contains("private enum LavaGuardLookRowMetrics"))
        XCTAssertTrue(customizationBlock.contains(".frame(width: LavaGuardLookRowMetrics.mascotFrameSize, height: LavaGuardLookRowMetrics.mascotFrameSize)"))
        XCTAssertTrue(customizationBlock.contains(".frame(minHeight: LavaGuardLookRowMetrics.minRowHeight)"))
        XCTAssertTrue(customizationBlock.contains("static let titleFontSize: CGFloat = 16"))
        XCTAssertTrue(customizationBlock.contains("static let subtitleFontSize: CGFloat = 15"))
        XCTAssertTrue(customizationBlock.contains("static let selectedCornerRadius: CGFloat = 10"))
        XCTAssertTrue(customizationBlock.contains("static let selectedHighlightOpacity: Double = 0.08"))
        XCTAssertTrue(customizationBlock.contains("let contourSize = size * 1.12"))
        XCTAssertTrue(customizationBlock.contains("let availability: LavaGuardAvailability"))
        XCTAssertTrue(customizationBlock.contains("if showsDescription,"))
        XCTAssertTrue(customizationBlock.contains("showsDescription: !availability.isRevealed"))
        XCTAssertTrue(customizationBlock.contains("\"Progress is off in Privacy & Data\""))
        XCTAssertTrue(customizationBlock.contains("guard showsProgressDetail else"))
        XCTAssertTrue(customizationBlock.contains("\"Currently at: \\(currentDays) days\""))
        XCTAssertFalse(customizationBlock.contains("\"Current progress: \\(currentDays) days\""))
        XCTAssertFalse(customizationBlock.contains("\"\\(currentDays)/\\(progress.requiredUsageDays) days - \\(remainingText) to unlock\""))
        XCTAssertTrue(customizationBlock.contains("MaskedLavaGuardIcon(size: LavaGuardLookRowMetrics.mascotSize)"))
        XCTAssertTrue(customizationBlock.contains("availability.title(for: look)"))
        XCTAssertTrue(customizationBlock.contains("availability.subtitle(for: look)"))
        XCTAssertTrue(customizationBlock.contains("availability.titleColor(for: look)"))
        XCTAssertTrue(customizationBlock.contains("if showsDescription"))
        XCTAssertTrue(customizationBlock.contains(".multilineTextAlignment(.leading)"))
        XCTAssertTrue(customizationBlock.contains(".layoutPriority(1)"))
        XCTAssertFalse(customizationBlock.contains("let reservesAccessoryColumn: Bool"))
        XCTAssertFalse(customizationBlock.contains("let showsSelectedAccessory: Bool"))
        XCTAssertFalse(customizationBlock.contains("Image(systemName: \"checkmark\")"))
        XCTAssertTrue(customizationBlock.contains(".lineLimit(1)"))
        XCTAssertTrue(customizationBlock.contains(".lineLimit(2)"))
        XCTAssertTrue(customizationBlock.contains(".background(selectedHighlight)"))
        XCTAssertTrue(customizationBlock.contains("private var selectedHighlight: some View"))
        XCTAssertTrue(customizationBlock.contains("look.dynamicIslandStatusGlyphColor.opacity(LavaGuardLookRowMetrics.selectedHighlightOpacity)"))
        XCTAssertFalse(customizationBlock.contains(".padding(.horizontal, -LavaGuardLookRowMetrics"))
        XCTAssertTrue(customizationBlock.contains(".accessibilityAddTraits(isSelected ? .isSelected : [])"))
        XCTAssertTrue(customizationBlock.contains("\"A Lava a day keeps bad domains away.\""))
        XCTAssertTrue(customizationBlock.contains("\"Always check the link first.\""))
        XCTAssertTrue(customizationBlock.contains("\"Block it once. Browse in peace.\""))
        XCTAssertTrue(customizationBlock.contains("\"Sign in where you meant to sign in.\""))
        XCTAssertTrue(customizationBlock.contains("\"Giveaways should not ask for secrets.\""))
        XCTAssertTrue(customizationBlock.contains("\"Make me your web-surfing buddy!\""))
        XCTAssertFalse(customizationBlock.contains("LavaGuardLookContent(look: look).equatable()"))
        XCTAssertFalse(customizationBlock.contains("transaction.animation = nil"))
        XCTAssertFalse(customizationBlock.contains("isExpanded.toggle()"))
        XCTAssertFalse(customizationBlock.contains("Image(systemName: \"chevron.down\")"))
        XCTAssertFalse(customizationBlock.contains(".overlay(alignment: .leading)"))
        XCTAssertFalse(customizationBlock.contains("Capsule()"))
        XCTAssertFalse(customizationBlock.contains("Image(systemName: isSelected ? \"checkmark.circle.fill\" : \"circle\")"))
        XCTAssertFalse(customizationBlock.contains("Picker(\"Lava Guard looks\""))
        XCTAssertTrue(customizationBlock.contains("if viewModel.canOfferLiveActivities"))
        XCTAssertTrue(customizationBlock.contains("LavaSectionGroup(\"Live Activities\")"))
        XCTAssertTrue(customizationBlock.contains("Toggle(\"Use Live Activities\""))
        XCTAssertTrue(customizationBlock.contains("viewModel.setUsesLiveActivities(isEnabled)"))
        XCTAssertTrue(customizationBlock.contains("Shows Lava status on the Lock Screen and Dynamic Island when available."))
        XCTAssertTrue(customizationBlock.contains("LavaSectionGroup(\"Language\")"))
        let appearanceIndex = try XCTUnwrap(customizationBlock.range(of: "LavaSectionGroup(\"Appearance\")")?.lowerBound)
        let liveActivitiesIndex = try XCTUnwrap(customizationBlock.range(of: "LavaSectionGroup(\"Live Activities\")")?.lowerBound)
        XCTAssertLessThan(appearanceIndex, liveActivitiesIndex)

        let guardPickerIndex = try XCTUnwrap(customizationBlock.range(of: "LavaGuardLookPickerRow(")?.lowerBound)
        let unlockNoteIndex = try XCTUnwrap(customizationBlock.range(of: "Keep Lava protecting you to unlock more Guards")?.lowerBound)
        let matchIconIndex = try XCTUnwrap(customizationBlock.range(of: "Toggle(\"Match App Icon to Lava Guard\"")?.lowerBound)
        let paidGateIndex = try XCTUnwrap(customizationBlock.range(of: "if !viewModel.configuration.hasLavaSecurityPlus {")?.lowerBound)
        XCTAssertLessThan(guardPickerIndex, matchIconIndex)
        XCTAssertLessThan(matchIconIndex, paidGateIndex)
        XCTAssertLessThan(paidGateIndex, unlockNoteIndex)
        XCTAssertTrue(customizationBlock.contains("SettingsSystemSettingsRow(title: \"Change in iOS Settings\")"))
        let languageIndex = try XCTUnwrap(customizationBlock.range(of: "LavaSectionGroup(\"Language\")")?.lowerBound)
        let lavaGuardIndex = try XCTUnwrap(customizationBlock.range(of: "LavaSectionGroup(\"Lava Guard\")")?.lowerBound)
        XCTAssertLessThan(languageIndex, lavaGuardIndex)
        XCTAssertFalse(customizationBlock.contains("systemImage: \"globe\""))
        XCTAssertFalse(customizationBlock.contains("SettingsSystemSettingsRow(title: \"Open iOS Settings\")"))
        XCTAssertFalse(customizationBlock.contains("summary: \"Open iOS Settings\""))
        XCTAssertFalse(customizationBlock.contains("Opens iOS Settings > Lava Security > Language."))
        XCTAssertFalse(customizationBlock.contains("Turning this on lets Lava request"))
    }

    func testMaskedLavaGuardIconUsesOriginalShieldContour() throws {
        let settings = try readSource("LavaSecApp/SettingsView.swift")
        let sharedMascot = try readSource("Shared/SoftShieldGuardian.swift")
        let maskedIconBlock = try sourceBlock(
            in: settings,
            startingAt: "private struct MaskedLavaGuardIcon: View",
            endingBefore: "private struct LavaGuardLookOptionRow: View"
        )

        XCTAssertTrue(sharedMascot.contains("struct LavaGuardianShieldShape: Shape"))
        XCTAssertFalse(sharedMascot.contains("private struct LavaGuardianShieldShape: Shape"))
        XCTAssertTrue(maskedIconBlock.contains("LavaGuardianShieldShape()"))
        XCTAssertFalse(maskedIconBlock.contains("MaskedLavaGuardShieldShape"))
        XCTAssertTrue(maskedIconBlock.contains("style: StrokeStyle("))
        XCTAssertTrue(maskedIconBlock.contains("dash: [2, 4]"))
        XCTAssertTrue(maskedIconBlock.contains("Text(\"?\")"))
    }

    func testCustomizationLanguageRowRedirectsToIOSSettingsAfterLiveActivities() throws {
        let settings = try readSource("LavaSecApp/SettingsView.swift")
        let customizationBlock = try sourceBlock(
            in: settings,
            startingAt: "private struct CustomizationSettingsView: View",
            endingBefore: "struct DNSResolverSettingsView: View"
        )
        let systemSettingsRowBlock = try sourceBlock(
            in: settings,
            startingAt: "private struct SettingsSystemSettingsRow: View",
            endingBefore: "private struct AccountSettingsView"
        )

        let liveActivitiesIndex = try XCTUnwrap(customizationBlock.range(of: "LavaSectionGroup(\"Live Activities\")")?.lowerBound)
        let languageIndex = try XCTUnwrap(customizationBlock.range(of: "LavaSectionGroup(\"Language\")")?.lowerBound)
        XCTAssertLessThan(liveActivitiesIndex, languageIndex)

        XCTAssertTrue(systemSettingsRowBlock.contains("UIApplication.openSettingsURLString"))
        XCTAssertTrue(systemSettingsRowBlock.contains("UIApplication.shared.open(settingsURL)"))
        XCTAssertTrue(systemSettingsRowBlock.contains("Image(systemName: \"arrow.up.right\")"))
        XCTAssertFalse(customizationBlock.contains("SettingsNavigationRow(\n                        path: $path,\n                        route: .language"))
    }

    func testLiveActivitiesToggleIsGatedToSupportedDeviceClasses() throws {
        let appViewModel = try readSource("LavaSecApp/AppViewModel.swift")
        let controller = try readSource("LavaSecApp/LavaLiveActivityController.swift")
        let settings = try readSource("LavaSecApp/SettingsView.swift")

        XCTAssertTrue(controller.contains("import UIKit"))
        XCTAssertTrue(controller.contains("var canOfferLiveActivities: Bool"))
        XCTAssertTrue(controller.contains("static func canOfferLiveActivities(for userInterfaceIdiom: UIUserInterfaceIdiom) -> Bool"))
        XCTAssertTrue(controller.contains("case .phone, .pad:"))
        XCTAssertTrue(controller.contains("guard canOfferLiveActivities,"))

        XCTAssertTrue(appViewModel.contains("var canOfferLiveActivities: Bool"))
        XCTAssertTrue(appViewModel.contains("liveActivityController.canOfferLiveActivities"))
        XCTAssertTrue(appViewModel.contains("guard canOfferLiveActivities else"))
        XCTAssertTrue(appViewModel.contains("let canEnableLiveActivities = canOfferLiveActivities && isEnabled"))
        XCTAssertTrue(appViewModel.contains("usesLiveActivities = canOfferLiveActivities && persistedUsesLiveActivities"))

        XCTAssertTrue(settings.contains("if viewModel.canOfferLiveActivities"))
    }

    func testAppearanceAndLiveActivityPreferencesPersistInAppGroupDefaults() throws {
        let appViewModel = try readSource("LavaSecApp/AppViewModel.swift")
        let appGroup = try readSource("Shared/AppGroup.swift")
        let rootView = try readSource("LavaSecApp/RootView.swift")
        let persistLookBlock = try sourceBlock(
            in: appViewModel,
            startingAt: "private func persistLavaGuardLook(_ look: GuardianShieldStyle)",
            endingBefore: "private func syncAppIcon(to look: GuardianShieldStyle)"
        )

        XCTAssertTrue(appViewModel.contains("enum LavaAppearancePreference: String, CaseIterable, Identifiable"))
        XCTAssertTrue(appViewModel.contains("case light"))
        XCTAssertTrue(appViewModel.contains("case dark"))
        XCTAssertTrue(appViewModel.contains("case system"))
        XCTAssertTrue(appViewModel.contains("@Published private(set) var appearancePreference: LavaAppearancePreference = .system"))
        XCTAssertTrue(appViewModel.contains("@Published private(set) var usesLiveActivities = false"))
        XCTAssertTrue(appViewModel.contains("private let appearancePreferenceDefaultsKey = \"lavasec.customization.appearance\""))
        XCTAssertTrue(appViewModel.contains("private let usesLiveActivitiesDefaultsKey = \"lavasec.customization.liveActivities\""))
        XCTAssertTrue(appViewModel.contains("@Published private(set) var lavaGuardLook: GuardianShieldStyle = .original"))
        XCTAssertTrue(appViewModel.contains("@Published private(set) var lavaGuardProgress = LavaGuardProgress()"))
        XCTAssertTrue(appViewModel.contains("@Published private(set) var updatesAppIconWithLavaGuard = true"))
        XCTAssertTrue(appGroup.contains("customizationLavaGuardLookDefaultsKey = \"lavasec.customization.lavaGuardLook\""))
        XCTAssertTrue(appViewModel.contains("private let lavaGuardLookDefaultsKey = LavaSecAppGroup.customizationLavaGuardLookDefaultsKey"))
        XCTAssertTrue(appViewModel.contains("private let updatesAppIconWithLavaGuardDefaultsKey = \"lavasec.customization.updatesAppIconWithLavaGuard\""))
        XCTAssertTrue(appViewModel.contains("private let lavaGuardProgressDefaultsKey = \"lavasec.customization.lavaGuardProgress\""))
        XCTAssertTrue(appViewModel.contains("defaults.set(preference.rawValue, forKey: appearancePreferenceDefaultsKey)"))
        XCTAssertTrue(appViewModel.contains("private func persistLavaGuardLook(_ look: GuardianShieldStyle)"))
        XCTAssertTrue(persistLookBlock.contains("defaults.set(look.rawValue, forKey: lavaGuardLookDefaultsKey)"))
        XCTAssertTrue(persistLookBlock.contains("appGroupDefaults.set(look.rawValue, forKey: lavaGuardLookDefaultsKey)"))
        XCTAssertFalse(persistLookBlock.contains("appGroupDefaults.synchronize()"))
        XCTAssertTrue(appViewModel.contains("persistLavaGuardLook(look)"))
        XCTAssertTrue(appViewModel.contains("func setLavaGuardLook(_ look: GuardianShieldStyle)"))
        XCTAssertTrue(appViewModel.contains("guard isLavaGuardLookSelectable(look) else"))
        XCTAssertTrue(appViewModel.contains("func lavaGuardAvailability(for look: GuardianShieldStyle) -> LavaGuardAvailability"))
        XCTAssertTrue(appViewModel.contains("LavaGuardAvailabilityPolicy.isAvailable("))
        XCTAssertTrue(appViewModel.contains("let showsProgressDetail = look.lavaGuardID == nextLavaGuardProgressDetailGuardID"))
        XCTAssertTrue(appViewModel.contains("private var nextLavaGuardProgressDetailGuardID: String?"))
        XCTAssertTrue(appViewModel.contains("for goal in LavaGuardProgressPolicy.unlockGoals"))
        XCTAssertTrue(appViewModel.contains("func setUpdatesAppIconWithLavaGuard(_ isEnabled: Bool)"))
        XCTAssertTrue(appViewModel.contains("defaults.set(isEnabled, forKey: updatesAppIconWithLavaGuardDefaultsKey)"))
        XCTAssertTrue(appViewModel.contains("syncAppIcon(to: lavaGuardLook)"))
        XCTAssertTrue(appViewModel.contains("reconcileLiveActivity()"))
        XCTAssertTrue(appViewModel.contains("defaults.set(canEnableLiveActivities, forKey: usesLiveActivitiesDefaultsKey)"))
        XCTAssertTrue(appViewModel.contains("var preferredColorScheme: ColorScheme?"))
        XCTAssertTrue(rootView.contains(".preferredColorScheme(viewModel.preferredColorScheme)"))
    }

    func testMascotShieldStyleAddsNamedLooksWithoutDuplicatingEmotions() throws {
        let sharedMascot = try readSource("Shared/SoftShieldGuardian.swift")
        let attributes = try readSource("Shared/LavaActivityAttributes.swift")
        let rootView = try readSource("LavaSecApp/RootView.swift")
        let guardView = try readSource("LavaSecApp/GuardView.swift")
        let settings = try readSource("LavaSecApp/SettingsView.swift")

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
        XCTAssertTrue(sharedMascot.contains("ObsidianShieldBody(wakeAmount: frame.shieldWakeAmount, style: shieldStyle)"))
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

        let tabViewBlock = try sourceBlock(
            in: rootView,
            startingAt: "TabView(selection: guardedRootTabSelection)",
            endingBefore: ".tint(LavaStyle.safeGreen)"
        )

        XCTAssertTrue(guardView.contains("SoftShieldGuardian(size: 96, state: guardianState, shieldStyle: viewModel.lavaGuardLook)"))
        XCTAssertTrue(settings.contains("shieldStyle: viewModel.lavaGuardLook"))
        XCTAssertTrue(settings.contains(".foregroundStyle(availability.titleColor(for: look))"))
        XCTAssertTrue(settings.contains("case .cherryQuartz:"))
        XCTAssertTrue(settings.contains("case .emerald:"))
        XCTAssertTrue(settings.contains("\"Giveaways should not ask for secrets.\""))
        XCTAssertTrue(settings.contains("\"Make me your web-surfing buddy!\""))
        XCTAssertTrue(tabViewBlock.contains("Label(\"Guard\", systemImage: \"shield.fill\")"))
        XCTAssertFalse(tabViewBlock.contains("LavaTabGuardianIcon()"))
        XCTAssertFalse(rootView.contains("LavaTabGuardianIcon()"))
        XCTAssertFalse(rootView.contains("private struct LavaTabGuardianIcon: View"))
        XCTAssertFalse(tabViewBlock.contains("shieldStyle: viewModel.lavaGuardLook"))
        XCTAssertFalse(tabViewBlock.contains("@EnvironmentObject private var viewModel: AppViewModel"))
    }

    func testKiwiCremeGuardLookAddsOnlyColorSchemeAndLine() throws {
        let sharedMascot = try readSource("Shared/SoftShieldGuardian.swift")
        let attributes = try readSource("Shared/LavaActivityAttributes.swift")
        let settings = try readSource("LavaSecApp/SettingsView.swift")
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
        XCTAssertTrue(sharedMascot.contains("case .fireOpal, .purpleObsidian, .obsidian, .cherryQuartz, .emerald, .kiwiCreme:"))
        XCTAssertTrue(shieldBodyBlock.contains(".kiwiCreme"))
        XCTAssertFalse(faceBlock.contains("kiwiCreme"))
    }

    func testLiveActivitySharedModelAndActionRequestsUseAppGroupCommandPath() throws {
        let attributes = try readSource("Shared/LavaActivityAttributes.swift")
        let actionRequest = try readSource("Shared/LavaLiveActivityActionRequest.swift")
        let intents = try readSource("Shared/LavaLiveActivityIntents.swift")
        let commandService = try readSource("Shared/LavaProtectionCommandService.swift")

        XCTAssertTrue(attributes.contains("import ActivityKit"))
        XCTAssertTrue(attributes.contains("struct LavaActivityAttributes: ActivityAttributes"))
        XCTAssertTrue(attributes.contains("enum ProtectionState: String, Codable, Hashable, Sendable"))
        XCTAssertTrue(attributes.contains("case on"))
        XCTAssertTrue(attributes.contains("case paused"))
        XCTAssertTrue(attributes.contains("var guardianState: GuardianMascotState"))
        XCTAssertTrue(attributes.contains("var statusSymbolName: String"))
        XCTAssertTrue(attributes.contains("var pauseRequiresAuthentication: Bool"))
        XCTAssertTrue(attributes.contains("var shieldStyle: GuardianShieldStyle"))
        XCTAssertTrue(attributes.contains("decodeIfPresent(GuardianShieldStyle.self, forKey: .shieldStyle) ?? .original"))
        XCTAssertTrue(attributes.contains("\"checkmark\""))
        XCTAssertTrue(attributes.contains("\"pause.fill\""))
        XCTAssertFalse(attributes.contains("\"checkmark.circle.fill\""))
        XCTAssertFalse(attributes.contains("\"pause.circle.fill\""))

        XCTAssertTrue(actionRequest.contains("enum LavaLiveActivityActionRequest: String, Codable, Sendable"))
        XCTAssertTrue(actionRequest.contains("case pauseFiveMinutes = \"pause-5-minutes\""))
        XCTAssertTrue(actionRequest.contains("case pauseTenMinutes = \"pause-10-minutes\""))
        XCTAssertTrue(actionRequest.contains("case pauseFifteenMinutes = \"pause-15-minutes\""))
        XCTAssertTrue(actionRequest.contains("case resume"))
        XCTAssertFalse(actionRequest.contains("case turnOff"))
        XCTAssertFalse(actionRequest.contains("pendingRequestDefaultsKey"))
        XCTAssertFalse(actionRequest.contains("actionNonceDefaultsKey"))
        XCTAssertFalse(actionRequest.contains("static func actionURL"))
        XCTAssertFalse(actionRequest.contains("static func pendingRequest("))

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
        XCTAssertTrue(intents.contains("try await LavaProtectionCommandService.perform(.pauseFiveMinutes)"))
        XCTAssertTrue(intents.contains("try await LavaProtectionCommandService.perform(.pauseTenMinutes)"))
        XCTAssertTrue(intents.contains("try await LavaProtectionCommandService.perform(.resume)"))
        XCTAssertFalse(intents.contains("LavaLiveActivityActionRequest.storePendingRequest"))

        XCTAssertTrue(commandService.contains("enum LavaProtectionCommandService"))
        XCTAssertTrue(commandService.contains("LavaSecAppGroup.sharedDefaults"))
        XCTAssertTrue(
            commandService.contains("ProtectionPauseStore(") && commandService.contains("ProtectionSessionStore("),
            "Pause/resume command state must flow through the LavaSecCore stores, not inline key access."
        )
        XCTAssertTrue(commandService.contains("pauseStore.pause(for: duration, requestedSessionID: sessionID, commandID: commandID)"))
        XCTAssertTrue(commandService.contains("pauseStore.resume(requestedSessionID: sessionID, commandID: commandID)"))
        XCTAssertTrue(
            commandService.contains("SecurityProtectedSurfaceStorage.isProtected(.protectionPause, defaults: defaults)"),
            "Auth-protected pause denial must stay enforced in the command service."
        )
        XCTAssertFalse(
            commandService.contains("CFNotificationCenterPostNotification"),
            "Pause/resume no longer post a Darwin signal; the app delivers pause via the reload-protection-pause provider message."
        )
        XCTAssertFalse(commandService.contains("passThroughPreparedSnapshot"))
        XCTAssertFalse(commandService.contains("PreparedFilterSnapshotIdentity.make(configuration: passThroughConfiguration, catalog: nil)"))
        XCTAssertTrue(commandService.contains("Activity<LavaActivityAttributes>.activities"))
        XCTAssertTrue(commandService.contains("private static func persistedShieldStyle(defaults: UserDefaults) -> GuardianShieldStyle"))
        XCTAssertTrue(commandService.contains("LavaSecAppGroup.customizationLavaGuardLookDefaultsKey"))
        XCTAssertTrue(commandService.contains("shieldStyle: persistedShieldStyle(defaults: defaults)"))
    }

    func testReconnectStateSurfacesTriangleGlyphAndReconnectButton() throws {
        let attributes = try readSource("Shared/LavaActivityAttributes.swift")
        let widget = try readSource("LavaSecWidget/LavaSecWidget.swift")
        let intents = try readSource("Shared/LavaLiveActivityIntents.swift")
        let commandService = try readSource("Shared/LavaProtectionCommandService.swift")
        let appViewModel = try readSource("LavaSecApp/AppViewModel.swift")

        XCTAssertTrue(attributes.contains("case needsReconnect"))
        XCTAssertTrue(attributes.contains("\"exclamationmark.triangle.fill\""))
        XCTAssertTrue(attributes.contains("\"Lava Security needs to reconnect\""))

        XCTAssertTrue(widget.contains("ReconnectLavaProtectionIntent()"))
        XCTAssertTrue(widget.contains("liveActivityActionLabel(\"Reconnect\")"))

        XCTAssertTrue(intents.contains("struct ReconnectLavaProtectionIntent"))
        XCTAssertTrue(intents.contains("LavaProtectionCommandService.perform(.reconnect)"))
        XCTAssertTrue(commandService.contains("private static func performReconnect()"))
        XCTAssertTrue(commandService.contains("manager.connection.startVPNTunnel()"))

        XCTAssertTrue(appViewModel.contains("return .needsReconnect"))
        XCTAssertTrue(appViewModel.contains("case .reconnect:\n            reconnectProtection()"))
    }

    func testNetworkLostAndReconnectingStatesSurfaceDistinctGlyphsWithoutActions() throws {
        let attributes = try readSource("Shared/LavaActivityAttributes.swift")
        let widget = try readSource("LavaSecWidget/LavaSecWidget.swift")
        let appViewModel = try readSource("LavaSecApp/AppViewModel.swift")

        // Both states exist with their own glyph + title (not folded into .on).
        XCTAssertTrue(attributes.contains("case networkUnavailable"))
        XCTAssertTrue(attributes.contains("case reconnecting"))
        XCTAssertTrue(attributes.contains("\"wifi.slash\""))
        XCTAssertTrue(attributes.contains("\"arrow.triangle.2.circlepath\""))
        XCTAssertTrue(attributes.contains("\"Waiting for network\""))
        XCTAssertTrue(attributes.contains("\"Lava Security is reconnecting\""))

        // The connectivity assessment maps to the new states.
        XCTAssertTrue(appViewModel.contains("protectionConnectivityAssessment.severity == .networkUnavailable"))
        XCTAssertTrue(appViewModel.contains("return .networkUnavailable"))
        XCTAssertTrue(appViewModel.contains("protectionConnectivityAssessment.severity == .recovering"))
        XCTAssertTrue(appViewModel.contains("return .reconnecting"))

        // Precedence: a lost network must resolve to .networkUnavailable BEFORE
        // the primaryAction == .reconnect branch, so it never inherits the
        // Reconnect button (reconnecting cannot help with no network path).
        let mappingBlock = try sourceBlock(
            in: appViewModel,
            startingAt: "private var liveActivityProtectionState",
            endingBefore: "func turnOffProtection()"
        )
        let networkUnavailableIndex = try XCTUnwrap(
            mappingBlock.range(of: "return .networkUnavailable")?.lowerBound
        )
        let reconnectActionIndex = try XCTUnwrap(
            mappingBlock.range(of: "primaryAction == .reconnect")?.lowerBound
        )
        XCTAssertLessThan(
            networkUnavailableIndex,
            reconnectActionIndex,
            "Network Lost must be classified before the reconnect-action branch so it never shows a useless Reconnect button."
        )

        // Neither state offers an action button in the expanded Dynamic Island;
        // both recover on their own.
        let expandedActionBlock = try sourceBlock(
            in: widget,
            startingAt: "case .needsReconnect:",
            endingBefore: ".frame(maxWidth: .infinity, alignment: .leading)"
        )
        XCTAssertTrue(expandedActionBlock.contains("case .reconnecting, .networkUnavailable:"))
        XCTAssertTrue(expandedActionBlock.contains("EmptyView()"))

        XCTAssertTrue(widget.contains("\"Waiting for network\""))
        XCTAssertTrue(widget.contains("\"Reconnecting\""))
    }

    func testLiveActivityPauseActionsAreHiddenAndDeniedWhenPauseRequiresAuthentication() throws {
        let widget = try readSource("LavaSecWidget/LavaSecWidget.swift")
        let commandService = try readSource("Shared/LavaProtectionCommandService.swift")

        let onStateBlock = try sourceBlock(
            in: widget,
            startingAt: "if !state.pauseRequiresAuthentication",
            endingBefore: "case .paused:"
        )
        XCTAssertTrue(onStateBlock.contains("if !state.pauseRequiresAuthentication"))
        XCTAssertTrue(onStateBlock.contains("pauseFiveMinutesButton(\"5 min\")"))
        XCTAssertTrue(onStateBlock.contains("pauseTenMinutesButton(\"10 min\")"))
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
        let commandService = try readSource("Shared/LavaProtectionCommandService.swift")
        let appGroup = try readSource("Shared/AppGroup.swift")
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
        let widget = try readSource("LavaSecWidget/LavaSecWidget.swift")
        let expandedViewBlock = try sourceBlock(
            in: widget,
            startingAt: "private struct LavaLiveActivityExpandedView: View",
            endingBefore: "private enum LavaLiveActivityStyle"
        )

        XCTAssertTrue(widget.contains("TimelineView(.periodic"))
        XCTAssertTrue(widget.contains("effectiveProtectionState(now: timeline.date)"))
        XCTAssertTrue(widget.contains("resumeDate <= now"))
        XCTAssertTrue(widget.contains("return .on"))
        XCTAssertTrue(widget.contains("LavaLiveActivityStatusGlyphView(state: context.state"))
        XCTAssertTrue(expandedViewBlock.contains("let protectionState = state.effectiveProtectionState(now: timeline.date)"))
        XCTAssertTrue(expandedViewBlock.contains("switch protectionState"))
        XCTAssertFalse(
            expandedViewBlock.contains("switch state.protectionState"),
            "Expanded Dynamic Island controls should render from the deadline-adjusted state, not stale ActivityKit state."
        )
    }

    func testLiveActivityControllerStartsUpdatesEndsAndPublishesPauseAuthState() throws {
        let controller = try readSource("LavaSecApp/LavaLiveActivityController.swift")
        let appViewModel = try readSource("LavaSecApp/AppViewModel.swift")

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

        XCTAssertTrue(appViewModel.contains("private let liveActivityController = LavaLiveActivityController()"))
        XCTAssertTrue(appViewModel.contains("reconcileLiveActivity()"))
        XCTAssertTrue(appViewModel.contains("shieldStyle: lavaGuardLook"))
        XCTAssertTrue(appViewModel.contains("performLiveActivityActionRequest(_ request: LavaLiveActivityActionRequest)"))
        XCTAssertTrue(appViewModel.contains("SecurityProtectedSurfaceStorage.isProtected(\n                    .protectionPause"))
        XCTAssertTrue(appViewModel.contains("pauseProtectionTemporarily(for: .fiveMinutes)"))
        XCTAssertTrue(appViewModel.contains("pauseProtectionTemporarily(for: .tenMinutes)"))

        let actionRequestBlock = try sourceBlock(
            in: appViewModel,
            startingAt: "func performLiveActivityActionRequest(_ request: LavaLiveActivityActionRequest)",
            endingBefore: "private var liveActivityProtectionState"
        )
        XCTAssertFalse(actionRequestBlock.contains("turnOffProtection()"))
    }

    func testLiveActivityRefreshRespectsSharedTemporaryPauseBeforePublishingStatus() throws {
        let controller = try readSource("LavaSecApp/LavaLiveActivityController.swift")
        let appViewModel = try readSource("LavaSecApp/AppViewModel.swift")

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
        let controller = try readSource("LavaSecApp/LavaLiveActivityController.swift")
        let appViewModel = try readSource("LavaSecApp/AppViewModel.swift")

        let liveActivityProtectionStateBlock = try sourceBlock(
            in: appViewModel,
            startingAt: "private var liveActivityProtectionState",
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
    }

    func testLiveActivityDoesNotExposeURLActionsAndFallbackResumeSkipsAuthentication() throws {
        let rootView = try readSource("LavaSecApp/RootView.swift")
        let securityPolicy = try readSource("Sources/LavaSecCore/SecurityAccessPolicy.swift")
        let securityController = try readSource("LavaSecApp/SecurityController.swift")
        let actionRequest = try readSource("Shared/LavaLiveActivityActionRequest.swift")

        XCTAssertTrue(securityPolicy.contains("enum SecurityProtectedSurfaceStorage"))
        XCTAssertTrue(securityPolicy.contains("public static let defaultsKey = \"securityProtectedSurfaces\""))
        XCTAssertTrue(securityPolicy.contains("case protectionPause"))
        XCTAssertTrue(securityController.contains("SecurityProtectedSurfaceStorage.loadProtectedSurfaces(from: defaults)"))
        XCTAssertTrue(securityController.contains("SecurityProtectedSurfaceStorage.saveProtectedSurfaces(protectedSurfaces, to: defaults)"))

        XCTAssertFalse(rootView.contains("handleLiveActivityActionURL"))
        XCTAssertFalse(rootView.contains("LavaLiveActivityActionRequest.pendingRequest(from: url)"))
        XCTAssertFalse(rootView.contains("handlePendingLiveActivityActionRequestIfNeeded()"))
        XCTAssertTrue(rootView.contains("if request == .resume || request == .reconnect {\n                viewModel.performLiveActivityActionRequest(request)"))
        XCTAssertTrue(rootView.contains("security.requireFreshAuthentication(\n                for: .protectionPause"))
        XCTAssertTrue(rootView.contains("viewModel.performLiveActivityActionRequest(request)"))
        XCTAssertFalse(rootView.contains("LavaLiveActivityActionRequest.rotateActionNonce()"))
        XCTAssertFalse(actionRequest.contains("components.scheme = \"lavasecurity\""))
        XCTAssertFalse(actionRequest.contains("components.host = actionHost"))
        XCTAssertFalse(actionRequest.contains("components.path = actionPath"))
    }

    func testWidgetTargetAndDynamicIslandUseMascotExpressionsAndSFGlyphs() throws {
        let project = try readSource("LavaSec.xcodeproj/project.pbxproj")
        let widget = try readSource("LavaSecWidget/LavaSecWidget.swift")
        let sharedMascot = try readSource("Shared/SoftShieldGuardian.swift")

        XCTAssertTrue(project.contains("LavaSecWidget.appex"))
        XCTAssertTrue(project.contains("LavaSecWidget.swift in Sources"))
        XCTAssertTrue(project.contains("SoftShieldGuardian.swift in Sources"))
        XCTAssertTrue(project.contains("LavaActivityAttributes.swift in Sources"))
        XCTAssertTrue(project.contains("PRODUCT_BUNDLE_IDENTIFIER = com.lavasec.app.widget"))
        XCTAssertTrue(project.contains("PRODUCT_BUNDLE_IDENTIFIER = com.lavasec.dev.qa.widget"))
        XCTAssertTrue(project.contains("SWIFT_EMIT_CONST_VALUE_PROTOCOLS = \"AppIntent LiveActivityIntent AppEntity AppEnum AppShortcutsProvider\""))
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
        XCTAssertTrue(widget.contains(".accessibilityLabel(Self.accessibilityLabel(for: protectionState))"))
        XCTAssertTrue(widget.contains("Image(systemName: protectionState.statusSymbolName)"))
        XCTAssertTrue(widget.contains(".font(.system(size: fontSize, weight: .semibold))"))
        XCTAssertFalse(widget.contains(".font(.system(size: fontSize, weight: .bold))"))
        XCTAssertTrue(widget.contains("LavaLiveActivityStatusGlyphView(state: context.state, fontSize: 17)"))
        XCTAssertTrue(widget.contains("LavaLiveActivityStatusGlyphView(state: context.state, fontSize: 16)"))
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
        XCTAssertTrue(widget.contains("Lava Security is On"))
        XCTAssertTrue(widget.contains("Lava Security is Paused"))
        XCTAssertTrue(widget.contains(".controlSize(.regular)"))
        XCTAssertTrue(widget.contains(".tint(LavaLiveActivityStyle.lavaGreen)"))
        XCTAssertTrue(widget.contains("static let expandedMascotContentSpacing: CGFloat = 12"))
        XCTAssertTrue(widget.contains("static let expandedActionButtonSpacing: CGFloat = 12"))
        XCTAssertTrue(widget.contains("static let expandedActionButtonWidth: CGFloat = 82"))
        XCTAssertTrue(widget.contains("static var expandedResumeButtonWidth: CGFloat"))
        XCTAssertTrue(widget.contains("expandedActionButtonWidth * 2 + expandedActionButtonSpacing"))
        XCTAssertTrue(widget.contains("static let expandedActionFontSize: CGFloat = 16"))
        XCTAssertTrue(widget.contains("static let expandedActionSymbolFontSize: CGFloat = 15"))
        XCTAssertTrue(widget.contains("static let expandedActionLabelSpacing: CGFloat = 8"))
        XCTAssertTrue(widget.contains("HStack(alignment: .center, spacing: LavaLiveActivityStyle.expandedMascotContentSpacing)"))
        XCTAssertTrue(widget.contains("HStack(spacing: LavaLiveActivityStyle.expandedActionButtonSpacing)"))
        XCTAssertTrue(widget.contains("HStack(spacing: LavaLiveActivityStyle.expandedActionLabelSpacing)"))
        XCTAssertTrue(widget.contains(".frame(width: LavaLiveActivityStyle.expandedActionButtonWidth)"))
        XCTAssertTrue(widget.contains(".frame(width: LavaLiveActivityStyle.expandedResumeButtonWidth)"))
        XCTAssertTrue(widget.contains(".buttonBorderShape(.roundedRectangle(radius: LavaLiveActivityStyle.expandedActionButtonCornerRadius))"))
        XCTAssertEqual(
            widget.components(separatedBy: "size: LavaLiveActivityStyle.expandedActionFontSize").count - 1,
            2
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
        XCTAssertTrue(widget.contains("pauseFiveMinutesButton(\"5 min\")"))
        XCTAssertTrue(widget.contains("pauseTenMinutesButton(\"10 min\")"))
        XCTAssertTrue(widget.contains("Button(intent: ResumeLavaProtectionIntent())"))
        XCTAssertTrue(widget.contains("if !state.pauseRequiresAuthentication"))
        XCTAssertFalse(widget.contains("Button(intent: AuthenticatedPauseLavaProtectionFiveMinutesIntent())"))
        XCTAssertTrue(widget.contains("Button(intent: PauseLavaProtectionFiveMinutesIntent())"))
        XCTAssertFalse(widget.contains("Button(intent: AuthenticatedPauseLavaProtectionTenMinutesIntent())"))
        XCTAssertTrue(widget.contains("Button(intent: PauseLavaProtectionTenMinutesIntent())"))
        XCTAssertFalse(widget.contains("Link(destination: url)"))
        XCTAssertFalse(widget.contains("LavaLiveActivityActionRequest.actionURL"))
        XCTAssertFalse(widget.contains("Button(\"Turn off\""))
    }

    func testLiveActivityPrivacyRedactionKeepsOnlyMascotShieldVisible() throws {
        let widget = try readSource("LavaSecWidget/LavaSecWidget.swift")
        let sharedMascot = try readSource("Shared/SoftShieldGuardian.swift")

        XCTAssertTrue(sharedMascot.contains("@Environment(\\.redactionReasons) private var redactionReasons"))
        XCTAssertTrue(sharedMascot.contains("maskExpressionWhenPrivacyRedacted: Bool = false"))
        XCTAssertTrue(sharedMascot.contains("keepsShieldVisibleWhenRedacted: Bool = false"))
        XCTAssertTrue(sharedMascot.contains("if shouldShowExpression {\n                face(frame)\n                    .privacySensitive(maskExpressionWhenPrivacyRedacted)\n            }"))
        XCTAssertTrue(sharedMascot.contains("!maskExpressionWhenPrivacyRedacted || redactionReasons.isEmpty"))
        XCTAssertTrue(sharedMascot.contains(".unredacted()"))

        XCTAssertTrue(widget.contains("maskExpressionWhenPrivacyRedacted: true,\n                keepsShieldVisibleWhenRedacted: true"))
        XCTAssertTrue(widget.contains("maskExpressionWhenPrivacyRedacted: true,\n                    keepsShieldVisibleWhenRedacted: true"))
        XCTAssertFalse(widget.contains("Text(expandedTitle(for: protectionState))\n                        .unredacted()"))
        XCTAssertFalse(widget.contains("liveActivityActionLabel(\"Resume\")\n                                .unredacted()"))
        XCTAssertFalse(widget.contains("pauseActivityActionLabel(title)\n                .unredacted()"))
    }

    func testLiveActivityCommandServiceLogsIntentExecutionForDeviceDebugging() throws {
        let commandService = try readSource("Shared/LavaProtectionCommandService.swift")

        XCTAssertTrue(commandService.contains("LavaSecDeviceDebugLog.append(component: \"live-activity-intent\""))
        XCTAssertTrue(commandService.contains("log(\"perform-begin\""))
        XCTAssertTrue(commandService.contains("log(\"perform-finished\""))
        XCTAssertTrue(commandService.contains("log(\"perform-error\""))
        XCTAssertTrue(commandService.contains("log(\"activity-update-begin\""))
        XCTAssertTrue(commandService.contains("log(\"activity-update-finished\""))
    }

    func testLiveActivityCommandServiceSerializesSharedStateAndDoesNotBlockOnActivityKit() throws {
        let commandService = try readSource("Shared/LavaProtectionCommandService.swift")
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
    }

    private func readSource(_ relativePath: String) throws -> String {
        let sourceURL = try packageRootURL().appendingPathComponent(relativePath)
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }

    private func packageRootURL() throws -> URL {
        let testFileURL = URL(fileURLWithPath: #filePath)
        return testFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
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

    private func sourceBlock(
        in source: String,
        startingAt startMarker: String,
        endingBefore endMarker: String
    ) throws -> String {
        let start = try XCTUnwrap(source.range(of: startMarker)?.lowerBound)
        let suffix = source[start...]
        let end = try XCTUnwrap(suffix.range(of: endMarker)?.lowerBound)
        return String(suffix[..<end])
    }
}
