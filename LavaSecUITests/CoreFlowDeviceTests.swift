import XCTest
import LavaSecCore

final class CoreFlowDeviceTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testDNSParsingNormalizationAndBlockedResponsesOnDevice() throws {
        let query = dnsQuery(id: 0x1234, domain: "Ads.Example.COM", type: DNSRecordType.a.rawValue)
        let question = try DNSMessage.parseQuestion(from: query)

        XCTAssertEqual(question.transactionID, 0x1234)
        XCTAssertEqual(question.domain, "Ads.Example.COM")
        XCTAssertEqual(question.normalizedDomain, "ads.example.com")
        XCTAssertEqual(question.recordType, .a)

        let blocked = try DNSMessage.blockedResponse(for: query, question: question, ttl: 60)
        XCTAssertEqual(readUInt16(blocked, at: 0), 0x1234)
        XCTAssertEqual(readUInt16(blocked, at: 4), 1)
        XCTAssertEqual(readUInt16(blocked, at: 6), 1)
        XCTAssertEqual(Array(blocked.suffix(4)), [0, 0, 0, 0])

        let httpsQuery = dnsQuery(id: 0x5678, domain: "svc.example.com", type: DNSRecordType.https.rawValue)
        let httpsBlocked = try DNSMessage.blockedResponse(for: httpsQuery, ttl: 60)
        XCTAssertEqual(readUInt16(httpsBlocked, at: 0), 0x5678)
        XCTAssertEqual(readUInt16(httpsBlocked, at: 6), 0)
    }

    func testFilterDecisionPrecedenceAndNormalizedDomainsOnDevice() throws {
        var blockRules = DomainRuleSet()
        try blockRules.insert(domain: "example.com", matchesSubdomains: true)

        var allowRules = DomainRuleSet()
        try allowRules.insert(domain: "allowed.example.com", matchesSubdomains: false)

        var threatRules = DomainRuleSet()
        try threatRules.insert(domain: "dangerous.example.com", matchesSubdomains: false)

        let snapshot = FilterSnapshot(
            blockRules: blockRules,
            allowRules: allowRules,
            nonAllowableThreatRules: threatRules
        )

        XCTAssertEqual(
            snapshot.decision(forNormalizedDomain: "allowed.example.com"),
            FilterDecision(action: .allow, reason: .localAllowlist)
        )
        XCTAssertEqual(
            snapshot.decision(forNormalizedDomain: "dangerous.example.com"),
            FilterDecision(action: .block, reason: .threatGuardrail)
        )
        XCTAssertEqual(
            snapshot.decision(forNormalizedDomain: "sub.example.com"),
            FilterDecision(action: .block, reason: .blocklist)
        )
        XCTAssertEqual(snapshot.decision(forNormalizedDomain: "unknown.test"), .defaultAllow)
    }

    func testDoHValidationRestoresTransactionIDAndRejectsWrongQuestionOnDevice() throws {
        let query = dnsQuery(id: 0xCAFE, domain: "allowed.example.com", type: DNSRecordType.a.rawValue)
        let response = try DNSWireMessage.clearingTransactionID(in: DNSMessage.blockedResponse(for: query))
        let httpResponse = try XCTUnwrap(HTTPURLResponse(
            url: URL(string: "https://dns.example/dns-query")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/dns-message"]
        ))

        let validated = try DNSOverHTTPSRequest.validatedDNSResponse(
            body: response,
            response: httpResponse,
            originalQuery: query
        )
        XCTAssertEqual(DNSWireMessage.transactionID(in: validated), 0xCAFE)
        XCTAssertTrue(DNSWireMessage.isValidResponse(validated, matching: query))

        let differentQuestion = dnsQuery(id: 0xCAFE, domain: "different.example.com", type: DNSRecordType.a.rawValue)
        XCTAssertThrowsError(try DNSOverHTTPSRequest.validatedDNSResponse(
            body: response,
            response: httpResponse,
            originalQuery: differentQuestion
        ))
    }

    func testDNSWireTransactionIDRewritingOnDevice() throws {
        let query = dnsQuery(id: 0x1111, domain: "cache.example.com", type: DNSRecordType.a.rawValue)
        let secondQuery = dnsQuery(id: 0x2222, domain: "cache.example.com", type: DNSRecordType.a.rawValue)
        let response = try DNSMessage.blockedResponse(for: query)

        let cached = DNSWireMessage.clearingTransactionID(in: response)
        XCTAssertEqual(DNSWireMessage.transactionID(in: cached), 0)

        let rewritten = DNSWireMessage.replacingTransactionID(in: cached, from: secondQuery)
        XCTAssertEqual(DNSWireMessage.transactionID(in: rewritten), 0x2222)
        XCTAssertTrue(DNSWireMessage.isValidResponse(rewritten, matching: secondQuery))
    }

    func testDeviceDNSFallbackRefreshPolicyOnDevice() {
        XCTAssertEqual(
            DeviceDNSFallbackPolicy.refreshedResolverAddresses(
                current: ["1.1.1.1"],
                captured: [],
                preserveOnEmptyCapture: true
            ),
            ["1.1.1.1"]
        )
        XCTAssertEqual(
            DeviceDNSFallbackPolicy.refreshedResolverAddresses(
                current: ["1.1.1.1"],
                captured: [],
                preserveOnEmptyCapture: false
            ),
            []
        )
        XCTAssertEqual(
            DeviceDNSFallbackPolicy.refreshedResolverAddresses(
                current: ["1.1.1.1"],
                captured: ["9.9.9.9", "149.112.112.112"],
                preserveOnEmptyCapture: true
            ),
            ["9.9.9.9", "149.112.112.112"]
        )
    }

    @MainActor
    func testLiveVPNDNSPathAllowsAndBlocksHostedProbeDomainsOnDevice() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Live VPN DNS smoke coverage requires a physical device.")
        #else
        let app = XCUIApplication()
        app.launchArguments = [
            "-hasSeenLavaOnboarding", "YES",
            "-lava-live-dns-smoke-test",
            "-lava-live-dns-smoke-custom-resolver", "tls://dns.quad9.net"
        ]
        app.launchEnvironment = ["LAVA_UI_TEST_RESET_SECURITY": "1"]
        app.launch()

        XCTAssertTrue(app.staticTexts["Guard"].waitForExistence(timeout: 10))
        XCTAssertTrue(
            app.staticTexts["lavaLiveDNSSmokeStatus"].waitForExistence(timeout: 5),
            "Live DNS smoke status hook should be visible in the device test build."
        )

        if app.buttons["Turn Off"].firstMatch.waitForExistence(timeout: 2) {
            tapProtectionPrimaryAction(in: app)
            XCTAssertTrue(app.buttons["Turn On"].firstMatch.waitForExistence(timeout: 20))
        }

        tapProtectionPrimaryAction(in: app)
        allowSystemVPNPermissionIfNeeded()

        XCTAssertTrue(
            app.staticTexts["lavaLiveDNSSmokeVPNConnected"].waitForExistence(timeout: 60),
            "Lava should report the packet tunnel as connected before DNS smoke probes run."
        )

        app.buttons["lavaLiveDNSSmokeRunButton"].firstMatch.tap()
        XCTAssertTrue(
            app.staticTexts["lavaLiveDNSSmokePassed"].waitForExistence(timeout: 45),
            app.staticTexts["lavaLiveDNSSmokeStatus"].firstMatch.label
        )

        let stopButton = app.buttons["lavaLiveDNSSmokeStopButton"].firstMatch
        if stopButton.waitForExistence(timeout: 2), stopButton.isEnabled {
            stopButton.tap()
            XCTAssertTrue(app.staticTexts["lavaLiveDNSSmokeVPNStatus"].waitForExistence(timeout: 20))
        }
        #endif
    }

    private func dnsQuery(id: UInt16, domain: String, type: UInt16) -> Data {
        var data = Data()
        appendUInt16(id, to: &data)
        appendUInt16(0x0100, to: &data)
        appendUInt16(1, to: &data)
        appendUInt16(0, to: &data)
        appendUInt16(0, to: &data)
        appendUInt16(0, to: &data)

        for label in domain.split(separator: ".") {
            let bytes = Array(label.utf8)
            data.append(UInt8(bytes.count))
            data.append(contentsOf: bytes)
        }

        data.append(0)
        appendUInt16(type, to: &data)
        appendUInt16(1, to: &data)
        return data
    }

    private func appendUInt16(_ value: UInt16, to data: inout Data) {
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }

    private func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
    }

    @MainActor
    private func tapProtectionPrimaryAction(in app: XCUIApplication) {
        let turnOffButton = app.buttons["Turn Off"].firstMatch
        if turnOffButton.waitForExistence(timeout: 2) {
            turnOffButton.tap()
            return
        }

        let turnOnButton = app.buttons["Turn On"].firstMatch
        if turnOnButton.waitForExistence(timeout: 2) {
            turnOnButton.tap()
            return
        }

        let turnOffText = app.staticTexts["Turn Off"].firstMatch
        if turnOffText.waitForExistence(timeout: 2) {
            turnOffText.tap()
            return
        }

        let turnOnText = app.staticTexts["Turn On"].firstMatch
        XCTAssertTrue(turnOnText.waitForExistence(timeout: 5), "Missing protection action button")
        turnOnText.tap()
    }

    @MainActor
    private func allowSystemVPNPermissionIfNeeded() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allowButton = springboard.buttons["Allow"].firstMatch
        if allowButton.waitForExistence(timeout: 10) {
            allowButton.tap()
        }
    }
}
