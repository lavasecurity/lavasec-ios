import Foundation
import LavaSecKit

/// Product surface to which a third-party legal notice applies.
public enum ThirdPartyLegalNoticeCategory: String, Codable, Sendable {
    /// Notice for a selectable DNS resolver.
    case dnsResolver
    /// Notice for an account sign-in provider.
    case signInProvider
    /// Notice for a bundled or downloadable blocklist source.
    case blocklistSource
}

/// Display and attribution metadata for one third-party dependency or service.
public struct ThirdPartyLegalNotice: Identifiable, Hashable, Codable, Sendable {
    /// Stable identifier used to associate the notice with its product entry.
    public let id: String
    /// Name presented to the user.
    public let displayName: String
    /// Product surface associated with the notice.
    public let category: ThirdPartyLegalNoticeCategory
    /// Name of the third-party owner or organization.
    public let ownerName: String
    /// Attribution or trademark notice shown to the user.
    public let noticeText: String
    /// Upstream project or service information URL, when available.
    public let sourceURL: URL?
    /// Full license-text URL, when separately available.
    public let licenseTextURL: URL?
    /// Additional notice URL, when supplied by the owner.
    public let noticeURL: URL?
    /// Description of how Lava Security distributes or retrieves the material.
    public let distributionModeDescription: String?
    /// Whether the planned product use displays the third party's logo.
    public let usesLogo: Bool
    /// Whether the described planned use requires written permission.
    public let requiresWrittenPermissionForPlannedUse: Bool
    /// Plain-language description of Lava Security's planned use.
    public let plannedUse: String

    /// Creates a notice by storing the supplied attribution and planned-use metadata.
    public init(
        id: String,
        displayName: String,
        category: ThirdPartyLegalNoticeCategory,
        ownerName: String,
        noticeText: String,
        sourceURL: URL?,
        licenseTextURL: URL? = nil,
        noticeURL: URL? = nil,
        distributionModeDescription: String? = nil,
        usesLogo: Bool = false,
        requiresWrittenPermissionForPlannedUse: Bool = false,
        plannedUse: String
    ) {
        self.id = id
        self.displayName = displayName
        self.category = category
        self.ownerName = ownerName
        self.noticeText = noticeText
        self.sourceURL = sourceURL
        self.licenseTextURL = licenseTextURL
        self.noticeURL = noticeURL
        self.distributionModeDescription = distributionModeDescription
        self.usesLogo = usesLogo
        self.requiresWrittenPermissionForPlannedUse = requiresWrittenPermissionForPlannedUse
        self.plannedUse = plannedUse
    }
}

/// Built-in third-party notices grouped for the app's legal-notice screens.
public enum ThirdPartyLegalNotices {
    /// General non-affiliation disclaimer displayed with third-party notices.
    public static let affiliationDisclaimer = "Third-party names identify services, sign-in providers, or data sources. Lava Security is not affiliated with, endorsed by, sponsored by, or reviewed by these providers or projects."
    private static let dnsResolverPlannedUse = "Plain-text identification of a selectable DNS resolver and optional encrypted upstream forwarding for allowed DNS lookups."

    /// Notices for the built-in DNS resolver catalog.
    public static let dnsResolverNotices: [ThirdPartyLegalNotice] = [
        ThirdPartyLegalNotice(
            id: DNSResolverPreset.device.id,
            displayName: DNSResolverPreset.device.displayName,
            category: .dnsResolver,
            ownerName: "Current network provider",
            noticeText: "Device DNS identifies the DNS resolver supplied by the current Wi-Fi, cellular, or system network configuration.",
            sourceURL: nil,
            plannedUse: "Plain-text identification of the device DNS resolver used for allowed DNS lookups when selected or used as fallback."
        ),
        ThirdPartyLegalNotice(
            id: DNSResolverPreset.mullvad.id,
            displayName: DNSResolverPreset.mullvad.displayName,
            category: .dnsResolver,
            ownerName: "Mullvad VPN AB",
            noticeText: "Mullvad is a trademark of Mullvad VPN AB.",
            sourceURL: URL(string: "https://mullvad.net/en/help/dns-over-https-and-dns-over-tls"),
            plannedUse: dnsResolverPlannedUse
        ),
        ThirdPartyLegalNotice(
            id: DNSResolverPreset.cloudflare.id,
            displayName: DNSResolverPreset.cloudflare.displayName,
            category: .dnsResolver,
            ownerName: "Cloudflare, Inc.",
            noticeText: "Cloudflare is a trademark or registered trademark of Cloudflare, Inc. in the United States and other jurisdictions.",
            sourceURL: URL(string: "https://www.cloudflare.com/learning/dns/what-is-1.1.1.1/"),
            plannedUse: dnsResolverPlannedUse
        ),
        ThirdPartyLegalNotice(
            id: DNSResolverPreset.quad9Secure.id,
            displayName: DNSResolverPreset.quad9Secure.displayName,
            category: .dnsResolver,
            ownerName: "Quad9 Foundation",
            noticeText: "Quad9 is a trademark of Quad9 Foundation.",
            sourceURL: URL(string: "https://www.quad9.org/about/"),
            plannedUse: dnsResolverPlannedUse
        ),
        ThirdPartyLegalNotice(
            id: DNSResolverPreset.hagezi.id,
            displayName: DNSResolverPreset.hagezi.displayName,
            category: .dnsResolver,
            ownerName: "HaGeZi",
            noticeText: "HaGeZi DNS is a public resolver operated by the HaGeZi project.",
            sourceURL: URL(string: "https://github.com/hagezi/dns-servers"),
            plannedUse: dnsResolverPlannedUse
        ),
        ThirdPartyLegalNotice(
            id: DNSResolverPreset.google.id,
            displayName: DNSResolverPreset.google.displayName,
            category: .dnsResolver,
            ownerName: "Google LLC",
            noticeText: "Google and Google Public DNS are trademarks of Google LLC.",
            sourceURL: URL(string: "https://developers.google.com/speed/public-dns"),
            plannedUse: dnsResolverPlannedUse
        ),
        ThirdPartyLegalNotice(
            id: DNSResolverPreset.mullvadDoH.id,
            displayName: DNSResolverPreset.mullvadDoH.displayName,
            category: .dnsResolver,
            ownerName: "Mullvad VPN AB",
            noticeText: "Mullvad is a trademark of Mullvad VPN AB.",
            sourceURL: URL(string: "https://mullvad.net/en/help/dns-over-https-and-dns-over-tls"),
            plannedUse: dnsResolverPlannedUse
        ),
        ThirdPartyLegalNotice(
            id: DNSResolverPreset.cloudflareDoH.id,
            displayName: DNSResolverPreset.cloudflareDoH.displayName,
            category: .dnsResolver,
            ownerName: "Cloudflare, Inc.",
            noticeText: "Cloudflare is a trademark or registered trademark of Cloudflare, Inc. in the United States and other jurisdictions.",
            sourceURL: URL(string: "https://www.cloudflare.com/learning/dns/what-is-1.1.1.1/"),
            plannedUse: dnsResolverPlannedUse
        ),
        ThirdPartyLegalNotice(
            id: DNSResolverPreset.quad9SecureDoH.id,
            displayName: DNSResolverPreset.quad9SecureDoH.displayName,
            category: .dnsResolver,
            ownerName: "Quad9 Foundation",
            noticeText: "Quad9 is a trademark of Quad9 Foundation.",
            sourceURL: URL(string: "https://www.quad9.org/about/"),
            plannedUse: dnsResolverPlannedUse
        ),
        ThirdPartyLegalNotice(
            id: DNSResolverPreset.hageziDoH.id,
            displayName: DNSResolverPreset.hageziDoH.displayName,
            category: .dnsResolver,
            ownerName: "HaGeZi",
            noticeText: "HaGeZi DNS is a public resolver operated by the HaGeZi project.",
            sourceURL: URL(string: "https://github.com/hagezi/dns-servers"),
            plannedUse: dnsResolverPlannedUse
        ),
        ThirdPartyLegalNotice(
            id: DNSResolverPreset.googleDoH.id,
            displayName: DNSResolverPreset.googleDoH.displayName,
            category: .dnsResolver,
            ownerName: "Google LLC",
            noticeText: "Google and Google Public DNS are trademarks of Google LLC.",
            sourceURL: URL(string: "https://developers.google.com/speed/public-dns"),
            plannedUse: dnsResolverPlannedUse
        ),
        ThirdPartyLegalNotice(
            id: DNSResolverPreset.mullvadDoT.id,
            displayName: DNSResolverPreset.mullvadDoT.displayName,
            category: .dnsResolver,
            ownerName: "Mullvad VPN AB",
            noticeText: "Mullvad is a trademark of Mullvad VPN AB.",
            sourceURL: URL(string: "https://mullvad.net/en/help/dns-over-https-and-dns-over-tls"),
            plannedUse: dnsResolverPlannedUse
        ),
        ThirdPartyLegalNotice(
            id: DNSResolverPreset.cloudflareDoT.id,
            displayName: DNSResolverPreset.cloudflareDoT.displayName,
            category: .dnsResolver,
            ownerName: "Cloudflare, Inc.",
            noticeText: "Cloudflare is a trademark or registered trademark of Cloudflare, Inc. in the United States and other jurisdictions.",
            sourceURL: URL(string: "https://www.cloudflare.com/learning/dns/what-is-1.1.1.1/"),
            plannedUse: dnsResolverPlannedUse
        ),
        ThirdPartyLegalNotice(
            id: DNSResolverPreset.quad9SecureDoT.id,
            displayName: DNSResolverPreset.quad9SecureDoT.displayName,
            category: .dnsResolver,
            ownerName: "Quad9 Foundation",
            noticeText: "Quad9 is a trademark of Quad9 Foundation.",
            sourceURL: URL(string: "https://www.quad9.org/about/"),
            plannedUse: dnsResolverPlannedUse
        ),
        ThirdPartyLegalNotice(
            id: DNSResolverPreset.hageziDoT.id,
            displayName: DNSResolverPreset.hageziDoT.displayName,
            category: .dnsResolver,
            ownerName: "HaGeZi",
            noticeText: "HaGeZi DNS is a public resolver operated by the HaGeZi project.",
            sourceURL: URL(string: "https://github.com/hagezi/dns-servers"),
            plannedUse: dnsResolverPlannedUse
        ),
        ThirdPartyLegalNotice(
            id: DNSResolverPreset.googleDoT.id,
            displayName: DNSResolverPreset.googleDoT.displayName,
            category: .dnsResolver,
            ownerName: "Google LLC",
            noticeText: "Google and Google Public DNS are trademarks of Google LLC.",
            sourceURL: URL(string: "https://developers.google.com/speed/public-dns"),
            plannedUse: dnsResolverPlannedUse
        )
    ]

    /// Notices for supported account sign-in providers.
    public static let signInProviderNotices: [ThirdPartyLegalNotice] = [
        ThirdPartyLegalNotice(
            id: "apple-sign-in",
            displayName: "Apple",
            category: .signInProvider,
            ownerName: "Apple Inc.",
            noticeText: "Apple, the Apple logo, iPhone, and App Store are trademarks of Apple Inc.",
            sourceURL: URL(string: "https://developer.apple.com/design/human-interface-guidelines/sign-in-with-apple"),
            plannedUse: "Plain-text identification of a planned sign-in option. No provider logo is shown."
        ),
        ThirdPartyLegalNotice(
            id: "google-sign-in",
            displayName: "Google",
            category: .signInProvider,
            ownerName: "Google LLC",
            noticeText: "Google is a trademark of Google LLC.",
            sourceURL: URL(string: "https://developers.google.com/identity/branding-guidelines"),
            plannedUse: "Plain-text identification of a planned sign-in option. No provider logo is shown."
        )
    ]

    /// Notices derived from the curated and guardrail blocklist catalogs.
    public static let blocklistNotices: [ThirdPartyLegalNotice] = {
        (DefaultCatalog.curatedSources + DefaultCatalog.guardrailSources).map { blocklistNotice(for: $0) }
    }()

    package static let all: [ThirdPartyLegalNotice] = dnsResolverNotices + signInProviderNotices + blocklistNotices

    package static func notice(id: String) -> ThirdPartyLegalNotice? {
        all.first { $0.id == id }
    }

    private static func blocklistNotice(for source: BlocklistSource) -> ThirdPartyLegalNotice {
        let ownerName = blocklistOwnerName(for: source.id)
        let projectURL = blocklistProjectURL(for: source.id)
        let isGPL = source.licenseName.hasPrefix("GPL")
        let licenseTextURL: URL? = if isGPL {
            URL(string: "https://www.gnu.org/licenses/gpl-3.0.en.html")
        } else if source.licenseName.hasPrefix("MPL") {
            URL(string: "https://www.mozilla.org/en-US/MPL/2.0/")
        } else {
            nil
        }
        let distributionMode = isGPL
            ? "The app fetches the upstream source URL directly and processes the downloaded list locally on this device."
            : "The app fetches the upstream source URL directly and processes the downloaded list locally on this device."

        return ThirdPartyLegalNotice(
            id: source.id,
            displayName: source.name,
            category: .blocklistSource,
            ownerName: ownerName,
            noticeText: blocklistNoticeText(for: source, ownerName: ownerName),
            sourceURL: projectURL ?? source.sourceURL,
            licenseTextURL: licenseTextURL,
            noticeURL: projectURL ?? source.sourceURL,
            distributionModeDescription: distributionMode,
            plannedUse: "Attribution and source identification for a selectable or guardrail DNS blocklist."
        )
    }

    private static func blocklistOwnerName(for sourceID: String) -> String {
        switch sourceID {
        case let id where id.hasPrefix("blocklistproject-"):
            "The Block List Project"
        case let id where id.hasPrefix("hagezi-"):
            "HaGeZi DNS Blocklists"
        case let id where id.hasPrefix("oisd-"):
            "OISD"
        case let id where id.hasPrefix("stevenblack-"):
            "Steven Black"
        case let id where id.hasPrefix("adguard-"):
            "AdGuard"
        case let id where id.hasPrefix("1hosts-"):
            "1Hosts (badmojr)"
        case DefaultCatalog.phishingDatabaseActive.id:
            "Phishing.Database"
        default:
            "Third-party source project"
        }
    }

    private static func blocklistProjectURL(for sourceID: String) -> URL? {
        switch sourceID {
        case let id where id.hasPrefix("blocklistproject-"):
            URL(string: "https://github.com/blocklistproject/Lists")
        case let id where id.hasPrefix("hagezi-"):
            URL(string: "https://github.com/hagezi/dns-blocklists")
        case let id where id.hasPrefix("oisd-"):
            URL(string: "https://github.com/sjhgvr/oisd")
        case let id where id.hasPrefix("stevenblack-"):
            URL(string: "https://github.com/StevenBlack/hosts")
        case let id where id.hasPrefix("adguard-"):
            URL(string: "https://github.com/AdguardTeam/AdGuardSDNSFilter")
        case let id where id.hasPrefix("1hosts-"):
            URL(string: "https://github.com/badmojr/1Hosts")
        case DefaultCatalog.phishingDatabaseActive.id:
            URL(string: "https://github.com/Phishing-Database/Phishing.Database")
        default:
            nil
        }
    }

    private static func blocklistNoticeText(for source: BlocklistSource, ownerName: String) -> String {
        "\(source.name) is a third-party source shown for attribution and source identification. License: \(source.licenseName). Owner or project: \(ownerName)."
    }
}
