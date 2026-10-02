import XCTest

@testable import LavaSecChainedUpstream
@testable import LavaSecKit

/// Bounded packet queues for the chained data path.
///
/// The failure being prevented is not packet loss — it is the extension being killed. An
/// unbounded queue absorbing a fast downlink is the documented SpeedTest jetsam mode, and the
/// NE process runs under a ~50 MB ceiling (`INV-MEM-1`) with the engine already resident. So
/// these tests are about the queue staying bounded while it is being pushed, and about
/// bounding it in BYTES rather than only in packets.
final class ChainedPacketQueueTests: XCTestCase {
    private static let mtu = 1280

    private func makeQueue(
        packets: Int = ChainedPacketQueueLimits.engineQueueDepth,
        bytes: Int = ChainedPacketQueueLimits.engineQueueDepth * mtu
    ) -> ChainedPacketQueue {
        ChainedPacketQueue(limits: ChainedPacketQueueLimits(maximumPackets: packets, maximumBytes: bytes))
    }

    private func packet(_ size: Int, fill: UInt8 = 0xAB) -> [UInt8] {
        Array(repeating: fill, count: size)
    }

    // MARK: - The bound is real under sustained pressure

    func testTheQueueShedsUnderSustainedOverloadRatherThanGrowing() {
        // Offer far more than the queue can hold, the way a fast downlink does, and assert the
        // resident size never exceeds either bound at ANY point — not just at the end, which a
        // queue that grew and then drained would also satisfy.
        var queue = makeQueue()
        var peakPackets = 0
        var peakBytes = 0

        for _ in 0..<(ChainedPacketQueueLimits.engineQueueDepth * 20) {
            queue.enqueue(packet(Self.mtu))
            peakPackets = max(peakPackets, queue.count)
            peakBytes = max(peakBytes, queue.byteCount)
            XCTAssertLessThanOrEqual(queue.count, queue.limits.maximumPackets)
            XCTAssertLessThanOrEqual(queue.byteCount, queue.limits.maximumBytes)
        }

        XCTAssertEqual(peakPackets, queue.limits.maximumPackets, "the queue should reach its bound")
        XCTAssertGreaterThan(peakBytes, 0)

        // Exact, not `> 0`. The shed counters are what the tunnel reports instead of inferring
        // congestion from a throughput dip, so an arithmetic error in them is a diagnostic that
        // lies — and `> 0` is satisfied by every wrong answer above zero.
        //
        // The expectation is computed from the offered load rather than read back from the
        // queue: offered minus what it can still be holding. Deriving it from `queue` would
        // make the assertion agree with whatever the counters say.
        let offered = ChainedPacketQueueLimits.engineQueueDepth * 20
        XCTAssertEqual(
            queue.shedPacketCount, offered - queue.count,
            "every offered packet is either resident or shed, exactly once")
        XCTAssertEqual(
            queue.shedByteCount, (offered - queue.count) * Self.mtu,
            "shed bytes must match the shed packets, not merely be positive")
    }

    func testTheByteBoundHoldsWhenPacketsAreLargerThanTheMTUAssumption() {
        // The reason a packet count is not enough. With a generous packet bound and a tight
        // byte bound, oversized arrivals must be held to the BYTES — otherwise 256 jumbo
        // buffers is megabytes of resident memory inside a ~50 MB process.
        var queue = makeQueue(packets: 1000, bytes: 64 * 1024)
        for _ in 0..<500 {
            queue.enqueue(packet(9000))
            XCTAssertLessThanOrEqual(queue.byteCount, 64 * 1024)
        }
        XCTAssertLessThanOrEqual(queue.byteCount, 64 * 1024)
        XCTAssertEqual(
            queue.shedPacketCount, 500 - queue.count,
            "every offered packet is either resident or shed, exactly once")
        XCTAssertEqual(queue.shedByteCount, (500 - queue.count) * 9000)
    }

    func testAFullQueueDoesNotAdmitOneMoreThanItsLimit() {
        // The off-by-one that makes a bound advisory: checking `count > limit` AFTER appending
        // leaves the queue one over for as long as nothing else arrives.
        var queue = makeQueue(packets: 3, bytes: 3 * Self.mtu)
        for _ in 0..<10 {
            queue.enqueue(packet(Self.mtu))
            XCTAssertLessThanOrEqual(queue.count, 3)
        }
        XCTAssertEqual(queue.count, 3)
    }

    // MARK: - Which packet is dropped, and why it differs from the engine

    func testTheOldestIsEvictedSoQueueingDelayStaysBounded() {
        // A packet older than the path RTT has already been retransmitted by TCP, so
        // delivering it spends bandwidth on a duplicate. Evicting the oldest delivers more
        // useful bytes than refusing the newest, and it keeps the delay through a full queue
        // at one drain rather than pinning it at the full depth.
        var queue = makeQueue(packets: 3, bytes: 3 * Self.mtu)
        for marker in UInt8(1)...UInt8(3) {
            queue.enqueue(packet(Self.mtu, fill: marker))
        }
        let admission = queue.enqueue(packet(Self.mtu, fill: 4))
        XCTAssertEqual(admission, .admittedAfterEvicting(packets: 1, bytes: Self.mtu))

        // 1 is gone; 2, 3, 4 remain in order.
        XCTAssertEqual(queue.dequeue()?.first, 2)
        XCTAssertEqual(queue.dequeue()?.first, 3)
        XCTAssertEqual(queue.dequeue()?.first, 4)
        XCTAssertNil(queue.dequeue())
    }

    func testEvictionRemovesAsManyAsTheArrivalNeeds() {
        // One large arrival can require several small evictions. Evicting exactly one would
        // leave the byte bound broken.
        var queue = makeQueue(packets: 100, bytes: 1000)
        for _ in 0..<10 { queue.enqueue(packet(100)) }
        XCTAssertEqual(queue.byteCount, 1000)

        let admission = queue.enqueue(packet(450))
        XCTAssertEqual(admission, .admittedAfterEvicting(packets: 5, bytes: 500))
        XCTAssertLessThanOrEqual(queue.byteCount, 1000)
        XCTAssertEqual(queue.byteCount, 950)
    }

    func testTheDepthCeilingIsReadFromTheEngineNotRestated() throws {
        // Derived, not chosen: a queue deeper than the one it feeds adds latency and resident
        // memory without adding throughput. Read from the vendored engine so a toolchain or
        // upstream bump cannot leave our ceiling and the engine's silently disagreeing — the
        // same discipline the retransmit floor uses for REKEY_TIMEOUT.
        let noise = try readSource(.wireGuardCoreVendoredNoise)
        let match = try XCTUnwrap(
            noise.range(of: #"MAX_QUEUE_DEPTH: usize = (\d+)"#, options: .regularExpression),
            "MAX_QUEUE_DEPTH is no longer declared the way this test reads it"
        )
        let engineDepth = try XCTUnwrap(
            Int(noise[match].split(separator: "=").last?.trimmingCharacters(in: .whitespaces) ?? ""),
            "could not read MAX_QUEUE_DEPTH's value"
        )
        XCTAssertEqual(ChainedPacketQueueLimits.engineQueueDepth, engineDepth)
    }

    func testTheEngineRefusesTheNewestWhichIsWhyThisQueueSaysWhyItDiffers() throws {
        // Pins the asymmetry the type comment explains. If upstream ever changes
        // `queue_packet` to evict instead of refuse, the rationale here needs revisiting
        // rather than silently describing behaviour that no longer differs.
        let noise = try readSource(.wireGuardCoreVendoredNoise)
        let block = try XCTUnwrap(
            noise.range(of: #"fn queue_packet\([\s\S]{0,400}?\n    \}"#, options: .regularExpression),
            "queue_packet is no longer shaped the way this test reads it"
        )
        let body = String(noise[block])
        XCTAssertTrue(
            body.contains("< MAX_QUEUE_DEPTH"),
            "the engine still bounds by depth"
        )
        XCTAssertTrue(
            body.contains("push_back"),
            "the engine still appends, refusing the arrival when full rather than evicting"
        )
        XCTAssertFalse(
            body.contains("pop_front"),
            "the engine now evicts; this queue's differing discipline needs re-justifying"
        )
    }

    // MARK: - Refusals

    func testAPacketLargerThanTheWholeBudgetIsRefusedWithoutEmptyingTheQueue() {
        // Evicting everything for something that still would not fit discards live traffic and
        // gains nothing.
        var queue = makeQueue(packets: 10, bytes: 1000)
        for _ in 0..<5 { queue.enqueue(packet(100)) }
        let before = queue.count

        let admission = queue.enqueue(packet(2000))
        XCTAssertEqual(admission, .refusedOversized(bytes: 2000, limit: 1000))
        XCTAssertEqual(queue.count, before, "the queue must be untouched")
        XCTAssertEqual(queue.byteCount, 500)
    }

    func testEmptyPacketsAreRefusedSoTheyCannotConsumeTheBudget() {
        var queue = makeQueue(packets: 4, bytes: 4 * Self.mtu)
        XCTAssertEqual(queue.enqueue([]), .refusedEmpty)
        XCTAssertTrue(queue.isEmpty)
        XCTAssertEqual(queue.shedPacketCount, 1)
    }

    func testAZeroCapacityQueueRefusesEverythingRatherThanTrapping() {
        // Degenerate limits are a caller bug, not a crash. In an extension a trap is a tunnel
        // abort, which drops the user to no protection at all.
        var queue = makeQueue(packets: 0, bytes: 0)
        XCTAssertFalse(queue.enqueue(packet(10)).wasQueued)
        XCTAssertTrue(queue.isEmpty)
        XCTAssertNil(queue.dequeue())
    }

    func testNoPacketCapacityIsNotReportedAsOversized() {
        // A packet well inside the byte budget, refused only because there is no packet
        // capacity. Calling that "oversized" sends whoever reads the device log hunting for a
        // jumbo frame that does not exist.
        var queue = makeQueue(packets: 0, bytes: 1000)
        let admission = queue.enqueue(packet(10))
        XCTAssertEqual(admission, .refusedNoCapacity)
        XCTAssertEqual(admission.logValue, "refused-no-capacity")
        XCTAssertNotEqual(admission, .refusedOversized(bytes: 10, limit: 1000))
    }

    func testAnOversizedPacketIsStillReportedAsOversized() {
        var queue = makeQueue(packets: 10, bytes: 1000)
        XCTAssertEqual(
            queue.enqueue(packet(2000)), .refusedOversized(bytes: 2000, limit: 1000))
    }

    // MARK: - The bound is on memory held, not on bytes counted

    func testAShortPacketCannotPinALargeBackingBuffer() {
        // Copy-on-write is the hole. `[UInt8]` handed over by a caller keeps ITS buffer when
        // appended, so a multi-megabyte allocation trimmed to a few bytes would be retained in
        // full while the queue reported a handful of bytes — the accounting measures `count`
        // and the memory is `capacity`. The jetsam bound this type exists for would be
        // defeated by a queue that believed it was 300 KB and was holding hundreds of MB.
        var oversizedBacking = [UInt8]()
        oversizedBacking.reserveCapacity(4 * 1024 * 1024)
        oversizedBacking.append(contentsOf: repeatElement(0xAB, count: 8))
        XCTAssertGreaterThanOrEqual(oversizedBacking.capacity, 4 * 1024 * 1024)

        var queue = makeQueue(packets: 4, bytes: 4096)
        XCTAssertTrue(queue.enqueue(oversizedBacking).wasQueued)
        XCTAssertEqual(queue.byteCount, 8)

        let stored = try? XCTUnwrap(queue.dequeue())
        XCTAssertEqual(stored?.count, 8)
        // The stored copy must be sized to the packet, not to the caller's allocation.
        XCTAssertLessThan(
            stored?.capacity ?? .max, 4 * 1024 * 1024,
            "the queue retained the caller's oversized buffer"
        )
    }

    func testAnAbsurdMTUYieldsAFiniteBudgetRatherThanNoneOrATrap() throws {
        // Two failures to avoid at once, and the second is the one an earlier fix walked into.
        //
        // Trapping is unacceptable: in an extension it is a tunnel abort, dropping the user to
        // no protection at all. But saturating the budget to Int.max is WORSE than trapping in
        // the way that matters here — it leaves the packet count as the only defence, so 256
        // packets of a gigabyte each is ~256 GB resident while every admission reports success
        // inside a bound that no longer bounds.
        //
        // Clamping the MTU keeps it finite and real.
        for mtu in [Int.max, Int.max / 2, 1 << 40, 70_000] {
            let limits = try XCTUnwrap(ChainedPacketQueueLimits.forChainedTunnel(mtu: mtu))
            XCTAssertGreaterThan(limits.maximumBytes, 0, "mtu \(mtu)")
            XCTAssertLessThanOrEqual(
                limits.maximumBytes,
                ChainedPacketQueueLimits.engineQueueDepth
                    * ChainedPacketQueueLimits.maximumPlausibleMTU,
                "mtu \(mtu) produced a budget that is not a real ceiling")
        }

        // And the bound still binds: a queue built from an absurd MTU sheds rather than
        // growing, which the saturating version did not.
        var queue = ChainedPacketQueue(
            limits: try XCTUnwrap(ChainedPacketQueueLimits.forChainedTunnel(mtu: Int.max)))
        for _ in 0..<(ChainedPacketQueueLimits.engineQueueDepth * 3) {
            queue.enqueue(packet(64 * 1024))
            XCTAssertLessThanOrEqual(queue.byteCount, queue.limits.maximumBytes)
        }
        XCTAssertEqual(
            queue.shedPacketCount,
            ChainedPacketQueueLimits.engineQueueDepth * 3 - queue.count,
            "every offered packet is either resident or shed, exactly once")
        // Sized to the ENGINE's datagram ceiling, not the IP maximum: 65535 gave ~16 MB per
        // direction and over 32 MB for both, inside a ~50 MB process. A bound that large is a
        // bound in name only.
        XCTAssertLessThan(
            queue.limits.maximumBytes * 2, 4 * 1024 * 1024,
            "both directions must stay a small fraction of the process ceiling")
    }

    func testAnAbsurdPacketLimitIsClampedRatherThanAllocated() {
        // The bottom end was always clamped and the top end was not, which the ring turned
        // from a curiosity into a defect: storage is allocated eagerly at `maximumPackets`
        // slots, so ten million built ten million slots before the first packet arrived —
        // residency set by the packet bound and escaping the byte budget entirely, inside a
        // process bounded at ~50 MB. The growing array this replaced merely wasted the limit.
        //
        // Constructing the queue is part of the assertion: without the clamp this line is the
        // allocation, not a step towards it.
        let absurd = ChainedPacketQueueLimits(maximumPackets: 10_000_000, maximumBytes: 1_500)
        XCTAssertEqual(absurd.maximumPackets, ChainedPacketQueueLimits.engineQueueDepth)
        var queue = ChainedPacketQueue(limits: absurd)
        XCTAssertEqual(queue.enqueue([1, 2, 3]), .admitted)
        XCTAssertEqual(queue.count, 1)

        // And the ceiling is the engine's depth, not an arbitrary large number — a queue
        // deeper than the thing it feeds cannot raise throughput, so every slot above it is
        // pure latency and resident memory.
        XCTAssertEqual(
            ChainedPacketQueueLimits(maximumPackets: 257, maximumBytes: 4096).maximumPackets,
            256)
        XCTAssertEqual(
            ChainedPacketQueueLimits(maximumPackets: 10, maximumBytes: 4096).maximumPackets,
            10, "a limit below the ceiling must pass through untouched")
    }

    func testNegativeLimitsAreNormalizedRatherThanTrusted() {
        let limits = ChainedPacketQueueLimits(maximumPackets: -5, maximumBytes: -100)
        XCTAssertEqual(limits.maximumPackets, 0)
        XCTAssertEqual(limits.maximumBytes, 0)
    }

    // MARK: - Derived limits

    func testChainedLimitsAgreeWithTheChainedMTU() throws {
        let limits = try XCTUnwrap(ChainedPacketQueueLimits.forChainedTunnel(mtu: Self.mtu))
        XCTAssertEqual(limits.maximumPackets, ChainedPacketQueueLimits.engineQueueDepth)
        XCTAssertEqual(limits.maximumBytes, ChainedPacketQueueLimits.engineQueueDepth * Self.mtu)

        // Both bounds bind together: a full queue of MTU-sized packets hits them at the same
        // moment, so neither is decorative.
        var queue = ChainedPacketQueue(limits: limits)
        for _ in 0..<limits.maximumPackets { queue.enqueue(Array(repeating: 1, count: Self.mtu)) }
        XCTAssertEqual(queue.count, limits.maximumPackets)
        XCTAssertEqual(queue.byteCount, limits.maximumBytes)
    }

    func testBothDirectionsTogetherStayFarUnderTheProcessCeiling() throws {
        // The number that matters for INV-MEM-1. Two directions at the chained MTU is 640 KB;
        // the ceiling is ~50 MB with the engine and its session state already resident.
        let perDirection = try XCTUnwrap(
            ChainedPacketQueueLimits.forChainedTunnel(mtu: Self.mtu)).maximumBytes
        XCTAssertEqual(perDirection, 327_680)
        XCTAssertLessThan(perDirection * 2, 2 * 1024 * 1024)
    }

    func testASubMinimumMTUIsRefusedRatherThanFabricated() {
        // Clamping produced an apparently valid queue that refuses every ordinary packet as
        // oversized — a caller bug presenting as a working queue that silently drops all
        // traffic, which is the hardest shape to diagnose. A positive-but-tiny value has
        // exactly the same effect as a nonpositive one, so both are refused.
        for mtu in [0, -1, Int.min, 1, 576, TunnelRoutePlan.minimumIPv6LinkMTU - 1] {
            XCTAssertNil(ChainedPacketQueueLimits.forChainedTunnel(mtu: mtu), "mtu \(mtu)")
        }
        XCTAssertNotNil(
            ChainedPacketQueueLimits.forChainedTunnel(mtu: TunnelRoutePlan.minimumIPv6LinkMTU))
    }

    // MARK: - Lifecycle

    func testClearingForANewSessionIsNotCountedAsShedding() {
        // Those packets belong to a tunnel that no longer exists. Counting them would make
        // every reconnect look like congestion in the diagnostics.
        var queue = makeQueue()
        for _ in 0..<10 { queue.enqueue(packet(Self.mtu)) }
        let shedBefore = queue.shedPacketCount

        queue.removeAll()
        XCTAssertTrue(queue.isEmpty)
        XCTAssertEqual(queue.byteCount, 0)
        XCTAssertEqual(queue.shedPacketCount, shedBefore, "a session end is not congestion")
    }

    func testFIFOOrderIsPreservedForEverythingNotEvicted() {
        var queue = makeQueue(packets: 100, bytes: 100 * Self.mtu)
        for marker in UInt8(1)...UInt8(50) { queue.enqueue(packet(10, fill: marker)) }
        for marker in UInt8(1)...UInt8(50) {
            XCTAssertEqual(queue.dequeue()?.first, marker)
        }
        XCTAssertNil(queue.dequeue())
    }

    func testByteAccountingSurvivesInterleavedEnqueueAndDequeue() {
        // The accounting bug that only shows up in traffic: byteCount drifting from the real
        // contents, so the bound stops meaning anything after a while.
        var queue = makeQueue(packets: 8, bytes: 8 * 100)
        var expected: [Int] = []
        for step in 0..<200 {
            if step % 3 == 0, !expected.isEmpty {
                _ = queue.dequeue()
                expected.removeFirst()
            } else {
                let size = 40 + (step % 5) * 10
                if queue.enqueue(packet(size)).wasQueued {
                    expected.append(size)
                    while expected.count > 8 || expected.reduce(0, +) > 800 {
                        expected.removeFirst()
                    }
                }
            }
            XCTAssertEqual(queue.count, expected.count, "step \(step)")
            XCTAssertEqual(queue.byteCount, expected.reduce(0, +), "step \(step)")
        }
    }

    func testLogValuesNameTheOutcomeWithoutCarryingPayload() {
        XCTAssertEqual(ChainedQueueAdmission.admitted.logValue, "queued")
        XCTAssertEqual(
            ChainedQueueAdmission.admittedAfterEvicting(packets: 3, bytes: 300).logValue,
            "queued-evicting-3")
        XCTAssertEqual(
            ChainedQueueAdmission.refusedOversized(bytes: 9000, limit: 1000).logValue,
            "refused-oversized")
        XCTAssertEqual(ChainedQueueAdmission.refusedEmpty.logValue, "refused-empty")
    }

    // MARK: - The ring

    func testTheRingBehavesExactlyLikeTheShiftingArrayItReplaced() {
        // The storage changed from an array shifted by `removeFirst()` to a fixed ring with a
        // head index, because eviction runs on every arrival once the queue is full and
        // `removeFirst()` made that O(depth) — the rate mismatch this queue absorbs, made
        // worse by the absorbing.
        //
        // Refactors like that fail on modular arithmetic at the wrap, in states that are
        // tedious to hit by hand. So the oracle is the OLD implementation: a plain array with
        // `removeFirst()`, driven through the same operations, with every observable compared
        // after each step. A wrap-around bug shows up as a divergence rather than as a test
        // someone had to think to write.
        //
        // The sequence is deterministic — a fixed LCG, not `random()` — so a failure is
        // reproducible from the seed alone.
        let limits = ChainedPacketQueueLimits(maximumPackets: 8, maximumBytes: 8 * 64)
        var queue = ChainedPacketQueue(limits: limits)
        var model: [[UInt8]] = []
        var modelBytes = 0
        var seed: UInt64 = 0x5EED

        func next(_ bound: Int) -> Int {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((seed >> 33) % UInt64(bound))
        }

        for step in 0..<4_000 {
            // Skewed towards enqueue so the ring stays full and keeps wrapping, which is the
            // state the old implementation was slow in and the new one can be wrong in.
            if next(10) < 7 {
                let size = 1 + next(48)
                let packet = [UInt8](repeating: UInt8(step % 251), count: size)
                _ = queue.enqueue(packet)

                if size <= limits.maximumBytes {
                    while !model.isEmpty
                        && (model.count + 1 > limits.maximumPackets
                            || modelBytes + size > limits.maximumBytes)
                    {
                        modelBytes -= model.removeFirst().count
                    }
                    model.append(packet)
                    modelBytes += size
                }
            } else if next(20) == 0 {
                queue.removeAll()
                model.removeAll()
                modelBytes = 0
            } else {
                let dequeued = queue.dequeue()
                let expected = model.isEmpty ? nil : model.removeFirst()
                XCTAssertEqual(dequeued, expected, "step \(step)")
                modelBytes -= expected?.count ?? 0
            }

            XCTAssertEqual(queue.count, model.count, "step \(step)")
            XCTAssertEqual(queue.byteCount, modelBytes, "step \(step)")
            XCTAssertEqual(queue.isEmpty, model.isEmpty, "step \(step)")
        }

        // And the contents agree, not just the counts — draining compares every packet in
        // order, so a ring that kept the right NUMBER of packets in the wrong ORDER fails.
        while let packet = queue.dequeue() {
            XCTAssertEqual(packet, model.isEmpty ? nil : model.removeFirst())
        }
        XCTAssertTrue(model.isEmpty)
    }

    func testAVacatedRingSlotDoesNotPinItsPacket() {
        // The ring outlives its entries, so a slot left holding a packet after that packet was
        // accounted as gone keeps the buffer alive — `byteCount` falls while residency does
        // not, which is exactly the accounting-vs-residency gap this type exists to close
        // (`INV-MEM-1`). A shifting array could not have this bug; a reused ring can.
        //
        // Detected through copy-on-write rather than through the queue's own numbers, because
        // the numbers are the thing that would be lying. Mutating a uniquely-referenced
        // `[UInt8]` happens in place; if the ring still held a reference, the same mutation
        // copies and the buffer moves. So an unchanged base address proves the queue let go.
        var queue = ChainedPacketQueue(
            limits: ChainedPacketQueueLimits(maximumPackets: 4, maximumBytes: 4096))
        _ = queue.enqueue([UInt8](repeating: 7, count: 64))
        var dequeued = try! XCTUnwrap(queue.dequeue())

        let addressBefore = dequeued.withUnsafeBufferPointer { UInt(bitPattern: $0.baseAddress) }
        dequeued[0] = 1
        let addressAfter = dequeued.withUnsafeBufferPointer { UInt(bitPattern: $0.baseAddress) }
        XCTAssertEqual(
            addressBefore, addressAfter,
            "the dequeued packet was copied on write, so the ring still holds its buffer")

        // Same property for eviction, which is the path that runs on every arrival once full.
        var evicting = ChainedPacketQueue(
            limits: ChainedPacketQueueLimits(maximumPackets: 1, maximumBytes: 4096))
        _ = evicting.enqueue([UInt8](repeating: 3, count: 64))
        _ = evicting.enqueue([UInt8](repeating: 4, count: 64))
        var survivor = try! XCTUnwrap(evicting.dequeue())
        let survivorBefore = survivor.withUnsafeBufferPointer { UInt(bitPattern: $0.baseAddress) }
        survivor[0] = 9
        let survivorAfter = survivor.withUnsafeBufferPointer { UInt(bitPattern: $0.baseAddress) }
        XCTAssertEqual(survivorBefore, survivorAfter)

        // And a reused slot starts clean rather than inheriting the packet it used to hold.
        queue.removeAll()
        XCTAssertEqual(queue.byteCount, 0)
        _ = queue.enqueue([9])
        XCTAssertEqual(queue.count, 1)
        XCTAssertEqual(queue.byteCount, 1)
        XCTAssertEqual(queue.dequeue(), [9])
    }

    /// The borrowed overload copies ONCE — asserted on the function's shape, not its results.
    ///
    /// 🔴 THE ASSERTIONS BELOW CANNOT CATCH THE DEFECT THIS TEST IS NAMED FOR, and that is a
    /// property of the defect rather than a weakness in them. Replacing the whole body with
    /// `enqueue([UInt8](packet))` — the two-copy congestion path the doc block names — leaves the
    /// queue byte-for-byte identical: same `count`, same `byteCount`, same dequeued bytes, same
    /// `.refusedEmpty` / `.refusedOversized`. The difference is one allocation and one memcpy per
    /// parked packet, on the congestion path, where memory and CPU pressure are already highest.
    ///
    /// So the one-copy strategy is pinned STRUCTURALLY: the overload must build its own compact
    /// buffer and must not delegate to the array form. The behavioural assertions stay because
    /// they cover what they always covered — that the borrowed path round-trips faithfully and
    /// refuses the same shapes (sweep, PR #623).
    func testTheBorrowedOverloadDoesNotDelegateToTheArrayForm() throws {
        let source = try readSource(.chainedPacketQueue)
        let borrowed = try sourceBlock(
            in: source,
            startingAt: "public mutating func enqueue(_ packet: UnsafeRawBufferPointer) -> ChainedQueueAdmission {",
            endingBefore: "/// Offers a packet, evicting the oldest as needed to stay inside both bounds.")
        XCTAssertTrue(
            borrowed.contains("owned.append(contentsOf: packet)"),
            "the borrowed overload must make its OWN compact copy straight from the buffer")
        for delegation in ["enqueue([UInt8](", "enqueue(Array(", "return enqueue("] {
            XCTAssertFalse(
                borrowed.contains(delegation),
                "delegating to the array form costs two copies of every parked packet — one to "
                    + "build the `[UInt8]`, one for the queue's own compact storage — and no "
                    + "observable queue state can tell the two apart")
        }
    }

    func testABorrowedPacketIsCopiedExactlyOnce() {
        // The congestion path used to go through the array form: one copy to make the `[UInt8]`,
        // one more for the queue's own compact storage. Double allocation and memcpy exactly
        // where memory and CPU pressure are highest, and a contradiction of this type's stated
        // one-copy-per-packet design.
        var queue = ChainedPacketQueue(limits: ChainedPacketQueueLimits.forChainedTunnel(mtu: 1280)!)
        let bytes: [UInt8] = Array(repeating: 0xC3, count: 400)

        bytes.withUnsafeBytes { _ = queue.enqueue($0) }

        XCTAssertEqual(queue.count, 1)
        XCTAssertEqual(queue.byteCount, 400)
        XCTAssertEqual(queue.dequeue(), bytes, "the borrowed bytes did not survive the copy")

        // The refusals behave identically to the array form, or the two overloads would disagree
        // about what the bounds mean.
        let empty: [UInt8] = []
        empty.withUnsafeBytes { XCTAssertEqual(queue.enqueue($0), .refusedEmpty) }
        let huge: [UInt8] = Array(repeating: 0, count: queue.limits.maximumBytes + 1)
        huge.withUnsafeBytes {
            guard case .refusedOversized = queue.enqueue($0) else {
                return XCTFail("an oversized borrowed packet was admitted")
            }
        }
    }
}
