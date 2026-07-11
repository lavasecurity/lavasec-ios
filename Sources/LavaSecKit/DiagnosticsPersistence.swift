import Foundation

/// Loads and saves the diagnostics store.
public enum DiagnosticsPersistence {
    /// Loads and day-rolls a store, returning new state when no valid file is available.
    public static func load(from url: URL, maxEvents: Int = 250) -> DiagnosticsStore {
        guard let data = try? Data(contentsOf: url),
              let store = try? makeJSONDecoder().decode(DiagnosticsStore.self, from: data)
        else {
            return DiagnosticsStore(maxEvents: maxEvents)
        }

        var currentStore = store
        currentStore.resetForCurrentDayIfNeeded()
        return currentStore
    }

    /// Saves the diagnostics store atomically at `url`.
    public static func save(_ store: DiagnosticsStore, to url: URL) throws {
        let directoryURL = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )

        let data = try makeJSONEncoder().encode(store)
        try data.write(to: url, options: [.atomic])
    }

    /// Creates the decoder used for persisted diagnostics data.
    public static func makeJSONDecoder() -> JSONDecoder {
        JSONDecoder()
    }

    /// Creates the pretty-printed, sorted-key encoder used for persisted diagnostics data.
    public static func makeJSONEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        // Machine-only file rewritten whole on the debounced cadence (up to 120x/hour under
        // active browsing) — sortedKeys keeps writes byte-stable for identical content, but
        // pretty-printing only inflates the payload (~50%) on flash.
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
