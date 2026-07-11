import Foundation
import XCTest

final class TemporaryDirectorySupportTests: XCTestCase {
    func testSynchronousSuccessReturnsValueAndRemovesNestedContents() throws {
        let (directory, value) = try withTemporaryDirectory { directory in
            let nestedDirectory = directory.appendingPathComponent("nested", isDirectory: true)
            try FileManager.default.createDirectory(
                at: nestedDirectory,
                withIntermediateDirectories: true
            )
            try Data("fixture".utf8).write(
                to: nestedDirectory.appendingPathComponent("value.txt")
            )

            XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
            return (directory, 42)
        }

        XCTAssertEqual(value, 42)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testSynchronousThrowPreservesErrorAndRemovesDirectory() throws {
        var capturedDirectory: URL?

        do {
            try withTemporaryDirectory { directory -> Void in
                capturedDirectory = directory
                try Data("fixture".utf8).write(
                    to: directory.appendingPathComponent("value.txt")
                )
                throw FixtureError.expected
            }
            XCTFail("Expected the fixture operation to throw.")
        } catch FixtureError.expected {
            // Expected.
        }

        let directory = try XCTUnwrap(capturedDirectory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testSynchronousSuccessSurfacesCleanupFailure() {
        XCTAssertThrowsError(
            try withTemporaryDirectory { directory in
                try FileManager.default.removeItem(at: directory)
            }
        )
    }

    func testSynchronousBodyErrorWinsWhenCleanupAlsoFails() {
        do {
            try withTemporaryDirectory { directory in
                try FileManager.default.removeItem(at: directory)
                throw FixtureError.expected
            }
            XCTFail("Expected the fixture operation to throw.")
        } catch FixtureError.expected {
            // Expected.
        } catch {
            XCTFail("Expected the body error to win, got \(error).")
        }
    }

    func testAsynchronousSuccessReturnsValueAndRemovesNestedContents() async throws {
        let (directory, value) = try await withTemporaryDirectory { directory in
            let nestedDirectory = directory.appendingPathComponent("nested", isDirectory: true)
            try FileManager.default.createDirectory(
                at: nestedDirectory,
                withIntermediateDirectories: true
            )
            try Data("fixture".utf8).write(
                to: nestedDirectory.appendingPathComponent("value.txt")
            )
            await Task.yield()

            XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
            return (directory, 42)
        }

        XCTAssertEqual(value, 42)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testAsynchronousThrowPreservesErrorAndRemovesDirectory() async throws {
        let capture = TemporaryDirectoryURLCapture()

        do {
            try await withTemporaryDirectory { directory -> Void in
                await capture.publish(directory)
                try Data("fixture".utf8).write(
                    to: directory.appendingPathComponent("value.txt")
                )
                await Task.yield()
                throw FixtureError.expected
            }
            XCTFail("Expected the fixture operation to throw.")
        } catch FixtureError.expected {
            // Expected.
        }

        let directory = await capture.waitForURL()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testCancellationPropagatesAndRemovesDirectoryAfterBodyUnwinds() async {
        let capture = TemporaryDirectoryURLCapture()
        let task = Task<Void, Error> {
            try await withTemporaryDirectory { directory in
                await capture.publish(directory)
                try Data("fixture".utf8).write(
                    to: directory.appendingPathComponent("value.txt")
                )
                try await Task.sleep(nanoseconds: 60_000_000_000)
            }
        }

        let directory = await capture.waitForURL()
        task.cancel()

        do {
            try await task.value
            XCTFail("Expected cancellation to propagate from the fixture operation.")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error).")
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }
}

private enum FixtureError: Error {
    case expected
}

private actor TemporaryDirectoryURLCapture {
    private var capturedURL: URL?
    private var waiters: [CheckedContinuation<URL, Never>] = []

    func publish(_ url: URL) {
        capturedURL = url
        let currentWaiters = waiters
        waiters.removeAll()
        for waiter in currentWaiters {
            waiter.resume(returning: url)
        }
    }

    func waitForURL() async -> URL {
        if let capturedURL {
            return capturedURL
        }

        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}
