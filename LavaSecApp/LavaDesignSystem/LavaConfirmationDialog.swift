import SwiftUI

/// A branded, centered confirmation card for *soft* two-choice prompts — the kind
/// where the action is harmless and we want the app's own voice (e.g. the
/// rage-shake "Send feedback?" nudge). Destructive confirmations deliberately stay
/// on the system `.alert`, where the native destructive role and accessibility are
/// the right tools.
///
/// Buttons stack vertically: the green primary on top, the neutral "escape" choice
/// below — so the calm option never competes with the primary for emphasis.
struct LavaConfirmationDialog: View {
    let title: String
    let message: String
    let confirmTitle: String
    let cancelTitle: String
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
                .foregroundStyle(LavaStyle.primaryText)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(LavaStyle.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 8) {
                Button(confirmTitle, action: onConfirm)
                    .buttonStyle(LavaStandaloneActionButtonStyle())

                Button(cancelTitle, action: onCancel)
                    .buttonStyle(LavaSecondaryActionButtonStyle())
            }
            .padding(.top, 10)
        }
        .padding(20)
        .frame(maxWidth: 320)
        .lavaSurface(.card)
        .shadow(color: Color.black.opacity(0.28), radius: 24, y: 10)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }
}

private struct LavaConfirmationDialogPresentation: ViewModifier {
    @Binding var isPresented: Bool
    let title: String
    let message: String
    let confirmTitle: String
    let cancelTitle: String
    let onConfirm: () -> Void
    let onCancel: () -> Void

    func body(content: Content) -> some View {
        content
            .overlay {
                if isPresented {
                    ZStack {
                        Color.black.opacity(0.45)
                            .ignoresSafeArea()
                            .contentShape(Rectangle())
                            .onTapGesture(perform: onCancel)
                            .transition(.opacity)
                            .accessibilityHidden(true)

                        LavaConfirmationDialog(
                            title: title,
                            message: message,
                            confirmTitle: confirmTitle,
                            cancelTitle: cancelTitle,
                            onConfirm: onConfirm,
                            onCancel: onCancel
                        )
                        .padding(40)
                        .transition(.scale(scale: 0.96).combined(with: .opacity))
                    }
                    .accessibilityIdentifier("lavaConfirmationDialog")
                }
            }
            .animation(.easeOut(duration: 0.2), value: isPresented)
    }
}

extension View {
    /// Presents a ``LavaConfirmationDialog`` over the current view while
    /// `isPresented` is true. Tapping the dimmed backdrop runs `onCancel` — safe,
    /// because these prompts are non-destructive. For destructive confirmations,
    /// prefer the system `.alert` instead.
    func lavaConfirmationDialog(
        isPresented: Binding<Bool>,
        title: String,
        message: String,
        confirmTitle: String,
        cancelTitle: String,
        onConfirm: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) -> some View {
        modifier(
            LavaConfirmationDialogPresentation(
                isPresented: isPresented,
                title: title,
                message: message,
                confirmTitle: confirmTitle,
                cancelTitle: cancelTitle,
                onConfirm: onConfirm,
                onCancel: onCancel
            )
        )
    }
}
