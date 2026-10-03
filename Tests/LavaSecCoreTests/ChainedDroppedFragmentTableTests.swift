import XCTest

@testable import LavaSecChainedUpstream

/// The bounded memory that lets a fragment tail be judged by the head it belongs to.
final class ChainedDroppedFragmentTableTests: XCTestCase {

    func testAnIdentityIsFoundOnlyAfterItIsRemembered() {
        var table = ChainedDroppedFragmentTable()
        let identity = Self.identity(1)
        XCTAssertFalse(table.contains(identity), "an empty table claimed to know something")
        table.remember(identity)
        XCTAssertTrue(table.contains(identity))
    }

    func testTheKeyIsTheFullReassemblyTupleAndNotAnyPartOfIt() {
        // Every field is load-bearing: dropping any one of them from the key would make two
        // different datagrams the same identity, and the fail-closed direction means the cost is
        // legitimate traffic destroyed rather than a leak — quietly, and only under
        // fragmentation.
        var table = ChainedDroppedFragmentTable()
        let base = ChainedFragmentIdentity(
            source: 0x0A_FF_00_02, destination: 0x08_08_08_08,
            identification: 0x4242, protocolNumber: UInt8(IPPROTO_UDP))
        table.remember(base)

        let variants = [
            ChainedFragmentIdentity(
                source: 0x0A_FF_00_03, destination: base.destination,
                identification: base.identification, protocolNumber: base.protocolNumber),
            ChainedFragmentIdentity(
                source: base.source, destination: 0x01_01_01_01,
                identification: base.identification, protocolNumber: base.protocolNumber),
            ChainedFragmentIdentity(
                source: base.source, destination: base.destination,
                identification: 0x4243, protocolNumber: base.protocolNumber),
            ChainedFragmentIdentity(
                source: base.source, destination: base.destination,
                identification: base.identification, protocolNumber: UInt8(IPPROTO_TCP)),
        ]
        for variant in variants {
            XCTAssertFalse(table.contains(variant), "the key ignores a field it must not")
        }
    }

    func testARepeatedHeadDoesNotConsumeTheTable() {
        // A retransmitted or duplicated head arriving many times would otherwise evict the
        // identities whose tails have not arrived yet — the table emptying itself of exactly
        // what it exists to hold, using one datagram.
        var table = ChainedDroppedFragmentTable()
        let survivor = Self.identity(1)
        table.remember(survivor)
        for _ in 0..<(ChainedDroppedFragmentTable.capacity * 4) {
            table.remember(Self.identity(2))
        }
        XCTAssertTrue(table.contains(survivor), "a repeated head evicted an unrelated identity")
        XCTAssertEqual(table.rememberedCount, 2)
    }

    func testARerememberedIdentityBecomesTheYoungest() {
        // The bound in the type's documentation depends on this. Returning early when the
        // identity was already present was right about not consuming a second entry and wrong
        // about age: an identity re-remembered while already the oldest stayed the oldest, so
        // ONE further dropped head evicted it — and the tails arriving after the retransmission
        // missed the table and were forwarded. The stated 32-head bound was really 1, in exactly
        // the shape a retransmitting resolver produces.
        var table = ChainedDroppedFragmentTable()
        let retransmitted = Self.identity(0)
        table.remember(retransmitted)
        for index in 1..<ChainedDroppedFragmentTable.capacity {
            table.remember(Self.identity(UInt16(index)))
        }
        // Full, with `retransmitted` at the old end. The head arrives again.
        table.remember(retransmitted)
        XCTAssertEqual(
            table.rememberedCount, ChainedDroppedFragmentTable.capacity,
            "the retransmission consumed a second entry")

        // One more head now evicts the OLDEST, which must no longer be the retransmitted one.
        table.remember(Self.identity(9_000))
        XCTAssertTrue(
            table.contains(retransmitted),
            "a retransmitted head was evicted by a single later drop — its tails would leak")
        XCTAssertFalse(table.contains(Self.identity(1)), "eviction did not take the oldest")
    }

    func testTheOldestIdentityIsEvictedOnceTheTableIsFull() {
        // The bound is the point: this is resident memory in a process capped at ~50 MB
        // (`INV-MEM-1`), so it cannot grow with traffic. A miss means a tail is forwarded, and
        // the cost of that is stated where the deny-list is chosen.
        var table = ChainedDroppedFragmentTable()
        for index in 0..<ChainedDroppedFragmentTable.capacity {
            table.remember(Self.identity(UInt16(index)))
        }
        XCTAssertEqual(table.rememberedCount, ChainedDroppedFragmentTable.capacity)
        XCTAssertTrue(table.contains(Self.identity(0)))

        table.remember(Self.identity(9_000))
        XCTAssertEqual(
            table.rememberedCount, ChainedDroppedFragmentTable.capacity,
            "the table grew past its bound")
        XCTAssertFalse(table.contains(Self.identity(0)), "the oldest identity was not evicted")
        XCTAssertTrue(table.contains(Self.identity(9_000)))
        XCTAssertTrue(
            table.contains(Self.identity(UInt16(ChainedDroppedFragmentTable.capacity - 1))),
            "eviction took something other than the oldest")
    }

    func testForgettingReleasesOnlyTheNamedIdentity() {
        // `forget` exists for exactly one caller — a forwarded head reclaiming its tuple — and
        // the failure this test pins is over-forgetting: releasing neighbours along with the
        // named identity would forward the tails of datagrams whose heads were dropped, which
        // is the leak the table exists to stop, opened by its own release path.
        var table = ChainedDroppedFragmentTable()
        table.remember(Self.identity(1))
        table.remember(Self.identity(2))
        table.remember(Self.identity(3))
        table.forget(Self.identity(2))
        XCTAssertFalse(table.contains(Self.identity(2)))
        XCTAssertTrue(table.contains(Self.identity(1)), "forgetting one identity released another")
        XCTAssertTrue(table.contains(Self.identity(3)), "forgetting one identity released another")
        XCTAssertEqual(table.rememberedCount, 2)
    }

    func testForgettingAnUnknownIdentityChangesNothing() {
        var table = ChainedDroppedFragmentTable()
        table.remember(Self.identity(1))
        table.forget(Self.identity(9))
        XCTAssertTrue(table.contains(Self.identity(1)))
        XCTAssertEqual(table.rememberedCount, 1)
    }

    func testEvictionStillTakesTheOldestAfterAForget() {
        // A forget that leaves the age order corrupted — a hole, or a shifted head — would make
        // the next eviction take the wrong entry, silently converting the documented 32-head
        // bound into something smaller for whichever identity ended up mis-aged.
        var table = ChainedDroppedFragmentTable()
        for index in 0..<ChainedDroppedFragmentTable.capacity {
            table.remember(Self.identity(UInt16(index)))
        }
        table.forget(Self.identity(0))  // the oldest goes; identity(1) is now oldest
        table.remember(Self.identity(9_000))  // refills to capacity, evicting nothing
        XCTAssertEqual(table.rememberedCount, ChainedDroppedFragmentTable.capacity)
        XCTAssertTrue(table.contains(Self.identity(1)))

        table.remember(Self.identity(9_001))  // over capacity: must evict identity(1)
        XCTAssertFalse(table.contains(Self.identity(1)), "eviction did not take the oldest")
        XCTAssertTrue(table.contains(Self.identity(2)), "eviction took something other than the oldest")
    }

    private static func identity(_ identification: UInt16) -> ChainedFragmentIdentity {
        ChainedFragmentIdentity(
            source: 0x0A_FF_00_02, destination: 0x08_08_08_08,
            identification: identification, protocolNumber: UInt8(IPPROTO_UDP))
    }
}
