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
    /// Notice for a third-party library compiled into a shipped binary. Unlike the
    /// other categories — which describe services the app *talks to* — this one covers
    /// code the app *contains*, so its notice must carry the upstream copyright line
    /// and license, not just an identification of the vendor.
    case bundledLibrary
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
    public static let affiliationDisclaimer = "Third-party names identify services, sign-in providers, data sources, or open-source libraries included in Lava. Lava Security is not affiliated with, endorsed by, sponsored by, or reviewed by these providers or projects."
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
            id: DNSResolverPreset.quad9Unfiltered.id,
            displayName: DNSResolverPreset.quad9Unfiltered.displayName,
            category: .dnsResolver,
            ownerName: "Quad9 Foundation",
            noticeText: "Quad9 is a trademark of Quad9 Foundation.",
            sourceURL: URL(string: "https://www.quad9.net/about/"),
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
            id: DNSResolverPreset.quad9UnfilteredDoH.id,
            displayName: DNSResolverPreset.quad9UnfilteredDoH.displayName,
            category: .dnsResolver,
            ownerName: "Quad9 Foundation",
            noticeText: "Quad9 is a trademark of Quad9 Foundation.",
            sourceURL: URL(string: "https://www.quad9.net/about/"),
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
            id: DNSResolverPreset.quad9UnfilteredDoT.id,
            displayName: DNSResolverPreset.quad9UnfilteredDoT.displayName,
            category: .dnsResolver,
            ownerName: "Quad9 Foundation",
            noticeText: "Quad9 is a trademark of Quad9 Foundation.",
            sourceURL: URL(string: "https://www.quad9.net/about/"),
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

    /// Notices for third-party code compiled into a shipped binary.
    ///
    /// This category carries a duty the other three do not. A blocklist or a resolver is
    /// *contacted* at runtime and never redistributed, so a link to its license suffices.
    /// A bundled library is **redistributed in binary form**, and BSD-3-Clause clause 2
    /// requires the copyright notice, the full condition list, and the disclaimer to be
    /// reproduced "in the documentation and/or other materials provided with the
    /// distribution" — a URL is not reproduction. The verbatim text therefore lives in the
    /// repository at `ThirdParty/wireguard-core/LICENSE-boringtun.txt`; `licenseTextURL`
    /// is a convenience link, not the compliance artifact. The Phase-3 UI section must
    /// render that text, not merely link it.
    ///
    /// The trademark sentence is adapted from upstream's own wording in
    /// `boringtun/README.md`, extended to name Lava Security as well: the mark belongs to
    /// Jason A. Donenfeld, and neither Cloudflare nor we are endorsed by him.
    ///
    /// This is the concise product-facing entry for BoringTun. Complete package and license
    /// text for every crate present in the shipped Apple-target archives is generated into
    /// `ThirdParty/wireguard-core/THIRD-PARTY-NOTICES.txt` and copied byte-for-byte into the
    /// app bundle. `BundledLibraryAttributionSourceTests` checks that inventory and prevents
    /// a newly linked dependency from entering without attribution.
    ///
    /// Note the obligation attaches earlier than the feature ships: the committed
    /// xcframework is itself a binary redistribution and sits inside the public-export
    /// scope, so it reaches the public mirror on the next promotion regardless of whether
    /// any target links it. See `docs/legal/third-party-notices.md` for the current status.
    public static let bundledLibraryNotices: [ThirdPartyLegalNotice] = [
        ThirdPartyLegalNotice(
            id: "boringtun",
            displayName: "BoringTun",
            category: .bundledLibrary,
            ownerName: "Cloudflare, Inc.",
            noticeText: "Copyright (c) 2019 Cloudflare, Inc. All rights reserved. "
                + "Used under the BSD 3-Clause License. "
                + "WireGuard is a registered trademark of Jason A. Donenfeld. "
                + "BoringTun and Lava Security are not sponsored or endorsed by Jason A. Donenfeld.",
            sourceURL: URL(string: "https://github.com/cloudflare/boringtun"),
            licenseTextURL: URL(string: "https://opensource.org/license/bsd-3-clause"),
            distributionModeDescription: "Vendored upstream source, compiled from a pinned "
                + "toolchain into a static library that is linked into the app's packet-tunnel "
                + "extension in every build, whether or not chained upstream is turned on. "
                + "No code is downloaded at runtime.",
            plannedUse: "Cryptographic core — Noise handshake and transport encryption — for a "
                + "user-supplied WireGuard upstream. No logo or provider branding is shown."
        )
    ]

    package static let all: [ThirdPartyLegalNotice] =
        dnsResolverNotices + signInProviderNotices + blocklistNotices + bundledLibraryNotices

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
            LavaCoreStrings.localized("Third-party source project")
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
        LavaCoreStrings.localizedFormat("%1$@ is a third-party source shown for attribution and source identification. License: %2$@. Owner or project: %3$@.", source.name, source.licenseName, ownerName)
    }
}
