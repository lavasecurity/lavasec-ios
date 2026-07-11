import Foundation
import XCTest

final class RepositoryTopologySourceTests: XCTestCase {
    func testDocumentedDeploymentFloorAndPackageLayersStayCurrent() throws {
        XCTAssertTrue(try readSource(.readme).contains("iOS 18+"))
        XCTAssertFalse(try readSource(.readme).contains("iOS 17+"))
        let guide = try readSource(.moduleBoundaries)
        for layer in [
            "LavaSecKit",
            "LavaSecNetworking",
            "LavaSecDNS",
            "LavaSecFilterPipeline",
            "LavaSecPresentation",
            "LavaSecAppServices",
        ] {
            XCTAssertTrue(guide.contains(layer), "missing documented layer: \(layer)")
        }
    }

    func testNetworkingLayerOwnsPinnedFetcherAndFilterPipelineDependsOnIt() throws {
        let manifest = try readSource(.package)

        XCTAssertTrue(
            manifest.contains(#".library(name: "LavaSecNetworking", targets: ["LavaSecNetworking"])"#),
            "the networking layer must be available as its own package product"
        )

        let networkingTarget = packageTargetBlock(named: "LavaSecNetworking", in: manifest)
        XCTAssertNotNil(networkingTarget, "Package.swift must define the LavaSecNetworking target")
        XCTAssertTrue(
            networkingTarget?.contains(#"dependencies: ["LavaSecKit"]"#) == true,
            "LavaSecNetworking must depend only on LavaSecKit"
        )

        let filterPipelineTarget = packageTargetBlock(named: "LavaSecFilterPipeline", in: manifest)
        XCTAssertTrue(
            filterPipelineTarget?.contains(#"dependencies: ["LavaSecKit", "LavaSecNetworking"]"#) == true,
            "LavaSecFilterPipeline must depend on Kit and Networking"
        )
        XCTAssertFalse(
            filterPipelineTarget?.contains("LavaSecDNS") == true,
            "LavaSecFilterPipeline must not retain a DNS-layer dependency"
        )

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: sourceFileURL(.pinnedPublicHTTPSFetcher).path),
            "the pinned HTTPS fetcher must live in LavaSecNetworking"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: expectedAbsentSourceFileURL(.dnsPinnedPublicHTTPSFetcher).path
            ),
            "the obsolete LavaSecDNS fetcher path must be absent"
        )
    }

    func testPresentationLayerOwnsAnimationWhileKitOwnsGuardianState() throws {
        let manifest = try readSource(.package)

        XCTAssertTrue(
            manifest.contains(#".library(name: "LavaSecPresentation", targets: ["LavaSecPresentation"])"#),
            "the presentation layer must be available as its own package product"
        )

        let presentationTarget = packageTargetBlock(named: "LavaSecPresentation", in: manifest)
        XCTAssertNotNil(presentationTarget, "Package.swift must define the LavaSecPresentation target")
        XCTAssertTrue(
            presentationTarget?.contains(#"dependencies: ["LavaSecKit"]"#) == true,
            "LavaSecPresentation must depend only on LavaSecKit"
        )

        let coreTarget = packageTargetBlock(named: "LavaSecCore", in: manifest)
        XCTAssertTrue(
            coreTarget?.contains("LavaSecPresentation") == true,
            "the compatibility façade must re-export the presentation layer"
        )

        let coreProductTargets = try packageProductTargets(
            named: "LavaSecCore",
            in: manifest
        )
        XCTAssertTrue(
            coreProductTargets.contains("LavaSecPresentation"),
            "the compatibility product must include the presentation layer"
        )

        let projectManifest = try readSource(.projectYAML)
        let appTarget = projectTargetBlock(named: "LavaSec", endingBefore: "LavaSecTunnel", in: projectManifest)
        let tunnelTarget = projectTargetBlock(named: "LavaSecTunnel", endingBefore: "LavaSecWidget", in: projectManifest)
        let widgetTarget = projectTargetBlock(named: "LavaSecWidget", endingBefore: "LavaSecIntents", in: projectManifest)
        XCTAssertTrue(appTarget?.contains("product: LavaSecPresentation") == true)
        XCTAssertTrue(widgetTarget?.contains("product: LavaSecPresentation") == true)
        XCTAssertFalse(
            tunnelTarget?.contains("product: LavaSecPresentation") == true,
            "the packet tunnel must not link UI animation policy"
        )
        XCTAssertFalse(
            tunnelTarget?.contains("product: LavaSecCore") == true,
            "the packet tunnel must not link the compatibility façade"
        )

        for sourceFile in [SourceFile.guardView, .developerPreviewViews, .softShieldGuardian] {
            XCTAssertTrue(
                try readSource(sourceFile).contains("import LavaSecPresentation"),
                "\(sourceFile.rawValue) must import the narrow presentation product"
            )
        }

        let stateURL = sourceFileURL(.guardianMascotState)
        let animationURL = sourceFileURL(.guardianMascotAnimation)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: stateURL.path),
            "GuardianMascotState must live in LavaSecKit"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: animationURL.path),
            "guardian frames and plans must live in LavaSecPresentation"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: expectedAbsentSourceFileURL(.appServicesGuardianMascotAnimation).path
            ),
            "the obsolete LavaSecAppServices guardian path must be absent"
        )

        if let stateSource = try? readSource(.guardianMascotState) {
            XCTAssertTrue(stateSource.contains("public enum GuardianMascotState"))
            XCTAssertFalse(stateSource.contains("GuardianMascotFrame"))
            XCTAssertFalse(stateSource.contains("GuardianMascotAnimationPlan"))
        }
        if let animationSource = try? readSource(.guardianMascotAnimation) {
            XCTAssertTrue(animationSource.contains("public struct GuardianMascotFrame"))
            XCTAssertTrue(animationSource.contains("public struct GuardianMascotAnimationPlan"))
            XCTAssertFalse(animationSource.contains("public enum GuardianMascotState"))
        }
    }

    private func packageTargetBlock(named targetName: String, in manifest: String) -> String? {
        try? sourceBlock(
            in: manifest,
            startingAt: ".target(\n            name: \"\(targetName)\"",
            endingBefore: "\n        ),"
        )
    }

    private func packageProductTargets(named productName: String, in manifest: String) throws -> [String] {
        let declaration = try sourceBlock(
            in: manifest,
            startingAt: ".library(name: \"\(productName)\",",
            endingBefore: ")"
        )
        let targetsMarker = try XCTUnwrap(declaration.range(of: "targets: ["))
        let targetsEnd = try XCTUnwrap(
            declaration[targetsMarker.upperBound...].firstIndex(of: "]")
        )

        return declaration[targetsMarker.upperBound..<targetsEnd]
            .split(separator: ",")
            .map { target in
                target.trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
    }

    private func projectTargetBlock(
        named targetName: String,
        endingBefore nextTargetName: String,
        in manifest: String
    ) -> String? {
        try? sourceBlock(
            in: manifest,
            startingAt: "  \(targetName):\n",
            endingBefore: "  \(nextTargetName):\n"
        )
    }
}
