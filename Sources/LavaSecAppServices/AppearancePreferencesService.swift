import Foundation

/// Platform-neutral appearance choices persisted by the native application.
public enum AppearancePreference: String, CaseIterable, Sendable {
    /// Force the platform's light appearance.
    case light
    /// Force the platform's dark appearance.
    case dark
    /// Follow the system appearance.
    case system
}

/// A coherent native preference value and its in-process observation revision.
public struct AppearancePreferencesSnapshot: Equatable, Sendable {
    /// The confirmed native appearance choice.
    public let preference: AppearancePreference
    /// Monotonically increases within one service lifetime; it is not persisted.
    public let revision: Int
}

/// Owns appearance preference persistence independently of any screen or UI runtime.
/// Consumers reconnect by reading authority; they never replay a mutation to recover state.
@MainActor
public final class AppearancePreferencesService {
    private static let defaultsKey = "lavasec.customization.appearance"
    private let defaults: UserDefaults
    private var observers: [UUID: (AppearancePreferencesSnapshot) -> Void] = [:]

    /// The latest confirmed value for this native service lifetime.
    public private(set) var snapshot: AppearancePreferencesSnapshot

    /// Reads the existing preference key without migrating or writing launch-time data.
    public init(defaults: UserDefaults) {
        self.defaults = defaults
        snapshot = AppearancePreferencesSnapshot(preference: Self.read(defaults), revision: 0)
    }

    /// Persists a native command and returns its confirmed snapshot. Repeated values are idempotent.
    @discardableResult
    public func setPreference(_ preference: AppearancePreference) -> AppearancePreferencesSnapshot {
        defaults.set(preference.rawValue, forKey: Self.defaultsKey)
        return publish(preference)
    }

    /// Reconciles foreground/reconnection state with the native store without replaying commands.
    @discardableResult
    public func refresh() -> AppearancePreferencesSnapshot {
        publish(Self.read(defaults))
    }

    /// Registers before delivering the initial snapshot so attachment has no read/subscribe gap.
    public func observe(_ observer: @escaping (AppearancePreferencesSnapshot) -> Void) -> UUID {
        let token = UUID()
        observers[token] = observer
        observer(snapshot)
        return token
    }

    /// Ends one subscription; accepted commands and other native consumers remain alive.
    public func removeObserver(_ token: UUID) {
        observers.removeValue(forKey: token)
    }

    private static func read(_ defaults: UserDefaults) -> AppearancePreference {
        defaults.string(forKey: defaultsKey).flatMap(AppearancePreference.init(rawValue:)) ?? .system
    }

    private func publish(_ preference: AppearancePreference) -> AppearancePreferencesSnapshot {
        guard preference != snapshot.preference else { return snapshot }
        snapshot = AppearancePreferencesSnapshot(preference: preference, revision: snapshot.revision + 1)
        let published = snapshot
        for callback in Array(observers.values) { callback(published) }
        return published
    }
}
