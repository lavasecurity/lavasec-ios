import SwiftUI
import UIKit
import LavaSecKit

/// Native lifetime and credential owner. Only nonsecret presentation metadata crosses the bridge.
@MainActor
final class LavaPasscodeSession: ObservableObject {
    let id: UUID
    let authenticating: Bool
    @Published var code = ""
    @Published var focused = false
    struct Header: Equatable {
        let title: String
        let cancelTitle: String
        let showCancel: Bool
    }
    @Published private(set) var header: Header?
    private var entry: PasscodeEntrySession
    private let security: SecurityController

    init(id: UUID, authenticating: Bool, security: SecurityController) {
        self.id = id; self.authenticating = authenticating; self.security = security
        entry = PasscodeEntrySession(mode: authenticating ? .authenticate : .setup)
    }
    var current: Bool {
        let bridge = LavaAppBridge.shared
        guard UIApplication.shared.applicationState == .active, security.protectedDataIsAvailableForPresentation else { return false }
        return authenticating ? security.passcodeAuthenticationRequest?.id == id
            : bridge.flow?.id == id && bridge.flow?.name == "passcode" && bridge.canReadPresentation(.appUnlock)
    }
    var projection: [String: Any] {
        let title = authenticating ? "Enter Passcode" : entry.confirming ? "Confirm Passcode" : "Set Passcode"
        let subtitle = authenticating ? security.passcodeAuthenticationRequest?.reason ?? ""
            : entry.confirming ? "Enter it again to confirm" : "Enter a 4-digit code for Lava"
        return ["id": id.uuidString, "authenticating": authenticating, "title": title.lavaLocalized,
                "subtitle": subtitle.lavaLocalized, "message": entry.message?.lavaLocalized ?? ""]
    }
    func receive(_ value: String) {
        guard current else { code = ""; focused = false; return }
        let filtered = String(value.filter(\.isNumber).prefix(4))
        code = filtered
        guard filtered.count == 4 else { return }
        let effect = entry.enter(filtered)
        code = ""
        switch effect {
        case .none: break
        case .authenticate(let code):
            if !security.completePasscodeAuthentication(requestID: id, code: code) { entry.failed("Wrong passcode") }
        case .setPasscode(let code):
            do {
                try security.setPasscode(code)
                if LavaAppBridge.shared.flow?.id == id { LavaAppBridge.shared.flow = nil }
            } catch { entry.failed(error.localizedDescription) }
        }
        LavaAppBridge.shared.publish()
    }
    func setHeader(_ value: Header) { if header != value { header = value } }
    func retire() { header = nil; code = ""; focused = false; entry = PasscodeEntrySession(mode: authenticating ? .authenticate : .setup) }
}

/// System navigation chrome only. The app-owned passcode body remains React Native.
struct LavaAppPasscodeNavigation<Content: View>: View {
    @ObservedObject var session: LavaPasscodeSession
    @ViewBuilder let content: () -> Content
    var body: some View {
        NavigationStack {
            content()
                .background(LavaStyle.groupedBackground.ignoresSafeArea())
                .navigationTitle(session.header?.title ?? "")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    if let header = session.header, header.showCancel {
                        ToolbarItem(placement: .topBarLeading) {
                            Button(header.cancelTitle) {
                                let bridge = LavaAppBridge.shared
                                guard bridge.passcodeSession === session, session.current else { return }
                                do {
                                    _ = try bridge.passcodeCommand(["id": session.id.uuidString, "action": "cancel"])
                                    bridge.publish()
                                } catch { }
                            }
                        }
                    }
                }
        }.interactiveDismissDisabled()
    }
}

extension LavaAppBridge {
    /// Public chrome metadata cannot create a session or authorize private reads.
    func passcodeHeader(_ input: [String: Any]) throws -> Any {
        guard let session = passcodeSession, session.authenticating, session.current,
              input["id"] as? String == session.id.uuidString,
              let title = input["title"] as? String, !title.isEmpty, title.utf8.count <= 256,
              let cancelTitle = input["cancelTitle"] as? String, !cancelTitle.isEmpty, cancelTitle.utf8.count <= 256,
              let showCancel = input["showCancel"] as? Bool else { throw CommandError("Authentication cancelled.") }
        session.setHeader(.init(title: title, cancelTitle: cancelTitle, showCancel: showCancel))
        return NSNull()
    }
    func currentPasscodeSession() -> LavaPasscodeSession? {
        let request = security.passcodeAuthenticationRequest
        let id = request?.id ?? (flow?.name == "passcode" ? flow?.id : nil)
        guard let id else { passcodeSession?.retire(); passcodeSession = nil; return nil }
        if passcodeSession?.id != id {
            passcodeSession?.retire()
            passcodeSession = LavaPasscodeSession(id: id, authenticating: request != nil, security: security)
        }
        return passcodeSession
    }
    func passcodeProjection() -> [String: Any]? {
        guard UIApplication.shared.applicationState != .background, security.protectedDataIsAvailableForPresentation,
              let session = currentPasscodeSession(), session.authenticating || canReadPresentation(.appUnlock) else { return nil }
        return session.projection
    }
    func passcodeCommand(_ input: [String: Any]) throws -> Any {
        guard let session = currentPasscodeSession(), session.current,
              input["id"] as? String == session.id.uuidString,
              let action = input["action"] as? String, ["cancel", "focus"].contains(action) else { throw CommandError("Authentication cancelled.") }
        if action == "focus" { session.focused = true; return NSNull() }
        session.retire()
        if session.authenticating { security.cancelPasscodeAuthentication(requestID: session.id) }
        else if flow?.id == session.id { flow = nil }
        return NSNull()
    }
}

/// Reusable credential atoms. RN chooses their placement; neither atom renders a screen or receives credentials.
@objc(LavaPasscodeInputContent)
@MainActor
final class LavaPasscodeInputContent: UIView {
    private var host: UIHostingController<AnyView>?
    private var ownerID = ""
    private var kind = ""
    @objc func configure(ownerID: String, kind: String) {
        guard ownerID != self.ownerID || kind != self.kind else { return }
        resetForRecycle(); self.ownerID = ownerID; self.kind = kind
        guard let session = LavaAppBridge.shared.currentPasscodeSession(), session.id.uuidString == ownerID else { return }
        let host = UIHostingController(rootView: AnyView(LavaPasscodeAtom(session: session, digits: kind == "digits")))
        host.view.backgroundColor = .clear
        self.host = host
        updateContainment()
    }
    override func layoutSubviews() { super.layoutSubviews(); updateContainment() }
    override func didMoveToWindow() { super.didMoveToWindow(); updateContainment() }
    private func updateContainment() {
        if let host { LavaNativeContainment.update(host, in: self) { $0.backgroundColor = .clear } }
    }
    @objc func resetForRecycle() {
        if let host { LavaNativeContainment.remove(host) }
        host = nil; ownerID = ""; kind = ""
    }
}

private struct LavaPasscodeAtom: View {
    @ObservedObject var session: LavaPasscodeSession
    let digits: Bool
    var body: some View {
        Group {
            if digits { SecurityPasscodeDigitsView(code: session.code) }
            else {
                SecurityHiddenPasscodeField(code: Binding(get: { session.code }, set: { session.receive($0) }), isFocused: $session.focused)
                    .opacity(0.01)
                    .task {
                        session.focused = false
                        try? await Task.sleep(nanoseconds: 200_000_000)
                        if !Task.isCancelled && session.current { session.focused = true }
                    }
            }
        }.tint(LavaStyle.safeGreen)
    }
}
