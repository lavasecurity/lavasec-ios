import XCTest
@testable import LavaSecCore

final class ResolverBootstrapServiceTests: XCTestCase {
    private final class ResolverSpy: @unchecked Sendable {
        private let lock = NSLock()
        private var resolveCount = 0
        var result = ResolverBootstrapService.ResolvedAddresses(ipv4: ["1.2.3.4"], ipv6: ["::1"])
        var gate: DispatchSemaphore?

        var count: Int {
            lock.lock()
            defer {
                lock.unlock()
            }
            return resolveCount
        }

        func resolve(_ hostname: String) -> ResolverBootstrapService.ResolvedAddresses {
            gate?.wait()
            lock.lock()
            resolveCount += 1
            let result = result
            lock.unlock()
            return result
        }
    }

    private func makeService(spy: ResolverSpy, queue: DispatchQueue) -> ResolverBootstrapService {
        ResolverBootstrapService(
            resolveAddresses: { hostname in
                spy.resolve(hostname)
            },
            queue: queue
        )
    }

    func testPrewarmResolvesOnceAndServesFromCache() {
        let spy = ResolverSpy()
        let queue = DispatchQueue(label: "test.bootstrap")
        let service = makeService(spy: spy, queue: queue)

        XCTAssertNil(service.cachedAddresses(forHostname: "doq.example"))

        service.prewarm(hostname: "doq.example")
        queue.sync {}

        XCTAssertEqual(
            service.cachedAddresses(forHostname: "doq.example"),
            ResolverBootstrapService.ResolvedAddresses(ipv4: ["1.2.3.4"], ipv6: ["::1"])
        )

        service.prewarm(hostname: "doq.example")
        queue.sync {}

        XCTAssertEqual(spy.count, 1, "A cached hostname must not resolve again.")
    }

    func testConcurrentPrewarmsCoalesceWhileLookupIsInFlight() {
        let spy = ResolverSpy()
        let gate = DispatchSemaphore(value: 0)
        spy.gate = gate
        let queue = DispatchQueue(label: "test.bootstrap")
        let service = makeService(spy: spy, queue: queue)

        service.prewarm(hostname: "doq.example")
        service.prewarm(hostname: "doq.example")
        service.prewarm(hostname: "doq.example")
        gate.signal()
        queue.sync {}

        XCTAssertEqual(spy.count, 1, "Duplicate pre-warms must join the in-flight lookup.")
        XCTAssertNotNil(service.cachedAddresses(forHostname: "doq.example"))
    }

    func testEmptyResultsAreNotCachedSoRetriesResolveAgain() {
        let spy = ResolverSpy()
        spy.result = ResolverBootstrapService.ResolvedAddresses(ipv4: [], ipv6: [])
        let queue = DispatchQueue(label: "test.bootstrap")
        let service = makeService(spy: spy, queue: queue)

        service.prewarm(hostname: "doq.example")
        queue.sync {}

        XCTAssertNil(service.cachedAddresses(forHostname: "doq.example"))

        spy.result = ResolverBootstrapService.ResolvedAddresses(ipv4: ["9.9.9.9"], ipv6: [])
        service.prewarm(hostname: "doq.example")
        queue.sync {}

        XCTAssertEqual(spy.count, 2, "A failed lookup must not poison the cache.")
        XCTAssertEqual(
            service.cachedAddresses(forHostname: "doq.example"),
            ResolverBootstrapService.ResolvedAddresses(ipv4: ["9.9.9.9"], ipv6: [])
        )
    }

    func testInvalidateAllDropsCacheAndAllowsReResolution() {
        let spy = ResolverSpy()
        let queue = DispatchQueue(label: "test.bootstrap")
        let service = makeService(spy: spy, queue: queue)

        service.prewarm(hostname: "doq.example")
        queue.sync {}
        service.invalidateAll()

        XCTAssertNil(service.cachedAddresses(forHostname: "doq.example"))

        service.prewarm(hostname: "doq.example")
        queue.sync {}

        XCTAssertEqual(spy.count, 2)
        XCTAssertNotNil(service.cachedAddresses(forHostname: "doq.example"))
    }

    func testHostnamesAreCachedIndependently() {
        let spy = ResolverSpy()
        let queue = DispatchQueue(label: "test.bootstrap")
        let service = makeService(spy: spy, queue: queue)

        service.prewarm(hostname: "a.example")
        service.prewarm(hostname: "b.example")
        queue.sync {}

        XCTAssertEqual(spy.count, 2)
        XCTAssertNotNil(service.cachedAddresses(forHostname: "a.example"))
        XCTAssertNotNil(service.cachedAddresses(forHostname: "b.example"))
        XCTAssertNil(service.cachedAddresses(forHostname: "c.example"))
    }
}
