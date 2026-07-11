import Foundation
import XCTest

@testable import LavaSecDNS
@testable import LavaSecKit

struct ResolverHealthTestScenario {
    var state: ResolverHealthEvidenceState
    var snapshot: TunnelHealthSnapshot

    init(
        state: ResolverHealthEvidenceState = ResolverHealthEvidenceState(),
        snapshot: TunnelHealthSnapshot = resolverHealthProviderSnapshot()
    ) {
        self.state = state
        self.snapshot = snapshot
    }

    @discardableResult
    mutating func apply(
        _ event: ResolverHealthEvent,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> ResolverHealthTransition {
        let providerOwnedSnapshot = snapshot
        let transition = ResolverHealthReducer.reduce(
            state: state,
            event: event,
            projectingOnto: snapshot
        )
        transition.projection.apply(to: &snapshot)
        state = transition.state
        XCTAssertResolverHealthProviderFieldsEqual(
            snapshot,
            providerOwnedSnapshot,
            file: file,
            line: line
        )
        return transition
    }
}

func resolverHealthProviderSnapshot(
    networkKind: TunnelNetworkKind = .wifi
) -> TunnelHealthSnapshot {
    TunnelHealthSnapshot(
        startedAt: Date(timeIntervalSince1970: 100),
        updatedAt: Date(timeIntervalSince1970: 200),
        networkKind: networkKind
    )
}

func XCTAssertResolverHealthProviderFieldsEqual(
    _ actual: TunnelHealthSnapshot,
    _ expected: TunnelHealthSnapshot,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertEqual(actual.startedAt, expected.startedAt, file: file, line: line)
    XCTAssertEqual(actual.updatedAt, expected.updatedAt, file: file, line: line)
    XCTAssertEqual(actual.networkKind, expected.networkKind, file: file, line: line)
    XCTAssertEqual(actual.cacheHitCount, expected.cacheHitCount, file: file, line: line)
    XCTAssertEqual(actual.cacheMissCount, expected.cacheMissCount, file: file, line: line)
    XCTAssertEqual(actual.coalescedQueryCount, expected.coalescedQueryCount, file: file, line: line)
    XCTAssertEqual(
        actual.lastNetworkSettingsReapplyFailureAt,
        expected.lastNetworkSettingsReapplyFailureAt,
        file: file,
        line: line
    )
    XCTAssertEqual(
        actual.lastNetworkSettingsReapplyFailureReason,
        expected.lastNetworkSettingsReapplyFailureReason,
        file: file,
        line: line
    )
    XCTAssertEqual(
        actual.networkSettingsReapplyFailureCount,
        expected.networkSettingsReapplyFailureCount,
        file: file,
        line: line
    )
    XCTAssertEqual(
        actual.failClosedServedQueryCount,
        expected.failClosedServedQueryCount,
        file: file,
        line: line
    )
    XCTAssertEqual(actual.lastFailClosedAt, expected.lastFailClosedAt, file: file, line: line)
    XCTAssertEqual(
        actual.lastFailClosedReason,
        expected.lastFailClosedReason,
        file: file,
        line: line
    )
}
