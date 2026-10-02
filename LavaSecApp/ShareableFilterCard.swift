import SwiftUI
import UIKit
import LavaSecKit

// MARK: - Payload summary

/// What a share card may say about its own contents.
///
/// Counts come from the decoded payload. The sender's library name is excluded;
/// user-controlled domains and source definitions remain visible in import review.
///
/// These describe what the CARD CONTAINS, not what the recipient will end up with.
/// The card is rendered on the sender's device and knows nothing about the
/// recipient's tier, so reconciliation may drop items on import. Only the review
/// screen may state what will actually apply — card copy says "contains".
struct ShareableFilterCardSummary: Equatable {
    let blocklistCount: Int
    let blockedDomainCount: Int
    let customListCount: Int
    let allowedDomainCount: Int

    init(configuration: ShareableFilterConfiguration) {
        // `enabledBlocklistIDs` carries custom-source ids alongside curated ones
        // (see ShareableFilterConfiguration.init(configuration:)), so subtract them
        // out rather than double-counting a custom list as a curated blocklist.
        let customIDs = Set(configuration.customBlocklists.map(\.id))
        self.blocklistCount = configuration.enabledBlocklistIDs.subtracting(customIDs).count
        self.customListCount = configuration.customBlocklists.count
        self.blockedDomainCount = configuration.blockedDomains.count
        self.allowedDomainCount = configuration.allowedDomains?.count ?? 0
    }

    /// Chip labels, in display order. Zero-valued entries are omitted so a simple
    /// share doesn't advertise "0 blocked sites".
    ///
    /// The custom-list chip is deliberately never suppressed when present: a custom
    /// source identifies a sender-chosen URL that the recipient may enable. Both
    /// enabled and stored disabled definitions count toward the shared contents.
    var chipLabels: [String] {
        var labels: [String] = []
        if blocklistCount > 0 {
            labels.append(
                (blocklistCount == 1 ? "%@ blocklist" : "%@ blocklists")
                    .lavaLocalizedFormat(blocklistCount.formatted())
            )
        }
        if blockedDomainCount > 0 {
            labels.append(
                (blockedDomainCount == 1 ? "%@ blocked site" : "%@ blocked sites")
                    .lavaLocalizedFormat(blockedDomainCount.formatted())
            )
        }
        if customListCount > 0 {
            labels.append(
                (customListCount == 1 ? "%@ custom list" : "%@ custom lists")
                    .lavaLocalizedFormat(customListCount.formatted())
            )
        }
        if allowedDomainCount > 0 {
            labels.append((allowedDomainCount == 1 ? "%@ allowed site" : "%@ allowed sites").lavaLocalizedFormat(allowedDomainCount.formatted()))
        }
        return labels
    }
}

// MARK: - Card

/// The recipient-facing share card.
///
/// Rendered to a deterministic PNG and shared as an ordinary image attachment, so
/// it has to survive being recompressed and rescaled by whatever messenger carries
/// it. Everything below serves that: fixed light colours regardless of the sender's
/// appearance setting, a solid white field behind the code, no gradient, overlay,
/// or logo anywhere inside the quiet zone, and nearest-neighbour interpolation so
/// modules stay square-edged instead of being smoothed into each other.
struct ShareableFilterCard: View {
    let qrImage: UIImage
    let summary: ShareableFilterCardSummary

    // Export branding uses the canonical light orange, including the wordmark.
    // Keep the palette fixed so the PNG is identical in either appearance.
    private static let ember = Color(red: 0.95, green: 0.34, blue: 0.18)
    private static let ink = Color(red: 0.08, green: 0.07, blue: 0.06)
    private static let body = Color(red: 0.37, green: 0.35, blue: 0.32)
    // Quiet, but legible. At the previous #948C85 the provenance line measured only
    // ~3.1:1 on white — under WCAG AA's 4.5:1 for normal text, and in practice hard
    // to read at 8pt. A provenance disclosure that cannot be read is not a
    // disclosure; #6B635C reaches ~5.9:1 while staying clearly quieter than the
    // instruction lines above it.
    private static let fine = Color(red: 0.42, green: 0.388, blue: 0.36)
    private static let separator = Color(red: 0.81, green: 0.78, blue: 0.75)
    private static let chipFill = Color(red: 0.957, green: 0.941, blue: 0.922)
    private static let chipInk = Color(red: 0.33, green: 0.30, blue: 0.28)

    /// Equal breathing room above the title block and below the last instruction,
    /// so the middle section reads as optically centred rather than top-anchored.
    private static let balancedGap: CGFloat = 14

    var body: some View {
        VStack(spacing: 0) {
            // The full-width ember bar became a rule: it keeps the brand's colour at
            // the top edge while returning ~40pt of height to the code.
            Self.ember
                .frame(height: 4)

            VStack(spacing: 0) {
                header
                    .padding(.top, 8)


                // No ad-hoc gap above or below: `qrField` owns the whole vertical
                // clear space, so a later tidy-up of a spacing constant cannot
                // silently eat into the quiet zone the code depends on.
                qrField

                Text("Scan to import — or to get Lava first".lavaLocalized)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Self.ink)
                    .multilineTextAlignment(.center)

                Text("New? Install, finish setup, then scan again.".lavaLocalized)
                    .font(.system(size: 9.5))
                    .foregroundStyle(Self.body)
                    .multilineTextAlignment(.center)
                    .padding(.top, 4)

                Color.clear.frame(height: Self.balancedGap)

                // Quiet by design. The claim must always be present and must never be
                // dressed up as an alarm — a friend's legitimate share should not read
                // as a scam warning. The importer's review screen carries the weight.
                Text("Shared by another person. Not reviewed by Lava Security.".lavaLocalized)
                    .font(.system(size: 8))
                    .foregroundStyle(Self.fine)
                    .multilineTextAlignment(.center)
                    .padding(.bottom, 7)
            }
            .padding(.horizontal, ShareableFilterCardRenderer.horizontalMargin)
        }
        .frame(
            width: ShareableFilterCardRenderer.pointSize.width,
            height: ShareableFilterCardRenderer.pointSize.height,
            // TOP, not the default centre. The code is capped at `maximumQRSide`, so
            // when the fixed rows come out shorter than the tallest locale the content's
            // natural height is UNDER 450 — and a centring frame then splits that slack
            // above the ember bar and below the provenance line. On a zh-Hant device
            // render that showed as a white strip above the bar, which is meant to bleed
            // to the edge. Anchoring top puts all remaining slack at the bottom, inside
            // the white field where it is invisible.
            // pinned: SharedFilterImportSourceTests.testCardAnchorsContentToTheTopEdge
            alignment: .top
        )
        .background(.white)
    }

    /// Static brand export: a two-line header stays inside the original header budget.
    private var header: some View {
        // Preserve the previous title/count allocation so the flexible QR field keeps
        // its layout budget. The visible header is composed entirely inside it.
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Color.clear.frame(width: 18, height: 18)
                Text(verbatim: "Lava Security").font(.system(size: 15, weight: .semibold))
                Text(verbatim: "·").font(.system(size: 15))
                Text("Shared filter".lavaLocalized).font(.system(size: 15, weight: .bold))
            }
            Color.clear.frame(height: Self.balancedGap)
            if !summary.chipLabels.isEmpty {
                HStack(spacing: 5) {
                    ForEach(summary.chipLabels, id: \.self) { label in
                        Text(label).font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 9).padding(.vertical, 3.5)
                    }
                }.padding(.top, 5)
            }
        }
        .hidden()
        .accessibilityHidden(true)
        .overlay { visibleHeader }
    }

    private var visibleHeader: some View {
        HStack(alignment: .center, spacing: 8) {
            SoftShieldGuardian(size: 42, state: .awake, animates: false, shieldStyle: .original)
                .environment(\.colorScheme, .light)
                .environment(\.redactionReasons, [])
                .padding(.horizontal, 8)
            VStack(alignment: .leading, spacing: 5) {
                (Text(verbatim: "Lava Security").foregroundColor(Self.ember)
                 + Text(verbatim: " ")
                 + Text("Shared filter".lavaLocalized).foregroundColor(Self.ink))
                    .font(.system(size: 13, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if !summary.chipLabels.isEmpty { chips }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 42, alignment: .leading)
    }
    private var chips: some View {
        Grid(alignment: .leading, horizontalSpacing: 5, verticalSpacing: 2) {
            ForEach(Array(stride(from: 0, to: summary.chipLabels.count, by: 2)), id: \.self) { index in
                GridRow {
                    Text(summary.chipLabels[index])
                    if index + 1 < summary.chipLabels.count {
                        Text(verbatim: "·")
                        Text(summary.chipLabels[index + 1])
                    }
                }
            }
        }
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(Self.chipInk)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 7)
            .padding(.vertical, 3.5)
            .background(Self.chipFill, in: Capsule())
    }

    /// The code, on its own white field with a quiet zone on every side.
    ///
    /// Deliberately the FLEXIBLE element of the card: it takes whatever height the
    /// fixed rows leave, capped at `maximumQRSide` by width. Sizing it with a fixed
    /// frame instead is how an earlier revision silently overflowed the 450pt card
    /// and pushed the provenance line off the bottom edge — a hardcoded side length
    /// has no way to notice that the text above and below it grew. Letting the code
    /// absorb the remainder makes that class of bug unrepresentable, and in a fixed
    /// 360 × 450 frame with fixed type it still resolves to the same size every
    /// render, so the export stays deterministic.
    /// Clear space the card adds above and below the code.
    ///
    /// The horizontal quiet zone is served by the 33pt page margin; vertically the
    /// neighbours are a chip and a line of text, so the card has to supply it. Sized
    /// from the code's ACTUAL module count at the largest side it can render — a code
    /// that lays out smaller has thinner modules and needs less, so one constant is
    /// always sufficient and the code stays the flexible element.
    private var verticalQuietZone: CGFloat {
        let widestModule = SharedFilterCardQuietZone.moduleWidth(
            renderedSide: ShareableFilterCardRenderer.maximumQRSide,
            moduleCount: LavaQRCode.moduleCount(of: qrImage)
        )
        return SharedFilterCardQuietZone.additionalClearance(widestModule: widestModule)
    }

    private var qrField: some View {
        Image(uiImage: qrImage)
            .interpolation(.none)
            .resizable()
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: ShareableFilterCardRenderer.maximumQRSide)
            .padding(.horizontal, ShareableFilterCardRenderer.quietZoneInset)
            .padding(.vertical, verticalQuietZone)
            .background(.white)
    }
}

// MARK: - Renderer

/// Turns a share code into the deterministic PNG-backed image the share sheet sends.
enum ShareableFilterCardRenderer {
    /// 4:5. Displays large in Messages and WhatsApp without cropping.
    static let pointSize = CGSize(width: 360, height: 450)
    /// 360 × 450 @3x = 1080 × 1350.
    static let renderScale: CGFloat = 3
    /// Deliberately dominant: the code is the only part of this card that has a job.
    ///
    /// Sized against the quiet-zone ceiling rather than by eye. The card's own white
    /// margin has to serve as the four-module quiet zone — a messenger may render
    /// the card against a dark bubble and round its corners — which bounds the code
    /// at `width / (1 + 8/modules)`. The binding case is the SMALLEST payload, since
    /// fewer modules means fatter ones.
    ///
    /// Those module counts are MEASURED from `CIQRCodeGenerator`'s output extent, not
    /// read off the QR version tables: the extent is the symbol plus a one-module
    /// border the generator draws itself. The shortest real Lava link measures 39
    /// extent-modules (a version-5 symbol at correction level Q), giving ~7.5pt
    /// modules and a ~30pt requirement — fatter, and hungrier, than the 45-module
    /// case an earlier revision of this comment asserted without checking.
    ///
    /// Horizontally that is met with room to spare: 33pt margin + 4pt inset + the
    /// generator's own ~7.5pt border. Vertically the card must supply it explicitly,
    /// which is what `ShareableFilterCard.verticalQuietZone` does.
    ///
    /// Upper bound only — the code is laid out flexibly and may resolve smaller when
    /// the fixed rows need the height (longer localized copy, for instance).
    static let maximumQRSide: CGFloat = 294
    /// White margin left and right of the code, and therefore the horizontal quiet zone.
    static let horizontalMargin: CGFloat = 33
    /// Extra white left and right of the code, on top of `horizontalMargin`. The
    /// vertical counterpart is computed per-code from its module width.
    static let quietZoneInset: CGFloat = 4

    /// Correction levels tried in order, most robust first.
    ///
    /// A share card is normally delivered as an image attachment, so it gets
    /// recompressed and rescaled before anyone points a camera at it — which argues
    /// for the highest correction level that still fits. Higher correction costs
    /// capacity, though, so a large filter may only encode at a lower one.
    ///
    /// Stepping down changes ONLY the error-correction level. The payload is
    /// identical at every step: nothing is ever truncated, summarised, or dropped to
    /// make a code fit. If no level encodes, the caller gets nil and the card is
    /// withheld entirely in favour of the copyable setup code.
    static let correctionLevels = ["Q", "M", "L"]

    /// Renders the card for `code`, or nil if the full link cannot be encoded.
    @MainActor
    static func render(
        configurationCode code: String,
        configuration: ShareableFilterConfiguration
    ) -> UIImage? {
        guard let url = try? ShareableFilterLink.url(forConfigurationCode: code),
              let qrImage = qrImage(for: url.absoluteString) else {
            return nil
        }

        let card = ShareableFilterCard(
            qrImage: qrImage,
            summary: ShareableFilterCardSummary(configuration: configuration)
        )
        let renderer = ImageRenderer(content: card)
        renderer.scale = renderScale
        renderer.isOpaque = true
        return renderer.uiImage
    }

    /// First correction level that encodes the whole string, or nil.
    static func qrImage(for string: String) -> UIImage? {
        for level in correctionLevels {
            if let image = LavaQRCode.image(for: string, correctionLevel: level) {
                return image
            }
        }
        return nil
    }
}
