import Foundation
import Combine
import SwiftUI
import UIKit
import LavaSecKit
import LavaSecAppServices
import LavaSecPresentation

#if DEBUG || LAVA_QA_TOOLS
@MainActor private enum LavaQAVisitAdmissions {
    static var lifetime = QAPresentationVisitLifetime()
}

private struct PhoneQAEntry: Identifiable {
    let id: String
    let title: String
    let explanation: String
    let symbol: String
    var disabled = false
    var destructive = false
    let action: () -> Void
}

private struct PhoneQASection: Identifiable {
    let title: String
    var entries: [PhoneQAEntry]
    var id: String { title }
}


/// Native QA actions, test observations and confidential staging input belong to one admitted visit.
@MainActor
final class LavaQASession: ObservableObject {
    let id: String
    let viewModel: AppViewModel
    let surface: SecurityProtectedSurface
    var copiedDomain: String?
    @Published var chainedUpstreamConf = ""
    var search = ""
    var showingResult = false
    var condition: QAInternetNetworkCondition?
    var suite: QAInternetScenarioSuite?
    var scenario: QAInternetScenario?
    var prepared = false
    var verified = false
    var evidence = ""
    var result: String?
    var results: [String: String] = [:]
    var detailID = UUID()
    var detailRevision = 0
    private(set) var retired = false
    let showWelcome: () -> Void
    let showUserBugReport: () -> Void
    init(id: String, viewModel: AppViewModel, surface: SecurityProtectedSurface, showWelcome: @escaping () -> Void, showUserBugReport: @escaping () -> Void) {
        self.id = id; self.viewModel = viewModel; self.surface = surface; self.showWelcome = showWelcome; self.showUserBugReport = showUserBugReport
    }
    var current: Bool {
        let bridge = LavaAppBridge.shared
        return !retired && bridge.qaSession === self && UIApplication.shared.applicationState == .active && bridge.canReadPresentation(surface)
    }
    func changed() { if current { LavaAppBridge.shared.publish() } }
    private func matches(_ values: String...) -> Bool {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || values.contains { $0.lavaLocalized.localizedStandardContains(query) }
    }

    private var sections: [PhoneQASection] {
        var result = [
            PhoneQASection(title: "Onboarding", entries: [
                PhoneQAEntry(id: "mock-onboarding", title: "Mock fresh onboarding",
                    explanation: "Rehearse setup with simulated actions. Nothing is saved.", symbol: "play.rectangle") {
                    LavaAppBridge.shared.presentQAMockOnboarding()
                }
            ]),
            PhoneQASection(title: "Internet QA Suites", entries: QAInternetScenarioSuite.allCases.map { value in
                PhoneQAEntry(id: value.id, title: value.title, explanation: value.summary,
                    symbol: "point.3.connected.trianglepath.dotted") { [self] in suite = value }
            }),
            PhoneQASection(title: "Network Conditions", entries: QAInternetNetworkCondition.allCases.map { value in
                PhoneQAEntry(id: value.id, title: value.title, explanation: value.summary,
                    symbol: value.qaSystemImage) { [self] in condition = value }
            }),
            PhoneQASection(title: "DNS Setups", entries: QAInternetDNSSetup.allCases.map { value in
                PhoneQAEntry(id: value.id, title: value.title, explanation: value.summary,
                    symbol: value.qaSystemImage) { [self] in viewModel.applyQAInternetDNSSetup(value); showingResult = true; changed() }
            }),
            PhoneQASection(title: "Blocklist Loads", entries: QAInternetBlocklistLoad.allCases.map { value in
                PhoneQAEntry(id: value.id, title: value.title, explanation: value.summary,
                    symbol: "line.3.horizontal.decrease.circle") { [self] in viewModel.applyQAInternetBlocklistLoad(value); showingResult = true; changed() }
            }),
            PhoneQASection(title: "Haptics", entries: PhoneQAHapticPreview.allCases.map { value in
                PhoneQAEntry(id: String(describing: value.id), title: value.title, explanation: value.summary,
                    symbol: value.systemImage) { ProtectionHapticFeedback.play(value.feedback) }
            })
        ]
        result += AdminQAActionSection.allCases.map { section in
            PhoneQASection(title: section.title, entries: AdminQAAction.allCases.filter { $0.section == section }.map { value in
                PhoneQAEntry(id: value.id, title: value.title, explanation: value.summary,
                    symbol: value.qaSystemImage, destructive: value == .clearLocalActivity || value == .clearQAState) { [self] in
                    viewModel.applyAdminQAAction(value)
                    if value == .showWelcome { showWelcome() }
                    else if value == .showUserBugReport { showUserBugReport() }
                    else { showingResult = true; changed() }
                }
            })
        }
        result.append(PhoneQASection(title: "VPN Profile", entries: AdminQAVPNProfileAction.allCases.map { value in
            PhoneQAEntry(id: value.id, title: value.title, explanation: value.summary,
                symbol: value.qaSystemImage, disabled: viewModel.isConfiguringVPN,
                destructive: value != .installProfile) { [self] in
                Task { [weak self] in
                    guard let self, current else { return }
                    await viewModel.applyAdminQAVPNProfileAction(value)
                    guard current else { return }
                    showingResult = true; detailID = UUID(); changed()
                }
            }
        }))
        result.append(PhoneQASection(title: "Chained Upstream", entries: [
            PhoneQAEntry(id: "remove-key", title: "Remove key, keep configuration", explanation: "Remove the stored key to check missing-key recovery.", symbol: "key.slash", disabled: viewModel.isStagingChainedUpstreamForQA, destructive: true) { [self] in
                viewModel.clearStagedChainedUpstreamForQA(keepingConfiguration: true); showingResult = true; changed()
            },
            PhoneQAEntry(id: "clear-upstream", title: "Clear staged upstream", explanation: "Remove the staged configuration and its key.", symbol: "trash", disabled: viewModel.isStagingChainedUpstreamForQA, destructive: true) { [self] in
                viewModel.clearStagedChainedUpstreamForQA(keepingConfiguration: false); showingResult = true; changed()
            }
        ]))
        result.append(PhoneQASection(title: "Hosted QA", entries: [
            PhoneQAEntry(id: "hosted-site", title: "Open Hosted QA Site", explanation: "Run allowed, blocked, exception, and threat-guardrail probes.", symbol: "safari") {
                UIApplication.shared.open(QADomainProbeSet.hostedPageURL)
            }
        ]))
        result.append(PhoneQASection(title: "Probe Domains", entries: viewModel.qaProbeDomains.map { domain in
            PhoneQAEntry(id: domain, title: domain, explanation: copiedDomain == domain ? "Copied" : "Copy domain", symbol: "doc.on.doc") { [self] in
                UIPasteboard.general.string = domain; copiedDomain = domain
            }
        }))
        return result.compactMap { section in
            let entries = section.entries.filter { matches(section.title, $0.title, $0.explanation, $0.id) }
            return entries.isEmpty ? nil : PhoneQASection(title: section.title, entries: entries)
        }
    }


    private var formsMatch: Bool {
        matches("Chained Upstream", "WireGuard configuration", "Custom Probe Suffix", "DNS Leak Canary", "resolver IP")
    }
    private var configurationMatches: Bool {
        guard let scenario else { return true }
        let config = viewModel.configuration, setup = scenario.dnsSetup
        return config.resolverPresetID == setup.resolverPresetID
            && config.customResolverAddress == setup.customResolverAddress
            && config.fallbackToDeviceDNS == setup.fallbackToDeviceDNS
            && config.usesEncryptedDeviceDNSFallback == setup.usesEncryptedDeviceDNSFallback
            && config.fallbackResolverPresetID == setup.fallbackResolverPresetID
            && config.enabledBlocklistIDs == scenario.blocklistLoad.enabledBlocklistIDs
    }
    var hasDetail: Bool { showingResult || condition != nil || suite != nil }
    var detailKind: String? { showingResult ? "result" : condition != nil ? "check" : suite != nil ? "suite" : nil }
    func admits(_ action: String, input: [String: Any]) -> Bool {
        let detailActions = ["detail.close", "detail.back", "scenario", "prepare", "verified", "evidence", "record", "hosted"]
        if detailActions.contains(action) {
            guard hasDetail, input["detail"] as? String == detailID.uuidString else { return false }
            if action == "scenario", detailKind != "suite" { return false }
            if ["prepare", "verified", "evidence", "record", "hosted", "detail.back"].contains(action), detailKind != "check" { return false }
            return action != "detail.back" || suite != nil
        }
        return !hasDetail && input["detail"] == nil
            && ["search", "row", "result", "suffix", "probes.apply", "canaryIP", "canary.arm", "canary.disarm", "stage"].contains(action)
    }
    private func suiteProjection(_ suite: QAInternetScenarioSuite) -> [String: Any] {
        ["id": detailID.uuidString, "kind": "suite", "title": "Guided checks".lavaLocalized,
            "name": suite.title.lavaLocalized, "count": "%lld guided checks".lavaLocalizedFormat(suite.totalCombinationCount),
            "rows": suite.scenarios.map { scenario in ["id": scenario.id,
                "title": [scenario.networkCondition.title, scenario.dnsSetup.title, scenario.blocklistLoad.title].map(\.lavaLocalized).joined(separator: " / "),
                "subtitle": results[scenario.id] ?? "Not run".lavaLocalized] }]
    }
    func projection() -> [String: Any] {
        if prepared && !configurationMatches { verified = false; result = nil; if let scenario { results[scenario.id] = "Not run" } }
        var projection: [String: Any] = ["id": id, "search": search, "formsVisible": formsMatch,
            "hasConfiguration": !chainedUpstreamConf.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "staging": viewModel.isStagingChainedUpstreamForQA,
            "probeSuffix": viewModel.qaProbeSuffixDraft, "canaryIP": viewModel.leakCanaryResolverIPDraft,
            "hasResult": viewModel.adminQAStatusMessage != nil,
            "sections": sections.map { section in ["title": section.title.lavaLocalized,
                "rows": section.entries.map { entry in ["id": entry.id, "title": entry.title.lavaLocalized,
                    "subtitle": entry.explanation.lavaLocalized, "icon": entry.symbol,
                    "disabled": entry.disabled, "destructive": entry.destructive] }] }]
        if showingResult {
            projection["detail"] = ["id": detailID.uuidString, "kind": "result", "title": "QA result".lavaLocalized,
                "message": viewModel.adminQAStatusMessage ?? "No result yet.".lavaLocalized]
        } else if let condition {
            var detail: [String: Any] = ["id": detailID.uuidString, "revision": detailRevision, "kind": "check", "title": condition.title.lavaLocalized,
                "steps": condition.testerSteps.map(\.lavaLocalized), "expected": condition.expectedOutcome.lavaLocalized,
                "prepared": prepared, "verified": verified, "configurationMatches": configurationMatches,
                "evidence": evidence, "result": result?.lavaLocalized ?? "", "canRecord": prepared && verified && configurationMatches && !evidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "canBlock": !evidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "canBack": suite != nil]
            if let suite { detail["parent"] = suiteProjection(suite) }
            projection["detail"] = detail
        } else if let suite {
            projection["detail"] = suiteProjection(suite)
        }
        return projection
    }
    /// Local navigation only: the visit/detail token remains mandatory, while
    /// Close/Back keeps the native chrome's ability to leave a concealed body.
    func dismissDetail(back: Bool) {
        if back {
            condition = nil; scenario = nil; resetCheck()
            // Keep the returned suite's token so retained native chrome can
            // still close it before a private projection is reauthorized.
        } else {
            showingResult = false; condition = nil; suite = nil; scenario = nil
            results = [:]; resetCheck(); detailID = UUID()
        }
    }
    func command(_ action: String, _ input: [String: Any]) async {
        guard current else { return }
        switch action {
        case "search": search = input["value"] as? String ?? ""
        case "row":
            guard let id = input["row"] as? String, let entry = sections.flatMap(\.entries).first(where: { $0.id == id }), !entry.disabled else { return }
            detailID = UUID(); entry.action()
        case "result": showingResult = true; detailID = UUID()
        case "detail.close": dismissDetail(back: false)
        case "detail.back": dismissDetail(back: true)
        case "scenario":
            guard let id = input["row"] as? String, let scenario = suite?.scenarios.first(where: { $0.id == id }) else { return }
            self.scenario = scenario; condition = scenario.networkCondition; resetCheck(); detailID = UUID()
        case "prepare":
            if let scenario { viewModel.applyQAInternetScenario(scenario) }
            else if let condition { viewModel.prepareQAInternetNetworkCondition(condition) }
            else { return }
            prepared = true; verified = false; evidence = ""; result = nil; detailID = UUID(); detailRevision &+= 1
            if let scenario { results[scenario.id] = "Not run" }
        case "verified": verified = prepared && configurationMatches && input["value"] as? Bool == true
        case "evidence": evidence = input["value"] as? String ?? ""
        case "record":
            guard let value = input["value"] as? String, ["Passed", "Failed", "Blocked"].contains(value),
                  !evidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  value == "Blocked" || prepared && verified && configurationMatches else { return }
            result = value + " — tester reported"
            if let scenario { results[scenario.id] = (result?.lavaLocalized ?? "") + "\n" + evidence }
        case "hosted": await UIApplication.shared.open(QADomainProbeSet.hostedPageURL)
        case "suffix": viewModel.qaProbeSuffixDraft = input["value"] as? String ?? ""
        case "probes.apply": viewModel.applyCustomQAProbeSet()
        case "canaryIP": viewModel.leakCanaryResolverIPDraft = input["value"] as? String ?? ""
        case "canary.arm": viewModel.armDNSLeakCanaryForQA(resolverIP: viewModel.leakCanaryResolverIPDraft)
        case "canary.disarm": viewModel.disarmDNSLeakCanaryForQA()
        case "stage":
            let submitted = chainedUpstreamConf
            guard !viewModel.isStagingChainedUpstreamForQA, !submitted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            let staged = await viewModel.stageChainedUpstreamForQA(conf: submitted)
            // Retire only the submitted secret after a confirmed write, including
            // background completion. Clearing an old owner cannot touch a new visit.
            if staged, !retired, LavaAppBridge.shared.qaSession === self,
               chainedUpstreamConf == submitted { chainedUpstreamConf = "" }
        default: break
        }
    }
    private func resetCheck() { prepared = false; verified = false; evidence = ""; result = nil }
    func retire() {
        retired = true; chainedUpstreamConf = ""; evidence = ""; results = [:]
        condition = nil; suite = nil; scenario = nil; showingResult = false
    }
}
private enum PhoneQAHapticPreview: CaseIterable, Identifiable {
    case turnOnSuccess
    case turnOnFailure
    case turnOff
    case guardianTap

    var id: Self {
        self
    }

    var title: String {
        switch self {
        case .turnOnSuccess:
            "Turn On Success"
        case .turnOnFailure:
            "Turn On Failure"
        case .turnOff:
            "Turn Off"
        case .guardianTap:
            "Guardian Tap"
        }
    }

    var summary: String {
        switch self {
        case .turnOnSuccess:
            "Notification success"
        case .turnOnFailure:
            "Notification error"
        case .turnOff:
            "Light impact"
        case .guardianTap:
            "Light impact"
        }
    }

    var systemImage: String {
        switch self {
        case .turnOnSuccess:
            "checkmark.circle"
        case .turnOnFailure:
            "exclamationmark.circle"
        case .turnOff:
            "power"
        case .guardianTap:
            "hand.tap"
        }
    }

    var feedback: ProtectionHapticFeedback {
        switch self {
        case .turnOnSuccess:
            .protectionOnSucceeded
        case .turnOnFailure:
            .protectionStartFailed
        case .turnOff:
            .protectionTurnedOff
        case .guardianTap:
            .guardianTapAcknowledged
        }
    }
}


private extension QAInternetNetworkCondition {
    var qaSystemImage: String {
        switch self {
        case .cellularHandover:
            "antenna.radiowaves.left.and.right"
        case .wifiToCellularSwitch:
            "wifi.slash"
        case .cellularToWifiSwitch:
            "wifi"
        case .flappingEdgeWifi:
            "wifi.exclamationmark"
        case .sameSSIDRoaming:
            "dot.radiowaves.left.and.right"
        case .wifiInternetBlackhole:
            "wifi.slash"
        case .airplaneModeRecovery:
            "airplane"
        case .elevatorSignalLoss:
            "arrow.up.and.down"
        case .deprioritizedLowBandwidth:
            "speedometer"
        case .lowDataModeConstrained:
            "arrow.down.circle"
        case .ipv6OnlyNAT64:
            "network"
        case .mtuDoQFragmentation:
            "bolt.horizontal.icloud"
        case .captivePortalRejoin:
            "network.badge.shield.half.filled"
        }
    }
}

private extension QAInternetDNSSetup {
    var qaSystemImage: String {
        switch transport {
        case .deviceDNS:
            "iphone.gen3.radiowaves.left.and.right"
        case .plainDNS:
            "network"
        case .dnsOverHTTPS:
            "lock.icloud"
        case .dnsOverTLS:
            "lock.shield"
        case .dnsOverQUIC:
            "bolt.horizontal.icloud"
        }
    }
}

private extension AdminQAAction {
    var qaSystemImage: String {
        switch self {
        case .showWelcome:
            "sparkles"
        case .showUserBugReport:
            "ladybug"
        case .applyHostedProbes:
            "testtube.2"
        case .testDefaultAllow:
            "checkmark.seal"
        case .testAllowlist:
            "checkmark.circle"
        case .testDenylist:
            LavaOutcomeSymbol.blocked
        case .testThreatGuardrail:
            "exclamationmark.shield"
        case .setGoogleDNS:
            "network"
        case .setCloudflareDoH:
            "lock.icloud"
        case .setCloudflareDoT:
            "lock.shield"
        case .enableLocalDomainHistory:
            "clock.badge.checkmark"
        case .disableLocalDomainHistory:
            "clock.badge.xmark"
        case .clearLocalActivity:
            "trash"
        case .setPaidPlan:
            "creditcard"
        case .setFreePlan:
            "person.crop.circle"
        case .clearQAState:
            "xmark.circle"
        }
    }
}

private extension AdminQAVPNProfileAction {
    var qaSystemImage: String {
        switch self {
        case .installProfile:
            "plus.circle"
        case .removeProfile:
            "minus.circle"
        case .resetProfile:
            "arrow.clockwise.circle"
        }
    }
}


/// Native-only configuration buffer with clipboard and late-input admission.
/// Fabric receives the visit ID and a Boolean readiness projection, never keys.
@objc(LavaQAConfigurationContent)
@MainActor
final class LavaQAConfigurationContent: UIView, UITextViewDelegate {
    private let textView = LavaQAConfigurationTextView()
    private weak var owner: LavaQASession?
    private var changes: AnyCancellable?
    private var observers = Set<AnyCancellable>()
    override init(frame: CGRect) {
        super.init(frame: frame)
        textView.delegate = self
        textView.backgroundColor = .systemBackground
        textView.autocorrectionType = .no; textView.autocapitalizationType = .none
        textView.font = .monospacedSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .footnote).pointSize, weight: .regular)
        textView.adjustsFontForContentSizeCategory = false
        textView.layer.cornerRadius = 8; textView.layer.borderWidth = 1
        textView.layer.borderColor = UIColor.secondaryLabel.withAlphaComponent(0.3).cgColor
        textView.accessibilityLabel = "WireGuard configuration".lavaLocalized
        textView.mayInteract = { [weak self] in self?.window != nil && self?.owner?.current == true }
        addSubview(textView)
        let bridge = LavaAppBridge.shared
        for publisher in [bridge.objectWillChange, bridge.security.objectWillChange] {
            publisher.sink { [weak self] _ in DispatchQueue.main.async { self?.refresh() } }.store(in: &observers)
        }
        for notification in [UIApplication.willResignActiveNotification, UIApplication.protectedDataWillBecomeUnavailableNotification] {
            NotificationCenter.default.publisher(for: notification).sink { [weak self] _ in
                MainActor.assumeIsolated {
                    if bridge.security.backgroundPrivacyCoverRequired { self?.textView.isHidden = true }
                }
            }.store(in: &observers)
        }
        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification).sink { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }.store(in: &observers)
    }
    required init?(coder: NSCoder) { nil }
    @objc(configureWithOwnerID:fontSize:)
    func configure(ownerID: String, fontSize: Double) {
        textView.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let next = LavaAppBridge.shared.qaSession
        guard let next, next.id == ownerID, !next.retired else { resetForRecycle(); return }
        if owner !== next {
            resetForRecycle(); owner = next
            changes = next.objectWillChange.sink { [weak self] _ in DispatchQueue.main.async { self?.refresh() } }
        }
        refresh()
    }
    private func refresh() {
        guard let owner, !owner.retired, LavaAppBridge.shared.qaSession === owner else { resetForRecycle(); return }
        let authorized = owner.current
        let retainInactive = UIApplication.shared.applicationState != .active && !LavaAppBridge.shared.security.backgroundPrivacyCoverRequired
        textView.isHidden = !authorized && !retainInactive
        textView.accessibilityElementsHidden = !authorized
        if authorized, textView.text != owner.chainedUpstreamConf { textView.text = owner.chainedUpstreamConf }
        textView.layer.borderColor = UIColor.secondaryLabel.withAlphaComponent(0.3).cgColor
    }
    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool { owner?.current == true }
    func textViewDidChange(_ textView: UITextView) {
        guard let owner, owner.current else { refresh(); return }
        owner.chainedUpstreamConf = textView.text; owner.changed()
    }
    override func didMoveToWindow() { super.didMoveToWindow(); refresh() }
    override func layoutSubviews() { super.layoutSubviews(); textView.frame = bounds }
    @objc func resetForRecycle() {
        changes?.cancel(); changes = nil; owner = nil
        textView.text = ""; textView.isHidden = true
    }
}
@MainActor private final class LavaQAConfigurationTextView: UITextView {
    var mayInteract: (() -> Bool)?
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        mayInteract?() == true && super.point(inside: point, with: event)
    }
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        mayInteract?() == true && super.canPerformAction(action, withSender: sender)
    }
}

#else
// MARK: - Inert Release QA configuration leaf
// Fabric registers this component in every RN build. Release keeps only its
// Objective-C surface; visits, confidential input and QA services stay gated.
// pinned: ReleaseGateSourceTests.testReleaseQAConfigurationLeafHasOnlyInertFabricInterface
@objc(LavaQAConfigurationContent)
@MainActor
final class LavaQAConfigurationContent: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
    }
    required init?(coder: NSCoder) { nil }
    @objc(configureWithOwnerID:fontSize:)
    func configure(ownerID: String, fontSize: Double) {}
    @objc func resetForRecycle() {}
}
#endif

extension LavaAppBridge {
    private func qaSurface(for id: String) -> SecurityProtectedSurface {
        // Rage-shake's native developer gate historically required App Unlock;
        // the pushed Settings destination retains its stronger settings turn.
        flow?.id.uuidString == id && flow?.name == "phoneQASheet" ? .appUnlock : .appSettings
    }
    func retireQASession(id: String) {
        #if DEBUG || LAVA_QA_TOOLS
        LavaQAVisitAdmissions.lifetime.retire(id: id)
        if let owner = qaSession, owner.id == id { owner.retire(); qaSession = nil }
        #endif
    }
    func retireQAForNewFlow(id: String) {
        #if DEBUG || LAVA_QA_TOOLS
        LavaQAVisitAdmissions.lifetime.retireSuperseded(by: id)
        if let owner = qaSession, owner.id != id { owner.retire(); qaSession = nil }
        #endif
    }
    func qaProjection() -> [String: Any]? {
        #if DEBUG || LAVA_QA_TOOLS
        guard let qaSession, qaSession.current else { return nil }
        return qaSession.projection()
        #else
        return nil
        #endif
    }
    func qaCommand(_ input: [String: Any]) async throws -> Any {
        #if DEBUG || LAVA_QA_TOOLS
        guard let id = input["id"] as? String, let action = input["action"] as? String else { throw CommandError("Invalid app command.") }
        // Route teardown is local cleanup. Reauthentication must not retain a
        // closed route's confidential editor or allow its late enter to recreate it.
        if action == "leave" || action == "close" {
            retireQASession(id: id)
            if action == "close", flow?.id.uuidString == id { flow = nil }
            return NSNull()
        }
        if action == "detail.close" || action == "detail.back" {
            guard let owner = qaSession, owner.id == id, !owner.retired,
                  owner.admits(action, input: input) else { throw CommandError("Read access changed.") }
            owner.dismissDetail(back: action == "detail.back")
            publish()
            return NSNull()
        }
        let ownerBeforeAuthentication = qaSession
        let surface = ownerBeforeAuthentication?.surface ?? qaSurface(for: id)
        let ticket: Int?
        if action == "enter" {
            guard let next = LavaQAVisitAdmissions.lifetime.requestEntry(id: id) else { throw CommandError("Read access changed.") }
            ticket = next
        } else {
            ticket = nil
            guard let ownerBeforeAuthentication, ownerBeforeAuthentication.id == id,
                  !ownerBeforeAuthentication.retired, ownerBeforeAuthentication.admits(action, input: input) else { throw CommandError("Read access changed.") }
        }
        try await authorize(surface, surface == .appSettings ? "Open Device QA settings" : "Unlock Lava")
        guard UIApplication.shared.applicationState == .active, canReadPresentation(surface),
              qaSession === ownerBeforeAuthentication else { throw CommandError("Read access changed.") }
        if action == "enter" {
            guard let ticket, LavaQAVisitAdmissions.lifetime.admit(id: id, ticket: ticket) else { throw CommandError("Read access changed.") }
            if qaSession == nil {
                qaSession = LavaQASession(id: id, viewModel: model, surface: surface,
                    showWelcome: flow?.id.uuidString == id ? flow?.showWelcome ?? { UserDefaults.standard.set(false, forKey: "hasSeenLavaOnboarding") } : { UserDefaults.standard.set(false, forKey: "hasSeenLavaOnboarding") },
                    showUserBugReport: { [weak self] in
                        guard let self else { return }
                        if self.flow?.id.uuidString == id, self.flow?.name == "phoneQASheet" { self.flow = LavaAppNativeFlow(name: "feedback") }
                        else { self.model.reports.rageShakeDestination = .bugReport }
                    })
            }
            return NSNull()
        }
        guard let owner = qaSession, owner.id == id, owner.current else { throw CommandError("Read access changed.") }
        guard owner.admits(action, input: input) else { throw CommandError("Read access changed.") }
        await owner.command(action, input)
        return NSNull()
        #else
        throw CommandError("Unknown native flow.")
        #endif
    }
    func presentQAMockOnboarding() {
        #if DEBUG || LAVA_QA_TOOLS
        guard let qaSession, qaSession.current, let root = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).flatMap(\.windows).first(where: \.isKeyWindow)?.rootViewController else { return }
        var top = root; while let next = top.presentedViewController { top = next }
        let controller = UIHostingController(rootView: LavaAppHost(onboardingPreview: true)
            .modifier(LavaQAMockProtectionMask())
            .environmentObject(security)
            .preferredColorScheme(model.customization.preferredColorScheme)
            .lavaTextSizeOverride(model.customization.textSizeOverride))
        controller.modalPresentationStyle = .fullScreen; top.present(controller, animated: true)
        #endif
    }
}

#if DEBUG || LAVA_QA_TOOLS
/// Native presentation/privacy containment around the existing RN onboarding preview.
private struct LavaQAMockProtectionMask: ViewModifier {
    @EnvironmentObject private var security: SecurityController
    func body(content: Content) -> some View {
        content.overlay {
            if security.isAppUnlockBlockingUI || security.isAppUnlockPrivacyMaskVisible {
                LavaSheetLockMask(unlock: { Task { await security.authenticateAppUnlockIfNeeded() } })
            }
        }
    }
}
#endif
