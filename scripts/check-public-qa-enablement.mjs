#!/usr/bin/env node
import { spawnSync } from "node:child_process";
import { addedLinesFromUnifiedDiff } from "./unified-diff.mjs";

const repoRoot = process.cwd();
const protectedFlag = ["LAVA", "QA", "TOOLS"].join("_");
const allowedSwiftRoots = [
  "LavaSecApp",
  "LavaSecTunnel",
  "LavaSecWidget",
  "LavaSecIntents",
  "LavaSecUITests",
  "Shared",
  "Sources",
  "Tests",
];
const referenceOnlyAnalyzerPaths = new Set([
  "scripts/check-public-qa-enablement.mjs",
  "scripts/check-string-coverage.mjs",
]);
const internalOnlyWorkflowPath = ".github/workflows/light-build.yml";

function parseArguments(args) {
  let base;
  let head;
  for (let index = 0; index < args.length; index += 2) {
    const flag = args[index];
    const value = args[index + 1];
    if (!value || !["--base", "--head"].includes(flag)) {
      throw new Error(
        "usage: node scripts/check-public-qa-enablement.mjs --base <sha> --head <sha>",
      );
    }
    if (flag === "--base") {
      base = value;
    } else {
      head = value;
    }
  }
  if (!base || !head) {
    throw new Error("--base and --head are required");
  }
  return { base, head };
}

function gitPatch(args) {
  const result = spawnSync(
    "git",
    ["-c", "core.quotePath=false", ...args],
    { cwd: repoRoot, encoding: "utf8", maxBuffer: 256 * 1024 * 1024 },
  );
  if (result.status !== 0) {
    const detail = result.error?.message || result.stderr.trim() || `exit status ${result.status}`;
    throw new Error(`git ${args[0]} failed: ${detail}`);
  }
  return result.stdout;
}

function protectedFlagIndices(content) {
  const indices = [];
  let index = content.indexOf(protectedFlag);
  while (index !== -1) {
    indices.push(index);
    index = content.indexOf(protectedFlag, index + protectedFlag.length);
  }
  return indices;
}

function pathIsAllowedSwiftSource(file) {
  return file.endsWith(".swift")
    && allowedSwiftRoots.some((root) => file.startsWith(`${root}/`));
}

function pathMayReferenceProtectedFlag(file, baseHasInternalOnlyWorkflow) {
  // Guard implementations and fixture sources must be able to name the token they
  // inspect. They do not participate in an app/package build; executable build scripts
  // elsewhere under scripts/ remain forbidden and are covered by fixture tests.
  return pathIsAllowedSwiftSource(file)
    || /^scripts\/tests\/[^/]+\.test\.mjs$/.test(file)
    || referenceOnlyAnalyzerPaths.has(file)
    // The internal lane legitimately compiles the QA configuration, but the workflow is
    // denylisted from public exports. Trust only a path already present in the base tree:
    // a public PR cannot create a lookalike workflow in its head to gain this exception.
    || (baseHasInternalOnlyWorkflow && file === internalOnlyWorkflowPath);
}

let range;
try {
  range = parseArguments(process.argv.slice(2));
} catch (error) {
  console.error(`check-public-qa-enablement: ${error.message}`);
  process.exit(2);
}

let additions;
let baseHasInternalOnlyWorkflow;
try {
  baseHasInternalOnlyWorkflow = gitPatch([
    "ls-tree",
    "--name-only",
    range.base,
    "--",
    internalOnlyWorkflowPath,
  ]).trim() === internalOnlyWorkflowPath;
  const revisionRange = `${range.base}..${range.head}`;
  const historyPatch = gitPatch([
    "log",
    revisionRange,
    "--format=",
    "--patch",
    "--text",
    "--diff-merges=first-parent",
    "--unified=0",
    "--no-color",
    "--no-ext-diff",
    "--no-renames",
    "--",
    ".",
  ]);
  const endpointPatch = gitPatch([
    "diff",
    revisionRange,
    "--text",
    "--unified=0",
    "--no-color",
    "--no-ext-diff",
    "--no-renames",
    "--",
    ".",
  ]);
  additions = [
    ...addedLinesFromUnifiedDiff(historyPatch),
    ...addedLinesFromUnifiedDiff(endpointPatch),
  ];
} catch (error) {
  console.error(`check-public-qa-enablement: ${error.message}`);
  process.exit(2);
}

const violations = new Map();
for (const addition of additions) {
  if (protectedFlagIndices(addition.content).length > 0
      && !pathMayReferenceProtectedFlag(addition.file, baseHasInternalOnlyWorkflow)) {
    const key = `${addition.file}:${addition.line}:${addition.content}`;
    violations.set(key, addition);
  }
}

if (violations.size > 0) {
  for (const violation of violations.values()) {
    console.error(
      `check-public-qa-enablement: ${violation.file}:${violation.line}: ${protectedFlag} occurrence is outside approved source and analyzer paths`,
    );
  }
  process.exitCode = 1;
} else {
  console.log("check-public-qa-enablement: no newly enabled public QA build flag");
}
