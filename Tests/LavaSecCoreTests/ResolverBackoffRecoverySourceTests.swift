import XCTest

final class ResolverBackoffRecoverySourceTests: XCTestCase {
    func testProviderClaimsRecoveryOnTheExistingBackoffQueue() throws {
        let provider = sourceCodeOnly(try readPacketTunnelProviderSource())
        let claim = try sourceBlock(in: provider,
            startingAt: "claimEncryptedRecovery: {",
            endingBefore: "resolveDoH:")
        XCTAssertTrue(sourceContainsInOrder([
            "self.resolverBackoffStateQueue.sync",
            "self.resolverBackoffPolicy.claimEncryptedRecovery(from: addresses)",
        ], in: claim))
    }
}
