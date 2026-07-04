import Foundation
import Network
#if canImport(Darwin)
import Darwin
#endif

// SEC-1 connect-time peer-IP validation.
//
// `validatePublicSourceURL` (and the initial-URL / redirect scheme+host gate) classify IP
// LITERALS only. A blocklist source hostname — the initial `CustomBlocklistSource.sourceURL`
// OR a 3xx `Location` — that DNS-resolves to a private/loopback/reserved address
// (`printer.lan`, `foo.local`, or an attacker-controlled name pointing at 127.0.0.1 / 10.x /
// 192.168.x, i.e. DNS rebinding) passes those gates, and a stock `URLSession` fetch would
// connect to the private endpoint: on-device SSRF.
//
// Resolve-then-check-then-hand-the-URL-back-to-URLSession is TOCTOU-incomplete: URLSession
// performs its OWN DNS resolution at connect time, so a hostile authoritative server can
// answer the check with a public A record and answer the connect with a private one. The
// only robust fix is to RESOLVE ONCE, validate every resolved address is public, and then
// PIN the connection to a validated address so the transport can never re-resolve.
//
// `URLSession` cannot pin a resolved IP while still presenting the hostname's SNI (there is
// no public API for it), and connecting URLSession to an IP literal breaks TLS for the
// SNI-virtual-hosted CDNs every real source lives on (raw.githubusercontent.com, *.github.io).
// So this fetch runs over `NWConnection`, which — exactly like `DoTConnection` — connects to
// a specific IP endpoint while `sec_protocol_options_set_tls_server_name` sets SNI (and thus
// certificate validation) to the hostname. The connection binds to the validated public
// address; the certificate is still validated against the hostname; ATS-equivalent TLS 1.2+
// and full chain validation are preserved.
//
// The same gate runs on EVERY hop — the initial URL and each redirect target — so the
// residual is closed for both paths, not just redirects.

/// A resolved peer address. Carries the raw network-order bytes needed both to CLASSIFY the
/// address's scope (reusing `IPAddressScope` via `NetworkEndpointValidator`) and to PIN an
/// `NWConnection` directly to it, so the transport never performs a second, unvalidated DNS
/// resolution.
struct ResolvedIPAddress: Equatable, Sendable {
    enum Family: Equatable, Sendable {
        case ipv4
        case ipv6
    }

    let family: Family
    /// 4 bytes for IPv4, 16 bytes for IPv6, network byte order (matching `IPAddressScope`).
    let bytes: [UInt8]
    /// Canonical textual form, for diagnostics only.
    let presentation: String

    init(family: Family, bytes: [UInt8]) {
        self.family = family
        self.bytes = bytes
        self.presentation = Self.presentation(family: family, bytes: bytes)
    }

    /// A validated address is one whose scope is globally-routable public unicast; anything
    /// else is an SSRF target. IPv4-mapped and NAT64-embedded addresses borrow their embedded
    /// scope inside `IPAddressScope`, so a mapped/synthesized private target is rejected too.
    var isPublic: Bool {
        switch family {
        case .ipv4:
            return NetworkEndpointValidator.isPublicResolvedIPv4(octets: bytes)
        case .ipv6:
            return NetworkEndpointValidator.isPublicResolvedIPv6(bytes: bytes)
        }
    }

    /// An EXPLICIT IP endpoint (never a name) — this is what guarantees the connection binds
    /// to exactly this validated address with no DNS step.
    var networkHost: NWEndpoint.Host? {
        switch family {
        case .ipv4:
            return IPv4Address(Data(bytes)).map(NWEndpoint.Host.ipv4)
        case .ipv6:
            return IPv6Address(Data(bytes)).map(NWEndpoint.Host.ipv6)
        }
    }

    /// Parse an IP-literal host into a pinnable address (no DNS). Returns nil for a hostname.
    init?(literal value: String) {
        if value.contains(":"), let address = IPv6Address(value) {
            self.init(family: .ipv6, bytes: Array(address.rawValue))
            return
        }
        if let address = IPv4Address(value) {
            self.init(family: .ipv4, bytes: Array(address.rawValue))
            return
        }
        return nil
    }

    /// Build from a `getaddrinfo` result node's socket address.
    init?(socketAddress: UnsafeMutablePointer<sockaddr>?, length: socklen_t) {
        guard let socketAddress else {
            return nil
        }
        switch Int32(socketAddress.pointee.sa_family) {
        case AF_INET:
            guard Int(length) >= MemoryLayout<sockaddr_in>.size else {
                return nil
            }
            let bytes = socketAddress.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { pointer -> [UInt8] in
                var address = pointer.pointee.sin_addr
                return withUnsafeBytes(of: &address) { Array($0) }
            }
            guard bytes.count == 4 else {
                return nil
            }
            self.init(family: .ipv4, bytes: bytes)
        case AF_INET6:
            guard Int(length) >= MemoryLayout<sockaddr_in6>.size else {
                return nil
            }
            let bytes = socketAddress.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { pointer -> [UInt8] in
                var address = pointer.pointee.sin6_addr
                return withUnsafeBytes(of: &address) { Array($0) }
            }
            guard bytes.count == 16 else {
                return nil
            }
            self.init(family: .ipv6, bytes: bytes)
        default:
            return nil
        }
    }

    private static func presentation(family: Family, bytes: [UInt8]) -> String {
        switch family {
        case .ipv4:
            return IPv4Address(Data(bytes))?.debugDescription
                ?? bytes.map(String.init).joined(separator: ".")
        case .ipv6:
            return IPv6Address(Data(bytes))?.debugDescription
                ?? bytes.map { String(format: "%02x", $0) }.joined()
        }
    }
}

/// Resolves a hostname to its A/AAAA addresses. Injected so tests can map a hostname to a
/// private address (or an empty answer) without touching real DNS.
typealias HostAddressResolver = @Sendable (_ host: String) throws -> [ResolvedIPAddress]

enum SystemHostResolver {
    /// `getaddrinfo` over `AF_UNSPEC` + `SOCK_STREAM`, i.e. exactly the A/AAAA set the system
    /// resolver (honoring the device's DNS and any NAT64 synthesis) would hand a TCP client.
    static func resolve(_ host: String) throws -> [ResolvedIPAddress] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP

        var resultPointer: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, nil, &hints, &resultPointer)
        guard status == 0, let head = resultPointer else {
            // Resolution failure is a transport error (not an SSRF refusal): surface it as a
            // host-not-found so the caller's cache fallback / error wrapping behaves as before.
            throw URLError(.cannotFindHost)
        }
        defer { freeaddrinfo(head) }

        var addresses: [ResolvedIPAddress] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = head
        while let node = cursor {
            if let address = ResolvedIPAddress(socketAddress: node.pointee.ai_addr, length: node.pointee.ai_addrlen) {
                addresses.append(address)
            }
            cursor = node.pointee.ai_next
        }
        return addresses
    }
}

enum PinnedPublicHTTPSFetcher {
    struct Configuration: Sendable {
        var maximumRedirects: Int = 5
        /// Connect deadline: bounds how long a blackholed address (one that never reaches
        /// `.ready` — a firewall silently dropping the SYN) stalls before the fetch fails over
        /// to the next pinned address. Kept short so a dead dual-stack address doesn't sink a
        /// working one.
        var connectTimeoutSeconds: Int = 10
        /// Idle timeout: reset on every received chunk, so a large slow download is not killed
        /// while it makes progress, but a stalled connection fails deterministically.
        var idleTimeoutSeconds: Int = 30
        var maximumHeaderByteCount: Int = 64 * 1024

        static let `default` = Configuration()
    }

    enum HTTPExchangeOutcome: Sendable {
        case response(status: Int, body: Data)
        case redirect(to: URL)
    }

    /// Fetch `url` over an SSRF-safe, IP-pinned HTTPS connection. Every hop (the initial URL
    /// and each redirect target) is re-validated: HTTPS-only + non-empty host, the existing
    /// `validatePublicSourceURL` literal/credential/localhost gate, and — the piece that
    /// closes the residual — a single DNS resolution whose every answer must be public, with
    /// the connection pinned to one of those exact addresses.
    static func fetch(
        url: URL,
        maximumByteCount: Int,
        resolver: @escaping HostAddressResolver = SystemHostResolver.resolve,
        configuration: Configuration = .default
    ) async throws -> Data {
        var currentURL = url
        var redirectCount = 0

        while true {
            try Task.checkCancellation()

            try validateHopURL(currentURL)

            guard let host = asciiHost(from: currentURL) else {
                throw NetworkEndpointValidationError.privateNetworkNotAllowed
            }
            guard let port = UInt16(exactly: currentURL.port ?? 443) else {
                throw URLError(.badURL)
            }

            // Connect-time gate: resolve ONCE, require every answer public, and return the
            // exact addresses to pin.
            let pinnedAddresses = try await resolvePinnedAddresses(forHost: host, resolver: resolver)
            let requestData = makeRequestBytes(host: host, port: port, url: currentURL)

            let outcome = try await connectAndExchange(
                addresses: pinnedAddresses,
                hostname: host,
                port: port,
                requestURL: currentURL,
                requestData: requestData,
                maximumByteCount: maximumByteCount,
                configuration: configuration
            )

            switch outcome {
            case .response(let status, let body):
                guard (200..<300).contains(status) else {
                    throw BlocklistCatalogSyncError.invalidHTTPStatus(status)
                }
                return body
            case .redirect(let target):
                redirectCount += 1
                guard redirectCount <= configuration.maximumRedirects else {
                    throw URLError(.httpTooManyRedirects)
                }
                currentURL = target
            }
        }
    }

    /// HTTPS-only + non-empty host + the shared public-source literal/credential/localhost
    /// gate — run on EVERY hop. `validatePublicSourceURL` intentionally treats hostless URLs
    /// as out of scope and never checks the scheme (both are enforced at source-entry), so a
    /// hostless `Location`, a non-HTTPS scheme (`file:///`, `data:`), or an `http://` DOWNGRADE
    /// must be refused here, matching the source-entry `https://` + host policy.
    static func validateHopURL(_ url: URL) throws {
        guard url.scheme?.lowercased() == "https" else {
            throw NetworkEndpointValidationError.privateNetworkNotAllowed
        }
        guard let host = URLComponents(url: url, resolvingAgainstBaseURL: false)?.host?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !host.isEmpty
        else {
            throw NetworkEndpointValidationError.privateNetworkNotAllowed
        }
        try NetworkEndpointValidator.validatePublicSourceURL(url)
    }

    /// Resolve `host` and return the addresses to pin, or throw `.privateNetworkNotAllowed`
    /// (fail closed) unless it resolves to EXCLUSIVELY public addresses.
    ///
    /// Strict all-public is deliberate: a legitimate public blocklist CDN never answers with a
    /// private/loopback address, so a mixed answer (public decoy + private target) is a
    /// rebinding signal and is refused wholesale. The caller pins one of these exact addresses,
    /// so the transport never re-resolves.
    static func pinnedAddresses(
        forHost host: String,
        resolver: HostAddressResolver
    ) throws -> [ResolvedIPAddress] {
        let bareHost = strippedBrackets(host.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !bareHost.isEmpty else {
            throw NetworkEndpointValidationError.privateNetworkNotAllowed
        }

        // IP-literal host: no DNS. The URL gate already rejected private literals, but we still
        // need the raw bytes to pin AND we re-classify here so a literal can never be pinned
        // without passing the public-scope gate (defense in depth).
        if let literal = ResolvedIPAddress(literal: bareHost) {
            guard literal.isPublic else {
                throw NetworkEndpointValidationError.privateNetworkNotAllowed
            }
            return [literal]
        }

        let resolved = try resolver(bareHost)
        guard !resolved.isEmpty else {
            // No usable address to confirm as public — fail closed rather than hand an
            // unvalidated host to a transport that would resolve it itself.
            throw NetworkEndpointValidationError.privateNetworkNotAllowed
        }
        for address in resolved where !address.isPublic {
            throw NetworkEndpointValidationError.privateNetworkNotAllowed
        }
        return resolved
    }

    /// Run the synchronous resolve+classify gate OFF the cooperative executor: `getaddrinfo`
    /// blocks (up to the system DNS timeout), and blocking a Swift-concurrency thread — with up
    /// to `maxConcurrentSources` fetches in flight — could starve the pool.
    private static func resolvePinnedAddresses(
        forHost host: String,
        resolver: @escaping HostAddressResolver
    ) async throws -> [ResolvedIPAddress] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    continuation.resume(returning: try pinnedAddresses(forHost: host, resolver: resolver))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Try the pinned addresses in order, falling through to the next only on a
    /// connection-establishment failure (so a dead IPv6 address doesn't sink a dual-stack host
    /// whose IPv4 works). Any post-connect failure — timeout, protocol error, size cap — is
    /// propagated immediately.
    private static func connectAndExchange(
        addresses: [ResolvedIPAddress],
        hostname: String,
        port: UInt16,
        requestURL: URL,
        requestData: Data,
        maximumByteCount: Int,
        configuration: Configuration
    ) async throws -> HTTPExchangeOutcome {
        var lastError: Error = URLError(.cannotConnectToHost)
        for (index, address) in addresses.enumerated() {
            do {
                return try await performExchange(
                    address: address,
                    hostname: hostname,
                    port: port,
                    requestURL: requestURL,
                    requestData: requestData,
                    maximumByteCount: maximumByteCount,
                    configuration: configuration
                )
            } catch let error as URLError where error.code == .cannotConnectToHost {
                lastError = error
                if index == addresses.count - 1 {
                    throw error
                }
                continue
            }
        }
        throw lastError
    }

    private static func performExchange(
        address: ResolvedIPAddress,
        hostname: String,
        port: UInt16,
        requestURL: URL,
        requestData: Data,
        maximumByteCount: Int,
        configuration: Configuration
    ) async throws -> HTTPExchangeOutcome {
        let exchange = PinnedHTTPSExchange(
            address: address,
            hostname: hostname,
            port: port,
            requestURL: requestURL,
            requestData: requestData,
            maximumByteCount: maximumByteCount,
            configuration: configuration
        )
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<HTTPExchangeOutcome, Error>) in
                exchange.perform { result in
                    continuation.resume(with: result)
                }
            }
        } onCancel: {
            exchange.cancel()
        }
    }

    /// Build the HTTP/1.1 GET request. `Accept-Encoding: identity` keeps the body undecoded
    /// (the real sources honor it), `Connection: close` lets the server frame the body by
    /// closing, and the `Host` header carries the original hostname the SNI/cert validate.
    static func makeRequestBytes(host: String, port: UInt16, url: URL) -> Data {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var target = components?.percentEncodedPath ?? url.path
        if target.isEmpty {
            target = "/"
        }
        if let query = components?.percentEncodedQuery, !query.isEmpty {
            target += "?" + query
        }

        let bareHost = strippedBrackets(host)
        let isIPv6Literal = bareHost.contains(":")
        let hostHeaderHost = isIPv6Literal ? "[\(bareHost)]" : bareHost
        let hostHeader = port == 443 ? hostHeaderHost : "\(hostHeaderHost):\(port)"

        let requestLines = [
            "GET \(target) HTTP/1.1",
            "Host: \(hostHeader)",
            "User-Agent: LavaSec-BlocklistSync/1.0",
            "Accept: */*",
            "Accept-Encoding: identity",
            "Connection: close",
            "",
            ""
        ]
        return Data(requestLines.joined(separator: "\r\n").utf8)
    }

    static func strippedBrackets(_ host: String) -> String {
        guard host.hasPrefix("["), host.hasSuffix("]"), host.count >= 2 else {
            return host
        }
        return String(host.dropFirst().dropLast())
    }

    /// The IDNA-ASCII (punycode), bracket-stripped host used for resolution, SNI, and the
    /// `Host` header. `getaddrinfo` (no `AI_IDN` on Darwin) and TLS SNI require the `xn--…`
    /// form; the Unicode `URLComponents.host` would fail resolution and break IDN sources that
    /// `URLSession` handled transparently.
    ///
    /// `url.host(percentEncoded: false)` yields punycode when the URL carried a raw Unicode
    /// host, but for a PERCENT-ENCODED IDN (`https://b%C3%BCcher.example/`) it decodes back to
    /// Unicode. So any non-ASCII result is re-wrapped through a fresh `URL` to force Foundation's
    /// IDNA-ASCII encoding (the same engine `URLSession` used); a host that still can't be
    /// rendered ASCII fails closed rather than being handed to `getaddrinfo`/SNI as Unicode.
    static func asciiHost(from url: URL) -> String? {
        guard let decoded = url.host(percentEncoded: false)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !decoded.isEmpty
        else {
            return nil
        }
        let bareHost = strippedBrackets(decoded)
        if bareHost.allSatisfy(\.isASCII) {
            return bareHost
        }
        guard let reencoded = URL(string: "https://\(bareHost)/")?.host(percentEncoded: false),
              reencoded.allSatisfy(\.isASCII)
        else {
            return nil
        }
        return strippedBrackets(reencoded)
    }
}

/// A single IP-pinned HTTPS request/response over one `NWConnection`. One-shot (the request
/// carries `Connection: close`), modeled on `DoTConnection`'s serial-queue + timeout
/// discipline. Completes EXACTLY once.
final class PinnedHTTPSExchange: @unchecked Sendable {
    private enum Phase {
        case connecting
        case head
        case body
        case done
    }

    private let address: ResolvedIPAddress
    private let hostname: String
    private let port: UInt16
    private let requestURL: URL
    private let requestData: Data
    private let maximumByteCount: Int
    private let configuration: PinnedPublicHTTPSFetcher.Configuration
    private let queue: DispatchQueue

    private var connection: NWConnection?
    private var completion: (@Sendable (Result<PinnedPublicHTTPSFetcher.HTTPExchangeOutcome, Error>) -> Void)?
    private var timeout: DispatchWorkItem?
    private var cancelRequested = false

    private var phase: Phase = .connecting
    private var headBuffer = Data()
    private var statusCode = 0
    private var bodyDecoder: HTTPResponseBodyDecoder?

    init(
        address: ResolvedIPAddress,
        hostname: String,
        port: UInt16,
        requestURL: URL,
        requestData: Data,
        maximumByteCount: Int,
        configuration: PinnedPublicHTTPSFetcher.Configuration
    ) {
        self.address = address
        self.hostname = hostname
        self.port = port
        self.requestURL = requestURL
        self.requestData = requestData
        self.maximumByteCount = maximumByteCount
        self.configuration = configuration
        self.queue = DispatchQueue(label: "com.lavasec.blocklist.https-fetch", qos: .utility)
    }

    func perform(completion: @escaping @Sendable (Result<PinnedPublicHTTPSFetcher.HTTPExchangeOutcome, Error>) -> Void) {
        queue.async { [self] in
            self.completion = completion
            if cancelRequested {
                finish(.failure(CancellationError()))
            } else {
                startConnection()
            }
        }
    }

    func cancel() {
        queue.async { [self] in
            cancelRequested = true
            finish(.failure(CancellationError()))
        }
    }

    private var isFinished: Bool {
        completion == nil
    }

    private func startConnection() {
        guard let networkHost = address.networkHost, let networkPort = NWEndpoint.Port(rawValue: port) else {
            finish(.failure(URLError(.cannotConnectToHost)))
            return
        }

        let tlsOptions = NWProtocolTLS.Options()
        // Connect to the pinned IP but present the HOSTNAME's SNI — so the certificate is
        // validated against the hostname the user configured, exactly as ATS/URLSession would.
        hostname.withCString { serverName in
            sec_protocol_options_set_tls_server_name(tlsOptions.securityProtocolOptions, serverName)
        }
        sec_protocol_options_set_min_tls_protocol_version(tlsOptions.securityProtocolOptions, .TLSv12)

        let parameters = NWParameters(tls: tlsOptions, tcp: NWProtocolTCP.Options())
        let networkConnection = NWConnection(host: networkHost, port: networkPort, using: parameters)
        connection = networkConnection
        phase = .connecting
        networkConnection.stateUpdateHandler = { [weak self] state in
            self?.queue.async { self?.handleConnectionState(state) }
        }
        scheduleTimeout(seconds: configuration.connectTimeoutSeconds)
        networkConnection.start(queue: queue)
    }

    private func handleConnectionState(_ state: NWConnection.State) {
        guard !isFinished else {
            return
        }
        switch state {
        case .ready:
            sendRequest()
        case .failed, .cancelled, .waiting:
            // Handshake failure / early close / no route (`.waiting`, e.g. an AAAA on an
            // IPv4-only network): fail as connection-level so the orchestrator falls through to
            // the next pinned address immediately, rather than stalling a dead dual-stack
            // address for the full idle timeout. A transient `.waiting` that would have become
            // `.ready` is rare for a validated public IP, and the cost of bailing is only the
            // next address / a cache fallback (both fine for a background refresh).
            finish(.failure(URLError(.cannotConnectToHost)))
        default:
            break
        }
    }

    private func sendRequest() {
        guard let connection else {
            finish(.failure(URLError(.cannotConnectToHost)))
            return
        }
        phase = .head
        // Connection is up: switch from the short connect deadline to the transfer idle timeout.
        scheduleTimeout(seconds: configuration.idleTimeoutSeconds)
        connection.send(content: requestData, completion: .contentProcessed { [weak self] error in
            self?.queue.async {
                guard let self, !self.isFinished else {
                    return
                }
                if error != nil {
                    self.finish(.failure(URLError(.networkConnectionLost)))
                    return
                }
                self.receiveMore()
            }
        })
    }

    private func receiveMore() {
        guard let connection, !isFinished else {
            return
        }
        scheduleTimeout(seconds: configuration.idleTimeoutSeconds)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            self?.queue.async {
                guard let self, !self.isFinished else {
                    return
                }
                if error != nil {
                    self.finish(.failure(URLError(.networkConnectionLost)))
                    return
                }
                if let data, !data.isEmpty {
                    do {
                        try self.ingest(data)
                    } catch {
                        self.finish(.failure(error))
                        return
                    }
                    if self.isFinished {
                        return
                    }
                }
                if isComplete {
                    do {
                        try self.handleEndOfStream()
                    } catch {
                        self.finish(.failure(error))
                    }
                    return
                }
                self.receiveMore()
            }
        }
    }

    private func ingest(_ data: Data) throws {
        switch phase {
        case .head:
            headBuffer.append(data)
            if headBuffer.count > configuration.maximumHeaderByteCount {
                throw URLError(.badServerResponse)
            }
            let terminator = Data("\r\n\r\n".utf8)
            guard let range = headBuffer.range(of: terminator) else {
                return
            }
            let headData = headBuffer.subdata(in: headBuffer.startIndex..<range.lowerBound)
            let leftover = headBuffer.subdata(in: range.upperBound..<headBuffer.endIndex)
            try beginBody(headData: headData, leftover: leftover)
        case .body:
            try bodyDecoder?.feed(data)
            finishIfBodyComplete()
        case .connecting, .done:
            break
        }
    }

    private func beginBody(headData: Data, leftover: Data) throws {
        let head = try PinnedHTTPSResponseHead(headData)
        statusCode = head.statusCode

        if PinnedHTTPSResponseHead.isRedirect(head.statusCode),
           let location = head.value(for: "location")?.trimmingCharacters(in: .whitespaces),
           !location.isEmpty,
           let target = URL(string: location, relativeTo: requestURL)?.absoluteURL {
            finish(.success(.redirect(to: target)))
            return
        }

        guard (200..<300).contains(head.statusCode) else {
            // Non-2xx, non-followable-redirect: surface the status; the body is irrelevant.
            finish(.success(.response(status: head.statusCode, body: Data())))
            return
        }

        // We requested identity; any other coding is a server that ignored it. Fail closed
        // rather than ship compressed bytes to a text parser (the caller falls back to cache).
        if let encoding = head.value(for: "content-encoding")?
            .trimmingCharacters(in: .whitespaces).lowercased(),
            !encoding.isEmpty, encoding != "identity" {
            throw URLError(.badServerResponse)
        }

        if let transferEncoding = head.value(for: "transfer-encoding")?.lowercased(),
           transferEncoding.contains("chunked") {
            bodyDecoder = ChunkedResponseBodyDecoder(maximumByteCount: maximumByteCount)
        } else {
            let expectedLength = head.value(for: "content-length")
                .flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            bodyDecoder = IdentityResponseBodyDecoder(
                expectedLength: expectedLength,
                maximumByteCount: maximumByteCount
            )
        }

        phase = .body
        if !leftover.isEmpty {
            try bodyDecoder?.feed(leftover)
        }
        finishIfBodyComplete()
    }

    private func finishIfBodyComplete() {
        guard let bodyDecoder, bodyDecoder.isComplete else {
            return
        }
        finish(.success(.response(status: statusCode, body: bodyDecoder.output)))
    }

    private func handleEndOfStream() throws {
        switch phase {
        case .head:
            // Connection closed before the full header block: not a usable response.
            throw URLError(.badServerResponse)
        case .body:
            guard var bodyDecoder else {
                throw URLError(.badServerResponse)
            }
            if !bodyDecoder.isComplete {
                // Identity-without-length completes at EOF; chunked throws if truncated.
                try bodyDecoder.markEndOfStream()
                self.bodyDecoder = bodyDecoder
            }
            finish(.success(.response(status: statusCode, body: bodyDecoder.output)))
        case .connecting, .done:
            break
        }
    }

    private func scheduleTimeout(seconds: Int) {
        timeout?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else {
                return
            }
            // A timeout while still establishing the connection (a blackholed address that
            // never reaches `.ready`) is connection-level, so the orchestrator falls through to
            // the next pinned address — the same failover `.waiting` and `.failed` get. A
            // timeout after the connection is up (a stalled transfer) fails as `.timedOut`,
            // without a wasteful full re-download on the next address.
            let error = self.phase == .connecting
                ? URLError(.cannotConnectToHost)
                : URLError(.timedOut)
            self.finish(.failure(error))
        }
        timeout = work
        queue.asyncAfter(deadline: .now() + .seconds(seconds), execute: work)
    }

    private func finish(_ result: Result<PinnedPublicHTTPSFetcher.HTTPExchangeOutcome, Error>) {
        guard let completion else {
            return
        }
        self.completion = nil
        timeout?.cancel()
        timeout = nil
        phase = .done
        let closingConnection = connection
        connection = nil
        closingConnection?.stateUpdateHandler = nil
        closingConnection?.cancel()
        completion(result)
    }
}

/// Parsed HTTP response head (status line + headers). Header names are lowercased; the last
/// occurrence of a name wins (adequate for the single-valued headers this fetch reads).
struct PinnedHTTPSResponseHead {
    let statusCode: Int
    private let headers: [(name: String, value: String)]

    init(_ data: Data) throws {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw URLError(.badServerResponse)
        }
        let lines = text.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else {
            throw URLError(.badServerResponse)
        }
        let parts = statusLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 2,
              parts[0].uppercased().hasPrefix("HTTP/"),
              let code = Int(parts[1])
        else {
            throw URLError(.badServerResponse)
        }
        statusCode = code

        var parsed: [(name: String, value: String)] = []
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else {
                continue
            }
            let name = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            parsed.append((name, value))
        }
        headers = parsed
    }

    func value(for name: String) -> String? {
        let lowered = name.lowercased()
        return headers.last(where: { $0.name == lowered })?.value
    }

    static func isRedirect(_ code: Int) -> Bool {
        code == 301 || code == 302 || code == 303 || code == 307 || code == 308
    }
}

/// Incrementally decodes a response body, enforcing the decoded-byte ceiling as bytes arrive
/// (so peak memory stays bounded and a decompression/oversize source fails closed early).
protocol HTTPResponseBodyDecoder {
    var output: Data { get }
    var isComplete: Bool { get }
    mutating func feed(_ data: Data) throws
    /// Called on connection close; throws if the body was truncated mid-frame.
    mutating func markEndOfStream() throws
}

/// `Content-Length`-bounded or read-to-close body. With `Connection: close`, an absent length
/// completes at EOF.
struct IdentityResponseBodyDecoder: HTTPResponseBodyDecoder {
    let expectedLength: Int?
    let maximumByteCount: Int
    private(set) var output = Data()
    private(set) var isComplete = false

    init(expectedLength: Int?, maximumByteCount: Int) {
        // A negative / malformed `Content-Length` (e.g. `-1`) must never become a real length:
        // it would make `feed` trap on `offsetBy: <negative>`. Drop it and read to EOF instead
        // (still bounded by `Connection: close` + the byte cap).
        self.expectedLength = expectedLength.flatMap { $0 >= 0 ? $0 : nil }
        self.maximumByteCount = maximumByteCount
    }

    mutating func feed(_ data: Data) throws {
        guard !isComplete else {
            return
        }
        output.append(data)
        if let expectedLength, output.count >= expectedLength {
            if output.count > expectedLength {
                output.removeSubrange(output.index(output.startIndex, offsetBy: expectedLength)..<output.endIndex)
            }
            isComplete = true
        }
        if output.count > maximumByteCount {
            throw BlocklistDownloadSizeLimitExceeded(byteSize: output.count, maximumByteCount: maximumByteCount)
        }
    }

    mutating func markEndOfStream() throws {
        if let expectedLength, output.count < expectedLength {
            throw URLError(.badServerResponse)
        }
        isComplete = true
    }
}

/// RFC 7230 chunked transfer decoder. Decodes across arbitrary receive boundaries and enforces
/// the decoded-byte ceiling as it goes.
struct ChunkedResponseBodyDecoder: HTTPResponseBodyDecoder {
    private enum Stage: Equatable {
        case size
        case data(remaining: Int)
        case dataTrailingCRLF
        case trailers
        case done
    }

    let maximumByteCount: Int
    private var stage: Stage = .size
    private var buffer = Data()
    private(set) var output = Data()
    private var trailerBytesConsumed = 0

    /// Trailer headers never grow `output`, so they aren't bounded by `maximumByteCount`. A
    /// hostile host could otherwise stream endless small CRLF-terminated trailer lines — each
    /// resetting the idle timeout, never terminating — to keep the sync task alive forever.
    /// Cap the whole trailer section (real trailers are absent or a few bytes).
    private static let maximumTrailerByteCount = 16 * 1024

    init(maximumByteCount: Int) {
        self.maximumByteCount = maximumByteCount
    }

    var isComplete: Bool {
        stage == .done
    }

    mutating func feed(_ data: Data) throws {
        buffer.append(data)
        try process()
    }

    mutating func markEndOfStream() throws {
        if stage != .done {
            throw URLError(.badServerResponse)
        }
    }

    private static let crlf = Data("\r\n".utf8)

    private mutating func process() throws {
        loop: while true {
            switch stage {
            case .size:
                guard let lineRange = buffer.range(of: Self.crlf) else {
                    if buffer.count > 1024 {
                        // A chunk-size line this long is malformed, not merely fragmented.
                        throw URLError(.badServerResponse)
                    }
                    break loop
                }
                let lineData = buffer.subdata(in: buffer.startIndex..<lineRange.lowerBound)
                buffer.removeSubrange(buffer.startIndex..<lineRange.upperBound)
                guard let line = String(data: lineData, encoding: .ascii) else {
                    throw URLError(.badServerResponse)
                }
                // Drop any chunk extensions (";name=value").
                let sizeToken = line.split(separator: ";", maxSplits: 1).first.map(String.init) ?? line
                guard let size = Int(sizeToken.trimmingCharacters(in: .whitespaces), radix: 16), size >= 0 else {
                    throw URLError(.badServerResponse)
                }
                stage = size == 0 ? .trailers : .data(remaining: size)
            case .data(let remaining):
                guard !buffer.isEmpty else {
                    break loop
                }
                let take = min(remaining, buffer.count)
                let end = buffer.index(buffer.startIndex, offsetBy: take)
                output.append(buffer.subdata(in: buffer.startIndex..<end))
                buffer.removeSubrange(buffer.startIndex..<end)
                if output.count > maximumByteCount {
                    throw BlocklistDownloadSizeLimitExceeded(byteSize: output.count, maximumByteCount: maximumByteCount)
                }
                let newRemaining = remaining - take
                stage = newRemaining == 0 ? .dataTrailingCRLF : .data(remaining: newRemaining)
            case .dataTrailingCRLF:
                guard buffer.count >= 2 else {
                    break loop
                }
                let end = buffer.index(buffer.startIndex, offsetBy: 2)
                let separator = buffer.subdata(in: buffer.startIndex..<end)
                guard separator == Self.crlf else {
                    throw URLError(.badServerResponse)
                }
                buffer.removeSubrange(buffer.startIndex..<end)
                stage = .size
            case .trailers:
                // Bound the whole trailer section: consumed lines PLUS whatever is buffered but
                // not yet terminated. This catches both a flood of small terminated trailer
                // lines and a single never-terminated one.
                if trailerBytesConsumed + buffer.count > Self.maximumTrailerByteCount {
                    throw URLError(.badServerResponse)
                }
                guard let lineRange = buffer.range(of: Self.crlf) else {
                    break loop
                }
                let lineData = buffer.subdata(in: buffer.startIndex..<lineRange.lowerBound)
                trailerBytesConsumed += buffer.distance(from: buffer.startIndex, to: lineRange.upperBound)
                buffer.removeSubrange(buffer.startIndex..<lineRange.upperBound)
                // A blank line ends the trailer section; any non-empty line is a trailer header
                // (ignored).
                if lineData.isEmpty {
                    stage = .done
                    break loop
                }
            case .done:
                break loop
            }
        }
    }
}
