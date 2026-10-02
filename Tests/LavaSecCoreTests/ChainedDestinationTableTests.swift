import XCTest

@testable import LavaSecChainedUpstream
@testable import LavaSecKit

/// The counting half of the per-destination signal: bounded, demand-driven, and unable to lose
/// the one row the user is waiting on.
final class ChainedDestinationTableTests: XCTestCase {

    func testASendCreatesAnEntryAndOpensItsWindow() {
        var table = ChainedDestinationTable()
        XCTAssertNil(table.observation(for: Self.wanted), "an empty table claimed to know a host")
        table.recordSend(to: Self.wanted, atSeconds: 7)

        let observation = table.observation(for: Self.wanted)
        XCTAssertNotNil(observation)
        XCTAssertEqual(observation?.sentPacketCount, 1)
        XCTAssertEqual(observation?.receivedPacketCount, 0)
        XCTAssertEqual(observation?.firstUnansweredSendAtSeconds, 7)
        XCTAssertEqual(observation?.lastSendAtSeconds, 7)
    }

    func testAReceiptClosesTheWindowAndCountsThePacket() {
        var table = ChainedDestinationTable()
        table.recordSend(to: Self.wanted, atSeconds: 7)
        table.recordReceipt(from: Self.wanted, atSeconds: 9)

        let observation = table.observation(for: Self.wanted)
        XCTAssertEqual(observation?.receivedPacketCount, 1)
        XCTAssertNil(
            observation?.firstUnansweredSendAtSeconds,
            "a destination that answered was still being waited on")
        XCTAssertEqual(
            observation?.lastSendAtSeconds, 7, "a receipt was mistaken for the user asking again")
    }

    func testASendAfterAnAnswerOpensAFreshWindow() {
        var table = ChainedDestinationTable()
        table.recordSend(to: Self.wanted, atSeconds: 7)
        table.recordReceipt(from: Self.wanted, atSeconds: 9)
        table.recordSend(to: Self.wanted, atSeconds: 11)
        XCTAssertEqual(table.observation(for: Self.wanted)?.firstUnansweredSendAtSeconds, 11)
    }

    func testASendWithinTheContinuityWindowKeepsTheOriginalAnchor() {
        // Sustained demand is one continuous question. Re-anchoring on every packet would make
        // the wait unable to accumulate at all, and a retransmitting connection would report
        // healthy forever.
        var table = ChainedDestinationTable()
        table.recordSend(to: Self.wanted, atSeconds: 100)
        for offset in [1, 2, 4, 8] {
            table.recordSend(to: Self.wanted, atSeconds: 100 + offset)
        }
        XCTAssertEqual(table.observation(for: Self.wanted)?.firstUnansweredSendAtSeconds, 100)
        XCTAssertEqual(table.observation(for: Self.wanted)?.sentPacketCount, 5)
    }

    func testASendAfterALapseReAnchorsTheWindowInsteadOfInheritingIt() {
        // The user asked, stopped, and asked again. The second question must not inherit the age
        // of the first — otherwise returning to a host after a coffee break reports it as
        // unreachable on its very first packet, before it has had one round trip to answer in.
        var table = ChainedDestinationTable()
        table.recordSend(to: Self.wanted, atSeconds: 100)
        let after = 100 + ChainedDestinationReachabilityPolicy.demandContinuitySeconds
        table.recordSend(to: Self.wanted, atSeconds: after)

        guard let observation = table.observation(for: Self.wanted) else {
            return XCTFail("the destination vanished across a re-anchoring send")
        }
        XCTAssertEqual(observation.firstUnansweredSendAtSeconds, after)
        XCTAssertEqual(
            ChainedDestinationReachabilityPolicy.verdict(for: observation, atSeconds: after),
            .awaiting(seconds: 0),
            "the returning user was told their host was dead")
    }

    func testAQualifiedWindowIsNotReAnchoredByBackoffGaps() {
        // The table half of the same fix. A stalled connect's later retransmits are gaps longer
        // than `demandContinuitySeconds`, so the lapse rule would re-anchor on each one and the
        // wait could never accumulate past the threshold twice (Codex P2, PR #593).
        var table = ChainedDestinationTable()
        for second in [0, 1, 3, 7, 15] {
            table.recordSend(to: Self.wanted, atSeconds: second)
        }
        // Past the threshold with five sends behind it: qualified.
        table.recordSend(to: Self.wanted, atSeconds: 31)
        XCTAssertEqual(
            table.observation(for: Self.wanted)?.firstUnansweredSendAtSeconds, 0,
            "a 16-second backoff gap re-anchored a window that had already qualified")
        table.recordSend(to: Self.wanted, atSeconds: 63)

        guard let observation = table.observation(for: Self.wanted) else {
            return XCTFail("the destination vanished")
        }
        XCTAssertEqual(observation.firstUnansweredSendAtSeconds, 0)
        XCTAssertEqual(
            ChainedDestinationReachabilityPolicy.verdict(for: observation, atSeconds: 63),
            .unanswered(seconds: 63),
            "the host is still failing, so it must still be reportable")
    }

    func testAReceiptClearsAQualifiedWindowAndItsSendCount() {
        var table = ChainedDestinationTable()
        for second in [0, 1, 3, 7, 15] {
            table.recordSend(to: Self.wanted, atSeconds: second)
        }
        table.recordReceipt(from: Self.wanted, atSeconds: 30)

        let observation = table.observation(for: Self.wanted)
        XCTAssertNil(observation?.firstUnansweredSendAtSeconds)
        XCTAssertEqual(
            observation?.sendsInCurrentWindow, 0,
            "the window's send count must clear with the window, or the next stray packet inherits "
                + "a qualification it did not earn")
    }

    func testABurstInsideOneSecondStillEvictsTheLeastRecentlyActive() {
        // Eviction order is a per-packet SEQUENCE, not a timestamp. With one-second granularity a
        // full table touched inside a single second compared equal on every row, so the strict `<`
        // never moved off index 0 and the next arrival evicted whatever was inserted first — even
        // if it had just been sent to (Codex P2, PR #593).
        var table = ChainedDestinationTable()
        for index in 0..<ChainedDestinationTable.capacity {
            table.recordSend(to: Self.chatter(index), atSeconds: 5)
        }
        // Same second, and the oldest row is touched again — it must now be the youngest.
        table.recordSend(to: Self.chatter(0), atSeconds: 5)
        table.recordSend(to: Self.wanted, atSeconds: 5)

        XCTAssertNotNil(
            table.observation(for: Self.chatter(0)),
            "a row sent to immediately before the eviction was discarded anyway")
        XCTAssertNil(
            table.observation(for: Self.chatter(1)),
            "the least recently active row is the one that should have gone")
        XCTAssertNotNil(table.observation(for: Self.wanted))
    }

    func testAReceiptFromAnUnknownSourceDoesNotClaimASlot() {
        // Population is demand-driven. An unsolicited inbound source has no window to close, and
        // admitting it would let arbitrary inbound traffic evict the row the user is waiting on.
        var table = ChainedDestinationTable()
        table.recordReceipt(from: Self.wanted, atSeconds: 3)
        XCTAssertEqual(table.trackedCount, 0)
        XCTAssertNil(table.observation(for: Self.wanted))
    }

    func testTheTableNeverGrowsPastItsCapacity() {
        var table = ChainedDestinationTable()
        for index in 0..<(ChainedDestinationTable.capacity * 3) {
            table.recordSend(to: Self.chatter(index), atSeconds: index)
        }
        XCTAssertEqual(table.trackedCount, ChainedDestinationTable.capacity)
        XCTAssertEqual(table.destinations.count, ChainedDestinationTable.capacity)
    }

    func testTheLeastRecentlyActiveEntryIsTheOneEvicted() {
        var table = ChainedDestinationTable()
        for index in 0..<ChainedDestinationTable.capacity {
            table.recordSend(to: Self.chatter(index), atSeconds: index)
        }
        table.recordSend(to: Self.wanted, atSeconds: 1_000)

        XCTAssertNil(table.observation(for: Self.chatter(0)), "the oldest row was not the evicted one")
        XCTAssertNotNil(table.observation(for: Self.chatter(1)))
        XCTAssertNotNil(table.observation(for: Self.wanted))
        XCTAssertEqual(table.trackedCount, ChainedDestinationTable.capacity)
    }

    func testAReceiptCountsAsActivityForEviction() {
        // The eviction key is activity, not receipts — but it must include receipts too, or a
        // chatty inbound flow the user is happily consuming would be evicted while silent rows
        // survive.
        var table = ChainedDestinationTable()
        table.recordSend(to: Self.chatter(0), atSeconds: 0)
        for index in 1..<ChainedDestinationTable.capacity {
            table.recordSend(to: Self.chatter(index), atSeconds: index)
        }
        table.recordReceipt(from: Self.chatter(0), atSeconds: 900)
        table.recordSend(to: Self.wanted, atSeconds: 1_000)

        XCTAssertNotNil(
            table.observation(for: Self.chatter(0)), "a freshly answering host was evicted as stale")
        XCTAssertNil(table.observation(for: Self.chatter(1)))
    }

    func testTheDestinationBeingSentToSurvivesAFullTableOfChatter() {
        // THE PROPERTY `capacity` IS SIZED FOR. A split tunnel's claimed range is typically a
        // whole tailnet, so the row that matters competes with peers, the resolver and discovery
        // noise. The host the user is actively sending to is by definition the youngest by
        // activity, so it must be the last thing evicted rather than the first — and its window
        // must survive intact, since a reset window is the same failure wearing a different hat.
        var table = ChainedDestinationTable()
        table.recordSend(to: Self.wanted, atSeconds: 0)
        for index in 0..<(ChainedDestinationTable.capacity * 4) {
            table.recordSend(to: Self.chatter(index), atSeconds: index + 1)
            table.recordSend(to: Self.wanted, atSeconds: index + 1)
        }

        let observation = table.observation(for: Self.wanted)
        XCTAssertNotNil(observation, "the host the user was waiting on was crowded out")
        XCTAssertEqual(
            observation?.firstUnansweredSendAtSeconds, 0, "the wait was restarted by unrelated traffic")
        XCTAssertEqual(table.trackedCount, ChainedDestinationTable.capacity)
    }

    func testInterleavedBurstsAreNeverCreditedToTheWrongDestination() {
        // The hot-index hint makes the common single-destination burst one comparison instead of
        // a scan. It is only ever used after its address matches, so an interleave must still
        // land every packet on its own row.
        var table = ChainedDestinationTable()
        for index in 0..<6 {
            table.recordSend(to: Self.wanted, atSeconds: index)
            table.recordSend(to: Self.chatter(0), atSeconds: index)
        }
        table.recordReceipt(from: Self.wanted, atSeconds: 6)

        XCTAssertEqual(table.observation(for: Self.wanted)?.sentPacketCount, 6)
        XCTAssertEqual(table.observation(for: Self.chatter(0))?.sentPacketCount, 6)
        XCTAssertNil(table.observation(for: Self.wanted)?.firstUnansweredSendAtSeconds)
        XCTAssertEqual(
            table.observation(for: Self.chatter(0))?.firstUnansweredSendAtSeconds, 0,
            "one host's answer closed another host's window")
    }

    func testDestinationsReportsEveryTrackedRowWithItsOwnCounts() {
        var table = ChainedDestinationTable()
        table.recordSend(to: Self.wanted, atSeconds: 1)
        table.recordSend(to: Self.wanted, atSeconds: 2)
        table.recordSend(to: Self.chatter(0), atSeconds: 3)
        table.recordReceipt(from: Self.chatter(0), atSeconds: 4)

        let rows = Dictionary(
            uniqueKeysWithValues: table.destinations.map { ($0.address, $0.observation) })
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[Self.wanted]?.sentPacketCount, 2)
        XCTAssertEqual(rows[Self.wanted]?.receivedPacketCount, 0)
        XCTAssertEqual(rows[Self.chatter(0)]?.receivedPacketCount, 1)
    }

    /// `100.64.0.1` — inside the `100.64.0.0/10` range of the capture that motivated this type.
    private static let wanted: UInt32 = 0x64_40_00_01

    /// Distinct in-range noise: other tailnet nodes, the resolver, discovery traffic.
    private static func chatter(_ index: Int) -> UInt32 {
        0x64_40_01_00 &+ UInt32(index)
    }
}
