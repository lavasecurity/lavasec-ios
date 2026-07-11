import Foundation
import XCTest

final class ModuleBoundarySourceTests: XCTestCase {
    private let layerProducts = [
        "LavaSecKit",
        "LavaSecNetworking",
        "LavaSecDNS",
        "LavaSecFilterPipeline",
        "LavaSecPresentation",
        "LavaSecAppServices",
    ]

    private var expectedPackageProducts: [String: [String]] {
        var products = Dictionary(uniqueKeysWithValues: layerProducts.map { ($0, [$0]) })
        products["LavaSecCore"] = ["LavaSecCore"] + layerProducts
        return products
    }

    private var expectedLayerSourcePaths: [String: String] {
        Dictionary(uniqueKeysWithValues: layerProducts.map { ($0, "Sources/\($0)") })
    }

    private var expectedConsumerProducts: [String: [String]] {
        [
            "LavaSec": layerProducts,
            "LavaSecTunnel": [
                "LavaSecKit",
                "LavaSecNetworking",
                "LavaSecDNS",
                "LavaSecFilterPipeline",
            ],
            "LavaSecWidget": ["LavaSecKit", "LavaSecPresentation"],
            "LavaSecIntents": ["LavaSecKit", "LavaSecFilterPipeline"],
        ]
    }

    private let expectedNonProductionTargetTypes = [
        "LavaSecUITests": "bundle.ui-testing",
    ]

    func testPackageExposesExactProductsAndCompatibilityFacade() throws {
        let package = try dumpPackage(at: packageRootURL)

        XCTAssertEqual(try package.libraryProducts(), expectedPackageProducts)
        XCTAssertEqual(
            try package.targetDependencies(
                named: "LavaSecCore",
                expectedType: "regular"
            ),
            layerProducts
        )
        XCTAssertEqual(
            try package.targetDependencies(
                named: "LavaSecCoreFacadeCompileTests",
                expectedType: "test"
            ),
            ["LavaSecCore"]
        )
        try package.validateTargetSourcePaths(expectedLayerSourcePaths)
    }

    func testProductionTargetsLinkExactApprovedProductMatrix() throws {
        let project = try readSource(.projectYAML)
        let targets = try classifiedProductionTargets(in: project)

        for target in targets {
            let expectedProducts = try XCTUnwrap(expectedConsumerProducts[target.name])
            XCTAssertEqual(
                target.localPackageProducts,
                expectedProducts,
                "\(target.name) must link exactly its approved local package products"
            )
        }
    }

    func testProductionSourcesDoNotNameCompatibilityFacade() throws {
        let project = try readSource(.projectYAML)
        let sourcePaths = Set(
            try classifiedProductionTargets(in: project)
                .flatMap(\.sourcePaths)
                .filter { $0.hasSuffix(".swift") }
        )
        let sourceURLs = sourcePaths.map { packageRootURL.appendingPathComponent($0) }

        XCTAssertEqual(try productionFacadeIdentifiers(in: sourceURLs), [])
    }

    func testValidatorsRejectDeliberatelyContaminatedFixtures() throws {
        let contaminatedProject = """
        targets:
          LavaSec:
            sources:
              # product: LavaSecDNS
              - path: LavaSecApp/Fake.swift
            dependencies:
              - package: LavaSecPackage
                product: LavaSecKit
              - package: LavaSecPackage
                product: LavaSecCore
          LavaSecTunnel:
            dependencies:
              - package: LavaSecPackage
                product: LavaSecKit
          Decoy:
            dependencies:
              - package: LavaSecPackage
                product: LavaSecNetworking
        """
        XCTAssertEqual(
            try localPackageProducts(for: "LavaSec", in: contaminatedProject),
            ["LavaSecKit", "LavaSecCore"]
        )
        XCTAssertNotEqual(
            try localPackageProducts(for: "LavaSec", in: contaminatedProject),
            expectedConsumerProducts["LavaSec"]
        )

        XCTAssertEqual(
            exactFacadeIdentifierLines(in: """
            // import LavaSecCore
            import LavaSecCorePlus
            import LavaSecCore
            """),
            [1, 3]
        )
    }

    func testDumpedPackageValidatorRejectsExtraProductAndDependency() throws {
        var products: [[String: Any]] = expectedPackageProducts.map { name, targets in
            [
                "name": name,
                "targets": targets,
                "type": ["library": ["automatic"]],
            ]
        }
        products.append([
            "name": "Forbidden",
            "targets": ["LavaSecKit"],
            "type": ["library": ["dynamic"]],
        ])
        let dependencies: [[String: Any]] = (layerProducts + ["ForbiddenTarget"]).map {
            ["byName": [$0, NSNull()]]
        }
        let data = try JSONSerialization.data(withJSONObject: [
            "products": products,
            "targets": [[
                "name": "LavaSecCore",
                "type": "regular",
                "dependencies": dependencies,
            ]],
        ])
        let package = try decodeDumpedPackage(from: data)

        XCTAssertNotEqual(try package.libraryProducts(), expectedPackageProducts)
        XCTAssertNotEqual(
            try package.targetDependencies(named: "LavaSecCore"),
            layerProducts
        )
    }

    func testDumpedPackageValidatorRejectsRelocatedLayerTarget() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "products": [],
            "targets": [[
                "name": "LavaSecNetworking",
                "type": "regular",
                "path": "Unlinted/LavaSecNetworking",
                "dependencies": [],
            ]],
        ])
        let package = try decodeDumpedPackage(from: data)

        XCTAssertThrowsError(
            try package.validateTargetSourcePaths([
                "LavaSecNetworking": "Sources/LavaSecNetworking",
            ])
        ) { error in
            XCTAssertEqual(
                String(describing: error),
                "package target LavaSecNetworking has source path "
                    + "Unlinted/LavaSecNetworking, expected Sources/LavaSecNetworking"
            )
        }
    }

    func testProjectParserAcceptsSemanticYAMLAndStillFindsForbiddenProducts() throws {
        let project = #"""
        targets:
          LavaSec:
            dependencies:
              - product: "LavaSecKit" # approved local product
                package: 'LavaSecPackage'
              - package: "LavaSecPackage" # reordered and quoted
                product: 'LavaSecCore' # forbidden compatibility façade
        """#

        XCTAssertEqual(
            try localPackageProducts(for: "LavaSec", in: project),
            ["LavaSecKit", "LavaSecCore"]
        )
    }

    func testProjectParserDiscoversNativeTargets() throws {
        let project = """
        packages:
          LavaSecPackage:
            path: .
        targets:
          LavaSec:
            type: application
            platform: iOS
            sources:
              - path: LavaSecApp/Main.swift
          LavaSecTunnel:
            type: app-extension
            platform: iOS
            sources:
              - path: LavaSecTunnel/PacketTunnelProvider.swift
          LavaSecIntents:
            type: extensionkit-extension
            platform: iOS
            sources:
              - path: LavaSecIntents/FocusFilterIntent.swift
          LavaSecUITests:
            type: bundle.ui-testing
            platform: iOS
            sources:
              - path: LavaSecUITests/CoreFlowDeviceTests.swift
        """

        let targets = try YAMLBoundaryParser(source: project).xcodeTargets()

        XCTAssertEqual(
            targets.map(\.name),
            ["LavaSec", "LavaSecTunnel", "LavaSecIntents", "LavaSecUITests"]
        )
        XCTAssertEqual(
            targets.map(\.type),
            ["application", "app-extension", "extensionkit-extension", "bundle.ui-testing"]
        )
        XCTAssertEqual(targets.map(\.platform), ["iOS", "iOS", "iOS", "iOS"])
        XCTAssertEqual(targets[0].sourcePaths, ["LavaSecApp/Main.swift"])
        XCTAssertEqual(targets[3].sourcePaths, ["LavaSecUITests/CoreFlowDeviceTests.swift"])
    }

    func testProjectParserPreservesEmbeddedHashInUnquotedSourcePath() throws {
        let project = """
        packages:
          LavaSecPackage:
            path: .
        targets:
          LavaSec:
            type: application
            platform: iOS
            sources:
              - path: LavaSecApp/Safe.swift#Injected.swift # reviewed membership
        """

        let targets = try YAMLBoundaryParser(source: project).xcodeTargets()

        XCTAssertEqual(
            targets.first?.sourcePaths,
            ["LavaSecApp/Safe.swift#Injected.swift"]
        )
    }

    func testProjectParserRejectsSharedShellCommandBreakpoints() throws {
        let project = """
        name: LavaSec
        packages:
          LavaSecPackage:
            path: .
        breakpoints:
          - type: Symbolic
            symbol: malloc
            enabled: true
            continueAfterRunningActions: true
            actions:
              - type: ShellCommand
                path: /usr/bin/touch
                arguments: /tmp/lavasec-breakpoint-pwned
                waitUntilDone: true
        targets:
          LavaSec:
            type: application
            platform: iOS
            sources:
              - path: LavaSecApp/Main.swift
        """

        XCTAssertThrowsError(try YAMLBoundaryParser(source: project).xcodeTargets())
    }

    func testProjectParserRejectsAggregateTargets() throws {
        let project = """
        packages:
          LavaSecPackage:
            path: .
        targets:
          LavaSec:
            type: application
            platform: iOS
        aggregateTargets:
          EscapeAggregate:
            buildScripts:
              - script: echo hacked
        """

        XCTAssertThrowsError(try YAMLBoundaryParser(source: project).xcodeTargets())
    }

    func testProjectParserRejectsXcodeGenSemanticExpansion() throws {
        let packages = """
        packages:
          LavaSecPackage:
            path: .

        """
        let fixtures = [
            """
            include: extra.yml
            targets:
              LavaSec:
                type: application
            """,
            """
            targetTemplates:
              Escape:
                sources:
                  - path: Escaped/Bad.swift
            targets:
              LavaSec:
                templates:
                  - Escape
                type: application
            """,
            """
            escape: &escape
              dependencies:
                - package: LavaSecPackage
                  product: LavaSecCore
            targets:
              LavaSec:
                <<: *escape
                type: application
            """,
            """
            targets:
              LavaSec:
                type: application
                "sources:REPLACE":
                  - path: Escaped/Bad.swift
            """,
        ]

        for fixture in fixtures {
            XCTAssertThrowsError(
                try YAMLBoundaryParser(source: packages + fixture).xcodeTargets()
            )
        }
    }

    func testProjectParserRejectsAnAliasForTheRepoRootPackage() throws {
        let project = """
        packages:
          LavaSecPackage:
            path: .
          AliasPackage:
            path: .
        targets:
          LavaSec:
            type: application
            dependencies:
              - package: LavaSecPackage
                product: LavaSecKit
              - package: AliasPackage
                product: LavaSecCore
        """

        XCTAssertThrowsError(try YAMLBoundaryParser(source: project).xcodeTargets())
    }

    func testProjectParserRejectsReservedProductsFromRemotePackageAliases() throws {
        let project = """
        packages:
          LavaSecPackage:
            path: .
          AliasPackage:
            url: https://github.com/lavasecurity/lavasec-ios
            branch: main
        targets:
          LavaSec:
            type: application
            dependencies:
              - package: LavaSecPackage
                product: LavaSecKit
              - package: AliasPackage
                product: LavaSecCore
        """

        XCTAssertThrowsError(try YAMLBoundaryParser(source: project).xcodeTargets())
    }

    func testProjectParserClassifiesRemotePackageProducts() throws {
        let packages = """
        packages:
          LavaSecPackage:
            path: .
          GoogleSignIn:
            url: https://github.com/google/GoogleSignIn-iOS
            majorVersion: 9.1.0

        """
        let approved = packages + """
        targets:
          LavaSec:
            type: application
            platform: iOS
            dependencies:
              - package: GoogleSignIn
                product: GoogleSignIn
        """
        XCTAssertNoThrow(try YAMLBoundaryParser(source: approved).xcodeTargets())

        let unapproved = packages + """
        targets:
          LavaSecTunnel:
            type: app-extension
            platform: iOS
            dependencies:
              - package: GoogleSignIn
                product: GoogleSignInSwift
        """
        XCTAssertThrowsError(try YAMLBoundaryParser(source: unapproved).xcodeTargets())
    }

    func testProjectParserRejectsMultiPlatformTargetExpansion() throws {
        let project = """
        packages:
          LavaSecPackage:
            path: .
        targets:
          LavaSec:
            type: application
            platform: auto
            sources:
              - path: LavaSecApp/Main.swift
        """

        XCTAssertThrowsError(try YAMLBoundaryParser(source: project).xcodeTargets())
    }

    func testProjectParserRejectsXcodeGenEnvironmentSubstitution() throws {
        let project = """
        packages:
          LavaSecPackage:
            path: .
        targets:
          LavaSec:
            type: application
            platform: iOS
            sources:
              - path: LavaSecApp/${ESCAPE}/Bad.swift
        """

        XCTAssertThrowsError(try YAMLBoundaryParser(source: project).xcodeTargets())
    }

    func testProjectParserRejectsGeneratedTargetRenaming() throws {
        let project = """
        packages:
          LavaSecPackage:
            path: .
        targets:
          LavaSec:
            name: RenamedNativeTarget
            type: application
            platform: iOS
            sources:
              - path: LavaSecApp/Main.swift
        """

        XCTAssertThrowsError(try YAMLBoundaryParser(source: project).xcodeTargets())
    }

    func testProjectParserRejectsUnapprovedGenerationCommands() throws {
        let fixtures = [
            "preGenCommand: python3 scripts/mutate-sources.py",
            "postGenCommand: python3 scripts/mutate-project.py",
            "projectFormat: xcode16_3",
        ]

        for option in fixtures {
            let project = """
            options:
              \(option)
            packages:
              LavaSecPackage:
                path: .
            targets:
              LavaSec:
                type: application
                platform: iOS
                sources:
                  - path: LavaSecApp/Main.swift
            """
            XCTAssertThrowsError(try YAMLBoundaryParser(source: project).xcodeTargets())
        }
    }

    func testProjectParserRejectsProjectFormatOverride() throws {
        let project = """
        options:
          settingPresets: none
          xcodeVersion: "26.3"
          developmentLanguage: en
          defaultConfig: Release
          postGenCommand: python3 scripts/xcodegen-fixups.py
          fileTypes:
            icon:
              file: true
              buildPhase: resources
          projectFormat: xcode16_3
        packages:
          LavaSecPackage:
            path: .
        targets:
          LavaSec:
            type: application
            platform: iOS
            sources:
              - path: LavaSecApp/Main.swift
        """

        XCTAssertThrowsError(try YAMLBoundaryParser(source: project).xcodeTargets())
    }

    func testProjectParserRejectsLegacyAndImplicitGraphExpansion() throws {
        let fixtures: [(name: String, project: String)] = [
            (
                "deprecated localPackages",
                """
                localPackages:
                  - Evil/LavaSecPackage
                packages:
                  LavaSecPackage:
                    path: .
                targets:
                  LavaSec:
                    type: application
                    platform: iOS
                """
            ),
            (
                "transitive target dependencies",
                """
                packages:
                  LavaSecPackage:
                    path: .
                targets:
                  LavaSecWidget:
                    type: app-extension
                    platform: iOS
                    transitivelyLinkDependencies: true
                """
            ),
            (
                "global Swift file-type override",
                """
                options:
                  postGenCommand: python3 scripts/xcodegen-fixups.py
                  fileTypes:
                    swift:
                      buildPhase: resources
                packages:
                  LavaSecPackage:
                    path: .
                targets:
                  LavaSec:
                    type: application
                    platform: iOS
                """
            ),
            (
                "legacy target",
                """
                packages:
                  LavaSecPackage:
                    path: .
                targets:
                  LavaSec:
                    type: application
                    platform: iOS
                    legacy:
                      toolPath: /usr/bin/true
                """
            ),
            (
                "build-tool plugin",
                """
                packages:
                  LavaSecPackage:
                    path: .
                targets:
                  LavaSec:
                    type: application
                    platform: iOS
                    buildToolPlugins:
                      - plugin: EscapePlugin
                        package: LavaSecPackage
                """
            ),
            (
                "pre-build script",
                """
                packages:
                  LavaSecPackage:
                    path: .
                targets:
                  LavaSec:
                    type: application
                    platform: iOS
                    preBuildScripts:
                      - script: echo hacked
                """
            ),
            (
                "generated Info.plist",
                """
                packages:
                  LavaSecPackage:
                    path: .
                targets:
                  LavaSec:
                    type: application
                    platform: iOS
                    info:
                      path: LavaSecApp/Main.swift
                """
            ),
            (
                "generated entitlements",
                """
                packages:
                  LavaSecPackage:
                    path: .
                targets:
                  LavaSec:
                    type: application
                    platform: iOS
                    entitlements:
                      path: LavaSecApp/Main.swift
                """
            ),
            (
                "target-local scheme action",
                """
                packages:
                  LavaSecPackage:
                    path: .
                targets:
                  LavaSec:
                    type: application
                    platform: iOS
                    scheme:
                      preActions:
                        - script: echo hacked
                """
            ),
            (
                "scheme template",
                """
                schemeTemplates:
                  Escape:
                    preActions:
                      - script: echo hacked
                packages:
                  LavaSecPackage:
                    path: .
                targets:
                  LavaSec:
                    type: application
                    platform: iOS
                """
            ),
            (
                "shared-scheme pre-action",
                """
                packages:
                  LavaSecPackage:
                    path: .
                targets:
                  LavaSec:
                    type: application
                    platform: iOS
                schemes:
                  LavaSec:
                    build:
                      targets:
                        LavaSec: all
                      preActions:
                        - script: echo hacked
                """
            ),
            (
                "shared-scheme post-action",
                """
                packages:
                  LavaSecPackage:
                    path: .
                targets:
                  LavaSec:
                    type: application
                    platform: iOS
                schemes:
                  LavaSec:
                    build:
                      targets:
                        LavaSec: all
                      postActions:
                        - script: echo hacked
                """
            ),
        ]

        for fixture in fixtures {
            XCTAssertThrowsError(
                try YAMLBoundaryParser(source: fixture.project).xcodeTargets(),
                fixture.name
            )
        }
    }

    func testProductionSourceSelectionDeduplicatesSharedAndExcludesTestOnlySources() throws {
        let project = """
        packages:
          LavaSecPackage:
            path: .
        targets:
          LavaSec:
            type: application
            platform: iOS
            sources:
              - path: LavaSecApp/Main.swift
              - path: Shared/Common.swift
          LavaSecTunnel:
            type: app-extension
            platform: iOS
            sources:
              - path: LavaSecTunnel/PacketTunnelProvider.swift
              - path: Shared/Common.swift
          LavaSecUITests:
            type: bundle.ui-testing
            platform: iOS
            sources:
              - path: Shared/TestOnly.swift
        """
        let productionNames = Set(["LavaSec", "LavaSecTunnel"])
        let targets = try YAMLBoundaryParser(source: project).xcodeTargets()

        let paths = Set(
            targets
                .filter { productionNames.contains($0.name) }
                .flatMap(\.sourcePaths)
                .filter { $0.hasSuffix(".swift") }
        )

        XCTAssertEqual(
            paths,
            Set([
                "LavaSecApp/Main.swift",
                "LavaSecTunnel/PacketTunnelProvider.swift",
                "Shared/Common.swift",
            ])
        )
        XCTAssertFalse(paths.contains("Shared/TestOnly.swift"))
    }

    func testProjectParserRejectsDuplicateAndUnconsumedDependencyKeys() throws {
        let duplicateProduct = """
        targets:
          LavaSec:
            dependencies:
              - package: LavaSecPackage
                product: LavaSecKit
                product: LavaSecCore
        """
        XCTAssertThrowsError(try localPackageProducts(for: "LavaSec", in: duplicateProduct))

        let unconsumedKey = """
        targets:
          LavaSec:
            dependencies:
              - package: LavaSecPackage
                product: LavaSecKit
                unexpected: true
        """
        XCTAssertThrowsError(try localPackageProducts(for: "LavaSec", in: unconsumedKey))
    }

    func testProjectParserRejectsUnsupportedEscapesThatCouldHideLocalPackage() {
        let escapedPackage = #"""
        targets:
          LavaSec:
            dependencies:
              - package: "LavaSec\u0050ackage"
                product: LavaSecCore
        """#

        XCTAssertThrowsError(
            try localPackageProducts(for: "LavaSec", in: escapedPackage)
        )
    }

    func testProjectParserRejectsUnsupportedYAMLNodeSyntax() {
        let unsupportedValues = [
            "&local LavaSecPackage",
            "!!str LavaSecPackage",
            "*local",
            "[LavaSecPackage]",
            "{value: LavaSecPackage}",
            "|",
            ">",
        ]

        for packageValue in unsupportedValues {
            let project = """
            targets:
              LavaSec:
                dependencies:
                  - package: \(packageValue)
                    product: LavaSecCore
            """
            XCTAssertThrowsError(
                try localPackageProducts(for: "LavaSec", in: project),
                "unsupported YAML value must fail closed: \(packageValue)"
            )
        }
    }

    func testProductionIdentifierRatchetRejectsEveryExactOccurrence() {
        let source = #"""
           import LavaSecCore
        import LavaSecCore // trailing comment
        @_exported @preconcurrency import LavaSecCore
        @_implementationOnly import LavaSecCore
        @_spi(Friends) import LavaSecCore
        public import LavaSecCore
        import let LavaSecCore.forbiddenGlobal
        // import LavaSecCore
        let decoy = "import LavaSecCore"
        /*
        import LavaSecCore
        */
        import LavaSecCorePlus
        """#

        XCTAssertEqual(
            exactFacadeIdentifierLines(in: source),
            Array(1...9) + [11]
        )
    }

    func testProductionScannerIncludesHiddenFilesAndFailsMissingRoots() throws {
        let fixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("LavaSecModuleBoundary-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: fixtureRoot,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }

        let hiddenSource = fixtureRoot.appendingPathComponent(".Hidden.swift")
        try Data("import LavaSecCore\n".utf8).write(to: hiddenSource)
        XCTAssertEqual(
            try productionFacadeIdentifiers(in: [hiddenSource], relativeTo: fixtureRoot),
            [".Hidden.swift:1"]
        )

        let linkTarget = fixtureRoot.appendingPathComponent("LinkedSource.txt")
        try Data("import LavaSecCore\n".utf8).write(to: linkTarget)
        let linkedSource = fixtureRoot.appendingPathComponent("Linked.swift")
        try FileManager.default.createSymbolicLink(
            at: linkedSource,
            withDestinationURL: linkTarget
        )
        XCTAssertEqual(
            try productionFacadeIdentifiers(
                in: [hiddenSource, linkedSource],
                relativeTo: fixtureRoot
            ),
            [".Hidden.swift:1", "Linked.swift:1"]
        )

        let missingRoot = fixtureRoot.appendingPathComponent("Missing")
        XCTAssertThrowsError(
            try productionFacadeIdentifiers(in: [missingRoot], relativeTo: fixtureRoot)
        )
    }

    private func classifiedProductionTargets(
        in project: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> [XcodeBoundaryTarget] {
        let targets = try YAMLBoundaryParser(source: project).xcodeTargets()
        let targetsByName = Dictionary(uniqueKeysWithValues: targets.map { ($0.name, $0) })
        let expectedNames = Set(expectedConsumerProducts.keys)
            .union(expectedNonProductionTargetTypes.keys)
        XCTAssertEqual(
            Set(targetsByName.keys),
            expectedNames,
            "Every native Xcode target must be classified as a production consumer or explicit non-production exemption.",
            file: file,
            line: line
        )
        for (name, expectedType) in expectedNonProductionTargetTypes {
            XCTAssertEqual(
                targetsByName[name]?.type,
                expectedType,
                "The non-production exemption for \(name) is pinned to its target type.",
                file: file,
                line: line
            )
        }
        return targets.filter { expectedConsumerProducts[$0.name] != nil }
    }

    private func localPackageProducts(for targetName: String, in project: String) throws -> [String] {
        let packageDefinitions = """
        packages:
          LavaSecPackage:
            path: .

        """
        return try YAMLBoundaryParser(source: packageDefinitions + project)
            .localPackageProducts(for: targetName)
    }

    private func productionFacadeIdentifiers(
        in files: [URL],
        relativeTo baseURL: URL = packageRootURL
    ) throws -> [String] {
        var violations: [String] = []

        for fileURL in Set(files).sorted(by: { $0.path < $1.path }) {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(
                atPath: fileURL.path,
                isDirectory: &isDirectory
            ), !isDirectory.boolValue else {
                throw ModuleBoundaryParseError(
                    "missing production Swift source \(fileURL.path)"
                )
            }

            let source: String
            do {
                source = try String(contentsOf: fileURL, encoding: .utf8)
            } catch {
                throw ModuleBoundaryParseError(
                    "could not read production source \(fileURL.path): \(error)"
                )
            }
            for line in exactFacadeIdentifierLines(in: source) {
                let basePrefix = baseURL.standardizedFileURL.path + "/"
                let filePath = fileURL.standardizedFileURL.path
                let relativePath = filePath.hasPrefix(basePrefix)
                    ? String(filePath.dropFirst(basePrefix.count))
                    : filePath
                violations.append("\(relativePath):\(line)")
            }
        }
        return violations.sorted()
    }

    private func exactFacadeIdentifierLines(in source: String) -> [Int] {
        logicalLines(in: source).enumerated().compactMap { index, line in
            containsExactFacadeIdentifier(in: line) ? index + 1 : nil
        }
    }

    private func containsExactFacadeIdentifier(in source: String) -> Bool {
        let identifier = "LavaSecCore"
        var searchStart = source.startIndex
        while searchStart < source.endIndex,
              let range = source.range(
                  of: identifier,
                  range: searchStart..<source.endIndex
              ) {
            let previous = range.lowerBound == source.startIndex
                ? nil
                : source[source.index(before: range.lowerBound)]
            let next = range.upperBound == source.endIndex
                ? nil
                : source[range.upperBound]
            if previous.map(isIdentifierContinuation) != true,
               next.map(isIdentifierContinuation) != true {
                return true
            }
            searchStart = range.upperBound
        }
        return false
    }

    private func isIdentifierContinuation(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }

    private func logicalLines(in source: String) -> [String] {
        let characters = Array(source)
        var lines: [String] = []
        var current: [Character] = []
        var index = 0
        while index < characters.count {
            if characters[index] == "\r" || characters[index] == "\n" {
                lines.append(String(current))
                current.removeAll(keepingCapacity: true)
                if characters[index] == "\r",
                   index + 1 < characters.count,
                   characters[index + 1] == "\n" {
                    index += 1
                }
            } else {
                current.append(characters[index])
            }
            index += 1
        }
        lines.append(String(current))
        return lines
    }
}
