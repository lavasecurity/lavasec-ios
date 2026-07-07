import Foundation

public enum DiagnosticsPersistence {
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

    public static func save(_ store: DiagnosticsStore, to url: URL) throws {
        let directoryURL = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )

        let data = try makeJSONEncoder().encode(store)
        try data.write(to: url, options: [.atomic])
    }

    public static func makeJSONDecoder() -> JSONDecoder {
        JSONDecoder()
    }

    public static func makeJSONEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        // Machine-only file rewritten whole on the debounced cadence (up to 120x/hour under
        // active browsing) — sortedKeys keeps writes byte-stable for identical content, but
        // pretty-printing only inflates the payload (~50%) on flash.
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
