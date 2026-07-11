import SwiftUI
import UIKit
import LavaSecKit
import LavaSecPresentation

struct SoftShieldGuardian: View {
    let size: CGFloat
    let state: GuardianMascotState
    let animates: Bool
    let blinkTrigger: Int
    let minimumFeatureScale: CGFloat
    let maskExpressionWhenPrivacyRedacted: Bool
    let keepsShieldVisibleWhenRedacted: Bool
    let shieldStyle: GuardianShieldStyle

    @State private var activePlan: GuardianMascotAnimationPlan
    @State private var transitionElapsed: Double

    init(
        size: CGFloat,
        state: GuardianMascotState = .awake,
        animates: Bool = true,
        blinkTrigger: Int = 0,
        minimumFeatureScale: CGFloat = 1,
        maskExpressionWhenPrivacyRedacted: Bool = false,
        keepsShieldVisibleWhenRedacted: Bool = false,
        shieldStyle: GuardianShieldStyle = .original
    ) {
        self.size = size
        self.state = state
        self.animates = animates
        self.blinkTrigger = blinkTrigger
        self.minimumFeatureScale = minimumFeatureScale
        self.maskExpressionWhenPrivacyRedacted = maskExpressionWhenPrivacyRedacted
        self.keepsShieldVisibleWhenRedacted = keepsShieldVisibleWhenRedacted
        self.shieldStyle = shieldStyle

        let initialStartState: GuardianMascotState = state == .waking ? .sleeping : state
        let initialPlan = GuardianMascotAnimationPlan.animation(from: initialStartState, to: state)
        _activePlan = State(initialValue: initialPlan)
        _transitionElapsed = State(initialValue: animates && state == .waking ? 0 : initialPlan.duration)
    }

    var body: some View {
        SoftShieldGuardianContent(
            size: size,
            plan: activePlan,
            elapsed: transitionElapsed,
            minimumFeatureScale: minimumFeatureScale,
            maskExpressionWhenPrivacyRedacted: maskExpressionWhenPrivacyRedacted,
            keepsShieldVisibleWhenRedacted: keepsShieldVisibleWhenRedacted,
            shieldStyle: shieldStyle
        )
        .frame(width: size, height: size)
        .accessibilityLabel(LavaCoreStrings.localized("a11y.shieldGuardian"))
        .onAppear {
            if state == .waking {
                startTransition(from: .sleeping, to: .waking, animated: animates)
            }
        }
        .onChange(of: state) { _, newState in
            guard newState != activePlan.endState else {
                return
            }

            startTransition(from: activePlan.endState, to: newState, animated: animates)
        }
        .onChange(of: blinkTrigger) { _, _ in
            runPlan(GuardianMascotAnimationPlan.blink(on: activePlan.endState), animated: animates)
        }
    }

    private func startTransition(
        from startState: GuardianMascotState,
        to endState: GuardianMascotState,
        animated: Bool
    ) {
        let plan = GuardianMascotAnimationPlan.animation(from: startState, to: endState)
        runPlan(plan, animated: animated)
    }

    private func runPlan(
        _ plan: GuardianMascotAnimationPlan,
        animated: Bool
    ) {
        activePlan = plan
        guard animated else {
            transitionElapsed = plan.duration
            return
        }

        transitionElapsed = 0
        withAnimation(.linear(duration: plan.duration)) {
            transitionElapsed = plan.duration
        }
    }
}

extension GuardianShieldStyle {
    /// Canonical accent for Dynamic Island checkmark and pause glyphs paired with this guard look.
    var dynamicIslandStatusGlyphColor: Color {
        switch self {
        case .original, .fireOpal:
            LavaGuardianStyle.lavaOrange
        case .purpleObsidian:
            LavaGuardianStyle.purpleObsidianGlyph
        case .obsidian:
            LavaGuardianStyle.obsidianGlyph
        case .cherryQuartz:
            LavaGuardianStyle.cherryQuartzGlyph
        case .emerald:
            LavaGuardianStyle.emeraldGlyph
        case .kiwiCreme:
            LavaGuardianStyle.kiwiCremeGlyph
        }
    }
}

private struct SoftShieldGuardianContent: View, Animatable {
    let size: CGFloat
    let plan: GuardianMascotAnimationPlan
    var elapsed: Double
    let minimumFeatureScale: CGFloat
    let maskExpressionWhenPrivacyRedacted: Bool
    let keepsShieldVisibleWhenRedacted: Bool
    let shieldStyle: GuardianShieldStyle

    @Environment(\.redactionReasons) private var redactionReasons

    nonisolated var animatableData: Double {
        get { elapsed }
        set { elapsed = newValue }
    }

    var body: some View {
        let frame = plan.frame(at: elapsed)

        ZStack {
            shield(frame)
            if shouldShowExpression {
                face(frame)
                    .privacySensitive(maskExpressionWhenPrivacyRedacted)
            }
        }
    }

    private var shouldShowExpression: Bool {
        !maskExpressionWhenPrivacyRedacted || redactionReasons.isEmpty
    }

    private var guardianGradient: LinearGradient {
        LinearGradient(
            colors: [LavaGuardianStyle.lavaOrange.opacity(0.82), LavaGuardianStyle.lavaOrange],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    @ViewBuilder
    private func shield(_ frame: GuardianMascotFrame) -> some View {
        if keepsShieldVisibleWhenRedacted {
            shieldBody(frame)
                .unredacted()
        } else {
            shieldBody(frame)
        }
    }

    @ViewBuilder
    private func shieldBody(_ frame: GuardianMascotFrame) -> some View {
        switch shieldStyle {
        case .original:
            originalShieldBody(frame)
        case .fireOpal, .purpleObsidian, .obsidian, .cherryQuartz, .emerald, .kiwiCreme:
            obsidianShieldBody(frame)
        }
    }

    private func originalShieldBody(_ frame: GuardianMascotFrame) -> some View {
        ZStack {
            LavaGuardianShieldShape()
                .fill(LavaGuardianStyle.guardianSleepGray)
                .opacity(1 - frame.shieldWakeAmount)

            LavaGuardianShieldShape()
                .fill(guardianGradient)
                .opacity(frame.shieldWakeAmount)
                .shadow(
                    color: LavaGuardianStyle.lavaOrange.opacity(0.18 * frame.glowAmount),
                    radius: 12,
                    x: 0,
                    y: 8
                )
        }
        .scaleEffect(frame.shieldScale)
    }

    private func obsidianShieldBody(_ frame: GuardianMascotFrame) -> some View {
        ObsidianShieldBody(wakeAmount: frame.shieldWakeAmount, style: shieldStyle)
            .shadow(
                color: obsidianGlowColor.opacity(0.18 * frame.glowAmount),
                radius: 12,
                x: 0,
                y: 8
            )
            .scaleEffect(frame.shieldScale)
    }

    private var obsidianGlowColor: Color {
        switch shieldStyle {
        case .purpleObsidian:
            Color(red: 0.62, green: 0.38, blue: 0.95)
        case .obsidian:
            Color(red: 0.50, green: 0.55, blue: 0.54)
        case .cherryQuartz:
            Color(red: 1.00, green: 0.58, blue: 0.78)
        case .emerald:
            Color(red: 0.16, green: 0.47, blue: 0.34)
        case .kiwiCreme:
            LavaGuardianStyle.kiwiCremeSupportBrown
        case .original, .fireOpal:
            LavaGuardianStyle.lavaOrange
        }
    }

    private func face(_ frame: GuardianMascotFrame) -> some View {
        ZStack {
            morphedEyes(frame)

            GuardianMouthShape(curve: frame.mouthCurve)
                .stroke(
                    faceColor,
                    style: StrokeStyle(
                        lineWidth: max(3 * minimumFeatureScale, size * 0.038),
                        lineCap: .round
                    )
                )
                .frame(
                    width: size * (0.48 + CGFloat(frame.gratitudeAmount) * 0.04),
                    height: size * 0.12
                )
                .offset(y: size * 0.11)
        }
    }

    private var faceColor: Color {
        LavaGuardianStyle.guardianFaceLight
    }

    private func morphedEyes(_ frame: GuardianMascotFrame) -> some View {
        let leftEye = eyePose(for: .left, frame: frame)
        let rightEye = eyePose(for: .right, frame: frame)
        let openAmount = CGFloat(max(frame.leftEyeOpenAmount, frame.rightEyeOpenAmount))
        let happyAmount = clampUnit(frame.happyEyeAmount)
        let concernAmount = clampUnit(frame.concernAmount)
        let happyEyeLengthAmount = max(1 - openAmount, clampUnit(happyAmount / 0.85))
        let smileTransitionAmount = happyAmount > 0 ? clampUnit(openAmount + happyAmount) : openAmount
        let happySpacingCompensation = happyAmount > 0 ? happyEyeLengthAmount * 0.066 : 0
        let spacing = size * (0.34 + smileTransitionAmount * 0.09 - happySpacingCompensation - concernAmount * 0.04)

        return HStack(spacing: spacing) {
            guardianEye(leftEye)
            guardianEye(rightEye)
        }
        .offset(y: -size * (0.06 + openAmount * 0.01 - concernAmount * 0.005))
    }

    private func guardianEye(_ pose: GuardianEyePose) -> some View {
        MorphingGuardianEyeShape(
            openAmount: pose.openAmount,
            curveAmount: pose.curveAmount
        )
        .fill(faceColor)
        .frame(width: pose.width, height: pose.height)
        .rotationEffect(pose.rotation)
    }

    private func eyePose(for side: GuardianEyeSide, frame: GuardianMascotFrame) -> GuardianEyePose {
        let rawOpenAmount = side == .left ? frame.leftEyeOpenAmount : frame.rightEyeOpenAmount
        let openAmount = clampUnit(rawOpenAmount)
        let sleepyAmount = clampUnit(frame.sleepyEyeAmount)
        let happyAmount = clampUnit(frame.happyEyeAmount)
        let concernAmount = clampUnit(frame.concernAmount)
        let winkAmount = side == .right ? clampUnit(frame.winkAmount) : 0
        let closedAmount = 1 - openAmount
        let happyLengthenAmount = clampUnit(happyAmount / 0.85)
        let happyBendAmount = clampUnit(happyAmount / 0.92)
        let sleepyCurveAmount = sleepyAmount * max(0, 1 - openAmount * 5.0)
        let winkCurveAmount = winkAmount * max(0, 1 - openAmount * 2.0) * 0.24
        let eyeLengthAmount = max(closedAmount, happyLengthenAmount)
        let renderedOpenAmount = openAmount
        let compactFeatureScale = max(0.72, min(1, minimumFeatureScale))
        let width = size * (0.074 + eyeLengthAmount * 0.066 + concernAmount * 0.014) * compactFeatureScale
        let height = size * (0.064 + renderedOpenAmount * 0.004 + happyAmount * 0.006 - concernAmount * 0.012) * compactFeatureScale
        let curveAmount = Double(happyBendAmount - sleepyCurveAmount - winkCurveAmount)
        let closedTilt = side == .left ? 4 : -4
        let closedTiltRotation = Double(closedTilt) * Double(1 - renderedOpenAmount) * Double(1 - happyAmount * 0.4)
        // Raise the inner corners when concerned so the face reads as gentle, help-seeking worry rather than a stern glare.
        let concernTilt = side == .left ? -5.0 : 5.0
        let rotation = Angle.degrees(closedTiltRotation + concernTilt * Double(concernAmount))

        return GuardianEyePose(
            openAmount: Double(renderedOpenAmount),
            curveAmount: curveAmount,
            width: width,
            height: height,
            rotation: rotation
        )
    }
}

private struct ObsidianShieldBody: View {
    let wakeAmount: Double
    let style: GuardianShieldStyle

    var body: some View {
        ObsidianShieldLayer(palette: ObsidianShieldPalette(wakeAmount: wakeAmount, style: style))
    }
}

private struct ObsidianShieldLayer: View {
    let palette: ObsidianShieldPalette

    var body: some View {
        ZStack {
            LavaGuardianShieldShape()
                .fill(palette.innerGradient)

            ObsidianOuterShell(palette: palette)
        }
        .compositingGroup()
    }
}

private enum ObsidianShieldGeometry {
    static let innerShieldScale: CGFloat = 0.91
}

private struct ObsidianOuterShell: View {
    let palette: ObsidianShieldPalette

    var body: some View {
        ZStack {
            Rectangle()
                .fill(palette.shellGradient)

            LavaGuardianShellFacet(kind: .right)
                .fill(palette.rightFacetColor)

            LavaGuardianShellFacet(kind: .lowerRight)
                .fill(palette.lowerRightFacetColor)

            LavaGuardianShellFacet(kind: .warmSide)
                .fill(palette.warmSideFacetColor)
        }
        .mask {
            LavaGuardianShieldRimShape(innerScale: ObsidianShieldGeometry.innerShieldScale)
                .fill(style: FillStyle(eoFill: true))
        }
    }
}

private struct ObsidianShieldPalette {
    let wakeAmount: Double
    let style: GuardianShieldStyle

    var innerGradient: LinearGradient {
        LinearGradient(
            colors: innerGradientColors,
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    var shellGradient: LinearGradient {
        LinearGradient(
            colors: shellGradientColors,
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    var rightFacetColor: Color {
        color(
            sleeping: ObsidianSleepingPalette.rightFacet,
            awake: colorway.rightFacet
        )
    }

    var lowerRightFacetColor: Color {
        color(
            sleeping: ObsidianSleepingPalette.lowerRightFacet,
            awake: colorway.lowerRightFacet
        )
    }

    var warmSideFacetColor: Color {
        color(
            sleeping: ObsidianSleepingPalette.warmSideFacet,
            awake: colorway.warmSideFacet
        )
    }

    private var innerGradientColors: [Color] {
        [
            color(sleeping: ObsidianSleepingPalette.innerTop, awake: colorway.innerTop),
            color(sleeping: ObsidianSleepingPalette.innerMid, awake: colorway.innerMid),
            color(sleeping: ObsidianSleepingPalette.innerBottom, awake: colorway.innerBottom)
        ]
    }

    private var shellGradientColors: [Color] {
        [
            color(sleeping: ObsidianSleepingPalette.shellTop, awake: colorway.shellTop),
            color(sleeping: ObsidianSleepingPalette.shellMid, awake: colorway.shellMid),
            color(sleeping: ObsidianSleepingPalette.shellDeep, awake: colorway.shellDeep),
            color(sleeping: ObsidianSleepingPalette.shellBottom, awake: colorway.shellBottom)
        ]
    }

    private var colorway: ObsidianShieldColorway {
        ObsidianShieldColorway(style: style)
    }

    private func color(sleeping: LavaGuardianColorStop, awake: LavaGuardianColorStop) -> Color {
        sleeping.color(blendingTo: awake, wakeAmount: wakeAmount)
    }
}

private enum ObsidianSleepingPalette {
    static let innerTop = LavaGuardianColorStop(red: 0.73, green: 0.76, blue: 0.74)
    static let innerMid = LavaGuardianColorStop(red: 0.56, green: 0.60, blue: 0.58)
    static let innerBottom = LavaGuardianColorStop(red: 0.42, green: 0.46, blue: 0.44)
    static let shellTop = LavaGuardianColorStop(red: 0.76, green: 0.79, blue: 0.77)
    static let shellMid = LavaGuardianColorStop(red: 0.58, green: 0.62, blue: 0.60)
    static let shellDeep = LavaGuardianColorStop(red: 0.30, green: 0.33, blue: 0.31)
    static let shellBottom = LavaGuardianColorStop(red: 0.12, green: 0.14, blue: 0.13)
    static let rightFacet = LavaGuardianColorStop(red: 0.28, green: 0.31, blue: 0.30, opacity: 0.82)
    static let lowerRightFacet = LavaGuardianColorStop(red: 0.10, green: 0.12, blue: 0.11, opacity: 0.62)
    static let warmSideFacet = LavaGuardianColorStop(red: 0.47, green: 0.50, blue: 0.48, opacity: 0.72)
}

private enum ObsidianShieldColorway {
    case ember
    case purple
    case neutral
    case cherryQuartz
    case emerald
    case kiwiCreme

    init(style: GuardianShieldStyle) {
        switch style {
        case .purpleObsidian:
            self = .purple
        case .obsidian:
            self = .neutral
        case .cherryQuartz:
            self = .cherryQuartz
        case .emerald:
            self = .emerald
        case .kiwiCreme:
            self = .kiwiCreme
        case .original, .fireOpal:
            self = .ember
        }
    }

    var innerTop: LavaGuardianColorStop {
        switch self {
        case .ember:
            LavaGuardianColorStop(red: 1.00, green: 0.60, blue: 0.40)
        case .purple:
            LavaGuardianColorStop(red: 0.82, green: 0.68, blue: 1.00)
        case .neutral:
            LavaGuardianColorStop(red: 0.70, green: 0.73, blue: 0.72)
        case .cherryQuartz:
            LavaGuardianColorStop(red: 1.00, green: 0.84, blue: 0.92)
        case .emerald:
            LavaGuardianColorStop(red: 0.45, green: 0.86, blue: 0.63)
        case .kiwiCreme:
            LavaGuardianColorStop(red: 1.00, green: 0.98, blue: 0.91)
        }
    }

    var innerMid: LavaGuardianColorStop {
        switch self {
        case .ember:
            LavaGuardianColorStop(red: 1.00, green: 0.35, blue: 0.22)
        case .purple:
            LavaGuardianColorStop(red: 0.56, green: 0.34, blue: 0.88)
        case .neutral:
            LavaGuardianColorStop(red: 0.43, green: 0.46, blue: 0.45)
        case .cherryQuartz:
            LavaGuardianColorStop(red: 1.00, green: 0.62, blue: 0.80)
        case .emerald:
            LavaGuardianColorStop(red: 0.24, green: 0.61, blue: 0.41)
        case .kiwiCreme:
            LavaGuardianColorStop(red: 0.91, green: 0.84, blue: 0.72)
        }
    }

    var innerBottom: LavaGuardianColorStop {
        switch self {
        case .ember:
            LavaGuardianColorStop(red: 0.85, green: 0.27, blue: 0.18)
        case .purple:
            LavaGuardianColorStop(red: 0.35, green: 0.20, blue: 0.58)
        case .neutral:
            LavaGuardianColorStop(red: 0.24, green: 0.26, blue: 0.25)
        case .cherryQuartz:
            LavaGuardianColorStop(red: 0.86, green: 0.32, blue: 0.56)
        case .emerald:
            LavaGuardianColorStop(red: 0.16, green: 0.47, blue: 0.34)
        case .kiwiCreme:
            LavaGuardianColorStop(red: 0.68, green: 0.60, blue: 0.51)
        }
    }

    var shellTop: LavaGuardianColorStop {
        switch self {
        case .ember:
            LavaGuardianColorStop(red: 1.00, green: 0.56, blue: 0.38)
        case .purple:
            LavaGuardianColorStop(red: 0.78, green: 0.62, blue: 1.00)
        case .neutral:
            LavaGuardianColorStop(red: 0.62, green: 0.66, blue: 0.65)
        case .cherryQuartz:
            LavaGuardianColorStop(red: 1.00, green: 0.78, blue: 0.90)
        case .emerald:
            LavaGuardianColorStop(red: 0.55, green: 0.96, blue: 0.72)
        case .kiwiCreme:
            LavaGuardianColorStop(red: 0.99, green: 0.94, blue: 0.84)
        }
    }

    var shellMid: LavaGuardianColorStop {
        switch self {
        case .ember:
            LavaGuardianColorStop(red: 1.00, green: 0.35, blue: 0.22)
        case .purple:
            LavaGuardianColorStop(red: 0.49, green: 0.28, blue: 0.78)
        case .neutral:
            LavaGuardianColorStop(red: 0.38, green: 0.41, blue: 0.40)
        case .cherryQuartz:
            LavaGuardianColorStop(red: 0.96, green: 0.46, blue: 0.70)
        case .emerald:
            LavaGuardianColorStop(red: 0.20, green: 0.56, blue: 0.38)
        case .kiwiCreme:
            LavaGuardianColorStop(red: 0.66, green: 0.58, blue: 0.49)
        }
    }

    var shellDeep: LavaGuardianColorStop {
        switch self {
        case .ember:
            LavaGuardianColorStop(red: 0.29, green: 0.15, blue: 0.13)
        case .purple:
            LavaGuardianColorStop(red: 0.18, green: 0.11, blue: 0.27)
        case .neutral:
            LavaGuardianColorStop(red: 0.17, green: 0.18, blue: 0.18)
        case .cherryQuartz:
            LavaGuardianColorStop(red: 0.28, green: 0.06, blue: 0.16)
        case .emerald:
            LavaGuardianColorStop(red: 0.04, green: 0.18, blue: 0.11)
        case .kiwiCreme:
            LavaGuardianColorStop(red: 0.25, green: 0.22, blue: 0.19)
        }
    }

    var shellBottom: LavaGuardianColorStop {
        switch self {
        case .ember:
            LavaGuardianColorStop(red: 0.05, green: 0.035, blue: 0.03)
        case .purple:
            LavaGuardianColorStop(red: 0.045, green: 0.035, blue: 0.06)
        case .neutral:
            LavaGuardianColorStop(red: 0.055, green: 0.06, blue: 0.06)
        case .cherryQuartz:
            LavaGuardianColorStop(red: 0.06, green: 0.025, blue: 0.055)
        case .emerald:
            LavaGuardianColorStop(red: 0.02, green: 0.06, blue: 0.04)
        case .kiwiCreme:
            LavaGuardianColorStop(red: 0.08, green: 0.07, blue: 0.06)
        }
    }

    var rightFacet: LavaGuardianColorStop {
        switch self {
        case .ember:
            LavaGuardianColorStop(red: 0.23, green: 0.14, blue: 0.12, opacity: 0.82)
        case .purple:
            LavaGuardianColorStop(red: 0.16, green: 0.10, blue: 0.23, opacity: 0.82)
        case .neutral:
            LavaGuardianColorStop(red: 0.18, green: 0.20, blue: 0.20, opacity: 0.82)
        case .cherryQuartz:
            LavaGuardianColorStop(red: 0.22, green: 0.06, blue: 0.14, opacity: 0.82)
        case .emerald:
            LavaGuardianColorStop(red: 0.03, green: 0.16, blue: 0.09, opacity: 0.82)
        case .kiwiCreme:
            LavaGuardianColorStop(red: 0.56, green: 0.50, blue: 0.43, opacity: 0.82)
        }
    }

    var lowerRightFacet: LavaGuardianColorStop {
        switch self {
        case .ember:
            LavaGuardianColorStop(red: 0.05, green: 0.035, blue: 0.03, opacity: 0.62)
        case .purple:
            LavaGuardianColorStop(red: 0.035, green: 0.025, blue: 0.055, opacity: 0.62)
        case .neutral:
            LavaGuardianColorStop(red: 0.055, green: 0.06, blue: 0.06, opacity: 0.62)
        case .cherryQuartz:
            LavaGuardianColorStop(red: 0.06, green: 0.025, blue: 0.055, opacity: 0.62)
        case .emerald:
            LavaGuardianColorStop(red: 0.02, green: 0.06, blue: 0.04, opacity: 0.62)
        case .kiwiCreme:
            LavaGuardianColorStop(red: 0.22, green: 0.19, blue: 0.16, opacity: 0.62)
        }
    }

    var warmSideFacet: LavaGuardianColorStop {
        switch self {
        case .ember:
            LavaGuardianColorStop(red: 0.72, green: 0.28, blue: 0.19, opacity: 0.72)
        case .purple:
            LavaGuardianColorStop(red: 0.55, green: 0.34, blue: 0.82, opacity: 0.72)
        case .neutral:
            LavaGuardianColorStop(red: 0.50, green: 0.54, blue: 0.53, opacity: 0.72)
        case .cherryQuartz:
            LavaGuardianColorStop(red: 0.98, green: 0.42, blue: 0.66, opacity: 0.72)
        case .emerald:
            LavaGuardianColorStop(red: 0.24, green: 0.66, blue: 0.43, opacity: 0.72)
        case .kiwiCreme:
            LavaGuardianColorStop(red: 0.82, green: 0.75, blue: 0.64, opacity: 0.72)
        }
    }
}

private struct LavaGuardianColorStop {
    let red: Double
    let green: Double
    let blue: Double
    var opacity: Double = 1

    func color(blendingTo awake: LavaGuardianColorStop, wakeAmount: Double) -> Color {
        let amount = min(max(wakeAmount, 0), 1)
        return Color(
            red: blend(red, awake.red, amount),
            green: blend(green, awake.green, amount),
            blue: blend(blue, awake.blue, amount),
            opacity: blend(opacity, awake.opacity, amount)
        )
    }

    private func blend(_ sleeping: Double, _ awake: Double, _ amount: Double) -> Double {
        sleeping + (awake - sleeping) * amount
    }
}

struct LavaGuardianShieldShape: Shape {
    var scaleX: CGFloat = 1
    var scaleY: CGFloat = 1

    func path(in rect: CGRect) -> Path {
        LavaGuardianPathMapper(rect: rect, scaleX: scaleX, scaleY: scaleY).path { mapper, path in
            path.move(to: mapper.point(110, 8))
            path.addCurve(
                to: mapper.point(204, 50),
                control1: mapper.point(141, 8),
                control2: mapper.point(193, 31)
            )
            path.addCurve(
                to: mapper.point(200, 187),
                control1: mapper.point(216, 72),
                control2: mapper.point(209, 166)
            )
            path.addCurve(
                to: mapper.point(119, 245),
                control1: mapper.point(189, 211),
                control2: mapper.point(136, 238)
            )
            path.addCurve(
                to: mapper.point(101, 245),
                control1: mapper.point(113, 248),
                control2: mapper.point(107, 248)
            )
            path.addCurve(
                to: mapper.point(20, 187),
                control1: mapper.point(84, 238),
                control2: mapper.point(31, 211)
            )
            path.addCurve(
                to: mapper.point(16, 50),
                control1: mapper.point(11, 166),
                control2: mapper.point(4, 72)
            )
            path.addCurve(
                to: mapper.point(110, 8),
                control1: mapper.point(27, 31),
                control2: mapper.point(79, 8)
            )
            path.closeSubpath()
        }
    }
}

private struct LavaGuardianShieldRimShape: Shape {
    let innerScale: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = LavaGuardianShieldShape().path(in: rect)
        path.addPath(LavaGuardianShieldShape(scaleX: innerScale, scaleY: innerScale).path(in: rect))
        return path
    }
}

private struct LavaGuardianShellFacet: Shape {
    enum Kind {
        case right
        case lowerRight
        case warmSide
    }

    let kind: Kind

    func path(in rect: CGRect) -> Path {
        let mapper = LavaGuardianPathMapper(rect: rect, scaleX: 1, scaleY: 1)
        var path = Path()

        switch kind {
        case .right:
            path.move(to: mapper.point(147, 0))
            path.addLine(to: mapper.point(214, 43))
            path.addLine(to: mapper.point(208, 158))
            path.addLine(to: mapper.point(155, 120))
        case .lowerRight:
            path.move(to: mapper.point(157, 118))
            path.addLine(to: mapper.point(208, 158))
            path.addLine(to: mapper.point(193, 205))
            path.addLine(to: mapper.point(128, 236))
        case .warmSide:
            path.move(to: mapper.point(147, 2))
            path.addLine(to: mapper.point(198, 43))
            path.addLine(to: mapper.point(156, 119))
            path.addLine(to: mapper.point(122, 17))
        }

        path.closeSubpath()
        return path
    }
}

private struct LavaGuardianPathMapper {
    private let rect: CGRect
    private let drawingRect: CGRect
    private let scaleX: CGFloat
    private let scaleY: CGFloat

    init(rect: CGRect, scaleX: CGFloat, scaleY: CGFloat) {
        self.rect = rect
        self.scaleX = scaleX
        self.scaleY = scaleY

        let aspect: CGFloat = 220 / 250
        let width = min(rect.width, rect.height * aspect)
        let height = width / aspect
        self.drawingRect = CGRect(
            x: rect.midX - width / 2,
            y: rect.midY - height / 2,
            width: width,
            height: height
        )
    }

    func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        let normalizedX = x / 220
        let normalizedY = y / 250
        let raw = CGPoint(
            x: drawingRect.minX + normalizedX * drawingRect.width,
            y: drawingRect.minY + normalizedY * drawingRect.height
        )

        return CGPoint(
            x: rect.midX + (raw.x - rect.midX) * scaleX,
            y: rect.midY + (raw.y - rect.midY) * scaleY
        )
    }

    func path(_ build: (LavaGuardianPathMapper, inout Path) -> Void) -> Path {
        var path = Path()
        build(self, &path)
        return path
    }
}

private enum LavaGuardianStyle {
    typealias RGB = (red: CGFloat, green: CGFloat, blue: CGFloat)

    static let lavaOrange = adaptiveColor(
        light: (0.95, 0.34, 0.18),
        dark: (1.00, 0.54, 0.34)
    )
    static let guardianSleepGray = adaptiveColor(
        light: (0.67, 0.71, 0.69),
        dark: (0.36, 0.40, 0.38)
    )
    static let guardianFaceLight = adaptiveColor(
        light: (1.00, 0.98, 0.93),
        dark: (0.94, 0.98, 0.95)
    )
    static let purpleObsidianGlyph = adaptiveColor(
        light: (0.56, 0.34, 0.88),
        dark: (0.82, 0.68, 1.00)
    )
    static let obsidianGlyph = adaptiveColor(
        light: (0.38, 0.41, 0.40),
        dark: (0.70, 0.73, 0.72)
    )
    static let cherryQuartzGlyph = adaptiveColor(
        light: (0.78, 0.32, 0.58),
        dark: (1.00, 0.82, 0.90)
    )
    static let emeraldGlyph = adaptiveColor(
        light: (0.16, 0.47, 0.34),
        dark: (0.45, 0.86, 0.63)
    )
    static let kiwiCremeCanonicalColorRGB: RGB = (0.91, 0.84, 0.72)
    static let kiwiCremeSupportBrownRGB: RGB = (0.46, 0.39, 0.32)
    static let kiwiCremeCreamRGB: RGB = (1.00, 0.94, 0.84)
    static let kiwiCremeSupportBrown = adaptiveColor(
        light: kiwiCremeSupportBrownRGB,
        dark: kiwiCremeCreamRGB
    )
    static let kiwiCremeGlyph = kiwiCremeSupportBrown

    private static func adaptiveColor(light: RGB, dark: RGB) -> Color {
        Color(uiColor: UIColor { traits in
            let rgb = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
        })
    }
}

private struct GuardianMouthShape: Shape {
    var curve: Double

    var animatableData: Double {
        get { curve }
        set { curve = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let restingY = rect.midY
        let controlY = restingY + rect.height * CGFloat(curve) * 0.48

        path.move(to: CGPoint(x: rect.minX, y: restingY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: restingY),
            control: CGPoint(x: rect.midX, y: controlY)
        )
        return path
    }
}

private enum GuardianEyeSide {
    case left
    case right
}

private struct GuardianEyePose {
    let openAmount: Double
    let curveAmount: Double
    let width: CGFloat
    let height: CGFloat
    let rotation: Angle
}

private struct MorphingGuardianEyeShape: Shape {
    var openAmount: Double
    var curveAmount: Double

    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(openAmount, curveAmount) }
        set {
            openAmount = newValue.first
            curveAmount = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let openness = min(max(openAmount, 0), 1)
        let curve = min(max(curveAmount, -1), 1)
        let bendAmount = CGFloat(abs(curve))
        let closedInfluence = max(CGFloat(1 - openness), bendAmount)
        let lineWidth = max(2, rect.height * interpolate(CGFloat(1), CGFloat(0.5), closedInfluence))

        return continuousEyePath(in: rect, curve: curve, openness: openness)
            .strokedPath(StrokeStyle(lineWidth: lineWidth, lineCap: .round))
    }

    private func continuousEyePath(in rect: CGRect, curve: Double, openness: Double) -> Path {
        var path = Path()
        let bendAmount = CGFloat(abs(curve))
        let closedInfluence = max(CGFloat(1 - openness), bendAmount)
        let lineWidth = max(2, rect.height * interpolate(CGFloat(1), CGFloat(0.5), closedInfluence))
        let halfLineWidth = lineWidth / 2
        let insetStartX = rect.minX + halfLineWidth
        let insetEndX = rect.maxX - halfLineWidth
        let minimumSegment = max(0.5, rect.width * 0.04)
        let startX = min(insetStartX, rect.midX - minimumSegment / 2)
        let endX = max(insetEndX, rect.midX + minimumSegment / 2)
        let closedRestingProgress = curve > 0 ? 0.32 + bendAmount * 0.30 : 0.32
        let closedControlProgress = curve > 0 ? 0.32 - bendAmount * 0.32 : 0.32 + bendAmount * 0.68
        let restingProgress = interpolate(CGFloat(0.5), closedRestingProgress, closedInfluence)
        let controlProgress = interpolate(CGFloat(0.5), closedControlProgress, closedInfluence)
        let restingY = rect.minY + rect.height * restingProgress
        let controlY = rect.minY + rect.height * controlProgress

        path.move(to: CGPoint(x: startX, y: restingY))
        path.addQuadCurve(
            to: CGPoint(x: endX, y: restingY),
            control: CGPoint(x: rect.midX, y: controlY)
        )
        return path
    }

}

private func interpolate(_ start: CGFloat, _ end: CGFloat, _ progress: CGFloat) -> CGFloat {
    let clampedProgress = min(max(progress, 0), 1)
    return start + (end - start) * clampedProgress
}

private func clampUnit(_ value: Double) -> CGFloat {
    CGFloat(min(max(value, 0), 1))
}
