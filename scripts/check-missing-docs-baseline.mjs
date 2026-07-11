#!/usr/bin/env node
import { spawnSync } from "node:child_process";
import fs from "node:fs";

import { addedLinesFromUnifiedDiff } from "./unified-diff.mjs";

const baselinePath = ".swiftlint-missing-docs-baseline.json";
const configPath = ".swiftlint-missing-docs.yml";
const requiredPolicyFiles = new Set([baselinePath, configPath]);
const approvedIncludedRoots = [
  "Sources/LavaSecKit",
  "Sources/LavaSecNetworking",
  "Sources/LavaSecDNS",
  "Sources/LavaSecFilterPipeline",
  "Sources/LavaSecPresentation",
  "Sources/LavaSecAppServices",
];
const approvedExcludedPaths = new Set([
  "Sources/LavaSecKit/Generated/DefaultCatalog+Generated.swift",
]);
const approvedMissingDocsOptions = new Map([
  ["warning", "[open, public]"],
  ["excludes_extensions", "true"],
  ["excludes_inherited_types", "true"],
  ["excludes_trivial_init", "false"],
  ["evaluate_effective_access_control_level", "false"],
]);

function parseArguments(args) {
  if (args.length === 0) {
    return null;
  }

  let base;
  let head;
  for (let index = 0; index < args.length; index += 2) {
    const flag = args[index];
    const value = args[index + 1];
    if (!value || !["--base", "--head"].includes(flag)) {
      throw new Error(
        "usage: node scripts/check-missing-docs-baseline.mjs [--base <sha> --head <sha>]",
      );
    }
    if (flag === "--base") {
      if (base !== undefined) throw new Error("--base may be provided only once");
      base = value;
    } else {
      if (head !== undefined) throw new Error("--head may be provided only once");
      head = value;
    }
  }
  if (!base || !head) {
    throw new Error("--base and --head must be provided together");
  }
  return { base, head };
}

function git(args) {
  return spawnSync("git", args, {
    encoding: "utf8",
    maxBuffer: 64 * 1024 * 1024,
  });
}

function requireCommit(revision, label) {
  const result = git(["rev-parse", "--verify", "--quiet", `${revision}^{commit}`]);
  if (result.status !== 0) {
    throw new Error(`${label} revision is not a commit: ${revision}`);
  }
}

class DuplicateJSONKeyError extends Error {
  constructor(key) {
    super(key);
    this.key = key;
  }
}

class JSONStructureScanError extends Error {}

function rejectDuplicateJSONKeys(contents, label) {
  let index = 0;
  const syntaxError = () => {
    throw new JSONStructureScanError();
  };
  const skipWhitespace = () => {
    while (index < contents.length && /[\t\n\r ]/.test(contents[index])) {
      index += 1;
    }
  };
  const parseString = () => {
    if (contents[index] !== '"') syntaxError();
    const start = index;
    index += 1;
    while (index < contents.length) {
      const character = contents[index];
      if (character === '"') {
        index += 1;
        try {
          return JSON.parse(contents.slice(start, index));
        } catch {
          syntaxError();
        }
      }
      if (character === "\\") {
        index += 1;
        const escape = contents[index];
        if (escape === "u") {
          if (!/^[0-9a-fA-F]{4}$/.test(contents.slice(index + 1, index + 5))) {
            syntaxError();
          }
          index += 5;
          continue;
        }
        if (!'"\\/bfnrt'.includes(escape ?? "")) syntaxError();
        index += 1;
        continue;
      }
      if (character.charCodeAt(0) <= 0x1F) syntaxError();
      index += 1;
    }
    syntaxError();
  };
  const parseNumber = () => {
    const number = contents.slice(index).match(
      /^-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?/,
    )?.[0];
    if (!number) syntaxError();
    index += number.length;
  };
  const parseValue = () => {
    skipWhitespace();
    const character = contents[index];
    if (character === "{") {
      parseObject();
      return;
    }
    if (character === "[") {
      parseArray();
      return;
    }
    if (character === '"') {
      parseString();
      return;
    }
    for (const literal of ["true", "false", "null"]) {
      if (contents.startsWith(literal, index)) {
        index += literal.length;
        return;
      }
    }
    parseNumber();
  };
  const parseObject = () => {
    index += 1;
    skipWhitespace();
    const keys = new Set();
    if (contents[index] === "}") {
      index += 1;
      return;
    }
    while (index < contents.length) {
      skipWhitespace();
      const key = parseString();
      if (keys.has(key)) throw new DuplicateJSONKeyError(key);
      keys.add(key);
      skipWhitespace();
      if (contents[index] !== ":") syntaxError();
      index += 1;
      parseValue();
      skipWhitespace();
      if (contents[index] === "}") {
        index += 1;
        return;
      }
      if (contents[index] !== ",") syntaxError();
      index += 1;
    }
    syntaxError();
  };
  const parseArray = () => {
    index += 1;
    skipWhitespace();
    if (contents[index] === "]") {
      index += 1;
      return;
    }
    while (index < contents.length) {
      parseValue();
      skipWhitespace();
      if (contents[index] === "]") {
        index += 1;
        return;
      }
      if (contents[index] !== ",") syntaxError();
      index += 1;
    }
    syntaxError();
  };

  try {
    parseValue();
    skipWhitespace();
    if (index !== contents.length) syntaxError();
  } catch (error) {
    if (error instanceof DuplicateJSONKeyError) {
      const key = /^[A-Za-z_][A-Za-z0-9_]*$/.test(error.key)
        ? error.key
        : JSON.stringify(error.key);
      throw new Error(`${label} baseline contains duplicate JSON object key ${key}`);
    }
    if (!(error instanceof JSONStructureScanError)) throw error;
    // JSON.parse below remains the source of the stable malformed-JSON diagnostic.
  }
}

function parseBaseline(contents, label) {
  let baseline;
  rejectDuplicateJSONKeys(contents, label);
  try {
    baseline = JSON.parse(contents);
  } catch {
    throw new Error(`${label} baseline is not valid JSON`);
  }
  if (!Array.isArray(baseline)) {
    throw new Error(`${label} baseline must be a JSON array`);
  }
  const identities = [];
  for (const [index, entry] of baseline.entries()) {
    if (entry === null
        || typeof entry !== "object"
        || Array.isArray(entry)
        || entry.violation === null
        || typeof entry.violation !== "object"
        || entry.violation.ruleIdentifier !== "missing_docs"
        || entry.violation.location === null
        || typeof entry.violation.location !== "object"
        || typeof entry.violation.location.file !== "string"
        || entry.violation.location.file.length === 0
        || typeof entry.violation.reason !== "string"
        || typeof entry.text !== "string") {
      throw new Error(
        `${label} baseline entry ${index + 1} must be a missing_docs violation with complete identity fields`,
      );
    }
    const identity = [
      entry.violation.location.file,
      entry.violation.ruleIdentifier,
      entry.text,
      entry.violation.reason,
    ];
    identities.push({
      file: entry.violation.location.file,
      key: JSON.stringify(identity),
    });
  }
  return { count: baseline.length, identities };
}

function parseListSection(contents, key, label) {
  const lines = contents.split(/\r?\n/);
  const candidates = lines
    .map((line, index) => ({ index, line }))
    .filter(({ line }) => new RegExp(`^${key}\\s*:`).test(line));
  if (candidates.length !== 1 || candidates[0].line !== `${key}:`) {
    throw new Error(`${label} missing-doc config must contain one direct ${key}: list`);
  }
  const entries = [];
  for (let index = candidates[0].index + 1; index < lines.length; index += 1) {
    const line = lines[index];
    const trimmed = line.trim();
    if (trimmed.length === 0 || trimmed.startsWith("#")) {
      continue;
    }
    if (!/^\s/.test(line)) {
      break;
    }
    const entry = line.match(/^\s+-\s+([^\s].*?)\s*$/);
    if (!entry) {
      throw new Error(`${label} missing-doc ${key} scope contains unsupported YAML`);
    }
    entries.push(entry[1]);
  }
  if (new Set(entries).size !== entries.length) {
    throw new Error(`${label} missing-doc ${key} scope contains duplicates`);
  }
  return entries;
}

function parseMappingSection(contents, key, label) {
  const lines = contents.split(/\r?\n/);
  const candidates = lines
    .map((line, index) => ({ index, line }))
    .filter(({ line }) => new RegExp(`^${key}\\s*:`).test(line));
  if (candidates.length !== 1 || candidates[0].line !== `${key}:`) {
    throw new Error(`${label} missing-doc config must contain one direct ${key}: mapping`);
  }
  const entries = new Map();
  for (let index = candidates[0].index + 1; index < lines.length; index += 1) {
    const line = lines[index];
    const trimmed = line.trim();
    if (trimmed.length === 0 || trimmed.startsWith("#")) {
      continue;
    }
    if (!/^\s/.test(line)) {
      break;
    }
    const entry = line.match(/^\s+([A-Za-z_][A-Za-z0-9_]*)\s*:\s*(\S.*?)\s*$/);
    if (!entry) {
      throw new Error(`${label} missing-doc ${key} options contain unsupported YAML`);
    }
    if (entries.has(entry[1])) {
      throw new Error(`${label} missing-doc ${key} options contain duplicate ${entry[1]}`);
    }
    entries.set(entry[1], entry[2]);
  }
  return entries;
}

function validateMissingDocsConfig(contents, label) {
  if (contents.includes("\uFEFF")) {
    throw new Error(`${label} missing-doc config contains an unsupported byte-order mark`);
  }
  if (/\r(?!\n)|[\u0085\u2028\u2029]/u.test(contents)) {
    throw new Error(`${label} missing-doc config contains an unsupported line separator`);
  }
  const allowedTopLevelKeys = new Set([
    "included",
    "excluded",
    "opt_in_rules",
    "missing_docs",
  ]);
  for (const line of contents.split(/\r?\n/)) {
    const trimmed = line.trim();
    if (trimmed.length === 0 || trimmed.startsWith("#") || /^\s/.test(line)) {
      continue;
    }
    const mapping = line.match(/^([A-Za-z_][A-Za-z0-9_]*)\s*:/);
    if (!mapping) {
      throw new Error(`${label} missing-doc config contains unsupported top-level syntax`);
    }
    if (!allowedTopLevelKeys.has(mapping[1])) {
      throw new Error(
        `${label} missing-doc config contains unsupported top-level key ${mapping[1]}`,
      );
    }
    if (line !== `${mapping[1]}:`) {
      throw new Error(`${label} missing-doc config contains unsupported top-level syntax`);
    }
  }
  const included = parseListSection(contents, "included", label);
  if (JSON.stringify([...included].sort()) !== JSON.stringify([...approvedIncludedRoots].sort())) {
    throw new Error(`${label} missing-doc included scope differs from policy`);
  }
  const excluded = parseListSection(contents, "excluded", label);
  const unapproved = excluded.filter((entry) => !approvedExcludedPaths.has(entry)).sort();
  if (unapproved.length > 0) {
    throw new Error(
      `${label} missing-doc excluded scope contains unapproved paths: ${unapproved.join(", ")}`,
    );
  }
  const optInRules = parseListSection(contents, "opt_in_rules", label);
  if (JSON.stringify(optInRules) !== JSON.stringify(["missing_docs"])) {
    throw new Error(`${label} missing-doc opt_in_rules differs from policy`);
  }
  const ruleOptions = parseMappingSection(contents, "missing_docs", label);
  const canonicalOptions = (options) => JSON.stringify(
    [...options].sort(([left], [right]) => left.localeCompare(right)),
  );
  if (canonicalOptions(ruleOptions) !== canonicalOptions(approvedMissingDocsOptions)) {
    throw new Error(`${label} missing-doc rule options differ from policy`);
  }
}

function baselineAt(revision, label, { allowMissing }) {
  requireCommit(revision, label);
  const object = `${revision}:${baselinePath}`;
  const exists = git(["cat-file", "-e", object]);
  if (exists.status !== 0) {
    if (allowMissing) return null;
    throw new Error(`${label} baseline is missing`);
  }

  const result = git(["show", object]);
  if (result.status !== 0) {
    const detail = result.error?.message || result.stderr.trim() || `exit status ${result.status}`;
    throw new Error(`could not read ${label} baseline: ${detail}`);
  }
  return parseBaseline(result.stdout, label);
}

function configAt(revision, label) {
  requireCommit(revision, label);
  const result = git(["show", `${revision}:${configPath}`]);
  if (result.status !== 0) {
    const detail = result.error?.message || result.stderr.trim() || `exit status ${result.status}`;
    throw new Error(`could not read ${label} missing-doc config: ${detail}`);
  }
  return result.stdout;
}

function isMissingDocsSuppression(content) {
  const directive = content.match(
    /\/\/[\s\S]*?\bswiftlint\s*:\s*disable(?::(?:this|next|previous|file))?(?:\s+([\s\S]*?))?\s*$/i,
  );
  if (!directive) {
    return false;
  }
  const rules = (directive[1] ?? "")
    .split(/[\s,]+/)
    .map((rule) => rule.toLowerCase())
    .filter((rule) => rule.length > 0);
  return rules.length === 0 || rules.includes("all") || rules.includes("missing_docs");
}

function containsMissingDocsSuppression(content) {
  return content
    .split(/\r\n|[\n\r\u0085\u2028\u2029]/u)
    .some(isMissingDocsSuppression);
}

function isProtectedMissingDocsPath(filePath) {
  const identity = filePath.normalize("NFC").toLowerCase();
  return approvedIncludedRoots.some((root) => {
    const rootIdentity = root.normalize("NFC").toLowerCase();
    return identity === rootIdentity || identity.startsWith(`${rootIdentity}/`);
  });
}

function isProtectedMissingDocsAncestor(filePath) {
  const identity = filePath.normalize("NFC").toLowerCase();
  return approvedIncludedRoots.some((root) => (
    root.normalize("NFC").toLowerCase().startsWith(`${identity}/`)
  ));
}

function validateProtectedMissingDocsTree(head) {
  const result = git(["ls-tree", "-r", "-z", head]);
  if (result.status !== 0) {
    const detail = result.error?.message || result.stderr.trim() || `exit status ${result.status}`;
    throw new Error(`could not inspect head missing-doc source tree: ${detail}`);
  }
  const protectedFiles = [];
  const foundApprovedExclusions = new Set();
  const foundPolicyFiles = new Set();
  for (const record of result.stdout.split("\0").filter((entry) => entry.length > 0)) {
    const separator = record.indexOf("\t");
    const metadata = separator >= 0 ? record.slice(0, separator).split(" ") : [];
    const filePath = separator >= 0 ? record.slice(separator + 1) : "";
    if (metadata.length !== 3 || filePath.length === 0) {
      throw new Error("head tree contains malformed Git metadata");
    }
    const [mode, type] = metadata;
    if (requiredPolicyFiles.has(filePath)) {
      if (type !== "blob" || mode !== "100644") {
        throw new Error(
          `head missing-doc policy file is not a regular 100644 blob ${filePath} (${mode} ${type})`,
        );
      }
      foundPolicyFiles.add(filePath);
    }
    for (const excludedPath of approvedExcludedPaths) {
      if (filePath === excludedPath) {
        if (type !== "blob" || !["100644", "100755"].includes(mode)) {
          throw new Error(
            `head missing-doc exclusion is not a regular file ${filePath} (${mode} ${type})`,
          );
        }
        foundApprovedExclusions.add(excludedPath);
      } else if (filePath.startsWith(`${excludedPath}/`)) {
        throw new Error(
          `head missing-doc exclusion path contains tracked descendant ${filePath}`,
        );
      }
    }
    if ((isProtectedMissingDocsPath(filePath) || isProtectedMissingDocsAncestor(filePath))
        && (type !== "blob" || !["100644", "100755"].includes(mode))) {
      throw new Error(
        `head protected missing-doc scope contains non-regular entry ${filePath} (${mode} ${type})`,
      );
    }
    if (isProtectedMissingDocsPath(filePath)
        && type === "blob"
        && ["100644", "100755"].includes(mode)) {
      protectedFiles.push(filePath);
    }
  }
  for (const excludedPath of approvedExcludedPaths) {
    if (!foundApprovedExclusions.has(excludedPath)) {
      throw new Error(`head missing-doc exclusion is missing ${excludedPath}`);
    }
  }
  for (const policyFile of requiredPolicyFiles) {
    if (!foundPolicyFiles.has(policyFile)) {
      throw new Error(`head missing-doc policy file is missing ${policyFile}`);
    }
  }
  return protectedFiles;
}

function requireRegularWorkingTreeFile(filePath) {
  let current = "";
  const components = filePath.split("/");
  for (const [index, component] of components.entries()) {
    current = current ? `${current}/${component}` : component;
    let stats;
    try {
      stats = fs.lstatSync(current);
    } catch (error) {
      throw new Error(`working tree is missing ${current}: ${error.message}`);
    }
    if (stats.isSymbolicLink()) {
      throw new Error(`working tree path contains symlink ${current}`);
    }
    const isLeaf = index === components.length - 1;
    if ((isLeaf && !stats.isFile()) || (!isLeaf && !stats.isDirectory())) {
      throw new Error(`working tree path has unexpected type ${current}`);
    }
  }
}

function validateWorkingTreeMissingDocsFiles() {
  const result = git(["ls-files", "--stage", "-z"]);
  if (result.status !== 0) {
    const detail = result.error?.message || result.stderr.trim() || `exit status ${result.status}`;
    throw new Error(`could not inspect working-tree index: ${detail}`);
  }
  const protectedFiles = new Set();
  const foundPolicyFiles = new Set();
  const foundApprovedExclusions = new Set();
  for (const record of result.stdout.split("\0").filter((entry) => entry.length > 0)) {
    const separator = record.indexOf("\t");
    const metadata = separator >= 0 ? record.slice(0, separator).split(" ") : [];
    const filePath = separator >= 0 ? record.slice(separator + 1) : "";
    if (metadata.length !== 3 || filePath.length === 0) {
      throw new Error("working-tree index contains malformed Git metadata");
    }
    const [mode, , stage] = metadata;
    if (stage !== "0") {
      throw new Error(`working-tree index contains unresolved entry ${filePath}`);
    }
    if (requiredPolicyFiles.has(filePath)) {
      if (mode !== "100644") {
        throw new Error(
          `working-tree missing-doc policy file is not a regular 100644 blob ${filePath} (${mode})`,
        );
      }
      foundPolicyFiles.add(filePath);
    }
    for (const excludedPath of approvedExcludedPaths) {
      if (filePath === excludedPath) {
        if (!["100644", "100755"].includes(mode)) {
          throw new Error(
            `working-tree missing-doc exclusion is not a regular file ${filePath} (${mode})`,
          );
        }
        foundApprovedExclusions.add(excludedPath);
      } else if (filePath.startsWith(`${excludedPath}/`)) {
        throw new Error(
          `working-tree missing-doc exclusion path contains tracked descendant ${filePath}`,
        );
      }
    }
    if ((isProtectedMissingDocsPath(filePath) || isProtectedMissingDocsAncestor(filePath))
        && !["100644", "100755"].includes(mode)) {
      throw new Error(
        `working-tree protected missing-doc scope contains non-regular entry ${filePath} (${mode})`,
      );
    }
    if (isProtectedMissingDocsPath(filePath) && ["100644", "100755"].includes(mode)) {
      protectedFiles.add(filePath);
    }
  }
  for (const policyFile of requiredPolicyFiles) {
    if (!foundPolicyFiles.has(policyFile)) {
      throw new Error(`working-tree missing-doc policy file is missing ${policyFile}`);
    }
    requireRegularWorkingTreeFile(policyFile);
  }
  for (const excludedPath of approvedExcludedPaths) {
    if (!foundApprovedExclusions.has(excludedPath)) {
      throw new Error(`working-tree missing-doc exclusion is missing ${excludedPath}`);
    }
  }

  const untracked = git(["ls-files", "--others", "--exclude-standard", "-z"]);
  if (untracked.status !== 0) {
    const detail = untracked.error?.message || untracked.stderr.trim()
      || `exit status ${untracked.status}`;
    throw new Error(`could not inspect untracked working-tree files: ${detail}`);
  }
  for (const filePath of untracked.stdout.split("\0").filter((entry) => entry.length > 0)) {
    for (const excludedPath of approvedExcludedPaths) {
      if (filePath === excludedPath || filePath.startsWith(`${excludedPath}/`)) {
        throw new Error(`working-tree missing-doc exclusion path contains untracked entry ${filePath}`);
      }
    }
    if (isProtectedMissingDocsPath(filePath)) {
      protectedFiles.add(filePath);
    }
  }
  for (const filePath of protectedFiles) {
    requireRegularWorkingTreeFile(filePath);
  }
  return [...protectedFiles];
}

function rejectWorkingTreeMissingDocsSuppressions(protectedFiles) {
  for (const filePath of protectedFiles) {
    const contents = fs.readFileSync(filePath, "utf8");
    if (containsMissingDocsSuppression(contents)) {
      throw new Error(`working tree contains missing-doc suppression in ${filePath}`);
    }
  }
}

function rejectAddedMissingDocsSuppressions(base, head) {
  const result = git([
    "diff",
    "--text",
    "--unified=0",
    "--no-ext-diff",
    "--no-renames",
    base,
    head,
  ]);
  if (result.status !== 0) {
    const detail = result.error?.message || result.stderr.trim() || `exit status ${result.status}`;
    throw new Error(`could not inspect missing-doc source changes: ${detail}`);
  }
  const suppression = addedLinesFromUnifiedDiff(result.stdout).find((addition) => (
    isProtectedMissingDocsPath(addition.file)
      && containsMissingDocsSuppression(addition.content)
  ));
  if (suppression) {
    throw new Error(
      `head introduces missing-doc suppression in ${suppression.file}:${suppression.line}`,
    );
  }
}

function entryLabel(count) {
  return count === 1 ? "entry" : "entries";
}

function newBaselineIdentities(base, head) {
  const remaining = new Map();
  for (const identity of base.identities) {
    remaining.set(identity.key, (remaining.get(identity.key) ?? 0) + 1);
  }
  const added = [];
  for (const identity of head.identities) {
    const count = remaining.get(identity.key) ?? 0;
    if (count === 0) {
      added.push(identity);
    } else if (count === 1) {
      remaining.delete(identity.key);
    } else {
      remaining.set(identity.key, count - 1);
    }
  }
  return added;
}

let range;
try {
  range = parseArguments(process.argv.slice(2));
  if (range === null) {
    validateProtectedMissingDocsTree("HEAD");
    const protectedFiles = validateWorkingTreeMissingDocsFiles();
    validateMissingDocsConfig(fs.readFileSync(configPath, "utf8"), "working-tree");
    rejectWorkingTreeMissingDocsSuppressions(protectedFiles);
    const contents = fs.readFileSync(baselinePath, "utf8");
    const { count } = parseBaseline(contents, "working-tree");
    console.log(
      `check-missing-docs-baseline: working-tree baseline is valid: ${count} ${entryLabel(count)}`,
    );
  } else {
    validateProtectedMissingDocsTree(range.head);
    validateMissingDocsConfig(configAt(range.head, "head"), "head");
    rejectAddedMissingDocsSuppressions(range.base, range.head);
    const headBaseline = baselineAt(range.head, "head", { allowMissing: false });
    const baseBaseline = baselineAt(range.base, "base", { allowMissing: true });
    if (baseBaseline === null) {
      console.log(
        `check-missing-docs-baseline: initial baseline seed accepted: ${headBaseline.count} ${entryLabel(headBaseline.count)}`,
      );
    } else {
      if (headBaseline.count > baseBaseline.count) {
        throw new Error(`baseline grew: ${baseBaseline.count} -> ${headBaseline.count}`);
      }
      const added = newBaselineIdentities(baseBaseline, headBaseline);
      if (added.length > 0) {
        const noun = added.length === 1 ? "identity" : "identities";
        const files = [...new Set(added.map((entry) => entry.file))].sort();
        throw new Error(
          `baseline contains ${added.length} new missing-doc ${noun}: ${files.join(", ")}`,
        );
      }
      console.log(
        `check-missing-docs-baseline: baseline count did not increase: ${baseBaseline.count} -> ${headBaseline.count}`,
      );
    }
  }
} catch (error) {
  console.error(`check-missing-docs-baseline: ${error.message}`);
  process.exitCode = 1;
}
