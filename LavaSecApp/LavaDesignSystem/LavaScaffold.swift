import SwiftUI
import UIKit
import LavaSecKit

/// UIKit owns segmented selection, tracking, animation and accessibility in both
/// native and React Native pages. Respect the system's Reduce Motion behavior.
struct LavaSegmentedPicker<Value: Hashable>: UIViewRepresentable {
    let label: String
    let options: [Value]
    @Binding var selection: Value
    let optionTitle: (Value) -> String

    func makeUIView(context: Context) -> UISegmentedControl {
        let control = UISegmentedControl(items: [])
        #if LAVA_REACT_NATIVE
        control.addGestureRecognizer(LavaControlTrackingGuard())
        #endif
        control.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .valueChanged)
        return control
    }

    func updateUIView(_ control: UISegmentedControl, context: Context) {
        let titles = options.map(optionTitle)
        if context.coordinator.options != options || context.coordinator.titles != titles {
            control.removeAllSegments()
            for (index, title) in titles.enumerated() {
                control.insertSegment(withTitle: title, at: index, animated: false)
            }
        }
        context.coordinator.parent = self
        context.coordinator.options = options
        context.coordinator.titles = titles
        let selected = options.firstIndex(of: selection) ?? UISegmentedControl.noSegment
        if control.selectedSegmentIndex != selected { control.selectedSegmentIndex = selected }
        control.isEnabled = context.environment.isEnabled
        control.accessibilityLabel = label.lavaLocalized
        control.tintColor = UIColor(LavaStyle.safeGreen)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UISegmentedControl, context: Context) -> CGSize? {
        let size = uiView.sizeThatFits(CGSize(width: proposal.width ?? uiView.intrinsicContentSize.width, height: 0))
        return CGSize(width: proposal.width ?? size.width, height: size.height)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject {
        var parent: LavaSegmentedPicker
        var options: [Value] = []
        var titles: [String] = []
        init(_ parent: LavaSegmentedPicker) { self.parent = parent }
        @objc func changed(_ control: UISegmentedControl) {
            guard options.indices.contains(control.selectedSegmentIndex) else { return }
            parent.selection = options[control.selectedSegmentIndex]
        }
    }
}

extension View {
    func lavaSectionLabelText() -> some View {
        font(LavaTypography.sectionLabel)
            .foregroundStyle(LavaStyle.secondaryText)
    }

    /// The primary text of a list / table ROW — one shared size so row titles do not drift per
    /// screen (`LavaTypography.rowTitle`, 15 pt semibold, Dynamic-Type-scaling). **Font only**: a row
    /// title carries its own color (active / inactive / frozen / error), so this sets no color.
    func lavaRowTitleText() -> some View {
        font(LavaTypography.rowTitle)
    }

    /// The title of a tappable ENTRY CARD or navigation row — the surfaces that OPEN a list or a
    /// detail. One step above a row title (`LavaTypography.cardTitle`, 17 pt). **Font only** (above).
    func lavaCardTitleText() -> some View {
        font(LavaTypography.cardTitle)
    }

    /// Emphasized body copy, including a Guard slogan; scales with the body role.
    func lavaEmphasisText() -> some View {
        font(.body.weight(.semibold))
    }

    /// Secondary supporting copy — `.subheadline` (15 pt). The DEFAULT for the dense,
    /// glanceable text that sits under a title or inside a card (row subtitles, panel
    /// captions, one- or two-line explainers). Rule: reach for this first; use the larger
    /// `lavaBodySupportingText()` only for genuine primary paragraph copy (below). Both are
    /// secondary-colored and grow vertically; they differ only in size, so pick by role — do
    /// not coin-flip between them per screen.
    func lavaSupportingText(color: Color = LavaStyle.secondaryText) -> some View {
        font(.subheadline)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Primary paragraph copy — `.body` (17 pt). For the main readable prose of a screen or
    /// sheet (an explanatory paragraph the user is meant to actually read), NOT for the dense
    /// caption/subtitle text that belongs to `lavaSupportingText()` (15 pt) above. If in doubt
    /// it is supporting, not body — default to the smaller one.
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

    /// The visible line owns paragraph flow; transparent padding keeps a real
    /// 44pt target. Shared panel insets contain the expanded target at the clip.
    func lavaQuietLinkText() -> some View {
        font(.footnote.weight(.semibold))
            .foregroundStyle(LavaStyle.safeGreen)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(minHeight: 20, alignment: .leading)
            .padding(.vertical, LavaSpacing.quietLinkInteractionInset)
            .contentShape(Rectangle())
            .padding(.vertical, -LavaSpacing.quietLinkInteractionInset)
    }

    func lavaRowSubtitleText() -> some View {
        font(LavaTypography.rowMetadata)
            .foregroundStyle(LavaStyle.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    func lavaMetadataText() -> some View {
        font(LavaTypography.rowMetadata)
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
                    .accessibilityAddTraits(.isHeader)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .trailing) {
                        if let titleAccessory {
                            titleAccessory
                        }
                    }
            }

            content
        }
        .padding(.horizontal, LavaSpacing.screenHorizontal)
        .padding(.top, LavaSpacing.screenTop)
        .padding(.bottom, LavaSpacing.screenBottom)
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
    static let footerBottomPadding: CGFloat = 24
}

struct LavaSheetScaffold<Header: View, Content: View, Footer: View>: View {
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var scrollViewport: LavaSheetScrollViewport?

    let spacing: CGFloat
    let scrolls: Bool
    let viewAlignedScrolling: Bool
    /// Scrolling sheets always host their OWN `ScrollViewReader` for focused-input reveal.
    /// This option also enables the reader for non-scrolling content. The scaffold
    /// publishes the proxy through `\.lavaSheetScrollProxy`, so a pinned-header control (e.g.
    /// the blocklist category jump-pills) can drive the list WITHOUT a caller wrapping the
    /// whole scaffold in a reader. Wrapping externally puts this view's fill-frame *inside*
    /// the reader, which stops the scroll surface from filling the sheet — the `.safeAreaInset`
    /// footer then floats mid-content and the pinned header lands wrong (lavasec-ios#326
    /// follow-up). Keeping the reader inside, below the fill-frame, preserves the bar geometry.
    let hostsScrollProxy: Bool
    let header: Header
    let content: Content
    let footer: Footer

    init(
        spacing: CGFloat = 18,
        scrolls: Bool = true,
        viewAlignedScrolling: Bool = false,
        hostsScrollProxy: Bool = false,
        @ViewBuilder header: () -> Header,
        @ViewBuilder content: () -> Content,
        @ViewBuilder footer: () -> Footer
    ) {
        self.spacing = spacing
        self.scrolls = scrolls
        self.viewAlignedScrolling = viewAlignedScrolling
        self.hostsScrollProxy = hostsScrollProxy
        self.header = header()
        self.content = content()
        self.footer = footer()
    }

    var body: some View {
        // The fill-frame stays OUTSIDE `scrollProxyHost` so, when a reader is hosted, it is the
        // reader (not a collapsed content-sized box) that fills the sheet — see `hostsScrollProxy`.
        scrollProxyHost
            .background(sheetBackgroundStyle)
            .presentationBackground(sheetBackgroundStyle)
            .modifier(LavaSheetNavigationToolbarBackground(hasHeader: hasHeader))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var scrollProxyHost: some View {
        if hostsScrollProxy || scrolls {
            ScrollViewReader { proxy in
                contentSurface
                    .environment(\.lavaSheetScrollProxy, proxy)
            }
        } else {
            contentSurface
        }
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
                    if !scrollsFooter {
                        footerBar
                    }
                }
        } else {
            sheetContent
                .safeAreaInset(edge: .top, spacing: 0) {
                    headerBar
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if !scrollsFooter {
                        footerBar
                    }
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
                    if !scrollsFooter {
                        footerBar
                    }
                }
        } else {
            sheetContent
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if !scrollsFooter {
                        footerBar
                    }
                }
        }
    }

    @ViewBuilder
    private var sheetContent: some View {
        if scrolls {
            scrollSurface
                .environment(\.lavaSheetScrollViewport, scrollViewport)
                .onGeometryChange(for: LavaSheetScrollViewport.self) { geometry in
                    LavaSheetScrollViewport(size: geometry.size)
                } action: { newViewport in
                    scrollViewport = newViewport
                }
        } else {
            contentStack
                .padding(.horizontal, LavaSpacing.screenHorizontal)
                .padding(.top, LavaSpacing.screenTop)
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
            .padding(.horizontal, LavaSpacing.screenHorizontal)
            .padding(.top, LavaSheetScaffoldMetrics.scrollTopPadding)
            .padding(.bottom, scrollsFooter ? 0 : LavaSheetScaffoldMetrics.scrollBottomPadding)
    }

    private var contentStack: some View {
        VStack(alignment: .leading, spacing: spacing) {
            // Keep the content in the same structural position through rotation so a
            // focused editor retains its draft and responder. Only the footer moves.
            content
            if scrollsFooter {
                footer
                    .padding(.bottom, LavaSheetScaffoldMetrics.footerBottomPadding)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var scrollsFooter: Bool {
        // In compact height, a pinned action bar plus the keyboard can consume the
        // entire editor viewport. Scrolling sheets keep those same actions after
        // their content, with shared stack spacing and unchanged button hit targets.
        scrolls && hasFooter && verticalSizeClass == .compact
    }

    private var headerBar: some View {
        header
            .padding(.horizontal, LavaSpacing.screenHorizontal)
            .padding(.top, 12)
            .padding(.bottom, 10)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background {
                Rectangle()
                    .fill(LavaStyle.groupedBackground)
                    .ignoresSafeArea(edges: .top)
            }
    }

    private var footerBar: some View {
        footer
            .padding(.horizontal, LavaSpacing.screenHorizontal)
            .padding(.top, 12)
            .padding(.bottom, LavaSheetScaffoldMetrics.footerBottomPadding)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(LavaStyle.groupedBackground)
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
            content.toolbarBackground(LavaStyle.groupedBackground, for: .navigationBar)
        }
    }
}

/// The proxy a scrolling `LavaSheetScaffold` (or one with `hostsScrollProxy: true`)
/// publishes for its subtree. Shared inputs and pinned-header controls target this same
/// scroll surface. It is optional outside a hosting scaffold.
private struct LavaSheetScrollProxyKey: EnvironmentKey {
    // Computed (not a stored `static let`) so Swift 6 strict concurrency doesn't flag the
    // non-Sendable `ScrollViewProxy?` as shared mutable global state — there is no storage.
    static var defaultValue: ScrollViewProxy? { nil }
}

/// Measures the local scroll surface after SwiftUI has consumed header/footer
/// and keyboard safe areas. Subtracting inherited insets again would turn an
/// available editor viewport into a false zero. Content scrolling does not change
/// this size, so it cannot trigger repeated focused-field reveal.
struct LavaSheetScrollViewport: Equatable {
    let size: CGSize

    var usableHeight: CGFloat { max(0, size.height) }
}

private struct LavaSheetScrollViewportKey: EnvironmentKey {
    static var defaultValue: LavaSheetScrollViewport? { nil }
}

extension EnvironmentValues {
    var lavaSheetScrollViewport: LavaSheetScrollViewport? {
        get { self[LavaSheetScrollViewportKey.self] }
        set { self[LavaSheetScrollViewportKey.self] = newValue }
    }

    var lavaSheetScrollProxy: ScrollViewProxy? {
        get { self[LavaSheetScrollProxyKey.self] }
        set { self[LavaSheetScrollProxyKey.self] = newValue }
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

/// Full sheets use the same system navigation bar as pushed pages. UIKit owns
/// circular icon chrome, group geometry, alignment and transition matching.
extension View {
    /// Opt-in only at full-sheet roots/stages. Ordinary push navigation keeps its
    /// native bar and gestures; this modifier never substitutes page transitions.
    @ViewBuilder
    func lavaFullSheetHeader<Leading: View, Trailing: View>(
        _ title: String, isPresented: Bool = true,
        @ViewBuilder leading: @escaping () -> Leading,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) -> some View {
        if isPresented {
            navigationTitle(title.lavaLocalized)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar(.visible, for: .navigationBar)
                .tint(LavaStyle.primaryText)
                .toolbar {
                    ToolbarItemGroup(placement: .topBarLeading) { leading() }
                    ToolbarItemGroup(placement: .topBarTrailing) { trailing() }
                }
        } else {
            self
        }
    }

    func lavaFullSheetHeader(_ title: String, close: @escaping () -> Void) -> some View {
        lavaFullSheetHeader(title, leading: {
            LavaToolbarIconButton(systemName: "xmark", accessibilityLabel: "Close", role: .close, action: close)
        }, trailing: { EmptyView() })
    }
}

/// Focused task presentation: shared full-sheet chrome owns the header,
/// LavaSheetScaffold owns scrolling and the pinned action footer. A Back action
/// is an actual prior step; Close always exits through the caller's cleanup.
struct LavaTaskSheet<Content: View, Footer: View>: View {
    let title: String
    let back: (() -> Void)?
    let actionsDisabled: Bool
    let scrolls: Bool
    let close: () -> Void
    let content: Content
    let footer: Footer

    init(title: String, back: (() -> Void)? = nil, actionsDisabled: Bool = false, scrolls: Bool = true,
         close: @escaping () -> Void, @ViewBuilder content: () -> Content,
         @ViewBuilder footer: () -> Footer) {
        self.title = title
        self.back = back
        self.actionsDisabled = actionsDisabled
        self.scrolls = scrolls
        self.close = close
        self.content = content()
        self.footer = footer()
    }

    var body: some View {
        NavigationStack {
            LavaSheetScaffold(content: { content }, footer: { footer })
                .lavaFullSheetHeader(title, leading: {
                    if let back {
                        LavaToolbarIconButton(systemName: "chevron.left", accessibilityLabel: "Back", action: back)
                            .disabled(actionsDisabled)
                    }
                }, trailing: {
                    LavaToolbarIconButton(systemName: "xmark", accessibilityLabel: "Close", role: .close, action: close)
                        .disabled(actionsDisabled)
                })
        }
        .presentationDetents([.large])
    }
}

/// A completed task uses a single calm outcome composition. The footer always
/// belongs to the screen's bottom safe area, and long/large text can scroll.
/// Callers enter this screen only after their existing operation confirms success.
/// Presentation only. The explicit operation owner consumes success; appearance never replays it.
struct LavaSuccessScreen<Detail: View>: View {
    let title: String
    let message: String
    let done: () -> Void
    let detail: Detail

    init(title: String, message: String, done: @escaping () -> Void,
         @ViewBuilder detail: () -> Detail) {
        self.title = title
        self.message = message
        self.done = done
        self.detail = detail()
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: LavaSpacing.xl) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: LavaIconSize.heroResult, weight: .regular))
                        .foregroundStyle(LavaStyle.safeGreen)
                        .accessibilityHidden(true)
                    Text(title.lavaLocalized)
                        .font(.title2.bold())
                        .foregroundStyle(LavaStyle.primaryText)
                        .accessibilityAddTraits(.isHeader)
                    Text(message.lavaLocalized)
                        .lavaBodySupportingText()
                    detail
                }
                .multilineTextAlignment(.center)
                .padding(LavaSpacing.screenHorizontal)
                .frame(maxWidth: .infinity)
                .frame(minHeight: geometry.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button("Done".lavaLocalized, action: done)
                .buttonStyle(LavaStandaloneActionButtonStyle())
                .padding(.horizontal, LavaSpacing.screenHorizontal)
                .padding(.top, LavaSpacing.md)
                .padding(.bottom, LavaSpacing.xl)
                .background(LavaStyle.groupedBackground)
        }
        .background(LavaStyle.groupedBackground.ignoresSafeArea())
        .presentationDetents([.large])
    }
}

extension LavaSuccessScreen where Detail == EmptyView {
    init(title: String, message: String, done: @escaping () -> Void) {
        self.init(title: title, message: message, done: done, detail: { EmptyView() })
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
            VStack(alignment: .leading, spacing: LavaSpacing.xl) {
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

/// Quiet explanatory copy and an in-panel explanation use the same paragraph gap.
/// Style the label with lavaQuietLinkText; its tap padding is outside text flow.
struct LavaQuietFooter<Link: View>: View {
    let note: String?
    let link: Link

    init(_ note: String?, @ViewBuilder link: () -> Link) {
        self.note = note
        self.link = link()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LavaSpacing.explanationToLink) {
            if let note {
                Text(note.lavaLocalized)
                    .lavaQuietNoteText()
            }
            link
                .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A contextual settings destination, kept beside the quiet explanation it clarifies.
struct LavaSectionFooterLink {
    let title: String
    let action: () -> Void
    var accessibilityIdentifier: String = ""
}

struct LavaSectionGroup<Content: View>: View {
    let title: String
    let footer: String?
    let footerLink: LavaSectionFooterLink?
    let content: Content

    init(
        _ title: String, footer: String? = nil,
        footerLink: LavaSectionFooterLink? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.footer = footer
        self.footerLink = footerLink
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.lavaLocalized)
                .lavaSectionLabelText()
                .accessibilityAddTraits(.isHeader)

            content

            if let footerLink {
                LavaQuietFooter(footer) {
                    Button(action: footerLink.action) {
                        Text(footerLink.title.lavaLocalized)
                            .lavaQuietLinkText()
                    }
                    .accessibilityIdentifier(footerLink.accessibilityIdentifier)
                    .accessibilityAddTraits(.isLink)
                }
            } else if let footer {
                Text(footer.lavaLocalized)
                    .lavaQuietNoteText()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Inline actions and toolbar actions share exactly the same circular control.
enum LavaIconActionPresentation { case filled, plain }

struct LavaIconActionButton: View {
    let systemName: String
    let accessibilityLabel: String
    var destructive = false
    var tint: Color? = nil
    var presentation: LavaIconActionPresentation = .filled
    let action: () -> Void

    var body: some View {
        Button(role: destructive ? .destructive : nil, action: action) {
            LavaToolbarSymbol(systemName: systemName,
                              role: destructive ? .destructive : nil,
                              tint: tint)
                .frame(width: LavaToolbarMetrics.buttonSize, height: LavaToolbarMetrics.buttonSize)
                .background(presentation == .filled ? Color(uiColor: .secondarySystemFill) : .clear, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel.lavaLocalized)
    }
}

struct LavaToolbarIconButton: View {
    let systemName: String
    let accessibilityLabel: String
    var role: LavaActionRole? = nil
    var tint: Color? = nil
    let action: () -> Void

    var body: some View {
        Button(role: role.flatMap(\.buttonRole), action: action) {
            LavaToolbarSymbol(systemName: systemName, role: role, tint: tint)
        }
        .lavaNativeActionStyle(confirm: LavaActionRole.isConfirmation(symbol: systemName, role: role))
        .accessibilityLabel(accessibilityLabel.lavaLocalized)
    }
}

/// In-content mode controls share the native prominent green treatment with
/// toolbar confirmations while exposing their selected state independently.
struct LavaToolbarModeButton: View {
    let systemName: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        LavaToolbarModeControl(
            systemName: systemName,
            isProminent: isSelected,
            isSelected: isSelected,
            action: action
        )
            .frame(width: LavaToolbarMetrics.buttonSize, height: LavaToolbarMetrics.buttonSize)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// One-shot toolbar actions can use the same prominent green treatment as a
/// selected mode without claiming a persistent selected state to accessibility.
struct LavaToolbarProminentActionButton: View {
    let systemName: String
    let isProminent: Bool
    let action: () -> Void

    var body: some View {
        LavaToolbarModeControl(
            systemName: systemName,
            isProminent: isProminent,
            isSelected: false,
            action: action
        )
        .frame(width: LavaToolbarMetrics.buttonSize, height: LavaToolbarMetrics.buttonSize)
    }
}

/// The native and RN mode adapters use identical UIButton configuration and
/// geometry. A selected surface cannot change the glyph's rendering path or
/// intrinsic padding, including while UIKit interpolates its material.
private struct LavaToolbarModeControl: UIViewRepresentable {
    let systemName: String
    let isProminent: Bool
    let isSelected: Bool
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        button.addTarget(context.coordinator, action: #selector(Coordinator.pressed), for: .touchUpInside)
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {
        context.coordinator.action = action
        var configuration: UIButton.Configuration
        if #available(iOS 26.0, *) {
            configuration = isProminent ? .prominentGlass() : .glass()
        } else {
            configuration = isProminent ? .filled() : .plain()
        }
        let traits = UITraitCollection(userInterfaceStyle: colorScheme == .dark ? .dark : .light)
        let foreground = (isProminent ? UIColor.white : UIColor(LavaStyle.navigationForeground)).resolvedColor(with: traits)
        configuration.baseBackgroundColor = isProminent ? UIColor(LavaStyle.safeControlGreen).resolvedColor(with: traits) : nil
        configuration.baseForegroundColor = foreground
        // Match the visible material to the shared large navigation control;
        // a fixed hit target does not override configuration's default size.
        configuration.buttonSize = .large
        configuration.cornerStyle = .capsule
        let inset = (LavaToolbarMetrics.buttonSize - LavaToolbarMetrics.iconFrameSize) / 2
        configuration.contentInsets = NSDirectionalEdgeInsets(top: inset, leading: inset, bottom: inset, trailing: inset)
        if let symbol = UIImage(systemName: systemName, withConfiguration:
            UIImage.SymbolConfiguration(pointSize: LavaToolbarMetrics.checkmarkIconPointSize, weight: .semibold)) {
            let canvas = CGSize(width: LavaToolbarMetrics.iconFrameSize, height: LavaToolbarMetrics.iconFrameSize)
            let image = UIGraphicsImageRenderer(size: canvas).image { _ in
                symbol.withTintColor(foreground, renderingMode: .alwaysOriginal).draw(at: CGPoint(
                    x: (canvas.width - symbol.size.width) / 2,
                    y: (canvas.height - symbol.size.height) / 2))
            }
            configuration.image = image.withRenderingMode(.alwaysOriginal)
        }
        button.configuration = configuration
        button.isEnabled = isEnabled
        button.accessibilityTraits = isSelected ? [.button, .selected] : [.button]
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIButton, context: Context) -> CGSize? {
        CGSize(width: LavaToolbarMetrics.buttonSize, height: LavaToolbarMetrics.buttonSize)
    }

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }
    final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func pressed() { action() }
    }
}

/// A group paints one capsule; contained actions retain separate 44pt targets.
struct LavaToolbarActionGroup<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 0) { content }
            .buttonStyle(LavaGroupedToolbarActionStyle())
            .background(LavaStyle.cardBackground, in: Capsule())
    }
}

private struct LavaGroupedToolbarActionStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: LavaToolbarMetrics.buttonSize, height: LavaToolbarMetrics.buttonSize)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

/// Native bars own grouping and chrome. Kept as the common call-site adapter
/// so toolbar policy stays centralized across existing native screens.
extension ToolbarContent {
    @ToolbarContentBuilder
    func lavaToolbarChrome() -> some ToolbarContent {
        self
    }
}

/// Semantic action role for icon buttons, mapped to the system `ButtonRole` with
/// availability handling. `.confirm` and `.close` are iOS 26-only, so this stays a
/// project enum to keep call sites free of those symbols and to fall back cleanly on
/// earlier OSes. `.cancel`/`.destructive` are standard since iOS 15 and apply everywhere.
enum LavaActionRole: Equatable {
    case confirm
    case cancel
    case close
    case destructive

    static func foreground(for symbol: String, role: LavaActionRole?) -> Color {
        // Navigation/dismissal never inherits confirmation color from a parent.
        if symbol == "xmark" || symbol == "chevron.left" { return LavaStyle.navigationForeground }
        if role == .destructive || symbol == "trash" { return .red }
        if isConfirmation(symbol: symbol, role: role) { return .white }
        return LavaStyle.navigationForeground
    }

    static func isConfirmation(symbol: String, role: LavaActionRole?) -> Bool {
        symbol != "xmark" && symbol != "chevron.left" && role != .destructive
            && (role == .confirm || symbol == "checkmark")
    }

    var buttonRole: ButtonRole? {
        switch self {
        case .cancel: return .cancel
        case .destructive: return .destructive
        case .confirm:
            // The shared native prominent style supplies confirmation chrome;
            // retain the explicitly supplied glyph rather than a system item.
            return nil
        case .close:
            if #available(iOS 26.0, *) { return .close }
            return nil
        }
    }
}

private struct LavaToolbarSymbol: View {
    let systemName: String
    let role: LavaActionRole?
    var tint: Color? = nil

    var body: some View {
        if LavaActionRole.isConfirmation(symbol: systemName, role: role),
           let symbol = UIImage(systemName: systemName, withConfiguration:
               UIImage.SymbolConfiguration(pointSize: LavaToolbarMetrics.checkmarkIconPointSize, weight: .semibold)) {
            // A symbolic UIImage can be re-colored by native prominent toolbars
            // even with alwaysOriginal. Resolve the system glyph's white pixels
            // once per view update; the system still owns the button and its fill.
            let image = UIGraphicsImageRenderer(size: symbol.size).image { _ in
                symbol.withTintColor(.white, renderingMode: .alwaysOriginal).draw(at: .zero)
            }
            Image(uiImage: image.withRenderingMode(.alwaysOriginal))
        } else {
            Image(systemName: systemName)
                .foregroundStyle(tint ?? LavaActionRole.foreground(for: systemName, role: role))
        }
    }
}

struct NativeToolbarIconButton: View {
    @Environment(\.isEnabled) private var isEnabled
    let systemName: String
    let accessibilityLabel: String
    /// Semantic role drives the shared confirmation fill and destructive color.
    /// The system still owns action semantics, navigation, focus and accessibility.
    var role: LavaActionRole? = nil
    /// Extra Voice Control spoken names ("tap <name>"), ADDED to the accessibility-label command —
    /// not a replacement — so a short alias never strips the existing "tap <label>" command. Set it
    /// where the label is long/phrase-like, to offer a shorter command alongside it.
    var accessibilityInputLabels: [String] = []
    let action: () -> Void

    var body: some View {
        Button(role: role.flatMap(\.buttonRole), action: action) {
            LavaToolbarSymbol(systemName: systemName, role: role)
        }
        .foregroundStyle(LavaActionRole.foreground(for: systemName, role: role))
        .lavaNativeActionStyle(confirm: LavaActionRole.isConfirmation(symbol: systemName, role: role),
                              tint: LavaActionRole.foreground(for: systemName, role: role))
        .accessibilityLabel(accessibilityLabel.lavaLocalized)
        // Aliases FIRST, then the label: `.accessibilityInputLabels` replaces the default set, and
        // Voice Control's "Show Names" overlay surfaces the FIRST entry — so a short alias becomes
        // the displayed/primary command while the original "tap <label>" still matches via the
        // appended label. Empty aliases → just the label, identical to the system default.
        .accessibilityInputLabels(accessibilityInputLabels + [accessibilityLabel.lavaLocalized])
    }

}

extension View {
    /// The system owns the circular toolbar frame and its prominent confirmation
    /// treatment. In-content and toolbar adopters do not draw a second circle.
    @ViewBuilder
    func lavaNativeActionStyle(confirm: Bool, tint: Color = LavaStyle.navigationForeground) -> some View {
        if confirm {
            if #available(iOS 26.0, *) {
                self.buttonStyle(.glassProminent).tint(LavaStyle.safeControlGreen).foregroundStyle(.white)
            } else {
                self.buttonStyle(.borderedProminent).tint(LavaStyle.safeControlGreen).foregroundStyle(.white)
            }
        } else { self.tint(tint) }
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
    /// system push; cross-fade follows the separate system transition preference.
    static func animation(reduceMotion: Bool) -> Animation {
        UIAccessibility.prefersCrossFadeTransitions ? .easeInOut(duration: 0.2) : .easeOut(duration: 0.32)
    }

    /// Gate for an *incidental* animation — a selection slide, section expand/collapse, animated
    /// scroll, or press-scale. Returns `nil` under Reduce Motion so the change lands instantly (no
    /// movement); otherwise the given animation. Distinct from `animation(reduceMotion:)`, which
    /// follows the explicit cross-fade preference for staged-flow page changes. Use as
    /// `.animation(LavaFlowTransition.incidental(.easeInOut(duration: 0.2), reduceMotion: reduceMotion), value:)`
    /// or `withAnimation(LavaFlowTransition.incidental(..., reduceMotion: reduceMotion))`.
    static func incidental(_ animation: Animation, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : animation
    }

    /// Horizontal page movement. Only an explicit cross-fade request substitutes opacity.
    static func transition(_ direction: LavaFlowDirection, reduceMotion: Bool) -> AnyTransition {
        guard !UIAccessibility.prefersCrossFadeTransitions else {
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

/// Optional outline treatment keeps the standard action geometry and interaction.
private struct LavaActionWhiteOutlineKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var lavaActionWhiteOutline: Bool {
        get { self[LavaActionWhiteOutlineKey.self] }
        set { self[LavaActionWhiteOutlineKey.self] = newValue }
    }
}

/// One interaction-state resolver for native full-width action roles. Disabled
/// controls retain readable text and never receive pressed feedback.
struct LavaFullWidthActionState {
    enum Role: CaseIterable { case primary, panel, secondary }

    let role: Role
    let isEnabled: Bool
    let isPressed: Bool

    init(role: Role, isEnabled: Bool, isPressed: Bool) {
        self.role = role
        self.isEnabled = isEnabled
        self.isPressed = isEnabled && isPressed
    }

    var foreground: Color {
        guard isEnabled else { return LavaStyle.secondaryText }
        switch role {
        case .primary: return LavaStyle.actionForeground
        case .panel: return LavaStyle.panelActionGreen
        case .secondary: return LavaStyle.primaryText
        }
    }

    var fill: Color {
        guard isEnabled else { return LavaStyle.disabledSurface }
        switch role {
        case .primary: return LavaStyle.safeControlGreen
        case .panel: return isPressed ? LavaStyle.panelActionPressedFill : LavaStyle.panelActionFill
        case .secondary: return LavaStyle.cardBackground
        }
    }

    // Preserve each role's existing native pressed material while sharing when
    // it appears, its shape, and the same subtle scale/reduced-motion behavior.
    var pressedOverlay: Color {
        role == .primary ? .black : Color(uiColor: .tertiarySystemFill)
    }
    var pressedOverlayOpacity: Double { isPressed ? (role == .primary ? 0.10 : 1) : 0 }
    var scale: CGFloat { isPressed ? 0.99 : 1 }
}

/// All native full-width actions share this rendered body. Environment belongs
/// to the installed View, so the visual style inherits actual enabled and Reduce
/// Motion values rather than reading an uninstalled style.
struct LavaFullWidthActionButtonBody<Label: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.lavaActionWhiteOutline) private var usesWhiteOutline

    let role: LavaFullWidthActionState.Role
    let isPressed: Bool
    var cornerRadius: CGFloat = LavaSurface.controlCornerRadius
    let label: Label

    var body: some View {
        let state = LavaFullWidthActionState(role: role, isEnabled: isEnabled, isPressed: isPressed)
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let outlined = usesWhiteOutline && isEnabled
        label
            .font(LavaTypography.actionLabel)
            .foregroundStyle(outlined ? Color.white : state.foreground)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, LavaRowHeight.horizontalInset)
            .padding(.vertical, LavaRowHeight.verticalInset)
            .frame(maxWidth: .infinity)
            .frame(minHeight: LavaSurface.actionButtonHeight)
            .background {
                shape.fill(outlined ? Color.clear : state.fill)
                    .overlay { shape.fill(state.pressedOverlay).opacity(state.pressedOverlayOpacity) }
            }
            // An inset stroke preserves the filled button's exact outer geometry.
            .overlay { shape.strokeBorder(.white.opacity(outlined ? 1 : 0), lineWidth: 1.5) }
            .contentShape(shape)
            .scaleEffect(state.scale)
            .animation(LavaFlowTransition.incidental(.easeOut(duration: 0.12), reduceMotion: reduceMotion), value: state.isPressed)
    }
}

/// The primitive owner retains the native button's action and role; the private
/// visual style below still receives its native pressed state. This candidate
/// applies the FB18927179 workaround to Button itself, not its rendered label.
/// Direct placement needs runtime qualification: the label-only experiment
/// suppressed ordinary taps. https://developer.apple.com/forums/thread/763436
struct LavaFullWidthActionPrimitiveStyle: PrimitiveButtonStyle {
    let role: LavaFullWidthActionState.Role
    var cornerRadius: CGFloat = LavaSurface.controlCornerRadius

    func makeBody(configuration: Configuration) -> some View {
        Button(configuration)
            .buttonStyle(LavaFullWidthActionVisualStyle(role: role, cornerRadius: cornerRadius))
            .simultaneousGesture(TapGesture())
    }
}

private struct LavaFullWidthActionVisualStyle: ButtonStyle {
    let role: LavaFullWidthActionState.Role
    let cornerRadius: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        LavaFullWidthActionButtonBody(role: role, isPressed: configuration.isPressed,
                                     cornerRadius: cornerRadius, label: configuration.label)
    }
}

// Retain existing callers, including the isolated host's original Activity date sheet.
struct LavaStandaloneActionButtonStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        LavaFullWidthActionPrimitiveStyle(role: .primary).makeBody(configuration: configuration)
    }
}

/// Flat action-row feedback without multiplying opacity on already-secondary text.
/// Disabled actions stay inert and lose accent colour; their labels remain readable.
/// This foundation is shared by app rows and the isolated review host's setup atoms.
/// pinned: AccountSignInSourceTests.testNativeDisabledRowsRemainReadable
struct LavaCondensedRowButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .saturation(isEnabled ? 1 : 0)
            .opacity(isEnabled && configuration.isPressed ? 0.6 : 1)
    }
}

struct LavaPlainCard<Content: View>: View {
    let borderTint: Color?
    let content: Content

    init(borderTint: Color? = nil, @ViewBuilder content: () -> Content) {
        self.borderTint = borderTint
        self.content = content()
    }

    var body: some View {
        content
            .padding(LavaSpacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .lavaSurface(.card, borderTint: borderTint)
    }
}

/// Setup's technical steps share an open heading and a compact quiet surface.
/// Text grows naturally; no line clamps or shrink-to-fit on instructions.
struct LavaSetupStepLayout<Content: View>: View {
    let title: String
    var description: String? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: LavaSpacing.xl) {
            LavaSetupStepHeading(title: title, description: description)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(.top, LavaSpacing.lg)
    }
}

struct LavaSetupStepHeading: View {
    let title: String
    let description: String?

    var body: some View {
        VStack(alignment: .leading, spacing: LavaSpacing.md) {
            Text(title.lavaLocalized)
                .font(.title.bold())
                .foregroundStyle(LavaStyle.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            if let description { Text(description.lavaLocalized).lavaBodySupportingText() }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A choice is a full accessible row, not a tiny checkmark target. Its state
/// updates immediately; a longer translation never shifts the neighboring rows.
struct LavaSetupChoiceRow: View {
    let title: String
    var emoji: String? = nil
    let summary: LocalizedStringKey
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            LavaSelectableRow(state: selected ? .selected : .unselected) {
                VStack(alignment: .leading, spacing: LavaSpacing.xs) {
                    HStack(spacing: LavaSpacing.sm) {
                        if let emoji {
                            Text(emoji).lavaRowTitleText().accessibilityHidden(true)
                        }
                        Text(title.lavaLocalized).lavaRowTitleText().foregroundStyle(LavaStyle.primaryText)
                    }
                    Text(summary).lavaSupportingText()
                }
            }
        }
        .buttonStyle(LavaCondensedRowButtonStyle())
        .accessibilityElement(children: .combine)
        .accessibilityValue(Text(selected ? "On" : "Off"))
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// Illustrations explain the upcoming native prompt without impersonating its
/// controls. Permission requests have one real action in the setup footer.
struct LavaSetupPermissionIllustration: View {
    enum Kind: String, CaseIterable { case localProtection, notifications }
    let kind: Kind

    var body: some View {
        LavaPlainCard {
            ZStack {
                ForEach(Kind.allCases, id: \.self) { variant in
                    illustration(variant)
                        .opacity(kind == variant ? 1 : 0)
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("setup.permission-illustration.\(kind.rawValue)")
    }

    @ViewBuilder
    private func illustration(_ variant: Kind) -> some View {
        if variant == .localProtection {
            HStack(alignment: .top, spacing: LavaSpacing.sm) {
                endpoint("iphone", title: "Device")
                connector
                endpoint("lava", title: "Lava")
                connector
                endpoint("globe", title: "Internet")
            }
        } else {
            HStack(spacing: LavaSpacing.lg) {
                Image(systemName: "bell.badge")
                    .font(.system(size: LavaIconSize.hero, weight: .regular))
                    .foregroundStyle(LavaStyle.safeGreen)
                VStack(alignment: .leading, spacing: LavaSpacing.sm) {
                    Text("Lava").lavaRowTitleText()
                    Text("Connection updates").lavaSupportingText()
                    Text("Protection resumed").lavaSupportingText()
                }
            }
            .padding(.vertical, LavaSpacing.lg)
        }
    }

    private var connector: some View {
        Image(systemName: "arrow.right")
            .font(.system(size: LavaIconSize.small))
            .foregroundStyle(LavaStyle.secondaryText)
            .frame(height: LavaToolbarMetrics.buttonSize)
    }

    private func endpoint(_ image: String, title: String) -> some View {
        VStack(spacing: LavaSpacing.sm) {
            Group {
                if image == "lava" {
                    LavaGuardianShieldShape()
                        .fill(LavaStyle.safeGreen)
                        .frame(width: LavaIconSize.node, height: LavaIconSize.node)
                } else {
                    Image(systemName: image)
                        .font(.system(size: LavaIconSize.node, weight: .regular))
                        .foregroundStyle(LavaStyle.safeGreen)
                }
            }
            .frame(height: LavaToolbarMetrics.buttonSize)
            Text(title.lavaLocalized).lavaSupportingText()
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }
}


/// Native emoji input replaces one complete emoji at a time. Marked IME text
/// stays untouched until composition finishes; model validation remains the final guard.
struct LavaEmojiField: UIViewRepresentable {
    @Binding var value: String
    func makeCoordinator() -> Coordinator { Coordinator(value: $value) }
    func makeUIView(context: Context) -> UITextField {
        let field = EmojiTextField()
        field.accessibilityLabel = "Emoji".lavaLocalized
        field.accessibilityIdentifier = "filter.identity.emoji.input"
        field.font = .preferredFont(forTextStyle: .title2)
        field.adjustsFontForContentSizeCategory = true
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        return field
    }
    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.value = $value
        if field.markedTextRange == nil && field.text != value { field.text = value }
    }
    final class Coordinator: NSObject, UITextFieldDelegate {
        var value: Binding<String>
        init(value: Binding<String>) { self.value = value }
        @objc func changed(_ field: UITextField) {
            guard field.markedTextRange == nil else { return }
            let accepted = FilterIdentityPolicy.committedEmoji(field.text ?? "", fallback: value.wrappedValue)
            if field.text != accepted { field.text = accepted }
            value.wrappedValue = accepted
        }
        func textField(_ field: UITextField, shouldChangeCharactersIn range: NSRange, replacementString text: String) -> Bool {
            guard field.markedTextRange == nil, !text.isEmpty else { return true }
            // Keyboard/paste insertion is the new identity, regardless of cursor position.
            let replacement = FilterIdentityPolicy.committedEmoji(text, fallback: "")
            guard !replacement.isEmpty else { return true }
            field.text = replacement
            value.wrappedValue = replacement
            return false
        }
        func textFieldDidBeginEditing(_ field: UITextField) { field.selectAll(nil) }
    }
    private final class EmojiTextField: UITextField {
        override var textInputContextIdentifier: String? { "lava.filter.emoji" }
        override var textInputMode: UITextInputMode? {
            UITextInputMode.activeInputModes.first { $0.primaryLanguage == "emoji" } ?? super.textInputMode
        }
    }
}


/// Shared setup anatomy for Auto-switch and the DNS patch. Instructions and
/// their destination row share one panel, as on Explore.
struct LavaSetupSection<Actions: View>: View {
    let title: String
    var summary: String? = nil
    let steps: [String]
    var footer: String? = nil
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        LavaSectionGroup(title, footer: footer) {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: LavaSpacing.md) {
                    if let summary {
                        Text(summary.lavaLocalized)
                            .font(LavaTypography.rowMetadata)
                            .foregroundStyle(LavaStyle.primaryText)
                    }
                    ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .firstTextBaseline, spacing: LavaSpacing.md) {
                            Text("\(index + 1)")
                                .lavaRowTitleText()
                                .foregroundStyle(LavaStyle.safeGreen)
                                .frame(width: 22, height: 22)
                                .background(LavaStyle.softGreen, in: Circle())
                            Text(step.lavaLocalized)
                                .font(LavaTypography.rowMetadata)
                                .foregroundStyle(LavaStyle.primaryText)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(.horizontal, LavaSpacing.infoPanelHorizontalInset)
                .padding(.vertical, LavaSpacing.infoPanelVerticalInset)
                .frame(maxWidth: .infinity, alignment: .leading)
                actions()
            }
            .lavaPanelBackground()
        }
    }
}


/// Setup actions are rows inside the section's panel, below its instructions.
struct LavaSetupAction: View {
    let title: String
    var badge: LavaNavigationCardBadge? = nil
    var accessory: LavaNavigationCardAccessory = .externalLink
    var accessibilityHint: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            LavaNavigationCardLabel(badge: badge, badgeSize: LavaNavigationRowMetrics.glyphPointSize,
                rowSpacing: LavaSpacing.md, title: title, summary: .none, accessory: accessory)
        }
        .buttonStyle(LavaCondensedRowButtonStyle())
        .accessibilityHint((accessibilityHint ?? "").lavaLocalized)
    }
}

/// Shared custom-source form: grouped input fields, validation, then one full-width action.
/// Blocklist and DNS editors provide fields and draft submission without duplicating anatomy.
struct LavaCustomEntryForm<Fields: View, Notice: View>: View {
    let actionTitle: String
    let actionSymbol: String
    let enabled: Bool
    let submit: () -> Void
    @ViewBuilder let fields: () -> Fields
    @ViewBuilder let notice: () -> Notice

    var body: some View {
        VStack(spacing: 12) {
            LavaTextInputPanel { fields() }
            notice()
            Button(action: submit) { FilterActionLabel(title: actionTitle, systemImage: actionSymbol) }
                .buttonStyle(LavaStandaloneActionButtonStyle())
                .disabled(!enabled)
        }
    }
}

/// A settings control's title and optional subtitle share one wrapping label column.
struct LavaSettingsControlLabel: View {
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.lavaLocalized)
                .font(LavaTypography.rowTitle)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            if let subtitle {
                Text(subtitle.lavaLocalized).lavaRowSubtitleText()
            }
        }
    }
}

/// Terminal task success uses the same scalable circular checkmark across consumers.
struct LavaSuccessGlyph: View {
    @ScaledMetric(relativeTo: .title) private var size = LavaIconSize.heroResult

    var body: some View {
        Image(systemName: "checkmark.circle.fill")
            .font(.system(size: size, weight: .bold))
            .foregroundStyle(LavaStyle.safeGreen)
            .accessibilityHidden(true)
    }
}

/// Terminal bodies stay centered, with a shared scrolling fallback for enlarged text.
/// The host continues to own its pinned completion actions.
struct LavaCompletionLayout<Content: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ViewBuilder var content: Content

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                GeometryReader { geometry in
                    ScrollView {
                        content.frame(maxWidth: .infinity, minHeight: geometry.size.height)
                    }
                }
            } else {
                content.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

/// Shared terminal success page for backup and filter import. The enclosing sheet
/// supplies a non-scrolling flexible region and its pinned completion action.
struct LavaCompletionContent: View {
    let title: String
    let message: String
    @AccessibilityFocusState private var isHeadingFocused: Bool

    var body: some View {
        LavaCompletionLayout { completionContent }
            // Moving VoiceOver to the newly mounted heading announces this outcome once.
            .onAppear { isHeadingFocused = true }
    }

    private var completionContent: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 20)
            LavaSuccessGlyph()
            Text(title.lavaLocalized)
                .font(.title2.bold())
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocused($isHeadingFocused)
            Text(message.lavaLocalized)
                .lavaSupportingText()
                .multilineTextAlignment(.center)
            Spacer(minLength: 20)
        }
        .frame(maxWidth: .infinity)
    }
}

/// A primary explanation keeps semantic body text and compact, shared section gaps.
/// Dense table metadata and quiet supporting panels remain separate roles.
struct LavaPrimaryExplainer<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        LavaInfoCard { VStack(spacing: LavaSpacing.sm) { content } }
    }
}

/// Natural-size variants retain the largest caption and balance spare space on
/// both sides of shorter copy. Only the active explanation is accessible.
struct LavaExplainerVariants: View {
    let variants: [String]
    let selected: String
    var body: some View {
        ZStack {
            ForEach(variants, id: \.self) { caption in
                Text(caption.lavaLocalized).lavaBodySupportingText()
                    .multilineTextAlignment(.center).frame(maxWidth: .infinity)
                    .opacity(selected == caption ? 1 : 0)
                    .accessibilityHidden(selected != caption)
            }
        }
    }
}

/// An educational cycling control is a single labeled capsule, distinct from a
/// standalone toolbar glyph. Its widest translated label owns a stable width.
struct LavaCyclingExamplePill: View {
    let label: String
    let hint: String
    let value: String
    let values: [String]
    var warning = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: LavaSpacing.xs) {
                ZStack {
                    ForEach(values, id: \.self) { option in
                        Text(option.lavaLocalized).font(.body.weight(.semibold))
                            .opacity(option == value ? 1 : 0)
                    }
                }
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: LavaIconSize.inline, weight: .semibold))
                    .accessibilityHidden(true)
            }
            .foregroundStyle(warning ? LavaStyle.lavaOrangeText : LavaStyle.safeGreen)
            .padding(.horizontal, LavaSpacing.md).padding(.vertical, LavaSpacing.xs)
            .background(warning ? LavaStyle.lavaOrangeSoft : LavaStyle.softGreen, in: Capsule())
            .frame(minHeight: LavaToolbarMetrics.buttonSize)
        }
        .buttonStyle(LavaCondensedRowButtonStyle())
        .accessibilityLabel(Text(label.lavaLocalized))
        .accessibilityValue(Text(value.lavaLocalized))
        .accessibilityHint(Text(hint.lavaLocalized))
    }
}
