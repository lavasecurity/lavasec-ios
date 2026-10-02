import CryptoKit
import Foundation

/// Exact identity of the tunnel executable whose chained lifecycle evidence is persisted.
///
/// Marketing version, build number, and source revision are useful provenance, but local
/// device builds intentionally leave the revision empty and currently share build number `1`.
/// Hashing the installed executable makes two genuinely different tunnel binaries different
/// lifecycle owners without allocating the whole executable in the memory-constrained Network
/// Extension process. If the executable cannot be read, callers must refuse chained startup:
/// falling back to version-only identity could charge a replacement build for its predecessor's
/// unknown hard exit.
public enum ChainedInstalledBuildIdentity {
    /// Combines ordinary build provenance with the exact installed executable digest.
    ///
    /// Returns `nil` when the executable is absent or unreadable; the tunnel treats that as
    /// unavailable lifecycle state and refuses chained startup rather than using a collision-prone
    /// version-only fallback.
    public static func make(
        version: String,
        build: String,
        revision: String,
        executableURL: URL?
    ) -> String? {
        guard let executableURL,
              let executableDigest = try? sha256Hex(of: executableURL)
        else {
            return nil
        }

        return [version, build, revision, executableDigest].joined(separator: "|")
    }

    private static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 64 * 1_024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
