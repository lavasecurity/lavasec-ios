import SwiftUI
import LavaSecCore
import UIKit

enum LavaStyle {
    typealias RGB = (red: CGFloat, green: CGFloat, blue: CGFloat)

    static let safeGreen = adaptiveColor(
        light: (0.16, 0.47, 0.34),
        dark: (0.45, 0.86, 0.63)
    )
    static let safeControlGreen = adaptiveColor(
        light: (0.16, 0.47, 0.34),
        dark: (0.13, 0.50, 0.32)
    )
    static let softGreen = adaptiveColor(
        light: (0.91, 0.97, 0.94),
        dark: (0.10, 0.22, 0.17)
    )
    static let panelActionGreen = adaptiveColor(
        light: (0.12, 0.40, 0.28),
        dark: (0.45, 0.86, 0.63)
    )
    static let panelActionFill = adaptiveColor(
        light: (0.82, 0.93, 0.87),
        dark: (0.12, 0.29, 0.21)
    )
    static let panelActionPressedFill = adaptiveColor(
        light: (0.75, 0.88, 0.81),
        dark: (0.15, 0.35, 0.25)
    )
    static let quietControl = adaptiveColor(
        light: (0.38, 0.46, 0.42),
        dark: (0.22, 0.30, 0.26)
    )
    static let lavaOrange = adaptiveColor(
        light: (0.95, 0.34, 0.18),
        dark: (1.00, 0.54, 0.34)
    )
    static let lavaOrangeSoft = adaptiveColor(
        light: (1.00, 0.92, 0.86),
        dark: (0.30, 0.13, 0.08)
    )
    static let cream = adaptiveColor(
        light: (1.00, 0.98, 0.94),
        dark: (0.11, 0.10, 0.09)
    )
    static let ink = adaptiveColor(
        light: (0.13, 0.23, 0.20),
        dark: (0.92, 0.96, 0.93)
    )
    static let primaryText = Color(uiColor: .label)
    static let secondaryText = Color(uiColor: .secondaryLabel)
    static let tertiaryText = Color(uiColor: .tertiaryLabel)
    static let groupedBackground = adaptiveColor(
        light: (0.96, 0.98, 0.96),
        dark: (0.04, 0.07, 0.06)
    )
    static let cardBackground = adaptiveColor(
        light: (1.00, 1.00, 1.00),
        dark: (0.17, 0.17, 0.18)
    )
    static let panelBackground = adaptiveColor(
        light: (0.98, 1.00, 0.98),
        dark: (0.01, 0.05, 0.035)
    )
    static let panelStroke = adaptiveColor(
        light: (0.72, 0.86, 0.76),
        dark: (0.16, 0.32, 0.24)
    )
    static let guardianSleepGray = adaptiveColor(
        light: (0.67, 0.71, 0.69),
        dark: (0.36, 0.40, 0.38)
    )
    static let guardianFaceLight = adaptiveColor(
        light: (1.00, 0.98, 0.93),
        dark: (0.94, 0.98, 0.95)
    )

    private static func adaptiveColor(light: RGB, dark: RGB) -> Color {
        Color(uiColor: UIColor { traits in
            let rgb = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
        })
    }
}

enum LavaSurface {
    enum Role {
        case card
        case panel
        case selection(isSelected: Bool)
    }

    static let cardCornerRadius: CGFloat = 20
    static let compactCornerRadius: CGFloat = 16
    static let selectionCornerRadius: CGFloat = 12
    static let cardBackground = LavaStyle.cardBackground
    static let panelBackground = LavaStyle.panelBackground
    static let panelStroke = LavaStyle.panelStroke
    static let selectionBackground = cardBackground
    static let selectedSelectionBackground = LavaStyle.softGreen
}

struct LavaSurfaceBackground: ViewModifier {
    let role: LavaSurface.Role
    let cornerRadius: CGFloat
    let borderTint: Color?

    @ViewBuilder
    func body(content: Content) -> some View {
        switch role {
        case .card:
            content
                .background(LavaSurface.cardBackground, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        case .panel:
            content
                .background(LavaSurface.panelBackground, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(borderTint ?? LavaSurface.panelStroke, lineWidth: 1)
                }
        case .selection(let isSelected):
            content
                .background(
                    isSelected ? LavaSurface.selectedSelectionBackground : LavaSurface.selectionBackground,
                    in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                )
        }
    }
}

extension View {
    func lavaSurface(_ role: LavaSurface.Role, cornerRadius: CGFloat? = nil, borderTint: Color? = nil) -> some View {
        let resolvedCornerRadius: CGFloat
        switch role {
        case .card:
            resolvedCornerRadius = cornerRadius ?? LavaSurface.cardCornerRadius
        case .panel:
            resolvedCornerRadius = cornerRadius ?? LavaSurface.cardCornerRadius
        case .selection:
            resolvedCornerRadius = cornerRadius ?? LavaSurface.selectionCornerRadius
        }

        return modifier(LavaSurfaceBackground(role: role, cornerRadius: resolvedCornerRadius, borderTint: borderTint))
    }

    func lavaPanelBackground(cornerRadius: CGFloat = LavaSurface.cardCornerRadius, borderTint: Color? = nil) -> some View {
        lavaSurface(.panel, cornerRadius: cornerRadius, borderTint: borderTint)
    }

    func lavaListChrome() -> some View {
        scrollContentBackground(.hidden)
            .background(LavaStyle.groupedBackground)
    }

    func lavaListPanelRow() -> some View {
        listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }

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

struct LavaNavigationRow<Destination: View>: View {
    let systemImage: String?
    let title: String
    let summary: String
    let destination: Destination

    init(
        systemImage: String? = nil,
        title: String,
        summary: String,
        @ViewBuilder destination: () -> Destination
    ) {
        self.systemImage = systemImage
        self.title = title
        self.summary = summary
        self.destination = destination()
    }

    var body: some View {
        NavigationLink {
            destination
        } label: {
            HStack(spacing: 12) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.headline)
                        .foregroundStyle(LavaStyle.safeGreen)
                        .frame(width: 34, height: 34)
                        .background(LavaStyle.softGreen, in: RoundedRectangle(cornerRadius: 10))
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

struct LavaPanelActionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    let height: CGFloat
    let cornerRadius: CGFloat

    init(height: CGFloat = 38, cornerRadius: CGFloat = 10) {
        self.height = height
        self.cornerRadius = cornerRadius
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(LavaStyle.panelActionGreen)
            .lineLimit(1)
            .minimumScaleFactor(0.82)
            .frame(maxWidth: .infinity)
            .frame(height: height)
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
            .frame(height: 44)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(LavaStyle.safeControlGreen)
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.black.opacity(configuration.isPressed ? 0.10 : 0))
                    }
            }
            .scaleEffect(configuration.isPressed ? 0.99 : 1)
            .opacity(isEnabled ? 1 : 0.45)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
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

    var body: some View {
        LavaTextInputRow(title: title) {
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
    }
}

private enum ProtectionStatusMetrics {
    static let primaryActionMaxWidth: CGFloat = 300
    static let primaryActionHeight: CGFloat = 56
}

private enum LavaRootTab: Hashable {
    case guardPanel
    case filters
    case activity
    case settings

    var securityPolicy: SecurityAccessPolicy {
        switch self {
        case .guardPanel:
            return .readOnly
        case .filters:
            return .readOnly
        case .activity:
            return .requires(.activityViewing)
        case .settings:
            return .requires(.appSettings)
        }
    }

    var title: String {
        switch self {
        case .guardPanel:
            return "Guard"
        case .filters:
            return "Filters"
        case .activity:
            return "Activity"
        case .settings:
            return "Settings"
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @EnvironmentObject private var security: SecurityController
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("hasSeenLavaOnboarding") private var hasSeenLavaOnboarding = false
    @State private var didHandleDebugLaunchRageShake = false
    @State private var didRequestInitialAppUnlock = false
    @State private var selectedRootTab: LavaRootTab = .guardPanel
    @State private var settingsPath = [SettingsRoute]()
    @State private var rootTabScrollToTopRequests = [LavaRootTab: Int]()

    #if DEBUG
    private static let debugRageShakeLaunchArgument = "-lava-trigger-rage-shake"
    #endif

    var body: some View {
        TabView(selection: guardedRootTabSelection) {
            GuardView(
                scrollToTopTrigger: scrollToTopTrigger(for: .guardPanel),
                openFilters: {
                    security.resetViewAuthenticationTurn()
                    selectedRootTab = .filters
                },
                openDNSResolver: {
                    openSettingsRoute(.dnsResolver)
                }
            )
                .tabItem {
                    Label("Guard", systemImage: "shield.fill")
                }
                .tag(LavaRootTab.guardPanel)

            FiltersView(scrollToTopTrigger: scrollToTopTrigger(for: .filters))
                .tabItem {
                    Label("Filters", systemImage: "line.3.horizontal.decrease.circle")
                }
                .tag(LavaRootTab.filters)

            ActivityView(scrollToTopTrigger: scrollToTopTrigger(for: .activity))
                .tabItem {
                    Label("Activity", systemImage: "chart.bar.xaxis")
                }
                .tag(LavaRootTab.activity)

            SettingsView(path: $settingsPath, scrollToTopTrigger: scrollToTopTrigger(for: .settings))
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
                .tag(LavaRootTab.settings)
        }
        .tint(LavaStyle.safeGreen)
        .background(LavaStyle.groupedBackground)
        .preferredColorScheme(viewModel.preferredColorScheme)
        .overlay {
            RageShakeDetector {
                viewModel.handleRageShake()
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .overlay {
            if security.isAppUnlockBlockingUI && security.passcodeAuthenticationRequest == nil {
                SecurityLockOverlay {
                    Task {
                        await security.authenticateAppUnlockIfNeeded()
                    }
                }
            }
        }
        .overlay {
            if security.isAppUnlockPrivacyMaskVisible && !security.isAppUnlockBlockingUI {
                SecurityPrivacyMaskOverlay()
            }
        }
        .fullScreenCover(item: $security.passcodeAuthenticationRequest) { request in
            SecurityPasscodeAuthenticationView(request: request)
                .environmentObject(security)
        }
        .sheet(item: $viewModel.rageShakeDestination) { destination in
            switch destination {
#if DEBUG || LAVA_QA_TOOLS
            case .phoneQA:
                PhoneQASheetView(
                    showWelcome: {
                        viewModel.dismissRageShakeDestination()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                            hasSeenLavaOnboarding = false
                        }
                    },
                    showUserBugReport: {
                        viewModel.dismissRageShakeDestination()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                            viewModel.rageShakeDestination = .bugReport
                        }
                    }
                )
                    .onAppear {
                        debugLogRageShakeSheet("phoneQA")
                    }
#endif
            case .bugReport:
                BugReportSheetView()
                    .onAppear {
                        debugLogRageShakeSheet("bugReport")
                    }
            }
        }
        .sheet(
            isPresented: Binding(
                get: { !hasSeenLavaOnboarding },
                set: { isPresented in
                    if !isPresented {
                        hasSeenLavaOnboarding = true
                    }
                }
            )
        ) {
            LavaOnboardingView(hasSeenOnboarding: $hasSeenLavaOnboarding)
        }
        .onAppear {
            handleDebugLaunchRageShakeIfNeeded()
            viewModel.reconcileLiveActivity()
            guard !didRequestInitialAppUnlock else {
                return
            }

            didRequestInitialAppUnlock = true
            Task {
                await security.authenticateAppUnlockIfNeeded()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                security.hideAppUnlockPrivacyMask()
                viewModel.reconcileTemporaryProtectionPause()
                viewModel.reconcileLiveActivity()
                Task {
                    await viewModel.refreshProtectionStatus(force: true)
                    await security.authenticateAppUnlockIfNeeded()
                }
            case .inactive:
                security.showAppUnlockPrivacyMaskIfNeeded()
            case .background:
                security.lockForBackgroundIfNeeded()
            @unknown default:
                security.resetForegroundSession()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .lavaOpenGuardFromNotification)) { _ in
            hasSeenLavaOnboarding = true
            viewModel.dismissRageShakeDestination()
            settingsPath = []
            security.resetViewAuthenticationTurn()
            selectedRootTab = .guardPanel
        }
        .onReceive(NotificationCenter.default.publisher(for: .lavaOpenDeepLinkURL)) { notification in
            guard let url = notification.object as? URL else {
                return
            }

            if let deepLink = LavaAppDeepLink(url: url) {
                handleDeepLink(deepLink)
            }
        }
    }

    private var guardedRootTabSelection: Binding<LavaRootTab> {
        Binding {
            selectedRootTab
        } set: { nextTab in
            guard nextTab != selectedRootTab else {
                requestRootTabScrollToTop(nextTab)
                return
            }

            security.resetViewAuthenticationTurn()

            // Switch synchronously when the tab needs no auth gate (Guard/Filters
            // are .readOnly; Activity is intentionally ungated). Routing every
            // switch through an async Task makes the TabView selection lag the tap
            // by a frame — the tapped tab flashes in, snaps back to the old tab,
            // then settles — which is the Upgrade↔Guard flicker. Only auth-gated
            // tabs (Settings) need the async authentication round-trip.
            if nextTab == .activity || nextTab.securityPolicy.requiredSurface == nil {
                selectedRootTab = nextTab
                return
            }

            Task {
                await selectRootTab(nextTab)
            }
        }
    }

    private func selectRootTab(_ tab: LavaRootTab) async {
        guard await canAccess(tab.securityPolicy, reason: "Open \(tab.title)") else {
            return
        }

        selectedRootTab = tab
    }

    private func openSettingsRoute(_ route: SettingsRoute) {
        Task {
            security.resetViewAuthenticationTurn()

            guard await canAccess(SettingsRoute.settingsTabPolicy, reason: "Open Settings"),
                  await canAccess(route.securityPolicy, reason: route.securityReason)
            else {
                return
            }

            settingsPath = [route]
            selectedRootTab = .settings
        }
    }

    private func openSettingsRoot() {
        Task {
            security.resetViewAuthenticationTurn()

            guard await canAccess(SettingsRoute.settingsTabPolicy, reason: "Open Settings") else {
                return
            }

            settingsPath = []
            selectedRootTab = .settings
        }
    }

    private func handleDeepLink(_ deepLink: LavaAppDeepLink) {
        hasSeenLavaOnboarding = true
        viewModel.dismissRageShakeDestination()
        security.resetViewAuthenticationTurn()

        switch deepLink {
        case .guardPanel:
            settingsPath = []
            selectedRootTab = .guardPanel
        case .filters:
            settingsPath = []
            Task {
                await selectRootTab(.filters)
            }
        case .activity:
            settingsPath = []
            Task {
                await selectRootTab(.activity)
            }
        case .settings(let settingsRoute):
            guard let settingsRoute else {
                openSettingsRoot()
                return
            }

            guard let route = SettingsRoute(settingsRoute) else {
                return
            }

            openSettingsRoute(route)
        }
    }

    private func performLiveActivityActionRequest(_ request: LavaLiveActivityActionRequest) {
        Task {
            security.resetViewAuthenticationTurn()

            if request == .resume || request == .reconnect {
                viewModel.performLiveActivityActionRequest(request)
                viewModel.reconcileLiveActivity()
                return
            }

            guard await security.requireFreshAuthentication(
                for: .protectionPause,
                reason: request.authenticationReason
            ) else {
                return
            }

            viewModel.performLiveActivityActionRequest(request)
            viewModel.reconcileLiveActivity()
        }
    }

    private func canAccess(_ policy: SecurityAccessPolicy, reason: String) async -> Bool {
        guard let surface = policy.requiredSurface else {
            return true
        }

        return await security.requireAuthentication(for: surface, reason: reason)
    }

    private func requestRootTabScrollToTop(_ tab: LavaRootTab) {
        rootTabScrollToTopRequests[tab, default: 0] += 1
    }

    private func scrollToTopTrigger(for tab: LavaRootTab) -> Int {
        rootTabScrollToTopRequests[tab, default: 0]
    }

    private func handleDebugLaunchRageShakeIfNeeded() {
        #if DEBUG
        guard !didHandleDebugLaunchRageShake,
              ProcessInfo.processInfo.arguments.contains(Self.debugRageShakeLaunchArgument)
        else {
            return
        }

        didHandleDebugLaunchRageShake = true
        hasSeenLavaOnboarding = true
        viewModel.handleRageShake()
        if let destination = viewModel.rageShakeDestination {
            print("LAVA_RAGE_SHAKE_DESTINATION \(destination.id)")
        }
        #endif
    }

    private func debugLogRageShakeSheet(_ destination: String) {
        #if DEBUG
        guard ProcessInfo.processInfo.arguments.contains(Self.debugRageShakeLaunchArgument) else {
            return
        }

        print("LAVA_RAGE_SHAKE_SHEET_VISIBLE \(destination)")
        #endif
    }
}

private extension SettingsRoute {
    init?(_ deepLink: LavaSettingsDeepLink) {
        switch deepLink {
        case .account:
            self = .account
        case .upgrade:
            self = .upgrade
        case .dnsResolver:
            self = .dnsResolver
        case .privacyData:
            self = .privacyData
        case .security:
            self = .security
        case .feedback:
            self = .bugReport
        case .legalNotices:
            self = .legalNotices
        case .nerdStats:
            self = .versionNerdStats
        }
    }
}

private struct BugReportSheetView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var isReportDirty = false

    var body: some View {
        NavigationStack {
            BugReportSettingsView(
                isReportDirty: $isReportDirty,
                onDismissRequested: canRequestDismiss
            )
        }
        .interactiveDismissDisabled(isReportDirty)
    }

    private func canRequestDismiss() {
        dismiss()
    }
}

struct GuardView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    let scrollToTopTrigger: Int
    let refreshesProtectionState: Bool
    let openFilters: () -> Void
    let openDNSResolver: () -> Void

    init(
        scrollToTopTrigger: Int = 0,
        refreshesProtectionState: Bool = true,
        openFilters: @escaping () -> Void = {},
        openDNSResolver: @escaping () -> Void = {}
    ) {
        self.scrollToTopTrigger = scrollToTopTrigger
        self.refreshesProtectionState = refreshesProtectionState
        self.openFilters = openFilters
        self.openDNSResolver = openDNSResolver
    }

    var body: some View {
        NavigationStack {
            LavaPrimaryTabScreenContent(
                title: "Guard",
                scrollToTopTrigger: scrollToTopTrigger
            ) {
                ProtectionStatusPanel()
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
            } content: {
                GuardProtectionFlowPanel(
                    openDNSResolver: openDNSResolver,
                    openFilters: openFilters
                )
            }
            .task {
                guard refreshesProtectionState else {
                    return
                }

                await refreshGuardProtectionState()

                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    guard !Task.isCancelled else {
                        return
                    }

                    await refreshGuardProtectionState()
                }
            }
        }
    }

    private func refreshGuardProtectionState() async {
        viewModel.refreshDiagnostics()
        await viewModel.refreshProtectionStatus()
        await viewModel.sampleTunnelHealth()
    }
}

struct ProtectionStatusPanel: View {
    @EnvironmentObject private var viewModel: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 16) {
                SoftShieldGuardian(size: 96, state: guardianState, shieldStyle: viewModel.lavaGuardLook)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Lava Security")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(LavaStyle.lavaOrange)

                    Text(viewModel.protectionTitle.lavaLocalized)
                        .font(.title.bold())
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)

                    Text(viewModel.protectionSubtitle.lavaLocalized)
                        .lavaBodySupportingText()
                }
            }

            ProtectionPrimaryActionButton()

            if let message = viewModel.guardPanelMessage {
                Text(message.lavaLocalized)
                    .font(.footnote)
                    .foregroundStyle(viewModel.guardPanelMessageIsError ? .red : LavaStyle.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }

        }
        .padding(18)
        .lavaPanelBackground()
    }

    private var guardianState: GuardianMascotState {
        if viewModel.isProtectionTemporarilyPaused {
            return .paused
        }

        switch viewModel.vpnStatus {
        case .connected:
            switch viewModel.protectionConnectivitySeverity {
            case .healthy, .usingDeviceDNSFallback:
                return .awake
            case .recovering, .networkUnavailable:
                return .retrying
            case .dnsSlow, .needsReconnect:
                return .concerned
            }
        case .connecting, .reasserting:
            return .waking
        default:
            return .sleeping
        }
    }
}

private struct ProtectionPrimaryActionButton: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @EnvironmentObject private var security: SecurityController

    var body: some View {
        VStack(spacing: 10) {
            Button {
                Task {
                    if viewModel.isProtectionTemporarilyPaused {
                        viewModel.resumeProtectionNow()
                        return
                    }

                    guard await security.requireFreshAuthentication(
                        for: .protectionControl,
                        reason: "Change Lava protection"
                    ) else {
                        return
                    }

                    viewModel.performProtectionPrimaryAction()
                }
            } label: {
                actionLabel
            }
            .buttonStyle(.borderedProminent)
            .tint(viewModel.protectionButtonTint)
            .disabled(viewModel.protectionPrimaryActionIsDisabled)
            .accessibilityHint("Controls Lava's local DNS protection.".lavaLocalized)
            .frame(maxWidth: ProtectionStatusMetrics.primaryActionMaxWidth)
            .contextMenu {
                if viewModel.showsTemporaryProtectionPauseControls {
                    ForEach(ProtectionPauseDuration.allCases) { option in
                        Button(option.label.lavaLocalized) {
                            Task {
                                guard await security.requireFreshAuthentication(
                                    for: .protectionPause,
                                    reason: "Pause Lava protection"
                                ) else {
                                    return
                                }

                                viewModel.pauseProtectionTemporarily(for: option)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var actionLabel: some View {
        HStack(spacing: 8) {
            if viewModel.isConfiguringVPN {
                ProgressView()
            }

            VStack(spacing: 2) {
                Text(viewModel.protectionButtonTitle.lavaLocalized)
                    .font(.title3.bold())

                if viewModel.showsTemporaryProtectionPauseControls {
                    Text("Long-press for pause options".lavaLocalized)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: ProtectionStatusMetrics.primaryActionHeight)
    }
}

private struct GuardProtectionFlowPanel: View {
    @EnvironmentObject private var viewModel: AppViewModel
    let openDNSResolver: () -> Void
    let openFilters: () -> Void

    var body: some View {
        LavaInfoCard {
            VStack(alignment: .leading, spacing: 0) {
                GuardFlowStepRow(
                    systemImage: "globe",
                    title: "Internet",
                    status: viewModel.guardEndpointFlowStepStatus
                )

                GuardFlowConnectorRow(
                    upperStatus: viewModel.guardEndpointFlowStepStatus,
                    lowerStatus: viewModel.guardDNSFlowStepStatus
                )

                GuardFlowStepRow(
                    systemImage: "network",
                    title: "DNS",
                    detail: viewModel.guardDNSFlowStepDetailComponents.name,
                    detailSuffix: viewModel.guardDNSFlowStepDetailComponents.transportAnnotation,
                    status: viewModel.guardDNSFlowStepStatus,
                    action: openDNSResolver,
                    accessibilityLabel: "Open DNS Resolver settings"
                )

                GuardFlowConnectorRow(
                    upperStatus: viewModel.guardDNSFlowStepStatus,
                    lowerStatus: viewModel.guardFilterFlowStepStatus
                )

                GuardFlowStepRow(
                    systemImage: "line.3.horizontal.decrease.circle.fill",
                    title: "Local filters",
                    detail: filterStatus,
                    status: viewModel.guardFilterFlowStepStatus,
                    action: openFilters,
                    accessibilityLabel: "Open Filters"
                )

                GuardFlowConnectorRow(
                    upperStatus: viewModel.guardFilterFlowStepStatus,
                    lowerStatus: viewModel.guardEndpointFlowStepStatus
                )

                GuardFlowStepRow(
                    systemImage: "iphone",
                    title: "Phone",
                    status: viewModel.guardEndpointFlowStepStatus
                )
            }
        }
    }

    private var filterStatus: String {
        viewModel.configuration.enabledBlocklistIDs.isEmpty && viewModel.configuration.blockedDomains.isEmpty
            ? "Not configured"
            : "Configured"
    }
}

private enum GuardFlowMetrics {
    static let iconSize: CGFloat = 38
    static let chevronSlotSize: CGFloat = 30
    static let horizontalSpacing: CGFloat = 12
    static let rowMinimumHeight: CGFloat = 42
    static let connectorWidth: CGFloat = 2
    static let connectorLineHeight: CGFloat = 12
    static let connectorVerticalInset: CGFloat = 3
    static let connectorHorizontalInset: CGFloat = (iconSize - connectorWidth) / 2
}

private struct GuardFlowStepRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let systemImage: String
    let title: String
    var detail: String?
    // Rendered as a non-truncating suffix so a long detail (custom resolver
    // names) can truncate without losing the transport annotation.
    var detailSuffix: String?
    var status: GuardFlowStepStatus = .healthy
    var action: (() -> Void)?
    var accessibilityLabel: String?

    var body: some View {
        if let action {
            Button(action: action) {
                rowContent(showsChevron: true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel((accessibilityLabel ?? "Open \(title)").lavaLocalized)
        } else {
            rowContent(showsChevron: false)
        }
    }

    private func rowContent(showsChevron: Bool) -> some View {
        let palette = GuardFlowStepPalette(status: status)
        let statusAnimation = GuardFlowAnimation.statusColor(for: status, reduceMotion: reduceMotion)

        return HStack(spacing: GuardFlowMetrics.horizontalSpacing) {
            Image(systemName: systemImage)
                .font(.headline.weight(.semibold))
                .foregroundStyle(palette.iconTint)
                .frame(width: GuardFlowMetrics.iconSize, height: GuardFlowMetrics.iconSize)
                .background(palette.iconBackground, in: Circle())
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 0) {
                    Text(labelText)
                        .font(.headline)
                        .foregroundStyle(palette.titleForeground)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .minimumScaleFactor(0.85)
                        .fixedSize(horizontal: false, vertical: true)

                    if let detailSuffix {
                        Text(" (\(detailSuffix))")
                            .font(.headline)
                            .foregroundStyle(palette.titleForeground)
                            .lineLimit(1)
                            .layoutPriority(1)
                    }
                }
            }

            Spacer(minLength: 8)

            chevronSlot(showsChevron: showsChevron)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: GuardFlowMetrics.rowMinimumHeight)
        .contentShape(Rectangle())
        .animation(statusAnimation, value: status)
    }

    @ViewBuilder
    private func chevronSlot(showsChevron: Bool) -> some View {
        ZStack {
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(LavaStyle.safeGreen)
                    .frame(width: GuardFlowMetrics.chevronSlotSize, height: GuardFlowMetrics.chevronSlotSize)
                    .background(LavaStyle.softGreen, in: Circle())
            }
        }
        .frame(width: GuardFlowMetrics.chevronSlotSize, height: GuardFlowMetrics.chevronSlotSize)
        .accessibilityHidden(true)
    }

    private var labelText: String {
        guard let detail else {
            return title.lavaLocalized
        }

        return "\(title.lavaLocalized): \(detail.lavaLocalized)"
    }
}

private enum GuardFlowAnimation {
    static func statusColor(for status: GuardFlowStepStatus, reduceMotion: Bool) -> Animation? {
        guard !reduceMotion else {
            return nil
        }

        let duration = status == .healthy
            ? GuardianMascotAnimationPlan.wakeDuration
            : GuardianMascotAnimationPlan.stateChangeDuration
        return .easeInOut(duration: duration)
    }
}

private struct GuardFlowStepPalette {
    let iconTint: Color
    let iconBackground: Color
    let titleForeground: Color
    let connectorFill: Color

    init(status: GuardFlowStepStatus) {
        switch status {
        case .healthy:
            iconTint = LavaStyle.safeGreen
            iconBackground = LavaStyle.softGreen
            titleForeground = LavaStyle.ink
            connectorFill = LavaStyle.safeGreen.opacity(0.35)
        case .inactive:
            iconTint = LavaStyle.secondaryText
            iconBackground = LavaStyle.secondaryText.opacity(0.12)
            titleForeground = LavaStyle.secondaryText
            connectorFill = LavaStyle.secondaryText.opacity(0.24)
        case .issue:
            iconTint = LavaStyle.lavaOrange
            iconBackground = LavaStyle.lavaOrangeSoft
            titleForeground = LavaStyle.secondaryText
            connectorFill = LavaStyle.lavaOrange.opacity(0.35)
        }
    }
}

private struct GuardFlowConnectorRow: View {
    // A connector joins the step above it to the step below it. It reads red
    // when a neighbor has an issue (a red step turns the bar above AND below it
    // red), grey only when both neighbors are inactive (protection off), and
    // green otherwise — a lone inactive step is a passthrough that still carries
    // traffic, so its bars stay green.
    let upperStatus: GuardFlowStepStatus
    let lowerStatus: GuardFlowStepStatus

    private var status: GuardFlowStepStatus {
        GuardFlowStepStatus.linkStatus(upperStatus, lowerStatus)
    }

    var body: some View {
        let palette = GuardFlowStepPalette(status: status)

        return HStack(alignment: .top, spacing: GuardFlowMetrics.horizontalSpacing) {
            Rectangle()
                .fill(palette.connectorFill)
                .frame(width: GuardFlowMetrics.connectorWidth, height: GuardFlowMetrics.connectorLineHeight)
                .padding(.leading, GuardFlowMetrics.connectorHorizontalInset)
                .padding(.trailing, GuardFlowMetrics.connectorHorizontalInset)
                .padding(.vertical, GuardFlowMetrics.connectorVerticalInset)
                .accessibilityHidden(true)

            Spacer(minLength: 8)

            Color.clear
                .frame(width: GuardFlowMetrics.chevronSlotSize, height: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: GuardFlowMetrics.connectorLineHeight + (GuardFlowMetrics.connectorVerticalInset * 2), alignment: .top)
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
        .background(LavaStyle.softGreen, in: RoundedRectangle(cornerRadius: 14))
    }
}

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

enum WebsiteAssetCaptureState: String {
    case protected
    case wake
}

struct WebsiteAssetCaptureConfiguration {
    let state: WebsiteAssetCaptureState

    static let launchArgument = "-lava-website-asset-capture"
    private static let stateArgument = "-lavaWebsiteCaptureState"

    static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains(launchArgument)
    }

    static var current: WebsiteAssetCaptureConfiguration {
        WebsiteAssetCaptureConfiguration(state: requestedState)
    }

    private static var requestedState: WebsiteAssetCaptureState {
        let arguments = ProcessInfo.processInfo.arguments
        guard let stateIndex = arguments.firstIndex(of: stateArgument),
              arguments.indices.contains(arguments.index(after: stateIndex))
        else {
            return .protected
        }

        return WebsiteAssetCaptureState(rawValue: arguments[arguments.index(after: stateIndex)]) ?? .protected
    }
}

struct WebsiteAssetCaptureRootView: View {
    let configuration: WebsiteAssetCaptureConfiguration

    @StateObject private var viewModel = AppViewModel.websiteAssetCapturePreview()
    @StateObject private var security = SecurityController()
    @State private var didStartSequence = false

    var body: some View {
        TabView(selection: .constant(LavaRootTab.guardPanel)) {
            GuardView(refreshesProtectionState: false)
                .tabItem {
                    Label("Guard", systemImage: "shield.fill")
                }
                .tag(LavaRootTab.guardPanel)

            Color.clear
                .tabItem {
                    Label("Filters", systemImage: "line.3.horizontal.decrease.circle")
                }
                .tag(LavaRootTab.filters)

            Color.clear
                .tabItem {
                    Label("Activity", systemImage: "chart.bar.xaxis")
                }
                .tag(LavaRootTab.activity)

            Color.clear
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
                .tag(LavaRootTab.settings)
        }
        .tint(LavaStyle.safeGreen)
        .background(LavaStyle.groupedBackground)
        .preferredColorScheme(.light)
        .environmentObject(viewModel)
        .environmentObject(security)
        .onAppear {
            startCaptureStateIfNeeded()
        }
    }

    private func startCaptureStateIfNeeded() {
        guard !didStartSequence else {
            return
        }

        didStartSequence = true

        switch configuration.state {
        case .protected:
            viewModel.applyWebsiteAssetCaptureProtectionState(.protected)
        case .wake:
            viewModel.applyWebsiteAssetCaptureProtectionState(.off)
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 700_000_000)
                guard !Task.isCancelled else {
                    return
                }

                viewModel.applyWebsiteAssetCaptureProtectionState(.waking)
                let wakeDuration = UInt64((GuardianMascotAnimationPlan.wakeDuration + 0.12) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: wakeDuration)
                guard !Task.isCancelled else {
                    return
                }

                viewModel.applyWebsiteAssetCaptureProtectionState(.protected)
            }
        }
    }
}
#endif

struct LavaInfoCard<Content: View>: View {
    let content: Content
    let borderTint: Color?

    init(borderTint: Color? = nil, @ViewBuilder content: () -> Content) {
        self.borderTint = borderTint
        self.content = content()
    }

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .lavaPanelBackground(cornerRadius: 20, borderTint: borderTint)
    }
}

struct LavaTabOverviewCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        LavaInfoCard {
            content
                .frame(height: 262, alignment: .center)
        }
    }
}

struct LavaOverviewMetricBlock: View {
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 42, weight: .bold, design: .rounded))
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
        LavaInfoCard(borderTint: borderTint) {
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

struct GentleProtectionDiagram: View {
    @EnvironmentObject private var viewModel: AppViewModel

    let blockedText: String
    let allowedText: String
    let isCompact: Bool

    init(blockedText: String, allowedText: String, isCompact: Bool = false) {
        self.blockedText = blockedText
        self.allowedText = allowedText
        self.isCompact = isCompact
    }

    var body: some View {
        VStack(spacing: isCompact ? 10 : 14) {
            HStack(spacing: isCompact ? 12 : 16) {
                DiagramEndpoint(
                    systemImage: "iphone",
                    title: "Phone",
                    tint: LavaStyle.safeGreen,
                    isCompact: isCompact
                )

                SoftShieldGuardian(
                    size: isCompact ? 54 : 62,
                    state: .awake,
                    animates: false,
                    shieldStyle: viewModel.lavaGuardLook
                )

                DiagramEndpoint(
                    systemImage: "globe",
                    title: "Internet",
                    tint: .teal,
                    isCompact: isCompact
                )
            }

            VStack(spacing: isCompact ? 6 : 8) {
                DiagramPathRow(
                    systemImage: "hand.raised.fill",
                    text: blockedText,
                    tint: LavaStyle.lavaOrange,
                    isCompact: isCompact
                )
                DiagramPathRow(
                    systemImage: "arrow.right.circle.fill",
                    text: allowedText,
                    tint: LavaStyle.safeGreen,
                    isCompact: isCompact
                )
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(blockedText). \(allowedText).")
    }
}

private struct DiagramEndpoint: View {
    let systemImage: String
    let title: String
    let tint: Color
    let isCompact: Bool

    var body: some View {
        VStack(spacing: isCompact ? 4 : 6) {
            Image(systemName: systemImage)
                .font(.system(size: isCompact ? 25 : 30, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: isCompact ? 46 : 54, height: isCompact ? 46 : 54)
                .background(tint.opacity(0.12), in: Circle())

            Text(title.lavaLocalized)
                .font(.caption.weight(.semibold))
                .foregroundStyle(LavaStyle.secondaryText)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct DiagramPathRow: View {
    let systemImage: String
    let text: String
    let tint: Color
    let isCompact: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(tint)
                .frame(width: 24)

            Text(text)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(LavaStyle.ink)
                .lineLimit(2)
                .minimumScaleFactor(0.82)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: isCompact ? 34 : 38)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
    }
}

#Preview {
    RootView()
        .environmentObject(AppViewModel(loadVPNState: false))
}

#if DEBUG
private struct ProtectionStatusPreviewCase: Identifiable {
    let id: String
    let label: String
    let health: TunnelHealthSnapshot

    static func all(now: Date = Date()) -> [ProtectionStatusPreviewCase] {
        [
            ProtectionStatusPreviewCase(
                id: "protected",
                label: "Protected",
                health: TunnelHealthSnapshot()
            ),
            ProtectionStatusPreviewCase(
                id: "recovering",
                label: "Network Changed",
                health: TunnelHealthSnapshot(
                    lastNetworkChangeAt: now.addingTimeInterval(-5),
                    lastResolverRuntimeResetAt: now.addingTimeInterval(-4),
                    resolverRuntimeResetCount: 1
                )
            ),
            ProtectionStatusPreviewCase(
                id: "device-dns",
                label: "Device DNS Fallback",
                health: TunnelHealthSnapshot(
                    lastDNSSmokeProbeAt: now.addingTimeInterval(-4),
                    lastDNSSmokeProbeSucceeded: false,
                    dnsSmokeProbeFailureCount: 1,
                    lastDeviceDNSFallbackActivatedAt: now.addingTimeInterval(-3),
                    deviceDNSFallbackActivationCount: 1,
                    lastNetworkChangeAt: now.addingTimeInterval(-5)
                )
            ),
            ProtectionStatusPreviewCase(
                id: "network-lost",
                label: "Network Lost",
                health: TunnelHealthSnapshot(
                    networkPathIsSatisfied: false,
                    lastNetworkChangeAt: now.addingTimeInterval(-5),
                    networkChangeCount: 1
                )
            ),
            ProtectionStatusPreviewCase(
                id: "reconnect",
                label: "Reconnect Needed",
                health: TunnelHealthSnapshot(
                    lastDNSSmokeProbeAt: now.addingTimeInterval(-3),
                    lastDNSSmokeProbeSucceeded: false,
                    dnsSmokeProbeFailureCount: 1,
                    lastNetworkChangeAt: now.addingTimeInterval(-5)
                )
            )
        ]
    }
}

#Preview("Protection States") {
    ScrollView {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(ProtectionStatusPreviewCase.all()) { previewCase in
                VStack(alignment: .leading, spacing: 8) {
                    Text(previewCase.label)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(LavaStyle.secondaryText)

                    ProtectionStatusPanel()
                        .environmentObject(AppViewModel.previewProtectionState(health: previewCase.health))
                }
            }
        }
        .padding()
    }
    .background(LavaStyle.groupedBackground)
}
#endif
