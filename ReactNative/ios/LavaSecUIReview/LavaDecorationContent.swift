import SwiftUI
import UIKit
import LavaSecKit

/// The small, native drawing surface behind the semantic React Native primitive.
@objc(LavaDecorationContent)
@MainActor
final class LavaDecorationContent: UIView {
    @objc var onGuardianGesture: ((String) -> Void)?
    private var guardianGesturesEnabled = false
    private lazy var guardianHold: LavaGuardianHoldRecognizer = {
        let recognizer = LavaGuardianHoldRecognizer(target: self, action: #selector(heldGuardian))
        recognizer.minimumPressDuration = GuardianLongPressHaptics.holdDuration
        // Once contact starts on the mascot, drift belongs to the held action.
        // The shared native tracking guard owns ancestor scrolling until release.
        recognizer.allowableMovement = .greatestFiniteMagnitude
        recognizer.onContact = { [weak self] touching in self?.onGuardianGesture?(touching ? "start" : "end") }
        recognizer.isEnabled = false
        return recognizer
    }()
    private lazy var guardianTap = UITapGestureRecognizer(target: self, action: #selector(tappedGuardian))
    private let symbolView = UIImageView()
    private let revealSymbolView = UIImageView()
    private let aperture = CAGradientLayer()
    private var revealEnabled = false
    private var revealVisible = false
    private var revealCenter = CGPoint.zero
    private var revealRadius: CGFloat = 22
    private let material = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterial))
    private var symbol = ""
    private var guardian: UIHostingController<AnyView>?
    private var renderedSize: CGFloat = -1
    private var mood = "sleeping"
    private var look = "original"
    private var drawingTint = UIColor.clear
    private var drawingPointSize: CGFloat = 0
    private var showsDrawing: Bool { symbol.isEmpty || symbol == "share.qr" || symbol == "lava.shield.fill" || symbol == LavaGlyphSymbol.ranking }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = false
        addGestureRecognizer(guardianHold)
        addGestureRecognizer(guardianTap)
        guardianTap.require(toFail: guardianHold)
        guardianTap.isEnabled = false
        NotificationCenter.default.addObserver(self, selector: #selector(cancelGuardianContact), name: UIApplication.willResignActiveNotification, object: nil)
        symbolView.contentMode = .scaleAspectFit
        addSubview(symbolView)
        revealSymbolView.contentMode = .scaleAspectFit
        revealSymbolView.isUserInteractionEnabled = false
        revealSymbolView.isHidden = true
        aperture.type = .radial
        aperture.startPoint = CGPoint(x: 0.5, y: 0.5)
        // Radial endPoint defines both ellipse radii relative to startPoint.
        // Keeping the same y would create a zero-height, invisible aperture.
        aperture.endPoint = CGPoint(x: 1, y: 1)
        revealSymbolView.layer.mask = aperture
        addSubview(revealSymbolView)
        NotificationCenter.default.addObserver(self, selector: #selector(settleReveal), name: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil)
        material.isHidden = true
        material.isUserInteractionEnabled = false
        material.layer.cornerRadius = LavaSurface.controlCornerRadius
        material.clipsToBounds = true
        addSubview(material)
    }

    required init?(coder: NSCoder) { nil }

    @objc func setGuardianGestures(_ enabled: Bool) {
        guardianGesturesEnabled = enabled
        guardianHold.isEnabled = enabled && window != nil
        guardianTap.isEnabled = enabled && window != nil
    }

    @objc private func cancelGuardianContact() {
        settleReveal()
        guardianHold.finishContact()
        guardianHold.isEnabled = false
        guardianTap.isEnabled = false
    }

    @objc private func heldGuardian() {
        guard guardianHold.state == .began else { return }
        guardianHold.finishContact()
        onGuardianGesture?("reveal")
    }

    @objc private func tappedGuardian() {
        guard guardianTap.state == .ended else { return }
        onGuardianGesture?("tap")
    }

    // Retaining an off-window route preserves its drawing, but Fabric recycling
    // ends that identity. Discard animation/QR state before another owner uses it.
    @objc func resetForRecycle() {
        setGuardianGestures(false)
        guardianHold.finishContact()
        if let guardian { LavaNativeContainment.remove(guardian) }
        guardian = nil
        renderedSize = -1
        symbol = ""
        mood = "sleeping"
        look = "original"
        drawingTint = .clear
        drawingPointSize = 0
        symbolView.image = nil
        revealEnabled = false
        revealVisible = false
        revealSymbolView.image = nil
        revealSymbolView.isHidden = true
        aperture.removeAllAnimations()
        material.isHidden = true
    }

    @objc func configure(symbol: String, mood: String, look: String, tone: String, colorScheme: String, fontPointSize: Double, fontWeight: String) {
        self.mood = mood
        self.look = look
        self.symbol = symbol
        drawingPointSize = CGFloat(fontPointSize)
        drawingTint = LavaSymbolPalette.color(for: tone, colorScheme: colorScheme)
        let drawing = showsDrawing
        material.isHidden = symbol != "privacy.material"
        symbolView.isHidden = drawing || !material.isHidden
        guardian?.viewIfLoaded?.isHidden = !drawing
        if drawing {
            updateGuardian()
        } else {
            // A SwiftUI Image.font(...) sizes the glyph typographically, not by
            // squeezing the padded UIImage into a same-size square. Activity's
            // reference uses 15pt semibold stats and a 12pt bold calendar glyph.
            let weight: UIImage.SymbolWeight = switch fontWeight {
            case "regular": .regular
            case "medium": .medium
            case "bold": .bold
            default: .semibold
            }
            let configuration = fontPointSize > 0
                ? UIImage.SymbolConfiguration(pointSize: CGFloat(fontPointSize), weight: weight)
                : UIImage.SymbolConfiguration(weight: weight)
            symbolView.contentMode = fontPointSize > 0 ? .center : .scaleAspectFit
            symbolView.image = symbol == "google.signin"
                ? UIImage(named: "GoogleSignInG")
                : UIImage(systemName: symbol, withConfiguration: configuration)
            symbolView.tintColor = drawingTint
            revealSymbolView.image = symbolView.image
            revealSymbolView.contentMode = symbolView.contentMode
            revealSymbolView.tintColor = drawingTint

        }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        symbolView.frame = bounds
        revealSymbolView.frame = bounds
        material.frame = bounds
        if showsDrawing && renderedSize != min(bounds.width, bounds.height) { updateGuardian() }
        updateContainment()
    }

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        updateContainment()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { cancelGuardianContact() }
        else { setGuardianGestures(guardianGesturesEnabled) }
        updateContainment()
    }

    /// The mask lives on a normal-colour copy of the same SF Symbol, so its
    /// softened aperture can never paint a spotlight outside the glyph strokes.
    @objc func configureReveal(enabled: Bool, visible: Bool, x: Double, y: Double, radius: Double) {
        let wasEnabled = revealEnabled
        let wasVisible = revealVisible
        revealEnabled = enabled && !showsDrawing
        revealVisible = revealEnabled && visible
        revealSymbolView.isHidden = !revealVisible
        // A skipped or not-yet-measured stage has no visible starting aperture.
        // Reappearing must use its destination immediately, not animate outward
        // from that glyph's placeholder center and flash every stage green.
        if !wasVisible || !revealVisible { aperture.removeAllAnimations() }
        symbolView.tintColor = revealEnabled ? LavaSymbolPalette.color(for: "secondary", colorScheme: "") : drawingTint
        let center = CGPoint(x: x, y: y)
        let size = CGFloat(max(1, radius))
        guard center != revealCenter || size != revealRadius || wasEnabled != revealEnabled else { return }
        let from = aperture.presentation()?.position ?? aperture.position
        revealCenter = center
        revealRadius = size
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        aperture.bounds = CGRect(x: 0, y: 0, width: size * 2, height: size * 2)
        aperture.position = center
        aperture.colors = [UIColor.black.cgColor, UIColor.black.cgColor, UIColor.clear.cgColor]
        aperture.locations = [0, NSNumber(value: max(0, 1 - 5 / Double(size))), 1]
        CATransaction.commit()
        aperture.removeAllAnimations()
        guard revealEnabled, wasEnabled, revealVisible, wasVisible, window != nil, UIApplication.shared.applicationState == .active,
              !UIAccessibility.isReduceMotionEnabled, from != center else { return }
        let animation = CABasicAnimation(keyPath: "position")
        animation.fromValue = NSValue(cgPoint: from)
        animation.toValue = NSValue(cgPoint: center)
        animation.duration = 0.6
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        aperture.add(animation, forKey: "glyphReveal")
    }

    @objc private func settleReveal() { aperture.removeAllAnimations() }

    private func updateContainment() {
        guard let guardian else { return }
        LavaNativeContainment.update(guardian, in: self) { view in
            view.backgroundColor = .clear
            view.isUserInteractionEnabled = false
            view.isHidden = !showsDrawing
        }
    }

    private func updateGuardian() {
        renderedSize = min(bounds.width, bounds.height)
        let state = GuardianMascotState(rawValue: mood) ?? .sleeping
        let style = GuardianShieldStyle(rawValue: look) ?? .original
        let size = min(bounds.width, bounds.height)
        let drawing: AnyView
        if symbol == LavaGlyphSymbol.ranking {
            let glyphSize = drawingPointSize > 0 ? drawingPointSize : size
            drawing = AnyView(LavaRankingGlyph().fill(Color(uiColor: drawingTint)).frame(width: glyphSize, height: glyphSize))
        } else if symbol == "lava.shield.fill" {
            // The faceless brand mark is the mascot's own contour, shared with
            // native filter cards. Keep it upright and free of expression/motion.
            drawing = AnyView(LavaGuardianShieldShape()
                .fill(Color(uiColor: drawingTint))
                .frame(width: size, height: size))
        } else if symbol == "share.qr", let qr = ReviewReferenceContent.shareQRImage(look) {
            // Square decoration for isolated reference callers. Share detail
            // owns its separate background filling the entire rounded card.
            drawing = AnyView(Image(uiImage: qr).interpolation(.none).resizable().scaledToFit()
                .frame(width: 220, height: 220).padding(10)
                .background(.white, in: RoundedRectangle(cornerRadius: 14))
                .blur(radius: mood == "revealed" ? 0 : 24).opacity(mood == "revealed" ? 1 : 0.25))
        } else if mood == "thankYou" {
            drawing = AnyView(GuardianThankYouAnimation(size: size, shieldStyle: style))
        } else if mood == "locked" {
            // Same proportional contour and glyph as MaskedLavaGuardIcon. Only
            // artwork crosses this boundary; availability remains screen state.
            drawing = AnyView(ZStack {
                LavaGuardianShieldShape()
                    .stroke(LavaStyle.secondaryText, style: StrokeStyle(lineWidth: max(1.8, size * 0.045), lineCap: .round, lineJoin: .round, dash: [2, 4]))
                    .frame(width: size * 1.12, height: size * 1.12)
                Text("?").font(.system(size: size * 0.44, weight: .bold, design: .rounded)).foregroundStyle(LavaStyle.secondaryText)
            })
        } else {
            drawing = AnyView(SoftShieldGuardian(size: size, state: state, shieldStyle: style))
        }
        if let guardian {
            guardian.rootView = drawing
            guardian.viewIfLoaded?.isHidden = false
        } else {
            let controller = UIHostingController(rootView: drawing)
            guardian = controller
            updateContainment()
        }
    }
}


/// UIKit owns movement tolerance; this subclass only reports the contact lifetime
/// needed by the existing haptic ramp. Failed/cancelled contacts never reveal.
@MainActor
private final class LavaGuardianHoldRecognizer: UILongPressGestureRecognizer {
    var onContact: ((Bool) -> Void)?
    private var hasContact = false

    func finishContact() {
        guard hasContact else { return }
        hasContact = false
        onContact?(false)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        guard state == .possible, !hasContact else { return }
        hasContact = true
        onContact?(true)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesMoved(touches, with: event)
        if state == .failed || state == .cancelled { finishContact() }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        finishContact()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        finishContact()
    }

    override func reset() {
        finishContact()
        super.reset()
    }
}
