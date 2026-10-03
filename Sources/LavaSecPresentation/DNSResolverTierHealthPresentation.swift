import Foundation
import LavaSecKit

/// Presents observed DNS tiers without assigning health or authorizing a repair.
public enum DNSResolverTierHealthPresentation {
    /// A stable diagnostic row independent of localized display text.
    public struct Row: Equatable, Sendable {
        /// The stable row identity within its tier.
        public let id: String
        /// The localizable row title.
        public let title: String
        /// The observed value or localizable state label.
        public let value: String
    }

    /// An ordered diagnostic section for one canonical tier.
    public struct Section: Equatable, Sendable {
        /// The stable section identity, including the canonical tier.
        public let id: String
        /// The section's canonical tier label.
        public let title: String
        /// Privacy-safe evidence and counters from that tier's running selection.
        public let rows: [Row]
    }

    /// Creates one section per tier from the running session's independent observations.
    /// Saved configuration is displayed separately; an old sample cannot claim current health.
    public static func sections(
        health: TunnelHealthSnapshot,
        isConnected: Bool,
        now: Date = Date()
    ) -> [Section] {
        let sampleAge = now.timeIntervalSince(health.updatedAt)
        let isCurrentSample = isConnected && sampleAge >= 0 && sampleAge <= 90
        return DNSResolverTier.allCases.map { tier in
            let title: String
            switch tier {
            case .tierZero: title = "T0 · VPN DNS health"
            case .tierOne: title = "T1 · Primary DNS health"
            case .tierTwo: title = "T2 · Fallback DNS health"
            }
            let snapshot = health.dnsTierHealth.first { $0.tier == tier }
            let isCurrentTierObservation = snapshot?.lastObservedAt.map { observedAt in
                (0...90).contains(now.timeIntervalSince(observedAt))
                    && observedAt >= health.startedAt && observedAt <= health.updatedAt
            } ?? false
            let isActiveTierSample = isCurrentSample && isCurrentTierObservation
                && (tier != .tierZero || health.isChainedUpstreamActive)
            var rows: [Row] = []
            func add(_ id: String, _ title: String, _ value: String) {
                rows.append(Row(id: id, title: title, value: value))
            }
            let observation: String
            if !isConnected {
                observation = "Not connected"
            } else if tier == .tierZero && !health.isChainedUpstreamActive {
                observation = "Not active"
            } else if !isCurrentSample || (snapshot?.lastOutcome != nil && !isCurrentTierObservation) {
                observation = "Sample out of date"
            } else if let outcome = snapshot?.lastOutcome {
                observation = observationLabel(outcome)
            } else {
                observation = "No observations yet"
            }
            add("observation", "Latest observation", observation)
            guard let snapshot else {
                return Section(id: "dns-health-\(tier.rawValue)", title: title, rows: rows)
            }
            if let kind = snapshot.resolverKind {
                add("source", "Resolver source", sourceLabel(kind))
            }
            if let transport = snapshot.transport {
                add("transport", "Transport", transport.displayName)
            }
            if let egress = snapshot.egress {
                add("egress", "DNS route", egressLabel(egress))
            }
            add("attempts", "Attempts", String(snapshot.attemptCount))
            add("served", "Served", String(snapshot.servedCount))
            add("answered", "Replies without service", String(snapshot.answeredCount))
            add("failures", "Failures", String(snapshot.failureCount))
            add("skipped", "Not attempted", String(snapshot.notAttemptedCount))
            add("failure-streak", "Failure streak", String(snapshot.consecutiveFailureCount))
            add("rejected-streak", "Rejected reply streak", String(snapshot.consecutiveRejectedResponseCount))
            add("recovery", "Recovery", isActiveTierSample
                ? recoveryLabel(kind: snapshot.recoveryKind, status: snapshot.recoveryStatus)
                : "Status unavailable")
            if let reason = snapshot.lastFailureReason {
                add("last-failure", "Last failure", reason)
            }
            return Section(id: "dns-health-\(tier.rawValue)", title: title, rows: rows)
        }
    }

    /// Describes repair admission using the resolver's actual recovery capability.
    public static func recoveryLabel(
        kind: DNSResolverTierHealthSnapshot.RecoveryKind,
        status: DNSResolverTierHealthSnapshot.RecoveryStatus
    ) -> String {
        switch status {
        case .notNeeded: return "Not needed"
        case .waiting:
            return kind == .recaptureDeviceDNS ? "Checking Device DNS" : "Waiting for recovery"
        case .throttled:
            return kind == .recaptureDeviceDNS ? "Reconnect deferred" : "Recovery deferred"
        case .unavailable: return "Recovery unavailable"
        case .eligible, .retrying, .upstreamWaiting, .restarting:
            switch kind {
            case .upstreamSession: return "Upstream session recovery"
            case .retryFixedEndpoint: return status == .eligible ? "Resolver retry eligible" : "Retrying resolver"
            case .recaptureDeviceDNS:
                return status == .restarting ? "Reconnecting for Device DNS" : "Device DNS reconnect eligible"
            case .none: return "No repair requested"
            }
        }
    }

    private static func observationLabel(_ outcome: DNSResolverTierHealthSnapshot.Outcome) -> String {
        switch outcome {
        case .served: return "Served"
        case .answered: return "Replied without service"
        case .failure: return "Failed"
        case .notAttempted: return "Not attempted"
        }
    }

    private static func sourceLabel(_ kind: DNSResolverTierHealthSnapshot.ResolverKind) -> String {
        switch kind {
        case .upstream: return "VPN DNS"
        case .device: return "Device DNS"
        case .fixed: return "Selected resolver"
        }
    }

    private static func egressLabel(_ egress: DNSResolverTierHealthSnapshot.Egress) -> String {
        switch egress {
        case .tunnel: return "VPN"
        case .physical: return "Physical network"
        case .mixed: return "Mixed routes"
        }
    }
}
