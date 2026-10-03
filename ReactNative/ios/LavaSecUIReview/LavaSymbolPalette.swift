import SwiftUI
import UIKit

/// SF Symbols share the canonical Swift palette. An explicit app appearance
/// prevents a transparent toolbar's local contrast traits from recoloring them.
enum LavaSymbolPalette {
    static func color(for tone: String, colorScheme: String = "") -> UIColor {
        let color: UIColor = switch tone {
        case "primary": UIColor(LavaStyle.primaryText)
        case "error": UIColor(LavaStyle.errorText)
        case "white": UIColor(LavaStyle.actionForeground)
        case "ink": UIColor(LavaStyle.ink)
        case "accentOrange": UIColor(LavaStyle.lavaOrange)
        case "secondary": UIColor(LavaStyle.secondaryText)
        case "tertiary": UIColor(LavaStyle.tertiaryText)
        case "orange": UIColor(LavaStyle.lavaOrangeText)
        default: UIColor(LavaStyle.safeGreen)
        }
        switch colorScheme {
        case "light": return color.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        case "dark": return color.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))
        default: return color
        }
    }
}
