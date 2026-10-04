import XCTest
import UIKit
import Vision
import CoreML
import CoreImage.CIFilterBuiltins
import LavaSecKit
@testable import LavaSec
#if DEBUG && targetEnvironment(simulator)
import CryptoKit
#endif

/// Native QR/capture/authority evidence only. The sibling marker deliberately
/// proves capture includes mounted children; it is not a second card composer.
@MainActor
final class LavaRNShareCardTests: XCTestCase {
    private func basis(_ owner: NSObject, id: String = "saved", code: String = "code",
                       payload: String = "https://example.com/import", labels: [String] = ["1 blocklist"],
                       security: UInt64 = 3, foreground: UInt64 = 4, module: UInt64 = 5) -> LavaShareCardAuthority.Basis {
        .init(owner: ObjectIdentifier(owner), filterID: id, configurationCode: code,
            payload: payload, labels: labels, securityRevision: security,
            foregroundEpoch: foreground, moduleEpoch: module)
    }
    func testUnchangedQueryReusesOneGrantAndEveryAuthorityChangeRefusesTheOldToken() {
        let owner = NSObject(), other = NSObject(), authority = LavaShareCardAuthority()
        let original = basis(owner), grant = authority.issue(original)
        XCTAssertEqual(authority.issue(original), grant)
        XCTAssertTrue(authority.admits(token: grant.token, basis: original))
        XCTAssertFalse(authority.admits(token: "foreign", basis: original))
        for changed in [basis(other), basis(owner, id: "other"), basis(owner, code: "changed"),
                        basis(owner, payload: "https://example.com/changed"), basis(owner, labels: ["2 blocklists"]),
                        basis(owner, security: 6), basis(owner, foreground: 7), basis(owner, module: 8)] {
            XCTAssertFalse(authority.admits(token: grant.token, basis: changed))
            let replacement = authority.issue(changed)
            XCTAssertNotEqual(replacement.token, grant.token)
            XCTAssertFalse(authority.admits(token: grant.token, basis: original))
        }
    }
    func testRetirementCannotReviveAnIdenticalPayloadGrant() {
        let owner = NSObject(), authority = LavaShareCardAuthority()
        let live = basis(owner), old = authority.issue(live)
        authority.retire()
        XCTAssertFalse(authority.admits(token: old.token, basis: live))
        XCTAssertNil(authority.grant)
        XCTAssertNotEqual(authority.issue(live).token, old.token)
    }
    func testQrLevelsKeepTheWholePayloadAndAddExactlyFourQuietModules() throws {
        for (payload, level) in [("https://example.com/import?code=whole", "Q"),
                                 (String(repeating: "x", count: 2000), "M"),
                                 (String(repeating: "x", count: 2700), "L")] {
            let matrix = try XCTUnwrap(LavaShareQrMatrix.encode(payload))
            XCTAssertEqual(matrix.correctionLevel, level)
            let pixels = try XCTUnwrap(matrix.image(cellPixels: 4))
            XCTAssertEqual(pixels.width, (matrix.moduleCount + 8) * 4)
            XCTAssertEqual(pixels.height, pixels.width)
            XCTAssertEqual(try qrPayloads(in: pixels), [payload])
        }
        XCTAssertNil(LavaShareQrMatrix.encode(""))
        XCTAssertNil(LavaShareQrMatrix.encode(String(repeating: "x", count: 16_385)))
    }

    /// A separately reported decoder check, not a fallback for Vision. The
    /// standard Core Image reference and production pixels must each carry the
    /// complete corpus. This establishes Simulator support only when it runs.
    func testCoreImageDecoderReadsStandardReferenceAndProductionFullPayloads() throws {
        let context = CIContext(options: [.useSoftwareRenderer: true])
        let detector = try XCTUnwrap(CIDetector(ofType: CIDetectorTypeQRCode, context: context,
            options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]), "Core Image must provide its public QR detector.")
        for (payload, level) in [("https://example.com/import?code=whole", "Q"),
                                 (String(repeating: "x", count: 2000), "M"),
                                 (String(repeating: "x", count: 2700), "L")] {
            let generator = CIFilter.qrCodeGenerator()
            generator.message = Data(payload.utf8)
            generator.correctionLevel = level
            let output = try XCTUnwrap(generator.outputImage)
            // Core Image supplies one white module. Extend its white background
            // by three modules, then scale the standard generator directly.
            let extent = output.extent.insetBy(dx: -3, dy: -3)
            let reference = output.composited(over: CIImage(color: .white).cropped(to: extent))
                .transformed(by: CGAffineTransform(scaleX: 4, y: 4))
            let referencePixels = try XCTUnwrap(context.createCGImage(reference, from: reference.extent))
            let matrix = try XCTUnwrap(LavaShareQrMatrix.encode(payload))
            let productionPixels = try XCTUnwrap(matrix.image(cellPixels: 4))
            for (name, pixels) in [("standard Core Image", referencePixels), ("production matrix", productionPixels)] {
                let features = detector.features(in: CIImage(cgImage: pixels)).compactMap { $0 as? CIQRCodeFeature }
                XCTAssertEqual(features.count, 1, "\(name), complete \(payload.utf8.count)-byte payload")
                XCTAssertEqual(features.compactMap(\.messageString), [payload], name)
            }
        }
    }

    /// Decoder selection is explicit by build target, never by failure. The
    /// iOS 26.5 Simulator standalone Core Image corpus passed after its Vision
    /// CPU request returned no observations; those failed Vision runs remain
    /// separate evidence. Physical-device assertions still exercise Vision.
    private func qrPayloads(in pixels: CGImage) throws -> [String?] {
        #if targetEnvironment(simulator)
        let context = CIContext(options: [.useSoftwareRenderer: true])
        let detector = try XCTUnwrap(CIDetector(ofType: CIDetectorTypeQRCode, context: context,
            options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
        // Keep nil/foreign observations so the exact one-payload assertion
        // cannot silently drop any unexpected feature returned by the decoder.
        return detector.features(in: CIImage(cgImage: pixels)).map { ($0 as? CIQRCodeFeature)?.messageString }
        #else
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        try VNImageRequestHandler(cgImage: pixels).perform([request])
        return request.results?.map(\.payloadStringValue) ?? []
        #endif
    }
    private enum DisplayFailure: Error { case presentationTimedOut }
    /// Wait for the owned offscreen child in the app's existing visible window
    /// and two real display ticks. Never replace the hosted RN root controller.
    @MainActor private final class DisplayReadiness: NSObject {
        let window: UIWindow
        let card: UIView
        private var frames = 0
        private var completion: CheckedContinuation<Void, Error>?
        private var displayLink: CADisplayLink?
        private var timeout: Task<Void, Never>?
        init(window: UIWindow, card: UIView) { self.window = window; self.card = card; super.init() }
        func wait() async throws {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                    completion = continuation
                    let link = CADisplayLink(target: self, selector: #selector(displayed))
                    displayLink = link
                    link.add(to: .main, forMode: .common)
                    timeout = Task { @MainActor [weak self] in
                        do { try await Task.sleep(for: .seconds(5)) } catch { return }
                        self?.settle(.failure(DisplayFailure.presentationTimedOut))
                    }
                }
            } onCancel: {
                Task { @MainActor [weak self] in self?.settle(.failure(CancellationError())) }
            }
        }
        @objc private func displayed() {
            guard window.isKeyWindow, !window.isHidden,
                  window.windowScene?.activationState == .foregroundActive,
                  window.rootViewController?.viewIfLoaded?.window === window,
                  card.superview === window, card.window === window else { frames = 0; return }
            card.layoutIfNeeded()
            frames += 1
            if frames >= 2 { settle(.success(())) }
        }
        private func settle(_ result: Result<Void, Error>) {
            guard let completion else { return }
            self.completion = nil
            displayLink?.invalidate(); displayLink = nil
            timeout?.cancel(); timeout = nil
            completion.resume(with: result)
        }
    }
    private func displayedFixture() async throws -> Fixture {
        let fixture = try Fixture()
        do { try await fixture.waitForDisplay(); return fixture }
        catch { fixture.close(); throw error }
    }
    @MainActor private final class Fixture {
        let window: UIWindow
        private let existingRoot: ObjectIdentifier
        let card: UIView
        let qr: LavaShareQrContent
        let payload: String
        let matrix: LavaShareQrMatrix
        let registry = LavaShareCardSurfaceRegistry()
        let token = UUID().uuidString
        init() throws {
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .first { $0.activationState == .foregroundActive })
            payload = try ShareableFilterLink.url(forConfigurationCode:
                ShareableFilterConfiguration(enabledBlocklistIDs: ["oisd-small"],
                    blockedDomains: ["ads.example"], allowedDomains: ["trusted.example"]).encodedConfigurationCode()).absoluteString
            matrix = try XCTUnwrap(LavaShareQrMatrix.encode(payload))
            window = try XCTUnwrap(scene.windows.first { $0.isKeyWindow && !$0.isHidden })
            existingRoot = ObjectIdentifier(try XCTUnwrap(window.rootViewController))
            let scale = window.screen.scale
            card = UIView(frame: CGRect(x: -10_000, y: 0, width: 1080 / scale, height: 1350 / scale))
            card.backgroundColor = .white
            card.overrideUserInterfaceStyle = .light
            window.addSubview(card)
            let marker = UIView(frame: CGRect(x: 48 / scale, y: 24 / scale, width: 30 / scale, height: 30 / scale))
            marker.backgroundColor = .red
            card.addSubview(marker)
            let label = UILabel(frame: CGRect(x: 48 / scale, y: 72 / scale, width: 600 / scale, height: 80 / scale))
            label.text = "Mounted React sibling fixture"
            label.font = .systemFont(ofSize: 36 / scale)
            label.textColor = .black
            card.addSubview(label)
            let cell = 900 / (matrix.moduleCount + 8), side = (matrix.moduleCount + 8) * cell
            qr = LavaShareQrContent(frame: CGRect(x: CGFloat((1080 - side) / 2) / scale,
                y: 250 / scale, width: CGFloat(side) / scale, height: CGFloat(side) / scale))
            card.addSubview(qr)
            qr.configure(payload: payload, moduleCount: matrix.moduleCount)
            card.layoutIfNeeded(); qr.layoutIfNeeded(); qr.layer.displayIfNeeded()
            registry.authorize(token: token, payload: payload)
            registry.update(view: card, token: token, payload: payload, ready: true)
        }
        func waitForDisplay() async throws {
            try await DisplayReadiness(window: window, card: card).wait()
            card.layoutIfNeeded(); qr.layoutIfNeeded(); qr.layer.displayIfNeeded()
        }
        func close() {
            registry.remove(view: card); card.removeFromSuperview()
            XCTAssertTrue(window.isKeyWindow)
            XCTAssertFalse(window.isHidden)
            XCTAssertEqual(window.rootViewController.map(ObjectIdentifier.init), existingRoot,
                "Fixture cleanup must leave the hosted app's window/controller intact.")
        }
        func capture(isCurrent: () -> Bool = { true }) throws -> UIImage {
            do { return try registry.capture(token: token, payload: payload, isCurrent: isCurrent) }
            catch {
                if error as? LavaShareCardSurfaceRegistry.Refusal == .captureFailed {
                    // Only the owned fixture is captured for failure diagnosis.
                    // This is never an export, a replacement result, or a grant.
                    let format = UIGraphicsImageRendererFormat()
                    format.scale = window.screen.scale; format.opaque = true; format.preferredRange = .standard
                    var rendered = false
                    let diagnostic = UIGraphicsImageRenderer(size: card.bounds.size, format: format).image { _ in
                        rendered = card.drawHierarchy(in: card.bounds, afterScreenUpdates: true)
                    }
                    let matches = diagnostic.cgImage.map { qr.matchesCapturedPixels($0, in: card, scale: format.scale) } ?? false
                    let pointRect = qr.convert(qr.bounds, to: card)
                    let pixelRect = CGRect(x: pointRect.minX * format.scale, y: pointRect.minY * format.scale,
                        width: pointRect.width * format.scale, height: pointRect.height * format.scale)
                    let roundedRect = CGRect(x: pixelRect.minX.rounded(), y: pixelRect.minY.rounded(),
                        width: pixelRect.width.rounded(), height: pixelRect.height.rounded())
                    let cell = Int((qr.bounds.width * format.scale / CGFloat(matrix.moduleCount + 8)).rounded())
                    let rawCrop = diagnostic.cgImage?.cropping(to: pixelRect)
                    let roundedCrop = diagnostic.cgImage?.cropping(to: roundedRect)
                    XCTContext.runActivity(named: "Native fixture capture failure diagnostics, not export evidence") { activity in
                        func attach(_ pixels: UIImage, name: String) {
                            let image = XCTAttachment(image: pixels)
                            image.name = name
                            image.lifetime = .keepAlways; activity.add(image)
                        }
                        attach(diagnostic, name: "Owned native fixture failed snapshot")
                        if let expected = matrix.image(cellPixels: cell) {
                            attach(UIImage(cgImage: expected), name: "Owned native fixture expected QR pixels")
                        }
                        if let rawCrop {
                            attach(UIImage(cgImage: rawCrop), name: "Owned native fixture raw validation crop")
                        }
                        let geometry = "scale=\(format.scale) modules=\(matrix.moduleCount) cell=\(cell) pointRect=\(precise(pointRect)) pixelRect=\(precise(pixelRect))"
                        let crops = "rawCrop=\(size(rawCrop)) roundedCrop=\(size(roundedCrop)) rawStage=\(firstMismatch(rawCrop, cell: cell)) roundedStage=\(firstMismatch(roundedCrop, cell: cell))"
                        let state = XCTAttachment(string: "rendered=\(rendered) pixels=\(diagnostic.cgImage?.width ?? 0)x\(diagnostic.cgImage?.height ?? 0) qrPixelsMatch=\(matches)\n\(geometry)\n\(crops)")
                        state.lifetime = .keepAlways; activity.add(state)
                    }
                }
                throw error
            }
        }
        private func precise(_ rect: CGRect) -> String {
            [rect.minX, rect.minY, rect.width, rect.height].map { String(format: "%.17g", Double($0)) }.joined(separator: ",")
        }
        private func size(_ image: CGImage?) -> String {
            image.map { "\($0.width)x\($0.height)" } ?? "nil"
        }
        /// Diagnostic copy of the unchanged production raster comparison. It
        /// reports the first failure only and never changes admission/result.
        private func firstMismatch(_ image: CGImage?, cell: Int) -> String {
            guard let image, cell >= 1 else { return "missingCropOrCell" }
            let side = (matrix.moduleCount + 8) * cell
            guard image.width == side, image.height == side else { return "cropDimensions(expected=\(side))" }
            var pixels = [UInt8](repeating: 0, count: side * side * 4)
            let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
                guard let context = CGContext(data: bytes.baseAddress, width: side, height: side,
                    bitsPerComponent: 8, bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
                context.interpolationQuality = .none
                context.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(side), height: CGFloat(side)))
                return true
            }
            guard rendered else { return "rasterContext" }
            for y in 0..<side {
                for x in 0..<side {
                    let mx = x / cell - 4, my = y / cell - 4
                    let black = mx >= 0 && my >= 0 && mx < matrix.moduleCount && my < matrix.moduleCount
                        && matrix.black[my * matrix.moduleCount + mx]
                    let index = (y * side + x) * 4
                    if pixels[index + 3] != 255 || !(0..<3).allSatisfy({ black ? pixels[index + $0] <= 5 : pixels[index + $0] >= 250 }) {
                        let rgba = Array(pixels[index..<(index + 4)])
                        return "x=\(x),y=\(y),module=\(mx),\(my),expectedBlack=\(black),rgba=\(rgba)"
                    }
                }
            }
            return "allPixelsMatch"
        }
    }
    func testAttachedOffscreenMountedChildrenCaptureAtExactPixelsAndDecodeTheFullLink() async throws {
        let fixture = try await displayedFixture(); defer { fixture.close() }
        XCTAssertNotNil(fixture.card.window)
        XCTAssertLessThan(fixture.card.frame.maxX, 0)
        let image = try fixture.capture(), pixels = try XCTUnwrap(image.cgImage)
        XCTAssertEqual(pixels.width, 1080); XCTAssertEqual(pixels.height, 1350)
        XCTAssertEqual(try qrPayloads(in: pixels), [fixture.payload])
        // Read actual sibling pixels outside the native QR; a QR-only rendering
        // cannot satisfy this assertion or substitute a native-composed card.
        let marker = try XCTUnwrap(pixels.cropping(to: CGRect(x: 48, y: 24, width: 30, height: 30)))
        var data = [UInt8](repeating: 0, count: 30 * 30 * 4)
        data.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress, width: 30, height: 30,
                bitsPerComponent: 8, bytesPerRow: 120, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
            context.draw(marker, in: CGRect(x: 0, y: 0, width: 30, height: 30))
        }
        XCTAssertTrue(stride(from: 0, to: data.count, by: 4).allSatisfy {
            data[$0] >= 250 && data[$0 + 1] <= 5 && data[$0 + 2] <= 5 && data[$0 + 3] == 255
        })
    }
    func testReadyForeignPayloadWrongModulesAndPhysicalGeometryRefuse() async throws {
        let fixture = try await displayedFixture(); defer { fixture.close() }
        fixture.registry.update(view: fixture.card, token: fixture.token, payload: fixture.payload, ready: false)
        XCTAssertThrowsError(try fixture.capture()) { XCTAssertEqual($0 as? LavaShareCardSurfaceRegistry.Refusal, .notReady) }
        fixture.registry.update(view: fixture.card, token: fixture.token, payload: fixture.payload, ready: true)
        XCTAssertThrowsError(try fixture.registry.capture(token: "foreign", payload: fixture.payload, isCurrent: { true }))
        XCTAssertThrowsError(try fixture.registry.capture(token: fixture.token, payload: "foreign", isCurrent: { true }))
        fixture.qr.configure(payload: fixture.payload, moduleCount: fixture.matrix.moduleCount + 4)
        XCTAssertThrowsError(try fixture.capture()) { XCTAssertEqual($0 as? LavaShareCardSurfaceRegistry.Refusal, .invalidQr) }
        fixture.qr.configure(payload: "https://example.com/other", moduleCount: fixture.matrix.moduleCount)
        XCTAssertThrowsError(try fixture.capture()) { XCTAssertEqual($0 as? LavaShareCardSurfaceRegistry.Refusal, .invalidQr) }
        fixture.card.bounds.size.width -= 1
        XCTAssertThrowsError(try fixture.capture()) { XCTAssertEqual($0 as? LavaShareCardSurfaceRegistry.Refusal, .invalidGeometry) }
    }
    func testHalfPixelQrPlacementAndClippedQrAreRefused() async throws {
        let fixture = try await displayedFixture(); defer { fixture.close() }
        fixture.qr.frame.origin.x += 0.5 / fixture.window.screen.scale
        XCTAssertThrowsError(try fixture.capture()) { XCTAssertEqual($0 as? LavaShareCardSurfaceRegistry.Refusal, .captureFailed) }
        fixture.qr.frame.origin.x = fixture.card.bounds.width - 1
        XCTAssertThrowsError(try fixture.capture()) { XCTAssertEqual($0 as? LavaShareCardSurfaceRegistry.Refusal, .invalidQr) }
    }
    /// With no authority reauthorization configured, a withdrawn token stays
    /// refused. The re-authorization path is covered by the two tests below.
    func testDuplicateSurfaceDetachedSurfaceAndWithdrawalCannotReuseAnOldGrant() async throws {
        let fixture = try await displayedFixture(); defer { fixture.close() }
        let duplicate = UIView(frame: fixture.card.frame)
        fixture.window.addSubview(duplicate)
        fixture.registry.update(view: duplicate, token: fixture.token, payload: fixture.payload, ready: true)
        XCTAssertThrowsError(try fixture.capture()) { XCTAssertEqual($0 as? LavaShareCardSurfaceRegistry.Refusal, .notReady) }
        fixture.registry.remove(view: duplicate); duplicate.removeFromSuperview()
        var withdrawn: [String] = []
        fixture.registry.onWithdrawal = { withdrawn.append($0) }
        fixture.card.removeFromSuperview()
        fixture.registry.update(view: fixture.card, token: fixture.token, payload: fixture.payload, ready: true)
        XCTAssertEqual(withdrawn, [fixture.token])
        fixture.window.addSubview(fixture.card)
        fixture.registry.update(view: fixture.card, token: fixture.token, payload: fixture.payload, ready: true)
        XCTAssertThrowsError(try fixture.capture()) { XCTAssertEqual($0 as? LavaShareCardSurfaceRegistry.Refusal, .retired) }
    }
    /// A transient screen unmount withdraws the registry entry. The authority
    /// grant survives, so a remounted surface presenting the same token must be
    /// re-admitted and export, rather than showing an enabled Share that fails.
    func testTransientWithdrawalReadmitsAStillAuthorizedToken() async throws {
        let fixture = try await displayedFixture(); defer { fixture.close() }
        var withdrawn: [String] = []
        fixture.registry.onWithdrawal = { withdrawn.append($0) }
        fixture.registry.reauthorize = { [token = fixture.token, payload = fixture.payload] candidate in
            candidate == token ? payload : nil
        }
        fixture.card.removeFromSuperview()
        fixture.registry.update(view: fixture.card, token: fixture.token, payload: fixture.payload, ready: true)
        XCTAssertEqual(withdrawn, [fixture.token])
        fixture.window.addSubview(fixture.card)
        fixture.registry.update(view: fixture.card, token: fixture.token, payload: fixture.payload, ready: true)
        let image = try fixture.capture()
        XCTAssertEqual(try XCTUnwrap(image.cgImage).width, 1080)
    }
    /// Re-admission is only for a token the authority still holds. Once the grant
    /// is retired (content, security, privacy, foreground or module change) the
    /// remounted surface is refused exactly as before.
    func testRetiredAuthorityTokenIsNotReAdmittedAfterWithdrawal() async throws {
        let fixture = try await displayedFixture(); defer { fixture.close() }
        fixture.registry.reauthorize = { _ in nil }
        fixture.card.removeFromSuperview()
        fixture.registry.update(view: fixture.card, token: fixture.token, payload: fixture.payload, ready: true)
        fixture.window.addSubview(fixture.card)
        fixture.registry.update(view: fixture.card, token: fixture.token, payload: fixture.payload, ready: true)
        XCTAssertThrowsError(try fixture.capture()) { XCTAssertEqual($0 as? LavaShareCardSurfaceRegistry.Refusal, .retired) }
    }
    func testPrivacyOrContentRetirementAtTheCaptureBoundaryRejectsActualPixels() async throws {
        let fixture = try await displayedFixture(); defer { fixture.close() }
        var checks = 0
        XCTAssertThrowsError(try fixture.capture(isCurrent: {
            checks += 1
            return checks == 1
        })) { XCTAssertEqual($0 as? LavaShareCardSurfaceRegistry.Refusal, .retired) }
        XCTAssertEqual(checks, 2, "The real image must pass QR validation before the final authority refuses it")
        fixture.registry.retire()
        XCTAssertThrowsError(try fixture.capture()) { XCTAssertEqual($0 as? LavaShareCardSurfaceRegistry.Refusal, .retired) }
    }

    #if DEBUG && targetEnvironment(simulator)
    // Helper/native-port fixture evidence only. The shipping RN UI journey must
    // independently present/cancel its real chooser and decode the retained PNG.
    private func evidenceCache() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lava-share-evidence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    func testCancelledChooserEvidenceRetainsExactCapturedPngOnlyTwiceAndDiscardsPriorFiles() async throws {
        let fixture = try await displayedFixture(); defer { fixture.close() }
        let root = try evidenceCache(); defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent(LavaShareCardUITestEvidence.directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("stale".utf8).write(to: directory.appendingPathComponent("share-card-1.png"))
        try Data("stale".utf8).write(to: directory.appendingPathComponent("unrelated-old-entry.png"))
        let observer = LavaShareCardUITestEvidence(enabled: true, cacheDirectory: root)
        let image = try fixture.capture(), original = try XCTUnwrap(image.pngData())
        let first = try XCTUnwrap(observer.completion(for: image, isCurrent: { true }))
        first(.cancelled)
        first(.cancelled) // The same chooser's replay cannot create another entry.
        let decoder = JSONDecoder()
        var receipt = try decoder.decode(LavaShareCardUITestEvidence.Receipt.self,
            from: Data(contentsOf: directory.appendingPathComponent(LavaShareCardUITestEvidence.receiptFilename)))
        XCTAssertEqual(receipt.images.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("unrelated-old-entry.png").path))
        let second = try XCTUnwrap(observer.completion(for: image, isCurrent: { true }))
        second(.cancelled)
        let third = try XCTUnwrap(observer.completion(for: image, isCurrent: { true }))
        third(.cancelled)
        receipt = try decoder.decode(LavaShareCardUITestEvidence.Receipt.self,
            from: Data(contentsOf: directory.appendingPathComponent(LavaShareCardUITestEvidence.receiptFilename)))
        XCTAssertEqual(receipt.formatVersion, 1)
        XCTAssertEqual(receipt.images.map(\.sequence), [1, 2])
        XCTAssertEqual(receipt.images.map(\.filename), ["share-card-1.png", "share-card-2.png"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted(),
            ["receipt.json", "share-card-1.png", "share-card-2.png"])
        for entry in receipt.images {
            let data = try Data(contentsOf: directory.appendingPathComponent(entry.filename))
            XCTAssertEqual(data, original, "Keep the actual captured image passed to the chooser, without composing/resizing it again.")
            XCTAssertEqual(entry.width, 1080); XCTAssertEqual(entry.height, 1350)
            XCTAssertEqual(entry.sha256, SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
            let pixels = try XCTUnwrap(UIImage(data: data)?.cgImage)
            XCTAssertEqual(pixels.width, 1080); XCTAssertEqual(pixels.height, 1350)
            XCTAssertEqual(try qrPayloads(in: pixels), [fixture.payload])
        }
    }
    func testDisabledNoncancelledStaleAndMalformedChooserEvidenceCreatesNoFiles() async throws {
        let fixture = try await displayedFixture(); defer { fixture.close() }
        let root = try evidenceCache(); defer { try? FileManager.default.removeItem(at: root) }
        let image = try fixture.capture()
        let disabled = LavaShareCardUITestEvidence(enabled: false, cacheDirectory: root)
        XCTAssertNil(disabled.completion(for: image, isCurrent: { true }))
        let observer = LavaShareCardUITestEvidence(enabled: true, cacheDirectory: root)
        for outcome in [ShareSheetPresenter.Outcome.completed, .unavailable, .failed(NSError(domain: "fixture", code: 1))] {
            let declined = try XCTUnwrap(observer.completion(for: image, isCurrent: { true }))
            declined(outcome)
            declined(.cancelled)
        }
        var current = false
        let retired = try XCTUnwrap(observer.completion(for: image, isCurrent: { current }))
        retired(.cancelled)
        current = true
        retired(.cancelled) // Retirement consumed this completion, even if a later authority becomes current.
        try XCTUnwrap(observer.completion(for: UIImage(), isCurrent: { true }))(.cancelled)
        let pixels = try XCTUnwrap(image.cgImage)
        let cropped = try XCTUnwrap(pixels.cropping(to: CGRect(x: 0, y: 0, width: 1079, height: 1350)))
        try XCTUnwrap(observer.completion(for: UIImage(cgImage: cropped), isCurrent: { true }))(.cancelled)
        try XCTUnwrap(observer.completion(for: UIImage(cgImage: pixels, scale: image.scale, orientation: .left), isCurrent: { true }))(.cancelled)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }
    func testRetirementAfterEncodingOrPublicationAndCacheFailureDoNotCommitAReceipt() async throws {
        let fixture = try await displayedFixture(); defer { fixture.close() }
        let root = try evidenceCache(); defer { try? FileManager.default.removeItem(at: root) }
        let image = try fixture.capture()
        for admittedChecks in [1, 2] {
            let cache = root.appendingPathComponent("boundary-\(admittedChecks)", isDirectory: true)
            let observer = LavaShareCardUITestEvidence(enabled: true, cacheDirectory: cache)
            var checks = 0
            try XCTUnwrap(observer.completion(for: image, isCurrent: {
                checks += 1
                return checks <= admittedChecks
            }))(.cancelled)
            XCTAssertEqual(checks, admittedChecks + 1)
            let directory = cache.appendingPathComponent(LavaShareCardUITestEvidence.directoryName)
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("share-card-1.png").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("receipt.json").path))
        }
        let blockedCache = root.appendingPathComponent("not-a-directory")
        try Data("fixture".utf8).write(to: blockedCache)
        let failed = LavaShareCardUITestEvidence(enabled: true, cacheDirectory: blockedCache)
        try XCTUnwrap(failed.completion(for: image, isCurrent: { true }))(.cancelled)
        XCTAssertEqual(try Data(contentsOf: blockedCache), Data("fixture".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: blockedCache.appendingPathComponent(LavaShareCardUITestEvidence.directoryName).path))
    }
    #endif
}
