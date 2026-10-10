import Foundation
import LavaSecKit

/// File-provider metadata is advisory. The actual read is bounded to the limit
/// plus one byte, with balanced security-scoped access and strict UTF-8 decoding.
public enum WireGuardConfigurationFile {
    /// Maximum decoded input size; larger configuration files are rejected.
    public static let maximumBytes = 64 * 1024
    public enum ReadFailure: LocalizedError {
        case unreadable, tooLarge(Int), notText
        public var errorDescription: String? {
            switch self {
            case .unreadable:
                LavaCoreStrings.localized("Couldn't open that file. Try moving it to Files first.")
            case .tooLarge(let bytes):
                LavaCoreStrings.localizedFormat("That file is %lld KB — far too big for a WireGuard config. Wrong file?", bytes / 1024)
            case .notText:
                LavaCoreStrings.localized("That file isn't text, so it isn't a WireGuard config.")
            }
        }
    }
    /// Reads strict UTF-8 under balanced file-provider access and a hard byte limit.
    public static func read(at url: URL) throws -> String {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > maximumBytes { throw ReadFailure.tooLarge(size) }
        guard let handle = try? FileHandle(forReadingFrom: url) else { throw ReadFailure.unreadable }
        defer { try? handle.close() }
        return try read(from: handle)
    }
    /// The metadata-independent reader consumes at most the limit plus one byte.
    static func read(from handle: FileHandle) throws -> String {
        var data = Data()
        do {
            while data.count <= maximumBytes {
                let remaining = maximumBytes + 1 - data.count
                guard let chunk = try handle.read(upToCount: min(8 * 1024, remaining)), !chunk.isEmpty else { break }
                data.append(chunk)
            }
        } catch { throw ReadFailure.unreadable }
        guard data.count <= maximumBytes else { throw ReadFailure.tooLarge(data.count) }
        guard let text = String(data: data, encoding: .utf8) else { throw ReadFailure.notText }
        return text
    }
}
