#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";
import { splitYAMLDocumentComments } from "./yaml-comment-utils.mjs";

const repoRoot = process.cwd();
const manifestPath = path.join(repoRoot, "project.yml");
const approvedPostGenCommand = "python3 scripts/xcodegen-fixups.py";
const approvedScalarOptions = new Map([
  ["defaultConfig", "Release"],
  ["developmentLanguage", "en"],
  ["settingPresets", "none"],
  ["xcodeVersion", "26.3"],
]);
const approvedOptionKeys = new Set([
  ...approvedScalarOptions.keys(),
  "fileTypes",
  "postGenCommand",
]);
const approvedTopLevelKeys = new Set([
  "configFiles",
  "configs",
  "name",
  "options",
  "packages",
  "schemes",
  "settings",
  "targets",
]);
const arguments_ = process.argv.slice(2);
const emitBoundaryJSON = arguments_.length === 1 && arguments_[0] === "--emit-boundary-json";
if (arguments_.length > 0 && !emitBoundaryJSON) {
  console.error("check-xcodegen-sources: usage: node scripts/check-xcodegen-sources.mjs [--emit-boundary-json]");
  process.exit(2);
}

const allowedSourceRootsByTarget = new Map([
  ["LavaSec", new Set(["LavaSecApp", "Shared"])],
  ["LavaSecTunnel", new Set(["LavaSecTunnel", "Shared"])],
  ["LavaSecWidget", new Set(["LavaSecWidget", "Shared"])],
  ["LavaSecIntents", new Set(["LavaSecIntents", "Shared"])],
  ["LavaSecUITests", new Set(["LavaSecUITests"])],
]);

function parseYAMLScalar(rawScalar) {
  const scalar = rawScalar.trim();
  if (!scalar) {
    throw new Error("empty YAML scalar");
  }
  let value;
  if (scalar.startsWith("'")) {
    if (!scalar.endsWith("'")) {
      throw new Error("unterminated single-quoted YAML scalar");
    }
    value = scalar.slice(1, -1).replaceAll("''", "'");
  } else if (scalar.startsWith('"')) {
    if (!scalar.endsWith('"')) {
      throw new Error("unterminated double-quoted YAML scalar");
    }
    try {
      value = JSON.parse(scalar);
    } catch {
      throw new Error("invalid double-quoted YAML scalar");
    }
  } else {
    value = scalar;
  }
  if (value.includes("${")) {
    throw new Error("XcodeGen environment substitution is unsupported");
  }
  return value;
}

function parseYAMLMapping(content, lineNumber) {
  let quote;
  let colonIndex;
  for (let index = 0; index < content.length; index += 1) {
    const character = content[index];
    if (quote === '"' && character === "\\") {
      index += 1;
    } else if (character === "'" && quote !== '"') {
      if (quote === "'" && content[index + 1] === "'") {
        index += 1;
      } else {
        quote = quote === "'" ? undefined : "'";
      }
    } else if (character === '"' && quote !== "'") {
      quote = quote === '"' ? undefined : '"';
    } else if (character === ":" && quote === undefined
        && (index + 1 === content.length || /\s/.test(content[index + 1]))) {
      colonIndex = index;
      break;
    }
  }
  if (colonIndex === undefined) {
    throw new Error(`expected YAML mapping at line ${lineNumber}`);
  }

  const key = parseYAMLScalar(content.slice(0, colonIndex));
  const rawValue = content.slice(colonIndex + 1).trim();
  return {
    key,
    value: rawValue ? parseYAMLScalar(rawValue) : undefined,
  };
}

function significantYAMLLines(manifest) {
  const lines = [];
  for (const [index, { content }] of splitYAMLDocumentComments(manifest).entries()) {
    if (!content.trim()) {
      continue;
    }
    const indentation = content.match(/^[ \t]*/)[0];
    if (indentation.includes("\t")) {
      throw new Error(`tab indentation at YAML line ${index + 1}`);
    }
    lines.push({
      indent: indentation.length,
      content: content.slice(indentation.length).trimEnd(),
      lineNumber: index + 1,
    });
  }
  return lines;
}

function scopeEnd(lines, index) {
  for (let candidate = index + 1; candidate < lines.length; candidate += 1) {
    if (lines[candidate].indent <= lines[index].indent) {
      return candidate;
    }
  }
  return lines.length;
}

function directChildIndices(lines, start, end) {
  if (start >= end) {
    return [];
  }
  let childIndent = Number.POSITIVE_INFINITY;
  for (let index = start; index < end; index += 1) {
    childIndent = Math.min(childIndent, lines[index].indent);
  }
  const indices = [];
  for (let index = start; index < end; index += 1) {
    if (lines[index].indent === childIndent) {
      indices.push(index);
    }
  }
  return indices;
}

function uniqueMappingIndex(lines, indices, name, description, required = true) {
  const matches = [];
  for (const index of indices) {
    const mapping = parseYAMLMapping(lines[index].content, lines[index].lineNumber);
    if (mapping.key === name) {
      matches.push(index);
    }
  }
  if (matches.length > 1) {
    throw new Error(`duplicate ${description}`);
  }
  if (required && matches.length === 0) {
    throw new Error(`missing ${description}`);
  }
  return matches[0];
}

function parseSourceEntries(lines, sourcesIndex, targetName) {
  const end = scopeEnd(lines, sourcesIndex);
  const entryIndices = directChildIndices(lines, sourcesIndex + 1, end);
  const entries = [];

  for (const [offset, entryIndex] of entryIndices.entries()) {
    const entryLine = lines[entryIndex];
    if (!entryLine.content.startsWith("- ")) {
      throw new Error(`unsupported source entry at line ${entryLine.lineNumber}`);
    }
    const entryEnd = offset + 1 < entryIndices.length ? entryIndices[offset + 1] : end;
    const pairs = [
      parseYAMLMapping(entryLine.content.slice(2), entryLine.lineNumber),
    ];
    if (entryIndex + 1 < entryEnd) {
      const continuationIndices = directChildIndices(lines, entryIndex + 1, entryEnd);
      if (continuationIndices.length !== entryEnd - entryIndex - 1) {
        throw new Error(`nested source syntax is unsupported at line ${entryLine.lineNumber}`);
      }
      for (const continuationIndex of continuationIndices) {
        pairs.push(parseYAMLMapping(
          lines[continuationIndex].content,
          lines[continuationIndex].lineNumber,
        ));
      }
    }

    const values = new Map();
    for (const pair of pairs) {
      if (!["path", "buildPhase"].includes(pair.key) || pair.value === undefined) {
        throw new Error(`source entry in ${targetName} has missing or unsupported keys`);
      }
      if (values.has(pair.key)) {
        throw new Error(`duplicate source key ${pair.key} in target ${targetName}`);
      }
      values.set(pair.key, pair.value);
    }
    if (!values.has("path")) {
      throw new Error(`source entry in ${targetName} is missing path`);
    }
    entries.push({
      path: values.get("path"),
      buildPhase: values.get("buildPhase"),
    });
  }
  return entries;
}

function validateApprovedFileTypes(lines, fileTypesIndex) {
  if (fileTypesIndex === undefined
      || parseYAMLMapping(
        lines[fileTypesIndex].content,
        lines[fileTypesIndex].lineNumber,
      ).value !== undefined) {
    throw new Error("options.fileTypes must contain only the approved icon override");
  }
  const typeIndices = directChildIndices(
    lines,
    fileTypesIndex + 1,
    scopeEnd(lines, fileTypesIndex),
  );
  if (typeIndices.length !== 1) {
    throw new Error("options.fileTypes must contain only the approved icon override");
  }
  const icon = parseYAMLMapping(lines[typeIndices[0]].content, lines[typeIndices[0]].lineNumber);
  if (icon.key !== "icon" || icon.value !== undefined) {
    throw new Error("options.fileTypes must contain only the approved icon override");
  }
  const propertyIndices = directChildIndices(
    lines,
    typeIndices[0] + 1,
    scopeEnd(lines, typeIndices[0]),
  );
  const properties = new Map();
  for (const propertyIndex of propertyIndices) {
    const property = parseYAMLMapping(
      lines[propertyIndex].content,
      lines[propertyIndex].lineNumber,
    );
    if (property.value === undefined || properties.has(property.key)) {
      throw new Error("options.fileTypes must contain only the approved icon override");
    }
    properties.set(property.key, property.value);
  }
  if (properties.size !== 2
      || properties.get("file") !== "true"
      || properties.get("buildPhase") !== "resources") {
    throw new Error("options.fileTypes must contain only the approved icon override");
  }
}

function validateGenerationCommands(lines, documentIndices) {
  const optionsIndex = uniqueMappingIndex(
    lines,
    documentIndices,
    "options",
    "options mapping",
    false,
  );
  if (optionsIndex === undefined) {
    return;
  }
  if (parseYAMLMapping(lines[optionsIndex].content, lines[optionsIndex].lineNumber).value !== undefined) {
    throw new Error("options must be a mapping");
  }

  const optionIndices = directChildIndices(lines, optionsIndex + 1, scopeEnd(lines, optionsIndex));
  const options = new Map();
  let postGenCommand;
  let fileTypesIndex;
  for (const optionIndex of optionIndices) {
    const option = parseYAMLMapping(lines[optionIndex].content, lines[optionIndex].lineNumber);
    if (option.key === "<<" || option.key.includes(":")) {
      throw new Error(`unsupported XcodeGen expansion key in options: ${option.key}`);
    }
    if (option.key === "preGenCommand") {
      throw new Error("XcodeGen preGenCommand is unsupported");
    }
    if (option.key === "transitivelyLinkDependencies") {
      throw new Error("transitive dependency linking is unsupported in options");
    }
    if (!approvedOptionKeys.has(option.key)) {
      throw new Error(`unsupported XcodeGen option: ${option.key}`);
    }
    if (options.has(option.key)) {
      if (option.key === "postGenCommand") {
        throw new Error("duplicate XcodeGen postGenCommand");
      }
      if (option.key === "fileTypes") {
        throw new Error("duplicate options.fileTypes mapping");
      }
      throw new Error(`duplicate XcodeGen option ${option.key}`);
    }
    options.set(option.key, option);
    if (option.key === "postGenCommand") {
      postGenCommand = option.value;
    }
    if (option.key === "fileTypes") {
      fileTypesIndex = optionIndex;
    }
  }
  if (postGenCommand !== approvedPostGenCommand) {
    throw new Error(`XcodeGen postGenCommand must be exactly ${approvedPostGenCommand}`);
  }
  validateApprovedFileTypes(lines, fileTypesIndex);
  for (const [key, expectedValue] of approvedScalarOptions) {
    if (options.get(key)?.value !== expectedValue) {
      throw new Error(`XcodeGen option ${key} differs from policy`);
    }
  }
}

function validateSchemeCommands(lines, documentIndices) {
  const schemesIndex = uniqueMappingIndex(
    lines,
    documentIndices,
    "schemes",
    "schemes mapping",
    false,
  );
  if (schemesIndex === undefined) {
    return;
  }
  if (parseYAMLMapping(lines[schemesIndex].content, lines[schemesIndex].lineNumber).value !== undefined) {
    throw new Error("schemes must be a mapping");
  }

  for (let index = schemesIndex + 1; index < scopeEnd(lines, schemesIndex); index += 1) {
    const candidate = lines[index].content.startsWith("- ")
      ? lines[index].content.slice(2)
      : lines[index].content;
    let mapping;
    try {
      mapping = parseYAMLMapping(candidate, lines[index].lineNumber);
    } catch {
      // Scalar sequence members (for example, test target names) are valid scheme syntax.
      continue;
    }
    if (["preActions", "postActions"].includes(mapping.key)) {
      throw new Error(`unsupported executable scheme key: ${mapping.key}`);
    }
  }
}

function parseTargetSourcePaths(manifest) {
  const lines = significantYAMLLines(manifest);
  if (lines.length === 0) {
    throw new Error("project.yml is empty");
  }
  const documentIndices = directChildIndices(lines, 0, lines.length);
  // This audit intentionally accepts only a direct manifest. XcodeGen composition rewrites
  // sources and dependencies before generation, so accepting an unexpanded form would fail open.
  for (const index of documentIndices) {
    const { key } = parseYAMLMapping(lines[index].content, lines[index].lineNumber);
    if (key === "<<"
        || key.includes(":")
        || [
          "aggregateTargets",
          "include",
          "localPackages",
          "schemeTemplates",
          "targetTemplates",
        ].includes(key)) {
      throw new Error(`unsupported top-level XcodeGen expansion key: ${key}`);
    }
    if (!approvedTopLevelKeys.has(key)) {
      throw new Error(`unsupported top-level XcodeGen key: ${key}`);
    }
  }
  validateGenerationCommands(lines, documentIndices);
  validateSchemeCommands(lines, documentIndices);
  const targetsIndex = uniqueMappingIndex(
    lines,
    documentIndices,
    "targets",
    "targets mapping",
  );
  if (parseYAMLMapping(lines[targetsIndex].content, lines[targetsIndex].lineNumber).value !== undefined) {
    throw new Error("targets must be a mapping");
  }

  const targetIndices = directChildIndices(lines, targetsIndex + 1, scopeEnd(lines, targetsIndex));
  if (targetIndices.length === 0) {
    throw new Error("targets mapping is empty");
  }

  const pathsByTarget = new Map();
  for (const targetIndex of targetIndices) {
    const target = parseYAMLMapping(lines[targetIndex].content, lines[targetIndex].lineNumber);
    if (target.value !== undefined) {
      throw new Error(`Xcode target ${target.key} must be a mapping`);
    }
    if (pathsByTarget.has(target.key)) {
      throw new Error(`duplicate Xcode target: ${target.key}`);
    }

    const targetEnd = scopeEnd(lines, targetIndex);
    const propertyIndices = directChildIndices(lines, targetIndex + 1, targetEnd);
    for (const propertyIndex of propertyIndices) {
      const { key } = parseYAMLMapping(
        lines[propertyIndex].content,
        lines[propertyIndex].lineNumber,
      );
      if (["legacy", "name", "platformPrefix", "platformSuffix"].includes(key)) {
        throw new Error(`unsupported XcodeGen identity key in target ${target.key}: ${key}`);
      }
      if (key === "transitivelyLinkDependencies") {
        throw new Error(`transitive dependency linking is unsupported in target ${target.key}`);
      }
      if (["entitlements", "info"].includes(key)) {
        throw new Error(`unsupported generated-file key in target ${target.key}: ${key}`);
      }
      if ([
        "buildRules",
        "buildToolPlugins",
        "postBuildScripts",
        "postCompileScripts",
        "postbuildScripts",
        "preBuildScripts",
        "prebuildScripts",
        "scheme",
      ].includes(key)) {
        throw new Error(`unsupported executable graph key in target ${target.key}: ${key}`);
      }
      if (key === "<<" || key.includes(":") || ["templates", "templateAttributes"].includes(key)) {
        throw new Error(`unsupported XcodeGen expansion key in target ${target.key}: ${key}`);
      }
    }
    const platformIndex = uniqueMappingIndex(
      lines,
      propertyIndices,
      "platform",
      `platform in target ${target.key}`,
      false,
    );
    if (platformIndex !== undefined
        && parseYAMLMapping(
          lines[platformIndex].content,
          lines[platformIndex].lineNumber,
        ).value !== "iOS") {
      throw new Error(`target ${target.key} must use exactly platform iOS`);
    }
    const sourcesIndex = uniqueMappingIndex(
      lines,
      propertyIndices,
      "sources",
      `sources mapping in target ${target.key}`,
      false,
    );
    if (sourcesIndex === undefined) {
      pathsByTarget.set(target.key, []);
      continue;
    }
    if (parseYAMLMapping(lines[sourcesIndex].content, lines[sourcesIndex].lineNumber).value !== undefined) {
      throw new Error(`sources for target ${target.key} must be a sequence`);
    }
    pathsByTarget.set(target.key, parseSourceEntries(lines, sourcesIndex, target.key));
  }

  return pathsByTarget;
}

function swiftFilesUnder(relativeRoot) {
  const absoluteRoot = path.join(repoRoot, relativeRoot);
  if (!fs.existsSync(absoluteRoot)) {
    return [];
  }
  const rootStatus = fs.lstatSync(absoluteRoot);
  if (rootStatus.isSymbolicLink()) {
    throw new Error(`source tree contains symbolic link: ${relativeRoot}`);
  }
  if (!rootStatus.isDirectory()) {
    return [];
  }

  const files = [];
  const visit = (directory) => {
    for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
      const entryPath = path.join(directory, entry.name);
      if (entry.isSymbolicLink()) {
        throw new Error(
          `source tree contains symbolic link: ${path.relative(repoRoot, entryPath).split(path.sep).join("/")}`,
        );
      } else if (entry.isDirectory()) {
        visit(entryPath);
      } else if (entry.isFile() && entry.name.endsWith(".swift")) {
        files.push(path.relative(repoRoot, entryPath).split(path.sep).join("/"));
      }
    }
  };
  visit(absoluteRoot);
  return files;
}

let manifest;
try {
  manifest = fs.readFileSync(manifestPath, "utf8");
} catch (error) {
  console.error(`check-xcodegen-sources: cannot read project.yml: ${error.message}`);
  process.exitCode = 1;
}

if (manifest !== undefined) {
  const errors = [];
  let pathsByTarget = new Map();
  try {
    pathsByTarget = parseTargetSourcePaths(manifest);
  } catch (error) {
    errors.push(`cannot parse target sources: ${error.message}`);
  }
  const registeredPaths = new Set();
  const compiledSwiftPathsByTarget = new Map();
  const sourceRoots = new Set(
    [...allowedSourceRootsByTarget.values()].flatMap((roots) => [...roots]),
  );

  for (const [target, sourceEntries] of pathsByTarget) {
    compiledSwiftPathsByTarget.set(target, new Set());
    const allowedRoots = allowedSourceRootsByTarget.get(target);
    if (!allowedRoots) {
      errors.push(`unclassified Xcode target: ${target}`);
    }
    const seenInTarget = new Set();
    for (const { path: sourcePath, buildPhase } of sourceEntries) {
      const components = sourcePath.split("/");
      if (path.isAbsolute(sourcePath)
          || components.some((component) => component === "" || component === "." || component === "..")) {
        errors.push(`unsafe source path in target ${target}: ${sourcePath}`);
        continue;
      }
      if (allowedRoots && !allowedRoots.has(components[0])) {
        errors.push(`source root ${components[0]} is not allowed in target ${target}: ${sourcePath}`);
      }
      sourceRoots.add(components[0]);

      const absolutePath = path.join(repoRoot, sourcePath);
      if (fs.existsSync(absolutePath)) {
        const sourceStatus = fs.lstatSync(absolutePath);
        if (sourceStatus.isSymbolicLink()) {
          errors.push(`source tree contains symbolic link: ${sourcePath}`);
          continue;
        }
        if (sourceStatus.isDirectory()) {
          try {
            if (swiftFilesUnder(sourcePath).length > 0) {
              errors.push(`directory source path must list Swift files explicitly: ${sourcePath}`);
            }
          } catch (error) {
            errors.push(error.message);
          }
          continue;
        }
      }
      if (components.length < 2) {
        errors.push(`top-level source path is unsupported: ${sourcePath}`);
        continue;
      }
      if (!sourcePath.endsWith(".swift")) {
        continue;
      }

      if (buildPhase !== undefined && buildPhase !== "sources") {
        errors.push(`Swift source is not in the sources build phase for ${target}: ${sourcePath}`);
        continue;
      }

      const swiftPath = sourcePath;
      if (seenInTarget.has(swiftPath)) {
        errors.push(`duplicate Swift path in target ${target}: ${swiftPath}`);
      }
      seenInTarget.add(swiftPath);
      registeredPaths.add(swiftPath);
      compiledSwiftPathsByTarget.get(target).add(swiftPath);
    }
  }

  for (const swiftPath of [...registeredPaths].sort()) {
    if (!fs.existsSync(path.join(repoRoot, swiftPath))) {
      errors.push(`manifest Swift path does not exist: ${swiftPath}`);
    }
  }

  const diskPaths = [];
  for (const sourceRoot of [...sourceRoots].sort()) {
    try {
      diskPaths.push(...swiftFilesUnder(sourceRoot));
    } catch (error) {
      errors.push(error.message);
    }
  }
  diskPaths.sort();
  for (const swiftPath of diskPaths) {
    if (!registeredPaths.has(swiftPath)) {
      errors.push(`unregistered Swift source: ${swiftPath}`);
    }
  }

  if (errors.length > 0) {
    for (const error of errors) {
      console.error(`check-xcodegen-sources: ${error}`);
    }
    process.exitCode = 1;
  } else if (emitBoundaryJSON) {
    const targets = Object.fromEntries(
      [...compiledSwiftPathsByTarget]
        .sort(([left], [right]) => left.localeCompare(right))
        .map(([target, paths]) => [target, [...paths].sort()]),
    );
    console.log(JSON.stringify({ targets }, null, 2));
  } else {
    console.log("check-xcodegen-sources: all Swift sources have valid explicit target membership");
  }
}
