import SwiftUI
import LavaSecKit

/// Opaque cover for native flow content while App Unlock or the privacy mask is active.
/// The mounted React feedback draft survives underneath; the cover blocks hits and
/// accessibility until the existing security owner grants a new authentication turn.
struct LavaSheetLockMask: View {
    let unlock: () -> Void

    var body: some View {
        ZStack {
            Rectangle()
                .fill(LavaStyle.groupedBackground)
                .ignoresSafeArea()

            VStack(spacing: 18) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: LavaIconSize.hero, weight: .semibold))
                    .foregroundStyle(LavaStyle.safeGreen)

                Text("Lava Locked")
                    .font(.title.bold())

                Button("Unlock Lava", action: unlock)
                    .buttonStyle(.borderedProminent)
                    .tint(LavaStyle.safeControlGreen)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityIdentifier("sheetLockMask")
    }
}
