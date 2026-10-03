import CoreGraphics
import Foundation
import ImageIO
import Vision
import LavaSecKit

/// Why a chosen image could not yield exactly one Lava filter code.
///
/// Each case is distinguishable because the recovery differs: a photo with no code
/// is a wrong-picture mistake, whereas a photo with two codes is a genuinely
/// ambiguous instruction that Lava must refuse rather than guess at.
enum ShareableFilterImageDecodeError: LocalizedError, Equatable {
    case unreadableImage
    case imageTooLarge
    case noLavaFilterQRCode
    case ambiguousLavaFilterQRCodes

    var errorDescription: String? {
        switch self {
        case .unreadableImage:
            return "That image couldn't be opened. Try a different one.".lavaLocalized
        case .imageTooLarge:
            return "That image is too large to scan. Try a smaller one.".lavaLocalized
        case .noLavaFilterQRCode:
            return "No Lava filter QR found in that image.".lavaLocalized
        case .ambiguousLavaFilterQRCodes:
            return "That image has more than one Lava filter QR. Crop it to just one and try again.".lavaLocalized
        }
    }
}

/// Reads a shared filter out of an image the recipient already has on this device
/// — typically a card saved from Messages.
///
/// Deliberately paired with `PhotosPicker` rather than `PHPhotoLibrary`: the picker
/// runs out of process and hands back only the single item the user chose, so Lava
/// never requests, and never holds, access to the whole photo library. That is also
/// why the app ships no `NSPhotoLibraryUsageDescription` — there is no library
/// access to justify.
enum ShareableFilterImageDecoder {
    /// Decodes the single Lava filter code in `imageData`.
    ///
    /// - Throws: ``ShareableFilterImageDecodeError`` describing precisely which of
    ///   the four failure shapes occurred.
    static func decode(imageData: Data) async throws -> ShareableFilterConfiguration {
        do {
            try SharedFilterImageLimits.validate(byteCount: imageData.count)
        } catch {
            throw ShareableFilterImageDecodeError.imageTooLarge
        }
        return try await decode(source: CGImageSourceCreateWithData(imageData as CFData, sourceOptions))
    }

    /// Decodes the single Lava filter code in the image at `fileURL`.
    ///
    /// Preferred over ``decode(imageData:)``: the file is inspected and memory-mapped
    /// rather than read into memory, so an oversized asset is refused on its declared
    /// size before any of it is resident. Reading the bytes first would put the whole
    /// asset in memory before any cap could look at it — which is exactly what the
    /// byte cap is supposed to prevent.
    static func decode(fileURL: URL) async throws -> ShareableFilterConfiguration {
        let byteCount = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int) ?? nil
        guard let byteCount else {
            throw ShareableFilterImageDecodeError.unreadableImage
        }
        do {
            try SharedFilterImageLimits.validate(byteCount: byteCount)
        } catch {
            throw ShareableFilterImageDecodeError.imageTooLarge
        }
        return try await decode(source: CGImageSourceCreateWithURL(fileURL as CFURL, sourceOptions))
    }

    /// Never build a decoded-image cache for a one-shot scan.
    ///
    /// Computed rather than stored: `CFDictionary` is not `Sendable`, so a static
    /// constant would be shared mutable state under strict concurrency.
    private static var sourceOptions: CFDictionary {
        [kCGImageSourceShouldCache: false] as CFDictionary
    }

    private static func decode(source: CGImageSource?) async throws -> ShareableFilterConfiguration {
        let cgImage = try boundedImage(from: source)
        let payloads = try await detectQRPayloads(in: cgImage)

        // Every candidate goes through the one strict parser. A photo can contain
        // any number of unrelated QR codes; only canonical Lava links or raw LF1
        // codes are considered, and everything else is simply not a candidate.
        var configurations: [ShareableFilterConfiguration] = []
        var seenPayloads: Set<String> = []
        for payload in payloads {
            // Vision reports the same physical code more than once for some images;
            // dedupe on the payload so one code cannot look like an ambiguous pair.
            guard seenPayloads.insert(payload).inserted else { continue }
            guard let configuration = try? ShareableFilterLink.decode(payload) else { continue }
            configurations.append(configuration)
        }

        guard !configurations.isEmpty else {
            throw ShareableFilterImageDecodeError.noLavaFilterQRCode
        }
        guard configurations.count == 1 else {
            // Two different valid payloads is an ambiguous instruction. Picking one
            // would silently import a filter the user did not choose.
            throw ShareableFilterImageDecodeError.ambiguousLavaFilterQRCodes
        }
        return configurations[0]
    }

    /// A bitmap bounded *before* any full-resolution decode ever happens.
    ///
    /// Deliberately not `UIImage(data:)` followed by a resize: touching `.cgImage`
    /// on a data-backed `UIImage` decodes the original bitmap first, so the resize
    /// arrives too late to bound anything and the byte cap does not constrain peak
    /// memory at all (see ``SharedFilterImageLimits``). ImageIO instead reads the
    /// declared dimensions from the header without decoding, and then produces the
    /// thumbnail directly at the bounded size.
    private static func boundedImage(from source: CGImageSource?) throws -> CGImage {
        guard let source, CGImageSourceGetCount(source) > 0 else {
            throw ShareableFilterImageDecodeError.unreadableImage
        }

        // Header read only — this allocates no bitmap, which is the whole point.
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, sourceOptions)
            as? [CFString: Any]
        guard let width = properties?[kCGImagePropertyPixelWidth] as? Int,
              let height = properties?[kCGImagePropertyPixelHeight] as? Int
        else {
            throw ShareableFilterImageDecodeError.unreadableImage
        }

        do {
            try SharedFilterImageLimits.validate(pixelWidth: width, pixelHeight: height)
        } catch SharedFilterImageLimits.Rejection.tooManyPixels {
            throw ShareableFilterImageDecodeError.imageTooLarge
        } catch {
            throw ShareableFilterImageDecodeError.unreadableImage
        }

        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            // Honour EXIF orientation so a rotated photo presents the code upright.
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: SharedFilterImageLimits.maximumDetectionEdge,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else {
            throw ShareableFilterImageDecodeError.unreadableImage
        }
        return thumbnail
    }

    /// Runs QR detection off the main actor and returns every payload string found.
    private static func detectQRPayloads(in cgImage: CGImage) async throws -> [String] {
        try await Task.detached(priority: .userInitiated) {
            let request = VNDetectBarcodesRequest()
            // QR only. Widening this would start accepting symbologies the share
            // format never uses, for no benefit.
            request.symbologies = [.qr]

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                throw ShareableFilterImageDecodeError.unreadableImage
            }
            return (request.results ?? []).compactMap(\.payloadStringValue)
        }.value
    }
}
