import Foundation
import Darwin
import OSLog
import LavaSecAppServices

/// One app-owned service survives individual React runtimes. A dedicated suite
/// preserves native QA preferences when TestFlight swaps the app implementation.
@MainActor
@objc(LavaAppearanceBridge)
final class AppearanceBridge: NSObject {
    @objc static let shared = AppearanceBridge()
    let service = AppearancePreferencesService(
        defaults: UserDefaults(suiteName: "com.lavasecurity.lavasec.ui-review.appearance")!
    )

    @objc func snapshot() -> NSDictionary {
        ReviewMetrics.recordFirstJSQuery()
        return dictionary(service.refresh())
    }

    @objc func setPreference(_ rawValue: String) -> NSDictionary? {
        guard let preference = AppearancePreference(rawValue: rawValue) else { return nil }
        return dictionary(service.setPreference(preference))
    }

    @objc func observe(_ callback: @escaping (NSDictionary) -> Void) -> String {
        service.observe { [weak self] snapshot in
            guard let self else { return }
            callback(dictionary(snapshot))
        }.uuidString
    }

    @objc func removeObserver(_ token: String) {
        guard let id = UUID(uuidString: token) else { return }
        service.removeObserver(id)
    }

    private func dictionary(_ snapshot: AppearancePreferencesSnapshot) -> NSDictionary {
        ["preference": snapshot.preference.rawValue, "revision": snapshot.revision]
    }
}

/// Review evidence only: this measures a simulator/debug runtime, not device performance.
@MainActor
enum ReviewMetrics {
    private static let log = Logger(subsystem: "com.lavasecurity.lavasec.ui-review", category: "runtime")
    private static var openedAt: TimeInterval?
    private static var nativeFootprint: UInt64 = 0

    static func beginOpening() {
        nativeFootprint = footprint()
        openedAt = ProcessInfo.processInfo.systemUptime
    }

    static func recordFirstJSQuery() {
        guard let openedAt else { return }
        self.openedAt = nil
        let milliseconds = (ProcessInfo.processInfo.systemUptime - openedAt) * 1_000
        let current = footprint()
        log.notice("JS service ready: duration_ms=\(milliseconds, privacy: .public), native_bytes=\(nativeFootprint, privacy: .public), current_bytes=\(current, privacy: .public)")
    }

    private static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }
}
