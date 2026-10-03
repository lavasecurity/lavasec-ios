import Foundation

/// User-facing identity is metadata, independent of rule compilation and filter ID.
public enum FilterIdentityPolicy {
    /// Compare the complete draft without trimming or validating away an unfinished edit.
    /// Swift string equality treats canonically equivalent Unicode as the same identity.
    public static func hasUnsavedChanges(name: String, emoji: String, savedName: String, savedEmoji: String) -> Bool {
        name != savedName || emoji != savedEmoji
    }

    /// Returns the last complete emoji in committed input, replacing the prior identity.
    /// Invalid nonempty input retains the old value; clearing remains a deliberate edit.
    public static func committedEmoji(_ input: String, fallback: String) -> String {
        if input.isEmpty { return "" }
        return input.map(String.init).last(where: isValidEmoji) ?? fallback
    }

    /// Canonical spelling for newly entered names, with surrounding whitespace removed.
    public static func normalizedName(_ raw: String) -> String {
        raw.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Validate on commit, not during IME composition. Existing stored names are
    /// deliberately decoded unchanged; this rule governs newly entered names.
    public static func isValidName(_ raw: String) -> Bool {
        guard !raw.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return false }
        let value = normalizedName(raw)
        guard !value.isEmpty else { return false }
        var hasBase = false
        for scalar in value.unicodeScalars {
            if CharacterSet.nonBaseCharacters.contains(scalar) {
                guard hasBase else { return false }
            } else if CharacterSet.letters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar) {
                hasBase = true
            } else if scalar == " " {
                hasBase = false
            } else { return false }
        }
        return true
    }

    /// An emoji-only edit retains the exact stored name, including legacy punctuation.
    /// Actual renames must meet today's entry policy and use canonical trimmed spelling.
    public static func nameForEdit(_ raw: String, savedName: String) -> String? {
        if raw == savedName { return savedName }
        return isValidName(raw) ? normalizedName(raw) : nil
    }

    /// Exactly one extended grapheme; accepts flags, keycaps, variation selectors
    /// and joined families/professions. Plain digits and text are not emoji.
    public static func isValidEmoji(_ value: String) -> Bool {
        guard value.count == 1, !value.isEmpty else { return false }
        let scalars = Array(value.unicodeScalars)
        if scalars.count == 2, scalars.allSatisfy({ (0x1F1E6...0x1F1FF).contains($0.value) }) { return true }
        if scalars.last?.value == 0x20E3 {
            return scalars.count <= 3 && "0123456789#*".unicodeScalars.contains(scalars[0])
                && (scalars.count == 2 || scalars[1].value == 0xFE0F)
        }
        guard scalars.first?.properties.isEmojiModifier != true,
              scalars.last?.value != 0x200D,
              !scalars.contains(where: { (0x1F1E6...0x1F1FF).contains($0.value) }) else { return false }
        for index in scalars.indices where scalars[index].value == 0x200D {
            guard index > 0, index + 1 < scalars.count, scalars[index + 1].properties.isEmoji,
                  !scalars[index + 1].properties.isEmojiModifier else { return false }
        }
        guard scalars.contains(where: { $0.properties.isEmojiPresentation || $0.value == 0xFE0F }),
              scalars.first?.properties.isEmoji == true else { return false }
        return scalars.allSatisfy { scalar in
            scalar.properties.isEmoji || scalar.value == 0x200D || scalar.value == 0xFE0F
                || (0xE0020...0xE007F).contains(scalar.value)
        }
    }

    /// Presentation-only identity for notifications and intents; stored names remain unchanged.
    public static func displayName(name: String, emoji: String) -> String {
        isValidEmoji(emoji) ? "\(emoji) \(name)" : name
    }

    /// Defaults are stable across locale, relaunch, import and backup. Never use
    /// Swift's randomized Hasher for persistent visual identity.
    public static func defaultEmoji(id: String, name: String) -> String {
        switch name.lowercased() {
        case "core": return "🌱"
        case "balanced": return "🪴"
        case "extra": return "💐"
        default: break
        }
        let pool = ["🌿", "🪴", "🧩", "🧭", "🎒", "🏡", "🚲", "☕️", "📚", "🔑", "🎨", "🌻"]
        let hash = id.utf8.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 }
        return pool[Int(hash % UInt64(pool.count))]
    }
}
