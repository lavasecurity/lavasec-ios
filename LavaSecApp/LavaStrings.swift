import Foundation

enum LavaStrings {
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
