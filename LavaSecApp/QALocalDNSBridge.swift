#if DEBUG || LAVA_QA_TOOLS
import Foundation
@preconcurrency import Network
import Security

/// Foreground-only experiment. Terminates local DoT and sends the unchanged question
/// through the real tunnel's UDP DNS entry point. This is NOT a background DNS service.
/// All mutable state and Network callbacks are confined to `queue`.
final class QALocalDNSBridge: @unchecked Sendable {
    typealias Logger = @Sendable (String, [String: String]) -> Void
    private let queue = DispatchQueue(label: "com.lavasec.qa.local-dns-bridge")
    private let identity: SecIdentity
    private let log: Logger
    private let upstream: NWEndpoint
    private let port: NWEndpoint.Port
    private var listeners: [NWListener] = []
    private var clients: [UUID: Client] = [:]
    private var stopped = false
    private var queryCount = 0
    private var probes: [UUID: NWConnection] = [:]

    // Inject into the QA app's Documents directory; never bundle a private key.
    init(identityData: Data, port: UInt16 = 853, upstreamHost: String = "10.255.0.1",
         upstreamPort: UInt16 = 53, log: @escaping Logger) throws {
        var items: CFArray?
        let status = SecPKCS12Import(identityData as CFData,
            [kSecImportExportPassphrase as String: "lava-local-dns-lab",
             kSecImportToMemoryOnly as String: true] as CFDictionary, &items)
        guard status == errSecSuccess,
              let item = (items as? [[String: Any]])?.first,
              let value = item[kSecImportItemIdentity as String] else {
            throw NSError(domain: "QALocalDNSBridge.Identity", code: Int(status))
        }
        identity = value as! SecIdentity
        self.log = log
        self.port = NWEndpoint.Port(rawValue: port)!
        upstream = .hostPort(host: NWEndpoint.Host(upstreamHost), port: NWEndpoint.Port(rawValue: upstreamPort)!)
    }

    func start(seconds: Int) {
        queue.async { [self] in
            guard !stopped, listeners.isEmpty else { return }
            do {
                let tls = NWProtocolTLS.Options()
                guard let localIdentity = sec_identity_create(identity) else {
                    throw NSError(domain: "QALocalDNSBridge.Identity", code: -1)
                }
                sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
                sec_protocol_options_set_local_identity(tls.securityProtocolOptions, localIdentity)
                let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
                parameters.requiredInterfaceType = .loopback
                let listener = try NWListener(using: parameters, on: port)
                listener.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    if case .ready = state { log("qa-local-dns-ready", ["interface": "loopback"]) }
                    if case .failed(let error) = state {
                        log("qa-local-dns-listener-failed", ["error": "\(error)"])
                        stopOnQueue()
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
                listeners.append(listener)
                listener.start(queue: queue)
                queue.asyncAfter(deadline: .now() + .seconds(min(max(seconds, 1), 180))) { [weak self] in
                    self?.stopOnQueue()
                }
            } catch {
                log("qa-local-dns-listener-failed", ["error": "\(error)"])
                stopOnQueue()
            }
        }
    }

    func stop() { queue.async { [self] in stopOnQueue() } }

    /// Trust only the injected lab CA and validate the server name. This proves the
    /// adapter transport independently of the system's DNS-profile selection.
    func selfTest(certificateData: Data) {
        queue.asyncAfter(deadline: .now() + .seconds(2)) { [self] in
            guard !stopped, let certificate = SecCertificateCreateWithData(nil, certificateData as CFData) else { return }
            for (index, host) in ["www.linkedin.com", "www.oracle.com", "www.iana.org"].enumerated() {
                let tls = NWProtocolTLS.Options()
                sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, "lava-dns-lab.invalid")
                sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trust, complete in
                    let reference = sec_trust_copy_ref(trust).takeRetainedValue()
                    SecTrustSetPolicies(reference, SecPolicyCreateSSL(true, "lava-dns-lab.invalid" as CFString))
                    SecTrustSetAnchorCertificates(reference, [certificate] as CFArray)
                    SecTrustSetAnchorCertificatesOnly(reference, true)
                    complete(SecTrustEvaluateWithError(reference, nil))
                }, queue)
                let connection = NWConnection(host: "127.0.0.1", port: port,
                    using: NWParameters(tls: tls, tcp: .init()))
                let id = UUID()
                probes[id] = connection
                var query = Data([0x4C, UInt8(index), 1, 0, 0, 1, 0, 0, 0, 0, 0, 0])
                for label in host.split(separator: ".") {
                    query.append(UInt8(label.utf8.count)); query.append(contentsOf: label.utf8)
                }
                query.append(contentsOf: [0, 0, 1, 0, 1])
                var frame = Data([0, UInt8(query.count)])
                frame.append(query)
                connection.start(queue: queue)
                connection.send(content: frame, completion: .contentProcessed { [weak self] error in
                    guard let self, probes[id] != nil else { return }
                    guard error == nil else { finishProbe(id, host: host, outcome: "send-failed"); return }
                    connection.receive(minimumIncompleteLength: 2, maximumLength: 2) { [weak self] length, _, _, error in
                        guard let self, probes[id] != nil else { return }
                        guard error == nil, let length, length.count == 2 else {
                            finishProbe(id, host: host, outcome: "length-failed"); return
                        }
                        let count = Int(length[0]) << 8 | Int(length[1])
                        guard (12...4096).contains(count) else { finishProbe(id, host: host, outcome: "invalid-length"); return }
                        connection.receive(minimumIncompleteLength: count, maximumLength: count) { [weak self] data, _, _, error in
                            guard let self, probes[id] != nil else { return }
                            finishProbe(id, host: host, outcome: error == nil && data?.count == count ? "response" : "receive-failed",
                                        response: data)
                        }
                    }
                })
                queue.asyncAfter(deadline: .now() + .seconds(10)) { [weak self] in
                    self?.finishProbe(id, host: host, outcome: "timeout")
                }
            }
        }
    }

    private func finishProbe(_ id: UUID, host: String, outcome: String, response: Data? = nil) {
        guard let connection = probes.removeValue(forKey: id) else { return }
        connection.cancel()
        var details = ["host": host, "outcome": outcome]
        // Fixed public test domains only, bounded for diagnostic decoding on the Mac.
        if let response { details["responseHex"] = response.prefix(4096).map { String(format: "%02x", $0) }.joined() }
        log("qa-local-dns-selftest-result", details)
    }

    private func stopOnQueue() {
        guard !stopped else { return }
        stopped = true
        listeners.forEach { $0.cancel() }
        listeners.removeAll()
        probes.values.forEach { $0.cancel() }
        probes.removeAll()
        Array(clients.keys).forEach(close)
        log("qa-local-dns-stopped", ["queries": String(queryCount)])
    }

    private final class Client: @unchecked Sendable {
        let id = UUID()
        let connection: NWConnection
        var udp: NWConnection?
        var deadline: DispatchWorkItem?
        init(_ connection: NWConnection) { self.connection = connection }
    }

    private func accept(_ connection: NWConnection) {
        guard case .hostPort(let host, _) = connection.endpoint,
              ["127.0.0.1", "::1", "::ffff:127.0.0.1"].contains("\(host)") else {
            connection.cancel()
            return
        }
        guard !stopped, clients.count < 16 else { connection.cancel(); return }
        let client = Client(connection)
        clients[client.id] = client
        armDeadline(client, seconds: 15)
        connection.stateUpdateHandler = { [weak self, weak client] state in
            guard let self, let client else { return }
            switch state {
            case .ready:
                log("qa-local-dns-client-ready", [:])
                readLength(client)
            case .failed(let error):
                log("qa-local-dns-client-failed", ["error": "\(error)"])
                close(client.id)
            case .cancelled: close(client.id)
            default: break
            }
        }
        connection.start(queue: queue)
    }

    private func armDeadline(_ client: Client, seconds: Int) {
        client.deadline?.cancel()
        let item = DispatchWorkItem { [weak self, weak client] in
            guard let self, let client, clients[client.id] != nil else { return }
            log("qa-local-dns-timeout", [:])
            close(client.id)
        }
        client.deadline = item
        queue.asyncAfter(deadline: .now() + .seconds(seconds), execute: item)
    }

    private func close(_ id: UUID) {
        guard let client = clients.removeValue(forKey: id) else { return }
        client.deadline?.cancel()
        client.udp?.cancel()
        client.connection.cancel()
    }

    // Network may split a TLS record at any byte. min=max reads exactly a frame part;
    // bytes from pipelined questions remain buffered until the preceding reply is sent.
    private func readLength(_ client: Client) {
        guard clients[client.id] != nil else { return }
        armDeadline(client, seconds: 15)
        client.connection.receive(minimumIncompleteLength: 2, maximumLength: 2) { [weak self, weak client] data, _, _, error in
            guard let self, let client, clients[client.id] != nil else { return }
            guard error == nil, let data, data.count == 2 else { close(client.id); return }
            let size = Int(data[data.startIndex]) << 8 | Int(data[data.startIndex + 1])
            guard (12...4096).contains(size), queryCount < 500 else { close(client.id); return }
            client.connection.receive(minimumIncompleteLength: size, maximumLength: size) { [weak self, weak client] query, _, _, error in
                guard let self, let client, clients[client.id] != nil else { return }
                guard error == nil, let query, query.count == size,
                      let question = Self.question(query), query[2] & 0xF8 == 0,
                      query[4] == 0, query[5] == 1,
                      ["www.linkedin.com", "www.oracle.com", "www.iana.org"].contains(question.host) else {
                    log("qa-local-dns-query-rejected", [:])
                    close(client.id)
                    return
                }
                forward(query, question: question, client: client)
            }
        }
    }

    private func forward(_ query: Data, question: (host: String, type: Int), client: Client) {
        queryCount += 1
        let details = ["host": question.host, "type": String(question.type), "sequence": String(queryCount)]
        log("qa-local-dns-query", details)
        armDeadline(client, seconds: 5)
        let udp = NWConnection(to: upstream, using: .udp)
        client.udp = udp
        udp.stateUpdateHandler = { [weak self, weak client] state in
            guard let self, let client, clients[client.id] != nil else { return }
            if case .failed(let error) = state {
                log("qa-local-dns-upstream-failed", ["error": "\(error)"])
                close(client.id)
            }
        }
        udp.start(queue: queue)
        udp.send(content: query, completion: .contentProcessed { [weak self, weak client] error in
            guard let self, let client, clients[client.id] != nil else { return }
            guard error == nil else { close(client.id); return }
            udp.receiveMessage { [weak self, weak client] response, _, _, error in
                guard let self, let client, clients[client.id] != nil else { return }
                guard error == nil, let response, (12...65535).contains(response.count),
                      response.prefix(2) == query.prefix(2), response[2] & 0x80 != 0,
                      let echoed = Self.question(response), echoed == question else {
                    log("qa-local-dns-upstream-invalid", details)
                    close(client.id)
                    return
                }
                udp.cancel()
                client.udp = nil
                var result = details
                result["rcode"] = String(response[3] & 0x0F)
                result["answers"] = String(Int(response[6]) << 8 | Int(response[7]))
                result["bytes"] = String(response.count)
                log("qa-local-dns-response", result)
                var frame = Data([UInt8(response.count >> 8), UInt8(response.count & 255)])
                frame.append(response)
                client.connection.send(content: frame, completion: .contentProcessed { [weak self, weak client] error in
                    guard let self, let client, clients[client.id] != nil else { return }
                    if error != nil { close(client.id) } else { readLength(client) }
                })
            }
        })
    }

    private static func question(_ data: Data) -> (host: String, type: Int)? {
        let bytes = [UInt8](data)
        guard bytes.count >= 12, bytes[4] == 0, bytes[5] == 1 else { return nil }
        var offset = 12
        var labels: [String] = []
        while offset < bytes.count, bytes[offset] != 0 {
            let length = Int(bytes[offset])
            offset += 1
            guard (1...63).contains(length), offset + length < bytes.count,
                  let label = String(bytes: bytes[offset..<(offset + length)], encoding: .ascii) else { return nil }
            labels.append(label.lowercased())
            offset += length
        }
        guard offset + 4 < bytes.count, bytes[offset] == 0,
              bytes[offset + 3] == 0, bytes[offset + 4] == 1 else { return nil }
        return (labels.joined(separator: "."), Int(bytes[offset + 1]) << 8 | Int(bytes[offset + 2]))
    }
}
#endif
