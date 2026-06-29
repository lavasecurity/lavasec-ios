import SwiftUI
import LavaSecCore
import UIKit

#if DEBUG
struct MascotAnimationDemoView: View {
    @State private var heroState: GuardianMascotState = .sleeping
    @State private var heroLabel = "sleeping"

    private let expressionStates: [MascotExpressionDemo] = [
        MascotExpressionDemo(label: "sleeping", state: .sleeping),
        MascotExpressionDemo(label: "awake", state: .awake),
        MascotExpressionDemo(label: "paused", state: .paused),
        MascotExpressionDemo(label: "retrying", state: .retrying),
        MascotExpressionDemo(label: "concerned", state: .concerned),
        MascotExpressionDemo(label: "grateful", state: .grateful)
    ]

    var body: some View {
        VStack(spacing: 28) {
            Spacer(minLength: 20)

            VStack(spacing: 14) {
                SoftShieldGuardian(size: 156, state: heroState)
                    .frame(width: 172, height: 172)

                Text(heroLabel)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(LavaStyle.ink)
                    .frame(width: 180)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .background(LavaStyle.softGreen, in: RoundedRectangle(cornerRadius: 20))

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 14),
                    GridItem(.flexible(), spacing: 14)
                ],
                spacing: 16
            ) {
                ForEach(expressionStates) { expression in
                    VStack(spacing: 8) {
                        SoftShieldGuardian(size: 72, state: expression.state, animates: false)
                            .frame(width: 82, height: 82)

                        Text(expression.label)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(LavaStyle.secondaryText)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 124)
                    .lavaSurface(.card, cornerRadius: LavaSurface.compactCornerRadius)
                }
            }

            Spacer(minLength: 16)
        }
        .padding(24)
        .background(LavaStyle.groupedBackground)
        .task {
            await playDemo()
        }
    }

    private func playDemo() async {
        let sequence: [(GuardianMascotState, String, UInt64)] = [
            (.sleeping, "sleeping", 1_400_000_000),
            (.waking, "waking", 2_150_000_000),
            (.awake, "awake", 900_000_000),
            (.sleeping, "sleeping", 1_050_000_000),
            (.waking, "waking", 2_150_000_000),
            (.awake, "awake", 800_000_000),
            (.paused, "paused", 950_000_000),
            (.awake, "awake", 800_000_000),
            (.retrying, "retrying", 950_000_000),
            (.awake, "awake", 800_000_000),
            (.concerned, "concerned", 950_000_000),
            (.awake, "awake", 800_000_000),
            (.grateful, "grateful", 900_000_000),
            (.awake, "awake", 900_000_000)
        ]

        for (state, label, delay) in sequence {
            guard !Task.isCancelled else {
                return
            }

            heroState = state
            heroLabel = label
            try? await Task.sleep(nanoseconds: delay)
        }
    }
}

private struct MascotExpressionDemo: Identifiable {
    let label: String
    let state: GuardianMascotState

    var id: String {
        label
    }
}

enum WebsiteAssetCaptureState: String {
    case protected
    case wake
}

struct WebsiteAssetCaptureConfiguration {
    let state: WebsiteAssetCaptureState

    static let launchArgument = "-lava-website-asset-capture"
    private static let stateArgument = "-lavaWebsiteCaptureState"

    static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains(launchArgument)
    }

    static var current: WebsiteAssetCaptureConfiguration {
        WebsiteAssetCaptureConfiguration(state: requestedState)
    }

    private static var requestedState: WebsiteAssetCaptureState {
        let arguments = ProcessInfo.processInfo.arguments
        guard let stateIndex = arguments.firstIndex(of: stateArgument),
              arguments.indices.contains(arguments.index(after: stateIndex))
        else {
            return .protected
        }

        return WebsiteAssetCaptureState(rawValue: arguments[arguments.index(after: stateIndex)]) ?? .protected
    }
}

struct WebsiteAssetCaptureRootView: View {
    let configuration: WebsiteAssetCaptureConfiguration

    @StateObject private var viewModel = AppViewModel.websiteAssetCapturePreview()
    @StateObject private var security = SecurityController()
    @State private var didStartSequence = false

    var body: some View {
        TabView(selection: .constant(LavaRootTab.guardPanel)) {
            GuardView(refreshesProtectionState: false)
                .tabItem {
                    Label("Guard", systemImage: LavaIconRole.guardShield.sfSymbolName)
                }
                .tag(LavaRootTab.guardPanel)

            Color.clear
                .tabItem {
                    Label("Settings", systemImage: LavaIconRole.settings.sfSymbolName)
                }
                .tag(LavaRootTab.settings)
        }
        .tint(LavaStyle.safeGreen)
        .background(LavaStyle.groupedBackground)
        .preferredColorScheme(.light)
        .environmentObject(viewModel)
        .environmentObject(security)
        .onAppear {
            startCaptureStateIfNeeded()
        }
    }

    private func startCaptureStateIfNeeded() {
        guard !didStartSequence else {
            return
        }

        didStartSequence = true

        switch configuration.state {
        case .protected:
            viewModel.applyWebsiteAssetCaptureProtectionState(.protected)
        case .wake:
            viewModel.applyWebsiteAssetCaptureProtectionState(.off)
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 700_000_000)
                guard !Task.isCancelled else {
                    return
                }

                viewModel.applyWebsiteAssetCaptureProtectionState(.waking)
                let wakeDuration = UInt64((GuardianMascotAnimationPlan.wakeDuration + 0.12) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: wakeDuration)
                guard !Task.isCancelled else {
                    return
                }

                viewModel.applyWebsiteAssetCaptureProtectionState(.protected)
            }
        }
    }
}
#endif

struct GentleProtectionDiagram: View {
    @EnvironmentObject private var viewModel: AppViewModel

    let blockedText: String
    let allowedText: String
    let isCompact: Bool

    init(blockedText: String, allowedText: String, isCompact: Bool = false) {
        self.blockedText = blockedText
        self.allowedText = allowedText
        self.isCompact = isCompact
    }

    var body: some View {
        VStack(spacing: isCompact ? 10 : 14) {
            HStack(spacing: isCompact ? 12 : 16) {
                DiagramEndpoint(
                    systemImage: "iphone",
                    title: "Phone",
                    tint: LavaStyle.safeGreen,
                    isCompact: isCompact
                )

                SoftShieldGuardian(
                    size: isCompact ? 54 : 62,
                    state: .awake,
                    animates: false,
                    shieldStyle: viewModel.lavaGuardLook
                )

                DiagramEndpoint(
                    systemImage: "globe",
                    title: "Internet",
                    tint: .teal,
                    isCompact: isCompact
                )
            }

            VStack(spacing: isCompact ? 6 : 8) {
                DiagramPathRow(
                    systemImage: "hand.raised.fill",
                    text: blockedText,
                    tint: LavaStyle.lavaOrange,
                    isCompact: isCompact
                )
                DiagramPathRow(
                    systemImage: "arrow.right.circle.fill",
                    text: allowedText,
                    tint: LavaStyle.safeGreen,
                    isCompact: isCompact
                )
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(blockedText). \(allowedText).")
    }
}

private struct DiagramEndpoint: View {
    let systemImage: String
    let title: String
    let tint: Color
    let isCompact: Bool

    var body: some View {
        VStack(spacing: isCompact ? 4 : 6) {
            Image(systemName: systemImage)
                .font(.system(size: isCompact ? LavaIconSize.endpointCompact : LavaIconSize.endpoint, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: isCompact ? 46 : 54, height: isCompact ? 46 : 54)
                .background(tint.opacity(0.12), in: Circle())

            Text(title.lavaLocalized)
                .font(.caption.weight(.semibold))
                .foregroundStyle(LavaStyle.secondaryText)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct DiagramPathRow: View {
    let systemImage: String
    let text: String
    let tint: Color
    let isCompact: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(tint)
                .frame(width: 24)

            Text(text)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(LavaStyle.ink)
                .lineLimit(2)
                .minimumScaleFactor(0.82)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: isCompact ? 34 : 38)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
    }
}
