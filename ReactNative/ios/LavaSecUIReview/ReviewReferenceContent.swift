import Foundation
import SwiftUI
import LavaSecAppServices
import LavaSecKit
import UIKit
import CoreImage.CIFilterBuiltins

/// Read-only product attribution from the same registry used by LegalNoticesView.
/// Rendering remains in React; this bridge exposes no account or engine authority.
@objc(LavaReviewReferenceContent)
final class ReviewReferenceContent: NSObject {
    /// Reuse the native Guard identity palette for RN titles and borders.
    @objc static func guardAccents() -> String {
        func hex(_ color: UIColor, _ style: UIUserInterfaceStyle) -> String {
            let resolved = color.resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            return String(format: "#%02X%02X%02X", Int((red * 255).rounded()), Int((green * 255).rounded()), Int((blue * 255).rounded()))
        }
        let accents = Dictionary(uniqueKeysWithValues: GuardianShieldStyle.allCases.map { look in
            let color = UIColor(look.dynamicIslandStatusGlyphColor)
            return (look.rawValue, ["light": hex(color, .light), "dark": hex(color, .dark)])
        })
        guard let data = try? JSONEncoder().encode(accents) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    @objc static func blocklistCatalog() -> String {
        struct CatalogSection: Encodable { let title: String; let sources: [BlocklistSource] }
        let sections = DefaultCatalog.curatedSourcesByCategory.map { CatalogSection(title: $0.category.displayLabel, sources: $0.sources) }
        guard let data = try? JSONEncoder().encode(sections) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    @objc static func shareCode(_ filter: String) -> String {
        let level = OnboardingProtectionLevel.allCases.first { $0.displayName == filter } ?? .balanced
        let ids = level.enabledBlocklistIDs()
        return ShareableFilterConfiguration(enabledBlocklistIDs: ids).encodedConfigurationCode()
    }

    @objc static func sharePreview(_ name: String) -> String {
        let code = shareCode(name)
        guard let url = try? ShareableFilterLink.url(forConfigurationCode: code),
              let png = shareQRImage(name)?.pngData() else { return "" }
        let content = ["code": code, "url": url.absoluteString, "image": "data:image/png;base64," + png.base64EncodedString()]
        guard let data = try? JSONEncoder().encode(content) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    static func shareQRImage(_ name: String) -> UIImage? {
        guard let url = try? ShareableFilterLink.url(forConfigurationCode: shareCode(name)) else { return nil }
        let generator = CIFilter.qrCodeGenerator()
        generator.message = Data(url.absoluteString.utf8)
        generator.correctionLevel = "M"
        guard let output = generator.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        guard let cgImage = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
    private struct Section: Encodable {
        let title: String
        let notices: [ThirdPartyLegalNotice]
    }
    private struct Content: Encodable {
        let disclaimer: String
        let sections: [Section]
    }
    @objc static func legalNotices() -> String {
        let content = Content(disclaimer: ThirdPartyLegalNotices.affiliationDisclaimer, sections: [
            Section(title: "DNS providers", notices: ThirdPartyLegalNotices.dnsResolverNotices),
            Section(title: "Sign-in providers", notices: ThirdPartyLegalNotices.signInProviderNotices),
            Section(title: "Blocklist Licenses", notices: ThirdPartyLegalNotices.blocklistNotices),
            Section(title: "Bundled libraries", notices: ThirdPartyLegalNotices.bundledLibraryNotices),
        ])
        // All fields are static Codable values; an empty result is shown as an
        // explicit unavailable state by the review page rather than invented notices.
        guard let data = try? JSONEncoder().encode(content) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}
