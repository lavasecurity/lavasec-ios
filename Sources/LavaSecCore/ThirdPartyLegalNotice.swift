import Foundation

public enum ThirdPartyLegalNoticeCategory: String, Codable, Sendable {
    case dnsResolver
    case signInProvider
    case blocklistSource
}

public struct ThirdPartyLegalNotice: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let displayName: String
    public let category: ThirdPartyLegalNoticeCategory
    public let ownerName: String
    public let noticeText: String
    public let sourceURL: URL?
    public let licenseTextURL: URL?
    public let noticeURL: URL?
    public let distributionModeDescription: String?
    public let usesLogo: Bool
    public let requiresWrittenPermissionForPlannedUse: Bool
    public let plannedUse: String

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

public enum ThirdPartyLegalNotices {
    public static let affiliationDisclaimer = "Third-party names identify services, sign-in providers, or data sources. Lava Security is not affiliated with, endorsed by, sponsored by, or reviewed by these providers or projects."
    private static let dnsResolverPlannedUse = "Plain-text identification of a selectable DNS resolver and optional encrypted upstream forwarding for allowed DNS lookups."

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
            id: DNSResolverPreset.google.id,
            displayName: DNSResolverPreset.google.displayName,
            category: .dnsResolver,
            ownerName: "Google LLC",
            noticeText: "Google and Google Public DNS are trademarks of Google LLC.",
            sourceURL: URL(string: "https://developers.google.com/speed/public-dns"),
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
            id: DNSResolverPreset.dnsSB.id,
            displayName: DNSResolverPreset.dnsSB.displayName,
            category: .dnsResolver,
            ownerName: "xTom GmbH",
            noticeText: "DNS.SB is operated by xTom GmbH.",
            sourceURL: URL(string: "https://dns.sb/"),
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
            id: DNSResolverPreset.dnsSBDoH.id,
            displayName: DNSResolverPreset.dnsSBDoH.displayName,
            category: .dnsResolver,
            ownerName: "xTom GmbH",
            noticeText: "DNS.SB is operated by xTom GmbH.",
            sourceURL: URL(string: "https://dns.sb/doh/"),
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
            id: DNSResolverPreset.dnsSBDoT.id,
            displayName: DNSResolverPreset.dnsSBDoT.displayName,
            category: .dnsResolver,
            ownerName: "xTom GmbH",
            noticeText: "DNS.SB is operated by xTom GmbH.",
            sourceURL: URL(string: "https://dns.sb/dot/"),
            plannedUse: dnsResolverPlannedUse
        )
    ]

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

    public static let blocklistNotices: [ThirdPartyLegalNotice] = {
        (DefaultCatalog.curatedSources + DefaultCatalog.guardrailSources).map { blocklistNotice(for: $0) }
    }()

    public static let all: [ThirdPartyLegalNotice] = dnsResolverNotices + signInProviderNotices + blocklistNotices

    public static func notice(id: String) -> ThirdPartyLegalNotice? {
        all.first { $0.id == id }
    }

    private static func blocklistNotice(for source: BlocklistSource) -> ThirdPartyLegalNotice {
        let ownerName = blocklistOwnerName(for: source.id)
        let projectURL = blocklistProjectURL(for: source.id)
        let isGPL = source.licenseName.hasPrefix("GPL")
        let licenseTextURL = isGPL ? URL(string: "https://www.gnu.org/licenses/gpl-3.0.en.html") : nil
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
