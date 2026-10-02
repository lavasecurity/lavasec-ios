import Foundation
import LavaSecAppServices

@MainActor
@objc(LavaAppearanceBridge)
final class AppearanceBridge: NSObject {
    @objc static let shared = AppearanceBridge()
    let service = AppearancePreferencesService(defaults: .standard)
    @objc func snapshot() -> NSDictionary { dictionary(service.refresh()) }
    @objc func setPreference(_ raw: String) -> NSDictionary? {
        guard let preference = LavaAppearancePreference(rawValue: raw) else { return nil }
        // Actual authorization happens in the live app command adapter. The full
        // app never calls this fixture convenience setter.
        guard !LavaProtectionShortcutRuntime.shared.security.isProtected(.appSettings) else { return nil }
        LavaProtectionShortcutRuntime.shared.viewModel.customization.setAppearancePreference(preference)
        return dictionary(service.refresh())
    }
    @objc func observe(_ callback: @escaping (NSDictionary) -> Void) -> String {
        service.observe { [weak self] value in guard let self else { return }; callback(dictionary(value)) }.uuidString
    }
    @objc func removeObserver(_ token: String) { if let id = UUID(uuidString: token) { service.removeObserver(id) } }
    private func dictionary(_ value: AppearancePreferencesSnapshot) -> NSDictionary {
        ["preference": value.preference.rawValue, "revision": value.revision]
    }
}
