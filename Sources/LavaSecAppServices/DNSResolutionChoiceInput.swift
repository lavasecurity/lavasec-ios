import Foundation
import LavaSecKit

/// Converts a displayed DNS choice back to the saved selection without treating
/// localized default labels as user-authored names.
public enum DNSResolutionChoiceInput {
    /// Decodes a choice using its authored source name, with saved-name fallback
    /// for older callers. A malformed source name fails instead of using UI copy.
    public static func selection(from choice: [String: Any]) throws -> DNSResolutionSelection {
        var fields = choice
        // An empty source name is intentional. Older callers without this field
        // still send their saved name directly in `name`.
        if let sourceName = choice["sourceName"] { fields["name"] = sourceName }
        return try JSONDecoder().decode(DNSResolutionSelection.self,
            from: JSONSerialization.data(withJSONObject: fields))
    }
}
