import Foundation

/// Observes a Darwin (cross-process) notification by name and invokes `handler`
/// when it fires. App-only by design: the NE extension's run loop is dormant so
/// it cannot rely on Darwin observers (it uses provider messages), but the
/// foreground app receives them reliably — the correct channel for the
/// tunnel→app "health changed" nudge (UR-6).
///
/// The C callback cannot capture context, so the instance is round-tripped
/// through the observer pointer. `handler` is invoked on the Darwin notify
/// center's delivery thread; callers that need main-actor work should hop
/// themselves (the tunnel-health observer wraps its body in a main-actor task).
final class DarwinNotificationObserver {
    private let name: CFString
    private let handler: () -> Void

    init(name: String, handler: @escaping () -> Void) {
        self.name = name as CFString
        self.handler = handler

        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            observer,
            { _, observer, _, _, _ in
                guard let observer else {
                    return
                }
                Unmanaged<DarwinNotificationObserver>
                    .fromOpaque(observer)
                    .takeUnretainedValue()
                    .handler()
            },
            name as CFString,
            nil,
            .deliverImmediately
        )
    }

    deinit {
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            CFNotificationName(name),
            nil
        )
    }
}
