import Foundation

/// Bounded app-owned temporary copies used only while decoding an imported QR.
/// Plaintext files are private rendering input, never reusable presentation cache.
public enum PrivateImportFiles {
    private static let prefix = "lava-private-import-"

    /// Removes only this owner's abandoned copies older than one hour. Legacy
    /// anonymous UUID files cannot safely be distinguished from other temp data.
    public static func purgeExpired(in directory: URL = FileManager.default.temporaryDirectory,
                                    now: Date = Date()) {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]) else { return }
        for file in files where file.lastPathComponent.hasPrefix(prefix) {
            guard let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate,
                  now.timeIntervalSince(modified) >= 3600 else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// Copies a pre-size-validated asset; readers still delete it with `defer`.
    /// On iOS the atomic write creates protected bytes from the outset, including
    /// its auxiliary file, rather than tightening protection after a plain copy.
    public static func copy(_ source: URL, into directory: URL = FileManager.default.temporaryDirectory) throws -> URL {
        purgeExpired(in: directory)
        var target = directory.appendingPathComponent(prefix + UUID().uuidString)
        do {
            let bytes = try Data(contentsOf: source, options: .mappedIfSafe)
            #if os(iOS)
            try bytes.write(to: target, options: [.atomic, .completeFileProtection])
            #else
            try bytes.write(to: target, options: .atomic)
            #endif
            var resources = URLResourceValues()
            resources.isExcludedFromBackup = true
            try target.setResourceValues(resources)
            return target
        } catch {
            try? FileManager.default.removeItem(at: target)
            throw error
        }
    }
}
