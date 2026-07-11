import Foundation

private struct YAMLBoundaryLine {
    let indent: Int
    let content: String
    let number: Int
}

struct XcodeBoundaryTarget: Equatable {
    let name: String
    let type: String
    let platform: String
    let sourcePaths: [String]
    let localPackageProducts: [String]
}

struct YAMLBoundaryParser {
    private static let reservedLocalPackageProducts: Set<String> = [
        "LavaSecKit",
        "LavaSecNetworking",
        "LavaSecDNS",
        "LavaSecFilterPipeline",
        "LavaSecPresentation",
        "LavaSecAppServices",
        "LavaSecCore",
    ]
    private static let approvedRemotePackageProducts: [String: Set<String>] = [
        "LavaSec": ["GoogleSignIn/GoogleSignIn"],
    ]
    private static let approvedScalarOptions = [
        "defaultConfig": "Release",
        "developmentLanguage": "en",
        "settingPresets": "none",
        "xcodeVersion": "26.3",
    ]
    private static let approvedOptionKeys = Set(approvedScalarOptions.keys).union([
        "fileTypes",
        "postGenCommand",
    ])
    private static let approvedTopLevelKeys: Set<String> = [
        "configFiles",
        "configs",
        "name",
        "options",
        "packages",
        "schemes",
        "settings",
        "targets",
    ]

    private let lines: [YAMLBoundaryLine]

    init(source: String) throws {
        lines = try Self.significantLines(in: source)
    }

    func xcodeTargets() throws -> [XcodeBoundaryTarget] {
        let documentRange = lines.startIndex..<lines.endIndex
        guard let documentIndent = directChildIndent(in: documentRange) else {
            throw ModuleBoundaryParseError("project YAML is empty")
        }
        try rejectXcodeGenExpansionKeys(
            atIndent: documentIndent,
            in: documentRange,
            forbiddenNames: [
                "aggregateTargets",
                "include",
                "localPackages",
                "schemeTemplates",
                "targetTemplates",
            ],
            scope: "top level"
        )
        try validateApprovedTopLevelKeys(
            atIndent: documentIndent,
            in: documentRange
        )
        try validateGenerationCommands(
            documentIndent: documentIndent,
            in: documentRange
        )
        try validateSchemeCommands(
            documentIndent: documentIndent,
            in: documentRange
        )
        let localPackageAliases = try parseLocalPackageAliases(
            documentIndent: documentIndent,
            in: documentRange
        )
        let targetsIndex = try uniqueMapping(
            named: "targets",
            atIndent: documentIndent,
            in: documentRange,
            description: "targets mapping"
        )
        guard try mapping(at: targetsIndex).value == nil else {
            throw ModuleBoundaryParseError("targets must be a mapping")
        }

        let targetsRange = (targetsIndex + 1)..<scopeEnd(after: targetsIndex)
        guard let targetIndent = directChildIndent(in: targetsRange) else {
            throw ModuleBoundaryParseError("targets mapping is empty")
        }
        let targetIndices = targetsRange.filter { lines[$0].indent == targetIndent }
        var seenNames: Set<String> = []

        return try targetIndices.map { targetIndex in
            let target = try mapping(at: targetIndex)
            guard target.value == nil else {
                throw ModuleBoundaryParseError("Xcode target \(target.key) must be a mapping")
            }
            guard seenNames.insert(target.key).inserted else {
                throw ModuleBoundaryParseError("duplicate Xcode target \(target.key)")
            }

            let targetRange = (targetIndex + 1)..<scopeEnd(after: targetIndex)
            guard let targetKeyIndent = directChildIndent(in: targetRange) else {
                throw ModuleBoundaryParseError("Xcode target \(target.key) is empty")
            }
            try rejectXcodeGenExpansionKeys(
                atIndent: targetKeyIndent,
                in: targetRange,
                forbiddenNames: [
                    "name",
                    "platformPrefix",
                    "platformSuffix",
                    "legacy",
                    "transitivelyLinkDependencies",
                    "buildRules",
                    "buildToolPlugins",
                    "postBuildScripts",
                    "postCompileScripts",
                    "postbuildScripts",
                    "preBuildScripts",
                    "prebuildScripts",
                    "scheme",
                    "info",
                    "entitlements",
                    "templates",
                    "templateAttributes",
                ],
                scope: "Xcode target \(target.key)"
            )
            let typeIndex = try uniqueMapping(
                named: "type",
                atIndent: targetKeyIndent,
                in: targetRange,
                description: "type for Xcode target \(target.key)"
            )
            guard let type = try mapping(at: typeIndex).value else {
                throw ModuleBoundaryParseError(
                    "type for Xcode target \(target.key) must be a scalar"
                )
            }
            let platformIndex = try uniqueMapping(
                named: "platform",
                atIndent: targetKeyIndent,
                in: targetRange,
                description: "platform for Xcode target \(target.key)"
            )
            guard let platform = try mapping(at: platformIndex).value,
                  platform == "iOS" else {
                throw ModuleBoundaryParseError(
                    "Xcode target \(target.key) must use exactly platform iOS"
                )
            }
            return XcodeBoundaryTarget(
                name: target.key,
                type: type,
                platform: platform,
                sourcePaths: try parseSourcePaths(
                    for: target.key,
                    targetKeyIndent: targetKeyIndent,
                    in: targetRange
                ),
                localPackageProducts: try parseLocalPackageProductsIfPresent(
                    for: target.key,
                    targetKeyIndent: targetKeyIndent,
                    in: targetRange,
                    localPackageAliases: localPackageAliases
                )
            )
        }
    }

    func localPackageProducts(for targetName: String) throws -> [String] {
        let documentRange = lines.startIndex..<lines.endIndex
        guard let documentIndent = directChildIndent(in: documentRange) else {
            throw ModuleBoundaryParseError("project YAML is empty")
        }
        try rejectXcodeGenExpansionKeys(
            atIndent: documentIndent,
            in: documentRange,
            forbiddenNames: [
                "aggregateTargets",
                "include",
                "localPackages",
                "schemeTemplates",
                "targetTemplates",
            ],
            scope: "top level"
        )
        try validateApprovedTopLevelKeys(
            atIndent: documentIndent,
            in: documentRange
        )
        try validateGenerationCommands(
            documentIndent: documentIndent,
            in: documentRange
        )
        try validateSchemeCommands(
            documentIndent: documentIndent,
            in: documentRange
        )
        let localPackageAliases = try parseLocalPackageAliases(
            documentIndent: documentIndent,
            in: documentRange
        )
        let targetsIndex = try uniqueMapping(
            named: "targets",
            atIndent: documentIndent,
            in: documentRange,
            description: "targets mapping"
        )
        guard try mapping(at: targetsIndex).value == nil else {
            throw ModuleBoundaryParseError("targets must be a mapping")
        }

        let targetsEnd = scopeEnd(after: targetsIndex)
        let targetsRange = (targetsIndex + 1)..<targetsEnd
        guard let targetIndent = directChildIndent(in: targetsRange) else {
            throw ModuleBoundaryParseError("targets mapping is empty")
        }
        let targetIndex = try uniqueMapping(
            named: targetName,
            atIndent: targetIndent,
            in: targetsRange,
            description: "Xcode target \(targetName)"
        )
        guard try mapping(at: targetIndex).value == nil else {
            throw ModuleBoundaryParseError("Xcode target \(targetName) must be a mapping")
        }

        let targetEnd = scopeEnd(after: targetIndex)
        let targetRange = (targetIndex + 1)..<targetEnd
        guard let targetKeyIndent = directChildIndent(in: targetRange) else {
            throw ModuleBoundaryParseError("Xcode target \(targetName) is empty")
        }
        try rejectXcodeGenExpansionKeys(
            atIndent: targetKeyIndent,
            in: targetRange,
            forbiddenNames: [
                "name",
                "platformPrefix",
                "platformSuffix",
                "legacy",
                "transitivelyLinkDependencies",
                "buildRules",
                "buildToolPlugins",
                "postBuildScripts",
                "postCompileScripts",
                "postbuildScripts",
                "preBuildScripts",
                "prebuildScripts",
                "scheme",
                "info",
                "entitlements",
                "templates",
                "templateAttributes",
            ],
            scope: "Xcode target \(targetName)"
        )
        let dependenciesIndex = try uniqueMapping(
            named: "dependencies",
            atIndent: targetKeyIndent,
            in: targetRange,
            description: "dependencies for Xcode target \(targetName)"
        )
        guard try mapping(at: dependenciesIndex).value == nil else {
            throw ModuleBoundaryParseError(
                "dependencies for Xcode target \(targetName) must be a sequence"
            )
        }

        let dependenciesEnd = scopeEnd(after: dependenciesIndex)
        return try parseDependencies(
            in: (dependenciesIndex + 1)..<dependenciesEnd,
            targetName: targetName,
            localPackageAliases: localPackageAliases
        )
    }

    private func parseLocalPackageAliases(
        documentIndent: Int,
        in documentRange: Range<Int>
    ) throws -> Set<String> {
        let packagesIndex = try uniqueMapping(
            named: "packages",
            atIndent: documentIndent,
            in: documentRange,
            description: "packages mapping"
        )
        guard try mapping(at: packagesIndex).value == nil else {
            throw ModuleBoundaryParseError("packages must be a mapping")
        }

        let packagesRange = (packagesIndex + 1)..<scopeEnd(after: packagesIndex)
        guard let packageIndent = directChildIndent(in: packagesRange) else {
            throw ModuleBoundaryParseError("packages mapping is empty")
        }
        let packageIndices = packagesRange.filter { lines[$0].indent == packageIndent }
        var seenAliases: Set<String> = []
        var localAliases: Set<String> = []

        for packageIndex in packageIndices {
            let package = try mapping(at: packageIndex)
            guard package.value == nil else {
                throw ModuleBoundaryParseError("package \(package.key) must be a mapping")
            }
            guard seenAliases.insert(package.key).inserted else {
                throw ModuleBoundaryParseError("duplicate package alias \(package.key)")
            }

            let packageRange = (packageIndex + 1)..<scopeEnd(after: packageIndex)
            guard let propertyIndent = directChildIndent(in: packageRange) else {
                throw ModuleBoundaryParseError("package \(package.key) is empty")
            }
            try rejectXcodeGenExpansionKeys(
                atIndent: propertyIndent,
                in: packageRange,
                forbiddenNames: [],
                scope: "package \(package.key)"
            )

            var properties: [String: String] = [:]
            for index in packageRange where lines[index].indent == propertyIndent {
                let property = try mapping(at: index)
                guard let value = property.value else {
                    throw ModuleBoundaryParseError(
                        "package property \(property.key) in \(package.key) must be a scalar"
                    )
                }
                guard properties.updateValue(value, forKey: property.key) == nil else {
                    throw ModuleBoundaryParseError(
                        "duplicate package property \(property.key) in \(package.key)"
                    )
                }
            }

            if package.key == "LavaSecPackage" {
                guard properties == ["path": "."] else {
                    throw ModuleBoundaryParseError(
                        "LavaSecPackage must be the unique repo-root package at path ."
                    )
                }
                localAliases.insert(package.key)
            } else {
                guard properties["path"] == nil else {
                    throw ModuleBoundaryParseError(
                        "unapproved local package alias \(package.key)"
                    )
                }
                if let url = properties["url"], !url.hasPrefix("https://") {
                    throw ModuleBoundaryParseError(
                        "remote package \(package.key) must use an https URL"
                    )
                }
            }
        }

        guard localAliases == Set(["LavaSecPackage"]) else {
            throw ModuleBoundaryParseError(
                "packages must define exactly one repo-root LavaSecPackage"
            )
        }
        return localAliases
    }

    private func validateGenerationCommands(
        documentIndent: Int,
        in documentRange: Range<Int>
    ) throws {
        guard let optionsIndex = try optionalUniqueMapping(
            named: "options",
            atIndent: documentIndent,
            in: documentRange,
            description: "options mapping"
        ) else {
            return
        }
        guard try mapping(at: optionsIndex).value == nil else {
            throw ModuleBoundaryParseError("options must be a mapping")
        }

        let optionsRange = (optionsIndex + 1)..<scopeEnd(after: optionsIndex)
        guard let optionIndent = directChildIndent(in: optionsRange) else {
            throw ModuleBoundaryParseError("options mapping is empty")
        }
        var seenOptions: Set<String> = []
        var scalarOptions: [String: String] = [:]
        var postGenCommand: String?
        var fileTypesIndex: Int?
        for index in optionsRange where lines[index].indent == optionIndent {
            let option = try mapping(at: index)
            if option.key == "<<" || option.key.contains(":") {
                throw ModuleBoundaryParseError(
                    "unsupported XcodeGen expansion key in options: \(option.key)"
                )
            }
            if option.key == "preGenCommand" {
                throw ModuleBoundaryParseError("XcodeGen preGenCommand is unsupported")
            }
            if option.key == "transitivelyLinkDependencies" {
                throw ModuleBoundaryParseError(
                    "transitive dependency linking is unsupported in options"
                )
            }
            guard Self.approvedOptionKeys.contains(option.key) else {
                throw ModuleBoundaryParseError(
                    "unsupported XcodeGen option: \(option.key)"
                )
            }
            guard seenOptions.insert(option.key).inserted else {
                if option.key == "postGenCommand" {
                    throw ModuleBoundaryParseError("duplicate XcodeGen postGenCommand")
                }
                if option.key == "fileTypes" {
                    throw ModuleBoundaryParseError("duplicate options.fileTypes mapping")
                }
                throw ModuleBoundaryParseError("duplicate XcodeGen option \(option.key)")
            }
            if let value = option.value {
                scalarOptions[option.key] = value
            }
            if option.key == "postGenCommand" {
                postGenCommand = option.value
            }
            if option.key == "fileTypes" {
                fileTypesIndex = index
            }
        }
        if postGenCommand != "python3 scripts/xcodegen-fixups.py" {
            throw ModuleBoundaryParseError(
                "XcodeGen postGenCommand must be exactly python3 scripts/xcodegen-fixups.py"
            )
        }
        try validateApprovedFileTypes(at: fileTypesIndex)
        for (key, expectedValue) in Self.approvedScalarOptions {
            guard scalarOptions[key] == expectedValue else {
                throw ModuleBoundaryParseError(
                    "XcodeGen option \(key) differs from policy"
                )
            }
        }
    }

    private func validateApprovedFileTypes(at fileTypesIndex: Int?) throws {
        guard let fileTypesIndex,
              try mapping(at: fileTypesIndex).value == nil else {
            throw ModuleBoundaryParseError(
                "options.fileTypes must contain only the approved icon override"
            )
        }
        let fileTypesRange = (fileTypesIndex + 1)..<scopeEnd(after: fileTypesIndex)
        guard let typeIndent = directChildIndent(in: fileTypesRange) else {
            throw ModuleBoundaryParseError(
                "options.fileTypes must contain only the approved icon override"
            )
        }
        let typeIndices = fileTypesRange.filter { lines[$0].indent == typeIndent }
        guard typeIndices.count == 1,
              let iconIndex = typeIndices.first,
              try mapping(at: iconIndex).key == "icon",
              try mapping(at: iconIndex).value == nil else {
            throw ModuleBoundaryParseError(
                "options.fileTypes must contain only the approved icon override"
            )
        }

        let iconRange = (iconIndex + 1)..<scopeEnd(after: iconIndex)
        guard let propertyIndent = directChildIndent(in: iconRange) else {
            throw ModuleBoundaryParseError(
                "options.fileTypes must contain only the approved icon override"
            )
        }
        var properties: [String: String] = [:]
        for index in iconRange where lines[index].indent == propertyIndent {
            let property = try mapping(at: index)
            guard let value = property.value,
                  properties.updateValue(value, forKey: property.key) == nil else {
                throw ModuleBoundaryParseError(
                    "options.fileTypes must contain only the approved icon override"
                )
            }
        }
        guard properties == ["file": "true", "buildPhase": "resources"] else {
            throw ModuleBoundaryParseError(
                "options.fileTypes must contain only the approved icon override"
            )
        }
    }

    private func validateSchemeCommands(
        documentIndent: Int,
        in documentRange: Range<Int>
    ) throws {
        guard let schemesIndex = try optionalUniqueMapping(
            named: "schemes",
            atIndent: documentIndent,
            in: documentRange,
            description: "schemes mapping"
        ) else {
            return
        }
        guard try mapping(at: schemesIndex).value == nil else {
            throw ModuleBoundaryParseError("schemes must be a mapping")
        }

        let schemesRange = (schemesIndex + 1)..<scopeEnd(after: schemesIndex)
        for index in schemesRange where !lines[index].content.hasPrefix("- ") {
            guard let schemeMapping = try? mapping(at: index) else {
                continue
            }
            if ["preActions", "postActions"].contains(schemeMapping.key) {
                throw ModuleBoundaryParseError(
                    "unsupported executable scheme key: \(schemeMapping.key)"
                )
            }
        }
    }

    private func rejectXcodeGenExpansionKeys(
        atIndent indent: Int,
        in range: Range<Int>,
        forbiddenNames: Set<String>,
        scope: String
    ) throws {
        // Boundary policy is checked against direct YAML. Expansion would mutate the semantic
        // target graph before XcodeGen emits the project, so unsupported composition fails closed.
        for index in range where lines[index].indent == indent {
            let key = try mapping(at: index).key
            if key == "<<" || key.contains(":") || forbiddenNames.contains(key) {
                throw ModuleBoundaryParseError(
                    "unsupported XcodeGen expansion key in \(scope): \(key)"
                )
            }
        }
    }

    private func validateApprovedTopLevelKeys(
        atIndent indent: Int,
        in range: Range<Int>
    ) throws {
        for index in range where lines[index].indent == indent {
            let key = try mapping(at: index).key
            guard Self.approvedTopLevelKeys.contains(key) else {
                throw ModuleBoundaryParseError(
                    "unsupported top-level XcodeGen key: \(key)"
                )
            }
        }
    }

    private func parseDependencies(
        in range: Range<Int>,
        targetName: String,
        localPackageAliases: Set<String>
    ) throws -> [String] {
        guard let entryIndent = directChildIndent(in: range) else { return [] }
        let entryStarts = try range.filter { index in
            guard lines[index].indent == entryIndent else { return false }
            guard lines[index].content.hasPrefix("- ") else {
                throw ModuleBoundaryParseError(
                    "unconsumed dependency syntax at line \(lines[index].number)"
                )
            }
            return true
        }

        var products: [String] = []
        for (offset, start) in entryStarts.enumerated() {
            let end = offset + 1 < entryStarts.count ? entryStarts[offset + 1] : range.upperBound
            let values = try dependencyMapping(in: start..<end, entryIndent: entryIndent)
            let keys = Set(values.keys)
            if !keys.isDisjoint(with: ["package", "product"]) {
                guard keys == Set(["package", "product"]),
                      let package = values["package"],
                      let product = values["product"] else {
                    throw ModuleBoundaryParseError(
                        "package dependency in \(targetName) has duplicate, missing, or unconsumed keys"
                    )
                }
                if localPackageAliases.contains(package) {
                    products.append(product)
                } else if Self.reservedLocalPackageProducts.contains(product) {
                    throw ModuleBoundaryParseError(
                        "reserved local product \(product) cannot come from package \(package)"
                    )
                } else {
                    let identity = "\(package)/\(product)"
                    guard Self.approvedRemotePackageProducts[targetName]?.contains(identity) == true else {
                        throw ModuleBoundaryParseError(
                            "unapproved remote package product \(identity) in \(targetName)"
                        )
                    }
                }
            } else if keys.contains("target") {
                let allowedKeys = Set(["target", "embed", "codeSign"])
                guard keys.isSubset(of: allowedKeys), values["target"] != nil else {
                    throw ModuleBoundaryParseError(
                        "target dependency in \(targetName) has unconsumed keys"
                    )
                }
            } else {
                throw ModuleBoundaryParseError(
                    "unsupported dependency entry in \(targetName)"
                )
            }
        }
        return products
    }

    private func parseSourcePaths(
        for targetName: String,
        targetKeyIndent: Int,
        in targetRange: Range<Int>
    ) throws -> [String] {
        guard let sourcesIndex = try optionalUniqueMapping(
            named: "sources",
            atIndent: targetKeyIndent,
            in: targetRange,
            description: "sources for Xcode target \(targetName)"
        ) else {
            return []
        }
        guard try mapping(at: sourcesIndex).value == nil else {
            throw ModuleBoundaryParseError(
                "sources for Xcode target \(targetName) must be a sequence"
            )
        }

        let range = (sourcesIndex + 1)..<scopeEnd(after: sourcesIndex)
        guard let entryIndent = directChildIndent(in: range) else { return [] }
        let entryStarts = try range.filter { index in
            guard lines[index].indent == entryIndent else { return false }
            guard lines[index].content.hasPrefix("- ") else {
                throw ModuleBoundaryParseError(
                    "unconsumed source syntax at line \(lines[index].number)"
                )
            }
            return true
        }

        return try entryStarts.enumerated().map { offset, start in
            let end = offset + 1 < entryStarts.count
                ? entryStarts[offset + 1]
                : range.upperBound
            let values = try dependencyMapping(
                in: start..<end,
                entryIndent: entryIndent
            )
            let allowedKeys = Set(["path", "buildPhase"])
            guard Set(values.keys).isSubset(of: allowedKeys),
                  let path = values["path"] else {
                throw ModuleBoundaryParseError(
                    "source entry in \(targetName) has missing or unconsumed keys"
                )
            }
            return path
        }
    }

    private func parseLocalPackageProductsIfPresent(
        for targetName: String,
        targetKeyIndent: Int,
        in targetRange: Range<Int>,
        localPackageAliases: Set<String>
    ) throws -> [String] {
        guard let dependenciesIndex = try optionalUniqueMapping(
            named: "dependencies",
            atIndent: targetKeyIndent,
            in: targetRange,
            description: "dependencies for Xcode target \(targetName)"
        ) else {
            return []
        }
        guard try mapping(at: dependenciesIndex).value == nil else {
            throw ModuleBoundaryParseError(
                "dependencies for Xcode target \(targetName) must be a sequence"
            )
        }
        return try parseDependencies(
            in: (dependenciesIndex + 1)..<scopeEnd(after: dependenciesIndex),
            targetName: targetName,
            localPackageAliases: localPackageAliases
        )
    }

    private func dependencyMapping(
        in range: Range<Int>,
        entryIndent: Int
    ) throws -> [String: String] {
        guard let first = range.first else {
            throw ModuleBoundaryParseError("empty dependency entry")
        }
        let firstContent = String(lines[first].content.dropFirst(2))
        var pairs = [try Self.mapping(in: firstContent, line: lines[first].number)]

        if first + 1 < range.upperBound {
            let continuationIndent = lines[(first + 1)..<range.upperBound]
                .map(\.indent)
                .min()
            guard let continuationIndent, continuationIndent > entryIndent else {
                throw ModuleBoundaryParseError(
                    "invalid dependency indentation at line \(lines[first].number)"
                )
            }
            for index in (first + 1)..<range.upperBound {
                guard lines[index].indent == continuationIndent else {
                    throw ModuleBoundaryParseError(
                        "nested dependency syntax is unsupported at line \(lines[index].number)"
                    )
                }
                pairs.append(try mapping(at: index))
            }
        }

        var values: [String: String] = [:]
        for pair in pairs {
            guard let value = pair.value, !value.isEmpty else {
                throw ModuleBoundaryParseError("dependency key \(pair.key) has no scalar value")
            }
            guard values.updateValue(value, forKey: pair.key) == nil else {
                throw ModuleBoundaryParseError("duplicate dependency key \(pair.key)")
            }
        }
        return values
    }

    private func uniqueMapping(
        named name: String,
        atIndent indent: Int,
        in range: Range<Int>,
        description: String
    ) throws -> Int {
        var matches: [Int] = []
        for index in range where lines[index].indent == indent {
            if try mapping(at: index).key == name {
                matches.append(index)
            }
        }
        guard matches.count == 1, let match = matches.first else {
            let reason = matches.isEmpty ? "missing" : "duplicate"
            throw ModuleBoundaryParseError("\(reason) \(description)")
        }
        return match
    }

    private func optionalUniqueMapping(
        named name: String,
        atIndent indent: Int,
        in range: Range<Int>,
        description: String
    ) throws -> Int? {
        var matches: [Int] = []
        for index in range where lines[index].indent == indent {
            if try mapping(at: index).key == name {
                matches.append(index)
            }
        }
        guard matches.count <= 1 else {
            throw ModuleBoundaryParseError("duplicate \(description)")
        }
        return matches.first
    }

    private func mapping(at index: Int) throws -> (key: String, value: String?) {
        try Self.mapping(in: lines[index].content, line: lines[index].number)
    }

    private func scopeEnd(after index: Int) -> Int {
        let parentIndent = lines[index].indent
        return ((index + 1)..<lines.endIndex).first {
            lines[$0].indent <= parentIndent
        } ?? lines.endIndex
    }

    private func directChildIndent(in range: Range<Int>) -> Int? {
        range.map { lines[$0].indent }.min()
    }

    private static func significantLines(in source: String) throws -> [YAMLBoundaryLine] {
        try source.components(separatedBy: .newlines).enumerated().compactMap { offset, rawLine in
            let uncommented = try removingInlineComment(from: rawLine)
            let trimmed = uncommented.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }

            let indentation = uncommented.prefix { $0 == " " || $0 == "\t" }
            guard !indentation.contains("\t") else {
                throw ModuleBoundaryParseError("tab indentation at YAML line \(offset + 1)")
            }
            return YAMLBoundaryLine(
                indent: indentation.count,
                content: String(uncommented.dropFirst(indentation.count))
                    .trimmingCharacters(in: .whitespaces),
                number: offset + 1
            )
        }
    }

    private static func removingInlineComment(from line: String) throws -> String {
        let characters = Array(line)
        var quote: Character?
        var index = 0

        while index < characters.count {
            let character = characters[index]
            if quote == "\"", character == "\\" {
                index += 2
                continue
            }
            if character == "'", quote != "\"" {
                if quote == "'", index + 1 < characters.count, characters[index + 1] == "'" {
                    index += 2
                    continue
                }
                quote = quote == "'" ? nil : "'"
            } else if character == "\"", quote != "'" {
                quote = quote == "\"" ? nil : "\""
            } else if character == "#",
                      quote == nil,
                      index == 0 || characters[index - 1] == " " || characters[index - 1] == "\t" {
                return trimmingTrailingWhitespace(String(characters[..<index]))
            }
            index += 1
        }
        guard quote == nil else {
            throw ModuleBoundaryParseError("unterminated quoted YAML scalar")
        }
        return trimmingTrailingWhitespace(line)
    }

    private static func trimmingTrailingWhitespace(_ value: String) -> String {
        var characters = Array(value)
        while characters.last == " " || characters.last == "\t" {
            characters.removeLast()
        }
        return String(characters)
    }

    private static func mapping(
        in content: String,
        line: Int
    ) throws -> (key: String, value: String?) {
        let characters = Array(content)
        var quote: Character?
        var colon: Int?
        var index = 0

        while index < characters.count {
            let character = characters[index]
            if quote == "\"", character == "\\" {
                index += 2
                continue
            }
            if character == "'", quote != "\"" {
                if quote == "'", index + 1 < characters.count, characters[index + 1] == "'" {
                    index += 2
                    continue
                }
                quote = quote == "'" ? nil : "'"
            } else if character == "\"", quote != "'" {
                quote = quote == "\"" ? nil : "\""
            } else if character == ":", quote == nil {
                colon = index
                break
            }
            index += 1
        }
        guard let colon else {
            throw ModuleBoundaryParseError("expected YAML mapping at line \(line)")
        }
        let key = try scalar(String(characters[..<colon]))
        let rawValue = String(characters[(colon + 1)...])
            .trimmingCharacters(in: .whitespaces)
        return (key, rawValue.isEmpty ? nil : try scalar(rawValue))
    }

    private static func scalar(_ rawValue: String) throws -> String {
        let value = rawValue.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else {
            throw ModuleBoundaryParseError("empty YAML scalar")
        }
        if value.first == "'" {
            guard value.count >= 2, value.last == "'" else {
                throw ModuleBoundaryParseError("unterminated single-quoted YAML scalar")
            }
            return try checkedScalar(
                String(value.dropFirst().dropLast())
                    .replacingOccurrences(of: "''", with: "'")
            )
        }
        if value.first == "\"" {
            guard value.count >= 2, value.last == "\"" else {
                throw ModuleBoundaryParseError("unterminated double-quoted YAML scalar")
            }
            let contents = String(value.dropFirst().dropLast())
            guard !contents.contains("\\") else {
                throw ModuleBoundaryParseError(
                    "escaped YAML scalars are unsupported"
                )
            }
            return try checkedScalar(contents)
        }
        guard !value.contains("'") && !value.contains("\"") else {
            throw ModuleBoundaryParseError("unconsumed YAML scalar syntax")
        }
        let unsupportedPrefixes: Set<Character> = ["&", "*", "!", "[", "{", "|", ">"]
        guard let first = value.first, !unsupportedPrefixes.contains(first) else {
            throw ModuleBoundaryParseError("unsupported YAML node syntax")
        }
        return try checkedScalar(value)
    }

    private static func checkedScalar(_ value: String) throws -> String {
        guard !value.contains("${") else {
            throw ModuleBoundaryParseError(
                "XcodeGen environment substitution is unsupported"
            )
        }
        return value
    }
}

struct DumpedPackage: Decodable {
    private struct Product: Decodable {
        struct ProductType: Decodable {
            let library: [String]?
        }

        let name: String
        let targets: [String]
        let type: ProductType
    }

    private struct Target: Decodable {
        let name: String
        let dependencies: [Dependency]
        let path: String?
        let type: String
    }

    private struct Dependency: Decodable {
        let name: String

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: PackageDumpCodingKey.self)
            guard container.allKeys.count == 1,
                  let key = container.allKeys.first,
                  key.stringValue == "byName" else {
                throw DecodingError.dataCorrupted(
                    .init(
                        codingPath: decoder.codingPath,
                        debugDescription: "unsupported package dependency form"
                    )
                )
            }
            let values = try container.decode([String?].self, forKey: key)
            guard values.count == 2,
                  let name = values[0],
                  values[1] == nil else {
                throw DecodingError.dataCorruptedError(
                    forKey: key,
                    in: container,
                    debugDescription: "conditional or malformed by-name dependency"
                )
            }
            self.name = name
        }
    }

    private let products: [Product]
    private let targets: [Target]

    func libraryProducts() throws -> [String: [String]] {
        var result: [String: [String]] = [:]
        for product in products where product.type.library != nil {
            guard result.updateValue(product.targets, forKey: product.name) == nil else {
                throw ModuleBoundaryParseError("duplicate package product \(product.name)")
            }
        }
        return result
    }

    func targetDependencies(
        named targetName: String,
        expectedType: String? = nil
    ) throws -> [String] {
        try target(named: targetName, expectedType: expectedType).dependencies.map(\.name)
    }

    func validateTargetSourcePaths(_ expectedPaths: [String: String]) throws {
        for (targetName, expectedPath) in expectedPaths.sorted(by: { $0.key < $1.key }) {
            let target = try target(named: targetName, expectedType: "regular")
            if let path = target.path, path != expectedPath {
                throw ModuleBoundaryParseError(
                    "package target \(targetName) has source path \(path), "
                        + "expected \(expectedPath)"
                )
            }
        }
    }

    private func target(
        named targetName: String,
        expectedType: String?
    ) throws -> Target {
        let matches = targets.filter { $0.name == targetName }
        guard matches.count == 1, let target = matches.first else {
            let reason = matches.isEmpty ? "missing" : "duplicate"
            throw ModuleBoundaryParseError("\(reason) package target \(targetName)")
        }
        if let expectedType, target.type != expectedType {
            throw ModuleBoundaryParseError(
                "package target \(targetName) has type \(target.type), expected \(expectedType)"
            )
        }
        return target
    }
}

private struct PackageDumpCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

func dumpPackage(at packageRoot: URL) throws -> DumpedPackage {
    let process = Process()
    let standardOutput = Pipe()
    let standardError = Pipe()
    let scratchPath = FileManager.default.temporaryDirectory
        .appendingPathComponent("LavaSecPackageDump-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: scratchPath) }
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [
        "swift", "package", "dump-package",
        "--package-path", packageRoot.path,
        "--scratch-path", scratchPath.path,
    ]
    process.standardOutput = standardOutput
    process.standardError = standardError

    do {
        try process.run()
    } catch {
        throw ModuleBoundaryParseError("could not launch swift package dump-package: \(error)")
    }
    process.waitUntilExit()
    let output = standardOutput.fileHandleForReading.readDataToEndOfFile()
    let diagnostics = standardError.fileHandleForReading.readDataToEndOfFile()
    guard process.terminationStatus == 0 else {
        let message = String(decoding: diagnostics, as: UTF8.self)
        throw ModuleBoundaryParseError(
            "swift package dump-package failed with \(process.terminationStatus): \(message)"
        )
    }
    return try decodeDumpedPackage(from: output)
}

func decodeDumpedPackage(from data: Data) throws -> DumpedPackage {
    do {
        return try JSONDecoder().decode(DumpedPackage.self, from: data)
    } catch {
        throw ModuleBoundaryParseError("could not decode package dump JSON: \(error)")
    }
}

struct ModuleBoundaryParseError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
