import Combine
import SwiftUI
import UIKit
import LavaSecAppServices

/// Small credential-only atom. RN owns the surrounding task, consent and actions.
@objc(LavaBackupCredentialsContent)
@MainActor
final class LavaBackupCredentialsContent: UIView {
    @objc var sizeChanged: ((CGFloat) -> Void)?
    private var controller: UIHostingController<AnyView>?
    private var ownerID = ""
    private var mode = ""
    private var observers = Set<AnyCancellable>()
    private var lastHeight: CGFloat = 0
    private var suspended = false
    private var hasAcceptedDisplay = false
    override init(frame: CGRect) {
        super.init(frame: frame)
        let bridge = LavaAppBridge.shared
        for source in [bridge.objectWillChange, bridge.security.objectWillChange, bridge.model.account.objectWillChange] {
            source.sink { [weak self] _ in DispatchQueue.main.async { self?.refreshAdmission(); self?.setNeedsLayout() } }.store(in: &observers)
        }
        for name in [UIApplication.willResignActiveNotification, UIApplication.protectedDataWillBecomeUnavailableNotification] {
            NotificationCenter.default.publisher(for: name).sink { [weak self] _ in MainActor.assumeIsolated { self?.suspended = true; self?.refreshAdmission() } }.store(in: &observers)
        }
        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification).sink { [weak self] _ in DispatchQueue.main.async { self?.suspended = false; self?.refreshAdmission() } }.store(in: &observers)
        bridge.security.$viewAuthenticationRevision.dropFirst().sink { [weak self] _ in MainActor.assumeIsolated { self?.refreshAdmission() } }.store(in: &observers)
    }
    required init?(coder: NSCoder) { nil }
    @objc(configureWithOwnerID:mode:)
    func configure(ownerID: String, mode: String) {
        guard self.ownerID != ownerID || self.mode != mode else { refreshAdmission(); return }
        resetForRecycle(); self.ownerID = ownerID; self.mode = mode
        let bridge = LavaAppBridge.shared
        guard let owner = bridge.accountBackupSession, owner.id.uuidString == ownerID, owner.isCurrent else { return }
        let atom: AnyView
        if mode == "display", let setup = owner.setup { atom = AnyView(BackupRecoveryPhraseContent(session: setup)) }
        else if mode == "entry", let restore = owner.restore { atom = AnyView(BackupRecoveryEntryContent(session: restore, mayInteract: { [weak owner] in owner?.mayAccessCredentials == true })) }
        else { return }
        let hosted = UIHostingController(rootView: AnyView(atom.preferredColorScheme(bridge.model.customization.preferredColorScheme).lavaTextSizeOverride(bridge.model.customization.textSizeOverride)))
        hosted.safeAreaRegions = []; controller = hosted; updateContainment(); refreshAdmission(); setNeedsLayout()
    }
    private func conceal() { hasAcceptedDisplay = false; controller?.viewIfLoaded?.isHidden = true; controller?.viewIfLoaded?.isUserInteractionEnabled = false; controller?.viewIfLoaded?.accessibilityElementsHidden = true; controller?.viewIfLoaded?.endEditing(true) }
    private func refreshAdmission() {
        let bridge = LavaAppBridge.shared
        let owner = bridge.accountBackupSession
        let exactOwner = owner?.id.uuidString == ownerID && owner?.isCurrent == true
        if !suspended, exactOwner, owner?.mayAccessCredentials == true {
            hasAcceptedDisplay = true; controller?.viewIfLoaded?.isHidden = false; controller?.viewIfLoaded?.isUserInteractionEnabled = true; controller?.viewIfLoaded?.accessibilityElementsHidden = false
        } else if exactOwner, hasAcceptedDisplay, !bridge.security.backgroundPrivacyCoverRequired {
            // Preserve the admitted all-off frame without admitting an input or
            // fetching new credential material while read authority is suspended.
            // pinned: AccountBackupSessionSourceTests.testCredentialAtomRetainsOnlyAdmittedAllOffFrame
            controller?.viewIfLoaded?.isUserInteractionEnabled = false; controller?.viewIfLoaded?.accessibilityElementsHidden = true
        } else { conceal() }
    }
    override func didMoveToSuperview() { super.didMoveToSuperview(); updateContainment(); refreshAdmission() }
    override func didMoveToWindow() { super.didMoveToWindow(); updateContainment(); refreshAdmission() }
    override func layoutSubviews() {
        super.layoutSubviews(); updateContainment()
        guard bounds.width > 0, let controller, controller.parent != nil else { return }
        let size = controller.sizeThatFits(in: CGSize(width: bounds.width, height: CGFloat.greatestFiniteMagnitude))
        let height = ceil(size.height)
        if height > 0, abs(height - lastHeight) > 0.5 { lastHeight = height; sizeChanged?(height) }
    }
    private func updateContainment() {
        if let controller { LavaNativeContainment.update(controller, in: self) { $0.backgroundColor = .clear } }
    }
    @objc func resetForRecycle() { conceal(); if let controller { LavaNativeContainment.remove(controller) }; controller = nil; ownerID = ""; mode = ""; lastHeight = 0 }
}

private struct BackupRecoveryPhraseContent: View {
    @ObservedObject var session: BackupSetupSession
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var body: some View {
        VStack(spacing: 12) {
            // All eight words participate in sizeThatFits. A lazy grid can
            // report a partial height when Copy invalidates its hosted layout.
            let columns = dynamicTypeSize.isAccessibilitySize ? 1 : 2
            VStack(spacing: 8) {
                ForEach(Array(stride(from: 0, to: session.recoveryWords.count, by: columns)), id: \.self) { start in
                    HStack(spacing: 8) {
                        ForEach(start..<min(start + columns, session.recoveryWords.count), id: \.self) { index in
                            BackupRecoveryPhraseWord(number: index + 1, word: session.recoveryWords[index]).frame(maxWidth: .infinity)
                        }
                    }
                }
            }
            Button { if LavaAppBridge.shared.accountBackupSession?.mayAccessCredentials == true { session.copyPhrase() } } label: {
                ZStack {
                    Label("Copy phrase".lavaLocalized, systemImage: "doc.on.doc")
                        .opacity(session.consent.copiedRecoveryPhrase ? 0 : 1).accessibilityHidden(session.consent.copiedRecoveryPhrase)
                    Label("Copied".lavaLocalized, systemImage: "checkmark")
                        .opacity(session.consent.copiedRecoveryPhrase ? 1 : 0).accessibilityHidden(!session.consent.copiedRecoveryPhrase)
                }
            }
            .buttonStyle(LavaPanelActionButtonStyle())
            .disabled(session.recoveryPhrase.isEmpty || session.busy || session.step != .recoveryPhrase)
            .accessibilityInputLabels(["Copy phrase".lavaLocalized, "Copy".lavaLocalized] + (session.consent.copiedRecoveryPhrase ? ["Copied".lavaLocalized] : []))
        }
    }
}
private struct BackupRecoveryPhraseWord: View {
    let number: Int
    let word: String
    @ScaledMetric(relativeTo: .caption) private var numberWidth = 18.0
    var body: some View {
        HStack(spacing: 7) {
            Text("\(number)").font(.caption.weight(.bold)).foregroundStyle(.secondary).frame(width: numberWidth, alignment: .trailing)
            Text(word).font(.system(.body, design: .monospaced).weight(.semibold)).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
        }.lavaRecoveryWordSurface().accessibilityElement(children: .combine)
    }
}
private struct BackupRecoveryEntryContent: View {
    @ObservedObject var session: BackupRestoreSession
    let mayInteract: () -> Bool
    @FocusState private var focusedWord: Int?
    var body: some View {
        LavaTextInputPanel {
            LavaTextEditorInputRow(title: "Paste full phrase", text: Binding(get: { session.recoveryPhrasePaste }, set: { if mayInteract() { session.setPastedPhrase($0) } }), placeholder: "Paste the full recovery phrase", minHeight: 60)
            Divider()
            LavaTextInputRow(title: "Words") {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    ForEach(0..<BackupRecoveryPhrase.wordCount, id: \.self) { index in
                        BackupRecoveryWordField(number: index + 1, word: Binding(get: { session.recoveryWords[index] }, set: { if mayInteract() { session.setWord($0, at: index) } }), fieldIndex: index, focusedField: $focusedWord, onSpace: { focusedWord = index + 1 < BackupRecoveryPhrase.wordCount ? index + 1 : nil })
                    }
                }
            }
        }.disabled(session.isRestoring)
    }
}
private struct BackupRecoveryWordField: View {
    let number: Int
    @Binding var word: String
    let fieldIndex: Int
    @FocusState.Binding var focusedField: Int?
    let onSpace: () -> Void
    var body: some View {
        HStack(spacing: 7) {
            Text("\(number)").font(.caption.weight(.bold)).foregroundStyle(.secondary).frame(width: 18, alignment: .trailing).accessibilityHidden(true)
            TextField("Word %lld".lavaLocalizedFormat(number), text: $word).focused($focusedField, equals: fieldIndex).lavaTextInputBody(submitLabel: .next)
                .onChange(of: word) { _, value in if value.contains(" ") { word = value.replacingOccurrences(of: " ", with: ""); onSpace() } }
        }.lavaRecoveryWordSurface()
    }
}
