import UIKit
import CoreImage.CIFilterBuiltins

/// Full-payload encoder shared by the query and the native QR leaf. The returned
/// matrix excludes Core Image's verified one-module border, not a guessed inset.
struct LavaShareQrMatrix {
    let moduleCount: Int
    let black: [Bool]
    let correctionLevel: String

    static func encode(_ payload: String) -> Self? {
        guard !payload.isEmpty, payload.utf8.count <= 16_384 else { return nil }
        let context = CIContext(options: [.useSoftwareRenderer: true])
        for level in ["Q", "M", "L"] {
            let generator = CIFilter.qrCodeGenerator()
            generator.message = Data(payload.utf8)
            generator.correctionLevel = level
            guard let output = generator.outputImage,
                  let image = context.createCGImage(output, from: output.extent),
                  image.width == image.height else { continue }
            let extent = image.width, count = extent - 2
            guard count >= 21, count <= 177, (count - 21) % 4 == 0 else { return nil }
            var gray = [UInt8](repeating: 255, count: extent * extent)
            let rendered = gray.withUnsafeMutableBytes { bytes -> Bool in
                guard let raster = CGContext(data: bytes.baseAddress, width: extent, height: extent,
                    bitsPerComponent: 8, bytesPerRow: extent, space: CGColorSpaceCreateDeviceGray(),
                    bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
                raster.interpolationQuality = .none
                raster.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(extent), height: CGFloat(extent)))
                return true
            }
            guard rendered else { return nil }
            for i in 0..<extent {
                guard gray[i] >= 250, gray[(extent - 1) * extent + i] >= 250,
                      gray[i * extent] >= 250, gray[i * extent + extent - 1] >= 250 else { return nil }
            }
            var black: [Bool] = []
            black.reserveCapacity(count * count)
            for y in 1..<(extent - 1) {
                for x in 1..<(extent - 1) {
                    let value = gray[y * extent + x]
                    guard value <= 5 || value >= 250 else { return nil }
                    black.append(value <= 5)
                }
            }
            guard black.contains(true) else { return nil }
            return Self(moduleCount: count, black: black, correctionLevel: level)
        }
        return nil
    }

    func image(cellPixels: Int) -> CGImage? {
        guard cellPixels >= 1, cellPixels <= 128 else { return nil }
        let side = (moduleCount + 8) * cellPixels
        guard side <= 1080 else { return nil }
        var pixels = [UInt8](repeating: 255, count: side * side * 4)
        for y in 0..<moduleCount {
            for x in 0..<moduleCount where black[y * moduleCount + x] {
                for py in ((y + 4) * cellPixels)..<((y + 5) * cellPixels) {
                    for px in ((x + 4) * cellPixels)..<((x + 5) * cellPixels) {
                        let index = (py * side + px) * 4
                        pixels[index] = 0; pixels[index + 1] = 0; pixels[index + 2] = 0
                    }
                }
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
                .union(.byteOrder32Big), provider: provider, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent)
    }
}

@objc(LavaShareQrContent)
@MainActor
final class LavaShareQrContent: UIView {
    private(set) var payload = ""
    private(set) var matrix: LavaShareQrMatrix?
    private var expectedModuleCount = 0
    private var paintedPayload: String?
    private var paintedBounds = CGRect.zero
    private var paintedScale: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = true
        backgroundColor = .white
        isAccessibilityElement = false
        overrideUserInterfaceStyle = .light
    }
    required init?(coder: NSCoder) { nil }

    @objc func configure(payload: String, moduleCount: Int) {
        guard payload != self.payload || moduleCount != expectedModuleCount else { return }
        self.payload = payload
        expectedModuleCount = moduleCount
        matrix = LavaShareQrMatrix.encode(payload)
        paintedPayload = nil
        setNeedsDisplay()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds != paintedBounds { paintedPayload = nil; setNeedsDisplay() }
    }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        paintedPayload = nil
        if let window { contentScaleFactor = window.screen.scale }
        setNeedsDisplay()
    }
    private func cellPixels(scale: CGFloat) -> Int? {
        guard let matrix, matrix.moduleCount == expectedModuleCount,
              bounds.width > 0, bounds.width == bounds.height, scale > 0 else { return nil }
        let pixels = bounds.width * scale
        let cell = pixels / CGFloat(matrix.moduleCount + 8)
        guard abs(pixels.rounded() - pixels) < 0.01,
              abs(cell.rounded() - cell) < 0.0001, cell >= 3, pixels <= 1080 else { return nil }
        return Int(cell.rounded())
    }
    override func draw(_ rect: CGRect) {
        paintedPayload = nil
        guard let context = UIGraphicsGetCurrentContext() else { return }
        context.setFillColor(UIColor.white.cgColor); context.fill(bounds)
        let scale = window?.screen.scale ?? contentScaleFactor
        guard let matrix, let cell = cellPixels(scale: scale), let image = matrix.image(cellPixels: cell) else { return }
        context.setShouldAntialias(false)
        context.interpolationQuality = .none
        UIImage(cgImage: image, scale: scale, orientation: .up).draw(in: bounds)
        paintedPayload = payload
        paintedBounds = bounds
        paintedScale = scale
    }

    func prepareForCapture(payload: String, scale: CGFloat) -> Bool {
        guard self.payload == payload, window != nil, cellPixels(scale: scale) != nil else { return false }
        layer.displayIfNeeded()
        return paintedPayload == payload && paintedBounds == bounds && paintedScale == scale
    }

    /// Check actual captured modules, including every pixel of the four-module
    /// quiet zone. This also refuses offscreen drawHierarchy omissions/stale layers.
    func matchesCapturedPixels(_ image: CGImage, in surface: UIView, scale: CGFloat) -> Bool {
        guard let matrix, let cell = cellPixels(scale: scale) else { return false }
        let pointRect = convert(bounds, to: surface)
        let rect = CGRect(x: pointRect.minX * scale, y: pointRect.minY * scale,
            width: pointRect.width * scale, height: pointRect.height * scale)
        guard [rect.minX, rect.minY, rect.width, rect.height].allSatisfy({ abs($0.rounded() - $0) < 0.01 }) else { return false }
        // Point conversion can leave floating error at an integral pixel edge.
        // Canonicalize only admitted edges so cropping cannot expand by a row.
        let integerRect = CGRect(x: rect.minX.rounded(), y: rect.minY.rounded(),
            width: rect.width.rounded(), height: rect.height.rounded())
        guard let crop = image.cropping(to: integerRect), crop.width == (matrix.moduleCount + 8) * cell,
              crop.height == crop.width else { return false }
        let side = crop.width
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let raster = CGContext(data: bytes.baseAddress, width: side, height: side,
                bitsPerComponent: 8, bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            raster.interpolationQuality = .none
            raster.draw(crop, in: CGRect(x: 0, y: 0, width: CGFloat(side), height: CGFloat(side)))
            return true
        }
        guard rendered else { return false }
        for y in 0..<side {
            for x in 0..<side {
                let mx = x / cell - 4, my = y / cell - 4
                let black = mx >= 0 && my >= 0 && mx < matrix.moduleCount && my < matrix.moduleCount
                    && matrix.black[my * matrix.moduleCount + mx]
                let index = (y * side + x) * 4
                guard pixels[index + 3] == 255 else { return false }
                for c in 0..<3 {
                    guard black ? pixels[index + c] <= 5 : pixels[index + c] >= 250 else { return false }
                }
            }
        }
        return true
    }
}

@objc(LavaShareCardSurfaceRegistry)
@MainActor
final class LavaShareCardSurfaceRegistry: NSObject {
    @objc static let shared = LavaShareCardSurfaceRegistry()
    private final class Entry {
        weak var view: UIView?
        let ready: Bool
        init(_ view: UIView, ready: Bool) { self.view = view; self.ready = ready }
    }
    private var token: String?
    private var payload: String?
    private var entries: [Entry] = []
    var onWithdrawal: ((String) -> Void)?
    /// Consulted when a surface presents a token this registry no longer holds
    /// because its previous entry was withdrawn. Returns the authoritative
    /// payload while the token is still an admitted export grant, or nil once the
    /// grant has been retired. A transient unmount withdraws the registry entry,
    /// not the authority's grant, so a remounted surface must be re-admitted
    /// instead of leaving Share enabled but refused at the capture boundary.
    var reauthorize: ((String) -> String?)?

    func authorize(token: String, payload: String) {
        if self.token == token && self.payload == payload { return }
        self.token = token; self.payload = payload; entries = []
    }
    func retire() { token = nil; payload = nil; entries = [] }
    @objc func update(view: UIView, token: String, payload: String, ready: Bool) {
        let removed = removeEntry(view)
        if view.window == nil { withdrawIfEmpty(removed: removed); return }
        if self.token != token || self.payload != payload {
            guard let authorized = reauthorize?(token), authorized == payload else { return }
            authorize(token: token, payload: payload)
        }
        entries.append(Entry(view, ready: ready))
    }
    @objc func remove(view: UIView) { withdrawIfEmpty(removed: removeEntry(view)) }
    private func removeEntry(_ view: UIView) -> Bool {
        let removed = entries.contains { $0.view === view }
        entries.removeAll { $0.view == nil || $0.view === view }
        return removed
    }
    private func withdrawIfEmpty(removed: Bool) {
        guard removed, entries.isEmpty, let token else { return }
        retire()
        onWithdrawal?(token)
    }

    enum Refusal: Error, Equatable { case retired, notReady, invalidGeometry, invalidQr, captureFailed }
    func capture(token: String, payload: String, isCurrent: () -> Bool) throws -> UIImage {
        guard self.token == token, self.payload == payload, isCurrent() else { throw Refusal.retired }
        entries.removeAll { $0.view == nil }
        guard entries.count == 1, let entry = entries.first, entry.ready,
              let view = entry.view, let window = view.window, !window.isHidden else { throw Refusal.notReady }
        guard window.windowScene?.activationState == .foregroundActive else { throw Refusal.retired }
        var ancestor: UIView? = view
        while let next = ancestor {
            guard !next.isHidden, next.alpha == 1 else { throw Refusal.notReady }
            ancestor = next.superview
        }
        view.layoutIfNeeded()
        let scale = window.screen.scale
        guard abs(view.bounds.width * scale - 1080) < 0.01,
              abs(view.bounds.height * scale - 1350) < 0.01,
              view.bounds.origin == .zero else { throw Refusal.invalidGeometry }
        let codes = qrChildren(view)
        guard codes.count == 1, let qr = codes.first,
              qr.prepareForCapture(payload: payload, scale: scale) else { throw Refusal.invalidQr }
        var qrAncestor: UIView? = qr
        while let next = qrAncestor, next !== view {
            guard next.transform.isIdentity, !next.isHidden, next.alpha == 1,
                  next.bounds.contains(qr.convert(qr.bounds, to: next)) else { throw Refusal.invalidQr }
            qrAncestor = next.superview
        }
        guard view.bounds.contains(qr.convert(qr.bounds, to: view)) else { throw Refusal.invalidQr }
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale; format.opaque = true; format.preferredRange = .standard
        var rendered = false
        let image = UIGraphicsImageRenderer(size: view.bounds.size, format: format).image { _ in
            rendered = view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
        guard rendered, let pixels = image.cgImage, pixels.width == 1080, pixels.height == 1350,
              qr.matchesCapturedPixels(pixels, in: view, scale: scale) else { throw Refusal.captureFailed }
        guard self.token == token, self.payload == payload, entries.count == 1,
              entries.first === entry, entry.view === view, view.window === window,
              entry.ready, qr.prepareForCapture(payload: payload, scale: scale),
              abs(view.bounds.width * scale - 1080) < 0.01,
              abs(view.bounds.height * scale - 1350) < 0.01, isCurrent() else { throw Refusal.retired }
        return image
    }
    private func qrChildren(_ view: UIView) -> [LavaShareQrContent] {
        if let qr = view as? LavaShareQrContent { return [qr] }
        return view.subviews.flatMap(qrChildren)
    }
}
