import SwiftUI
import LavaSecCore
import UIKit

extension View {
    func lavaSectionLabelText() -> some View {
        font(.headline.bold())
            .foregroundStyle(LavaStyle.secondaryText)
    }

    func lavaSupportingText() -> some View {
        font(.subheadline)
            .foregroundStyle(LavaStyle.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    func lavaBodySupportingText() -> some View {
        font(.body)
            .foregroundStyle(LavaStyle.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Quiet helper / footer text. Intentionally carries NO horizontal inset so it
    /// sits flush (0-indent) with section titles and card edges — the single shared
    /// baseline. Do NOT wrap call sites in `.padding(.horizontal, …)`; that is what
    /// reintroduces the misaligned-quiet-text drift.
    func lavaQuietNoteText() -> some View {
        font(.footnote)
            .foregroundStyle(LavaStyle.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    func lavaRowSubtitleText() -> some View {
        font(.subheadline)
            .foregroundStyle(LavaStyle.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    func lavaMetadataText() -> some View {
        font(.caption)
            .foregroundStyle(LavaStyle.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    func lavaMetricLabelText(prominent: Bool = false) -> some View {
        font(prominent ? .subheadline : .caption)
            .foregroundStyle(LavaStyle.secondaryText)
    }

    func lavaInactiveText(_ isInactive: Bool) -> some View {
        foregroundStyle(isInactive ? LavaStyle.secondaryText : LavaStyle.primaryText)
    }

    func lavaChromeText() -> some View {
        foregroundStyle(LavaStyle.tertiaryText)
    }
}

struct LavaScreenContent<Content: View>: View {
    private static var scrollTopAnchorID: String { "lava-screen-scroll-top" }

    let title: String?
    let titleAccessory: AnyView?
    let spacing: CGFloat
    let scrolls: Bool
    let scrollToTopTrigger: Int
    let refreshAction: (() async -> Void)?
    let content: Content

    init(
        title: String? = nil,
        titleAccessory: AnyView? = nil,
        spacing: CGFloat = 18,
        scrolls: Bool = true,
        scrollToTopTrigger: Int = 0,
        refreshAction: (() async -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.titleAccessory = titleAccessory
        self.spacing = spacing
        self.scrolls = scrolls
        self.scrollToTopTrigger = scrollToTopTrigger
        self.refreshAction = refreshAction
        self.content = content()
    }

    var body: some View {
        ZStack {
            LavaStyle.groupedBackground
                .ignoresSafeArea()

            if scrolls || refreshAction != nil {
                scrollSurface
            } else {
                paddedContent
                    .frame(maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var scrollSurface: some View {
        ScrollViewReader { proxy in
            if let refreshAction {
                ScrollView {
                    paddedContent
                }
                .scrollBounceBehavior(.always, axes: .vertical)
                .scrollDismissesKeyboard(.interactively)
                .refreshable {
                    await refreshAction()
                }
                .onChange(of: scrollToTopTrigger) { _, _ in
                    scrollToTop(with: proxy)
                }
            } else {
                ScrollView {
                    paddedContent
                }
                .scrollBounceBehavior(.always, axes: .vertical)
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: scrollToTopTrigger) { _, _ in
                    scrollToTop(with: proxy)
                }
            }
        }
    }

    private var paddedContent: some View {
        VStack(alignment: .leading, spacing: spacing) {
            if let title {
                Text(title.lavaLocalized)
                    .font(.largeTitle.bold())
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .trailing) {
                        if let titleAccessory {
                            titleAccessory
                        }
                    }
            }

            content
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 96)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .topLeading) {
            Color.clear
                .frame(height: 0)
                .id(Self.scrollTopAnchorID)
        }
    }

    private func scrollToTop(with proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.24)) {
            proxy.scrollTo(Self.scrollTopAnchorID, anchor: .top)
        }
    }
}

private enum LavaSheetScaffoldMetrics {
    static let scrollTopPadding: CGFloat = 28
    static let scrollBottomPadding: CGFloat = 44
}

struct LavaSheetScaffold<Header: View, Content: View, Footer: View>: View {
    let spacing: CGFloat
    let scrolls: Bool
    let viewAlignedScrolling: Bool
    let header: Header
    let content: Content
    let footer: Footer

    init(
        spacing: CGFloat = 18,
        scrolls: Bool = true,
        viewAlignedScrolling: Bool = false,
        @ViewBuilder header: () -> Header,
        @ViewBuilder content: () -> Content,
        @ViewBuilder footer: () -> Footer
    ) {
        self.spacing = spacing
        self.scrolls = scrolls
        self.viewAlignedScrolling = viewAlignedScrolling
        self.header = header()
        self.content = content()
        self.footer = footer()
    }

    var body: some View {
        contentSurface
            .background(sheetBackgroundStyle)
            .presentationBackground(sheetBackgroundStyle)
            .modifier(LavaSheetNavigationToolbarBackground(hasHeader: hasHeader))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var contentSurface: some View {
        if hasHeader && hasFooter {
            contentWithHeaderAndFooterBars
        } else if hasHeader {
            contentWithHeaderBar
        } else if hasFooter {
            contentWithFooterBar
        } else {
            sheetContent
        }
    }

    @ViewBuilder
    private var contentWithHeaderAndFooterBars: some View {
        if #available(iOS 26.0, *) {
            sheetContent
                .scrollEdgeEffectStyle(.soft, for: .top)
                .scrollEdgeEffectStyle(.soft, for: .bottom)
                .safeAreaBar(edge: .top, spacing: 0) {
                    headerBar
                }
                .safeAreaBar(edge: .bottom, spacing: 0) {
                    footerBar
                }
        } else {
            sheetContent
                .safeAreaInset(edge: .top, spacing: 0) {
                    headerBar
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    footerBar
                }
        }
    }

    @ViewBuilder
    private var contentWithHeaderBar: some View {
        if #available(iOS 26.0, *) {
            sheetContent
                .scrollEdgeEffectStyle(.soft, for: .top)
                .safeAreaBar(edge: .top, spacing: 0) {
                    headerBar
                }
        } else {
            sheetContent
                .safeAreaInset(edge: .top, spacing: 0) {
                    headerBar
                }
        }
    }

    @ViewBuilder
    private var contentWithFooterBar: some View {
        if #available(iOS 26.0, *) {
            sheetContent
                .scrollEdgeEffectStyle(.soft, for: .bottom)
                .safeAreaBar(edge: .bottom, spacing: 0) {
                    footerBar
                }
        } else {
            sheetContent
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    footerBar
                }
        }
    }

    @ViewBuilder
    private var sheetContent: some View {
        if scrolls {
            scrollSurface
        } else {
            contentStack
                .padding(.horizontal, 18)
                .padding(.top, 16)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    @ViewBuilder
    private var scrollSurface: some View {
        if viewAlignedScrolling {
            ScrollView {
                scrollContent
                    .scrollTargetLayout()
            }
            .scrollIndicators(.hidden)
            .scrollTargetBehavior(.viewAligned)
        } else {
            ScrollView {
                scrollContent
            }
            .scrollIndicators(.hidden)
        }
    }

    private var scrollContent: some View {
        contentStack
            .padding(.horizontal, 18)
            .padding(.top, LavaSheetScaffoldMetrics.scrollTopPadding)
            .padding(.bottom, LavaSheetScaffoldMetrics.scrollBottomPadding)
    }

    private var contentStack: some View {
        VStack(alignment: .leading, spacing: spacing) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var headerBar: some View {
        header
            .padding(.horizontal, 18)
            .padding(.top, 12)
            .padding(.bottom, 10)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background {
                Rectangle()
                    .fill(.regularMaterial)
                    .ignoresSafeArea(edges: .top)
            }
    }

    private var footerBar: some View {
        footer
            .padding(.horizontal, 18)
            .padding(.top, 12)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(.regularMaterial)
    }

    private var sheetBackgroundStyle: Color {
        LavaStyle.groupedBackground
    }

    private var hasHeader: Bool {
        Header.self != EmptyView.self
    }

    private var hasFooter: Bool {
        Footer.self != EmptyView.self
    }
}

private struct LavaSheetNavigationToolbarBackground: ViewModifier {
    let hasHeader: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if hasHeader {
            content.toolbarBackground(.hidden, for: .navigationBar)
        } else {
            content.toolbarBackground(.regularMaterial, for: .navigationBar)
        }
    }
}

extension LavaSheetScaffold where Header == EmptyView, Footer == EmptyView {
    init(
        spacing: CGFloat = 18,
        scrolls: Bool = true,
        viewAlignedScrolling: Bool = false,
        @ViewBuilder content: () -> Content
    ) {
        self.init(
            spacing: spacing,
            scrolls: scrolls,
            viewAlignedScrolling: viewAlignedScrolling,
            header: { EmptyView() },
            content: content,
            footer: { EmptyView() }
        )
    }
}

extension LavaSheetScaffold where Header == EmptyView {
    init(
        spacing: CGFloat = 18,
        scrolls: Bool = true,
        viewAlignedScrolling: Bool = false,
        @ViewBuilder content: () -> Content,
        @ViewBuilder footer: () -> Footer
    ) {
        self.init(
            spacing: spacing,
            scrolls: scrolls,
            viewAlignedScrolling: viewAlignedScrolling,
            header: { EmptyView() },
            content: content,
            footer: footer
        )
    }
}

extension LavaSheetScaffold where Footer == EmptyView {
    init(
        spacing: CGFloat = 18,
        scrolls: Bool = true,
        viewAlignedScrolling: Bool = false,
        @ViewBuilder header: () -> Header,
        @ViewBuilder content: () -> Content
    ) {
        self.init(
            spacing: spacing,
            scrolls: scrolls,
            viewAlignedScrolling: viewAlignedScrolling,
            header: header,
            content: content,
            footer: { EmptyView() }
        )
    }
}

struct LavaTabScreenContent<Content: View>: View {
    let title: String
    let titleAccessory: AnyView?
    let scrolls: Bool
    let refreshAction: (() async -> Void)?
    let content: Content

    init(
        title: String,
        titleAccessory: AnyView? = nil,
        scrolls: Bool = true,
        refreshAction: (() async -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.titleAccessory = titleAccessory
        self.scrolls = scrolls
        self.refreshAction = refreshAction
        self.content = content()
    }

    var body: some View {
        LavaScreenContent(
            title: title,
            titleAccessory: titleAccessory,
            spacing: 18,
            scrolls: scrolls,
            refreshAction: refreshAction
        ) {
            content
        }
    }
}

struct LavaPrimaryTabScreenContent<TitleAccessory: View, Overview: View, Content: View>: View {
    let title: String
    let scrolls: Bool
    let scrollToTopTrigger: Int
    let refreshAction: (() async -> Void)?
    let showsTitleAccessory: Bool
    let titleAccessoryAction: (() -> Void)?
    let titleAccessory: TitleAccessory
    let overview: Overview
    let content: Content

    init(
        title: String,
        scrolls: Bool = true,
        scrollToTopTrigger: Int = 0,
        refreshAction: (() async -> Void)? = nil,
        showsTitleAccessory: Bool = true,
        titleAccessoryAction: (() -> Void)? = nil,
        @ViewBuilder titleAccessory: () -> TitleAccessory,
        @ViewBuilder overview: () -> Overview,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.scrolls = scrolls
        self.scrollToTopTrigger = scrollToTopTrigger
        self.refreshAction = refreshAction
        self.showsTitleAccessory = showsTitleAccessory
        self.titleAccessoryAction = titleAccessoryAction
        self.titleAccessory = titleAccessory()
        self.overview = overview()
        self.content = content()
    }

    var body: some View {
        LavaScreenContent(
            spacing: 0,
            scrolls: scrolls,
            scrollToTopTrigger: scrollToTopTrigger,
            refreshAction: refreshAction
        ) {
            VStack(alignment: .leading, spacing: 18) {
                overview
                    .frame(maxWidth: .infinity, alignment: .topLeading)

                content
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .navigationTitle(title.lavaLocalized)
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            if showsTitleAccessory {
                ToolbarItem(placement: .topBarTrailing) {
                    if let titleAccessoryAction {
                        Button(action: titleAccessoryAction) {
                            titleAccessory
                        }
                        .buttonStyle(.plain)
                    } else {
                        titleAccessory
                    }
                }
            }
        }
    }
}

extension LavaPrimaryTabScreenContent where TitleAccessory == EmptyView {
    init(
        title: String,
        scrolls: Bool = true,
        scrollToTopTrigger: Int = 0,
        refreshAction: (() async -> Void)? = nil,
        @ViewBuilder overview: () -> Overview,
        @ViewBuilder content: () -> Content
    ) {
        self.init(
            title: title,
            scrolls: scrolls,
            scrollToTopTrigger: scrollToTopTrigger,
            refreshAction: refreshAction,
            showsTitleAccessory: false,
            titleAccessoryAction: nil,
            titleAccessory: { EmptyView() },
            overview: overview,
            content: content
        )
    }
}

extension LavaPrimaryTabScreenContent where TitleAccessory == EmptyView, Overview == EmptyView {
    init(
        title: String,
        scrolls: Bool = true,
        scrollToTopTrigger: Int = 0,
        refreshAction: (() async -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.init(
            title: title,
            scrolls: scrolls,
            scrollToTopTrigger: scrollToTopTrigger,
            refreshAction: refreshAction,
            showsTitleAccessory: false,
            titleAccessoryAction: nil,
            titleAccessory: { EmptyView() },
            overview: { EmptyView() },
            content: content
        )
    }
}

struct LavaSectionGroup<Content: View>: View {
    let title: String
    let footer: String?
    let content: Content

    init(_ title: String, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.lavaLocalized)
                .lavaSectionLabelText()

            content

            if let footer {
                Text(footer.lavaLocalized)
                    .lavaQuietNoteText()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

enum LavaToolbarMetrics {
    static let buttonSize: CGFloat = 44
    static let iconFrameSize: CGFloat = 24
    // Matches the system navigation back chevron so custom flow-back buttons (import flow,
    // backup, custom resolver, bug report) are visually consistent with screens that use the
    // native back button — was 22pt, which read noticeably larger than the system chevron.
    static let chevronIconPointSize: CGFloat = 17
    static let xmarkIconPointSize: CGFloat = 15
    static let plusIconPointSize: CGFloat = 18
    static let checkmarkIconPointSize: CGFloat = 17
    static let framedIconPointSize: CGFloat = 15
    static let wideIconPointSize: CGFloat = 15
    static let framedIconVerticalOffset: CGFloat = -1
}

struct LavaToolbarIconButton: View {
    let systemName: String
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            LavaToolbarIconSymbol(systemName: systemName)
                .frame(width: LavaToolbarMetrics.iconFrameSize, height: LavaToolbarMetrics.iconFrameSize)
                .frame(width: LavaToolbarMetrics.buttonSize, height: LavaToolbarMetrics.buttonSize)
                .contentShape(Circle())
        }
        .frame(width: LavaToolbarMetrics.buttonSize, height: LavaToolbarMetrics.buttonSize)
        .contentShape(Circle())
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}

/// Semantic action role for icon buttons, mapped to the system `ButtonRole` with
/// availability handling. `.confirm` and `.close` are iOS 26-only, so this stays a
/// project enum to keep call sites free of those symbols and to fall back cleanly on
/// earlier OSes. `.cancel`/`.destructive` are standard since iOS 15 and apply everywhere.
enum LavaActionRole {
    case confirm
    case cancel
    case close
    case destructive

    var buttonRole: ButtonRole? {
        switch self {
        case .cancel: return .cancel
        case .destructive: return .destructive
        case .confirm:
            if #available(iOS 26.0, *) { return .confirm }
            return nil
        case .close:
            if #available(iOS 26.0, *) { return .close }
            return nil
        }
    }
}

struct NativeToolbarIconButton: View {
    let systemName: String
    let accessibilityLabel: String
    /// Optional semantic role. Drives the system's role styling (prominent confirm,
    /// destructive tint, etc.); leave nil for a plain icon action.
    var role: LavaActionRole? = nil
    let action: () -> Void

    var body: some View {
        Button(role: role.flatMap(\.buttonRole), action: action) {
            LavaToolbarIconSymbol(
                systemName: systemName,
                isDestructive: role.flatMap(\.buttonRole) == .destructive
            )
            .frame(width: LavaToolbarMetrics.iconFrameSize, height: LavaToolbarMetrics.iconFrameSize)
        }
        .accessibilityLabel(accessibilityLabel)
    }
}

private struct LavaToolbarIconSymbol: View {
    @Environment(\.isEnabled) private var isEnabled

    let systemName: String
    /// When the host button carries the destructive role, render the glyph in the
    /// system destructive red so the role reads visually — the enclosing Button's
    /// own tint is otherwise overridden by this explicit `foregroundStyle`.
    var isDestructive: Bool = false

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: iconPointSize, weight: .semibold))
            .foregroundStyle(symbolColor)
            .offset(y: iconVerticalOffset)
            .opacity(isEnabled ? 1 : 0.45)
            .accessibilityHidden(true)
    }

    private var symbolColor: Color {
        guard isEnabled else {
            return LavaStyle.tertiaryText
        }
        return isDestructive ? .red : LavaStyle.ink
    }

    private var iconPointSize: CGFloat {
        switch systemName {
        case "chevron.left":
            LavaToolbarMetrics.chevronIconPointSize
        case "xmark":
            LavaToolbarMetrics.xmarkIconPointSize
        case "plus":
            LavaToolbarMetrics.plusIconPointSize
        case "checkmark":
            LavaToolbarMetrics.checkmarkIconPointSize
        case "square.and.pencil":
            LavaToolbarMetrics.framedIconPointSize
        case "trash":
            LavaToolbarMetrics.wideIconPointSize
        default:
            LavaToolbarMetrics.framedIconPointSize
        }
    }

    private var iconVerticalOffset: CGFloat {
        switch systemName {
        case "square.and.pencil":
            LavaToolbarMetrics.framedIconVerticalOffset
        default:
            0
        }
    }
}

// MARK: - Staged-flow push transition

/// Direction of travel through a self-managed staged flow — one view that swaps
/// its body across a `switch`-driven stage/step machine instead of pushing onto
/// a `NavigationStack`. Forward mimics a native push (the incoming page enters
/// from the trailing edge while the outgoing page leaves toward the leading
/// edge); backward reverses it, matching a pop.
enum LavaFlowDirection {
    case forward
    case backward
}

/// The slide used by staged flows (Import a filter, Set up backup) so stepping
/// between their stages reads like the system push/pop the rest of the app gets
/// for free from `NavigationStack`, rather than a hard cut.
enum LavaFlowTransition {
    /// Timing for a staged-flow page change — tuned a touch quicker than the
    /// system push, and softened to a plain fade under Reduce Motion.
    static func animation(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.2) : .easeOut(duration: 0.32)
    }

    /// Horizontal push/pop transition honoring `direction`. Reduce Motion trades
    /// the slide for a cross-fade — still allowed, as a fade carries no motion.
    static func transition(_ direction: LavaFlowDirection, reduceMotion: Bool) -> AnyTransition {
        guard !reduceMotion else {
            return .opacity
        }
        let insertionEdge: Edge = direction == .backward ? .leading : .trailing
        let removalEdge: Edge = direction == .backward ? .trailing : .leading
        return .asymmetric(
            insertion: .move(edge: insertionEdge),
            removal: .move(edge: removalEdge)
        )
    }
}

extension View {
    /// Cross-slides between the stages of a self-managed flow as `value` changes,
    /// mimicking a `NavigationStack` push/pop. Apply to the switched stage content
    /// and host it in a stable container (e.g. a `ZStack`) so the outgoing and
    /// incoming pages overlap during the slide instead of reflowing. Drive the
    /// `value` change inside `withAnimation(LavaFlowTransition.animation(...))`
    /// and pass the matching `direction` so the slide reads the right way.
    func lavaFlowTransition<V: Hashable>(
        value: V,
        direction: LavaFlowDirection,
        reduceMotion: Bool
    ) -> some View {
        id(value)
            .transition(LavaFlowTransition.transition(direction, reduceMotion: reduceMotion))
    }
}
