import Foundation
@preconcurrency import NetworkExtension

/// Asks the running tunnel to resolve ONE hostname, for the single case where the app cannot
/// resolve it itself.
///
/// THE DEADLOCK THIS BREAKS. When the tunnel has no adoptable filter artifact it installs
/// `FailClosedRuntimeSnapshot` and answers every query with the block-all address. The app's
/// repair path — download the blocklist sources and publish a new artifact — has to resolve
/// those sources, `getaddrinfo` returns the tunnel's own `0.0.0.0`, and the fetch fails. The
/// repair needs the DNS it is repairing, so the outage never ends on its own: observed on
/// device (S9) as a total DNS outage whose only exit was toggling protection off and on.
///
/// The tunnel is not stuck the same way — it still reaches the device resolvers, because it is
/// what forwards to them. So it answers this one question directly.
///
/// 🔴 WHY THIS IS NOT "FAIL OPEN" (INV-DNS-1). The invariant governs what the tunnel SERVES.
/// Nothing here changes a served answer:
///  - `FailClosedRuntimeSnapshot` is untouched; every client still gets block-all, including
///    for this very hostname.
///  - The addresses return over the provider-message channel to this process only. They are
///    never encoded into a DNS response, never written to the utun, never counted as a served
///    query, and recorded in no Domain History entry.
///  - The caller re-classifies every returned address through the same public-scope gate it
///    applies to any resolved host, so a confused or hostile reply cannot widen what the app
///    will connect to — it can only fail to help.
///  - The tunnel admits the request only while it is actually fail-closed, and caps the number
///    of distinct hostnames per window.
enum BootstrapHostResolveBroker {
    /// Resolved addresses for `hostname`, or `nil` when the tunnel declined or is unreachable.
    ///
    /// `nil` is the ordinary outcome outside a fail-closed window and the caller must treat it
    /// as "no help available", never as "the host does not exist".
    static func resolve(
        hostname: String,
        session: NETunnelProviderSession
    ) async -> LavaSecBootstrapHostResolution? {
        let payload = [LavaSecAppGroup.resolveBootstrapHostnameKey: hostname]
        let messageData = LavaSecProviderMessageCodec.encode(
            kind: LavaSecAppGroup.resolveBootstrapHostMessage,
            operationID: nil,
            payload: payload)

        return await withCheckedContinuation { continuation in
            // `sendProviderMessage` invokes its reply handler exactly once on success and not
            // at all if it throws, so the throw is resumed here rather than left to leak the
            // continuation.
            let box = ContinuationBox(continuation)
            do {
                try session.sendProviderMessage(messageData) { reply in
                    box.resume(with: LavaSecBootstrapHostResolution.decode(reply))
                }
            } catch {
                box.resume(with: nil)
            }
        }
    }

    /// Guards the one-resume rule across the throw path and the reply path.
    private final class ContinuationBox: @unchecked Sendable {
        private var continuation: CheckedContinuation<LavaSecBootstrapHostResolution?, Never>?
        private let lock = NSLock()

        init(_ continuation: CheckedContinuation<LavaSecBootstrapHostResolution?, Never>) {
            self.continuation = continuation
        }

        func resume(with value: LavaSecBootstrapHostResolution?) {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(returning: value)
        }
    }
}
