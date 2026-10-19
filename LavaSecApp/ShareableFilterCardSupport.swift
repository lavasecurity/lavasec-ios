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

/// QR generation shared by native import and the React-owned export card.
enum ShareableFilterCardRenderer {
    /// Try the most robust correction level first without truncating the payload.
    static let correctionLevels = ["Q", "M", "L"]

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
