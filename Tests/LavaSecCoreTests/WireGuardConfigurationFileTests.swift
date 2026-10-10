import XCTest
@testable import LavaSecAppServices
import LavaSecKit

final class WireGuardConfigurationFileTests: XCTestCase {
    func testReadFailuresUsePackageCopyAndFormatTheSizeAtTheProducer() {
        let unreadable = WireGuardConfigurationFile.ReadFailure.unreadable.localizedDescription
        let notText = WireGuardConfigurationFile.ReadFailure.notText.localizedDescription
        let tooLarge = WireGuardConfigurationFile.ReadFailure.tooLarge(128 * 1024).localizedDescription
        XCTAssertEqual(unreadable, LavaCoreStrings.localized("Couldn't open that file. Try moving it to Files first."))
        XCTAssertEqual(notText, LavaCoreStrings.localized("That file isn't text, so it isn't a WireGuard config."))
        XCTAssertEqual(tooLarge, LavaCoreStrings.localizedFormat("That file is %lld KB — far too big for a WireGuard config. Wrong file?", 128))
        XCTAssertTrue(tooLarge.contains("128"))
        XCTAssertFalse(tooLarge.contains("%lld"))
        XCTAssertFalse(tooLarge.contains("ReadFailure"))
        XCTAssertNotEqual(unreadable, notText)
    }

    private func file(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".conf")
        try data.write(to: url); addTeardownBlock { try? FileManager.default.removeItem(at: url) }; return url
    }
    func testReadsUTF8WithoutTrustingTheExtension() throws {
        let contents = "[Interface]\nName = 東京\n"
        XCTAssertEqual(try WireGuardConfigurationFile.read(at: file(Data(contents.utf8))), contents)
    }
    func testRefusesOversizedAndNonUTF8Files() throws {
        let large = try file(Data(repeating: 65, count: WireGuardConfigurationFile.maximumBytes + 1))
        XCTAssertThrowsError(try WireGuardConfigurationFile.read(at: large)) { error in
            guard case WireGuardConfigurationFile.ReadFailure.tooLarge = error else { return XCTFail("Wrong error") }
        }
        let binary = try file(Data([0xFF,0xFE]))
        XCTAssertThrowsError(try WireGuardConfigurationFile.read(at: binary)) { error in
            guard case WireGuardConfigurationFile.ReadFailure.notText = error else { return XCTFail("Wrong error") }
        }
        let exact = try file(Data(repeating: 65, count: WireGuardConfigurationFile.maximumBytes))
        XCTAssertEqual(try WireGuardConfigurationFile.read(at: exact).utf8.count, WireGuardConfigurationFile.maximumBytes)
    }
    func testActualReadIsBoundedWhenMetadataIsUnavailableOrIncorrect() throws {
        let limit = WireGuardConfigurationFile.maximumBytes
        let large = try file(Data(repeating: 65, count: limit * 3))
        let handle = try FileHandle(forReadingFrom: large)
        defer { try? handle.close() }
        XCTAssertThrowsError(try WireGuardConfigurationFile.read(from: handle)) { error in
            guard case WireGuardConfigurationFile.ReadFailure.tooLarge(let bytes) = error else { return XCTFail("Wrong error") }
            XCTAssertEqual(bytes, limit + 1)
        }
        XCTAssertEqual(try handle.offset(), UInt64(limit + 1))
        let exact = try FileHandle(forReadingFrom: file(Data(repeating: 65, count: limit)))
        defer { try? exact.close() }
        XCTAssertEqual(try WireGuardConfigurationFile.read(from: exact).utf8.count, limit)
    }
}
