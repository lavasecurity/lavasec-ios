import SwiftUI

extension View {
    /// Routes a confirmation `.alert` through the app's shared scaffold so every
    /// two-choice prompt looks alike: the native system alert (the "Discard changes?"
    /// look — a centered card with the system's light border) whose buttons read
    /// *neutral* rather than the app's green. The Cancel/escape action stays calm, the
    /// way the old rage-shake "Not now" button did, and destructive roles keep their red.
    ///
    /// The app tints itself green (`RootView`'s `.tint`), and a native alert inherits that
    /// tint for its non-destructive buttons — which is why an un-styled "Cancel" shows up
    /// green. Re-tinting the *screen* neutral would also drain the green from its toggles
    /// and links, so instead the alert rides a clear, neutrally-tinted layer behind the
    /// content; the surrounding screen keeps its green untouched.
    ///
    /// Attach the `.alert` to the `Color` the closure hands back:
    ///
    ///     .lavaConfirmationAlert { host in
    ///         host.alert("Discard changes?", isPresented: $isShowing) {
    ///             Button("Cancel", role: .cancel) {}
    ///             Button("Discard", role: .destructive) { discard() }
    ///         } message: {
    ///             Text("Your draft changes will be removed.")
    ///         }
    ///     }
    func lavaConfirmationAlert<Output: View>(
        @ViewBuilder _ alert: (Color) -> Output
    ) -> some View {
        background {
            alert(Color.clear)
                .tint(LavaStyle.confirmationButtonTint)
        }
    }
}
