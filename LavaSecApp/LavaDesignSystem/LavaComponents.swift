import SwiftUI
import LavaSecCore
import UIKit

struct LavaNavigationRow<Destination: View>: View {
    let icon: LavaIconRole?
    let title: String
    let summary: String
    let destination: Destination

    init(
        icon: LavaIconRole? = nil,
        title: String,
        summary: String,
        @ViewBuilder destination: () -> Destination
    ) {
        self.icon = icon
        self.title = title
        self.summary = summary
        self.destination = destination()
    }

    var body: some View {
        NavigationLink {
            destination
        } label: {
            HStack(spacing: 12) {
                if let icon {
                    Image(systemName: icon.sfSymbolName)
                        .font(.headline)
                        .foregroundStyle(LavaStyle.safeGreen)
                        .frame(width: 34, height: 34)
                        .background(LavaStyle.softGreen, in: RoundedRectangle(cornerRadius: LavaSurface.iconBadgeCornerRadius))
                        .accessibilityHidden(true)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(title.lavaLocalized)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(summary.lavaLocalized)
                        .lavaRowSubtitleText()
                        .lineLimit(2)
                        .minimumScaleFactor(0.82)
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .lavaSurface(.card)
            .contentShape(RoundedRectangle(cornerRadius: LavaSurface.cardCornerRadius, style: .continuous))
        }
        .buttonStyle(LavaNavigationRowButtonStyle())
        .hoverEffect(.highlight)
    }
}

private struct LavaNavigationRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .overlay {
                RoundedRectangle(cornerRadius: LavaSurface.cardCornerRadius, style: .continuous)
                    .fill(Color(uiColor: .tertiarySystemFill).opacity(configuration.isPressed ? 1 : 0))
            }
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct LavaPanelActionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    let cornerRadius: CGFloat

    init(cornerRadius: CGFloat = LavaSurface.controlCornerRadius) {
        self.cornerRadius = cornerRadius
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(LavaStyle.panelActionGreen)
            .lineLimit(1)
            .minimumScaleFactor(0.82)
            .frame(maxWidth: .infinity)
            .frame(height: LavaSurface.actionButtonHeight)
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(configuration.isPressed ? LavaStyle.panelActionPressedFill : LavaStyle.panelActionFill)
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(Color(uiColor: .tertiarySystemFill).opacity(configuration.isPressed ? 1 : 0))
                    }
            }
            .scaleEffect(configuration.isPressed ? 0.99 : 1)
            .opacity(isEnabled ? 1 : 0.55)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct LavaStandaloneActionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.82)
            .frame(maxWidth: .infinity)
            .frame(height: LavaSurface.actionButtonHeight)
            .background {
                RoundedRectangle(cornerRadius: LavaSurface.controlCornerRadius, style: .continuous)
                    .fill(LavaStyle.safeControlGreen)
                    .overlay {
                        RoundedRectangle(cornerRadius: LavaSurface.controlCornerRadius, style: .continuous)
                            .fill(Color.black.opacity(configuration.isPressed ? 0.10 : 0))
                    }
            }
            .scaleEffect(configuration.isPressed ? 0.99 : 1)
            .opacity(isEnabled ? 1 : 0.45)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Neutral "secondary action" companion to `LavaStandaloneActionButtonStyle`.
/// Same 44pt filled-pill footprint, but in system-neutral colors so it reads as
/// the calm/escape choice (e.g. a dialog's "Not now") beside the green primary —
/// never competing with it for emphasis.
struct LavaSecondaryActionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Color(uiColor: .secondaryLabel))
            .lineLimit(1)
            .minimumScaleFactor(0.82)
            .frame(maxWidth: .infinity)
            .frame(height: LavaSurface.actionButtonHeight)
            .background {
                RoundedRectangle(cornerRadius: LavaSurface.controlCornerRadius, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemFill))
                    .overlay {
                        RoundedRectangle(cornerRadius: LavaSurface.controlCornerRadius, style: .continuous)
                            .fill(Color(uiColor: .tertiarySystemFill).opacity(configuration.isPressed ? 1 : 0))
                    }
            }
            .scaleEffect(configuration.isPressed ? 0.99 : 1)
            .opacity(isEnabled ? 1 : 0.45)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

extension View {
    /// The shared body of a single-line row: horizontal inset plus the `LavaRowHeight`
    /// tap-target floor, with content vertically centered. One definition so a toggle
    /// row, an action row, and a system-link row share the exact same height. Surface is
    /// applied separately — a row inside a `LavaCondensedList` inherits the list's card;
    /// a standalone row uses `lavaControlRowCard()`.
    ///
    /// Single-line rows take no extra vertical padding (the floor centers the control),
    /// which is why a toggle lands at `LavaRowHeight.standard` rather than inflating the
    /// way a `LavaPlainCard`-wrapped control did (card pad + the floor stacked to ~72pt).
    func lavaRow() -> some View {
        self
            .padding(.horizontal, LavaRowHeight.horizontalInset)
            .frame(maxWidth: .infinity, minHeight: LavaRowHeight.standard, alignment: .leading)
            .contentShape(Rectangle())
    }

    /// A standalone single control (toggle, segmented picker, lone action) in its own
    /// card at the shared row height. Use instead of `LavaPlainCard` for one-control
    /// rows; `LavaPlainCard` stays right for genuinely multi-content cards, and multi-row
    /// groups belong in a `LavaCondensedList` of `lavaRow`s.
    func lavaControlRowCard() -> some View {
        lavaRow().lavaSurface(.card)
    }
}

struct LavaPlainCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .lavaSurface(.card)
    }
}

struct LavaTextInputPanel<Content: View>: View {
    let spacing: CGFloat
    let content: Content

    init(spacing: CGFloat = 12, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        LavaPlainCard {
            VStack(alignment: .leading, spacing: spacing) {
                content
            }
        }
    }
}

struct LavaTextInputRow<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.lavaLocalized)
                .font(.caption.weight(.semibold))
                .foregroundStyle(LavaStyle.secondaryText)

            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct LavaTextEditorInputRow: View {
    let title: String
    @Binding var text: String
    let placeholder: String
    var minHeight: CGFloat = 96
    /// When set, shows a live character counter and hard-caps input at this length (UR-29).
    var characterLimit: Int? = nil

    var body: some View {
        LavaTextInputRow(title: title) {
            VStack(alignment: .leading, spacing: 4) {
                ZStack(alignment: .topLeading) {
                    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(placeholder.lavaLocalized)
                            .font(.body)
                            .foregroundStyle(LavaStyle.tertiaryText)
                            .padding(.top, 8)
                            .allowsHitTesting(false)
                    }

                    TextEditor(text: $text)
                        .font(.body)
                        .frame(minHeight: minHeight)
                        .scrollContentBackground(.hidden)
                        // TextEditor keeps UITextView line padding; pull it back to align with the row label.
                        .padding(.leading, -5)
                }

                if let characterLimit {
                    Text("\(text.count)/\(characterLimit)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(text.count >= characterLimit ? LavaStyle.lavaOrange : LavaStyle.tertiaryText)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .accessibilityLabel("\(text.count) of \(characterLimit) characters used")
                        .onChange(of: text) { _, newValue in
                            if newValue.count > characterLimit {
                                text = String(newValue.prefix(characterLimit))
                            }
                        }
                }
            }
        }
    }
}

extension View {
    func lavaTextInputBody(
        keyboardType: UIKeyboardType = .default,
        submitLabel: SubmitLabel = .done,
        axis: Axis = .horizontal
    ) -> some View {
        modifier(
            LavaTextInputBodyModifier(
                keyboardType: keyboardType,
                submitLabel: submitLabel,
                axis: axis
            )
        )
    }
}

private struct LavaTextInputBodyModifier: ViewModifier {
    let keyboardType: UIKeyboardType
    let submitLabel: SubmitLabel
    let axis: Axis

    func body(content: Content) -> some View {
        content
            .font(.body)
            .textInputAutocapitalization(.never)
            .keyboardType(keyboardType)
            .autocorrectionDisabled()
            .submitLabel(submitLabel)
            .lineLimit(axis == .vertical ? nil : 1)
            .fixedSize(horizontal: false, vertical: axis == .vertical)
    }
}

struct LavaDetailRow: View {
    let systemImage: String
    let title: String
    let subtitle: String?
    let tint: Color

    init(
        systemImage: String,
        title: String,
        subtitle: String? = nil,
        tint: Color = LavaStyle.safeGreen
    ) {
        self.systemImage = systemImage
        self.title = title
        self.subtitle = subtitle
        self.tint = tint
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.title3.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 28)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(title.lavaLocalized)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)

                if let subtitle {
                    Text(subtitle.lavaLocalized)
                        .lavaRowSubtitleText()
                }
            }

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

struct LavaMetricPill: View {
    let title: String
    let value: String

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(title.lavaLocalized)
                .lavaMetricLabelText()
        }
        .frame(maxWidth: .infinity)
        .frame(height: 54)
        .accessibilityElement(children: .combine)
        .background(LavaStyle.softGreen, in: RoundedRectangle(cornerRadius: LavaSurface.pillCornerRadius))
    }
}

struct LavaInfoCard<Content: View>: View {
    let content: Content
    let borderTint: Color?
    let minHeight: CGFloat?

    init(borderTint: Color? = nil, minHeight: CGFloat? = nil, @ViewBuilder content: () -> Content) {
        self.borderTint = borderTint
        self.minHeight = minHeight
        self.content = content()
    }

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .leading)
            .lavaPanelBackground(cornerRadius: 20, borderTint: borderTint)
    }
}

struct LavaOverviewMetricBlock: View {
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(LavaTypography.metricNumeral)
                .foregroundStyle(LavaStyle.ink)
                .monospacedDigit()
                .lineLimit(1)
                .allowsTightening(true)
                .minimumScaleFactor(0.9)
                .frame(maxWidth: .infinity)
                .frame(height: 52)

            Text(label.lavaLocalized)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(LavaStyle.secondaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.9)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .frame(height: 20)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 74)
        .accessibilityElement(children: .combine)
    }
}

struct LavaOverviewBannerRow: View {
    let systemImage: String
    let title: String
    let tint: Color
    let background: Color
    var allowsTitleWrapping: Bool = false

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)

            Text(title.lavaLocalized)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .lineLimit(titleLineLimit)
                .minimumScaleFactor(allowsTitleWrapping ? 1 : 0.82)
                .fixedSize(horizontal: false, vertical: allowsTitleWrapping)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, allowsTitleWrapping ? 10 : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: 50)
        .frame(height: rowHeight)
        .background(background, in: RoundedRectangle(cornerRadius: 16))
    }

    private var rowHeight: CGFloat? {
        allowsTitleWrapping ? nil : 50
    }

    private var titleLineLimit: Int? {
        allowsTitleWrapping ? nil : 1
    }
}

struct LavaInfoPanel: View {
    let title: String
    let description: String?
    let systemImage: String?
    let tint: Color
    var borderTint: Color? = nil

    init(
        title: String,
        description: String? = nil,
        systemImage: String? = nil,
        tint: Color = LavaStyle.safeGreen,
        borderTint: Color? = nil
    ) {
        self.title = title
        self.description = description
        self.systemImage = systemImage
        self.tint = tint
        self.borderTint = borderTint
    }

    var body: some View {
        // Floor to the shared row height so a single-line panel (e.g. a status row like
        // "Ready after sign-in") lines up with the rows beside it instead of sitting
        // shorter. Multi-line panels already exceed this, so it's a no-op there.
        LavaInfoCard(borderTint: borderTint, minHeight: LavaRowHeight.standard) {
            VStack(alignment: .leading, spacing: description == nil ? 0 : 10) {
                header

                if let description {
                    Text(description.lavaLocalized)
                        .lavaSupportingText()
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder
    private var header: some View {
        titleText
            .font(.headline)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(title.lavaLocalized)
    }

    private var titleText: Text {
        if let systemImage {
            Text(Image(systemName: systemImage))
                .foregroundColor(tint)
                + Text(" \(title.lavaLocalized)")
                .foregroundColor(LavaStyle.ink)
        } else {
            Text(title.lavaLocalized)
                .foregroundColor(LavaStyle.ink)
        }
    }
}
