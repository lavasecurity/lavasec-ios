@preconcurrency import ActivityKit
import Foundation
import Darwin
import Network
@preconcurrency import NetworkExtension
import Security
@preconcurrency import UserNotifications
import LavaSecCore

private struct TunnelCompletion: @unchecked Sendable {
    let handler: () -> Void

    func complete() {
        handler()
    }
}

private struct AppMessageCompletion: @unchecked Sendable {
    let handler: ((Data?) -> Void)?
    let latencySpan: LatencySpan?

    init(handler: ((Data?) -> Void)?, latencySpan: LatencySpan? = nil) {
        self.handler = handler
        self.latencySpan = latencySpan
    }

    func complete(_ response: Data?) {
        latencySpan?.end(details: ["status": response == nil ? "nil-reply" : "reply"])
        handler?(response)
    }
}

private final class ResolverWorkCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private let handler: () -> Void
    private var didComplete = false

    init(handler: @escaping () -> Void) {
        self.handler = handler
    }

    func complete() {
        lock.lock()
        guard !didComplete else {
            lock.unlock()
            return
        }

        didComplete = true
        lock.unlock()
        handler()
    }
}

private final class ResolverSmokeProbeTimeout: @unchecked Sendable {
    private let workItem: DispatchWorkItem

    init(handler: @escaping @Sendable () -> Void) {
        self.workItem = DispatchWorkItem(block: handler)
    }

    func schedule(on queue: DispatchQueue, timeoutSeconds: Int) {
        queue.asyncAfter(deadline: .now() + .seconds(timeoutSeconds), execute: workItem)
    }

    func cancel() {
        workItem.cancel()
    }
}

private enum ResolverQueryPurpose: Sendable {
    case forwarding
    case smokeProbe

    var usesIsolatedEncryptedConnection: Bool {
        switch self {
        case .forwarding:
            return false
        case .smokeProbe:
            return true
        }
    }
}

private let dnsStateQueueSpecificKey = DispatchSpecificKey<Bool>()

@_silgen_name("LavaSecCopySystemDNSServers")
private func LavaSecCopySystemDNSServers(_ buffer: UnsafeMutablePointer<CChar>, _ bufferLength: Int32) -> Int32

private struct ResolverAdjustedRuntimeSnapshot: FilterRuntimeSnapshot {
    let base: any FilterRuntimeSnapshot
    let resolver: DNSResolverPreset

    var blockRuleCount: Int {
        base.blockRuleCount
    }

    var allowRuleCount: Int {
        base.allowRuleCount
    }

    var guardrailRuleCount: Int {
        base.guardrailRuleCount
    }

    func decision(for rawDomain: String) -> FilterDecision {
        base.decision(for: rawDomain)
    }

    func decision(forNormalizedDomain normalizedDomain: String) -> FilterDecision {
        base.decision(forNormalizedDomain: normalizedDomain)
    }
}

private struct FailClosedRuntimeSnapshot: FilterRuntimeSnapshot {
    let resolver: DNSResolverPreset

    var blockRuleCount: Int { 0 }
    var allowRuleCount: Int { 0 }
    var guardrailRuleCount: Int { 0 }

    func decision(for rawDomain: String) -> FilterDecision {
        FilterDecision(action: .block, reason: .blocklist)
    }

    func decision(forNormalizedDomain normalizedDomain: String) -> FilterDecision {
        FilterDecision(action: .block, reason: .blocklist)
    }
}

private struct TunnelNetworkSettingsBundle {
    let settings: NEPacketTunnelNetworkSettings
    let tunnelAddress: String
    let dnsServerAddress: String
    let routeDescription: String
}

private struct NetworkPathUpdate: Sendable {
    let kind: TunnelNetworkKind
    let isSatisfied: Bool
    let statusDescription: String
}

final class PacketTunnelProvider: NEPacketTunnelProvider, @unchecked Sendable {
    private static let tunnelAddress = "10.255.0.2"
    private static let tunnelDNSServerAddress = "10.255.0.1"
    private static let tunnelRouteDescription = "10.255.0.0/24"
    private static let deviceDNSCaptureBufferLength = 1024
    private var snapshot: any FilterRuntimeSnapshot = FilterSnapshot(blockRules: DomainRuleSet())
    private var protectionPolicySnapshot: any FilterRuntimeSnapshot = FilterSnapshot(blockRules: DomainRuleSet())
    // Identity of the rule artifact currently resident in `snapshot` (nil for
    // the empty bootstrap and fail-closed snapshots). Guarded by snapshotQueue.
    // A live reload reads this to skip decoding an on-disk artifact that would
    // reproduce the resident snapshot — avoiding the 2x-resident memory peak
    // that jetsams the extension on large multi-list snapshots.
    private var residentSnapshotIdentity: PreparedFilterSnapshotIdentity?
    private let snapshotQueue = DispatchQueue(label: "com.lavasec.tunnel.snapshot", qos: .utility)
    private let blockedTTL: UInt32 = 1
    private let pausedWouldBlockForwardTTL: UInt32 = 1
    private static let maxConcurrentResolverQueries = 8
    private let resolverQueue = DispatchQueue(label: "com.lavasec.tunnel.resolver", qos: .utility, attributes: .concurrent)
    private let resolverSmokeProbeQueue = DispatchQueue(label: "com.lavasec.tunnel.resolver.smoke-probe", qos: .utility)
    private let resolverConcurrencyGate = DispatchSemaphore(value: PacketTunnelProvider.maxConcurrentResolverQueries)
    private let resolverSocketQueue = DispatchQueue(label: "com.lavasec.tunnel.resolver-sockets", qos: .utility)
    private let protectionPauseStateQueue = DispatchQueue(label: "com.lavasec.tunnel.protection-pause-state", qos: .utility)
    private let dnsStateQueue: DispatchQueue = {
        let queue = DispatchQueue(label: "com.lavasec.tunnel.dns-state", qos: .utility)
        queue.setSpecific(key: dnsStateQueueSpecificKey, value: true)
        return queue
    }()
    private static let udpDNSTimeoutSeconds = 1
    private static let tcpDNSTimeoutSeconds = 2
    private static let dohTimeoutSeconds = 5
    private static let dotTimeoutSeconds = 5
    private static let doqTimeoutSeconds = 5
    private static let resolverSmokeProbeTimeoutSeconds = 8
    private static let slowUpstreamResponseThresholdMilliseconds = 2_500
    private let resolverBackoffStateQueue = DispatchQueue(label: "com.lavasec.tunnel.resolver-backoff", qos: .utility)
    private let pathMonitor = Network.NWPathMonitor()
    private static let resolverSmokeProbeInterval: TimeInterval = DeviceDNSFallbackPolicy.routineSmokeProbeInterval
    private let healthWriteInterval: TimeInterval = 30
    private let diagnosticsWriteInterval: TimeInterval = 30
    private let configurationRefreshInterval: TimeInterval = 30
    private let protectionPauseStateRefreshInterval: TimeInterval = 1
    private var resolverSockets: [ResolverEndpoint: UDPResolverSocket] = [:]
    // dnsStateQueue-confined, like the dictionaries they replaced.
    private let dnsResponseCache = DNSResponseCache()
    private let inFlightQueryCoalescer = InFlightDNSQueryCoalescer<PendingDNSResponse>()
    private var resolverBackoffPolicy = ResolverBackoffPolicy()
    private var health = TunnelHealthSnapshot()
    private var diagnostics = DiagnosticsStore()
    private var appConfiguration = AppConfiguration()
    private var deviceDNSResolverAddresses: [String] = []
    private var deviceDNSFallbackModeActive = false
    private var consecutiveQueryFallbackSuccessCount = 0
    private var resolverSmokeProbeGeneration = 0
    private var resolverSmokeProbeTimer: DispatchSourceTimer?
    private var protectionPauseResumeTimer: DispatchSourceTimer?
    private var snapshotReloadGeneration: UInt64 = 0
    private var lastAppliedTemporaryProtectionPauseIsActive = false
    // dnsStateQueue-confined: marks the first DNS decision after tunnel start so
    // the "first DNS after start" latency target is measurable end to end.
    private var hasRecordedFirstDNSDecision = false
    private var firstDNSDecisionReferenceAt: Date?
    private var tunnelStartLatencyOperationID: LatencyOperationID?
    private var fallbackRecoverySmokeProbeWorkItem: DispatchWorkItem?
    private var networkKind: TunnelNetworkKind = .unknown
    private var lastConfigurationRefreshAt = Date.distantPast
    private var lastProtectionPauseStateRefreshAt = Date.distantPast
    private var cachedTemporaryProtectionPauseUntil: Date?
    private var lastConfigurationModifiedAt: Date?
    private var lastDiagnosticsControlModifiedAt: Date?
    private var lastAppliedDiagnosticsClearAt: Date?
    private var lastAppliedFilteringCountsClearAt: Date?
    // Health and diagnostics share one debounced dirty-flush persistence machine
    // (extracted to LavaSecCore; replaces the two byte-for-byte-identical inline
    // copies that were the disk-churn class behind the 2026-06-14 heat regression).
    // Stateless scheduler → one instance serves both controllers; each owns its
    // own pending token. dnsStateQueue-confined, like the inline state it replaces.
    private lazy var persistenceFlushScheduler = DispatchSettleWorkScheduler(queue: dnsStateQueue)
    private lazy var healthPersistence = DebouncedPersistenceController(
        writeInterval: healthWriteInterval,
        scheduler: persistenceFlushScheduler,
        write: { [weak self] _ in
            guard let self, let containerURL = LavaSecAppGroup.containerURL else {
                return false
            }
            let url = containerURL.appendingPathComponent(LavaSecAppGroup.tunnelHealthFilename)
            guard let data = try? JSONEncoder().encode(self.health) else {
                return false
            }
            try? data.write(to: url, options: Data.WritingOptions.atomic)
            return true
        }
    )
    private lazy var diagnosticsPersistence = DebouncedPersistenceController(
        writeInterval: diagnosticsWriteInterval,
        scheduler: persistenceFlushScheduler,
        write: { [weak self] now in
            guard let self else {
                return false
            }
            self.diagnostics.resetForCurrentDayIfNeeded(now: now)
            guard let diagnosticsURL = self.diagnosticsURL else {
                return false
            }
            try? DiagnosticsPersistence.save(self.diagnostics, to: diagnosticsURL)
            return true
        }
    )
    private let dohResolver: DoHTransport = {
        #if DEBUG || LAVA_QA_TOOLS
        DoHTransport(timeoutSeconds: PacketTunnelProvider.dohTimeoutSeconds) { event, details in
            LavaSecDeviceDebugLog.append(component: "tunnel", event: event, details: details)
        }
        #else
        DoHTransport(timeoutSeconds: PacketTunnelProvider.dohTimeoutSeconds)
        #endif
    }()
    private let dotResolver: DoTTransport = {
        #if DEBUG || LAVA_QA_TOOLS
        DoTTransport(timeoutSeconds: PacketTunnelProvider.dotTimeoutSeconds) { event, details in
            LavaSecDeviceDebugLog.append(component: "tunnel", event: event, details: details)
        }
        #else
        DoTTransport(timeoutSeconds: PacketTunnelProvider.dotTimeoutSeconds)
        #endif
    }()
    private let doqResolver: DoQTransport = {
        #if DEBUG || LAVA_QA_TOOLS
        DoQTransport(timeoutSeconds: PacketTunnelProvider.doqTimeoutSeconds) { event, details in
            LavaSecDeviceDebugLog.append(component: "tunnel", event: event, details: details)
        }
        #else
        DoQTransport(timeoutSeconds: PacketTunnelProvider.doqTimeoutSeconds)
        #endif
    }()
    // One operation id groups all resolver-path latency spans (endpoint
    // attempts, device fallback, bootstrap) for a tunnel session. Only read
    // inside DEBUG/QA latency emission; harmless and unused in Release.
    private let resolverLatencyOperationID = LatencyOperationID.make()
    private var activeResolverRuntimeIdentifier: String?
    private var resolverRuntimeGeneration = 0
    private var tunnelLifecycleGeneration: UInt64 = 0
    private var lastObservedPathKind: TunnelNetworkKind?
    private var lastObservedPathIsSatisfied: Bool?
    private var lastNetworkSettingsReapplyAt = Date.distantPast
    private let reconnectNeededActivityReminderInterval: TimeInterval = 300
    private var lastReconnectNeededActivityAt: Date?
    private var lastReconnectNeededActivityReason: String?
    #if LAVA_QA_TOOLS
    private var lastQAConnectivitySeverity: ProtectionConnectivitySeverity = .healthy
    private var lastQAConnectivityLogAt = Date.distantPast
    #endif

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        let operationID = Self.latencyOperationID(from: options)
        #if DEBUG || LAVA_QA_TOOLS
        let trace = Self.makeLatencyTrace(operationID: operationID, operationKind: "tunnelStart")
        let startSpan = trace.beginSpan("tunnel.start", details: [
            "status": "begin",
            "hasOptions": "\(options != nil)",
            "hasOperationID": "\(operationID != nil)"
        ])
        #endif

        #if DEBUG
        LavaSecDeviceDebugLog.append(component: "tunnel", event: "startTunnel-begin", details: [
            "hasOptions": "\(options != nil)",
            "hasOperationID": "\(operationID != nil)"
        ])
        #endif

        let completion = SendableCompletion(completionHandler)
        let lifecycleGeneration = beginTunnelLifecycle(reason: "startTunnel")
        beginFreshProtectionVPNSession(reason: "startTunnel")
        loadInitialSharedState()
        scheduleProtectionPauseResumeIfNeeded(reason: "startTunnel")
        refreshDeviceDNSResolverAddresses(reason: "startTunnel")
        resetHealth()
        resetResolverRuntimeForTunnelLifecycle(reason: "startTunnel")
        startPathMonitor()

        let settingsBundle = makeTunnelNetworkSettingsForCurrentConfiguration()

        #if DEBUG
        let settingsStartedAt = Date()
        LavaSecDeviceDebugLog.append(component: "tunnel", event: "setTunnelNetworkSettings-begin", details: [
            "tunnelAddress": settingsBundle.tunnelAddress,
            "dnsServerAddress": settingsBundle.dnsServerAddress,
            "route": settingsBundle.routeDescription
        ])
        #endif
        #if DEBUG || LAVA_QA_TOOLS
        let networkSettingsSpan = trace.beginSpan("tunnel.setNetworkSettings", parent: startSpan, details: [
            "status": "begin"
        ])
        #endif

        setTunnelNetworkSettings(settingsBundle.settings) { [weak self] error in
            guard let self else {
                #if DEBUG || LAVA_QA_TOOLS
                networkSettingsSpan.end(details: ["status": "missing-provider"])
                startSpan.end(details: ["status": "missing-provider"])
                #endif
                completion(error)
                return
            }

            if let error {
                #if DEBUG
                LavaSecDeviceDebugLog.append(component: "tunnel", event: "setTunnelNetworkSettings-error", details: Self.errorDebugDetails(error))
                #endif
                #if DEBUG || LAVA_QA_TOOLS
                networkSettingsSpan.end(details: ["status": "error", "errorKind": "\(type(of: error))"])
                startSpan.end(details: ["status": "error", "errorKind": "\(type(of: error))"])
                #endif
                self.cleanUpTunnelRuntimeAfterFailedStart(reason: "setTunnelNetworkSettings-error") {
                    completion(error)
                }
                return
            }

            guard self.isCurrentTunnelLifecycle(lifecycleGeneration) else {
                #if DEBUG || LAVA_QA_TOOLS
                LavaSecDeviceDebugLog.append(component: "tunnel", event: "setTunnelNetworkSettings-stale", details: [
                    "generation": "\(lifecycleGeneration)"
                ])
                #endif
                #if DEBUG || LAVA_QA_TOOLS
                networkSettingsSpan.end(details: ["status": "stale"])
                startSpan.end(details: ["status": "stale"])
                #endif
                completion(CocoaError(.userCancelled))
                return
            }

            #if DEBUG
            let duration = Date().timeIntervalSince(settingsStartedAt)
            LavaSecDeviceDebugLog.append(component: "tunnel", event: "setTunnelNetworkSettings-success", details: [
                "durationMs": "\(Int((duration * 1_000).rounded()))"
            ])
            #endif
            #if DEBUG || LAVA_QA_TOOLS
            networkSettingsSpan.end(details: ["status": "ok"])
            #endif

            self.markLocalProtectionUptimeStarted()
            self.dnsStateQueue.async { [weak self] in
                self?.hasRecordedFirstDNSDecision = false
                self?.firstDNSDecisionReferenceAt = Date()
                self?.tunnelStartLatencyOperationID = operationID
            }
            self.loadSnapshotInBackground(reason: "startTunnel", operationID: operationID)
            // Lazy vars are not thread-safe: force the resolver seams here,
            // single-threaded, before any packet or probe can race their
            // first touch.
            _ = self.resolverOrchestrator
            self.prewarmResolverBootstrapIfNeeded()
            self.scheduleResolverSmokeProbeIfNeeded(reason: "startTunnel")
            self.startPeriodicResolverSmokeProbe()
            self.readPackets()
            #if DEBUG
            LavaSecDeviceDebugLog.append(component: "tunnel", event: "startTunnel-ready")
            #endif
            #if DEBUG || LAVA_QA_TOOLS
            startSpan.end(details: ["status": "ready"])
            #endif
            completion(nil)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        #if DEBUG || LAVA_QA_TOOLS
        // Capture the OS stop reason (raw + readable) so an unexpected,
        // system-initiated teardown — e.g. .internalError(17), which stops the
        // tunnel with no app involvement and no auto-restart — is diagnosable
        // from the log instead of appearing as a "silent" disconnect.
        LavaSecDeviceDebugLog.append(component: "tunnel", event: "stopTunnel", details: [
            "reason": "\(reason.rawValue)",
            "reasonName": Self.stopReasonName(reason)
        ])
        #endif

        let completion = TunnelCompletion(handler: completionHandler)
        invalidateTunnelLifecycle(reason: "stopTunnel")
        cleanUpTunnelRuntimeAfterStop(reason: "stopTunnel") {
            completion.complete()
        }
    }

    #if DEBUG || LAVA_QA_TOOLS
    private static func stopReasonName(_ reason: NEProviderStopReason) -> String {
        switch reason {
        case .none: return "none"
        case .userInitiated: return "userInitiated"
        case .providerFailed: return "providerFailed"
        case .noNetworkAvailable: return "noNetworkAvailable"
        case .unrecoverableNetworkChange: return "unrecoverableNetworkChange"
        case .providerDisabled: return "providerDisabled"
        case .authenticationCanceled: return "authenticationCanceled"
        case .configurationFailed: return "configurationFailed"
        case .idleTimeout: return "idleTimeout"
        case .configurationDisabled: return "configurationDisabled"
        case .configurationRemoved: return "configurationRemoved"
        case .superceded: return "superceded"
        case .userLogout: return "userLogout"
        case .userSwitch: return "userSwitch"
        case .connectionFailed: return "connectionFailed"
        case .sleep: return "sleep"
        case .appUpdate: return "appUpdate"
        default:
            // .internalError = 17 (iOS 18.1+, "an internal error occurred in the
            // NetworkExtension framework"). Matched by raw value to stay
            // build-safe below the availability floor.
            return reason.rawValue == 17 ? "internalError" : "unknown(\(reason.rawValue))"
        }
    }
    #endif

    private func beginTunnelLifecycle(reason: String) -> UInt64 {
        let begin: () -> UInt64 = {
            self.tunnelLifecycleGeneration += 1
            #if DEBUG || LAVA_QA_TOOLS
            LavaSecDeviceDebugLog.append(component: "tunnel", event: "lifecycle-begin", details: [
                "reason": reason,
                "generation": "\(self.tunnelLifecycleGeneration)"
            ])
            #endif
            return self.tunnelLifecycleGeneration
        }

        if DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true {
            return begin()
        }

        return dnsStateQueue.sync(execute: begin)
    }

    private func invalidateTunnelLifecycle(reason: String) {
        let invalidate = {
            self.tunnelLifecycleGeneration += 1
            #if DEBUG || LAVA_QA_TOOLS
            LavaSecDeviceDebugLog.append(component: "tunnel", event: "lifecycle-invalidated", details: [
                "reason": reason,
                "generation": "\(self.tunnelLifecycleGeneration)"
            ])
            #endif
        }

        if DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true {
            invalidate()
            return
        }

        dnsStateQueue.sync(execute: invalidate)
    }

    private func isCurrentTunnelLifecycle(_ generation: UInt64) -> Bool {
        if DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true {
            return generation == tunnelLifecycleGeneration
        }

        return dnsStateQueue.sync {
            generation == tunnelLifecycleGeneration
        }
    }

    private func cleanUpTunnelRuntimeAfterFailedStart(reason: String, completion: @escaping @Sendable () -> Void) {
        invalidateTunnelLifecycle(reason: reason)
        cleanUpTunnelRuntimeAfterStop(reason: reason, completion: completion)
    }

    private func cleanUpTunnelRuntimeAfterStop(reason: String, completion: @escaping @Sendable () -> Void) {
        pathMonitor.cancel()
        dohResolver.cancel()
        dotResolver.cancel()
        doqResolver.cancel()
        stopPeriodicResolverSmokeProbe()
        cancelProtectionPauseResumeTimer()
        endProtectionVPNSession(reason: reason)
        cancelFallbackRecoverySmokeProbe()

        resolverSocketQueue.async { [weak self] in
            self?.resolverSockets = [:]
        }

        dnsStateQueue.async { [weak self] in
            guard let self else {
                completion()
                return
            }

            self.invalidateSnapshotReloadGeneration(reason: reason)
            self.diagnostics.stopLocalProtectionUptime()
            self.markDiagnosticsUpdated()
            self.persistHealthIfNeeded(force: true)
            self.persistDiagnosticsIfNeeded(force: true)
            completion()
        }
    }

    #if DEBUG
    private static func errorDebugDetails(_ error: Error) -> [String: String] {
        let nsError = error as NSError
        return [
            "errorDescription": nsError.localizedDescription,
            "errorDomain": nsError.domain,
            "errorCode": "\(nsError.code)",
            "underlyingError": "\(nsError.userInfo[NSUnderlyingErrorKey] ?? "nil")"
        ]
    }

    // phys_footprint is the dirty + compressed memory iOS charges against the
    // packet-tunnel jetsam limit (mapped/clean file pages are excluded), so it
    // is the right gauge for the snapshot memory budget and for verifying the
    // zero-copy mmap of the domain table.
    private static func currentMemoryFootprintMB() -> String {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            return "unknown"
        }
        return String(format: "%.1f", Double(info.phys_footprint) / 1_048_576)
    }
    #endif

    private static func errorSummary(_ error: Error) -> String {
        let nsError = error as NSError
        return "\(nsError.localizedDescription) (\(nsError.domain) \(nsError.code))"
    }

    private func makeTunnelNetworkSettingsForCurrentConfiguration() -> TunnelNetworkSettingsBundle {
        Self.makeTunnelNetworkSettings()
    }

    private static func makeTunnelNetworkSettings() -> TunnelNetworkSettingsBundle {
        let tunnelAddress = Self.tunnelAddress
        let dnsServerAddress = Self.tunnelDNSServerAddress
        let routeDescription = Self.tunnelRouteDescription
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: dnsServerAddress)
        settings.mtu = 1280

        let ipv4 = NEIPv4Settings(addresses: [tunnelAddress], subnetMasks: ["255.255.255.0"])
        ipv4.includedRoutes = [NEIPv4Route(destinationAddress: "10.255.0.0", subnetMask: "255.255.255.0")]
        settings.ipv4Settings = ipv4

        let dns = NEDNSSettings(servers: [dnsServerAddress])
        dns.matchDomains = [""]
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            // Keep DNS inside Lava's packet tunnel; Lava performs resolver fallback after local filtering.
            dns.allowFailover = false
        }
        #endif
        settings.dnsSettings = dns

        return TunnelNetworkSettingsBundle(
            settings: settings,
            tunnelAddress: tunnelAddress,
            dnsServerAddress: dnsServerAddress,
            routeDescription: routeDescription
        )
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        guard let providerMessage = LavaSecProviderMessageCodec.decode(messageData) else {
            let completion = AppMessageCompletion(handler: completionHandler)
            completion.complete(nil)
            return
        }

        let message = providerMessage.kind
        #if DEBUG || LAVA_QA_TOOLS
        let trace = providerMessage.operationID.map { operationID in
            LatencyTrace(
                operationID: LatencyOperationID(rawValue: operationID),
                sink: LatencyDebugLogEventSink(operationKind: "providerMessage") { event, details in
                    LavaSecDeviceDebugLog.append(component: "tunnel", event: event, details: details)
                }
            )
        }
        trace?.record("provider.message.received", details: ["kind": message])
        let completion = AppMessageCompletion(
            handler: completionHandler,
            latencySpan: trace?.beginSpan("provider.message.reply", details: ["kind": message])
        )
        #else
        let completion = AppMessageCompletion(handler: completionHandler)
        #endif

        switch message {
        case LavaSecAppGroup.reloadSnapshotMessage:
            requestSnapshotReload(
                reason: "appMessage",
                force: true,
                operationID: providerMessage.operationID.map(LatencyOperationID.init(rawValue:))
            )
            completion.complete(Data("ok".utf8))

        case LavaSecAppGroup.reloadProtectionPauseMessage:
            refreshProtectionPauseStateOnly(reason: "protectionPause")
            completion.complete(Data("ok".utf8))

        case LavaSecAppGroup.reloadConfigurationMessage:
            dnsStateQueue.async { [weak self] in
                guard let self else {
                    completion.complete(nil)
                    return
                }

                // Always load the new config so non-resolver fields (diagnostics
                // toggles, paid status) take effect. But only reset the DNS
                // runtime and reapply tunnel network settings — a VISIBLE
                // reconnect — when the RESOLVER config actually changed. A
                // diagnostics-flag or paid-status change must never drop the
                // live connection (plan acceptance: config change does not
                // reconnect unless identity changed).
                let previousResolverIdentity = Self.resolverNetworkIdentity(self.currentAppConfiguration())
                self.refreshConfigurationIfNeeded(force: true)
                let resolverChanged = Self.resolverNetworkIdentity(self.currentAppConfiguration()) != previousResolverIdentity

                #if DEBUG || LAVA_QA_TOOLS
                LavaSecDeviceDebugLog.append(component: "tunnel", event: "reload-configuration", details: [
                    "resolverChanged": "\(resolverChanged)"
                ])
                #endif

                if resolverChanged {
                    self.deviceDNSFallbackModeActive = false
                    self.consecutiveQueryFallbackSuccessCount = 0
                    self.health.deviceDNSFallbackModeActive = false
                    self.health.lastDeviceDNSFallbackActivatedAt = nil
                    self.health.consecutiveUpstreamFailureCount = 0
                    self.cancelFallbackRecoverySmokeProbe()
                    self.markHealthUpdated()
                    self.persistHealthIfNeeded(force: true)
                    self.resolverSmokeProbeGeneration += 1
                    self.replaceSnapshotResolver(self.currentAppConfiguration().resolverPreset)
                    self.refreshDNSRuntimeAfterSnapshotOrConfigurationChange()
                    self.reapplyTunnelNetworkSettings(reason: "configuration-changed", enforceThrottle: false)
                    self.scheduleResolverSmokeProbeIfNeeded(reason: "configuration-changed")
                }
                completion.complete(Data("ok".utf8))
            }

        case LavaSecAppGroup.clearDiagnosticsMessage:
            dnsStateQueue.async { [weak self] in
                guard let self else {
                    completion.complete(nil)
                    return
                }

                self.diagnostics.clearDomainHistory()
                self.markDiagnosticsUpdated()
                self.persistDiagnosticsIfNeeded(force: true)
                completion.complete(Data("ok".utf8))
            }

        case LavaSecAppGroup.clearFilteringCountsMessage:
            dnsStateQueue.async { [weak self] in
                guard let self else {
                    completion.complete(nil)
                    return
                }

                self.diagnostics.clearFilteringCounts()
                self.markDiagnosticsUpdated()
                self.persistDiagnosticsIfNeeded(force: true)
                completion.complete(Data("ok".utf8))
            }

        case LavaSecAppGroup.clearNetworkActivityLogMessage:
            dnsStateQueue.async { [weak self] in
                guard let self else {
                    completion.complete(nil)
                    return
                }

                if let networkActivityLogURL {
                    NetworkActivityLogPersistence.clear(at: networkActivityLogURL)
                }
                completion.complete(Data("ok".utf8))
            }

        case LavaSecAppGroup.flushTunnelHealthMessage:
            dnsStateQueue.async { [weak self] in
                guard let self else {
                    completion.complete(nil)
                    return
                }

                self.health.networkKind = self.currentNetworkKind()
                self.health.updatedAt = Date()
                self.persistHealthIfNeeded(force: true)
                completion.complete(Data("ok".utf8))
            }

        default:
            completion.complete(nil)
        }
    }

    private static func latencyOperationID(from options: [String: NSObject]?) -> LatencyOperationID? {
        guard let rawValue = options?[LavaSecAppGroup.latencyOperationIDOptionKey] as? String,
              !rawValue.isEmpty
        else {
            return nil
        }

        return LatencyOperationID(rawValue: rawValue)
    }

    #if DEBUG || LAVA_QA_TOOLS
    private static func makeLatencyTrace(operationID: LatencyOperationID?, operationKind: String) -> LatencyTrace {
        LatencyTrace(
            operationID: operationID ?? .make(),
            sink: LatencyDebugLogEventSink(operationKind: operationKind) { event, details in
                LavaSecDeviceDebugLog.append(component: "tunnel", event: event, details: details)
            }
        )
    }
    #endif

    private func readPackets() {
        packetFlow.readPackets { [weak self] packets, protocols in
            guard let self else {
                return
            }

            for (packet, protocolNumber) in zip(packets, protocols) {
                handle(packet: packet, protocolNumber: protocolNumber)
            }

            readPackets()
        }
    }

    private let dnsQueryDispatcher = DNSQueryDispatcher()

    private func handle(packet: Data, protocolNumber: NSNumber) {
        guard let request = IPv4UDPDNSPacket(packet) else {
            return
        }

        guard let question = try? DNSMessage.parseQuestion(from: request.dnsPayload) else {
            writeParseFailureResponse(for: request, protocolNumber: protocolNumber.intValue)
            return
        }

        let resolverConfiguration = currentResolverRuntimeConfiguration()
        // Precedence (bootstrap > pause > filter) lives in the pure, tested
        // DNSQueryDispatcher; the closures stay lazy so each provider-state read
        // happens only when its step is reached (preserving the per-query cost).
        let decision = dnsQueryDispatcher.decide(
            bootstrapResponse: {
                dohBootstrapResponse(
                    for: question,
                    query: request.dnsPayload,
                    resolverConfiguration: resolverConfiguration
                ) ?? doqBootstrapResponse(
                    for: question,
                    query: request.dnsPayload,
                    resolverConfiguration: resolverConfiguration
                )
            },
            isProtectionPaused: {
                isTemporaryProtectionPauseActive(synchronizesDefaults: false)
            },
            filterDecision: {
                filterDecision(forNormalizedDomain: question.normalizedDomain)
            }
        )

        switch decision {
        case .bootstrap(let bootstrapResponse):
            resetResolverRuntimeStateIfNeeded(identifier: resolverConfiguration.cacheIdentifier)
            writeDNSResponse(bootstrapResponse, for: request, protocolNumber: protocolNumber.intValue)

        case .pausedForward:
            let maximumAnswerTTL = temporaryPauseMaximumAnswerTTL(forNormalizedDomain: question.normalizedDomain)
            recordDiagnostic(domain: question.domain, decision: .defaultAllow)
            recordFirstDNSDecisionIfNeeded("pause-allow")
            forward(
                request,
                protocolNumber: protocolNumber,
                maximumAnswerTTL: maximumAnswerTTL,
                temporaryPauseNormalizedDomain: question.normalizedDomain
            )

        case .filtered(let filterDecision):
            recordDiagnostic(domain: question.domain, decision: filterDecision)
            recordFirstDNSDecisionIfNeeded(filterDecision.action == .block ? "block" : "allow")
            guard filterDecision.action == .block else {
                forward(request, protocolNumber: protocolNumber)
                return
            }

            guard let response = try? DNSMessage.blockedResponse(
                for: request.dnsPayload,
                question: question,
                ttl: blockedTTL
            ) else {
                return
            }

            writeDNSResponse(response, for: request, protocolNumber: protocolNumber.intValue)
        }
    }

    private func forward(
        _ request: IPv4UDPDNSPacket,
        protocolNumber: NSNumber,
        maximumAnswerTTL: UInt32? = nil,
        temporaryPauseNormalizedDomain: String? = nil
    ) {
        let resolverConfiguration = currentResolverRuntimeConfiguration()
        resetResolverRuntimeStateIfNeeded(identifier: resolverConfiguration.cacheIdentifier)
        let resolverGeneration = currentResolverRuntimeGeneration()
        let dnsPayload = request.dnsPayload
        let protocolValue = protocolNumber.intValue

        guard let cacheKey = DNSCacheKey(resolverIdentifier: resolverConfiguration.cacheIdentifier, dnsPayload: dnsPayload) else {
            runBoundedResolverWork { [weak self] finish in
                guard let self else {
                    finish()
                    return
                }

                self.resolveUpstream(dnsPayload, resolverConfiguration: resolverConfiguration) { [weak self] result in
                    defer {
                        finish()
                    }

                    let response = result.response ?? DNSResponseFactory.serverFailure(for: dnsPayload)

                    guard let response else {
                        return
                    }

                    let responseToWrite = self?.responseByApplyingMaximumAnswerTTL(
                        response,
                        maximumAnswerTTL: maximumAnswerTTL
                    ) ?? DNSResponseFactory.serverFailure(for: dnsPayload)

                    self?.dnsStateQueue.async { [weak self] in
                        guard let self,
                              let responseToWrite,
                              self.isActiveResolverRuntime(
                                identifier: resolverConfiguration.cacheIdentifier,
                                generation: resolverGeneration
                              )
                        else {
                            return
                        }

                        self.writeDNSResponse(responseToWrite, for: request, protocolNumber: protocolValue)
                    }
                }
            }

            return
        }

        let pending = PendingDNSResponse(
            request: request,
            protocolNumber: protocolValue,
            maximumAnswerTTL: maximumAnswerTTL,
            temporaryPauseNormalizedDomain: temporaryPauseNormalizedDomain
        )

        dnsStateQueue.async { [weak self] in
            guard let self else {
                return
            }

            guard self.isActiveResolverRuntime(
                identifier: resolverConfiguration.cacheIdentifier,
                generation: resolverGeneration
            ) else {
                guard let response = DNSResponseFactory.serverFailure(for: dnsPayload) else {
                    return
                }

                self.writeDNSResponse(response, for: request, protocolNumber: protocolValue)
                return
            }

            let now = Date()
            if let cachedResponse = self.dnsResponseCache.cachedResponse(for: cacheKey, query: dnsPayload, now: now) {
                self.recordCacheHit()
                guard let responseToWrite = self.responseByApplyingMaximumAnswerTTL(
                    cachedResponse,
                    maximumAnswerTTL: maximumAnswerTTL
                ) ?? DNSResponseFactory.serverFailure(for: dnsPayload) else {
                    return
                }
                self.writeDNSResponse(responseToWrite, for: request, protocolNumber: protocolValue)
                return
            }

            self.recordCacheMiss()

            guard self.inFlightQueryCoalescer.enqueue(pending, for: cacheKey) == .startedResolution else {
                self.recordCoalescedQuery()
                return
            }

            self.dispatchForwardResolution(
                cacheKey: cacheKey,
                query: dnsPayload,
                resolverConfiguration: resolverConfiguration,
                resolverGeneration: resolverGeneration,
                maximumAnswerTTL: maximumAnswerTTL
            )
        }
    }

    private func dispatchForwardResolution(
        cacheKey: DNSCacheKey,
        query: Data,
        resolverConfiguration: ResolverRuntimeConfiguration,
        resolverGeneration: Int,
        maximumAnswerTTL: UInt32?
    ) {
        runBoundedResolverWork { [weak self] finish in
            guard let self else {
                finish()
                return
            }

            let startedAt = Date()
            self.resolveUpstream(query, resolverConfiguration: resolverConfiguration) { [weak self] result in
                defer {
                    finish()
                }
                let result = result.recordingDuration(since: startedAt)

                self?.dnsStateQueue.async { [weak self] in
                    self?.completeForward(
                        cacheKey: cacheKey,
                        query: query,
                        resolverIdentifier: resolverConfiguration.cacheIdentifier,
                        resolverGeneration: resolverGeneration,
                        maximumAnswerTTL: maximumAnswerTTL,
                        result: result
                    )
                }
            }
        }
    }

    private func runBoundedResolverWork(
        _ work: @escaping @Sendable (_ finish: @escaping @Sendable () -> Void) -> Void
    ) {
        resolverQueue.async { [resolverConcurrencyGate] in
            resolverConcurrencyGate.wait()
            let completion = ResolverWorkCompletion {
                resolverConcurrencyGate.signal()
            }

            work {
                completion.complete()
            }
        }
    }

    private func runResolverSmokeProbeWork(
        _ work: @escaping @Sendable (_ finish: @escaping @Sendable () -> Void) -> Void
    ) {
        resolverSmokeProbeQueue.async {
            let completion = ResolverWorkCompletion {}
            work {
                completion.complete()
            }
        }
    }

    private func writeDNSResponse(_ dnsPayload: Data, for request: IPv4UDPDNSPacket, protocolNumber: Int) {
        guard let packet = IPv4UDPDNSPacket.response(to: request, dnsPayload: dnsPayload) else {
            return
        }

        packetFlow.writePackets([packet], withProtocols: [NSNumber(value: protocolNumber)])
    }

    private func resolveUpstream(
        _ query: Data,
        resolverConfiguration: ResolverRuntimeConfiguration,
        purpose: ResolverQueryPurpose = .forwarding,
        completion: @escaping @Sendable (DNSResolutionResult) -> Void
    ) {
        resolverOrchestrator.resolveUpstream(
            query,
            plan: resolverConfiguration,
            usesIsolatedEncryptedConnections: purpose.usesIsolatedEncryptedConnection,
            completion: completion
        )
    }

    private func resolvePrimaryUpstream(
        _ query: Data,
        resolverConfiguration: ResolverRuntimeConfiguration,
        purpose: ResolverQueryPurpose = .forwarding,
        completion: @escaping @Sendable (DNSResolutionResult) -> Void
    ) {
        resolverOrchestrator.resolvePrimaryUpstream(
            query,
            plan: resolverConfiguration,
            usesIsolatedEncryptedConnections: purpose.usesIsolatedEncryptedConnection,
            completion: completion
        )
    }

    private lazy var resolverOrchestrator = ResolverOrchestrator(executors: makeResolverExecutors())

    // Wire-level executors for the core orchestrator: transports, the
    // synchronous plain/device resolvers, and the backoff gate. Per-endpoint
    // debug logging and idle-reset-on-failure live here so the orchestrator
    // stays policy-pure.
    private func makeResolverExecutors() -> ResolverOrchestrator.Executors {
        let dohResolver = dohResolver
        let dotResolver = dotResolver
        let doqResolver = doqResolver
        #if DEBUG || LAVA_QA_TOOLS
        // One wire attempt per span. "Endpoint fallback" is the multi-attempt
        // subset (an attempt whose outcome != success followed by another), so
        // the per-attempt distribution and the failover cost both fall out of
        // aggregating resolver.endpointAttempt by name. The handshake sub-cost
        // is layered underneath via the transports' dns-<t>-connection-ready
        // debug events.
        let resolverLatencyOperationID = self.resolverLatencyOperationID
        let beginResolverSpan: @Sendable (String, [String: String]) -> LatencySpan = { name, details in
            Self.makeLatencyTrace(operationID: resolverLatencyOperationID, operationKind: "resolver")
                .beginSpan(name, details: details)
        }
        let endAttemptSpan: @Sendable (LatencySpan, DNSTransportResponse) -> Void = { span, upstreamResponse in
            span.end(details: [
                "outcome": upstreamResponse.outcome.rawValue,
                "succeeded": "\(upstreamResponse.response != nil)"
            ])
        }
        #endif
        return ResolverOrchestrator.Executors(
            isEndpointBackedOff: { [weak self] address in
                self?.isResolverBackedOff(address) ?? false
            },
            resolveDoH: { query, endpoint, completion in
                #if DEBUG || LAVA_QA_TOOLS
                let attemptSpan = beginResolverSpan("resolver.endpointAttempt", ["transport": "DoH"])
                #endif
                dohResolver.resolve(query, endpoint: endpoint.url) { upstreamResponse in
                    if upstreamResponse.response == nil {
                        dohResolver.resetSessionWhenIdle()
                    }
                    #if DEBUG || LAVA_QA_TOOLS
                    endAttemptSpan(attemptSpan, upstreamResponse)
                    #endif
                    completion(upstreamResponse)
                }
            },
            resolveDoT: { query, endpoint, usesIsolatedConnection, completion in
                #if DEBUG
                LavaSecDeviceDebugLog.append(component: "tunnel", event: "dns-dot-query-begin", details: [
                    "endpoint": endpoint.displayAddress,
                    "bootstrapCount": "\(endpoint.allBootstrapServers.count)"
                ])
                #endif
                #if DEBUG || LAVA_QA_TOOLS
                let attemptSpan = beginResolverSpan("resolver.endpointAttempt", ["transport": "DoT"])
                #endif

                let finish: @Sendable (DNSTransportResponse) -> Void = { upstreamResponse in
                    if upstreamResponse.response == nil, !usesIsolatedConnection {
                        dotResolver.resetConnectionsWhenIdle()
                    }

                    #if DEBUG
                    LavaSecDeviceDebugLog.append(component: "tunnel", event: "dns-dot-query-result", details: [
                        "endpoint": endpoint.displayAddress,
                        "outcome": upstreamResponse.outcome.rawValue,
                        "succeeded": "\(upstreamResponse.response != nil)"
                    ])
                    #endif
                    #if DEBUG || LAVA_QA_TOOLS
                    endAttemptSpan(attemptSpan, upstreamResponse)
                    #endif

                    completion(upstreamResponse)
                }

                if usesIsolatedConnection {
                    dotResolver.resolveIsolated(query, endpoint: endpoint, completion: finish)
                } else {
                    dotResolver.resolve(query, endpoint: endpoint, completion: finish)
                }
            },
            resolveDoQ: { query, endpoint, usesIsolatedConnection, completion in
                #if DEBUG
                LavaSecDeviceDebugLog.append(component: "tunnel", event: "dns-doq-query-begin", details: [
                    "endpoint": endpoint.displayAddress
                ])
                #endif
                #if DEBUG || LAVA_QA_TOOLS
                let attemptSpan = beginResolverSpan("resolver.endpointAttempt", ["transport": "DoQ"])
                #endif

                let finish: @Sendable (DNSTransportResponse) -> Void = { upstreamResponse in
                    if upstreamResponse.response == nil, !usesIsolatedConnection {
                        doqResolver.resetConnectionsWhenIdle()
                    }

                    #if DEBUG
                    LavaSecDeviceDebugLog.append(component: "tunnel", event: "dns-doq-query-result", details: [
                        "endpoint": endpoint.displayAddress,
                        "outcome": upstreamResponse.outcome.rawValue,
                        "succeeded": "\(upstreamResponse.response != nil)"
                    ])
                    #endif
                    #if DEBUG || LAVA_QA_TOOLS
                    endAttemptSpan(attemptSpan, upstreamResponse)
                    #endif

                    completion(upstreamResponse)
                }

                if usesIsolatedConnection {
                    doqResolver.resolveIsolated(query, endpoint: endpoint, completion: finish)
                } else {
                    doqResolver.resolve(query, endpoint: endpoint, completion: finish)
                }
            },
            resolvePlain: { [weak self] query, addresses, transport in
                guard let self else {
                    return DNSResolutionResult(
                        response: nil,
                        successfulResolverAddress: nil,
                        attempts: [],
                        transport: transport,
                        udpTruncated: false,
                        tcpFallbackAttempted: false,
                        tcpFallbackSucceeded: false
                    )
                }

                // Plain DNS iterates addresses with UDP-then-TCP and backoff
                // internally, so one span covers the whole plain resolution
                // (the dominant DNS phase for users on a plain-IP resolver).
                #if DEBUG || LAVA_QA_TOOLS
                let attemptSpan = beginResolverSpan("resolver.endpointAttempt", ["transport": "plain"])
                #endif
                let result = self.resolvePlainDNS(query, resolverAddresses: addresses, transport: transport)
                #if DEBUG || LAVA_QA_TOOLS
                attemptSpan.end(details: [
                    "outcome": result.failureSummary ?? "success",
                    "succeeded": "\(result.response != nil)",
                    "usedTCP": "\(result.tcpFallbackAttempted)"
                ])
                #endif
                return result
            },
            resolveDevice: { [weak self] query, addresses in
                guard let self else {
                    return DNSResolutionResult(
                        response: nil,
                        successfulResolverAddress: nil,
                        attempts: [],
                        transport: .deviceDNS,
                        udpTruncated: false,
                        tcpFallbackAttempted: false,
                        tcpFallbackSucceeded: false,
                        deviceDNSUnavailable: true
                    )
                }

                #if DEBUG || LAVA_QA_TOOLS
                let fallbackSpan = beginResolverSpan("resolver.deviceFallback", [:])
                #endif
                let result = self.resolveDeviceDNS(query, resolverAddresses: addresses)
                #if DEBUG || LAVA_QA_TOOLS
                fallbackSpan.end(details: ["succeeded": "\(result.response != nil)"])
                #endif
                return result
            }
        )
    }

    private func resolveDeviceDNS(_ query: Data, resolverAddresses: [String]) -> DNSResolutionResult {
        guard !resolverAddresses.isEmpty else {
            return DNSResolutionResult(
                response: nil,
                successfulResolverAddress: nil,
                attempts: [
                    ResolverAttempt(
                        address: DNSResolverPreset.device.id,
                        outcome: .deviceDNSUnavailable,
                        transport: .deviceDNS
                    )
                ],
                transport: .deviceDNS,
                udpTruncated: false,
                tcpFallbackAttempted: false,
                tcpFallbackSucceeded: false,
                deviceDNSUnavailable: true
            )
        }

        return resolvePlainDNS(query, resolverAddresses: resolverAddresses, transport: .deviceDNS)
    }

    private func resolvePlainDNS(
        _ query: Data,
        resolverAddresses: [String],
        transport: DNSResolverTransport = .plainDNS
    ) -> DNSResolutionResult {
        var attempts: [ResolverAttempt] = []
        var sawUDPTruncation = false
        var attemptedTCPFallback = false

        let addressesForAttempt = orderedResolverAddressesForAttempt(resolverAddresses)
        if addressesForAttempt.isEmpty, !resolverAddresses.isEmpty {
            return DNSResolutionResult(
                response: nil,
                successfulResolverAddress: nil,
                attempts: resolverAddresses.map {
                    ResolverAttempt(address: $0, outcome: .backedOff, transport: transport)
                },
                transport: transport,
                udpTruncated: false,
                tcpFallbackAttempted: false,
                tcpFallbackSucceeded: false
            )
        }

        for address in addressesForAttempt {
            guard let endpoint = ResolverEndpoint(address: address) else {
                attempts.append(ResolverAttempt(address: address, outcome: .invalidAddress, transport: transport))
                continue
            }

            let udpResult = resolveUDP(query, endpoint: endpoint)
            attempts.append(ResolverAttempt(address: address, outcome: udpResult.outcome, transport: transport))

            guard let udpResponse = udpResult.response else {
                guard shouldAttemptTCPFallback(afterUDPOutcome: udpResult.outcome) else {
                    continue
                }

                attemptedTCPFallback = true
                let tcpResult = TCPResolver.resolve(query, endpoint: endpoint, timeoutSeconds: Self.tcpDNSTimeoutSeconds)
                attempts.append(
                    ResolverAttempt(
                        address: address,
                        outcome: tcpResult.outcome,
                        transport: transport,
                        usedTCP: true
                    )
                )

                if let tcpResponse = tcpResult.response {
                    return DNSResolutionResult(
                        response: tcpResponse,
                        successfulResolverAddress: address,
                        attempts: attempts,
                        transport: transport,
                        udpTruncated: sawUDPTruncation,
                        tcpFallbackAttempted: attemptedTCPFallback,
                        tcpFallbackSucceeded: true
                    )
                }

                continue
            }

            if DNSMessageTraits.isTruncated(udpResponse) {
                sawUDPTruncation = true
                attemptedTCPFallback = true
                let tcpResult = TCPResolver.resolve(query, endpoint: endpoint, timeoutSeconds: Self.tcpDNSTimeoutSeconds)
                attempts.append(
                    ResolverAttempt(
                        address: address,
                        outcome: tcpResult.outcome,
                        transport: transport,
                        usedTCP: true
                    )
                )

                if let tcpResponse = tcpResult.response {
                    return DNSResolutionResult(
                        response: tcpResponse,
                        successfulResolverAddress: address,
                        attempts: attempts,
                        transport: transport,
                        udpTruncated: true,
                        tcpFallbackAttempted: attemptedTCPFallback,
                        tcpFallbackSucceeded: true
                    )
                }

                continue
            }

            return DNSResolutionResult(
                response: udpResponse,
                successfulResolverAddress: address,
                attempts: attempts,
                transport: transport,
                udpTruncated: sawUDPTruncation,
                tcpFallbackAttempted: attemptedTCPFallback,
                tcpFallbackSucceeded: false
            )
        }

        return DNSResolutionResult(
            response: nil,
            successfulResolverAddress: nil,
            attempts: attempts,
            transport: transport,
            udpTruncated: sawUDPTruncation,
            tcpFallbackAttempted: attemptedTCPFallback,
            tcpFallbackSucceeded: false
        )
    }

    private func shouldAttemptTCPFallback(afterUDPOutcome outcome: ResolverAttemptOutcome) -> Bool {
        switch outcome {
        case .timeout:
            return true
        case .sendFailed:
            return false
        case .success,
             .httpStatusFailure,
             .backedOff,
             .receiveFailed,
             .invalidAddress,
             .unsupported,
             .socketUnavailable,
             .mismatchedResponse,
             .deviceDNSUnavailable:
            return false
        }
    }

    private lazy var resolverBootstrapService = ResolverBootstrapService(
        resolveAddresses: { [weak self] hostname in
            guard let self else {
                return ResolverBootstrapService.ResolvedAddresses(ipv4: [], ipv6: [])
            }

            let resolverAddresses = self.orderedResolverAddressesForCurrentNetwork(self.currentDeviceDNSResolverAddresses())
            guard !resolverAddresses.isEmpty else {
                return ResolverBootstrapService.ResolvedAddresses(ipv4: [], ipv6: [])
            }

            #if DEBUG || LAVA_QA_TOOLS
            // Async pre-warm (off the packet path) but timed: a slow bootstrap
            // is what the synchronous-bootstrap extraction removed from the
            // hot path, so it stays worth ranking.
            let bootstrapSpan = Self.makeLatencyTrace(
                operationID: self.resolverLatencyOperationID,
                operationKind: "resolver"
            ).beginSpan("resolver.bootstrap")
            #endif
            let bootstrap = self.resolveDoQBootstrapAddresses(for: hostname, resolverAddresses: resolverAddresses)
            #if DEBUG || LAVA_QA_TOOLS
            bootstrapSpan.end(details: [
                "ipv4Count": "\(bootstrap.ipv4.count)",
                "ipv6Count": "\(bootstrap.ipv6.count)",
                "succeeded": "\(!bootstrap.ipv4.isEmpty || !bootstrap.ipv6.isEmpty)"
            ])
            #endif

            #if DEBUG
            LavaSecDeviceDebugLog.append(component: "tunnel", event: "dns-doq-bootstrap-resolved", details: [
                "hostname": hostname,
                "ipv4Count": "\(bootstrap.ipv4.count)",
                "ipv6Count": "\(bootstrap.ipv6.count)"
            ])
            #endif

            return ResolverBootstrapService.ResolvedAddresses(ipv4: bootstrap.ipv4, ipv6: bootstrap.ipv6)
        }
    )

    /// Settle window for coalescing the proactive resolver rebuild across a burst
    /// of network-path flaps (plan item 430). Long enough to swallow a flapping
    /// cellular/Wi-Fi handoff, short enough that a genuine single change re-probes
    /// promptly. Confined to `dnsStateQueue`.
    private let resolverProbeSettleInterval: TimeInterval = 1.5

    private lazy var resolverProbeCoalescer = NetworkSettleCoalescer(
        settleInterval: resolverProbeSettleInterval,
        scheduler: DispatchSettleWorkScheduler(queue: dnsStateQueue),
        work: { [weak self] in
            self?.performCoalescedNetworkSettleProbe()
        }
    )

    /// Runs the deferred proactive resolver rebuild (DoQ bootstrap pre-warm + DNS
    /// smoke probe) once the network path has settled. The connection teardown for
    /// each change already happened immediately in `handleNetworkPathUpdate`; only
    /// this proactive work is coalesced so a flap burst re-handshakes once, not per
    /// flap.
    private func performCoalescedNetworkSettleProbe() {
        guard DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true else {
            dnsStateQueue.async { [weak self] in
                self?.performCoalescedNetworkSettleProbe()
            }
            return
        }

        guard health.networkPathIsSatisfied else {
            return
        }

        prewarmResolverBootstrapIfNeeded()
        scheduleResolverSmokeProbeIfNeeded(reason: "network-settled")
    }

    private func doqEndpointResolvingBootstrapIfNeeded(_ endpoint: DNSOverQUICEndpoint) -> DNSOverQUICEndpoint {
        guard endpoint.allBootstrapServers.isEmpty,
              ResolverEndpoint(address: endpoint.hostname) == nil
        else {
            return endpoint
        }

        guard let cached = resolverBootstrapService.cachedAddresses(forHostname: endpoint.hostname) else {
            // Never block the packet path on a bootstrap lookup: warm the
            // cache asynchronously and let the stub resolver's retry find the
            // addresses (pre-warms at tunnel start, resolver switches, and
            // network changes make this miss rare).
            resolverBootstrapService.prewarm(hostname: endpoint.hostname)
            return endpoint
        }

        return DNSOverQUICEndpoint(
            hostname: endpoint.hostname,
            port: endpoint.port,
            bootstrapIPv4Servers: cached.ipv4,
            bootstrapIPv6Servers: cached.ipv6
        )
    }

    private func prewarmResolverBootstrapIfNeeded() {
        let resolverConfiguration = currentResolverRuntimeConfiguration()
        guard resolverConfiguration.transport == .dnsOverQUIC else {
            return
        }

        for endpoint in resolverConfiguration.doqEndpoints
        where endpoint.allBootstrapServers.isEmpty && ResolverEndpoint(address: endpoint.hostname) == nil {
            resolverBootstrapService.prewarm(hostname: endpoint.hostname)
        }
    }

    private func resolveDoQBootstrapAddresses(
        for hostname: String,
        resolverAddresses: [String]
    ) -> (ipv4: [String], ipv6: [String]) {
        let aQuery = DNSResolverSmokeProbe.query(
            transactionID: UInt16.random(in: 0...UInt16.max),
            domain: hostname,
            recordType: DNSRecordType.a.rawValue
        )
        let aResult = resolvePlainDNS(aQuery, resolverAddresses: resolverAddresses, transport: .deviceDNS)
        let ipv4 = DNSBootstrapAddressExtractor.addresses(from: aResult.response, matching: aQuery, recordType: .a)

        let aaaaQuery = DNSResolverSmokeProbe.query(
            transactionID: UInt16.random(in: 0...UInt16.max),
            domain: hostname,
            recordType: DNSRecordType.aaaa.rawValue
        )
        let aaaaResult = resolvePlainDNS(aaaaQuery, resolverAddresses: resolverAddresses, transport: .deviceDNS)
        let ipv6 = DNSBootstrapAddressExtractor.addresses(from: aaaaResult.response, matching: aaaaQuery, recordType: .aaaa)

        return (ipv4, ipv6)
    }

    private func resolveUDP(_ query: Data, endpoint: ResolverEndpoint) -> DNSUpstreamResponse {
        resolverSocketQueue.sync {
            if resolverSockets[endpoint] == nil {
                resolverSockets[endpoint] = UDPResolverSocket(endpoint: endpoint, timeoutSeconds: Self.udpDNSTimeoutSeconds)
            }

            guard let socket = resolverSockets[endpoint] else {
                return DNSUpstreamResponse(response: nil, outcome: .socketUnavailable)
            }

            let result = socket.resolve(query)
            if result.response == nil {
                resolverSockets[endpoint] = nil
            }

            return result
        }
    }

    private func orderedResolverAddressesForAttempt(_ addresses: [String], now: Date = Date()) -> [String] {
        resolverBackoffStateQueue.sync {
            resolverBackoffPolicy.availableAddresses(from: addresses, now: now)
        }
    }

    private func isResolverBackedOff(_ address: String, now: Date = Date()) -> Bool {
        resolverBackoffStateQueue.sync {
            resolverBackoffPolicy.isBackedOff(address, now: now)
        }
    }

    private func completeForward(
        cacheKey: DNSCacheKey,
        query: Data,
        resolverIdentifier: String,
        resolverGeneration: Int,
        maximumAnswerTTL: UInt32?,
        result: DNSResolutionResult
    ) {
        guard isActiveResolverRuntime(identifier: resolverIdentifier, generation: resolverGeneration) else {
            return
        }

        let pendingResponses = inFlightQueryCoalescer.drain(cacheKey)
        recordUpstreamResult(result)

        let upstreamResponse = result.response ?? DNSResponseFactory.serverFailure(for: query)

        guard let upstreamResponse else {
            return
        }
        let responseToWrite = DNSWireMessage.hasWellFormedResourceRecords(upstreamResponse)
            ? upstreamResponse
            : DNSResponseFactory.serverFailure(for: query)
        guard let responseToWrite else {
            return
        }

        let cacheMaximumAnswerTTL = pendingResponses
            .compactMap(\.maximumAnswerTTL)
            .min()
            ?? maximumAnswerTTL
        let responseToCache = responseByApplyingMaximumAnswerTTL(
            responseToWrite,
            maximumAnswerTTL: cacheMaximumAnswerTTL
        )

        if let responseToCache {
            dnsResponseCache.store(responseToCache, for: cacheKey)
        }

        for pending in pendingResponses {
            guard let pendingResponse = responseForPendingForward(
                responseToWrite,
                pending: pending
            ) else {
                continue
            }
            let response = DNSWireMessage.replacingTransactionID(in: pendingResponse, from: pending.request.dnsPayload)
            writeDNSResponse(response, for: pending.request, protocolNumber: pending.protocolNumber)
        }
    }

    private func responseByApplyingMaximumAnswerTTL(
        _ response: Data,
        maximumAnswerTTL: UInt32?
    ) -> Data? {
        guard DNSWireMessage.hasWellFormedResourceRecords(response) else {
            return nil
        }
        guard let maximumAnswerTTL else {
            return response
        }

        return DNSWireMessage.cappingCacheableTTLs(in: response, to: maximumAnswerTTL)
    }

    private func responseForPendingForward(
        _ response: Data,
        pending: PendingDNSResponse
    ) -> Data? {
        if let normalizedDomain = pending.temporaryPauseNormalizedDomain,
           !isTemporaryProtectionPauseActive(synchronizesDefaults: false),
           protectionPolicyDecision(forNormalizedDomain: normalizedDomain).action == .block {
            return try? DNSMessage.blockedResponse(
                for: pending.request.dnsPayload,
                ttl: blockedTTL
            )
        }

        return responseByApplyingMaximumAnswerTTL(
            response,
            maximumAnswerTTL: pending.maximumAnswerTTL
        )
    }

    private func writeParseFailureResponse(for request: IPv4UDPDNSPacket, protocolNumber: Int) {
        guard let response = DNSResponseFactory.serverFailure(for: request.dnsPayload) else {
            return
        }

        writeDNSResponse(response, for: request, protocolNumber: protocolNumber)
    }

    private func currentResolverRuntimeGeneration() -> Int {
        if DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true {
            return resolverRuntimeGeneration
        }

        return dnsStateQueue.sync {
            resolverRuntimeGeneration
        }
    }

    private func isActiveResolverRuntime(identifier: String, generation: Int) -> Bool {
        activeResolverRuntimeIdentifier == identifier && resolverRuntimeGeneration == generation
    }


    private func currentResolverRuntimeConfiguration(
        ignoresDeviceDNSFallbackMode: Bool = false,
        allowsQueryFallback: Bool = true
    ) -> ResolverRuntimeConfiguration {
        let configuration = currentAppConfiguration()
        return DNSResolverRuntimePlan.make(
            configuration: configuration,
            deviceDNSAddresses: currentDeviceDNSResolverAddresses(),
            networkKind: currentNetworkKind(),
            deviceDNSFallbackModeActive: currentDeviceDNSFallbackModeActive(),
            ignoresDeviceDNSFallbackMode: ignoresDeviceDNSFallbackMode,
            allowsQueryFallback: allowsQueryFallback
        )
    }

    private func orderedResolverAddressesForCurrentNetwork(_ addresses: [String]) -> [String] {
        DNSResolverRuntimePlan.orderedResolverAddresses(addresses, networkKind: currentNetworkKind())
    }

    private func dohBootstrapResponse(
        for question: DNSQuestion,
        query: Data,
        resolverConfiguration: ResolverRuntimeConfiguration
    ) -> Data? {
        guard resolverConfiguration.transport == .dnsOverHTTPS,
              let normalizedQuestionDomain = try? DomainName.normalize(question.domain),
              let endpoint = resolverConfiguration.dohEndpoints.first(where: { endpoint in
                  guard let endpointHost = endpoint.url.host,
                        let normalizedEndpointHost = try? DomainName.normalize(endpointHost)
                  else {
                      return false
                  }

                  return normalizedQuestionDomain == normalizedEndpointHost
              })
        else {
            return nil
        }

        // Bootstrap answers for the selected DoH hostname bypass filtering and diagnostics to avoid resolver recursion.
        return DNSBootstrapResponseFactory.response(for: query, question: question, endpoint: endpoint)
    }

    private func doqBootstrapResponse(
        for question: DNSQuestion,
        query: Data,
        resolverConfiguration: ResolverRuntimeConfiguration
    ) -> Data? {
        guard resolverConfiguration.transport == .dnsOverQUIC,
              let normalizedQuestionDomain = try? DomainName.normalize(question.domain),
              let endpoint = resolverConfiguration.doqEndpoints.first(where: { endpoint in
                  guard let normalizedEndpointHost = try? DomainName.normalize(endpoint.hostname) else {
                      return false
                  }

                  return normalizedQuestionDomain == normalizedEndpointHost
              })
        else {
            return nil
        }

        let bootstrappedEndpoint = doqEndpointResolvingBootstrapIfNeeded(endpoint)
        guard !bootstrappedEndpoint.allBootstrapServers.isEmpty else {
            return nil
        }

        // Bootstrap answers for the selected DoQ hostname keep NWConnection hostname-based for SNI/cert validation while avoiding resolver recursion.
        return DNSBootstrapResponseFactory.response(for: query, question: question, endpoint: bootstrappedEndpoint)
    }

    private func startPeriodicResolverSmokeProbe() {
        guard DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true else {
            dnsStateQueue.async { [weak self] in
                self?.startPeriodicResolverSmokeProbe()
            }
            return
        }

        resolverSmokeProbeTimer?.cancel()

        let timer = DispatchSource.makeTimerSource(queue: dnsStateQueue)
        timer.schedule(
            deadline: .now() + Self.resolverSmokeProbeInterval,
            repeating: Self.resolverSmokeProbeInterval
        )
        timer.setEventHandler { [weak self] in
            self?.scheduleResolverSmokeProbeIfNeeded(reason: "periodic-health-check")
        }
        resolverSmokeProbeTimer = timer
        timer.resume()
    }

    private func stopPeriodicResolverSmokeProbe() {
        guard DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true else {
            dnsStateQueue.async { [weak self] in
                self?.stopPeriodicResolverSmokeProbe()
            }
            return
        }

        resolverSmokeProbeTimer?.cancel()
        resolverSmokeProbeTimer = nil
    }

    private func scheduleFallbackRecoverySmokeProbeIfNeeded() {
        guard DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true else {
            dnsStateQueue.async { [weak self] in
                self?.scheduleFallbackRecoverySmokeProbeIfNeeded()
            }
            return
        }

        guard DeviceDNSFallbackPolicy.shouldScheduleFallbackFollowUpProbe(
                deviceDNSFallbackModeActive: deviceDNSFallbackModeActive,
                consecutiveFallbackEvidenceCount: consecutiveQueryFallbackSuccessCount
              ),
              health.networkPathIsSatisfied,
              fallbackRecoverySmokeProbeWorkItem == nil
        else {
            return
        }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else {
                return
            }

            self.fallbackRecoverySmokeProbeWorkItem = nil
            guard DeviceDNSFallbackPolicy.shouldScheduleFallbackFollowUpProbe(
                deviceDNSFallbackModeActive: self.deviceDNSFallbackModeActive,
                consecutiveFallbackEvidenceCount: self.consecutiveQueryFallbackSuccessCount
            ) else {
                return
            }

            self.scheduleResolverSmokeProbeIfNeeded(reason: "device-dns-fallback-recovery")
        }

        fallbackRecoverySmokeProbeWorkItem = workItem
        dnsStateQueue.asyncAfter(
            deadline: .now() + DeviceDNSFallbackPolicy.fallbackRecoverySmokeProbeInterval,
            execute: workItem
        )
    }

    private func cancelFallbackRecoverySmokeProbe() {
        guard DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true else {
            dnsStateQueue.async { [weak self] in
                self?.cancelFallbackRecoverySmokeProbe()
            }
            return
        }

        fallbackRecoverySmokeProbeWorkItem?.cancel()
        fallbackRecoverySmokeProbeWorkItem = nil
    }

    private func scheduleResolverSmokeProbeIfNeeded(reason: String) {
        guard DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true else {
            dnsStateQueue.async { [weak self] in
                self?.scheduleResolverSmokeProbeIfNeeded(reason: reason)
            }
            return
        }

        guard health.networkPathIsSatisfied else {
            return
        }

        let resolverConfiguration = currentResolverRuntimeConfiguration(
            ignoresDeviceDNSFallbackMode: true,
            allowsQueryFallback: false
        )
        let canUseDeviceDNSFallback = currentAppConfiguration().fallbackToDeviceDNS
            && resolverConfiguration.transport != .deviceDNS
            && !resolverConfiguration.deviceDNSFallbackAddresses.isEmpty
        resolverSmokeProbeGeneration += 1
        let generation = resolverSmokeProbeGeneration
        let query = DNSResolverSmokeProbe.query(transactionID: UInt16.random(in: 0...UInt16.max))

        #if DEBUG
        LavaSecDeviceDebugLog.append(component: "tunnel", event: "dns-smoke-probe-begin", details: [
            "reason": reason,
            "transport": resolverConfiguration.transport.rawValue,
            "canUseDeviceDNSFallback": "\(canUseDeviceDNSFallback)"
        ])
        #endif

        runResolverSmokeProbeWork { [weak self] finish in
            guard let self else {
                finish()
                return
            }

            let timeout = ResolverSmokeProbeTimeout { [weak self] in
                guard let self else {
                    finish()
                    return
                }

                self.dnsStateQueue.async { [weak self] in
                    guard let self else {
                        finish()
                        return
                    }

                    let timeoutResult = self.resolverSmokeProbeTimeoutResult(
                        resolverConfiguration: resolverConfiguration
                    )
                    self.completeResolverSmokeProbeResult(
                        generation: generation,
                        reason: reason,
                        primaryResult: timeoutResult,
                        primarySucceeded: false,
                        fallbackResult: nil,
                        fallbackSucceeded: false
                    )
                    finish()
                }
            }
            timeout.schedule(on: dnsStateQueue, timeoutSeconds: Self.resolverSmokeProbeTimeoutSeconds)

            self.resolvePrimaryUpstream(query, resolverConfiguration: resolverConfiguration, purpose: .smokeProbe) { [weak self] primaryResult in
                guard let self else {
                    timeout.cancel()
                    finish()
                    return
                }

                let primarySucceeded = DNSResolverSmokeProbe.acceptsResolutionResponse(
                    primaryResult.response,
                    matching: query
                )

                #if DEBUG
                LavaSecDeviceDebugLog.append(component: "tunnel", event: "dns-smoke-probe-primary-result", details: [
                    "reason": reason,
                    "primaryAccepted": "\(primarySucceeded)",
                    "primaryHasResponse": "\(primaryResult.response != nil)",
                    "primaryOutcome": primaryResult.failureSummary ?? "success",
                    "transport": primaryResult.transport.rawValue,
                    "resolver": primaryResult.successfulResolverAddress ?? primaryResult.attempts.last?.address ?? "nil"
                ])
                #endif

                guard !primarySucceeded, canUseDeviceDNSFallback else {
                    timeout.cancel()
                    self.dnsStateQueue.async { [weak self] in
                        self?.completeResolverSmokeProbeResult(
                            generation: generation,
                            reason: reason,
                            primaryResult: primaryResult,
                            primarySucceeded: primarySucceeded,
                            fallbackResult: nil,
                            fallbackSucceeded: false
                        )
                    }
                    finish()
                    return
                }

                self.resolverQueue.async { [weak self] in
                    guard let self else {
                        timeout.cancel()
                        finish()
                        return
                    }

                    #if DEBUG
                    LavaSecDeviceDebugLog.append(component: "tunnel", event: "dns-smoke-probe-fallback-begin", details: [
                        "reason": reason,
                        "resolverCount": "\(resolverConfiguration.deviceDNSFallbackAddresses.count)"
                    ])
                    #endif

                    let fallbackResult = self.resolveDeviceDNS(
                        query,
                        resolverAddresses: resolverConfiguration.deviceDNSFallbackAddresses
                    )
                    let fallbackSucceeded = DNSResolverSmokeProbe.acceptsResolutionResponse(
                        fallbackResult.response,
                        matching: query
                    )

                    #if DEBUG
                    LavaSecDeviceDebugLog.append(component: "tunnel", event: "dns-smoke-probe-fallback-result", details: [
                        "reason": reason,
                        "fallbackAccepted": "\(fallbackSucceeded)",
                        "fallbackHasResponse": "\(fallbackResult.response != nil)",
                        "fallbackOutcome": fallbackResult.failureSummary ?? "success",
                        "resolver": fallbackResult.successfulResolverAddress ?? fallbackResult.attempts.last?.address ?? "nil"
                    ])
                    #endif

                    timeout.cancel()
                    self.dnsStateQueue.async { [weak self] in
                        self?.completeResolverSmokeProbeResult(
                            generation: generation,
                            reason: reason,
                            primaryResult: primaryResult,
                            primarySucceeded: primarySucceeded,
                            fallbackResult: fallbackResult,
                            fallbackSucceeded: fallbackSucceeded
                        )
                    }
                    finish()
                }
            }
        }
    }

    private func resolverSmokeProbeTimeoutResult(
        resolverConfiguration: ResolverRuntimeConfiguration
    ) -> DNSResolutionResult {
        DNSResolutionResult(
            response: nil,
            successfulResolverAddress: nil,
            attempts: [
                ResolverAttempt(
                    address: resolverConfiguration.cacheIdentifier,
                    outcome: .timeout,
                    transport: resolverConfiguration.transport
                )
            ],
            transport: resolverConfiguration.transport,
            udpTruncated: false,
            tcpFallbackAttempted: false,
            tcpFallbackSucceeded: false
        )
    }

    private func completeResolverSmokeProbeResult(
        generation: Int,
        reason: String,
        primaryResult: DNSResolutionResult,
        primarySucceeded: Bool,
        fallbackResult: DNSResolutionResult?,
        fallbackSucceeded: Bool
    ) {
        guard generation == resolverSmokeProbeGeneration else {
            return
        }

        applyResolverSmokeProbeResult(
            generation: generation,
            reason: reason,
            primaryResult: primaryResult,
            primarySucceeded: primarySucceeded,
            fallbackResult: fallbackResult,
            fallbackSucceeded: fallbackSucceeded
        )

        if resolverSmokeProbeGeneration == generation {
            resolverSmokeProbeGeneration += 1
        }
    }

    private func applyResolverSmokeProbeResult(
        generation: Int,
        reason: String,
        primaryResult: DNSResolutionResult,
        primarySucceeded: Bool,
        fallbackResult: DNSResolutionResult?,
        fallbackSucceeded: Bool
    ) {
        guard generation == resolverSmokeProbeGeneration else {
            return
        }

        let now = Date()
        let wasDeviceDNSFallbackModeActive = deviceDNSFallbackModeActive
        let previousDNSSmokeProbeSucceeded = health.lastDNSSmokeProbeSucceeded
        health.lastDNSSmokeProbeAt = now
        health.lastDNSSmokeProbeSucceeded = primarySucceeded || fallbackSucceeded

        if primarySucceeded {
            consecutiveQueryFallbackSuccessCount = 0
            deviceDNSFallbackModeActive = false
            health.deviceDNSFallbackModeActive = false
            health.lastDeviceDNSFallbackActivatedAt = nil
            health.dnsSmokeProbeSuccessCount += 1
            health.lastFailureReason = nil
            health.lastResolverAddress = primaryResult.successfulResolverAddress
            health.lastResolverTransport = primaryResult.transport
            if primaryResult.transport == .dnsOverHTTPS, let negotiatedDoHProtocol = primaryResult.negotiatedDoHProtocol {
                health.lastDoHHTTPVersion = negotiatedDoHProtocol
            }
            health.consecutiveUpstreamFailureCount = 0
            clearReconnectNeededActivitySuppression()
            cancelFallbackRecoverySmokeProbe()
            let pendingResponses = wasDeviceDNSFallbackModeActive
                ? collectPendingResponsesAndResetResolverRuntime(
                    identifier: currentResolverRuntimeConfiguration().cacheIdentifier,
                    reason: "device-dns-fallback-recovered",
                    force: true
                )
                : []
            markHealthUpdated()
            if wasDeviceDNSFallbackModeActive {
                appendNetworkActivity(event: .deviceDNSFallbackRecovered, now: now)
            } else if reason == "network-path-changed" || previousDNSSmokeProbeSucceeded == false {
                appendNetworkActivity(
                    event: .dnsSmokeProbeSucceeded(
                        resolver: currentAppConfiguration().resolverPreset.displayName,
                        transport: primaryResult.transport,
                        dohHTTPVersion: primaryResult.negotiatedDoHProtocol
                    ),
                    now: now
                )
            }
            scheduleProtectionNotificationIfNeeded(now: now)
            writeServerFailures(for: pendingResponses)
            #if LAVA_QA_TOOLS
            logQAConnectivityAssessmentIfNeeded(reason: "dns-smoke-probe-success", now: now)
            #endif

            #if DEBUG
            LavaSecDeviceDebugLog.append(component: "tunnel", event: "dns-smoke-probe-success", details: [
                "reason": reason,
                "transport": primaryResult.transport.rawValue,
                "resolver": primaryResult.successfulResolverAddress ?? "nil",
                "dohHTTPVersion": primaryResult.negotiatedDoHProtocol ?? "nil"
            ])
            #endif
            return
        }

        if fallbackSucceeded, let fallbackResult {
            health.dnsSmokeProbeSuccessCount += 1
            consecutiveQueryFallbackSuccessCount = DeviceDNSFallbackPolicy.nextConsecutiveFallbackEvidenceCount(
                currentCount: consecutiveQueryFallbackSuccessCount,
                primaryResolverWasAttempted: primaryResult.hasFallbackActivationEvidence
            )
            if DeviceDNSFallbackPolicy.shouldActivateFallbackMode(
                consecutiveQueryFallbackSuccesses: consecutiveQueryFallbackSuccessCount
            ) {
                deviceDNSFallbackModeActive = true
                health.deviceDNSFallbackModeActive = true
                if !wasDeviceDNSFallbackModeActive {
                    health.lastDeviceDNSFallbackActivatedAt = now
                    health.deviceDNSFallbackActivationCount += 1
                } else if health.lastDeviceDNSFallbackActivatedAt == nil {
                    health.lastDeviceDNSFallbackActivatedAt = now
                }
            } else {
                health.deviceDNSFallbackModeActive = false
            }
            health.lastFailureReason = nil
            health.lastResolverAddress = fallbackResult.successfulResolverAddress
            health.lastResolverTransport = .deviceDNS
            health.consecutiveUpstreamFailureCount = 0
            clearReconnectNeededActivitySuppression()
            let pendingResponses = deviceDNSFallbackModeActive
                ? collectPendingResponsesAndResetResolverRuntime(
                    identifier: currentResolverRuntimeConfiguration().cacheIdentifier,
                    reason: "device-dns-fallback-activated",
                    force: true
                )
                : []
            markHealthUpdated()
            if deviceDNSFallbackModeActive, !wasDeviceDNSFallbackModeActive {
                appendNetworkActivity(event: .deviceDNSFallbackActivated(reason: reason), now: now)
            }
            scheduleFallbackRecoverySmokeProbeIfNeeded()
            if deviceDNSFallbackModeActive {
                scheduleProtectionNotificationIfNeeded(now: now)
            }
            persistHealthIfNeeded(force: true)
            writeServerFailures(for: pendingResponses)
            #if LAVA_QA_TOOLS
            logQAConnectivityAssessmentIfNeeded(
                reason: deviceDNSFallbackModeActive ? "device-dns-fallback-activated" : "device-dns-fallback-candidate",
                now: now
            )
            #endif

            #if DEBUG
            LavaSecDeviceDebugLog.append(component: "tunnel", event: "dns-smoke-probe-device-fallback", details: [
                "reason": reason,
                "resolver": fallbackResult.successfulResolverAddress ?? "nil",
                "evidenceCount": "\(consecutiveQueryFallbackSuccessCount)",
                "fallbackModeActive": "\(deviceDNSFallbackModeActive)"
            ])
            #endif
            return
        }

        health.dnsSmokeProbeFailureCount += 1
        if wasDeviceDNSFallbackModeActive {
            deviceDNSFallbackModeActive = false
            health.deviceDNSFallbackModeActive = false
            health.lastDeviceDNSFallbackActivatedAt = nil
            consecutiveQueryFallbackSuccessCount = 0
            cancelFallbackRecoverySmokeProbe()
        }
        health.lastFailureReason = primaryResult.failureSummary ?? fallbackResult?.failureSummary ?? "dns-smoke-failed"
        health.lastUpstreamFailureAt = now
        health.consecutiveUpstreamFailureCount += 1
        health.lastResolverAddress = primaryResult.successfulResolverAddress ?? primaryResult.attempts.last?.address
        health.lastResolverTransport = primaryResult.transport
        markHealthUpdated()
        let failureReason = health.lastFailureReason ?? "dns-smoke-failed"
        appendNetworkActivity(event: .dnsSmokeProbeFailed(reason: failureReason), now: now)
        appendReconnectNeededIfPolicyRequiresReconnect(now: now)
        scheduleProtectionNotificationIfNeeded(now: now)
        #if LAVA_QA_TOOLS
        logQAConnectivityAssessmentIfNeeded(reason: "dns-smoke-probe-failed", now: now)
        #endif

        #if DEBUG
        LavaSecDeviceDebugLog.append(component: "tunnel", event: "dns-smoke-probe-failed", details: [
            "reason": reason,
            "failure": health.lastFailureReason ?? "nil"
        ])
        #endif
    }

    private func resetHealth() {
        dnsStateQueue.async { [weak self] in
            guard let self else {
                return
            }

            self.health = TunnelHealthSnapshot(networkKind: self.currentNetworkKind())
            self.persistHealthIfNeeded(force: true)
        }
    }

    private func startPathMonitor() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard let self else {
                return
            }

            let update = NetworkPathUpdate(
                kind: Self.tunnelNetworkKind(for: path),
                isSatisfied: path.status == .satisfied,
                statusDescription: Self.pathStatusDescription(path.status)
            )
            self.dnsStateQueue.async { [weak self] in
                self?.handleNetworkPathUpdate(update)
            }
        }

        pathMonitor.start(queue: dnsStateQueue)
    }

    private func handleNetworkPathUpdate(_ update: NetworkPathUpdate) {
        let previousKind = lastObservedPathKind
        let previousIsSatisfied = lastObservedPathIsSatisfied
        let isInitialPathUpdate = previousKind == nil && previousIsSatisfied == nil
        let didMeaningfullyChange = previousKind != update.kind || previousIsSatisfied != update.isSatisfied

        lastObservedPathKind = update.kind
        lastObservedPathIsSatisfied = update.isSatisfied
        networkKind = update.kind
        health.networkKind = update.kind
        health.networkPathIsSatisfied = update.isSatisfied

        guard !isInitialPathUpdate, didMeaningfullyChange else {
            markHealthUpdated()
            if isInitialPathUpdate {
                persistHealthIfNeeded(force: true)
            }
            return
        }

        let now = Date()
        health.lastNetworkChangeAt = now
        health.networkChangeCount += 1
        health.lastFailureReason = nil
        health.consecutiveUpstreamFailureCount = 0
        deviceDNSFallbackModeActive = false
        consecutiveQueryFallbackSuccessCount = 0
        health.deviceDNSFallbackModeActive = false
        health.lastDeviceDNSFallbackActivatedAt = nil
        clearReconnectNeededActivitySuppression()
        cancelFallbackRecoverySmokeProbe()
        resolverSmokeProbeGeneration += 1
        refreshDeviceDNSResolverAddressesOnDNSQueue(reason: "network-path-changed")

        let resolverIdentifier = currentResolverRuntimeConfiguration().cacheIdentifier
        let pendingResponses = collectPendingResponsesAndResetResolverRuntime(
            identifier: resolverIdentifier,
            reason: "network-path-changed",
            force: true
        )
        resolverBootstrapService.invalidateAll()
        // Bootstrap pre-warm is deferred to the coalesced settle probe below so a
        // flap burst re-resolves once, not per flap (plan item 430).
        markHealthUpdated()
        appendNetworkActivity(
            event: .networkChanged(from: previousKind, to: update.kind, isSatisfied: update.isSatisfied),
            now: now
        )
        #if LAVA_QA_TOOLS
        logQAConnectivityAssessmentIfNeeded(reason: "network-path-changed", now: now)
        #endif
        persistHealthIfNeeded(force: true)
        if !update.isSatisfied {
            // Path is down: drop any pending settle probe so we don't re-handshake
            // into a dead network when the timer fires.
            resolverProbeCoalescer.cancel()
            scheduleProtectionNotificationIfNeeded(now: now)
        }

        #if DEBUG
        LavaSecDeviceDebugLog.append(component: "tunnel", event: "network-path-changed", details: [
            "previousKind": previousKind?.rawValue ?? "nil",
            "kind": update.kind.rawValue,
            "previousSatisfied": previousIsSatisfied.map { "\($0)" } ?? "nil",
            "isSatisfied": "\(update.isSatisfied)",
            "status": update.statusDescription,
            "pendingResponses": "\(pendingResponses.count)",
            "resolverIdentifier": resolverIdentifier
        ])
        #endif

        writeServerFailures(for: pendingResponses)

        if update.isSatisfied {
            reapplyTunnelNetworkSettings(reason: "network-path-changed", enforceThrottle: true)
            // Coalesce the proactive resolver rebuild (bootstrap pre-warm + smoke
            // probe) so a flap burst re-handshakes once after the path settles,
            // not once per flap (plan item 430). Settings reapply keeps its own
            // ≥1 s throttle above.
            resolverProbeCoalescer.noteUnsettled()
        }
    }

    private func reapplyTunnelNetworkSettings(reason: String, enforceThrottle: Bool) {
        let now = Date()
        guard !enforceThrottle || now.timeIntervalSince(lastNetworkSettingsReapplyAt) >= 1 else {
            return
        }

        lastNetworkSettingsReapplyAt = now
        let settingsBundle = makeTunnelNetworkSettingsForCurrentConfiguration()

        #if DEBUG
        LavaSecDeviceDebugLog.append(component: "tunnel", event: "network-settings-reapply-begin", details: [
            "reason": reason,
            "kind": currentNetworkKind().rawValue,
            "dnsServerAddress": settingsBundle.dnsServerAddress,
            "route": settingsBundle.routeDescription
        ])
        #endif

        setTunnelNetworkSettings(settingsBundle.settings) { [weak self] error in
            guard let self else {
                return
            }

            #if DEBUG
            if let error {
                LavaSecDeviceDebugLog.append(
                    component: "tunnel",
                    event: "network-settings-reapply-error",
                    details: Self.errorDebugDetails(error)
                )
            } else {
                LavaSecDeviceDebugLog.append(component: "tunnel", event: "network-settings-reapply-success", details: [
                    "reason": reason,
                    "kind": self.currentNetworkKind().rawValue
                ])
            }
            #endif

            if let error {
                self.recordNetworkSettingsReapplyFailure(error, reason: reason)
            }
        }
    }

    private func recordNetworkSettingsReapplyFailure(_ error: Error, reason: String) {
        let now = Date()
        let failureReason = "\(reason): \(Self.errorSummary(error))"
        dnsStateQueue.async { [weak self] in
            guard let self else {
                return
            }

            self.health.lastNetworkSettingsReapplyFailureAt = now
            self.health.lastNetworkSettingsReapplyFailureReason = failureReason
            self.health.networkSettingsReapplyFailureCount += 1
            self.health.lastFailureReason = failureReason
            self.markHealthUpdated()
            self.persistHealthIfNeeded(force: true)
            self.appendNetworkActivity(event: .networkSettingsReapplyFailed(reason: failureReason), now: now)
            self.scheduleProtectionNotificationIfNeeded(now: now)
        }
    }

    private func loadInitialSharedState() {
        #if DEBUG
        LavaSecDeviceDebugLog.append(component: "tunnel", event: "loadInitialSharedState-begin")
        #endif

        let configuration = loadConfiguration() ?? AppConfiguration()
        setAppConfiguration(configuration)
        lastConfigurationModifiedAt = modificationDate(for: configurationURL)
        lastConfigurationRefreshAt = Date()
        let bootstrapSnapshot: any FilterRuntimeSnapshot = configuration.enabledBlocklistIDs.isEmpty
            ? configuration.filterSnapshot()
            : FailClosedRuntimeSnapshot(resolver: configuration.resolverPreset)
        snapshot = bootstrapSnapshot
        protectionPolicySnapshot = bootstrapSnapshot

        if let diagnosticsURL {
            diagnostics = DiagnosticsPersistence.load(from: diagnosticsURL)
        }

        applyDiagnosticsControlIfNeeded(force: true)
        if diagnosticsPersistence.isDirty {
            persistDiagnosticsIfNeeded(force: true)
        }

        #if DEBUG
        LavaSecDeviceDebugLog.append(component: "tunnel", event: "loadInitialSharedState-ready", details: [
            "bootstrapBlockRuleCount": "\(snapshot.blockRuleCount)",
            "bootstrapAllowRuleCount": "\(snapshot.allowRuleCount)"
        ])
        #endif
    }

    private func recordDiagnostic(domain: String, decision: FilterDecision) {
        dnsStateQueue.async { [weak self] in
            guard let self else {
                return
            }

            self.refreshConfigurationIfNeeded()
            let configuration = self.currentAppConfiguration()
            guard configuration.keepFilteringCounts || configuration.keepDomainDiagnostics else {
                return
            }

            self.diagnostics.resetForCurrentDayIfNeeded()
            self.diagnostics.record(
                domain: domain,
                decision: decision,
                keepFilteringCounts: configuration.keepFilteringCounts,
                keepDomainHistory: configuration.keepDomainDiagnostics
            )
            self.markDiagnosticsUpdated()
        }
    }

    private func markLocalProtectionUptimeStarted() {
        dnsStateQueue.async { [weak self] in
            guard let self else {
                return
            }

            guard self.currentAppConfiguration().keepFilteringCounts else {
                return
            }

            self.diagnostics.startLocalProtectionUptime()
            self.markDiagnosticsUpdated()
            self.persistDiagnosticsIfNeeded(force: true)
        }
    }

    private func refreshConfigurationIfNeeded(force: Bool = false) {
        let now = Date()
        guard force || now.timeIntervalSince(lastConfigurationRefreshAt) >= configurationRefreshInterval else {
            return
        }

        lastConfigurationRefreshAt = now
        let modifiedAt = modificationDate(for: configurationURL)
        guard force || modifiedAt != lastConfigurationModifiedAt else {
            return
        }

        if let configuration = loadConfiguration() {
            setAppConfiguration(configuration)
            lastConfigurationModifiedAt = modifiedAt
        }
    }

    // The resolver/network-settings-relevant projection of the configuration.
    // A reload whose projection is unchanged must not reset the DNS runtime or
    // reapply tunnel network settings (which the user sees as a reconnect) —
    // diagnostics toggles and paid status are deliberately excluded.
    private static func resolverNetworkIdentity(_ configuration: AppConfiguration) -> String {
        [
            configuration.resolverPresetID,
            configuration.customResolverAddress ?? "",
            configuration.customResolverSecondaryAddress ?? "",
            configuration.fallbackToDeviceDNS ? "1" : "0"
        ].joined(separator: "|")
    }

    private func recordCacheHit() {
        health.cacheHitCount += 1
        markHealthUpdated()
    }

    private func recordCacheMiss() {
        health.cacheMissCount += 1
        markHealthUpdated()
    }

    private func recordCoalescedQuery() {
        health.coalescedQueryCount += 1
        markHealthUpdated()
    }

    private func recordUpstreamResult(_ result: DNSResolutionResult) {
        updateResolverBackoff(from: result.attempts)
        let now = Date()
        let wasDeviceDNSFallbackModeActive = deviceDNSFallbackModeActive
        var activatedDeviceDNSFallback = false
        var recoveredDeviceDNSFallback = false
        let didResolve = result.response != nil

        health.networkKind = currentNetworkKind()
        health.lastResolverAddress = result.successfulResolverAddress ?? result.attempts.last?.address
        health.lastResolverTransport = result.transport
        health.lastUpstreamDurationMilliseconds = result.durationMilliseconds

        if !didResolve {
            consecutiveQueryFallbackSuccessCount = 0
            health.consecutiveSlowUpstreamResponseCount = 0
            health.upstreamFailureCount += 1
            health.consecutiveUpstreamFailureCount += 1
            health.lastFailureReason = result.failureSummary
            health.lastUpstreamFailureAt = now
        } else {
            health.upstreamSuccessCount += 1
            health.lastFailureReason = nil
            health.lastUpstreamSuccessAt = now
            health.consecutiveUpstreamFailureCount = 0
            clearReconnectNeededActivitySuppression()
            if let durationMilliseconds = result.durationMilliseconds,
               durationMilliseconds >= Self.slowUpstreamResponseThresholdMilliseconds {
                health.slowUpstreamResponseCount += 1
                health.consecutiveSlowUpstreamResponseCount += 1
                health.lastSlowUpstreamResponseAt = now
            } else {
                health.consecutiveSlowUpstreamResponseCount = 0
            }
            if !result.deviceDNSFallbackSucceeded, result.transport != .deviceDNS {
                consecutiveQueryFallbackSuccessCount = 0
            }
            if wasDeviceDNSFallbackModeActive,
               result.transport != .deviceDNS,
               !result.deviceDNSFallbackSucceeded {
                deviceDNSFallbackModeActive = false
                health.deviceDNSFallbackModeActive = false
                health.lastDeviceDNSFallbackActivatedAt = nil
                consecutiveQueryFallbackSuccessCount = 0
                cancelFallbackRecoverySmokeProbe()
                recoveredDeviceDNSFallback = true
            }
        }

        if result.udpTruncated {
            health.udpTruncatedResponseCount += 1
        }

        if result.tcpFallbackAttempted {
            health.tcpFallbackAttemptCount += 1
        }

        if result.tcpFallbackSucceeded {
            health.tcpFallbackSuccessCount += 1
        }

        if result.deviceDNSFallbackAttempted {
            health.deviceDNSFallbackAttemptCount += 1
        }

        if result.deviceDNSFallbackSucceeded {
            health.deviceDNSFallbackSuccessCount += 1
            consecutiveQueryFallbackSuccessCount = DeviceDNSFallbackPolicy.nextConsecutiveFallbackEvidenceCount(
                currentCount: consecutiveQueryFallbackSuccessCount,
                primaryResolverWasAttempted: result.hasFallbackActivationEvidence
            )
            if !deviceDNSFallbackModeActive {
                if DeviceDNSFallbackPolicy.shouldActivateFallbackMode(
                    consecutiveQueryFallbackSuccesses: consecutiveQueryFallbackSuccessCount
                ) {
                    deviceDNSFallbackModeActive = true
                    health.deviceDNSFallbackModeActive = true
                    health.lastDeviceDNSFallbackActivatedAt = now
                    health.deviceDNSFallbackActivationCount += 1
                    activatedDeviceDNSFallback = true
                }
            } else {
                health.deviceDNSFallbackModeActive = true
            }
        }

        if result.deviceDNSUnavailable {
            health.deviceDNSUnavailableCount += 1
        }

        for attempt in result.attempts {
            health.resolverAttemptCounts[attempt.address, default: 0] += 1

            switch attempt.outcome {
            case .success:
                health.resolverSuccessCounts[attempt.address, default: 0] += 1
                if attempt.transport == .dnsOverHTTPS, let negotiatedDoHProtocol = attempt.negotiatedDoHProtocol {
                    health.lastDoHHTTPVersion = negotiatedDoHProtocol
                }
            case .timeout:
                health.upstreamTimeoutCount += 1
                health.resolverFailureCounts[attempt.address, default: 0] += 1
            case .httpStatusFailure:
                health.dohHTTPFailureCount += 1
                health.resolverFailureCounts[attempt.address, default: 0] += 1
            case .backedOff,
                 .sendFailed,
                 .receiveFailed,
                 .invalidAddress,
                 .unsupported,
                 .socketUnavailable,
                 .mismatchedResponse,
                 .deviceDNSUnavailable:
                health.resolverFailureCounts[attempt.address, default: 0] += 1
            }
        }

        health.deviceDNSFallbackModeActive = deviceDNSFallbackModeActive
        markHealthUpdated()
        if activatedDeviceDNSFallback {
            appendNetworkActivity(event: .deviceDNSFallbackActivated(reason: "query-fallback"), now: now)
            scheduleFallbackRecoverySmokeProbeIfNeeded()
        } else if recoveredDeviceDNSFallback {
            appendNetworkActivity(event: .deviceDNSFallbackRecovered, now: now)
        } else if result.deviceDNSFallbackSucceeded {
            scheduleFallbackRecoverySmokeProbeIfNeeded()
        }

        if !didResolve {
            appendReconnectNeededIfPolicyRequiresReconnect(now: now)
        }
        #if LAVA_QA_TOOLS
        logQAConnectivityAssessmentIfNeeded(
            reason: didResolve ? "upstream-success" : "upstream-failure",
            now: now
        )
        #endif

        if activatedDeviceDNSFallback || didResolve {
            scheduleProtectionNotificationIfNeeded(now: now)
        }
    }

    private func updateResolverBackoff(from attempts: [ResolverAttempt], now: Date = Date()) {
        resolverBackoffStateQueue.sync {
            resolverBackoffPolicy.record(
                attempts.map {
                    ResolverBackoffPolicy.Attempt(
                        address: $0.address,
                        outcome: ResolverBackoffPolicy.AttemptOutcome($0.outcome)
                    )
                },
                now: now
            )
        }
    }

    private func markHealthUpdated() {
        health.updatedAt = Date()
        health.networkKind = currentNetworkKind()
        healthPersistence.markDirty()
    }

    private func persistHealthIfNeeded(force: Bool = false) {
        healthPersistence.flush(force: force)
    }

    private func scheduleProtectionNotificationIfNeeded(now: Date = Date()) {
        let defaults = UserDefaults(suiteName: LavaSecAppGroup.identifier) ?? .standard
        let assessment = ProtectionConnectivityPolicy.assessment(
            isConnected: true,
            health: health,
            now: now
        )
        let history = protectionNotificationHistory(defaults: defaults)
        let resolvedNotificationIdentifiers = ProtectionConnectivityNotificationPolicy
            .resolvedProblemNotificationIdentifiers(
                for: assessment,
                health: health,
                history: history,
                now: now
            )
        let notificationCenter = UNUserNotificationCenter.current()
        if !resolvedNotificationIdentifiers.isEmpty {
            Self.clearResolvedProblemNotifications(
                resolvedNotificationIdentifiers,
                defaults: defaults,
                notificationCenter: notificationCenter
            )
        }

        guard let notification = ProtectionConnectivityNotificationPolicy.notification(
            for: assessment,
            health: health,
            history: protectionNotificationHistory(defaults: defaults),
            now: now
        ) else {
            return
        }

        notificationCenter.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                break
            case .notDetermined, .denied:
                return
            @unknown default:
                return
            }

            Self.recordProtectionNotificationDelivery(notification)

            let content = UNMutableNotificationContent()
            content.title = notification.title
            content.body = notification.body
            content.interruptionLevel = .passive
            content.userInfo = [
                LavaSecAppGroup.protectionNotificationRouteUserInfoKey:
                    LavaSecAppGroup.protectionNotificationGuardRouteValue,
                LavaSecAppGroup.protectionNotificationKindUserInfoKey: notification.kind.rawValue,
                LavaSecAppGroup.protectionNotificationIDUserInfoKey: notification.identifier
            ]

            let request = UNNotificationRequest(
                identifier: LavaSecAppGroup.protectionNotificationRequestIdentifier(
                    for: notification.identifier
                ),
                content: content,
                trigger: nil
            )
            notificationCenter.add(request) { error in
                guard error == nil else {
                    return
                }

                Self.removeSupersededProtectionNotifications(
                    for: notification,
                    notificationCenter: notificationCenter
                )
            }
        }
    }

    private func protectionNotificationHistory(
        defaults: UserDefaults
    ) -> ProtectionConnectivityNotificationHistory {
        let unresolvedProblemKind = defaults.string(
            forKey: LavaSecAppGroup.protectionUnresolvedProblemNotificationKindDefaultsKey
        ).flatMap(ProtectionConnectivityNotificationKind.init(rawValue:))

        return ProtectionConnectivityNotificationHistory(
            lastDeliveredNotificationID: defaults.string(
                forKey: LavaSecAppGroup.protectionLastDeliveredNotificationIDDefaultsKey
            ),
            lastDeliveredAt: defaults.object(
                forKey: LavaSecAppGroup.protectionLastDeliveredNotificationAtDefaultsKey
            ) as? Date,
            unresolvedProblemNotificationID: defaults.string(
                forKey: LavaSecAppGroup.protectionUnresolvedProblemNotificationIDDefaultsKey
            ),
            unresolvedProblemKind: unresolvedProblemKind
        )
    }

    private static func recordProtectionNotificationDelivery(_ notification: ProtectionConnectivityNotification) {
        let defaults = UserDefaults(suiteName: LavaSecAppGroup.identifier) ?? .standard

        defaults.set(
            notification.identifier,
            forKey: LavaSecAppGroup.protectionLastDeliveredNotificationIDDefaultsKey
        )
        defaults.set(Date(), forKey: LavaSecAppGroup.protectionLastDeliveredNotificationAtDefaultsKey)

        if notification.kind.isProblem {
            defaults.set(
                notification.identifier,
                forKey: LavaSecAppGroup.protectionUnresolvedProblemNotificationIDDefaultsKey
            )
            defaults.set(
                notification.kind.rawValue,
                forKey: LavaSecAppGroup.protectionUnresolvedProblemNotificationKindDefaultsKey
            )
        } else if notification.kind == .reconnected {
            defaults.removeObject(forKey: LavaSecAppGroup.protectionUnresolvedProblemNotificationIDDefaultsKey)
            defaults.removeObject(forKey: LavaSecAppGroup.protectionUnresolvedProblemNotificationKindDefaultsKey)
        }
    }

    private static func removeSupersededProtectionNotifications(
        for notification: ProtectionConnectivityNotification,
        notificationCenter: UNUserNotificationCenter
    ) {
        let requestIdentifiers = notification.supersededNotificationIdentifiers.map {
            LavaSecAppGroup.protectionNotificationRequestIdentifier(for: $0)
        }
        guard !requestIdentifiers.isEmpty else {
            return
        }

        notificationCenter.removePendingNotificationRequests(withIdentifiers: requestIdentifiers)
        notificationCenter.removeDeliveredNotifications(withIdentifiers: requestIdentifiers)
    }

    private static func clearResolvedProblemNotifications(
        _ identifiers: [String],
        defaults: UserDefaults,
        notificationCenter: UNUserNotificationCenter
    ) {
        defaults.removeObject(forKey: LavaSecAppGroup.protectionUnresolvedProblemNotificationIDDefaultsKey)
        defaults.removeObject(forKey: LavaSecAppGroup.protectionUnresolvedProblemNotificationKindDefaultsKey)

        let requestIdentifiers = identifiers.map {
            LavaSecAppGroup.protectionNotificationRequestIdentifier(for: $0)
        }
        notificationCenter.removePendingNotificationRequests(withIdentifiers: requestIdentifiers)
        notificationCenter.removeDeliveredNotifications(withIdentifiers: requestIdentifiers)
    }

    private func appendNetworkActivity(
        event: NetworkActivityEvent,
        now: Date = Date()
    ) {
        let configuration = currentAppConfiguration()
        guard configuration.keepNetworkActivity else {
            return
        }

        guard let networkActivityLogURL else {
            return
        }

        let assessment = ProtectionConnectivityPolicy.assessment(isConnected: true, health: health, now: now)
        let entry = NetworkActivityLogEntry(
            timestamp: now,
            event: event,
            lavaState: LavaStateSnapshot(
                protectionStatus: "Connected",
                connectivityStatus: assessment.title,
                networkKind: health.networkKind,
                networkPathIsSatisfied: health.networkPathIsSatisfied,
                resolverDisplayName: configuration.resolverPreset.displayName,
                resolverTransport: health.lastResolverTransport,
                fallbackToDeviceDNS: configuration.fallbackToDeviceDNS,
                deviceDNSFallbackActive: deviceDNSFallbackModeActive
            )
        )
        NetworkActivityLogPersistence.append(entry, to: networkActivityLogURL)
    }

    private func appendReconnectNeededIfPolicyRequiresReconnect(now: Date) {
        let assessment = ProtectionConnectivityPolicy.assessment(
            isConnected: true,
            health: health,
            now: now
        )
        guard assessment.primaryAction == .reconnect else {
            return
        }

        if let lastReconnectNeededActivityAt,
           now.timeIntervalSince(lastReconnectNeededActivityAt) < reconnectNeededActivityReminderInterval {
            return
        }

        let reason = health.lastFailureReason ?? "upstream-failed"
        appendNetworkActivity(event: .reconnectNeeded(reason: reason), now: now)
        lastReconnectNeededActivityAt = now
        lastReconnectNeededActivityReason = reason
    }

    private func clearReconnectNeededActivitySuppression() {
        lastReconnectNeededActivityAt = nil
        lastReconnectNeededActivityReason = nil
    }

    #if LAVA_QA_TOOLS
    private func logQAConnectivityAssessmentIfNeeded(reason: String, now: Date) {
        let assessment = ProtectionConnectivityPolicy.assessment(
            isConnected: true,
            health: health,
            now: now
        )
        let severity = assessment.severity
        let isProblem = severity == .needsReconnect
            || severity == .networkUnavailable
            || severity == .usingDeviceDNSFallback
        let didChangeSeverity = severity != lastQAConnectivitySeverity
        let isThrottledProblemReminder = isProblem && now.timeIntervalSince(lastQAConnectivityLogAt) >= 300

        guard didChangeSeverity || isThrottledProblemReminder else {
            return
        }

        lastQAConnectivitySeverity = severity
        lastQAConnectivityLogAt = now

        LavaSecDeviceDebugLog.append(component: "tunnel", event: "qa-connectivity-assessment", details: [
            "reason": reason,
            "severity": String(describing: severity),
            "primaryAction": String(describing: assessment.primaryAction),
            "networkKind": health.networkKind.rawValue,
            "networkPathIsSatisfied": "\(health.networkPathIsSatisfied)",
            "lastFailureReason": health.lastFailureReason ?? "nil",
            "lastResolverTransport": health.lastResolverTransport.rawValue,
            "upstreamSuccessCount": "\(health.upstreamSuccessCount)",
            "upstreamFailureCount": "\(health.upstreamFailureCount)",
            "consecutiveUpstreamFailureCount": "\(health.consecutiveUpstreamFailureCount)",
            "upstreamTimeoutCount": "\(health.upstreamTimeoutCount)",
            "dnsSmokeProbeSuccessCount": "\(health.dnsSmokeProbeSuccessCount)",
            "dnsSmokeProbeFailureCount": "\(health.dnsSmokeProbeFailureCount)",
            "lastDNSSmokeProbeSucceeded": health.lastDNSSmokeProbeSucceeded.map { "\($0)" } ?? "nil",
            "deviceDNSFallbackActivationCount": "\(health.deviceDNSFallbackActivationCount)",
            "deviceDNSFallbackModeActive": "\(deviceDNSFallbackModeActive)",
            "resolverRuntimeResetCount": "\(health.resolverRuntimeResetCount)",
            "lastNetworkChangeAt": Self.qaDebugDateString(health.lastNetworkChangeAt),
            "lastResolverRuntimeResetAt": Self.qaDebugDateString(health.lastResolverRuntimeResetAt),
            "lastUpstreamSuccessAt": Self.qaDebugDateString(health.lastUpstreamSuccessAt),
            "lastUpstreamFailureAt": Self.qaDebugDateString(health.lastUpstreamFailureAt),
            "lastDNSSmokeProbeAt": Self.qaDebugDateString(health.lastDNSSmokeProbeAt)
        ])
    }

    private static func qaDebugDateString(_ date: Date?) -> String {
        guard let date else {
            return "nil"
        }

        return ISO8601DateFormatter().string(from: date)
    }
    #endif

    private func applyDiagnosticsControlIfNeeded(force: Bool = false) {
        guard let diagnosticsControlURL else {
            return
        }

        let modifiedAt = modificationDate(for: diagnosticsControlURL)
        guard force || modifiedAt != lastDiagnosticsControlModifiedAt else {
            return
        }

        lastDiagnosticsControlModifiedAt = modifiedAt
        let control = DiagnosticsControlPersistence.load(from: diagnosticsControlURL)
        var didApplyControl = false

        if let requestedAt = control.clearDomainHistoryRequestedAt,
           lastAppliedDiagnosticsClearAt.map({ requestedAt > $0 }) ?? true {
            diagnostics.clearDomainHistory()
            lastAppliedDiagnosticsClearAt = requestedAt
            didApplyControl = true
        }

        if let requestedAt = control.clearFilteringCountsRequestedAt,
           lastAppliedFilteringCountsClearAt.map({ requestedAt > $0 }) ?? true {
            diagnostics.clearFilteringCounts(startedAt: requestedAt)
            lastAppliedFilteringCountsClearAt = requestedAt
            didApplyControl = true
        }

        if didApplyControl {
            markDiagnosticsUpdated()
        }
    }

    private func markDiagnosticsUpdated() {
        diagnosticsPersistence.markDirty()
    }

    private func persistDiagnosticsIfNeeded(force: Bool = false) {
        diagnosticsPersistence.flush(force: force)
    }

    private func currentNetworkKind() -> TunnelNetworkKind {
        if DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true {
            return networkKind
        }

        return dnsStateQueue.sync {
            networkKind
        }
    }

    private func currentDeviceDNSResolverAddresses() -> [String] {
        if DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true {
            return deviceDNSResolverAddresses
        }

        return dnsStateQueue.sync {
            deviceDNSResolverAddresses
        }
    }

    @discardableResult
    private func setDeviceDNSResolverAddresses(
        _ addresses: [String],
        preserveOnEmptyCapture: Bool = true
    ) -> [String] {
        if DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true {
            deviceDNSResolverAddresses = DeviceDNSFallbackPolicy.refreshedResolverAddresses(
                current: deviceDNSResolverAddresses,
                captured: addresses,
                preserveOnEmptyCapture: preserveOnEmptyCapture
            )
            return deviceDNSResolverAddresses
        }

        return dnsStateQueue.sync {
            deviceDNSResolverAddresses = DeviceDNSFallbackPolicy.refreshedResolverAddresses(
                current: deviceDNSResolverAddresses,
                captured: addresses,
                preserveOnEmptyCapture: preserveOnEmptyCapture
            )
            return deviceDNSResolverAddresses
        }
    }

    private func currentDeviceDNSFallbackModeActive() -> Bool {
        if DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true {
            return deviceDNSFallbackModeActive
        }

        return dnsStateQueue.sync {
            deviceDNSFallbackModeActive
        }
    }

    private func refreshDeviceDNSResolverAddresses(
        reason: String,
        preserveOnEmptyCapture: Bool = true
    ) {
        let addresses = Self.currentSystemDNSServerAddresses()
        let activeAddresses = setDeviceDNSResolverAddresses(
            addresses,
            preserveOnEmptyCapture: preserveOnEmptyCapture
        )

        #if DEBUG
        LavaSecDeviceDebugLog.append(component: "tunnel", event: "device-dns-captured", details: [
            "reason": reason,
            "count": "\(addresses.count)",
            "activeCount": "\(activeAddresses.count)"
        ])
        #endif
    }

    private func refreshDeviceDNSResolverAddressesOnDNSQueue(
        reason: String,
        preserveOnEmptyCapture: Bool = true
    ) {
        let addresses = Self.currentSystemDNSServerAddresses()
        deviceDNSResolverAddresses = DeviceDNSFallbackPolicy.refreshedResolverAddresses(
            current: deviceDNSResolverAddresses,
            captured: addresses,
            preserveOnEmptyCapture: preserveOnEmptyCapture
        )

        #if DEBUG
        LavaSecDeviceDebugLog.append(component: "tunnel", event: "device-dns-captured", details: [
            "reason": reason,
            "count": "\(addresses.count)",
            "activeCount": "\(deviceDNSResolverAddresses.count)"
        ])
        #endif
    }

    private static func currentSystemDNSServerAddresses() -> [String] {
        var buffer = [CChar](repeating: 0, count: deviceDNSCaptureBufferLength)
        let count = buffer.withUnsafeMutableBufferPointer { pointer -> Int32 in
            guard let baseAddress = pointer.baseAddress else {
                return 0
            }

            return LavaSecCopySystemDNSServers(baseAddress, Int32(pointer.count))
        }

        guard count > 0 else {
            return []
        }

        let capturedBytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        let captured = String(decoding: capturedBytes, as: UTF8.self)
        var uniqueAddresses: [String] = []
        var seenAddresses: Set<String> = []

        for address in captured.split(separator: "\n").map(String.init) where isUsableDeviceDNSServer(address) {
            guard seenAddresses.insert(address).inserted else {
                continue
            }

            uniqueAddresses.append(address)
        }

        return uniqueAddresses
    }

    private static func isUsableDeviceDNSServer(_ address: String) -> Bool {
        switch address {
        case tunnelDNSServerAddress, "0.0.0.0", "::", "127.0.0.1", "::1":
            return false
        default:
            return true
        }
    }

    private func currentAppConfiguration() -> AppConfiguration {
        if DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true {
            return appConfiguration
        }

        return dnsStateQueue.sync {
            appConfiguration
        }
    }

    private func setAppConfiguration(_ configuration: AppConfiguration) {
        if DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true {
            appConfiguration = configuration
            return
        }

        dnsStateQueue.sync {
            appConfiguration = configuration
        }
    }

    private static func tunnelNetworkKind(for path: Network.NWPath) -> TunnelNetworkKind {
        if path.usesInterfaceType(.cellular) {
            return .cellular
        }

        if path.usesInterfaceType(.wifi) {
            return .wifi
        }

        if path.usesInterfaceType(.wiredEthernet) {
            return .wired
        }

        return path.status == .satisfied ? .other : .unknown
    }

    private static func pathStatusDescription(_ status: Network.NWPath.Status) -> String {
        switch status {
        case .satisfied:
            "satisfied"
        case .unsatisfied:
            "unsatisfied"
        case .requiresConnection:
            "requires-connection"
        @unknown default:
            "unknown"
        }
    }

    // Runs on dnsStateQueue (the DNS handling path); the elapsed time is
    // measured from setTunnelNetworkSettings success per the plan's
    // "first DNS after tunnel start" latency target.
    private func recordFirstDNSDecisionIfNeeded(_ decision: String) {
        guard !hasRecordedFirstDNSDecision else {
            return
        }

        hasRecordedFirstDNSDecision = true

        #if DEBUG || LAVA_QA_TOOLS
        let elapsedMs = firstDNSDecisionReferenceAt.map { Int((Date().timeIntervalSince($0) * 1_000).rounded()) }
        let trace = Self.makeLatencyTrace(operationID: tunnelStartLatencyOperationID, operationKind: "tunnelStart")
        trace.record("tunnel.firstDNSDecision", details: [
            "decision": decision,
            "elapsedMs": elapsedMs.map(String.init) ?? "unknown"
        ])
        #endif
    }

    // Pause flips deliberately do NOT reset the DNS runtime or reload the
    // snapshot: the policy snapshot stays loaded during pause, pause-era cached
    // answers carry TTLs capped to the pause window, and pending forwards
    // re-check policy at completion. Refreshing pause state and the expiry
    // timer is sufficient (plan F2 / Track 5).
    private func refreshProtectionPauseStateOnly(reason: String) {
        guard DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true else {
            dnsStateQueue.async { [weak self] in
                self?.refreshProtectionPauseStateOnly(reason: reason)
            }
            return
        }

        let pauseUntil = refreshTemporaryProtectionPauseState(synchronizesDefaults: true)
        let pauseIsActive = pauseUntil.map { $0 > Date() } ?? false
        let didChangePauseActivity = pauseIsActive != lastAppliedTemporaryProtectionPauseIsActive
        lastAppliedTemporaryProtectionPauseIsActive = pauseIsActive
        scheduleProtectionPauseResumeIfNeeded(reason: reason)

        #if DEBUG || LAVA_QA_TOOLS
        LavaSecDeviceDebugLog.append(component: "tunnel", event: "pause-state-refreshed", details: [
            "reason": reason,
            "pauseActive": "\(pauseIsActive)",
            "changed": "\(didChangePauseActivity)"
        ])
        #endif
    }

    private func requestSnapshotReload(reason: String, force: Bool = false, operationID: LatencyOperationID? = nil) {
        guard DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true else {
            dnsStateQueue.async { [weak self] in
                self?.requestSnapshotReload(reason: reason, force: force, operationID: operationID)
            }
            return
        }

        let pauseUntil = refreshTemporaryProtectionPauseState(synchronizesDefaults: true)
        let pauseIsActive = pauseUntil.map { $0 > Date() } ?? false
        let didChangePauseActivity = pauseIsActive != lastAppliedTemporaryProtectionPauseIsActive
        lastAppliedTemporaryProtectionPauseIsActive = pauseIsActive
        scheduleProtectionPauseResumeIfNeeded(reason: reason)

        guard force || didChangePauseActivity else {
            #if DEBUG || LAVA_QA_TOOLS
            LavaSecDeviceDebugLog.append(component: "tunnel", event: "snapshot-reload-skipped", details: [
                "reason": reason,
                "pauseActive": "\(pauseIsActive)"
            ])
            #endif
            return
        }

        resetDNSRuntimeForProtectionPolicyChange(reason: reason)
        loadSnapshotInBackground(reason: reason, operationID: operationID)
    }

    private func nextSnapshotReloadGeneration() -> UInt64 {
        guard DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true else {
            return dnsStateQueue.sync {
                nextSnapshotReloadGeneration()
            }
        }

        snapshotReloadGeneration += 1
        return snapshotReloadGeneration
    }

    private func isCurrentSnapshotReloadGeneration(_ generation: UInt64) -> Bool {
        guard DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true else {
            return dnsStateQueue.sync {
                isCurrentSnapshotReloadGeneration(generation)
            }
        }

        return generation == snapshotReloadGeneration
    }

    private func invalidateSnapshotReloadGeneration(reason: String) {
        guard DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true else {
            dnsStateQueue.async { [weak self] in
                self?.invalidateSnapshotReloadGeneration(reason: reason)
            }
            return
        }

        snapshotReloadGeneration += 1

        #if DEBUG || LAVA_QA_TOOLS
        LavaSecDeviceDebugLog.append(component: "tunnel", event: "snapshot-reload-invalidated", details: [
            "reason": reason,
            "generation": "\(snapshotReloadGeneration)"
        ])
        #endif
    }

    private func loadSnapshotInBackground(reason: String, operationID: LatencyOperationID? = nil) {
        let generation = nextSnapshotReloadGeneration()
        #if DEBUG || LAVA_QA_TOOLS
        // Joins the caller's operation (tunnel start or a provider reload) so
        // app action spans and the tunnel's snapshot work share one id.
        let trace = Self.makeLatencyTrace(operationID: operationID, operationKind: "snapshotReload")
        let loadSpan = trace.beginSpan("tunnel.snapshotLoad", details: [
            "reason": reason,
            "generation": "\(generation)"
        ])
        #endif

        Task.detached(priority: .utility) { [weak self] in
            guard let self else {
                #if DEBUG || LAVA_QA_TOOLS
                loadSpan.end(details: ["status": "missing-provider"])
                #endif
                return
            }

            #if DEBUG
            let startedAt = Date()
            LavaSecDeviceDebugLog.append(component: "tunnel", event: "loadSnapshot-begin", details: [
                "generation": "\(generation)",
                "reason": reason
            ])
            #endif

            let configuration = self.loadConfiguration() ?? self.currentAppConfiguration()

            // Pre-decode no-op gate: if the on-disk artifact would reproduce the
            // resident snapshot, skip the multi-megabyte decode entirely. This
            // is the common pull-to-refresh-with-no-content-change case and
            // avoids the 2x-resident memory peak that jetsams the extension on
            // large multi-list snapshots.
            if self.residentSnapshotSatisfiesReload(configuration: configuration) {
                #if DEBUG || LAVA_QA_TOOLS
                LavaSecDeviceDebugLog.append(component: "tunnel", event: "loadSnapshot-reload-noop", details: [
                    "generation": "\(generation)",
                    "reason": reason
                ])
                loadSpan.end(details: ["status": "noop"])
                #endif
                return
            }

            // Backstop for the app's compile-time budget guardrail: never decode
            // an over-budget artifact (it would jetsam the extension). Read the
            // header only, and if it exceeds the rule budget, stay FAIL-CLOSED
            // (block all) rather than crash. The app's guardrail is the primary
            // path and surfaces the actionable message; this catches artifacts
            // written before a budget change or by an older build.
            if let overBudgetRuleCount = self.compactSnapshotRuleCountExceedingBudget() {
                self.replaceSnapshot(
                    FailClosedRuntimeSnapshot(resolver: configuration.resolverPreset),
                    identity: nil
                )
                #if DEBUG || LAVA_QA_TOOLS
                LavaSecDeviceDebugLog.append(component: "tunnel", event: "loadSnapshot-over-budget", details: [
                    "generation": "\(generation)",
                    "reason": reason,
                    "ruleCount": "\(overBudgetRuleCount)",
                    "maxRuleCount": "\(FilterSnapshotMemoryBudget.maxFilterRuleCount)"
                ])
                loadSpan.end(details: ["status": "over-budget"])
                #endif
                self.dnsStateQueue.async { [weak self] in
                    guard let self, self.isCurrentSnapshotReloadGeneration(generation) else {
                        return
                    }
                    self.refreshDNSRuntimeAfterSnapshotOrConfigurationChange()
                }
                return
            }

            // Genuine change replacing a resident snapshot with a new
            // lists-enabled (large) one: free the resident snapshot BEFORE
            // decoding the new one so peak memory is ~1x, not ~2x. Fail-CLOSED
            // (block all) during the brief decode window — never fail-open.
            // Skipped at tunnel start (no resident identity yet) where peak is
            // already 1x.
            if self.currentResidentSnapshotIdentity() != nil,
               !configuration.enabledBlocklistIDs.isEmpty,
               self.isCurrentSnapshotReloadGeneration(generation) {
                self.replaceSnapshot(
                    FailClosedRuntimeSnapshot(resolver: configuration.resolverPreset),
                    identity: nil
                )
                #if DEBUG || LAVA_QA_TOOLS
                LavaSecDeviceDebugLog.append(component: "tunnel", event: "loadSnapshot-failclosed-before-decode", details: [
                    "generation": "\(generation)",
                    "reason": reason
                ])
                #endif
            }

            guard let loaded = await self.loadCompiledSnapshot(configuration: configuration) else {
                guard self.isCurrentSnapshotReloadGeneration(generation) else {
                    #if DEBUG || LAVA_QA_TOOLS
                    LavaSecDeviceDebugLog.append(component: "tunnel", event: "loadSnapshot-skipped-stale-missing", details: [
                        "generation": "\(generation)",
                        "reason": reason
                    ])
                    loadSpan.end(details: ["status": "stale-missing"])
                    #endif
                    return
                }

                if !configuration.enabledBlocklistIDs.isEmpty {
                    let failClosedSnapshot = FailClosedRuntimeSnapshot(resolver: configuration.resolverPreset)
                    self.replaceSnapshot(failClosedSnapshot)
                    self.dnsStateQueue.async { [weak self] in
                        guard let self, self.isCurrentSnapshotReloadGeneration(generation) else {
                            return
                        }

                        self.refreshDNSRuntimeAfterSnapshotOrConfigurationChange()
                    }
                }

                #if DEBUG
                LavaSecDeviceDebugLog.append(component: "tunnel", event: "loadSnapshot-missing", details: [
                    "generation": "\(generation)",
                    "reason": reason
                ])
                #endif
                #if DEBUG || LAVA_QA_TOOLS
                loadSpan.end(details: [
                    "status": configuration.enabledBlocklistIDs.isEmpty ? "missing" : "fail-closed"
                ])
                #endif
                return
            }

            guard self.isCurrentSnapshotReloadGeneration(generation) else {
                #if DEBUG || LAVA_QA_TOOLS
                LavaSecDeviceDebugLog.append(component: "tunnel", event: "loadSnapshot-skipped-stale", details: [
                    "generation": "\(generation)",
                    "reason": reason
                ])
                loadSpan.end(details: ["status": "stale"])
                #endif
                return
            }

            let runtimeSnapshot = ResolverAdjustedRuntimeSnapshot(
                base: loaded.snapshot,
                resolver: configuration.resolverPreset
            )
            let runtimePolicySnapshot = ResolverAdjustedRuntimeSnapshot(
                base: loaded.snapshot,
                resolver: configuration.resolverPreset
            )
            self.dnsStateQueue.sync {
                self.refreshConfigurationIfNeeded(force: true)
            }
            self.replaceSnapshot(
                runtimeSnapshot,
                protectionPolicySnapshot: runtimePolicySnapshot,
                identity: loaded.identity
            )

            #if DEBUG
            let duration = Date().timeIntervalSince(startedAt)
            LavaSecDeviceDebugLog.append(component: "tunnel", event: "loadSnapshot-loaded", details: [
                "generation": "\(generation)",
                "reason": reason,
                "durationMs": "\(Int((duration * 1_000).rounded()))",
                "blockRuleCount": "\(runtimeSnapshot.blockRuleCount)",
                "allowRuleCount": "\(runtimeSnapshot.allowRuleCount)",
                "guardrailRuleCount": "\(runtimeSnapshot.guardrailRuleCount)",
                "footprintMB": Self.currentMemoryFootprintMB(),
                "resolver": configuration.resolverDiagnosticDisplayName
            ])
            #endif
            #if DEBUG || LAVA_QA_TOOLS
            loadSpan.end(details: [
                "status": "loaded",
                "blockRuleCount": "\(runtimeSnapshot.blockRuleCount)",
                "footprintMB": Self.currentMemoryFootprintMB()
            ])
            #endif

            self.dnsStateQueue.async { [weak self] in
                guard let self else {
                    return
                }
                guard self.isCurrentSnapshotReloadGeneration(generation) else {
                    return
                }

                self.refreshDNSRuntimeAfterSnapshotOrConfigurationChange()
                self.refreshConfigurationIfNeeded(force: true)
                self.applyDiagnosticsControlIfNeeded(force: true)
                self.scheduleProtectionPauseResumeIfNeeded(reason: "snapshot-loaded-\(reason)")
                if self.diagnosticsPersistence.isDirty {
                    self.persistDiagnosticsIfNeeded(force: true)
                }
            }
        }
    }

    private func scheduleProtectionPauseResumeIfNeeded(reason: String) {
        guard DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true else {
            dnsStateQueue.async { [weak self] in
                self?.scheduleProtectionPauseResumeIfNeeded(reason: reason)
            }
            return
        }

        cancelProtectionPauseResumeTimer()
        guard let until = currentTemporaryProtectionPauseUntil() else {
            return
        }

        let timer = DispatchSource.makeTimerSource(queue: dnsStateQueue)
        timer.schedule(deadline: .now() + max(0, until.timeIntervalSinceNow))
        timer.setEventHandler { [weak self] in
            self?.resumeExpiredTemporaryProtectionPauseIfNeeded()
        }
        protectionPauseResumeTimer = timer
        timer.resume()
    }

    private func cancelProtectionPauseResumeTimer() {
        guard DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true else {
            dnsStateQueue.async { [weak self] in
                self?.cancelProtectionPauseResumeTimer()
            }
            return
        }

        protectionPauseResumeTimer?.cancel()
        protectionPauseResumeTimer = nil
    }

    private func resumeExpiredTemporaryProtectionPauseIfNeeded() {
        guard DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true else {
            dnsStateQueue.async { [weak self] in
                self?.resumeExpiredTemporaryProtectionPauseIfNeeded()
            }
            return
        }

        guard let until = currentTemporaryProtectionPauseUntil() else {
            cancelProtectionPauseResumeTimer()
            return
        }

        guard Date() >= until else {
            scheduleProtectionPauseResumeIfNeeded(reason: "pause-not-expired")
            return
        }

        protectionPauseResumeTimer = nil
        try? protectionPauseStore.clearStoredPause()
        cacheTemporaryProtectionPauseUntil(nil)
        lastAppliedTemporaryProtectionPauseIsActive = false
        updateLiveActivitiesAfterTemporaryProtectionPauseExpired()
        // No DNS runtime reset or snapshot reload on expiry: the loaded snapshot
        // is identity-unchanged, pause-era cache entries expire with the pause
        // window, and pending forwards re-check policy at completion.
    }

    private func updateLiveActivitiesAfterTemporaryProtectionPauseExpired() {
        Task {
            let defaults = UserDefaults(suiteName: LavaSecAppGroup.identifier) ?? .standard
            let state = LavaActivityAttributes.ContentState(
                protectionState: .on,
                resumeDate: nil,
                pauseRequiresAuthentication: SecurityProtectedSurfaceStorage.isProtected(
                    .protectionPause,
                    defaults: defaults
                ),
                shieldStyle: GuardianShieldStyle(
                    rawValue: defaults.string(forKey: LavaSecAppGroup.customizationLavaGuardLookDefaultsKey) ?? ""
                ) ?? .original
            )
            let content = ActivityContent(state: state, staleDate: nil)
            let activities = Activity<LavaActivityAttributes>.activities

            #if DEBUG || LAVA_QA_TOOLS
            LavaSecDeviceDebugLog.append(component: "tunnel", event: "pause-expired-live-activity-update", details: [
                "count": String(activities.count)
            ])
            #endif

            for activity in activities {
                await activity.update(content)
            }
        }
    }

    private func isTemporaryProtectionPauseActive(
        now: Date = Date(),
        synchronizesDefaults: Bool = true
    ) -> Bool {
        guard let pauseUntil = currentTemporaryProtectionPauseUntil(synchronizesDefaults: synchronizesDefaults) else {
            return false
        }

        return pauseUntil > now
    }

    private func currentTemporaryProtectionPauseUntil(synchronizesDefaults: Bool = true) -> Date? {
        let now = Date()
        if synchronizesDefaults {
            return refreshTemporaryProtectionPauseState(synchronizesDefaults: true, now: now)
        }

        let shouldRefresh = protectionPauseStateQueue.sync {
            now.timeIntervalSince(lastProtectionPauseStateRefreshAt) >= protectionPauseStateRefreshInterval
        }
        if shouldRefresh {
            return refreshTemporaryProtectionPauseState(synchronizesDefaults: true, now: now)
        }

        return protectionPauseStateQueue.sync {
            cachedTemporaryProtectionPauseUntil
        }
    }

    private func refreshTemporaryProtectionPauseState(
        synchronizesDefaults: Bool = true,
        now: Date = Date()
    ) -> Date? {
        let pauseUntil = readTemporaryProtectionPauseUntilFromDefaults(
            synchronizesDefaults: synchronizesDefaults
        )
        cacheTemporaryProtectionPauseUntil(pauseUntil, refreshedAt: now)
        return pauseUntil
    }

    private func cacheTemporaryProtectionPauseUntil(_ pauseUntil: Date?, refreshedAt: Date = Date()) {
        protectionPauseStateQueue.sync {
            cachedTemporaryProtectionPauseUntil = pauseUntil
            lastProtectionPauseStateRefreshAt = refreshedAt
        }
    }

    // synchronizesDefaults now only selects forced-refresh vs cached reads upstream;
    // cfprefsd already serves current app-group values cross-process, and flushing
    // here ran on the DNS hot path up to once per second. The store applies the
    // session binding (pauseSessionID == activeSessionID) and deliberately
    // returns expired pauses so the expiry timer can observe and clear them.
    private func readTemporaryProtectionPauseUntilFromDefaults(synchronizesDefaults: Bool) -> Date? {
        (try? protectionPauseStore.storedPauseState())?.pausedUntil
    }

    private func beginFreshProtectionVPNSession(reason: String) {
        let sessionID = (try? protectionSessionStore.beginFreshSession()) ?? ""
        try? protectionPauseStore.clearStoredPause()
        cacheTemporaryProtectionPauseUntil(nil)

        #if DEBUG || LAVA_QA_TOOLS
        LavaSecDeviceDebugLog.append(component: "tunnel", event: "protection-session-begin", details: [
            "reason": reason,
            "sessionID": sessionID
        ])
        #endif
    }

    private func endProtectionVPNSession(reason: String) {
        _ = try? protectionSessionStore.clearActiveSessionID()
        try? protectionPauseStore.clearStoredPause()
        cacheTemporaryProtectionPauseUntil(nil)

        #if DEBUG || LAVA_QA_TOOLS
        LavaSecDeviceDebugLog.append(component: "tunnel", event: "protection-session-end", details: [
            "reason": reason
        ])
        #endif
    }

    private var protectionPauseDefaults: UserDefaults {
        UserDefaults(suiteName: LavaSecAppGroup.identifier) ?? .standard
    }

    // Single source of truth for session and pause state, shared with the app
    // and the intents process via the same app-group keys.
    private lazy var protectionSessionStore = ProtectionSessionStore(
        storage: ProtectionUserDefaultsStorage(defaults: protectionPauseDefaults),
        lock: ProtectionNSLock()
    )

    private lazy var protectionPauseStore = ProtectionPauseStore(
        storage: ProtectionUserDefaultsStorage(defaults: protectionPauseDefaults),
        lock: ProtectionNSLock()
    )

    private func replaceSnapshot(
        _ newSnapshot: any FilterRuntimeSnapshot,
        protectionPolicySnapshot newProtectionPolicySnapshot: (any FilterRuntimeSnapshot)? = nil,
        identity newIdentity: PreparedFilterSnapshotIdentity? = nil
    ) {
        snapshotQueue.sync {
            snapshot = newSnapshot
            protectionPolicySnapshot = newProtectionPolicySnapshot ?? newSnapshot
            residentSnapshotIdentity = newIdentity
        }
    }

    private func currentResidentSnapshotIdentity() -> PreparedFilterSnapshotIdentity? {
        snapshotQueue.sync { residentSnapshotIdentity }
    }

    // Cheap header-only budget check (no rule-table decode). Returns the total
    // filter-rule count when the on-disk artifact exceeds the on-device memory
    // budget, else nil. Used to refuse decoding an artifact that would jetsam
    // the extension.
    private func compactSnapshotRuleCountExceedingBudget() -> Int? {
        guard let summary = readCompactSnapshotSummary() else {
            return nil
        }

        let totalRuleCount = summary.blockRuleCount + summary.allowRuleCount + summary.guardrailRuleCount
        return FilterSnapshotMemoryBudget.exceedsBudget(ruleCount: totalRuleCount) ? totalRuleCount : nil
    }

    // Reads only the on-disk compact artifact header (no rule-table decode) and
    // returns true when decoding it would reproduce the resident snapshot for
    // the current configuration — i.e. the reload is a no-op and the
    // multi-megabyte decode (and its 2x-resident memory peak) can be skipped.
    private func residentSnapshotSatisfiesReload(configuration: AppConfiguration) -> Bool {
        guard let residentIdentity = currentResidentSnapshotIdentity(),
              let summary = readCompactSnapshotSummary()
        else {
            return false
        }

        return summary.canReuseForProtectionStartup(
            configuration: configuration,
            cachedCatalog: loadCachedCatalogMetadata()
        ) && summary.identity.hasSameSnapshotInputs(as: residentIdentity)
    }

    private func readCompactSnapshotSummary() -> CompactFilterSnapshotSummary? {
        guard let containerURL = LavaSecAppGroup.containerURL else {
            return nil
        }

        let url = containerURL.appendingPathComponent(LavaSecAppGroup.compactSnapshotFilename)
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else {
            return nil
        }

        return try? CompactFilterSnapshot.readSummary(from: data)
    }

    private func replaceSnapshotResolver(_ resolver: DNSResolverPreset) {
        snapshotQueue.sync {
            snapshot = ResolverAdjustedRuntimeSnapshot(base: snapshot, resolver: resolver)
            protectionPolicySnapshot = ResolverAdjustedRuntimeSnapshot(base: protectionPolicySnapshot, resolver: resolver)
        }
    }

    private func refreshDNSRuntimeAfterSnapshotOrConfigurationChange() {
        let resolverIdentifier = currentResolverRuntimeConfiguration().cacheIdentifier
        if let activeResolverRuntimeIdentifier,
           activeResolverRuntimeIdentifier != resolverIdentifier {
            resetResolverRuntimeStateOnDNSQueueIfNeeded(identifier: resolverIdentifier)
            return
        }

        resetDNSRuntimeForProtectionPolicyChange(reason: "snapshot-or-configuration-changed")
    }

    private func resetDNSRuntimeForProtectionPolicyChange(reason: String) {
        guard DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true else {
            dnsStateQueue.async { [weak self] in
                self?.resetDNSRuntimeForProtectionPolicyChange(reason: reason)
            }
            return
        }

        resolverRuntimeGeneration += 1
        let pendingResponses = inFlightQueryCoalescer.drainAll()
        dnsResponseCache.removeAll()
        health.lastResolverRuntimeResetAt = Date()
        health.lastResolverRuntimeResetReason = reason
        health.resolverRuntimeResetCount += 1
        writeServerFailures(for: pendingResponses)
    }

    private func resetResolverRuntimeStateIfNeeded(identifier: String) {
        let pendingResponses = dnsStateQueue.sync {
            collectPendingResponsesAndResetResolverRuntime(
                identifier: identifier,
                reason: "resolver-configuration-changed"
            )
        }

        writeServerFailures(for: pendingResponses)
    }

    private func resetResolverRuntimeStateOnDNSQueueIfNeeded(identifier: String) {
        let pendingResponses = collectPendingResponsesAndResetResolverRuntime(
            identifier: identifier,
            reason: "resolver-configuration-changed"
        )
        writeServerFailures(for: pendingResponses)
    }

    private func resetResolverRuntimeForTunnelLifecycle(reason: String) {
        dnsStateQueue.sync {
            activeResolverRuntimeIdentifier = nil
            resolverRuntimeGeneration += 1
            dnsResponseCache.removeAll()
            _ = inFlightQueryCoalescer.drainAll()
            resolverBackoffStateQueue.sync {
                resolverBackoffPolicy.reset()
            }
        }

        resolverSocketQueue.async { [weak self] in
            self?.resolverSockets = [:]
        }
        dohResolver.resetSession()
        dotResolver.resetConnections()
        doqResolver.resetConnections()
    }

    private func resetResolverTransientState() {
        resolverSocketQueue.async { [weak self] in
            self?.resolverSockets = [:]
        }
        dohResolver.resetSession()
        dotResolver.resetConnections()
        doqResolver.resetConnections()
    }

    private func collectPendingResponsesAndResetResolverRuntime(
        identifier: String,
        reason: String,
        force: Bool = false
    ) -> [PendingDNSResponse] {
        guard force || activeResolverRuntimeIdentifier != identifier else {
            return []
        }

        let isInitialActivation = activeResolverRuntimeIdentifier == nil
        activeResolverRuntimeIdentifier = identifier
        resolverRuntimeGeneration += 1
        let pendingResponses = inFlightQueryCoalescer.drainAll()
        dnsResponseCache.removeAll()
        // The negotiated-protocol observation belongs to the previous
        // resolver/network; the new runtime re-observes before claiming DoH3.
        health.lastDoHHTTPVersion = nil
        resolverBackoffStateQueue.sync {
            resolverBackoffPolicy.reset()
        }
        resetResolverTransientState()
        prewarmResolverBootstrapIfNeeded()
        if force || !isInitialActivation {
            health.lastResolverRuntimeResetAt = Date()
            health.lastResolverRuntimeResetReason = reason
            health.resolverRuntimeResetCount += 1
        }
        return pendingResponses
    }

    private func writeServerFailures(for pendingResponses: [PendingDNSResponse]) {
        for pending in pendingResponses {
            guard let response = DNSResponseFactory.serverFailure(for: pending.request.dnsPayload) else {
                continue
            }

            writeDNSResponse(response, for: pending.request, protocolNumber: pending.protocolNumber)
        }
    }

    private func filterDecision(for domain: String) -> FilterDecision {
        snapshotQueue.sync {
            snapshot.decision(for: domain)
        }
    }

    private func filterDecision(forNormalizedDomain normalizedDomain: String) -> FilterDecision {
        snapshotQueue.sync {
            snapshot.decision(forNormalizedDomain: normalizedDomain)
        }
    }

    private func protectionPolicyDecision(forNormalizedDomain normalizedDomain: String) -> FilterDecision {
        snapshotQueue.sync {
            protectionPolicySnapshot.decision(forNormalizedDomain: normalizedDomain)
        }
    }

    private func temporaryPauseMaximumAnswerTTL(forNormalizedDomain normalizedDomain: String) -> UInt32? {
        let decision = protectionPolicyDecision(forNormalizedDomain: normalizedDomain)
        return decision.action == .block ? pausedWouldBlockForwardTTL : nil
    }

    private func currentResolverPreset() -> DNSResolverPreset {
        snapshotQueue.sync {
            snapshot.resolver
        }
    }

    private func loadConfiguration() -> AppConfiguration? {
        guard let configurationURL,
              let data = try? Data(contentsOf: configurationURL)
        else {
            return nil
        }

        return try? JSONDecoder().decode(AppConfiguration.self, from: data)
    }

    private func loadCompiledSnapshot(
        configuration: AppConfiguration
    ) async -> (snapshot: any FilterRuntimeSnapshot, identity: PreparedFilterSnapshotIdentity)? {
        let cachedCatalog = loadCachedCatalogMetadata()
        let expectedIdentity = PreparedFilterSnapshotIdentity.make(
            configuration: configuration,
            catalog: cachedCatalog
        )

        if let compactSnapshot = loadCompactPreparedSnapshot() {
            if compactSnapshot.canReuseForProtectionStartup(
                configuration: configuration,
                cachedCatalog: cachedCatalog
            ) {
                #if DEBUG
                LavaSecDeviceDebugLog.append(component: "tunnel", event: "loadSnapshot-compact-hit", details: [
                    "identity": compactSnapshot.identity.fingerprint
                ])
                #endif
                return (compactSnapshot, compactSnapshot.identity)
            }

            #if DEBUG
            LavaSecDeviceDebugLog.append(component: "tunnel", event: "loadSnapshot-compact-miss", details: [
                "expected": expectedIdentity.fingerprint,
                "actual": compactSnapshot.identity.fingerprint
            ])
            #endif
        }

        if let preparedSnapshot = loadPreparedSnapshot() {
            if preparedSnapshot.canReuseForProtectionStartup(
                configuration: configuration,
                cachedCatalog: cachedCatalog
            ) {
                #if DEBUG
                LavaSecDeviceDebugLog.append(component: "tunnel", event: "loadSnapshot-prepared-hit", details: [
                    "identity": preparedSnapshot.identity.fingerprint
                ])
                #endif
                return (preparedSnapshot.snapshot, preparedSnapshot.identity)
            }

            #if DEBUG
            LavaSecDeviceDebugLog.append(component: "tunnel", event: "loadSnapshot-prepared-miss", details: [
                "expected": expectedIdentity.fingerprint,
                "actual": preparedSnapshot.identity.fingerprint
            ])
            #endif
        }

        let baseSnapshot = configuration.filterSnapshot()

        guard let catalogCacheURL else {
            return configuration.enabledBlocklistIDs.isEmpty ? (baseSnapshot, expectedIdentity) : nil
        }

        do {
            let compiled = try await CachedFilterSnapshotCompiler(
                cacheDirectoryURL: catalogCacheURL
            ).compile(baseSnapshot: baseSnapshot, configuration: configuration)
            return (compiled, expectedIdentity)
        } catch {
            #if DEBUG
            LavaSecDeviceDebugLog.append(component: "tunnel", event: "loadSnapshot-cache-compile-error", details: Self.errorDebugDetails(error))
            #endif
            return configuration.enabledBlocklistIDs.isEmpty ? (baseSnapshot, expectedIdentity) : nil
        }
    }

    private func loadCompactPreparedSnapshot() -> CompactFilterSnapshot? {
        guard let containerURL = LavaSecAppGroup.containerURL else {
            return nil
        }

        let url = containerURL.appendingPathComponent(LavaSecAppGroup.compactSnapshotFilename)
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else {
            return nil
        }

        return try? CompactFilterSnapshot.decode(from: data)
    }

    private func loadPreparedSnapshot() -> PreparedFilterSnapshot? {
        guard let containerURL = LavaSecAppGroup.containerURL else {
            return nil
        }

        let url = containerURL.appendingPathComponent(LavaSecAppGroup.snapshotFilename)
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }

        return try? JSONDecoder().decode(PreparedFilterSnapshot.self, from: data)
    }

    private func loadCachedCatalogMetadata() -> BlocklistCatalog? {
        guard let catalogCacheURL else {
            return nil
        }

        return try? BlocklistCatalogSynchronizer(
            cacheDirectoryURL: catalogCacheURL
        ).loadCachedCatalogMetadata()
    }

    private var catalogCacheURL: URL? {
        LavaSecAppGroup.containerURL?.appendingPathComponent(
            LavaSecAppGroup.catalogCacheDirectoryName,
            isDirectory: true
        )
    }

    private var configurationURL: URL? {
        LavaSecAppGroup.containerURL?.appendingPathComponent(LavaSecAppGroup.configurationFilename)
    }

    private var diagnosticsURL: URL? {
        LavaSecAppGroup.containerURL?.appendingPathComponent(LavaSecAppGroup.diagnosticsFilename)
    }

    private var networkActivityLogURL: URL? {
        LavaSecAppGroup.containerURL?.appendingPathComponent(LavaSecAppGroup.networkActivityLogFilename)
    }

    private var diagnosticsControlURL: URL? {
        LavaSecAppGroup.containerURL?.appendingPathComponent(LavaSecAppGroup.diagnosticsControlFilename)
    }

    private func modificationDate(for url: URL?) -> Date? {
        guard let url,
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        else {
            return nil
        }

        return attributes[.modificationDate] as? Date
    }
}

private struct IPv4UDPDNSPacket: Sendable {
    let sourceAddress: Data
    let destinationAddress: Data
    let sourcePort: UInt16
    let destinationPort: UInt16
    let identifier: UInt16
    let dnsPayload: Data

    init?(_ packet: Data) {
        guard packet.count >= 28 else {
            return nil
        }

        let version = packet[0] >> 4
        let headerLength = Int(packet[0] & 0x0F) * 4
        guard version == 4, headerLength >= 20, packet.count >= headerLength + 8 else {
            return nil
        }

        let totalLength = Int(Self.readUInt16(packet, at: 2))
        guard totalLength >= headerLength + 8, totalLength <= packet.count else {
            return nil
        }

        let flagsAndFragmentOffset = Self.readUInt16(packet, at: 6)
        let moreFragments = flagsAndFragmentOffset & 0x2000 != 0
        let fragmentOffset = flagsAndFragmentOffset & 0x1FFF
        guard !moreFragments, fragmentOffset == 0 else {
            return nil
        }

        guard packet[9] == UInt8(IPPROTO_UDP) else {
            return nil
        }

        let udpOffset = headerLength
        let udpLength = Int(Self.readUInt16(packet, at: udpOffset + 4))
        guard udpLength >= 8, udpOffset + udpLength <= totalLength else {
            return nil
        }

        let sourcePort = Self.readUInt16(packet, at: udpOffset)
        let destinationPort = Self.readUInt16(packet, at: udpOffset + 2)
        guard destinationPort == 53 else {
            return nil
        }

        let payloadStart = udpOffset + 8
        let payloadEnd = udpOffset + udpLength
        guard payloadEnd > payloadStart else {
            return nil
        }

        self.sourceAddress = Data(packet[12..<16])
        self.destinationAddress = Data(packet[16..<20])
        self.sourcePort = sourcePort
        self.destinationPort = destinationPort
        self.identifier = Self.readUInt16(packet, at: 4)
        self.dnsPayload = Data(packet[payloadStart..<payloadEnd])
    }

    static func response(to request: IPv4UDPDNSPacket, dnsPayload: Data) -> Data? {
        let ipHeaderLength = 20
        let udpHeaderLength = 8
        let totalLength = ipHeaderLength + udpHeaderLength + dnsPayload.count
        guard totalLength <= UInt16.max else {
            return nil
        }

        var packet = Data()
        packet.reserveCapacity(totalLength)

        packet.append(0x45)
        packet.append(0)
        appendUInt16(UInt16(totalLength), to: &packet)
        appendUInt16(request.identifier, to: &packet)
        appendUInt16(0, to: &packet)
        packet.append(64)
        packet.append(UInt8(IPPROTO_UDP))
        appendUInt16(0, to: &packet)
        packet.append(request.destinationAddress)
        packet.append(request.sourceAddress)

        let checksum = ipv4HeaderChecksum(packet)
        packet[10] = UInt8((checksum >> 8) & 0xFF)
        packet[11] = UInt8(checksum & 0xFF)

        appendUInt16(request.destinationPort, to: &packet)
        appendUInt16(request.sourcePort, to: &packet)
        appendUInt16(UInt16(udpHeaderLength + dnsPayload.count), to: &packet)
        appendUInt16(0, to: &packet)
        packet.append(dnsPayload)

        return packet
    }

    private static func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
    }

    private static func appendUInt16(_ value: UInt16, to data: inout Data) {
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }

    private static func ipv4HeaderChecksum(_ packet: Data) -> UInt16 {
        var sum: UInt32 = 0
        var offset = 0

        while offset + 1 < 20 {
            sum += UInt32(readUInt16(packet, at: offset))
            offset += 2
        }

        while sum >> 16 != 0 {
            sum = (sum & 0xFFFF) + (sum >> 16)
        }

        return UInt16(~sum & 0xFFFF)
    }
}

private typealias ResolverRuntimeConfiguration = DNSResolverRuntimePlan

private struct PendingDNSResponse: Sendable {
    let request: IPv4UDPDNSPacket
    let protocolNumber: Int
    let maximumAnswerTTL: UInt32?
    let temporaryPauseNormalizedDomain: String?
}

private struct ResolverEndpoint: Hashable, Sendable {
    let address: String
    let family: Int32

    init?(address: String) {
        var ipv4 = in_addr()
        if inet_pton(AF_INET, address, &ipv4) == 1 {
            self.address = address
            self.family = AF_INET
            return
        }

        var ipv6 = in6_addr()
        if inet_pton(AF_INET6, address, &ipv6) == 1 {
            self.address = address
            self.family = AF_INET6
            return
        }

        return nil
    }

    var socketAddressLength: socklen_t {
        if family == AF_INET6 {
            return socklen_t(MemoryLayout<sockaddr_in6>.size)
        }

        return socklen_t(MemoryLayout<sockaddr_in>.size)
    }
}

private extension ResolverBackoffPolicy.AttemptOutcome {
    init(_ outcome: ResolverAttemptOutcome) {
        switch outcome {
        case .success:
            self = .success
        case .timeout:
            self = .timeout
        case .httpStatusFailure:
            self = .httpStatusFailure
        case .backedOff:
            self = .backedOff
        case .sendFailed:
            self = .sendFailed
        case .receiveFailed:
            self = .receiveFailed
        case .invalidAddress:
            self = .invalidAddress
        case .unsupported:
            self = .unsupported
        case .socketUnavailable:
            self = .socketUnavailable
        case .mismatchedResponse:
            self = .mismatchedResponse
        case .deviceDNSUnavailable:
            self = .deviceDNSUnavailable
        }
    }
}

private struct DNSUpstreamResponse: Sendable {
    let response: Data?
    let outcome: ResolverAttemptOutcome
}

private final class UDPResolverSocket {
    private static let maxMismatchedResponses = 8
    let endpoint: ResolverEndpoint
    private let fileDescriptor: Int32

    init?(endpoint: ResolverEndpoint, timeoutSeconds: Int) {
        let descriptor = socket(endpoint.family, SOCK_DGRAM, IPPROTO_UDP)
        guard descriptor >= 0 else {
            return nil
        }

        guard configureSocketTimeouts(descriptor, receive: true, send: false, timeoutSeconds: timeoutSeconds) else {
            Darwin.close(descriptor)
            return nil
        }

        self.endpoint = endpoint
        self.fileDescriptor = descriptor
    }

    deinit {
        Darwin.close(fileDescriptor)
    }

    func resolve(_ query: Data) -> DNSUpstreamResponse {
        guard DNSWireMessage.transactionID(in: query) != nil else {
            return DNSUpstreamResponse(response: nil, outcome: .receiveFailed)
        }

        let sent = send(query, endpoint: endpoint, fileDescriptor: fileDescriptor)

        guard sent == query.count else {
            return DNSUpstreamResponse(response: nil, outcome: .sendFailed)
        }

        let bufferCapacity = 4096
        var buffer = [UInt8](repeating: 0, count: bufferCapacity)
        var mismatchedResponseCount = 0

        while true {
            var sourceAddress = sockaddr_storage()
            var sourceAddressLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let received = withUnsafeMutablePointer(to: &sourceAddress) { sourcePointer in
                sourcePointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                    buffer.withUnsafeMutableBytes { bufferBytes in
                        recvfrom(
                            fileDescriptor,
                            bufferBytes.baseAddress,
                            bufferCapacity,
                            0,
                            socketAddress,
                            &sourceAddressLength
                        )
                    }
                }
            }

            guard received > 0 else {
                return DNSUpstreamResponse(response: nil, outcome: receiveFailureOutcome())
            }

            guard isExpectedSource(sourceAddress, endpoint: endpoint) else {
                mismatchedResponseCount += 1
                guard mismatchedResponseCount < Self.maxMismatchedResponses else {
                    return DNSUpstreamResponse(response: nil, outcome: .mismatchedResponse)
                }
                continue
            }

            let response = Data(buffer.prefix(received))
            if DNSWireMessage.isValidResponse(response, matching: query) {
                return DNSUpstreamResponse(response: response, outcome: .success)
            }

            mismatchedResponseCount += 1
            guard mismatchedResponseCount < Self.maxMismatchedResponses else {
                return DNSUpstreamResponse(response: nil, outcome: .mismatchedResponse)
            }
        }
    }
}

private enum TCPResolver {
    static func resolve(_ query: Data, endpoint: ResolverEndpoint, timeoutSeconds: Int) -> DNSUpstreamResponse {
        let descriptor = socket(endpoint.family, SOCK_STREAM, IPPROTO_TCP)
        guard descriptor >= 0 else {
            return DNSUpstreamResponse(response: nil, outcome: .socketUnavailable)
        }

        defer {
            Darwin.close(descriptor)
        }

        guard configureSocketTimeouts(descriptor, receive: true, send: true, timeoutSeconds: timeoutSeconds) else {
            return DNSUpstreamResponse(response: nil, outcome: .socketUnavailable)
        }

        guard connect(descriptor, endpoint: endpoint, timeoutSeconds: timeoutSeconds) else {
            return DNSUpstreamResponse(response: nil, outcome: receiveFailureOutcome())
        }

        var framedQuery = Data()
        appendUInt16(UInt16(query.count), to: &framedQuery)
        framedQuery.append(query)

        guard sendAll(framedQuery, fileDescriptor: descriptor) else {
            return DNSUpstreamResponse(response: nil, outcome: .sendFailed)
        }

        guard let lengthData = receiveExact(2, fileDescriptor: descriptor) else {
            return DNSUpstreamResponse(response: nil, outcome: receiveFailureOutcome())
        }

        let responseLength = Int(readUInt16(lengthData, at: 0))
        guard responseLength > 0, let response = receiveExact(responseLength, fileDescriptor: descriptor) else {
            return DNSUpstreamResponse(response: nil, outcome: receiveFailureOutcome())
        }

        guard DNSWireMessage.isValidResponse(response, matching: query) else {
            return DNSUpstreamResponse(response: nil, outcome: .mismatchedResponse)
        }

        return DNSUpstreamResponse(response: response, outcome: .success)
    }

    private static func connect(_ fileDescriptor: Int32, endpoint: ResolverEndpoint, timeoutSeconds: Int) -> Bool {
        let originalFlags = fcntl(fileDescriptor, F_GETFL, 0)
        if originalFlags >= 0 {
            _ = fcntl(fileDescriptor, F_SETFL, originalFlags | O_NONBLOCK)
        }
        defer {
            if originalFlags >= 0 {
                _ = fcntl(fileDescriptor, F_SETFL, originalFlags)
            }
        }

        let result = connectSocket(fileDescriptor, endpoint: endpoint)
        if result == 0 {
            return true
        }

        guard errno == EINPROGRESS else {
            return false
        }

        var descriptor = pollfd(fd: fileDescriptor, events: Int16(POLLOUT), revents: 0)
        let pollResult = poll(&descriptor, 1, Int32(timeoutSeconds * 1_000))
        guard pollResult > 0 else {
            errno = ETIMEDOUT
            return false
        }

        var socketError: Int32 = 0
        var socketErrorLength = socklen_t(MemoryLayout<Int32>.size)
        let optionResult = getsockopt(
            fileDescriptor,
            SOL_SOCKET,
            SO_ERROR,
            &socketError,
            &socketErrorLength
        )
        guard optionResult == 0, socketError == 0 else {
            errno = socketError == 0 ? errno : socketError
            return false
        }

        return true
    }

    private static func connectSocket(_ fileDescriptor: Int32, endpoint: ResolverEndpoint) -> Int32 {
        if endpoint.family == AF_INET6 {
            var address = sockaddr_in6()
            address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            address.sin6_family = sa_family_t(AF_INET6)
            address.sin6_port = in_port_t(53).bigEndian
            guard inet_pton(AF_INET6, endpoint.address, &address.sin6_addr) == 1 else {
                return -1
            }

            return withUnsafePointer(to: &address) { addressPointer in
                addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                    Darwin.connect(fileDescriptor, socketAddress, endpoint.socketAddressLength)
                }
            }
        }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(53).bigEndian
        guard inet_pton(AF_INET, endpoint.address, &address.sin_addr) == 1 else {
            return -1
        }

        return withUnsafePointer(to: &address) { addressPointer in
            addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.connect(fileDescriptor, socketAddress, endpoint.socketAddressLength)
            }
        }
    }

    private static func sendAll(_ data: Data, fileDescriptor: Int32) -> Bool {
        var sentCount = 0
        return data.withUnsafeBytes { rawBytes in
            while sentCount < data.count {
                guard let baseAddress = rawBytes.baseAddress else {
                    return false
                }

                let sent = Darwin.send(
                    fileDescriptor,
                    baseAddress.advanced(by: sentCount),
                    data.count - sentCount,
                    0
                )

                guard sent > 0 else {
                    return false
                }

                sentCount += sent
            }

            return true
        }
    }

    private static func receiveExact(_ byteCount: Int, fileDescriptor: Int32) -> Data? {
        var data = Data(count: byteCount)
        var receivedCount = 0

        while receivedCount < byteCount {
            let received = data.withUnsafeMutableBytes { rawBytes in
                guard let baseAddress = rawBytes.baseAddress else {
                    return 0
                }

                return recv(
                    fileDescriptor,
                    baseAddress.advanced(by: receivedCount),
                    byteCount - receivedCount,
                    0
                )
            }

            guard received > 0 else {
                return nil
            }

            receivedCount += received
        }

        return data
    }

    private static func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
    }

    private static func appendUInt16(_ value: UInt16, to data: inout Data) {
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }
}

private enum DNSMessageTraits {
    static func isTruncated(_ response: Data) -> Bool {
        guard response.count >= 4 else {
            return false
        }

        let flags = (UInt16(response[2]) << 8) | UInt16(response[3])
        return flags & 0x0200 != 0
    }
}

private func isExpectedSource(_ sourceAddress: sockaddr_storage, endpoint: ResolverEndpoint) -> Bool {
    guard Int32(sourceAddress.ss_family) == endpoint.family else {
        return false
    }

    if endpoint.family == AF_INET6 {
        var expectedAddress = in6_addr()
        guard inet_pton(AF_INET6, endpoint.address, &expectedAddress) == 1 else {
            return false
        }

        var mutableSourceAddress = sourceAddress
        return withUnsafePointer(to: &mutableSourceAddress) { sourcePointer in
            sourcePointer.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { ipv6Address in
                guard ipv6Address.pointee.sin6_port == in_port_t(53).bigEndian else {
                    return false
                }

                var actualAddress = ipv6Address.pointee.sin6_addr
                return withUnsafePointer(to: &actualAddress) { actualPointer in
                    withUnsafePointer(to: &expectedAddress) { expectedPointer in
                        memcmp(actualPointer, expectedPointer, MemoryLayout<in6_addr>.size) == 0
                    }
                }
            }
        }
    }

    var expectedAddress = in_addr()
    guard inet_pton(AF_INET, endpoint.address, &expectedAddress) == 1 else {
        return false
    }

    var mutableSourceAddress = sourceAddress
    return withUnsafePointer(to: &mutableSourceAddress) { sourcePointer in
        sourcePointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { ipv4Address in
            ipv4Address.pointee.sin_port == in_port_t(53).bigEndian
                && ipv4Address.pointee.sin_addr.s_addr == expectedAddress.s_addr
        }
    }
}

private func send(_ query: Data, endpoint: ResolverEndpoint, fileDescriptor: Int32) -> Int {
    if endpoint.family == AF_INET6 {
        var address = sockaddr_in6()
        address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_port = in_port_t(53).bigEndian
        guard inet_pton(AF_INET6, endpoint.address, &address.sin6_addr) == 1 else {
            return -1
        }

        return query.withUnsafeBytes { queryBytes in
            withUnsafePointer(to: &address) { addressPointer in
                addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                    sendto(
                        fileDescriptor,
                        queryBytes.baseAddress,
                        query.count,
                        0,
                        socketAddress,
                        endpoint.socketAddressLength
                    )
                }
            }
        }
    }

    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(53).bigEndian
    guard inet_pton(AF_INET, endpoint.address, &address.sin_addr) == 1 else {
        return -1
    }

    return query.withUnsafeBytes { queryBytes in
        withUnsafePointer(to: &address) { addressPointer in
            addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                sendto(
                    fileDescriptor,
                    queryBytes.baseAddress,
                    query.count,
                    0,
                    socketAddress,
                    endpoint.socketAddressLength
                )
            }
        }
    }
}

private func configureSocketTimeouts(
    _ descriptor: Int32,
    receive: Bool,
    send: Bool,
    timeoutSeconds: Int
) -> Bool {
    if receive {
        var receiveTimeout = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
        guard setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &receiveTimeout,
            socklen_t(MemoryLayout<timeval>.size)
        ) == 0 else {
            return false
        }
    }

    if send {
        var sendTimeout = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
        guard setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_SNDTIMEO,
            &sendTimeout,
            socklen_t(MemoryLayout<timeval>.size)
        ) == 0 else {
            return false
        }
    }

    return true
}

private func receiveFailureOutcome() -> ResolverAttemptOutcome {
    switch errno {
    case EAGAIN, EWOULDBLOCK, ETIMEDOUT:
        return .timeout
    default:
        return .receiveFailed
    }
}

private enum DNSResponseFactory {
    static func serverFailure(for query: Data) -> Data? {
        guard let question = try? DNSMessage.parseQuestion(from: query) else {
            return invalidQueryServerFailure(for: query)
        }

        let queryFlags = readUInt16(query, at: 2)
        let recursionDesired = queryFlags & 0x0100
        let questionBytes = query[question.questionRange]

        var response = Data()
        appendUInt16(question.transactionID, to: &response)
        appendUInt16(0x8000 | recursionDesired | 0x0080 | 0x0002, to: &response)
        appendUInt16(1, to: &response)
        appendUInt16(0, to: &response)
        appendUInt16(0, to: &response)
        appendUInt16(0, to: &response)
        response.append(questionBytes)
        return response
    }

    private static func invalidQueryServerFailure(for query: Data) -> Data? {
        guard query.count >= 12 else {
            return nil
        }

        let queryFlags = readUInt16(query, at: 2)
        let recursionDesired = queryFlags & 0x0100

        var response = Data()
        appendUInt16(readUInt16(query, at: 0), to: &response)
        appendUInt16(0x8000 | recursionDesired | 0x0080 | 0x0002, to: &response)
        appendUInt16(0, to: &response)
        appendUInt16(0, to: &response)
        appendUInt16(0, to: &response)
        appendUInt16(0, to: &response)
        return response
    }

    private static func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
    }

    private static func appendUInt16(_ value: UInt16, to data: inout Data) {
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }
}

private enum DNSBootstrapAddressExtractor {
    static func addresses(from response: Data?, matching query: Data, recordType: DNSRecordType) -> [String] {
        guard let response,
              response.count >= 12,
              DNSWireMessage.isValidResponse(response, matching: query)
        else {
            return []
        }

        let questionCount = Int(readUInt16(response, at: 4))
        let answerCount = Int(readUInt16(response, at: 6))
        var cursor = 12

        for _ in 0..<questionCount {
            guard skipName(in: response, cursor: &cursor), cursor + 4 <= response.count else {
                return []
            }
            cursor += 4
        }

        var addresses: [String] = []
        var seenAddresses = Set<String>()
        for _ in 0..<answerCount {
            guard skipName(in: response, cursor: &cursor), cursor + 10 <= response.count else {
                return addresses
            }

            let answerType = readUInt16(response, at: cursor)
            let answerClass = readUInt16(response, at: cursor + 2)
            let dataLength = Int(readUInt16(response, at: cursor + 8))
            cursor += 10

            guard cursor + dataLength <= response.count else {
                return addresses
            }

            defer {
                cursor += dataLength
            }

            guard answerType == recordType.rawValue,
                  answerClass == 1,
                  let address = addressString(from: response[cursor..<(cursor + dataLength)], recordType: recordType),
                  seenAddresses.insert(address).inserted
            else {
                continue
            }

            addresses.append(address)
        }

        return addresses
    }

    private static func addressString(from bytes: Data.SubSequence, recordType: DNSRecordType) -> String? {
        let family: Int32
        let expectedByteCount: Int
        let bufferLength: Int32

        switch recordType {
        case .a:
            family = AF_INET
            expectedByteCount = 4
            bufferLength = INET_ADDRSTRLEN
        case .aaaa:
            family = AF_INET6
            expectedByteCount = 16
            bufferLength = INET6_ADDRSTRLEN
        case .txt, .srv, .svcb, .https, .unknown:
            return nil
        }

        guard bytes.count == expectedByteCount else {
            return nil
        }

        var rawBytes = Array(bytes)
        var buffer = [CChar](repeating: 0, count: Int(bufferLength))
        let converted = rawBytes.withUnsafeMutableBytes { pointer in
            inet_ntop(family, pointer.baseAddress, &buffer, socklen_t(bufferLength))
        }
        guard converted != nil else {
            return nil
        }

        let terminatedLength = buffer.firstIndex(of: 0) ?? buffer.count
        return String(decoding: buffer[..<terminatedLength].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static func skipName(in data: Data, cursor: inout Int) -> Bool {
        var localCursor = cursor
        while localCursor < data.count {
            let length = data[localCursor]
            localCursor += 1

            if length == 0 {
                cursor = localCursor
                return true
            }

            if length & 0xC0 == 0xC0 {
                guard localCursor < data.count else {
                    return false
                }
                let pointer = (Int(length & 0x3F) << 8) | Int(data[localCursor])
                localCursor += 1
                guard isValidCompressedNameTarget(pointer, in: data) else {
                    return false
                }
                cursor = localCursor
                return true
            }

            guard length & 0xC0 == 0, localCursor + Int(length) <= data.count else {
                return false
            }

            localCursor += Int(length)
        }

        return false
    }

    private static func isValidCompressedNameTarget(_ offset: Int, in data: Data) -> Bool {
        guard offset >= 0, offset < data.count else {
            return false
        }

        var cursor = offset
        var visitedOffsets: Set<Int> = []
        while cursor < data.count {
            guard visitedOffsets.insert(cursor).inserted else {
                return false
            }

            let length = data[cursor]
            cursor += 1

            if length == 0 {
                return true
            }

            if length & 0xC0 == 0xC0 {
                guard cursor < data.count else {
                    return false
                }
                let pointer = (Int(length & 0x3F) << 8) | Int(data[cursor])
                guard pointer >= 0, pointer < data.count else {
                    return false
                }
                cursor = pointer
                continue
            }

            guard length & 0xC0 == 0, cursor + Int(length) <= data.count else {
                return false
            }

            cursor += Int(length)
        }

        return false
    }

    private static func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
    }
}

private enum DNSBootstrapResponseFactory {
    static func response(
        for query: Data,
        question: DNSQuestion,
        endpoint: DNSOverHTTPSEndpoint,
        ttl: UInt32 = 60
    ) -> Data? {
        response(
            for: query,
            question: question,
            ipv4Servers: endpoint.bootstrapIPv4Servers,
            ipv6Servers: endpoint.bootstrapIPv6Servers,
            ttl: ttl
        )
    }

    static func response(
        for query: Data,
        question: DNSQuestion,
        endpoint: DNSOverQUICEndpoint,
        ttl: UInt32 = 60
    ) -> Data? {
        response(
            for: query,
            question: question,
            ipv4Servers: endpoint.bootstrapIPv4Servers,
            ipv6Servers: endpoint.bootstrapIPv6Servers,
            ttl: ttl
        )
    }

    private static func response(
        for query: Data,
        question: DNSQuestion,
        ipv4Servers: [String],
        ipv6Servers: [String],
        ttl: UInt32
    ) -> Data? {
        let answerAddresses: [Data]
        switch question.recordType {
        case .a:
            answerAddresses = ipv4Servers.compactMap {
                addressData($0, family: AF_INET, byteCount: 4)
            }
        case .aaaa:
            answerAddresses = ipv6Servers.compactMap {
                addressData($0, family: AF_INET6, byteCount: 16)
            }
        case .txt, .srv, .svcb, .https, .unknown:
            answerAddresses = []
        }

        let queryFlags = readUInt16(query, at: 2)
        let recursionDesired = queryFlags & 0x0100
        let questionBytes = query[question.questionRange]

        var response = Data()
        appendUInt16(question.transactionID, to: &response)
        appendUInt16(0x8000 | recursionDesired | 0x0080, to: &response)
        appendUInt16(1, to: &response)
        appendUInt16(UInt16(answerAddresses.count), to: &response)
        appendUInt16(0, to: &response)
        appendUInt16(0, to: &response)
        response.append(questionBytes)

        for answerAddress in answerAddresses {
            response.append(contentsOf: [0xC0, 0x0C])
            appendUInt16(question.rawRecordType, to: &response)
            appendUInt16(1, to: &response)
            appendUInt32(ttl, to: &response)
            appendUInt16(UInt16(answerAddress.count), to: &response)
            response.append(answerAddress)
        }

        return response
    }

    private static func addressData(_ address: String, family: Int32, byteCount: Int) -> Data? {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let result = bytes.withUnsafeMutableBytes { rawBytes in
            inet_pton(family, address, rawBytes.baseAddress)
        }

        guard result == 1 else {
            return nil
        }

        return Data(bytes)
    }

    private static func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
    }

    private static func appendUInt16(_ value: UInt16, to data: inout Data) {
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8((value >> 24) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }
}

private final class SendableCompletion: @unchecked Sendable {
    private let handler: (Error?) -> Void

    init(_ handler: @escaping (Error?) -> Void) {
        self.handler = handler
    }

    func callAsFunction(_ error: Error?) {
        handler(error)
    }
}

/// `SettleWorkScheduling` backed by a one-shot `DispatchSourceTimer` on the
/// tunnel's `dnsStateQueue`, mirroring the existing `protectionPauseResumeTimer`
/// idiom. Used by the resolver-probe coalescer (plan item 430).
private final class DispatchSettleWorkScheduler: SettleWorkScheduling {
    private let queue: DispatchQueue

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    func schedule(after interval: TimeInterval, _ work: @escaping () -> Void) -> SettleWorkToken {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval)
        timer.setEventHandler {
            work()
        }
        timer.resume()
        return DispatchSettleWorkToken(timer: timer)
    }
}

private final class DispatchSettleWorkToken: SettleWorkToken {
    private let timer: DispatchSourceTimer
    private var isCancelled = false

    init(timer: DispatchSourceTimer) {
        self.timer = timer
    }

    func cancel() {
        guard !isCancelled else {
            return
        }
        isCancelled = true
        timer.cancel()
    }
}
