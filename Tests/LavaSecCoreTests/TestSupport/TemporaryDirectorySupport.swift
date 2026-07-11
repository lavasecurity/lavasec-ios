import Foundation

/// Runs a synchronous test operation inside an isolated temporary directory.
///
/// Cleanup failures surface when the operation succeeds. When the operation throws,
/// cleanup is still attempted without replacing the operation's original error.
func withTemporaryDirectory<Result>(
    prefix: String = "lavasec-tests",
    _ operation: (URL) throws -> Result
) throws -> Result {
    let directory = try makeTemporaryDirectory(prefix: prefix)

    do {
        let result = try operation(directory)
        try FileManager.default.removeItem(at: directory)
        return result
    } catch {
        try? FileManager.default.removeItem(at: directory)
        throw error
    }
}

/// Runs an asynchronous test operation inside an isolated temporary directory.
///
/// Cancellation follows normal Swift cooperative cancellation: once the operation
/// unwinds, cleanup completes synchronously before the cancellation error propagates.
func withTemporaryDirectory<Result>(
    prefix: String = "lavasec-tests",
    _ operation: (URL) async throws -> Result
) async throws -> Result {
    let directory = try makeTemporaryDirectory(prefix: prefix)

    do {
        let result = try await operation(directory)
        try FileManager.default.removeItem(at: directory)
        return result
    } catch {
        try? FileManager.default.removeItem(at: directory)
        throw error
    }
}

private func makeTemporaryDirectory(prefix: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    return directory
}
