import SwiftUI
import LavaSecKit
import LavaSecPresentation
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

#endif
