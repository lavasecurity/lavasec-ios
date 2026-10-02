import XCTest
import Darwin

@testable import LavaSecCore
@testable import LavaSecKit

final class DeviceLogObservationOrderTests: XCTestCase {
    private let bootSessionID = "0123456789abcdef0123456789abcdef"

    func testLiteralValueSerializesAndParsesCanonically() throws {
        // Production mutation caught: changing the version, separators, UUID spelling, or
        // decimal nanosecond representation breaks the shared writer/reader wire contract.
        let order = try XCTUnwrap(DeviceLogObservationOrder(
            bootSessionID: bootSessionID,
            monotonicNanoseconds: 18_446_744_073_709_551_615
        ))

        XCTAssertEqual(
            order.serialized,
            "v1:0123456789abcdef0123456789abcdef:18446744073709551615"
        )
        XCTAssertEqual(
            DeviceLogObservationOrder.parse(
                "v1:0123456789abcdef0123456789abcdef:18446744073709551615"
            ),
            order
        )
    }

    func testUnknownVersionIsRejected() {
        // Production mutation caught: ignoring the version would let a future incompatible
        // clock-domain format be silently ordered as v1.
        XCTAssertNil(DeviceLogObservationOrder.parse(
            "v2:0123456789abcdef0123456789abcdef:42"
        ))
    }

    func testNonCanonicalBootSessionIDsAreRejected() {
        // Production mutation caught: UUID parsing that accepts uppercase, hyphens, a wrong
        // width, or non-hex digits creates multiple spellings for one ordering domain.
        for value in [
            "v1:0123456789abcdef0123456789abcde:42",
            "v1:0123456789abcdef0123456789abcdef0:42",
            "v1:01234567-89ab-cdef-0123-456789abcdef:42",
            "v1:0123456789ABCDEF0123456789ABCDEF:42",
            "v1:0123456789abcdef0123456789abcdeg:42",
        ] {
            XCTAssertNil(DeviceLogObservationOrder.parse(value), value)
        }
    }

    func testInitializerRejectsNonCanonicalBootSessionIDs() {
        // Production mutation caught: removing the initializer's validation guard would let a
        // caller serialize malformed ordering domains even while parse remained strict.
        for bootSessionID in [
            "0123456789abcdef0123456789abcde",
            "0123456789abcdef0123456789abcdef0",
            "01234567-89ab-cdef-0123-456789abcdef",
            "0123456789ABCDEF0123456789ABCDEF",
            "0123456789abcdef0123456789abcdeg",
        ] {
            XCTAssertNil(
                DeviceLogObservationOrder(
                    bootSessionID: bootSessionID,
                    monotonicNanoseconds: 42
                ),
                bootSessionID
            )
        }
    }

    func testMissingAndTrailingComponentsAreRejected() {
        // Production mutation caught: a split that tolerates absent or surplus fields would
        // accept ambiguous tokens that do not have the exact v1 grammar.
        for value in [
            "v1",
            "v1:0123456789abcdef0123456789abcdef",
            "v1::42",
            "v1:0123456789abcdef0123456789abcdef:",
            "v1:0123456789abcdef0123456789abcdef:42:trailing",
        ] {
            XCTAssertNil(DeviceLogObservationOrder.parse(value), value)
        }
    }

    func testNegativeAndOverflowNanosecondsAreRejected() {
        // Production mutation caught: parsing through a signed, floating-point, or truncating
        // conversion could admit values outside the UInt64 monotonic clock domain.
        for value in [
            "v1:0123456789abcdef0123456789abcdef:-1",
            "v1:0123456789abcdef0123456789abcdef:18446744073709551616",
        ] {
            XCTAssertNil(DeviceLogObservationOrder.parse(value), value)
        }
    }

    func testNonCanonicalDecimalNanosecondsAreRejected() {
        // Production mutation caught: removing the canonical decimal comparison after UInt64
        // parsing would accept multiple spellings for the same monotonic observation.
        for value in [
            "v1:0123456789abcdef0123456789abcdef:00",
            "v1:0123456789abcdef0123456789abcdef:01",
            "v1:0123456789abcdef0123456789abcdef:+1",
        ] {
            XCTAssertNil(DeviceLogObservationOrder.parse(value), value)
        }
    }

    func testPreferredBootSessionUUIDWinsWithoutReadingBootTime() throws {
        // Production mutation caught: consulting the wall-clock-derived fallback even after the
        // canonical UUID succeeds can split the app and extension into avoidably weaker domains.
        var bootTimeReadCount = 0
        let resolver = DeviceLogClockDomainResolver(
            bootSessionUUID: { "01234567-89AB-CDEF-0123-456789ABCDEF\n" },
            bootTime: {
                bootTimeReadCount += 1
                return DeviceLogClockDomainResolver.BootTimeReading(
                    seconds: 1_786_297_931,
                    microseconds: 916_926,
                    byteCount: MemoryLayout<timeval>.size
                )
            }
        )

        XCTAssertEqual(try XCTUnwrap(resolver.resolve()), bootSessionID)
        XCTAssertEqual(bootTimeReadCount, 0)
    }

    func testUnavailableUUIDUsesLosslessBootTimeDomain() throws {
        // Production mutation caught: returning nil immediately after the physical-device EPERM
        // path would again omit observationOrder from every app and Network Extension record.
        let resolver = DeviceLogClockDomainResolver(
            bootSessionUUID: { nil },
            bootTime: {
                DeviceLogClockDomainResolver.BootTimeReading(
                    seconds: 1_786_297_931,
                    microseconds: 916_926,
                    byteCount: MemoryLayout<timeval>.size
                )
            }
        )

        XCTAssertEqual(
            try XCTUnwrap(resolver.resolve()),
            "62747631000000006a78be4b000dfdbe"
        )
    }

    func testBootTimeFallbackEncodesExactMinimumAndMaximumComponents() throws {
        // Production mutation caught: narrowing boot seconds to UInt32 or trimming zero padding
        // loses the full fixed-width timeval domain at one of these exact boundaries.
        func resolve(seconds: Int64, microseconds: Int64) throws -> String {
            try XCTUnwrap(DeviceLogClockDomainResolver(
                bootSessionUUID: { nil },
                bootTime: {
                    DeviceLogClockDomainResolver.BootTimeReading(
                        seconds: seconds,
                        microseconds: microseconds,
                        byteCount: MemoryLayout<timeval>.size
                    )
                }
            ).resolve())
        }

        XCTAssertEqual(
            try resolve(seconds: 0, microseconds: 0),
            "62747631000000000000000000000000"
        )
        XCTAssertEqual(
            try resolve(seconds: Int64.max, microseconds: 999_999),
            "627476317fffffffffffffff000f423f"
        )
    }

    func testIdenticalBootTimeValuesResolveIdenticallyAcrossIndependentResolvers() throws {
        // Production mutation caught: mixing in process-local state would make the app and NE
        // domains differ even though kern.boottime returned the same timeval in both sandboxes.
        func makeResolver() -> DeviceLogClockDomainResolver {
            DeviceLogClockDomainResolver(
                bootSessionUUID: { nil },
                bootTime: {
                    DeviceLogClockDomainResolver.BootTimeReading(
                        seconds: 1_786_297_931,
                        microseconds: 916_926,
                        byteCount: MemoryLayout<timeval>.size
                    )
                }
            )
        }

        XCTAssertEqual(try XCTUnwrap(makeResolver().resolve()), try XCTUnwrap(makeResolver().resolve()))
    }

    func testBootSecondAndMicrosecondChangesProduceDistinctDomains() throws {
        // Production mutation caught: truncating either timeval component can conflate distinct
        // clock domains and license cross-domain monotonic reordering.
        func resolve(seconds: Int64, microseconds: Int64) throws -> String {
            try XCTUnwrap(DeviceLogClockDomainResolver(
                bootSessionUUID: { nil },
                bootTime: {
                    DeviceLogClockDomainResolver.BootTimeReading(
                        seconds: seconds,
                        microseconds: microseconds,
                        byteCount: MemoryLayout<timeval>.size
                    )
                }
            ).resolve())
        }

        let baseline = try resolve(seconds: 1_786_297_931, microseconds: 916_926)
        XCTAssertNotEqual(baseline, try resolve(seconds: 1_786_297_932, microseconds: 916_926))
        XCTAssertNotEqual(baseline, try resolve(seconds: 1_786_297_931, microseconds: 916_927))
    }

    func testFailedOrMalformedBootTimeReadIsRejected() {
        // Production mutation caught: encoding a failed read or partial timeval would turn
        // uninitialized bytes into an apparently valid ordering domain.
        let failed = DeviceLogClockDomainResolver(
            bootSessionUUID: { nil },
            bootTime: { nil }
        )
        XCTAssertNil(failed.resolve())

        for byteCount in [MemoryLayout<timeval>.size - 1, MemoryLayout<timeval>.size + 1] {
            let malformedSize = DeviceLogClockDomainResolver(
                bootSessionUUID: { nil },
                bootTime: {
                    DeviceLogClockDomainResolver.BootTimeReading(
                        seconds: 1_786_297_931,
                        microseconds: 916_926,
                        byteCount: byteCount
                    )
                }
            )

            XCTAssertNil(
                malformedSize.resolve(),
                "returned byte count must match timeval exactly: \(byteCount)"
            )
        }
    }

    func testNegativeBootSecondsAreRejected() {
        // Production mutation caught: signed-to-unsigned conversion would wrap a malformed
        // negative timeval into a canonical-looking 64-bit domain component.
        let resolver = DeviceLogClockDomainResolver(
            bootSessionUUID: { nil },
            bootTime: {
                DeviceLogClockDomainResolver.BootTimeReading(
                    seconds: -1,
                    microseconds: 0,
                    byteCount: MemoryLayout<timeval>.size
                )
            }
        )

        XCTAssertNil(resolver.resolve())
    }

    func testBootMicrosecondsOutsideCanonicalRangeAreRejected() {
        // Production mutation caught: accepting an out-of-range tv_usec creates multiple timeval
        // spellings for one instant and therefore multiple ordering domains for the same boot.
        for microseconds: Int64 in [-1, 1_000_000] {
            let resolver = DeviceLogClockDomainResolver(
                bootSessionUUID: { nil },
                bootTime: {
                    DeviceLogClockDomainResolver.BootTimeReading(
                        seconds: 1_786_297_931,
                        microseconds: microseconds,
                        byteCount: MemoryLayout<timeval>.size
                    )
                }
            )

            XCTAssertNil(resolver.resolve(), "microseconds: \(microseconds)")
        }
    }

    func testSteadyStateCaptureOnlyUsesTheCachedDomainAndAdjacentClocks() throws {
        // Production mutation caught: moving either sysctl resolver into capture() restores
        // per-event kernel work on packet-path telemetry callbacks.
        let source = try readSource(.deviceLogObservationOrder)
        XCTAssertEqual(
            sourceOccurrenceCount(
                of: "private static let clockDomainID: String? = "
                    + "DeviceLogClockDomainResolver().resolve()",
                in: source
            ),
            1,
            "the resolved domain must be a stored static let, not a computed static var"
        )
        let capture = try sourceBlock(
            in: source,
            startingAt: "public static func capture() -> DeviceLogObservation {",
            endingBefore: "}\n\n/// Resolves one cached clock-domain identifier"
        )

        XCTAssertTrue(capture.contains("let clockDomainID = clockDomainID"))
        XCTAssertTrue(sourceContainsInOrder(
            ["let clockDomainID = clockDomainID", "let observedAt = Date()", "clock_gettime_nsec_np"],
            in: capture
        ))
        let executableCapture = sourceExcludingComments(capture)
        for forbidden in ["sysctl", "FileManager", "NSLock", "DispatchQueue", "resolve()"] {
            XCTAssertFalse(executableCapture.contains(forbidden), forbidden)
        }
        XCTAssertEqual(
            sourceOccurrenceCount(of: "DeviceLogClockDomainResolver().resolve()", in: source),
            1,
            "the resolver belongs only in the once-per-process static initializer"
        )
    }
}
