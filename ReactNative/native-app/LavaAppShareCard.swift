import Foundation
import UIKit
import LavaSecKit
import LavaSecAppServices
#if DEBUG && targetEnvironment(simulator)
import CryptoKit
#endif

/// One bounded export grant, distinct from the snapshot revision (ordinary
/// telemetry publications must not invalidate an otherwise unchanged card).
@MainActor
final class LavaShareCardAuthority {
    struct Basis: Equatable {
        let owner: ObjectIdentifier
        let filterID: String
        let configurationCode: String
        let payload: String
        let labels: [String]
        let securityRevision: UInt64
        let foregroundEpoch: UInt64
        let moduleEpoch: UInt64
    }
    struct Grant: Equatable { let token: String; let basis: Basis }
    private(set) var grant: Grant?
    func issue(_ basis: Basis) -> Grant {
        if let grant, grant.basis == basis { return grant }
        let fresh = Grant(token: UUID().uuidString, basis: basis)
        grant = fresh
        return fresh
    }
    func admits(token: String, basis: Basis) -> Bool {
        grant?.token == token && grant?.basis == basis
    }
    func retire() { grant = nil }
}

#if DEBUG && targetEnvironment(simulator)
/// Opt-in evidence for an owned disposable UI-test Simulator. This observes the
/// real chooser cancellation; it does not capture, authorize or compose a card.
@MainActor
final class LavaShareCardUITestEvidence {
    static let launchArgument = "-LavaUITestRetainShareCardPNG"
    static let directoryName = "LavaUITestShareCardEvidence"
    static let receiptFilename = "receipt.json"
    static let shared = LavaShareCardUITestEvidence(
        enabled: ProcessInfo.processInfo.arguments.contains(launchArgument),
        cacheDirectory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first)

    struct ImageReceipt: Codable, Equatable {
        let sequence: Int
        let filename: String
        let width: Int
        let height: Int
        let sha256: String
    }
    struct Receipt: Codable, Equatable {
        let formatVersion: Int
        let images: [ImageReceipt]
    }
    private enum Refusal: Error { case invalidImage, unavailableCache }
    private let enabled: Bool
    private let directory: URL?
    private var started = false
    private var images: [ImageReceipt] = []

    // Native fixture seam only. The shipping destination comes exclusively from
    // the app's private Caches directory, never a command/JS-supplied path.
    init(enabled: Bool, cacheDirectory: URL?) {
        self.enabled = enabled
        directory = cacheDirectory?.appendingPathComponent(Self.directoryName, isDirectory: true)
    }
    func completion(for image: UIImage, isCurrent: @escaping () -> Bool) -> ((ShareSheetPresenter.Outcome) -> Void)? {
        guard enabled else { return nil }
        var settled = false
        return { [weak self] outcome in
            guard !settled else { return }
            settled = true
            guard case .cancelled = outcome, let self else { return }
            do { try self.retainCancelled(image, isCurrent: isCurrent) }
            catch {
                // An absent receipt/image is failed evidence. Collection must
                // require both entries; fixture IO must not alter a user's share result.
            }
        }
    }
    private func retainCancelled(_ image: UIImage, isCurrent: () -> Bool) throws {
        guard images.count < 2, isCurrent() else { return }
        guard image.imageOrientation == .up, let pixels = image.cgImage,
              pixels.width == 1080, pixels.height == 1350,
              let data = image.pngData() else { throw Refusal.invalidImage }
        guard isCurrent() else { return }
        guard let directory else { throw Refusal.unavailableCache }
        let files = FileManager.default
        if !started {
            // Discard only our own prior opt-in evidence, so a fresh process
            // cannot accept old files as its first successful cancellation.
            if files.fileExists(atPath: directory.path) { try files.removeItem(at: directory) }
            try files.createDirectory(at: directory, withIntermediateDirectories: true)
            started = true
        }
        let sequence = images.count + 1
        let entry = ImageReceipt(sequence: sequence, filename: "share-card-\(sequence).png",
            width: pixels.width, height: pixels.height,
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
        let imageURL = directory.appendingPathComponent(entry.filename)
        do {
            try data.write(to: imageURL, options: [.atomic, .completeFileProtection])
            guard isCurrent() else {
                try files.removeItem(at: imageURL)
                return
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let receipt = try encoder.encode(Receipt(formatVersion: 1, images: images + [entry]))
            try receipt.write(to: directory.appendingPathComponent(Self.receiptFilename),
                options: [.atomic, .completeFileProtection])
            images.append(entry)
        } catch {
            try? files.removeItem(at: imageURL)
            throw error
        }
    }
}
#endif

extension LavaAppBridge {
    /// Native owns the immutable aggregate snapshot; JavaScript supplies no counts or image URI.
    struct ActivityShareGrant {
        let token: String
        let payload: String
        let scope: PresentationCacheScope
        let securityRevision: UInt64
        let foregroundEpoch: UInt64
        let moduleEpoch: UInt64
        let clearGeneration: UInt64
    }

    private func admitsActivityShare(_ grant: ActivityShareGrant) -> Bool {
        let scope = presentationScope("activity.query", [:])
        return activityShareGrant?.token == grant.token
            && canReadPresentation(.activityViewing) && canReadPresentation(.appUnlock)
            && !security.isAuthenticationUnavailable && !security.isAppUnlockBlockingUI
            && !security.isAppUnlockPrivacyMaskVisible && security.passcodeAuthenticationRequest == nil
            && scope.owner == grant.scope.owner && scope.logPolicy == grant.scope.logPolicy
            && security.viewAuthenticationRevision == grant.securityRevision
            && shareCardForegroundEpoch == grant.foregroundEpoch && shareCardModuleEpoch == grant.moduleEpoch
            && presentationDisplayClearGeneration == grant.clearGeneration
    }

    func activityShareQuery(_ input: [String: Any]) throws -> [String: Any] {
        guard let startValue = input["start"] as? Double, startValue.isFinite,
              let endValue = input["end"] as? Double, endValue.isFinite,
              let chart = input["chart"] as? String, ["total", "counts", "rate"].contains(chart),
              let period = input["period"] as? String, ["today", "week", "month", "custom"].contains(period) else {
            throw CommandError("Choose a valid date range.")
        }
        let start = Date(timeIntervalSince1970: startValue / 1000), end = Date(timeIntervalSince1970: endValue / 1000)
        guard end >= start, (Calendar.current.dateComponents([.day], from: start, to: end).day ?? Int.max) <= 731 else {
            throw CommandError("Choose a shorter date range.")
        }
        let payload = "https://apps.apple.com/app/lava-security/id6778022110"
        guard let matrix = LavaShareQrMatrix.encode(payload) else { throw CommandError("Please wait a moment and try again.") }
        let summary = model.reports.diagnostics.rangeSummary(from: start, to: end)
        let hourly = input["hourly"] as? Bool == true && Calendar.current.isDate(start, inSameDayAs: end)
        let locale = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")
        let buckets = model.reports.diagnostics.activityBuckets(from: start, to: end, hourly: hourly).map { bucket -> [String: Any] in
            ["start": bucket.start.timeIntervalSince1970 * 1000,
             "label": hourly ? bucket.start.formatted(.dateTime.hour().minute().locale(locale)) : bucket.start.formatted(.dateTime.month(.abbreviated).day().locale(locale)),
             "allowed": bucket.allowed, "blocked": bucket.blocked, "available": bucket.available, "partial": bucket.partial]
        }
        let startLabel = start.formatted(.dateTime.year().month(.wide).day().locale(locale))
        let endLabel = end.formatted(.dateTime.year().month(.wide).day().locale(locale))
        let grant = ActivityShareGrant(token: UUID().uuidString, payload: payload,
            scope: presentationScope("activity.query", [:]), securityRevision: security.viewAuthenticationRevision,
            foregroundEpoch: shareCardForegroundEpoch, moduleEpoch: shareCardModuleEpoch,
            clearGeneration: presentationDisplayClearGeneration)
        shareCardAuthority.retire()
        activityShareGrant = grant
        guard admitsActivityShare(grant) else { activityShareGrant = nil; throw CommandError("Read access changed.") }
        LavaShareCardSurfaceRegistry.shared.reauthorize = { [weak self] token in
            guard let self, let current = self.activityShareGrant, current.token == token,
                  self.admitsActivityShare(current) else { return nil }
            return current.payload
        }
        LavaShareCardSurfaceRegistry.shared.authorize(token: grant.token, payload: payload)
        return ["token": grant.token, "payload": payload, "moduleCount": matrix.moduleCount,
                "chart": chart, "period": period, "startLabel": startLabel, "endLabel": endLabel,
                "dateLabel": startLabel == endLabel ? startLabel : startLabel + " – " + endLabel,
                "allowed": summary.allowedCount, "blocked": summary.blockedCount,
                "uptime": summary.compactLocalProtectionUptimeText, "buckets": buckets]
    }

    func shareActivityCard(_ input: [String: Any]) throws {
        guard let grant = activityShareGrant, input["token"] as? String == grant.token,
              admitsActivityShare(grant) else { throw CommandError("Read access changed.") }
        let image: UIImage
        do {
            image = try LavaShareCardSurfaceRegistry.shared.capture(token: grant.token, payload: grant.payload,
                isCurrent: { self.admitsActivityShare(grant) })
        } catch { throw CommandError("Please wait a moment and try again.") }
        guard admitsActivityShare(grant) else { throw CommandError("Read access changed.") }
        #if DEBUG && targetEnvironment(simulator)
        ShareSheetPresenter.present(image: image, title: "See my activity on Lava Security".lavaLocalized,
            onComplete: LavaShareCardUITestEvidence.shared.completion(for: image,
                isCurrent: { self.admitsActivityShare(grant) }))
        #else
        ShareSheetPresenter.present(image: image, title: "See my activity on Lava Security".lavaLocalized)
        #endif
    }

    func shareCardContentChanged(_ library: FilterLibrary) {
        guard let grant = shareCardAuthority.grant else { return }
        guard let filter = library.filter(id: grant.basis.filterID),
              ShareableFilterConfiguration(filter: filter).encodedConfigurationCode() == grant.basis.configurationCode else {
            shareCardAuthority.retire()
            LavaShareCardSurfaceRegistry.shared.retire()
            return
        }
    }
    func shareCardSecurityChanged(revision: UInt64) {
        if let grant = activityShareGrant, grant.securityRevision != revision {
            activityShareGrant = nil
            LavaShareCardSurfaceRegistry.shared.retire()
        }
        guard let grant = shareCardAuthority.grant, grant.basis.securityRevision != revision else { return }
        shareCardAuthority.retire()
        LavaShareCardSurfaceRegistry.shared.retire()
    }
    func shareCardPrivacyChanged(isBlocked: Bool) {
        guard isBlocked else { return }
        activityShareGrant = nil
        shareCardAuthority.retire()
        LavaShareCardSurfaceRegistry.shared.retire()
    }
    private var shareCardPrivacyAllowsExport: Bool {
        canReadPresentation(.appUnlock) && canReadPresentation(.filterEditing)
            && !security.isAuthenticationUnavailable
            && !security.isAppUnlockBlockingUI && !security.isAppUnlockPrivacyMaskVisible
            && security.passcodeAuthenticationRequest == nil
    }
    private func shareCardBasis(for id: String) throws -> LavaShareCardAuthority.Basis {
        guard shareCardPrivacyAllowsExport, let filter = model.filter(id: id),
              model.isFilterShareable(filter) else { throw CommandError("This filter cannot be shared.") }
        let configuration = ShareableFilterConfiguration(filter: filter)
        let code = model.shareableFilterCode(for: filter)
        let payload = try ShareableFilterLink.url(forConfigurationCode: code).absoluteString
        return LavaShareCardAuthority.Basis(owner: ObjectIdentifier(model), filterID: id,
            configurationCode: code, payload: payload,
            labels: ShareableFilterCardSummary(configuration: configuration).chipLabels,
            securityRevision: security.viewAuthenticationRevision,
            foregroundEpoch: shareCardForegroundEpoch, moduleEpoch: shareCardModuleEpoch)
    }
    func shareCardQuery(_ input: [String: Any]) async throws -> [String: Any] {
        // Capture the module epoch only: a biometric prompt legitimately resigns
        // the app active while it is displayed, so the foreground epoch advances
        // even on a successful authorization. Pin the module retirement across
        // the suspension, then establish the foreground authority AFTER the
        // prompt returns — shareCardBasis' privacy gate already requires the app
        // to be active, and the basis binds the resulting (post-prompt) epoch.
        let module = shareCardModuleEpoch
        try await authorize(.filterEditing, "Share Filter", fresh: false)
        guard module == shareCardModuleEpoch,
              let id = input["id"] as? String else { throw CommandError("This filter cannot be shared.") }
        let basis = try shareCardBasis(for: id)
        let image = ShareableFilterCardRenderer.qrImage(for: basis.payload)?.pngData()
            .map { "data:image/png;base64," + $0.base64EncodedString() }
        var card: Any = NSNull()
        if let matrix = LavaShareQrMatrix.encode(basis.payload) {
            activityShareGrant = nil
            let grant = shareCardAuthority.issue(basis)
            // A transient screen unmount withdraws the registry entry, but it must
            // not kill the grant: the JS can remount the same token, and the next
            // query would otherwise mint a token the JS has not seen. The grant is
            // still retired by content, security, privacy, foreground and module
            // changes, so re-admitting it here cannot revive a stale card.
            LavaShareCardSurfaceRegistry.shared.reauthorize = { [weak self] token in
                guard let self, let current = self.shareCardAuthority.grant,
                      current.token == token else { return nil }
                return current.basis.payload
            }
            LavaShareCardSurfaceRegistry.shared.authorize(token: grant.token, payload: basis.payload)
            card = ["token": grant.token, "payload": basis.payload,
                    "moduleCount": matrix.moduleCount, "labels": basis.labels] as [String: Any]
        } else {
            shareCardAuthority.retire()
            LavaShareCardSurfaceRegistry.shared.retire()
        }
        return ["code": basis.configurationCode, "url": basis.payload,
                "image": image as Any? ?? NSNull(), "card": card]
    }
    func shareMountedCard(_ input: [String: Any]) throws {
        guard let id = input["id"] as? String, let token = input["token"] as? String,
              let grant = shareCardAuthority.grant, grant.basis.filterID == id else {
            throw CommandError("This filter cannot be shared.")
        }
        func current() -> Bool {
            guard let basis = try? shareCardBasis(for: id) else { return false }
            return shareCardAuthority.admits(token: token, basis: basis)
        }
        guard current() else { throw CommandError("This filter cannot be shared.") }
        let image: UIImage
        do {
            image = try LavaShareCardSurfaceRegistry.shared.capture(token: token,
                payload: grant.basis.payload, isCurrent: current)
        } catch {
            throw CommandError("Please wait a moment and try again.")
        }
        guard current() else { throw CommandError("This filter cannot be shared.") }
        // Only the image captured from the mounted shared compositor crosses this
        // boundary. Commands cannot name a file/URI or supply another image.
        #if DEBUG && targetEnvironment(simulator)
        ShareSheetPresenter.present(image: image,
            onComplete: LavaShareCardUITestEvidence.shared.completion(for: image, isCurrent: current))
        #else
        ShareSheetPresenter.present(image: image)
        #endif
    }
    @objc func retireShareCards() {
        activityShareGrant = nil
        shareCardModuleEpoch &+= 1
        shareCardAuthority.retire()
        LavaShareCardSurfaceRegistry.shared.retire()
    }
    @objc func shareCardForegroundEnded() {
        activityShareGrant = nil
        shareCardForegroundEpoch &+= 1
        shareCardAuthority.retire()
        LavaShareCardSurfaceRegistry.shared.retire()
    }
}
