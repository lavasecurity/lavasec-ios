import Foundation
import XCTest
@testable import LavaSecCore
@testable import LavaSecKit
@testable import LavaSecDNS

/// SEC-1 connect-time peer-IP validation. The blocklist source fetcher resolves each host
/// ONCE, refuses unless every resolved address is public, and pins the connection to a
/// validated address — closing the DNS-resolves-to-private residual (`printer.lan`, DNS
/// rebinding) that the IP-literal-only URL gate could not see, for BOTH the initial URL and
/// every redirect hop. These exercise the gate and the HTTP framing directly (no network).
final class PinnedPublicHTTPSFetcherTests: XCTestCase {

    // A resolver that returns a fixed answer for any host, and records that it was consulted.
    // `@unchecked Sendable`: the injected resolver runs synchronously on the test thread, so the
    // unsynchronized counter is safe here.
    private final class StubResolver: @unchecked Sendable {
        private(set) var callCount = 0
        private let answer: @Sendable (String) throws -> [ResolvedIPAddress]

        init(_ answer: @escaping @Sendable (String) throws -> [ResolvedIPAddress]) {
            self.answer = answer
        }

        var resolver: HostAddressResolver {
            { [self] host in
                callCount += 1
                return try answer(host)
            }
        }
    }

    private func address(_ literal: String) -> ResolvedIPAddress {
        guard let address = ResolvedIPAddress(literal: literal) else {
            fatalError("test fixture is not a valid IP literal: \(literal)")
        }
        return address
    }

    private func assertRefused(
        host: String,
        resolvedTo answer: [ResolvedIPAddress],
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let resolver = StubResolver { _ in answer }
        XCTAssertThrowsError(
            try PinnedPublicHTTPSFetcher.pinnedAddresses(forHost: host, resolver: resolver.resolver),
            message,
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(
                error as? NetworkEndpointValidationError,
                .privateNetworkNotAllowed,
                "\(message): expected privateNetworkNotAllowed",
                file: file,
                line: line
            )
        }
    }

    // MARK: - Connect-time gate: hostname → private answer is refused

    func testRefusesHostResolvingToPrivateIPv4() {
        assertRefused(host: "printer.lan", resolvedTo: [address("10.0.0.5")], "RFC1918 10/8")
        assertRefused(host: "printer.lan", resolvedTo: [address("192.168.1.10")], "RFC1918 192.168/16")
        assertRefused(host: "printer.lan", resolvedTo: [address("172.16.5.5")], "RFC1918 172.16/12")
    }

    func testRefusesHostResolvingToLoopback() {
        assertRefused(host: "evil.example.com", resolvedTo: [address("127.0.0.1")], "IPv4 loopback")
        assertRefused(host: "evil.example.com", resolvedTo: [address("::1")], "IPv6 loopback")
    }

    func testRefusesHostResolvingToOtherNonPublicScopes() {
        assertRefused(host: "h", resolvedTo: [address("169.254.10.10")], "link-local")
        assertRefused(host: "h", resolvedTo: [address("100.64.0.1")], "CGNAT shared space")
        assertRefused(host: "h", resolvedTo: [address("0.0.0.0")], "unspecified")
        assertRefused(host: "h", resolvedTo: [address("224.0.0.1")], "multicast")
        assertRefused(host: "h", resolvedTo: [address("192.0.2.5")], "TEST-NET-1 reserved")
        assertRefused(host: "h", resolvedTo: [address("fe80::1")], "IPv6 link-local")
        assertRefused(host: "h", resolvedTo: [address("fc00::1")], "IPv6 ULA")
    }

    func testRefusesMixedPublicAndPrivateAnswers() {
        // A hostile authoritative server that mixes a public decoy with a private target must
        // fail closed wholesale — the caller must never pin the private one, and a mixed answer
        // is itself a rebinding signal.
        assertRefused(
            host: "rebind.example.com",
            resolvedTo: [address("93.184.216.34"), address("10.1.2.3")],
            "public decoy + private target"
        )
    }

    func testRefusesEmptyResolution() {
        assertRefused(host: "nx.example.com", resolvedTo: [], "no address to confirm as public")
    }

    // MARK: - Connect-time gate: mapped / NAT64 embedded private is refused

    func testRefusesNAT64EmbeddedPrivateButAllowsEmbeddedPublic() {
        // 64:ff9b::/96 with 127.0.0.1 embedded — a NAT64 network would route this to loopback.
        assertRefused(host: "h", resolvedTo: [address("64:ff9b::7f00:1")], "NAT64-embedded loopback")
        // 64:ff9b::/96 with a public IPv4 (93.184.216.34) embedded is allowed.
        let publicNAT64 = address("64:ff9b::5db8:d822")
        XCTAssertTrue(publicNAT64.isPublic, "NAT64-embedded PUBLIC IPv4 is public")
    }

    func testRefusesIPv4MappedPrivateButAllowsMappedPublic() {
        assertRefused(host: "h", resolvedTo: [address("::ffff:127.0.0.1")], "IPv4-mapped loopback")
        assertRefused(host: "h", resolvedTo: [address("::ffff:10.0.0.1")], "IPv4-mapped private")
        XCTAssertTrue(address("::ffff:93.184.216.34").isPublic, "IPv4-mapped PUBLIC IPv4 is public")
    }

    func testResolvedAddressClassifierFailsClosedOnWrongLength() {
        // A malformed resolver answer must never be treated as public.
        XCTAssertFalse(NetworkEndpointValidator.isPublicResolvedIPv4(octets: [1, 2, 3]), "short IPv4")
        XCTAssertFalse(NetworkEndpointValidator.isPublicResolvedIPv4(octets: [1, 2, 3, 4, 5]), "long IPv4")
        XCTAssertFalse(NetworkEndpointValidator.isPublicResolvedIPv6(bytes: Array(repeating: 0x20, count: 8)), "short IPv6")
        XCTAssertTrue(NetworkEndpointValidator.isPublicResolvedIPv4(octets: [93, 184, 216, 34]), "well-formed public IPv4")
    }

    // MARK: - Connect-time gate: public host is allowed and pinned

    func testAllowsPublicHostAndReturnsPinnedAddress() throws {
        let answer = [address("93.184.216.34")]
        let resolver = StubResolver { _ in answer }
        let pinned = try PinnedPublicHTTPSFetcher.pinnedAddresses(
            forHost: "example.com",
            resolver: resolver.resolver
        )
        XCTAssertEqual(pinned.count, 1)
        XCTAssertEqual(pinned.first?.family, .ipv4)
        XCTAssertEqual(pinned.first?.presentation, "93.184.216.34")
        XCTAssertTrue(pinned.first?.isPublic == true)
        XCTAssertNotNil(pinned.first?.networkHost, "a validated address must be pinnable")
        XCTAssertEqual(resolver.callCount, 1)
    }

    func testAllowsDualStackPublicHostAndPinsBothFamilies() throws {
        let answer = [address("93.184.216.34"), address("2606:2800:220:1:248:1893:25c8:1946")]
        let resolver = StubResolver { _ in answer }
        let pinned = try PinnedPublicHTTPSFetcher.pinnedAddresses(
            forHost: "example.com",
            resolver: resolver.resolver
        )
        XCTAssertEqual(pinned.count, 2, "both public families are pinnable for connect fallback")
        XCTAssertEqual(Set(pinned.map(\.family)), [.ipv4, .ipv6])
    }

    // MARK: - Connect-time gate: IP-literal hosts skip DNS but are re-classified

    func testPublicIPLiteralHostSkipsResolver() throws {
        let resolver = StubResolver { _ in XCTFail("resolver must not run for an IP literal"); return [] }
        let pinned = try PinnedPublicHTTPSFetcher.pinnedAddresses(
            forHost: "93.184.216.34",
            resolver: resolver.resolver
        )
        XCTAssertEqual(pinned.map(\.presentation), ["93.184.216.34"])
        XCTAssertEqual(resolver.callCount, 0)
    }

    func testBracketedPublicIPv6LiteralHostSkipsResolver() throws {
        let resolver = StubResolver { _ in XCTFail("resolver must not run for an IP literal"); return [] }
        let pinned = try PinnedPublicHTTPSFetcher.pinnedAddresses(
            forHost: "[2606:4700:4700::1111]",
            resolver: resolver.resolver
        )
        XCTAssertEqual(pinned.first?.family, .ipv6)
        XCTAssertEqual(resolver.callCount, 0)
    }

    func testPrivateIPLiteralHostIsRefusedByTheGateItself() {
        // Defense in depth: even though the URL gate rejects private literals upstream, the
        // connect-time gate re-classifies so a literal can never be pinned unvalidated.
        let resolver = StubResolver { _ in XCTFail("resolver must not run for an IP literal"); return [] }
        XCTAssertThrowsError(
            try PinnedPublicHTTPSFetcher.pinnedAddresses(forHost: "10.0.0.1", resolver: resolver.resolver)
        ) { error in
            XCTAssertEqual(error as? NetworkEndpointValidationError, .privateNetworkNotAllowed)
        }
        XCTAssertEqual(resolver.callCount, 0)
    }

    // MARK: - Per-hop URL gate (initial URL + redirect targets)

    private func assertHopRefused(_ urlString: String, _ note: String) {
        let url = URL(string: urlString)!
        XCTAssertThrowsError(try PinnedPublicHTTPSFetcher.validateHopURL(url), note) { error in
            XCTAssertEqual(
                error as? NetworkEndpointValidationError,
                .privateNetworkNotAllowed,
                "\(note) must map to privateNetworkNotAllowed"
            )
        }
    }

    func testHopGateAllowsPublicHTTPS() {
        XCTAssertNoThrow(try PinnedPublicHTTPSFetcher.validateHopURL(URL(string: "https://cdn.example.net/list.txt")!))
    }

    func testHopGateRefusesHTTPDowngrade() {
        assertHopRefused("http://cdn.example.com/list.txt", "http:// downgrade")
    }

    func testHopGateRefusesNonHTTPSchemes() {
        assertHopRefused("file:///etc/passwd", "file scheme")
        assertHopRefused("data:text/plain;base64,SGk=", "data scheme")
        assertHopRefused("ftp://ftp.example.com/list.txt", "ftp scheme with a host")
    }

    func testHopGateRefusesHostlessHTTPS() throws {
        var components = URLComponents()
        components.scheme = "https"
        components.path = "/list.txt"
        let hostless = try XCTUnwrap(components.url)
        XCTAssertThrowsError(try PinnedPublicHTTPSFetcher.validateHopURL(hostless)) { error in
            XCTAssertEqual(error as? NetworkEndpointValidationError, .privateNetworkNotAllowed)
        }
    }

    func testHopGateRefusesPrivateAndLocalhostLiterals() {
        assertHopRefused("https://127.0.0.1/admin", "IPv4 loopback literal")
        assertHopRefused("https://192.168.1.1/list.txt", "private IPv4 literal")
        assertHopRefused("https://[::1]/list.txt", "IPv6 loopback literal")
        assertHopRefused("https://localhost/list.txt", "localhost name")
    }

    // MARK: - HTTP response head parsing

    func testResponseHeadParsesStatusAndHeadersCaseInsensitively() throws {
        let head = try PinnedHTTPSResponseHead(Data("HTTP/1.1 200 OK\r\nContent-Length: 5\r\nContent-Type: text/plain\r\n".utf8))
        XCTAssertEqual(head.statusCode, 200)
        XCTAssertEqual(head.value(for: "content-length"), "5")
        XCTAssertEqual(head.value(for: "CONTENT-TYPE"), "text/plain")
        XCTAssertNil(head.value(for: "location"))
    }

    func testResponseHeadParsesHTTP10AndLocation() throws {
        let head = try PinnedHTTPSResponseHead(Data("HTTP/1.0 302 Found\r\nLocation: https://cdn.example.net/x\r\n".utf8))
        XCTAssertEqual(head.statusCode, 302)
        XCTAssertEqual(head.value(for: "location"), "https://cdn.example.net/x")
    }

    func testResponseHeadRejectsMalformedStatusLine() {
        XCTAssertThrowsError(try PinnedHTTPSResponseHead(Data("garbage no status\r\n".utf8)))
        XCTAssertThrowsError(try PinnedHTTPSResponseHead(Data("HTTP/1.1\r\n".utf8)))
    }

    func testResponseHeadRedirectClassification() {
        for code in [301, 302, 303, 307, 308] {
            XCTAssertTrue(PinnedHTTPSResponseHead.isRedirect(code), "\(code) is a redirect")
        }
        for code in [200, 204, 304, 400, 404, 500] {
            XCTAssertFalse(PinnedHTTPSResponseHead.isRedirect(code), "\(code) is not a redirect")
        }
    }

    // MARK: - Streaming response parser: interim 1xx handling (#40 review R2)

    /// Holds the parser outcome across the exchange's internal queue. `@unchecked Sendable`: written
    /// once by the completion, read only after `wait(for:)` establishes the happens-before.
    private final class OutcomeBox: @unchecked Sendable {
        var value: Result<PinnedPublicHTTPSFetcher.HTTPExchangeOutcome, Error>?
    }

    /// Drive PinnedHTTPSExchange's response parser with raw bytes (DEBUG seam, no network).
    private func drainResponse(_ chunks: [String]) -> Result<PinnedPublicHTTPSFetcher.HTTPExchangeOutcome, Error> {
        let exchange = PinnedHTTPSExchange(
            address: address("93.184.216.34"),
            hostname: "example.com",
            port: 443,
            requestURL: URL(string: "https://example.com/list.txt")!,
            requestData: Data(),
            maximumByteCount: 1_000_000,
            configuration: .init()
        )
        let exp = expectation(description: "parser completes")
        let box = OutcomeBox()
        exchange.drainResponseForTesting(chunks.map { Data($0.utf8) }) { outcome in
            box.value = outcome
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2)
        return box.value ?? .failure(URLError(.unknown))
    }

    func testParserSkipsInterim1xxAndReturnsFinalResponse() {
        // 103 Early Hints (RFC 8297) then the real 200 in one packet — the CDN-on-GET shape that
        // previously threw invalidHTTPStatus(103) and made that source silently fail to sync.
        let outcome = drainResponse([
            "HTTP/1.1 103 Early Hints\r\nLink: </s.css>; rel=preload\r\n\r\n" +
            "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello",
        ])
        guard case .success(.response(let status, let body)) = outcome else {
            return XCTFail("expected a final 200 response, got \(outcome)")
        }
        XCTAssertEqual(status, 200)
        XCTAssertEqual(String(decoding: body, as: UTF8.self), "hello")
    }

    func testParserResumesAfterInterim1xxSplitAcrossChunks() {
        // Interim head and final head arrive in separate reads — the parser must resume, not stall.
        let outcome = drainResponse([
            "HTTP/1.1 100 Continue\r\n\r\n",
            "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nhi",
        ])
        guard case .success(.response(let status, let body)) = outcome else {
            return XCTFail("expected a final 200 response, got \(outcome)")
        }
        XCTAssertEqual(status, 200)
        XCTAssertEqual(String(decoding: body, as: UTF8.self), "hi")
    }

    func testParserBoundsInterim1xxFlood() {
        // A server flooding interim heads (9 > the cap of 8) must fail closed, not loop forever.
        let flood = String(repeating: "HTTP/1.1 100 Continue\r\n\r\n", count: 9)
        let outcome = drainResponse([flood + "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nhi"])
        guard case .failure = outcome else {
            return XCTFail("expected a bounded failure on an interim-1xx flood, got \(outcome)")
        }
    }

    // MARK: - Identity body decoder

    func testIdentityDecoderTrimsToContentLengthAndCompletes() throws {
        var decoder = IdentityResponseBodyDecoder(expectedLength: 5, maximumByteCount: 1_000)
        try decoder.feed(Data("HELLO WORLD".utf8))
        XCTAssertTrue(decoder.isComplete)
        XCTAssertEqual(String(data: decoder.output, encoding: .utf8), "HELLO")
    }

    func testIdentityDecoderZeroLengthCompletesAtHeadersWithoutFeed() throws {
        // A declared zero-length body (`Content-Length: 0`, or an empty 200/204) is complete the
        // instant headers are parsed — no body bytes will ever arrive to feed. `beginBody` only
        // feeds `leftover` when it is non-empty, so this MUST hold at construction. Without it, an
        // empty response on a keep-alive connection (Content-Length: 0 but no `Connection: close`,
        // so no EOF) would leave the parser waiting out the idle timeout instead of completing.
        let decoder = IdentityResponseBodyDecoder(expectedLength: 0, maximumByteCount: 1_000)
        XCTAssertTrue(decoder.isComplete, "zero-length body is complete at headers, before any feed or EOF")
        XCTAssertTrue(decoder.output.isEmpty)
    }

    func testIdentityDecoderWithoutLengthCompletesAtEOF() throws {
        var decoder = IdentityResponseBodyDecoder(expectedLength: nil, maximumByteCount: 1_000)
        try decoder.feed(Data("abc".utf8))
        try decoder.feed(Data("def".utf8))
        XCTAssertFalse(decoder.isComplete, "read-to-close is not complete until EOF")
        try decoder.markEndOfStream()
        XCTAssertTrue(decoder.isComplete)
        XCTAssertEqual(String(data: decoder.output, encoding: .utf8), "abcdef")
    }

    func testIdentityDecoderTruncatedBeforeContentLengthThrows() throws {
        var decoder = IdentityResponseBodyDecoder(expectedLength: 10, maximumByteCount: 1_000)
        try decoder.feed(Data("abc".utf8))
        XCTAssertThrowsError(try decoder.markEndOfStream(), "EOF before Content-Length is a truncated body")
    }

    func testIdentityDecoderTreatsNegativeContentLengthAsReadToClose() throws {
        // A hostile / malformed `Content-Length: -1` must not trap on a negative index — it is
        // dropped and the body reads to EOF (bounded by the byte cap).
        var decoder = IdentityResponseBodyDecoder(expectedLength: -1, maximumByteCount: 1_000)
        try decoder.feed(Data("abc".utf8))
        XCTAssertFalse(decoder.isComplete)
        try decoder.markEndOfStream()
        XCTAssertEqual(String(data: decoder.output, encoding: .utf8), "abc")
    }

    func testIdentityDecoderEnforcesSizeCap() {
        var decoder = IdentityResponseBodyDecoder(expectedLength: nil, maximumByteCount: 4)
        XCTAssertThrowsError(try decoder.feed(Data("abcdef".utf8))) { error in
            XCTAssertTrue(error is BlocklistDownloadSizeLimitExceeded, "over-cap body fails closed")
        }
    }

    // MARK: - Chunked body decoder

    func testChunkedDecoderDecodesAcrossReceiveBoundaries() throws {
        // "MozillaDeveloperNetwork" split into two chunks, fed one byte at a time.
        let raw = "7\r\nMozilla\r\n9\r\nDeveloper\r\n7\r\nNetwork\r\n0\r\n\r\n"
        var decoder = ChunkedResponseBodyDecoder(maximumByteCount: 1_000)
        for byte in Data(raw.utf8) {
            try decoder.feed(Data([byte]))
        }
        XCTAssertTrue(decoder.isComplete)
        XCTAssertEqual(String(data: decoder.output, encoding: .utf8), "MozillaDeveloperNetwork")
    }

    func testChunkedDecoderIgnoresChunkExtensionsAndTrailers() throws {
        let raw = "5;name=value\r\nHELLO\r\n0\r\nX-Trailer: 1\r\n\r\n"
        var decoder = ChunkedResponseBodyDecoder(maximumByteCount: 1_000)
        try decoder.feed(Data(raw.utf8))
        XCTAssertTrue(decoder.isComplete)
        XCTAssertEqual(String(data: decoder.output, encoding: .utf8), "HELLO")
    }

    func testChunkedDecoderTruncatedStreamThrowsAtEOF() throws {
        // Missing the terminating 0-length chunk.
        var decoder = ChunkedResponseBodyDecoder(maximumByteCount: 1_000)
        try decoder.feed(Data("5\r\nHELLO\r\n".utf8))
        XCTAssertFalse(decoder.isComplete)
        XCTAssertThrowsError(try decoder.markEndOfStream(), "a chunked stream cut short is not a valid body")
    }

    func testChunkedDecoderEnforcesSizeCap() {
        var decoder = ChunkedResponseBodyDecoder(maximumByteCount: 4)
        XCTAssertThrowsError(try decoder.feed(Data("6\r\nabcdef\r\n0\r\n\r\n".utf8))) { error in
            XCTAssertTrue(error is BlocklistDownloadSizeLimitExceeded)
        }
    }

    func testChunkedDecoderBoundsTrailerFlood() {
        // A hostile host streams the terminating 0-chunk then endless small trailer lines —
        // each resets the idle timeout and never grows the body, so without a trailer cap the
        // sync would stay alive forever. It must fail closed.
        var decoder = ChunkedResponseBodyDecoder(maximumByteCount: 5_000_000)
        var flood = "0\r\n"
        for _ in 0..<3_000 {
            flood += "X-Pad: aaaaaaaaaaaaaaaaaaaaaaaa\r\n"
        }
        XCTAssertThrowsError(try decoder.feed(Data(flood.utf8))) { error in
            XCTAssertTrue(error is URLError, "unbounded chunked trailers must fail closed")
        }
        XCTAssertFalse(decoder.isComplete)
    }

    func testChunkedDecoderRejectsMalformedSize() {
        var decoder = ChunkedResponseBodyDecoder(maximumByteCount: 1_000)
        XCTAssertThrowsError(try decoder.feed(Data("zz\r\n".utf8)), "a non-hex chunk size is malformed")
    }

    // MARK: - Request construction

    func testRequestPinsHostHeaderAndRequestsIdentityEncoding() {
        let request = String(
            decoding: PinnedPublicHTTPSFetcher.makeRequestBytes(
                host: "example.com",
                port: 443,
                url: URL(string: "https://example.com/path/list.txt?raw=1")!
            ),
            as: UTF8.self
        )
        XCTAssertTrue(request.hasPrefix("GET /path/list.txt?raw=1 HTTP/1.1\r\n"))
        XCTAssertTrue(request.contains("\r\nHost: example.com\r\n"))
        XCTAssertTrue(request.contains("\r\nAccept-Encoding: identity\r\n"), "we never advertise gzip")
        XCTAssertTrue(request.contains("\r\nConnection: close\r\n"))
        XCTAssertTrue(request.hasSuffix("\r\n\r\n"))
    }

    func testRequestBracketsIPv6HostAndCarriesNonDefaultPort() {
        let request = String(
            decoding: PinnedPublicHTTPSFetcher.makeRequestBytes(
                host: "2606:4700::1111",
                port: 8443,
                url: URL(string: "https://[2606:4700::1111]:8443/x")!
            ),
            as: UTF8.self
        )
        XCTAssertTrue(request.contains("\r\nHost: [2606:4700::1111]:8443\r\n"))
    }

    func testAsciiHostPunycodesIDNAndStripsIPv6Brackets() {
        // getaddrinfo + SNI need the IDNA-ASCII form; URLSession punycoded it for us before.
        XCTAssertEqual(
            PinnedPublicHTTPSFetcher.asciiHost(from: URL(string: "https://bücher.example/list.txt")!),
            "xn--bcher-kva.example"
        )
        // A percent-encoded IDN decodes to Unicode via host(percentEncoded:false); it must be
        // re-encoded to punycode, not handed to getaddrinfo as Unicode.
        XCTAssertEqual(
            PinnedPublicHTTPSFetcher.asciiHost(from: URL(string: "https://b%C3%BCcher.example/list.txt")!),
            "xn--bcher-kva.example",
            "percent-encoded IDN host is normalized to IDNA-ASCII"
        )
        XCTAssertEqual(
            PinnedPublicHTTPSFetcher.asciiHost(from: URL(string: "https://[2606:4700::1111]/x")!),
            "2606:4700::1111",
            "IPv6 literal is bracket-stripped for pinning"
        )
        XCTAssertEqual(
            PinnedPublicHTTPSFetcher.asciiHost(from: URL(string: "https://cdn.example.net/x")!),
            "cdn.example.net"
        )
    }

    // MARK: - Wiring pin (anti-regression)

    func testDefaultFetcherRoutesThroughThePinnedConnectTimeFetcher() throws {
        let source = try readSource(.blocklistCatalogSync)

        XCTAssertTrue(
            source.contains("PinnedPublicHTTPSFetcher.fetch(url: url, maximumByteCount: maximumBlocklistBytes)"),
            "defaultDataFetcher must route through the IP-pinned, connect-time-validated fetcher"
        )
        // The URLSession redirect-delegate transport (which re-resolved at connect — the SSRF
        // hole) must be gone.
        XCTAssertFalse(
            source.contains("URLSession.shared.download"),
            "URLSession re-resolves at connect and cannot pin the validated IP — must not return"
        )
        XCTAssertFalse(
            source.contains("PublicSourceRedirectValidator"),
            "the URLSession redirect delegate is superseded by connect-time validation"
        )
    }

    func testFetcherLocksTheSecurityCriticalTransportChoices() throws {
        let source = try readSource(.pinnedPublicHTTPSFetcher)

        // Connect to a pinned IP but present the HOSTNAME's SNI so the certificate still
        // validates against the hostname (not the IP) — the property that makes this both
        // SSRF-safe AND compatible with SNI-virtual-hosted CDNs.
        XCTAssertTrue(source.contains("sec_protocol_options_set_tls_server_name"))
        XCTAssertTrue(source.contains("sec_protocol_options_set_min_tls_protocol_version"))
        // Explicit IP endpoints (never a name) — no DNS step at connect.
        XCTAssertTrue(source.contains("NWEndpoint.Host.ipv4"))
        XCTAssertTrue(source.contains("NWEndpoint.Host.ipv6"))
        // Identity keeps the body undecoded for a text parser and avoids a decompression surface.
        XCTAssertTrue(source.contains("Accept-Encoding: identity"))
        // Every hop re-runs the resolve+classify gate.
        XCTAssertTrue(source.contains("pinnedAddresses(forHost:"))
        XCTAssertTrue(source.contains("validatePublicSourceURL"))
    }
}
