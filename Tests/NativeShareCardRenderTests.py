#!/usr/bin/env python3
"""Compile the actual SwiftUI share card and image importer for an iOS simulator.

No app code or test hook is shipped. Existing matching simulator build products
supply LavaSecKit/Presentation. Compilation is the default; --simulator explicitly
runs the executable on that already-booted simulator (never pass an active QA run).
PNG captures and Vision bounds are emitted by the runtime, not inferred from code.
If simulator Vision cannot initialize, use --render-only then compile/run
NativeShareCardHostDecode.swift on macOS against the captured output directory.
"""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import shutil
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--source-root', type=Path, default=Path(__file__).resolve().parents[1])
parser.add_argument('--products', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--render-only', action='store_true', help='Capture images without simulator Vision; requires separate host decode')
parser.add_argument('--simulator', help='Explicit already-booted simulator UUID; omitted means compile only')
args = parser.parse_args()
root, products, output = args.source_root.resolve(), args.products.resolve(), args.output.resolve()
output.mkdir(parents=True, exist_ok=True)
app = output / 'ShareCardRenderHarness.app'
app.mkdir(exist_ok=True)
files = ['LavaSecApp/ShareableFilterCard.swift', 'LavaSecApp/ShareableFilterImageDecoder.swift',
         'LavaSecApp/LavaStrings.swift', 'Shared/SoftShieldGuardian.swift', 'Shared/LavaActivityAttributes.swift']
sources = []
provenance = {}
for name in files:
    data = (root / name).read_bytes()
    target = output / Path(name).name
    target.write_bytes(data)
    sources.append(target)
    provenance[name] = hashlib.sha256(data).hexdigest()
# Extract the complete, unmodified QR generator declaration from its UI file.
qr_source = (root / 'LavaSecApp/ShareableFiltersUI.swift').read_text()
start = qr_source.index('enum LavaQRCode {')
end = qr_source.index('// MARK: - Share my filters', start)
qr = output / 'LavaQRCode.swift'
qr.write_text('import UIKit\nimport CoreImage.CIFilterBuiltins\n' + qr_source[start:end])
sources.append(qr)
provenance['LavaSecApp/ShareableFiltersUI.swift:LavaQRCode'] = hashlib.sha256(qr_source[start:end].encode()).hexdigest()
main = output / 'Harness.swift'
main.write_text(r'''
import Foundation
import UIKit
import SwiftUI
import Vision
import LavaSecKit

@main struct ShareCardRenderHarness {
    @MainActor static func main() async {
        do { try await check(); exit(0) }
        catch { fputs("Share card validation failed: \(error)\n", stderr); exit(1) }
    }
    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain: "ShareCardRenderHarness", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    @MainActor static func check() async throws {
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        for name in ["render-results.json", "render-captures.json", "host-decode-results.json"] {
            try? FileManager.default.removeItem(at: output.appendingPathComponent(name))
        }
        let enabled = try CustomBlocklistSource(id: "custom-active", displayName: "Active public source", rawURL: "https://example.com/active.txt", createdAt: Date(timeIntervalSince1970: 0))
        let disabled = try CustomBlocklistSource(id: "custom-disabled", displayName: "Stored disabled source", rawURL: "https://example.org/disabled.txt", createdAt: Date(timeIntervalSince1970: 0))
        let fixtures: [(String, ShareableFilterConfiguration)] = [
            ("small-v2", ShareableFilterConfiguration(enabledBlocklistIDs: ["oisd-small"])),
            ("three-counts-v2", ShareableFilterConfiguration(enabledBlocklistIDs: ["oisd-small", enabled.id], blockedDomains: ["ads.example", "tracker.example"], customBlocklists: [enabled])),
            ("mixed-v2", ShareableFilterConfiguration(enabledBlocklistIDs: ["oisd-small", "hagezi-pro", enabled.id], blockedDomains: ["ads.example", "tracker.example"], customBlocklists: [enabled, disabled], allowedDomains: ["trusted.example", "allowed.example"]))
        ]
        var observations: [[String: Any]] = []
        for (name, configuration) in fixtures {
            let code = configuration.encodedConfigurationCode()
            let link = try ShareableFilterLink.url(forConfigurationCode: code).absoluteString
            let expected = try ShareableFilterLink.decode(link)
            try require(expected.schemaVersion == 2, "Fixture must be version 2")
            if name == "mixed-v2" {
                try require(expected.customBlocklists.count == 2 && !expected.enabledBlocklistIDs.contains(disabled.id), "Disabled source must survive the payload")
                try require(expected.allowedDomains?.count == 2, "Allowed exceptions must survive the payload")
            }
            var lightPixels: Data?
            for (appearance, style) in [("light", UIUserInterfaceStyle.light), ("dark", .dark)] {
                var rendered: UIImage?
                UITraitCollection(userInterfaceStyle: style).performAsCurrent {
                    rendered = ShareableFilterCardRenderer.render(configurationCode: code, configuration: configuration)
                }
                guard let rendered, let pixels = rendered.cgImage, let png = rendered.pngData() else {
                    throw NSError(domain: "Card did not render", code: 1)
                }
                try require(pixels.width == 1080 && pixels.height == 1350, "Actual exported PNG must be 1080 × 1350")
                let file = output.appendingPathComponent("\(name)-\(appearance).png")
                try png.write(to: file)
                if CommandLine.arguments.contains("--render-only") {
                    let imageData = pixels.dataProvider!.data! as Data
                    if let lightPixels { try require(imageData == lightPixels, "Export pixels must match across appearance") }
                    else { lightPixels = imageData }
                    observations.append(["fixture": name, "appearance": appearance, "png": file.lastPathComponent,
                        "pixels": [pixels.width, pixels.height], "expectedPayload": link, "schemaVersion": expected.schemaVersion])
                    continue
                }
                let request = VNDetectBarcodesRequest()
                request.symbologies = [.qr]
                try VNImageRequestHandler(cgImage: pixels).perform([request])
                let imported = try await ShareableFilterImageDecoder.decode(imageData: png)
                try require(imported == expected, "Actual card importer lost or changed payload fields")
                let matches = (request.results ?? []).filter { $0.payloadStringValue == link }
                try require(matches.count == 1, "Actual card must contain one exact canonical QR link")
                let bounds = matches[0].boundingBox
                let pixelBounds = CGRect(x: bounds.minX * Double(pixels.width), y: (1 - bounds.maxY) * Double(pixels.height), width: bounds.width * Double(pixels.width), height: bounds.height * Double(pixels.height))
                try require(pixelBounds.minX > 0 && pixelBounds.minY > 0 && pixelBounds.maxX < Double(pixels.width) && pixelBounds.maxY < Double(pixels.height), "QR must be fully inside exported card")
                let imageData = pixels.dataProvider!.data! as Data
                if let lightPixels { try require(imageData == lightPixels, "Export pixels must be identical in light and dark appearance") }
                else { lightPixels = imageData }
                observations.append(["fixture": name, "appearance": appearance, "png": file.lastPathComponent,
                    "pixels": [pixels.width, pixels.height], "qrPixelBoundsTopLeft": [pixelBounds.minX, pixelBounds.minY, pixelBounds.width, pixelBounds.height],
                    "exactPayloadDecoded": true, "fullConfigurationDecoded": true, "schemaVersion": expected.schemaVersion])
            }
        }
        let report: [String: Any] = ["runtime": UIDevice.current.systemVersion, "device": UIDevice.current.model, "observations": observations]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent(CommandLine.arguments.contains("--render-only") ? "render-captures.json" : "render-results.json"))
        print(CommandLine.arguments.contains("--render-only") ? "CAPTURED: \(observations.count) actual card PNGs; identical light/dark pixels; decoding not run" : "PASS: \(observations.count) production card renders; exact Vision payload and production importer round trips; identical light/dark pixels")
    }
}
''')
sources.append(main)
for locale in (products / 'LavaSec.app').glob('*.lproj'):
    shutil.copytree(locale, app / locale.name, dirs_exist_ok=True)
resource_bundle = products / 'LavaSec_LavaSecKit.bundle'
if resource_bundle.exists():
    shutil.copytree(resource_bundle, app / resource_bundle.name, dirs_exist_ok=True)
with (app / 'Info.plist').open('wb') as stream:
    plistlib.dump({'CFBundleIdentifier': 'com.lavasecurity.card-render-harness', 'CFBundleExecutable': 'ShareCardRenderHarness',
                  'CFBundleName': 'ShareCardRenderHarness', 'CFBundlePackageType': 'APPL', 'CFBundleDevelopmentRegion': 'en'}, stream)
sdk = subprocess.check_output(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path'], text=True).strip()
objects = [products / f'{name}.o' for name in ['LavaSecKit', 'LavaSecPresentation']]
for object_file in objects:
    provenance[str(object_file)] = hashlib.sha256(object_file.read_bytes()).hexdigest()
command = ['xcrun', '--sdk', 'iphonesimulator', 'swiftc', '-sdk', sdk, '-target', 'arm64-apple-ios18.0-simulator', '-I', str(products),
           '-module-cache-path', str(output / 'module-cache'), '-parse-as-library', '-lsqlite3',
           *map(str, sources), *map(str, objects), '-o', str(app / 'ShareCardRenderHarness')]
subprocess.run(command, check=True)
subprocess.run(['codesign', '--force', '--sign', '-', str(app)], check=True)
(output / 'source-provenance.json').write_text(json.dumps({'sourceHead': subprocess.check_output(['git', '-C', str(root), 'rev-parse', 'HEAD'], text=True).strip(), 'sha256': provenance, 'compileCommand': command}, indent=2) + '\n')
if args.simulator:
    subprocess.run(['xcrun', 'simctl', 'spawn', args.simulator, str(app / 'ShareCardRenderHarness'), str(output), *(['--render-only'] if args.render_only else [])], check=True)
else:
    print(f'Compiled only; no runtime claim. Run after active UI tests finish: xcrun simctl spawn <UUID> {app / "ShareCardRenderHarness"} {output}' + (' --render-only' if args.render_only else ''))
