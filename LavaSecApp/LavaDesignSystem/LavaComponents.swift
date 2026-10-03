import SwiftUI
import UIKit
import LavaSecKit

struct LavaNavigationCardBadge {
    let content: AnyView

    // Keep the existing factory labels while the shared row owns glyph geometry.
    // Navigation glyphs have no individual badge background in either host.
    static func systemImage(
        _ systemImage: String,
        font _: Font = .headline,
        tint: Color = LavaStyle.primaryText,
        background _: Color = LavaStyle.softGreen,
        cornerRadius _: CGFloat = LavaSurface.iconBadgeCornerRadius
    ) -> LavaNavigationCardBadge {
        if systemImage == LavaGlyphSymbol.ranking {
            return .custom(LavaRankingGlyph().fill(tint)
                .frame(width: LavaNavigationRowMetrics.glyphPointSize, height: LavaNavigationRowMetrics.glyphPointSize))
        }
        return LavaNavigationCardBadge(
            content: AnyView(
                Image(systemName: systemImage)
                    .font(.system(size: LavaNavigationRowMetrics.glyphPointSize, weight: .regular))
                    .foregroundStyle(tint)
            )
        )
    }

    static func custom(
        _ content: some View,
        background _: Color = LavaStyle.softGreen,
        cornerRadius _: CGFloat = LavaSurface.iconBadgeCornerRadius
    ) -> LavaNavigationCardBadge {
        LavaNavigationCardBadge(
            content: AnyView(content)
        )
    }
}

/// Shared Plus identity for navigation and task-entry rows.
struct LavaSecurityPlusGlyph: View {
    var body: some View {
        Image(systemName: "shield.fill")
            .font(.system(size: LavaNavigationRowMetrics.glyphPointSize, weight: .regular))
            .foregroundStyle(LavaStyle.safeGreen)
            .overlay {
                Image(systemName: "plus")
                    .font(.system(size: LavaIconSize.badge, weight: .heavy))
                    .foregroundStyle(LavaStyle.softGreen)
                    .offset(y: -1)
            }
            .accessibilityHidden(true)
    }
}

enum LavaNavigationCardSummary {
    case none
    case standardLocalized(String)
    case localizedUnclamped(String)
    case verbatimSingleLine(String)
    case warningLocalized(String)

    @MainActor
    @ViewBuilder
    var content: some View {
        switch self {
        case .none: EmptyView()
        case .standardLocalized(let value):
            Text(value.lavaLocalized)
                .lavaRowSubtitleText()
        case .localizedUnclamped(let value):
            Text(value.lavaLocalized)
                .lavaRowSubtitleText()
        case .verbatimSingleLine(let value):
            Text(value)
                .font(.subheadline)
                .foregroundStyle(LavaStyle.secondaryText)
                .lineLimit(1)
                .truncationMode(.tail)
        case .warningLocalized(let value):
            Text(value.lavaLocalized)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(LavaStyle.lavaOrangeText)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }
}

enum LavaNavigationCardAccessory: Equatable {
    /// Sheets, pickers and commands keep the leading glyph/title, without
    /// promising a forward navigation transition.
    case none
    case chevron
    case externalLink
    case lock

    @ViewBuilder
    var content: some View {
        if let systemImage {
            Image(systemName: systemImage)
                .font(.system(size: LavaNavigationRowMetrics.accessoryPointSize, weight: .regular))
                .foregroundStyle(LavaStyle.secondaryText)
        }
    }

    private var systemImage: String? {
        switch self {
        case .none:
            nil
        case .chevron:
            "chevron.right"
        case .externalLink:
            "arrow.up.right"
        case .lock:
            "lock.fill"
        }
    }
}

struct LavaNavigationCardLabel: View {
    let badge: LavaNavigationCardBadge?
    let title: String
    let titleTint: Color
    let localizesTitle: Bool
    let titleLineLimit: Int?
    let summary: LavaNavigationCardSummary
    let accessory: LavaNavigationCardAccessory

    init(
        badge: LavaNavigationCardBadge?,
        badgeSize _: CGFloat,
        rowSpacing _: CGFloat,
        title: String,
        titleTint: Color = LavaStyle.primaryText,
        localizesTitle: Bool = true,
        titleLineLimit: Int? = nil,
        summary: LavaNavigationCardSummary,
        accessory: LavaNavigationCardAccessory
    ) {
        self.badge = badge
        self.title = title
        self.titleTint = titleTint
        self.localizesTitle = localizesTitle
        self.titleLineLimit = titleLineLimit
        self.summary = summary
        self.accessory = accessory
    }

    var body: some View {
        HStack(spacing: LavaSpacing.md) {
            if let badge {
                badge.content
                    .frame(width: LavaToolbarMetrics.iconFrameSize, height: LavaToolbarMetrics.iconFrameSize)
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: LavaSpacing.xs) {
                Text(localizesTitle ? title.lavaLocalized : title)
                    .lavaRowTitleText()
                    .foregroundStyle(titleTint)
                    .lineLimit(titleLineLimit)

                summary.content
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Reserve the same trailing slot for page links and task entries;
            // the caller chooses whether a navigation glyph belongs in it.
            ZStack {
                accessory.content
                    .accessibilityHidden(true)
            }
            .frame(width: LavaNavigationRowMetrics.accessoryPointSize)
        }
        .padding(.horizontal, LavaRowHeight.horizontalInset)
        .padding(.vertical, LavaRowHeight.verticalInset)
        .frame(maxWidth: .infinity, minHeight: LavaRowHeight.standard, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// Shared activation wrapper for navigation-card labels used by sheet task rows.
/// The label owns row geometry; this wrapper owns the single button target and the
/// disabled treatment so import, picker and utility adopters cannot drift apart.
struct LavaNavigationCardButton<Label: View>: View {
    let action: () -> Void
    let isEnabled: Bool
    let label: Label

    init(
        isEnabled: Bool = true,
        action: @escaping () -> Void,
        @ViewBuilder label: () -> Label
    ) {
        self.action = action
        self.isEnabled = isEnabled
        self.label = label()
    }

    var body: some View {
        Button(action: action) {
            label
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.5)
    }
}

/// Tinted action role; existing callers retain their optional shape argument.
struct LavaPanelActionButtonStyle: PrimitiveButtonStyle {
    let cornerRadius: CGFloat

    init(cornerRadius: CGFloat = LavaSurface.controlCornerRadius) {
        self.cornerRadius = cornerRadius
    }

    func makeBody(configuration: Configuration) -> some View {
        LavaFullWidthActionPrimitiveStyle(role: .panel, cornerRadius: cornerRadius)
            .makeBody(configuration: configuration)
    }
}

/// Neutral companion to the primary action; anatomy and interaction states are shared.
struct LavaSecondaryActionButtonStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        LavaFullWidthActionPrimitiveStyle(role: .secondary).makeBody(configuration: configuration)
    }
}

/// Native switches share the list row title and geometry. Parents own their
/// surface and external helper; the hint preserves that association for VoiceOver.
struct LavaToggleRow: View {
    let title: String
    @Binding var isOn: Bool
    var accessibilityHint: String? = nil

    var body: some View {
        Toggle(title.lavaLocalized, isOn: $isOn)
            .lavaRowTitleText()
            .tint(LavaStyle.safeGreen)
            .lavaRow()
            .accessibilityHint((accessibilityHint ?? "").lavaLocalized)
    }
}

extension View {
    /// The shared body of a control row: content insets plus the `LavaRowHeight`
    /// tap-target floor, with content vertically centered. One definition so a toggle
    /// row, an action row, and a system-link row share the exact same height. Surface is
    /// applied separately — a row inside a `LavaCondensedList` inherits the list's card;
    /// a standalone row uses `lavaControlRowCard()`.
    ///
    /// Padding is INSIDE the minimum-height frame: ordinary single-line toggles still
    /// occupy the standard floor, while wrapped translations and Dynamic Type labels
    /// grow with breathing room above and below instead of touching the card edges.
    func lavaRow() -> some View {
        self
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, LavaRowHeight.horizontalInset)
            .padding(.vertical, LavaRowHeight.verticalInset)
            .frame(maxWidth: .infinity, minHeight: LavaRowHeight.standard, alignment: .leading)
            .contentShape(Rectangle())
    }

    /// A standalone single control (toggle, segmented picker, lone action) in its own
    /// card at the shared minimum row height. Use instead of `LavaPlainCard` for one-control
    /// rows; `LavaPlainCard` stays right for genuinely multi-content cards, and multi-row
    /// groups belong in a `LavaCondensedList` of `lavaRow`s.
    func lavaControlRowCard() -> some View {
        lavaRow().lavaSurface(.card)
    }
}

/// Recovery phrase display and entry share one field surface and hit target.
/// The sensitive word remains owned by the caller; this modifier never stores it.
struct LavaRecoveryWordSurface: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, LavaSpacing.md)
            .padding(.vertical, LavaSpacing.sm)
            .frame(maxWidth: .infinity, minHeight: LavaSurface.actionButtonHeight, alignment: .leading)
            .background(LavaStyle.groupedBackground,
                        in: RoundedRectangle(cornerRadius: LavaSurface.selectionCornerRadius, style: .continuous))
    }
}

extension View {
    func lavaRecoveryWordSurface() -> some View { modifier(LavaRecoveryWordSurface()) }
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
                .font(LavaTypography.fieldLabel)
                .foregroundStyle(LavaStyle.secondaryText)

            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct LavaTextEditorInputRow: View {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.lavaSheetScrollProxy) private var scrollProxy
    @Environment(\.lavaSheetScrollViewport) private var scrollViewport
    @FocusState private var isFocused: Bool
    @State private var revealAnchorID = UUID()

    let title: String
    @Binding var text: String
    let placeholder: String
    var minHeight: CGFloat = 96
    /// When set, pins the editor to this height and scrolls overflow, instead of the
    /// default `minHeight` that grows with content. A focused sheet editor can become
    /// shorter to fit the measured usable viewport; its existing text view scrolls within it.
    /// A growing editor is right for a prose field,
    /// but where controls sit BELOW the editor (the chained config page's Choose File / Save row)
    /// it pushes them down the screen as the operator pastes — the moving-button behaviour that
    /// page must not have. `.frame(height:)` on the call site does NOT fix it: it proposes a
    /// height the inner `minHeight` `TextEditor` grows straight past. The bound has to live on the
    /// `TextEditor` itself (Kilo/Codex, PR #549).
    var fixedHeight: CGFloat? = nil
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
                        .focused($isFocused)
                        .font(.body)
                        // Preserve the usual fixed/growing bounds outside focused sheet
                        // editing. Inside a constrained viewport, the same UITextView is
                        // shortened so its internal scrolling can keep the caret visible.
                        .frame(minHeight: editorMinHeight, maxHeight: editorMaxHeight)
                        .scrollContentBackground(.hidden)
                        // TextEditor keeps UITextView line padding; pull it back to align with the row label.
                        .padding(.leading, -5)
                        .background(alignment: .top) {
                            // The measured local scroll surface already clears its header.
                            // Add only shared breathing room, not the inherited top inset
                            // again. This anchor changes no layout or editor identity.
                            Color.clear
                                .frame(width: 1, height: 1)
                                .alignmentGuide(.top) { dimension in
                                    dimension[.top] + LavaSpacing.sm
                                }
                                .id(revealAnchorID)
                        }
                }

                if let characterLimit {
                    Text("\(text.count)/\(characterLimit)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(text.count >= characterLimit ? LavaStyle.lavaOrangeText : LavaStyle.tertiaryText)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .accessibilityLabel("%lld of %lld characters used".lavaLocalizedFormat(text.count, characterLimit))
                        .onChange(of: text) { _, newValue in
                            if newValue.count > characterLimit {
                                text = String(newValue.prefix(characterLimit))
                            }
                        }
                }
            }
        }
        .onChange(of: isEnabled) { _, enabled in
            // Concealment disables the editor without changing its geometry. Release
            // focus so revealing it cannot reopen the keyboard or scroll the sheet.
            if !enabled { isFocused = false }
        }
        .onChange(of: isFocused) { _, focused in
            if focused { revealFocusedEditor() }
        }
        .onChange(of: scrollViewport) { _, _ in
            revealFocusedEditor()
        }
    }

    private var editorMaxHeight: CGFloat? {
        guard isFocused, let scrollViewport, scrollViewport.usableHeight > 0 else { return fixedHeight }
        // The anchor targets the text view itself, so the label and enclosing panel
        // can scroll above it. No guessed label or panel height is subtracted here.
        let visibleHeight = max(LavaSurface.actionButtonHeight, scrollViewport.usableHeight - 2 * LavaSpacing.sm)
        return min(fixedHeight ?? visibleHeight, visibleHeight)
    }

    private var editorMinHeight: CGFloat {
        min(fixedHeight ?? minHeight, editorMaxHeight ?? minHeight)
    }

    private func revealFocusedEditor() {
        guard isFocused, let scrollViewport, scrollViewport.usableHeight > 0 else { return }
        // Focus acquisition and measured viewport changes are the only triggers.
        // Typing and manual scrolling must not pull the reader back to this field.
        scrollProxy?.scrollTo(revealAnchorID, anchor: .top)
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
        HStack(alignment: .top, spacing: LavaSpacing.md) {
            Image(systemName: systemImage)
                .font(.title3.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 28)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(title.lavaLocalized)
                    .lavaCardTitleText()
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
            .padding(.horizontal, LavaSpacing.infoPanelHorizontalInset)
            .padding(.vertical, LavaSpacing.infoPanelVerticalInset)
            .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .leading)
            .lavaPanelBackground(borderTint: borderTint)
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
        .frame(minHeight: rowHeight)
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
    private var action: AnyView? = nil

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

    /// Optional panel action remains a separate accessibility element below its explanation.
    init<Action: View>(
        title: String,
        description: String? = nil,
        systemImage: String? = nil,
        tint: Color = LavaStyle.safeGreen,
        borderTint: Color? = nil,
        @ViewBuilder action: () -> Action
    ) {
        self.init(title: title, description: description, systemImage: systemImage, tint: tint, borderTint: borderTint)
        self.action = AnyView(action())
    }

    var body: some View {
        // Floor to the shared row height so a single-line panel (e.g. a status row like
        // "Ready after sign-in") lines up with the rows beside it instead of sitting
        // shorter. Multi-line panels already exceed this, so it's a no-op there.
        LavaInfoCard(borderTint: borderTint, minHeight: LavaRowHeight.standard) {
            VStack(alignment: .leading, spacing: LavaSpacing.explanationToLink) {
                VStack(alignment: .leading, spacing: description == nil ? 0 : 10) {
                    header
                    if let description {
                        Text(description.lavaLocalized)
                            .lavaSupportingText()
                    }
                }
                .accessibilityElement(children: .combine)
                if let action { action }
            }
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

/// Posts a VoiceOver announcement for an outcome the user triggered but that changes
/// asynchronously or off-screen (for example protection turning on/off). VoiceOver otherwise
/// stays silent unless focus already sits on the element whose value changed.
///
/// Lives in this already-compiled design-system file (part of the LavaSec.xcodeproj source list)
/// rather than a standalone file. Shared entry point for the plan's app-wide assistive-navigation
/// primitives (Task 6): wire it to every user-triggered outcome — protection on/off, filter
/// apply/save, Privacy & Data clear, backup complete, bug-report sent, resolver switch/fallback.
@MainActor
enum LavaAccessibilityAnnouncer {
    /// Announce a short, already-localized message. A no-op when VoiceOver is not running, so
    /// callers may wire it unconditionally. `@MainActor` because UIKit accessibility APIs are
    /// main-actor-bound under Swift 6 (matches other UIKit wrappers like ProtectionHapticFeedback).
    static func announce(_ message: String) {
        guard UIAccessibility.isVoiceOverRunning else { return }
        UIAccessibility.post(notification: .announcement, argument: message)
    }
}

/// Navigation between visited task steps. Unlike a segmented selection, steps
/// can be unavailable individually and their labels must wrap at large text.
struct LavaStepNavigation<Step: Identifiable>: View {
    let steps: [Step]
    let title: (Step) -> String
    let isSelected: (Step) -> Bool
    let isEnabled: (Step) -> Bool
    let select: (Step) -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                ForEach(steps) { step in
                    stepButton(step)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            VStack(spacing: 8) {
                ForEach(steps) { step in stepButton(step) }
            }
        }
    }

    private func stepButton(_ step: Step) -> some View {
        Button { select(step) } label: {
            Text(verbatim: title(step))
                .font(LavaTypography.rowTitle)
                .fontWeight(isSelected(step) ? .heavy : .semibold)
                .foregroundStyle(isEnabled(step) ? LavaStyle.primaryText : LavaStyle.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 10)
                .padding(.horizontal, 12)
                .frame(minWidth: 44, maxWidth: .infinity, minHeight: 44)
                .lavaSurface(.selection(isSelected: isSelected(step)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled(step))
        .accessibilityAddTraits(isSelected(step) ? [.isSelected] : [])
    }
}

/// Read-only diagnostic evidence. Keep the label/value pair together for
/// accessibility; long identifiers and larger text can use the full line below.
struct LavaDiagnosticValueRow: View {
    let title: String
    let value: String

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 12) {
                label.fixedSize()
                valueText.fixedSize()
            }
            VStack(alignment: .leading, spacing: 4) {
                label
                valueText
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var label: some View {
        Text(title.lavaLocalized)
            .font(LavaTypography.rowTitle)
            .foregroundStyle(LavaStyle.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var valueText: some View {
        Text(verbatim: value)
            .font(LavaTypography.rowMetadata)
            .monospacedDigit()
            .foregroundStyle(LavaStyle.primaryText)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Native counterpart of the Share QR privacy scaffold: static blurred artwork,
/// eye-slash, and the shared panel action. No secret is rendered behind the cover.
struct LavaPrivateContentCover: View {
    var title: String
    var actionTitle: String?
    var reveal: () -> Void = {}
    var body: some View {
        ZStack {
            VStack(alignment: .leading, spacing: LavaSpacing.md) {
                ForEach(0..<5) { index in
                    RoundedRectangle(cornerRadius: 4)
                        .fill(LavaStyle.secondaryText.opacity(0.22))
                        .frame(width: index % 2 == 0 ? 200 : 150, height: 12)
                }
            }
            .blur(radius: 10)
            .accessibilityHidden(true)
            VStack(spacing: LavaSpacing.md) {
                Image(systemName: "eye.slash.fill")
                    .font(.title2).foregroundStyle(LavaStyle.secondaryText)
                if actionTitle == nil { Text(title.lavaLocalized).font(LavaTypography.rowMetadata) }
                if let actionTitle {
                    Button(actionTitle.lavaLocalized, action: reveal)
                        .buttonStyle(LavaPanelActionButtonStyle())
                }
            }
            .padding(LavaSpacing.lg)
        }
        .frame(maxWidth: .infinity, minHeight: 184)
        .clipped()
    }
}
