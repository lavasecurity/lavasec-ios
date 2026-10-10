import Foundation
import UIKit
import SwiftUI
import UniformTypeIdentifiers
import Combine
import LavaSecKit
import LavaSecAppServices

@MainActor
final class LavaWireGuardEditorVisit: NSObject, UIDocumentPickerDelegate {
    let id: UUID
    let draftID: String
    let draftRevision: Int
    let initialName: String
    var name: String
    var nameResetRevision = 0
    var configuration = ""
    var revealed = true
    var reading = false
    var error = ""
    var importToken = UUID()
    let changed = PassthroughSubject<Void, Never>()
    init(flow: LavaAppNativeFlow, revision: Int) {
        id = flow.id; draftID = flow.wireGuardDraftID ?? ""; draftRevision = revision
        initialName = flow.wireGuardName; name = flow.wireGuardName
    }
    var dirty: Bool { name != initialName || !configuration.isEmpty }
    var concealed: Bool {
        !configuration.isEmpty && SecurityPrivacyPolicy.requiresPrivateDraftCover(isRevealed: revealed,
            applicationIsActive: UIApplication.shared.applicationState == .active,
            backgroundCoverRequired: LavaAppBridge.shared.security.backgroundPrivacyCoverRequired)
    }
    var canEdit: Bool {
        let bridge = LavaAppBridge.shared
        guard bridge.flow?.id == id, let draft = bridge.wireGuardDraft, draft.id == draftID,
              draft.revision == draftRevision, !reading, bridge.canReadPresentation(.appSettings),
              !bridge.model.isStagingChainedUpstreamForQA, let status = bridge.model.dnsSettingsProfileStatus else { return false }
        return ChainedSetupPolicy.canEditConfiguration(bridge.model.chainedSurfaceInputs(from: status))
    }
    var canSave: Bool {
        canEdit && (!configuration.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || LavaAppBridge.shared.flow?.wireGuardExists == true && String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80)) != initialName)
    }
    func retire() { importToken = UUID(); reading = false; configuration = ""; changed.send() }
    func chooseFile() {
        guard canEdit else { return }; error = ""
        var types: [UTType] = [.plainText, .text, .data]
        if let conf = UTType(filenameExtension: "conf") { types.insert(conf, at: 0) }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: false)
        picker.allowsMultipleSelection = false; picker.delegate = self
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState == .foregroundActive }),
              var top = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController else { return }
        while let presented = top.presentedViewController { top = presented }
        top.present(picker, animated: true)
    }
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard canEdit, let url = urls.first else { return }
        let token = UUID(); importToken = token
        let authorization = LavaAppBridge.shared.security.viewAuthenticationRevision
        reading = true; changed.send(); LavaAppBridge.shared.publish()
        Task { [weak self] in
            let imported = await Task.detached(priority: .userInitiated) { Result { try WireGuardConfigurationFile.read(at: url) } }.value
            guard let self, importToken == token else { return }
            reading = false
            defer { changed.send() }
            guard LavaAppBridge.shared.security.viewAuthenticationRevision == authorization, canEdit else { LavaAppBridge.shared.publish(); return }
            switch imported {
            case .success(let text):
                configuration = text; revealed = false
                if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    name = url.deletingPathExtension().lastPathComponent
                    // Only an external import replaces the shared field buffer.
                    // Typing acknowledgements never advance its reset revision.
                    nameResetRevision += 1
                }
            case .failure(let failure): error = failure.localizedDescription
            }
            LavaAppBridge.shared.foregroundDraftIsDirty = dirty; LavaAppBridge.shared.publish()
        }
    }
}

extension LavaAppBridge {
    /// The ordinary Name leaf must never create an editor visit or read its
    /// confidential configuration merely to decide whether UIKit may edit it.
    @objc(canEditWireGuardNameForOwnerID:)
    func canEditWireGuardName(ownerID: String) -> Bool {
        guard let flow, flow.name == "vpnConfiguration", flow.id.uuidString == ownerID,
              let visit = wireGuardEditorVisit, visit.id == flow.id,
              flow.wireGuardDraftID == visit.draftID,
              flow.wireGuardDraftRevision == visit.draftRevision else { return false }
        return visit.canEdit
    }

    func wireGuardEditorOwner(_ flow: LavaAppNativeFlow) -> LavaWireGuardEditorVisit? {
        guard flow.name == "vpnConfiguration", let draft = wireGuardDraft, draft.id == flow.wireGuardDraftID,
              draft.revision == flow.wireGuardDraftRevision else { return nil }
        if let wireGuardEditorVisit, wireGuardEditorVisit.id == flow.id { return wireGuardEditorVisit }
        wireGuardEditorVisit?.retire()
        let visit = LavaWireGuardEditorVisit(flow: flow, revision: draft.revision); wireGuardEditorVisit = visit; return visit
    }
    func wireGuardEditorProjection(_ flow: LavaAppNativeFlow) -> [String: Any]? {
        guard canReadPresentation(.appSettings), let visit = wireGuardEditorOwner(flow) else { return nil }
        return ["name": visit.name, "nameResetRevision": visit.nameResetRevision, "dirty": visit.dirty, "hasContent": !visit.configuration.isEmpty,
            "concealed": visit.concealed, "reading": visit.reading, "canEdit": visit.canEdit,
            "canSave": visit.canSave, "error": visit.error]
    }
    func wireGuardEditorCommand(_ action: String, _ input: [String: Any]) async throws -> Any {
        guard let flow, input["id"] as? String == flow.id.uuidString, let visit = wireGuardEditorOwner(flow) else { throw WireGuardChainFailure.changed }
        try await authorize(.appSettings, "Edit VPN chaining")
        guard self.flow?.id == flow.id, visit.canEdit else { throw WireGuardChainFailure.changed }
        switch action {
        case "vpnEditor.enter": break
        case "vpnEditor.name":
            guard let name = input["name"] as? String else { throw WireGuardChainFailure.changed }
            visit.name = name; foregroundDraftIsDirty = visit.dirty
        case "vpnEditor.file": visit.chooseFile()
        case "vpnEditor.save":
            guard visit.canSave, let save = flow.saveWireGuardDraft else { throw WireGuardChainFailure.changed }
            visit.error = save(visit.name, visit.configuration.isEmpty ? nil : visit.configuration) ?? ""
            guard visit.error.isEmpty else { throw CommandError(visit.error) }
            visit.retire(); flow.reportConfigurationRemovalFailure?(nil)
            model.refreshDNSSettingsPresentation(); self.flow = nil; foregroundDraftIsDirty = false
        default: throw CommandError("Invalid app command.")
        }
        return NSNull()
    }
}

@MainActor
private final class LavaWireGuardTextView: UITextView {
    var mayInteract: (() -> Bool)?
    var interactionFrozen = false
    var isInteractionAdmitted: Bool { !interactionFrozen && mayInteract?() == true }
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        isInteractionAdmitted && super.point(inside: point, with: event)
    }
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        isInteractionAdmitted && super.canPerformAction(action, withSender: sender)
    }
}

/// Confidential text is owned by UIKit/native memory. Fabric receives only its
/// visit ID and display metadata, never the configuration or any saved key.
@objc(LavaWireGuardInputContent)
@MainActor
final class LavaWireGuardInputContent: UIView, UITextViewDelegate {
    // Layout metadata only. Neither callbacks nor Fabric receive draft text.
    @objc var focusChanged: ((Bool) -> Void)?
    @objc var isEditing: Bool { textView.isFirstResponder && !textView.isHidden }
    private let textView = LavaWireGuardTextView()
    private let placeholder = UILabel()
    private let cover = UIHostingController(rootView: AnyView(EmptyView()))
    private weak var owner: LavaWireGuardEditorVisit?
    private var observers = Set<AnyCancellable>()
    private var ownerChanges: AnyCancellable?
    private var paragraphLineHeight: CGFloat = 0
    private var hasAcceptedRevealedDisplay = false
    override init(frame: CGRect) {
        super.init(frame: frame)
        textView.delegate = self; textView.backgroundColor = .clear
        textView.mayInteract = { [weak self] in self?.owner?.canEdit == true && self?.owner?.concealed == false }
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        textView.textContainer.lineFragmentPadding = 5
        textView.textColor = .label
        textView.autocorrectionType = .no; textView.autocapitalizationType = .none; textView.accessibilityLabel = "Content".lavaLocalized
        placeholder.numberOfLines = 0; placeholder.textColor = UIColor(LavaStyle.tertiaryText); placeholder.isAccessibilityElement = false
        cover.view.backgroundColor = .clear
        cover.safeAreaRegions = []
        addSubview(textView); addSubview(placeholder); addSubview(cover.view)
        let bridge = LavaAppBridge.shared
        for publisher in [bridge.objectWillChange, bridge.security.objectWillChange, bridge.model.objectWillChange] {
            publisher.sink { [weak self] _ in DispatchQueue.main.async { self?.update() } }.store(in: &observers)
        }
        for notification in [UIApplication.willResignActiveNotification, UIApplication.protectedDataWillBecomeUnavailableNotification] {
            NotificationCenter.default.publisher(for: notification).sink { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if bridge.security.backgroundPrivacyCoverRequired { self.owner?.revealed = false; self.concealImmediately() }
                    // Revoking input must not resign UIKit's responder and move
                    // an accepted all-off display. Delegate/action gates still
                    // require current native authority before any mutation.
                    self.freezeInteraction()
                }
            }.store(in: &observers)
        }
        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification).sink { [weak self] _ in
            DispatchQueue.main.async { self?.update() }
        }.store(in: &observers)
    }
    required init?(coder: NSCoder) { nil }
    @objc(configureWithOwnerID:placeholder:fontPointSize:)
    func configure(ownerID: String, placeholder: String, fontPointSize: CGFloat) {
        let bridge = LavaAppBridge.shared
        let nextOwner = bridge.flow.flatMap { $0.id.uuidString == ownerID ? bridge.wireGuardEditorOwner($0) : nil }
        if owner?.id != nextOwner?.id { concealImmediately() }
        owner = nextOwner
        ownerChanges = owner?.changed.sink { [weak self] in self?.update() }
        self.placeholder.text = placeholder
        let font = fontPointSize > 0 ? UIFont.systemFont(ofSize: fontPointSize) : UIFont.preferredFont(forTextStyle: .body)
        // Match LavaTextEditorInputRow's body paragraphs and leading pull-back.
        // Updating unrelated metadata must not restyle an uninterrupted edit.
        let nextLineHeight = font.pointSize * 22 / 17
        if textView.font != font || paragraphLineHeight != nextLineHeight {
            textView.font = font; paragraphLineHeight = nextLineHeight
            applyParagraphStyle()
        }
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = max(0, nextLineHeight - font.lineHeight)
        self.placeholder.attributedText = NSAttributedString(string: placeholder,
            attributes: [.font: font, .foregroundColor: UIColor(LavaStyle.tertiaryText), .paragraphStyle: paragraph])
        update()
    }
    private func applyParagraphStyle() {
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = max(0, paragraphLineHeight - (textView.font?.lineHeight ?? 0))
        textView.typingAttributes = [.font: textView.font ?? UIFont.preferredFont(forTextStyle: .body),
            .foregroundColor: UIColor.label, .paragraphStyle: paragraph]
        textView.textStorage.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: textView.textStorage.length))
    }
    private func freezeInteraction() {
        // Disabling UIKit's control can drop its existing responder when the
        // app activates. Keep the accepted all-off display's control flags;
        // native hit-testing, action and delegate admission keep input blocked.
        textView.interactionFrozen = true
        textView.isAccessibilityElement = false
    }
    private func concealImmediately() {
        hasAcceptedRevealedDisplay = false
        freezeInteraction()
        textView.resignFirstResponder(); textView.text = ""; textView.isHidden = true; cover.view.isHidden = false; placeholder.isHidden = true
    }
    private func update() {
        let bridge = LavaAppBridge.shared
        guard let owner, bridge.canReadPresentation(.appSettings) else {
            // Display retention never fetches the owner's configuration or
            // restores a retired frame. Input/AX stay revoked while the exact
            // already painted revealed visit waits for foreground authority.
            // pinned: WireGuardSetupSourceTests.testRNPrivateDraftRetentionDoesNotReadOrEditWithoutAuthority
            if SecurityPrivacyPolicy.canRetainAcceptedPrivateDraftDisplay(
                hasAcceptedRevealedDisplay: hasAcceptedRevealedDisplay,
                ownerIsCurrent: owner?.id == bridge.flow?.id && owner != nil,
                backgroundCoverRequired: bridge.security.backgroundPrivacyCoverRequired) {
                freezeInteraction(); return
            }
            cover.rootView = AnyView(LavaPrivateContentCover(title: "Configuration hidden", actionTitle: nil))
            concealImmediately(); return
        }
        cover.rootView = AnyView(LavaPrivateContentCover(title: "Configuration hidden",
            actionTitle: owner.canEdit && UIApplication.shared.applicationState == .active ? "Show configuration" : nil) { [weak self] in self?.showConfiguration() })
        if owner.concealed { concealImmediately() }
        else {
            cover.view.isHidden = true; textView.isHidden = false
            if textView.markedTextRange == nil && textView.text != owner.configuration {
                textView.text = owner.configuration; applyParagraphStyle()
            }
            placeholder.isHidden = !owner.configuration.isEmpty
            hasAcceptedRevealedDisplay = !bridge.security.backgroundPrivacyCoverRequired
        }
        let editable = owner.canEdit && !owner.concealed
        textView.interactionFrozen = !editable
        textView.isEditable = editable
        textView.isUserInteractionEnabled = editable
        textView.isAccessibilityElement = !owner.concealed
        setNeedsLayout()
    }
    @objc private func showConfiguration() {
        guard let owner, owner.canEdit else { return }; owner.revealed = true; update(); LavaAppBridge.shared.publish()
    }
    func textViewDidChange(_ textView: UITextView) {
        guard let owner, self.textView.isInteractionAdmitted else { update(); return }
        owner.configuration = textView.text; placeholder.isHidden = !owner.configuration.isEmpty
        LavaAppBridge.shared.foregroundDraftIsDirty = owner.dirty; LavaAppBridge.shared.publish()
    }
    func textViewShouldBeginEditing(_ textView: UITextView) -> Bool { self.textView.isInteractionAdmitted }
    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        self.textView.isInteractionAdmitted
    }
    func textViewDidBeginEditing(_ textView: UITextView) { focusChanged?(true) }
    func textViewDidEndEditing(_ textView: UITextView) { focusChanged?(false) }
    override func layoutSubviews() {
        super.layoutSubviews()
        textView.frame = CGRect(x: -5, y: 0, width: bounds.width + 5, height: bounds.height)
        cover.view.frame = bounds
        placeholder.frame = CGRect(origin: CGPoint(x: 0, y: 8), size: placeholder.sizeThatFits(CGSize(width: bounds.width, height: .greatestFiniteMagnitude)))
    }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            concealImmediately()
            cover.willMove(toParent: nil); cover.removeFromParent()
        } else {
            var ancestor: UIResponder? = next
            while let candidate = ancestor, !(candidate is UIViewController) { ancestor = candidate.next }
            if cover.parent == nil, let parent = ancestor as? UIViewController { parent.addChild(cover); cover.didMove(toParent: parent) }
            update()
        }
    }
}
