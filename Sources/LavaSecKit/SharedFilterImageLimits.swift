import Foundation

/// Size bounds applied to an image the recipient picked, before Lava decodes it.
///
/// **A byte cap alone does not bound memory.** Image formats compress, so a small
/// file may declare enormous pixel dimensions: a 30 000 × 30 000 PNG of flat colour
/// is a few megabytes on disk and roughly 3.6 GB once decoded. Materializing that
/// bitmap terminates the app, and the input is attacker-chosen in the only sense
/// that matters here — the sender picked the image the recipient is invited to open.
///
/// So the byte cap and the pixel cap are separate rules that fail for separate
/// reasons, and both are checked from the file header, before any bitmap exists.
public enum SharedFilterImageLimits {
    /// Why an image was refused before decoding.
    public enum Rejection: Error, Equatable, Sendable {
        /// The encoded file is larger than a share card could plausibly be.
        case tooManyBytes
        /// The header declared no usable pixel dimensions.
        case unreadableDimensions
        /// The declared dimensions would decode to an unreasonable bitmap.
        case tooManyPixels
    }

    /// Encoded-bytes ceiling. A share card is ~1080 × 1350; anything past this is
    /// not one, and there is no reason to read it into memory to find out.
    public static let maximumByteCount = 40 * 1024 * 1024

    /// Declared-pixel ceiling, ~64 MP. Comfortably above a 48 MP phone camera at
    /// full resolution, which is the largest image a person plausibly photographs
    /// a card with. Chosen as one flat rule rather than per-format: JPEG can be
    /// subsampled cheaply during decode and PNG cannot, but a rule that depends on
    /// the format is a rule that is wrong for whatever format is added next.
    public static let maximumPixelCount = 64_000_000

    /// Longest edge the detector is asked to work on. QR detection is reliable well
    /// below full sensor resolution, so this bounds the working bitmap without
    /// costing recognition.
    public static let maximumDetectionEdge = 2_048

    /// - Throws: ``Rejection/tooManyBytes`` when the encoded file is over the cap.
    public static func validate(byteCount: Int) throws {
        guard byteCount <= maximumByteCount else {
            throw Rejection.tooManyBytes
        }
    }

    /// - Throws: ``Rejection/unreadableDimensions`` for non-positive dimensions, or
    ///   ``Rejection/tooManyPixels`` when the product exceeds ``maximumPixelCount``.
    ///   The multiplication is overflow-checked because both values come from an
    ///   untrusted header; a wrapped product would otherwise pass as a small image.
    public static func validate(pixelWidth: Int, pixelHeight: Int) throws {
        guard pixelWidth > 0, pixelHeight > 0 else {
            throw Rejection.unreadableDimensions
        }
        let (pixelCount, overflowed) = pixelWidth.multipliedReportingOverflow(by: pixelHeight)
        guard !overflowed, pixelCount <= maximumPixelCount else {
            throw Rejection.tooManyPixels
        }
    }
}
