import SwiftUI
import LavaSecKit

enum LavaWebLinks {
    static let support = URL(string: "https://lavasecurity.app/support/")!
    static let privacy = URL(string: "https://lavasecurity.app/privacy/")!
    // No custom EULA is hosted; Apple's standard EULA is the compliant default
    // for the Guideline 3.1.2 "Terms of Use" link.
    static let terms = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
}

enum SettingsSubpageLayout {
    static let spacing: CGFloat = 18
    static let feedbackSpacing: CGFloat = 18
}

/// The shared layout for a Settings sub-screen — the single place the "Lava Settings Page"
/// anatomy is enforced, so a non-technical user (think a parent with no security background)
/// meets the same shape on every screen instead of a different layout each time:
///
///   1. Large navigation `title`, always run through `.lavaLocalized`.
///   2. Exactly one `intro` panel (`LavaInfoPanel`) above all sections — one plain sentence
///      saying what the screen does plus the single reassurance that matters. On a
///      `.technical` (Workshop) screen this panel is the plain-language on-ramp. Typed as a
///      concrete `LavaInfoPanel?` rather than a generic slot so the "one panel" rule is
///      structural, not a convention each screen has to remember.
///   3. The body is titled `LavaSectionGroup`s; per-option helper text lives in the group's
///      `footer:`, not scattered `lavaQuietNoteText`.
///   4. `tier` declares the screen's depth (`LavaTier`): `.calm` for everyday screens,
///      `.celebratory` for delight, `.technical` for power-user surfaces. The tier governs
///      the reading level — how much jargon is allowed — see `LavaTier` in LavaTokens.swift.
///
/// Sales surfaces (Upgrade) are intentionally exempt from the strict body anatomy but still
/// declare a `tier` and reuse the shared components/tokens.
struct SettingsSubpageContent<Content: View>: View {
    let title: String?
    let tier: LavaTier
    let intro: LavaInfoPanel?
    let spacing: CGFloat
    let scrolls: Bool
    let refreshAction: (() async -> Void)?
    let content: Content

    init(
        title: String? = nil,
        tier: LavaTier = .calm,
        intro: LavaInfoPanel? = nil,
        spacing: CGFloat = SettingsSubpageLayout.spacing,
        scrolls: Bool = true,
        refreshAction: (() async -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.tier = tier
        self.intro = intro
        self.spacing = spacing
        self.scrolls = scrolls
        self.refreshAction = refreshAction
        self.content = content()
    }

    var body: some View {
        LavaScreenContent(
            spacing: spacing,
            scrolls: scrolls,
            refreshAction: refreshAction
        ) {
            if let intro {
                intro
            }
            content
        }
        .lavaTier(tier)
        .modifier(SettingsSubpageNavigationTitle(title: title))
    }
}

/// Applies the localized large navigation title when a subpage declares one, leaving the
/// chrome untouched otherwise. Keeps the `.lavaLocalized` call in one place so no screen can
/// ship an unlocalized title.
private struct SettingsSubpageNavigationTitle: ViewModifier {
    let title: String?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let title {
            content.navigationTitle(title.lavaLocalized)
        } else {
            content
        }
    }
}

struct SettingsActionRow<Icon: View>: View {
    let title: String
    let iconTint: Color
    let titleTint: Color
    let icon: Icon

    init(
        title: String,
        iconTint: Color = LavaStyle.safeGreen,
        titleTint: Color = .primary,
        @ViewBuilder icon: () -> Icon
    ) {
        self.title = title
        self.iconTint = iconTint
        self.titleTint = titleTint
        self.icon = icon()
    }

    var body: some View {
        HStack(spacing: 12) {
            icon
                .foregroundStyle(iconTint)
                .frame(width: 28, height: 28)

            Text(title.lavaLocalized)
                .font(.headline)
                .foregroundStyle(titleTint)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}
