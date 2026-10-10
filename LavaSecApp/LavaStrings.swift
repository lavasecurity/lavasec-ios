import Foundation
import LavaSecKit

enum LavaStrings {
    /// Provider and user-authored resolver names remain identities. Only Lava's
    /// device/default custom labels are localization keys; checking the source
    /// name separately preserves authored names equal to "Guard" or "Custom DNS".
    static func resolverName(_ preset: DNSResolverPreset, customName: String? = nil, short: Bool = false) -> String {
        if preset.id == DNSResolverPreset.device.id {
            return (short ? "Device" : "Device DNS").lavaLocalized
        }
        if preset.id == DNSResolverPreset.customID {
            guard let customName, !customName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return "Custom DNS".lavaLocalized
            }
            return customName
        }
        return short ? preset.shortDisplayName : preset.displayName
    }

    static func localized(_ key: String, fallback: String) -> String {
        NSLocalizedString(key, tableName: "Localizable", bundle: .main, value: fallback, comment: "")
    }

    static func localizedFormat(_ key: String, fallback: String, _ arguments: CVarArg...) -> String {
        let format = localized(key, fallback: fallback)
        return String(format: format, locale: .autoupdatingCurrent, arguments: arguments)
    }
}

extension String {
    var lavaLocalized: String {
        LavaStrings.localized(self, fallback: self)
    }

    func lavaLocalizedFormat(_ arguments: CVarArg...) -> String {
        let format = LavaStrings.localized(self, fallback: self)
        return String(format: format, locale: .autoupdatingCurrent, arguments: arguments)
    }
}
