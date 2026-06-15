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

    func lavaQuietNoteText(horizontalPadding: CGFloat = 4) -> some View {
        font(.footnote)
            .foregroundStyle(LavaStyle.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, horizontalPadding)
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
    static let chevronIconPointSize: CGFloat = 22
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

struct NativeToolbarIconButton: View {
    let systemName: String
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            LavaToolbarIconSymbol(systemName: systemName)
                .frame(width: LavaToolbarMetrics.iconFrameSize, height: LavaToolbarMetrics.iconFrameSize)
        }
        .accessibilityLabel(accessibilityLabel)
    }
}

private struct LavaToolbarIconSymbol: View {
    @Environment(\.isEnabled) private var isEnabled

    let systemName: String

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: iconPointSize, weight: .semibold))
            .foregroundStyle(isEnabled ? LavaStyle.ink : LavaStyle.tertiaryText)
            .offset(y: iconVerticalOffset)
            .opacity(isEnabled ? 1 : 0.45)
            .accessibilityHidden(true)
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
