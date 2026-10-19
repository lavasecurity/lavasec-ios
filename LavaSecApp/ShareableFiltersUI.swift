import SwiftUI
import LavaSecKit
import LavaSecAppServices
import PhotosUI
@preconcurrency import AVFoundation
import CoreImage.CIFilterBuiltins
import UIKit

// MARK: - Import result

enum ShareableFilterImportResult: Equatable {
    case success(ruleCount: Int)
    case failure(message: String)
}

// MARK: - QR code generation

enum LavaQRCode {
    /// Points drawn per module, so a caller holding only the image can recover the
    /// module count — and therefore the quiet zone the code needs around it.
    static let pointsPerModule: CGFloat = 12

    /// The image's width in modules, INCLUDING the one-module border
    /// `CIQRCodeGenerator` draws inside its own output.
    ///
    /// Read from the image rather than looked up from the QR version tables, because
    /// the version depends on the payload and the correction level that happened to
    /// fit. The shortest real Lava link is a 37-module symbol, whose modules are
    /// fatter — and so need a wider quiet zone — than the 45-module case this card
    /// was first reasoned about.
    static func moduleCount(of image: UIImage) -> CGFloat {
        max(1, (image.size.width / pointsPerModule).rounded())
    }

    /// Renders `string` as a crisp (non-interpolated) QR image suitable for
    /// on-screen display. Returns `nil` only if Core Image cannot build the code —
    /// which, for a fixed `correctionLevel`, means the payload exceeds what that
    /// level can carry. Callers step the level down rather than shorten the payload.
    static func image(
        for string: String,
        scale: CGFloat = LavaQRCode.pointsPerModule,
        correctionLevel: String = "M"
    ) -> UIImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = correctionLevel

        guard let output = filter.outputImage else {
            return nil
        }

        let transformed = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cgImage = context.createCGImage(transformed, from: transformed.extent) else {
            return nil
        }

        return UIImage(cgImage: cgImage)
    }
}

// MARK: - Share my filters

/// A contextual share request keeps the saved identity independent of the current filter.
enum ImportFiltersStartMode {
    case chooseMethod
    case enterCode
    case scanCode
    /// Opens directly at the review for a configuration a Universal Link already
    /// carried. The payload is only ever held for the life of this presentation —
    /// it is never persisted, and never queued across onboarding.
    case review(ShareableFilterConfiguration)
}

/// The native flow retains only the already-committed result across privacy
/// teardown. Input, decoded content and scanner state belong to the native import visit.
@MainActor
final class ImportFiltersCompletion: ObservableObject {
    @Published private(set) var filterName: String?
    private(set) var unavailableListCount = 0
    private var acknowledged = false

    func recordCommittedFilter(named name: String, unavailableListCount: Int = 0) {
        guard filterName == nil else { return }
        // Visiting or recreating a presentation is silent. Claim feedback only
        // at the retained owner's actual commit, never in its initializer.
        let feedbackID = LavaFeedbackCoordinator.shared.begin("filter.import")
        self.unavailableListCount = unavailableListCount
        filterName = name
        // This retained commit owner survives privacy teardown; restored screen appearance is silent.
        LavaFeedbackCoordinator.shared.finish("filter.import", feedbackID, .succeeded)
    }

    func acknowledge() -> Bool {
        guard filterName != nil, !acknowledged else { return false }
        acknowledged = true
        return true
    }
}

final class QRScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onScan: ((String) -> Bool)?
    var onAttemptBegan: (() -> Void)?
    private var attempt = QRScanAttempt()
    private var presentationIsVisible = false
    var onCameraAuthorizationDenied: (() -> Void)?

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "app.lavasecurity.qrscanner.session")
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var captureDevice: AVCaptureDevice?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configureSession()

        // Tap anywhere to refocus — useful when the phone parks focus on the
        // wrong plane while the QR is held close.
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTapToFocus(_:)))
        view.addGestureRecognizer(tap)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        resumeCaptureIfVisible()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        suspendCapture()
    }

    /// Fabric containment can remove a camera island without a navigation
    /// transition. Its actual window lifetime independently owns capture.
    func resumeCaptureIfVisible() {
        guard !presentationIsVisible, isViewLoaded, view.window != nil else { return }
        presentationIsVisible = true
        attempt.appear(active: UIApplication.shared.applicationState == .active)
        onAttemptBegan?()
        unregisterAppActivityObservers()
        registerAppActivityObservers()
        startSessionIfNeeded()
    }

    func suspendCapture() {
        presentationIsVisible = false
        attempt.disappear()
        unregisterAppActivityObservers()
        stopSession()
    }

    func retireCapture() {
        suspendCapture()
        onScan = nil; onAttemptBegan = nil; onCameraAuthorizationDenied = nil
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Power the capture session down whenever the app leaves the active state —
    /// app switcher (`.inactive`) or background — and bring it back on return.
    /// `viewWillDisappear` only fires on real navigation, not on resign-active, so
    /// without this the camera keeps running in the app switcher, including when
    /// Security choices require no `LavaPrivacyShield`. Restart re-checks camera
    /// authorization independently of snapshot concealment.
    private func registerAppActivityObservers() {
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(appWillResignActive),
            name: UIApplication.willResignActiveNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(appDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    private func unregisterAppActivityObservers() {
        let center = NotificationCenter.default
        center.removeObserver(self, name: UIApplication.willResignActiveNotification, object: nil)
        center.removeObserver(self, name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    @objc private func appWillResignActive() {
        attempt.setActive(false)
        stopSession()
    }

    @objc private func appDidBecomeActive() {
        attempt.setActive(true)
        startSessionIfNeeded()
    }

    private func stopSession() {
        nonisolated(unsafe) let session = self.session
        sessionQueue.async {
            if session.isRunning {
                session.stopRunning()
            }
        }
    }

    private func configureSession() {
        guard let device = Self.bestAvailableCaptureDevice(),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input)
        else {
            return
        }

        session.beginConfiguration()

        // 1080p gives QR detection more pixels to work with for dense codes.
        if session.canSetSessionPreset(.hd1920x1080) {
            session.sessionPreset = .hd1920x1080
        }

        session.addInput(input)
        captureDevice = device
        configureContinuousFocus(for: device)

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            return
        }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]

        session.commitConfiguration()

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        view.layer.addSublayer(preview)
        previewLayer = preview
    }

    /// Prefer a multi-lens virtual device so the system can switch between lenses
    /// (e.g. to the ultra-wide) to keep a close-held QR in focus. Falls back to
    /// the plain wide-angle camera, then any default video device.
    private static func bestAvailableCaptureDevice() -> AVCaptureDevice? {
        let preferredTypes: [AVCaptureDevice.DeviceType] = [
            .builtInTripleCamera,
            .builtInDualWideCamera,
            .builtInDualCamera,
            .builtInWideAngleCamera
        ]
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: preferredTypes,
            mediaType: .video,
            position: .back
        )
        for type in preferredTypes {
            if let match = discovery.devices.first(where: { $0.deviceType == type }) {
                return match
            }
        }
        return AVCaptureDevice.default(for: .video)
    }

    /// Continuous autofocus biased toward near subjects (QR codes are usually
    /// held close), with continuous auto-exposure.
    private func configureContinuousFocus(for device: AVCaptureDevice) {
        guard (try? device.lockForConfiguration()) != nil else {
            return
        }
        defer { device.unlockForConfiguration() }

        if device.isFocusModeSupported(.continuousAutoFocus) {
            device.focusMode = .continuousAutoFocus
        }
        if device.isAutoFocusRangeRestrictionSupported {
            device.autoFocusRangeRestriction = .near
        }
        if device.isExposureModeSupported(.continuousAutoExposure) {
            device.exposureMode = .continuousAutoExposure
        }
    }

    @objc private func handleTapToFocus(_ gesture: UITapGestureRecognizer) {
        guard let device = captureDevice, let previewLayer else {
            return
        }

        let layerPoint = gesture.location(in: view)
        let focusPoint = previewLayer.captureDevicePointConverted(fromLayerPoint: layerPoint)

        guard device.isFocusPointOfInterestSupported || device.isExposurePointOfInterestSupported,
              (try? device.lockForConfiguration()) != nil
        else {
            return
        }
        defer { device.unlockForConfiguration() }

        if device.isFocusPointOfInterestSupported {
            device.focusPointOfInterest = focusPoint
            device.focusMode = device.isFocusModeSupported(.continuousAutoFocus) ? .continuousAutoFocus : .autoFocus
        }
        if device.isExposurePointOfInterestSupported {
            device.exposurePointOfInterest = focusPoint
            device.exposureMode = device.isExposureModeSupported(.continuousAutoExposure) ? .continuousAutoExposure : .autoExpose
        }
    }

    private func startSessionIfNeeded() {
        let generation = attempt.generation
        guard attempt.permitsDelivery(generation: generation) else { return }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            startRunning()
        case .notDetermined:
            Task { @MainActor [weak self] in
                let granted = await AVCaptureDevice.requestAccess(for: .video)
                guard let self, self.attempt.permitsDelivery(generation: generation) else { return }
                if granted {
                    self.startRunning()
                } else {
                    self.onCameraAuthorizationDenied?()
                }
            }
        default:
            // Denied or restricted — surface a recovery path instead of a black frame.
            onCameraAuthorizationDenied?()
        }
    }

    private func startRunning() {
        guard attempt.permitsDelivery(generation: attempt.generation) else { return }
        nonisolated(unsafe) let session = self.session
        sessionQueue.async {
            guard !session.isRunning else {
                return
            }
            session.startRunning()
        }
    }

    nonisolated func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        // The delegate is installed on .main. Deliver synchronously so a queued
        // actor task cannot outlive navigation and claim a later visible attempt.
        guard let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let value = object.stringValue else { return }
        MainActor.assumeIsolated {
            let callback = onScan
            let generation = attempt.generation
            // The navigation callback may synchronously change visibility. Mutate
            // a value copy, then publish only while this attempt still owns it.
            var next = attempt
            let accepted = next.receive(value, generation: generation) { callback?($0) ?? false }
            if attempt.generation == generation { attempt = next }
            if accepted { stopSession() }
        }
    }
}

// MARK: Error copy

enum ShareableFilterImportMessages {
    static func message(for error: Error) -> String {
        // The link parser wraps code errors rather than replacing them. Unwrap, or
        // every scan of an edited code would degrade to the generic message and
        // lose the one instruction that helps: ask for a fresh one.
        if let inputError = error as? ShareableFilterInputError {
            switch inputError {
            case .unrecognizedFormat, .invalidUniversalLink:
                return "That doesn't look like a Lava filter code."
            case .configurationCode(let codeError):
                return message(forCode: codeError)
            }
        }

        guard let codeError = error as? ShareableFilterConfigurationCodeError else {
            return "That code couldn't be read. Double-check it and try again."
        }
        return message(forCode: codeError)
    }

    private static func message(forCode codeError: ShareableFilterConfigurationCodeError) -> String {
        switch codeError {
        case .unrecognizedFormat:
            return "That doesn't look like a Lava filter code."
        case .integrityCheckFailed:
            return "This code looks edited or incomplete. Ask for a fresh one."
        case .unsupportedVersion:
            return "This code needs a newer version of Lava. Update the app and try again."
        case .malformedPayload:
            return "That code couldn't be read. Double-check it and try again."
        case .payloadTooLarge:
            return "This code is too large to import safely."
        }
    }
}
