import XCTest

@testable import LavaSecKit

// Matches the type's own gate, so a release-configuration test build stays consistent
// rather than failing on a symbol that deliberately does not exist there.
#if DEBUG || LAVA_QA_TOOLS

/// The memory reading that has to already be in the log before a jetsam kill, because the kill
/// leaves no chance to write one.
final class TunnelMemoryFootprintTests: XCTestCase {
    private let mb: UInt64 = 1024 * 1024

    func testThePercentageIsTakenFromThePeakNotTheCurrentReading() {
        // THE WHOLE POINT. A kill lands between 60 s samples, so the instantaneous reading at
        // flush time can sit comfortably low moments after a spike that nearly ended the process.
        // Reporting the current figure would show a healthy number for a process that was about
        // to die — the exact blind spot chimmy's field log had.
        let spiked = TunnelMemoryFootprint(bytes: 8 * mb, peakBytes: 47 * mb)
        XCTAssertEqual(spiked.megabytes, 8, "the current reading is still reported as itself")
        XCTAssertEqual(spiked.peakMegabytes, 47)
        XCTAssertEqual(
            spiked.percentOfReferenceCeiling, 94,
            "94% of the ceiling is the fact worth logging; 16% would hide it")
    }

    func testAnOverCeilingPeakIsReportedRatherThanClamped() {
        // A value over 100 is precisely the observation this type was added to capture. Clamping
        // it would erase the evidence at the only moment it matters.
        let over = TunnelMemoryFootprint(bytes: 10 * mb, peakBytes: 60 * mb)
        XCTAssertEqual(over.percentOfReferenceCeiling, 120)
    }

    func testAMissingPeakFallsBackToTheCurrentReadingRatherThanZero() {
        // An older kernel reports no peak. Treating that as a zero peak would render every line
        // as 0% and quietly turn the instrument off.
        let noPeak = TunnelMemoryFootprint(bytes: 25 * mb)
        XCTAssertNil(noPeak.peakMegabytes)
        XCTAssertEqual(noPeak.percentOfReferenceCeiling, 50)
    }

    func testAbsentAndNeverGrewStayDistinguishable() {
        // `nil` means the kernel did not report a peak; zero means it reported one and it was
        // zero. A reader diagnosing a kill needs to know which of those it is looking at, so the
        // optional is not collapsed.
        XCTAssertNil(TunnelMemoryFootprint(bytes: mb, peakBytes: nil).peakMegabytes)
        XCTAssertEqual(TunnelMemoryFootprint(bytes: mb, peakBytes: 0).peakMegabytes, 0)
    }

    func testTheReferenceCeilingMatchesTheInvariantTheTypesAreWrittenAgainst() {
        // ~50 MB is the figure `INV-MEM-1` and the chained-upstream types cite. If this drifts,
        // every percentage in every historical log line silently changes meaning.
        XCTAssertEqual(TunnelMemoryFootprint.referenceCeilingBytes, 52_428_800)
        XCTAssertEqual(
            TunnelMemoryFootprint(bytes: 50 * mb).percentOfReferenceCeiling, 100,
            "the ceiling itself must read as exactly 100%")
    }
}

#endif
