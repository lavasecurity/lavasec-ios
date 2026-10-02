// Decode actual simulator-rendered card PNGs on macOS when the standalone
// simulator process cannot create Vision's inference context. This checks the
// complete QR payload and measured bounds; it does not run the iOS image importer.
import Foundation
import ImageIO
import Vision

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try? FileManager.default.removeItem(at: output.appendingPathComponent("host-decode-results.json"))
let captureData = try Data(contentsOf: output.appendingPathComponent("render-captures.json"))
let captures = try JSONSerialization.jsonObject(with: captureData) as! [String: Any]
let observations = captures["observations"] as! [[String: Any]]
var results: [[String: Any]] = []
for observation in observations {
    let filename = observation["png"] as! String
    let expected = observation["expectedPayload"] as! String
    let file = output.appendingPathComponent(filename)
    let source = CGImageSourceCreateWithURL(file as CFURL, nil)!
    let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
    let request = VNDetectBarcodesRequest()
    request.symbologies = [.qr]
    try VNImageRequestHandler(cgImage: image).perform([request])
    let matches = (request.results ?? []).filter { $0.payloadStringValue == expected }
    guard matches.count == 1 else {
        fatalError("\(filename): exact canonical payload was not decoded exactly once")
    }
    let bounds = matches[0].boundingBox
    let pixels = CGRect(x: bounds.minX * Double(image.width), y: (1 - bounds.maxY) * Double(image.height), width: bounds.width * Double(image.width), height: bounds.height * Double(image.height))
    guard pixels.minX > 0, pixels.minY > 0, pixels.maxX < Double(image.width), pixels.maxY < Double(image.height) else {
        fatalError("\(filename): QR is not contained in the card")
    }
    results.append(["png": filename, "pixels": [image.width, image.height], "qrPixelBoundsTopLeft": [pixels.minX, pixels.minY, pixels.width, pixels.height], "exactPayloadDecoded": true])
}
let report: [String: Any] = ["host": ProcessInfo.processInfo.operatingSystemVersionString, "decoder": "macOS Vision VNDetectBarcodesRequest", "productionIOSImageImporterExecuted": false, "observations": results]
try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("host-decode-results.json"))
print("PASS: host Vision decoded \(results.count) actual exported cards to their exact canonical links")
