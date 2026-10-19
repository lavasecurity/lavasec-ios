import SwiftUI
import UIKit

/// A generic system control leaf. React owns its intent and action admission;
/// SwiftUI preserves the platform's bordered button paint and intrinsic metrics.
@objc(LavaSystemButtonContent)
@MainActor
final class LavaSystemButtonContent: UIView {
    @objc var onPress: ((String) -> Void)?
    @objc var onSizeChange: ((Double, Double) -> Void)?
    private var host: UIHostingController<AnyView>?
    private var eventID = ""
    private var enabled = false
    private var reportedSize = CGSize.zero
    override init(frame: CGRect) {
        super.init(frame: frame)
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (view: LavaSystemButtonContent, _: UITraitCollection) in view.reportSize() }
    }
    required init?(coder: NSCoder) { nil }
    @objc(configureWithTitle:fontSize:prominent:disabled:destructive:eventID:)
    func configure(title: String, fontSize: Double, prominent: Bool, disabled: Bool, destructive: Bool, eventID: String) {
        self.eventID = eventID; enabled = !disabled
        let body = LavaSystemButtonAtom(title: title, fontSize: fontSize, prominent: prominent, disabled: disabled, destructive: destructive) { [weak self] in
            guard let self, enabled, window != nil, self.eventID == eventID else { return }
            onPress?(eventID)
        }
        if let host { host.rootView = AnyView(body) }
        else {
            let host = UIHostingController(rootView: AnyView(body)); host.safeAreaRegions = []
            host.view.backgroundColor = .clear; self.host = host
        }
        updateContainment(); reportSize()
    }
    override func didMoveToWindow() { super.didMoveToWindow(); updateContainment(); reportSize() }
    override func layoutSubviews() { super.layoutSubviews(); updateContainment(); reportSize() }
    private func updateContainment() {
        if let host { LavaNativeContainment.update(host, in: self) { $0.backgroundColor = .clear } }
    }
    private func reportSize() {
        guard let host else { return }
        let size = host.sizeThatFits(in: CGSize(width: 10_000, height: 10_000))
        guard size.width > 0, size.height > 0, size != reportedSize else { return }
        reportedSize = size
        // Fabric applies props before installing its event emitter on initial
        // mount. Deliver intrinsic geometry after that synchronous transaction.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.reportedSize == size else { return }
            self.onSizeChange?(Double(size.width), Double(size.height))
        }
    }
    @objc func resetForRecycle() {
        if let host { LavaNativeContainment.remove(host) }
        host = nil; enabled = false; eventID = ""; reportedSize = .zero
    }
}
private struct LavaSystemButtonAtom: View {
    let title: String
    let fontSize: Double
    let prominent: Bool
    let disabled: Bool
    let destructive: Bool
    let action: () -> Void
    var body: some View {
        Group {
            if prominent { Button(title, role: destructive ? .destructive : nil, action: action).buttonStyle(.borderedProminent) }
            else { Button(title, role: destructive ? .destructive : nil, action: action).buttonStyle(.bordered) }
        }
        .font(.system(size: fontSize))
        .disabled(disabled)
        .tint(LavaStyle.safeGreen)
        .fixedSize()
    }
}
