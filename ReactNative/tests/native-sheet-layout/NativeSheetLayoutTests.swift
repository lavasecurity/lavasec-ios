import SwiftUI
import UIKit

/// Test-only app. UIKit probes read actual rendered frames, independently of
/// SwiftUI's accessibility child union. Every production layout is extracted
/// verbatim; this file supplies only hosts, measurement and assertions.
@main
@MainActor
final class NativeSheetLayoutTests: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    private var checks = 0
    private var failures: [String] = []
    private var measurements: [[String: Any]] = []

    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        self.window = window
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        Task { await run() }
        return true
    }

    private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !condition() { failures.append(message) }
    }

    private func run() async {
        guard let window, let parent = window.rootViewController else { fatalError("Missing host") }
        let cases: [(String, DynamicTypeSize)] = [("standard", .large), ("accessibility3", .accessibility3)]
        for width: CGFloat in [320, 393, 768] {
            for (typeName, typeSize) in cases {
                let recorder = FrameRecorder()
                let content = LayoutFixture(recorder: recorder)
                    .environment(\.dynamicTypeSize, typeSize)
                let host = UIHostingController(rootView: content)
                host.safeAreaRegions = []
                parent.addChild(host)
                // A deliberately offset host proves measurements do not assume
                // screen origin, status-bar height or the current sheet detent.
                host.view.frame = CGRect(x: 23, y: 91, width: width, height: 1600)
                parent.view.addSubview(host.view)
                host.didMove(toParent: parent)

                var previous: [String: CGRect] = [:]
                var stable = 0
                for _ in 0..<100 {
                    host.view.setNeedsLayout()
                    host.view.layoutIfNeeded()
                    recorder.views.forEach { $0.record() }
                    let frames = recorder.frames
                    if frames.count == 5 && frames.values.allSatisfy({ !$0.isEmpty && !$0.isInfinite }) {
                        stable = frames == previous ? stable + 1 : 0
                        if stable >= 3 { break }
                    }
                    previous = frames
                    try? await Task.sleep(for: .milliseconds(20))
                }
                let context = "width=\(width), type=\(typeName)"
                expect(stable >= 3, "\(context): actual layout must settle")
                if let header = recorder.frames["header"], let leading = recorder.frames["leading"],
                   let trailing = recorder.frames["trailing"], let vpn = recorder.frames["vpn"],
                   let notifications = recorder.frames["notifications"] {
                    let top = leading.minY - header.minY
                    let left = leading.minX - header.minX
                    let row: [String: Any] = ["width": width, "textSize": typeName,
                        "header": NSCoder.string(for: header), "leading": NSCoder.string(for: leading),
                        "trailing": NSCoder.string(for: trailing), "vpn": NSCoder.string(for: vpn),
                        "notifications": NSCoder.string(for: notifications), "topInset": top, "leftInset": left]
                    measurements.append(row)
                    expect(abs(header.minX - 23) < 0.5 && abs(header.minY - 91) < 0.5,
                           "\(context): measurement must use the offset UIKit host")
                    expect(abs(header.width - width) < 0.5, "\(context): header fills its actual host width")
                    expect(abs(top - 18) < 0.5, "\(context): actual top inset is18, got\(top)")
                    expect(abs(left - 18) < 0.5, "\(context): actual leading inset is18, got\(left)")
                    expect(abs(top - left) < 0.5, "\(context): top and leading insets match")
                    expect(abs(leading.width - 44) < 0.5 && abs(leading.height - 44) < 0.5,
                           "\(context): actual leading circular button is44×44")
                    expect(abs(trailing.width - 44) < 0.5 && abs(trailing.height - 44) < 0.5,
                           "\(context): actual native trailing button is44×44")
                    expect(abs(trailing.minY - header.minY - 18) < 0.5,
                           "\(context): multiline title cannot move the trailing control")
                    expect(header.contains(leading) && header.contains(trailing), "\(context): controls stay inside header")
                    expect(abs(vpn.width - notifications.width) < 0.5, "\(context): permission card widths match")
                    expect(abs(vpn.height - notifications.height) < 0.5,
                           "\(context): permission card heights match: VPN\(vpn.height), notifications\(notifications.height)")
                    expect(vpn.width > 0 && vpn.height > 0, "\(context): decorative cards have real nonzero layout")
                } else {
                    expect(false, "\(context): missing actual frame probes: \(recorder.frames)")
                }
                host.willMove(toParent: nil)
                host.view.removeFromSuperview()
                host.removeFromParent()
            }
        }
        let report: [String: Any] = ["passed": failures.isEmpty, "checks": checks,
            "failures": failures, "measurements": measurements]
        let data = try! JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        let path = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("results.json")
        try! data.write(to: path)
        print(String(data: data, encoding: .utf8)!)
        exit(failures.isEmpty ? 0 : 1)
    }
}

@MainActor
private struct LayoutFixture: View {
    let recorder: FrameRecorder
    var body: some View {
        VStack(spacing: 24) {
            LavaFullSheetHeader(title: "Review these connection choices before continuing") {
                LavaToolbarIconButton(systemName: "chevron.left", accessibilityLabel: "Back", action: {})
                    .background(FrameProbe(name: "leading", recorder: recorder))
            } trailing: {
                NativeToolbarIconButton(systemName: "xmark", accessibilityLabel: "Close", role: .close, action: {})
                    .background(FrameProbe(name: "trailing", recorder: recorder))
            }
            .background(FrameProbe(name: "header", recorder: recorder))
            LavaSetupPermissionIllustration(kind: .localProtection)
                .background(FrameProbe(name: "vpn", recorder: recorder))
            LavaSetupPermissionIllustration(kind: .notifications)
                .background(FrameProbe(name: "notifications", recorder: recorder))
            Spacer(minLength: 0)
        }
    }
}

@MainActor
private final class FrameRecorder {
    var frames: [String: CGRect] = [:]
    var views: [ProbeView] = []
}

private struct FrameProbe: UIViewRepresentable {
    let name: String
    let recorder: FrameRecorder
    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView(name: name, recorder: recorder)
        recorder.views.append(view)
        return view
    }
    func updateUIView(_ uiView: ProbeView, context: Context) { uiView.record() }
}

@MainActor
private final class ProbeView: UIView {
    let name: String
    weak var recorder: FrameRecorder?
    init(name: String, recorder: FrameRecorder) {
        self.name = name
        self.recorder = recorder
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
    }
    required init?(coder: NSCoder) { fatalError("Not used") }
    override func layoutSubviews() { super.layoutSubviews(); record() }
    override func didMoveToWindow() { super.didMoveToWindow(); record() }
    func record() {
        guard let window else { return }
        recorder?.frames[name] = convert(bounds, to: window)
    }
}
