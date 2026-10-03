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
  "ReactNative/native-app",
  "Shared",
  "Sources",
  "Tests",
];
const referenceOnlyAnalyzerPaths = new Set([
  "scripts/check-public-qa-enablement.mjs",
  "scripts/check-string-coverage.mjs",
]);
const internalOnlyWorkflowPath = ".github/workflows/light-build.yml";
const conditionalConsumerPath = "ReactNative/ios/LavaSecUIReview/LavaReviewModule.mm";
const historicalReferencePath = "docs/design-revamp/2026-09-15-round8-shared-editors.md";
const exploreNarrationRoot = "docs/design-revamp/explore-narration-drafts";
const exploreNarrationAudioExtensions = new Set([".mp3", ".caf", ".opus"]);
// This reviewed receipt records a past local invocation; it is not a build input.
// Permit only this complete Markdown reference, not arbitrary flags in this file
// or other documentation. Its committed modes are checked separately below.
const historicalReference = [
  "Command shape (complete local invocations are retained in the private receipt):",
  "`xcodebuild -workspace ReactNative/native-app/LavaSecRN.xcworkspace",
  "-scheme LavaSec -configuration QA -destination 'platform=iOS Simulator,id=<dedicated QA simulator>'",
  `'OTHER_SWIFT_FLAGS=$(inherited) -D ${protectedFlag}' build-for-testing\`, then \`xcodebuild test-without-building -xctestrun <frozen app lane>`,
  "-only-testing:LavaSecUITests/RNFullAppUITests/<selected test>` for the four named",
  "methods in the private receipt.",
].join("\n");
const historicalFlagLine = historicalReference.split("\n")[3];
// `--text` keeps binary attributes from hiding build inputs. Exempt only the three
// compiled Rust archives: scanning machine code for Swift build flags yields no signal
// and can break unified-diff parsing. Headers, plist, toolchain metadata and unexpected
// files under build/ remain scanned in BOTH repositories. The separate internal native
// gate also rebuilds the archives byte-for-byte; the public text scan does not depend on it.
// Review narration audio is excluded after its modes and headers are verified below;
// adjacent Markdown scripts and translations remain scanned.
const nonTextArtifactPaths = [
  ...["ios-arm64", "ios-arm64-simulator", "macos-arm64"].map(slice =>
    `:(exclude)ThirdParty/wireguard-core/build/LavaSecWGCore.xcframework/${slice}/liblavasec_wireguard_core.a`),
  ":(exclude,glob)docs/design-revamp/explore-narration-drafts/**/*.mp3",
  ":(exclude,glob)docs/design-revamp/explore-narration-drafts/**/*.caf",
  ":(exclude,glob)docs/design-revamp/explore-narration-drafts/**/*.opus",
];

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

function gitBlob(object) {
  const result = spawnSync("git", ["cat-file", "blob", object], {
    cwd: repoRoot,
    encoding: null,
    maxBuffer: 256 * 1024 * 1024,
  });
  if (result.status !== 0) {
    const detail = result.error?.message || result.stderr?.toString("utf8").trim() || `exit status ${result.status}`;
    throw new Error(`git cat-file failed: ${detail}`);
  }
  return result.stdout;
}

function gitBinary(args) {
  const result = spawnSync(
    "git",
    ["-c", "core.quotePath=false", ...args],
    { cwd: repoRoot, encoding: null, maxBuffer: 256 * 1024 * 1024 },
  );
  if (result.status !== 0) {
    const detail = result.error?.message || result.stderr?.toString("utf8").trim() || `exit status ${result.status}`;
    throw new Error(`git ${args[0]} failed: ${detail}`);
  }
  return result.stdout;
}

function parseNulDelimitedTree(tree, revision) {
  const entries = [];
  let offset = 0;
  while (offset < tree.length) {
    const end = tree.indexOf(0, offset);
    if (end < 0) throw new Error(`unterminated tree entry in ${exploreNarrationRoot}@${revision}`);
    const record = tree.subarray(offset, end);
    offset = end + 1;
    const separator = record.indexOf(0x09);
    if (separator < 0) throw new Error(`unexpected tree entry in ${exploreNarrationRoot}@${revision}`);
    const match = record.subarray(0, separator).toString("ascii").match(/^(\d{6}) blob ([0-9a-f]+)$/);
    if (!match) throw new Error(`unexpected tree entry in ${exploreNarrationRoot}@${revision}`);
    entries.push({mode: match[1], object: match[2], fileBytes: record.subarray(separator + 1)});
  }
  return entries;
}

function extensionFromGitPath(fileBytes) {
  const basenameOffset = fileBytes.lastIndexOf(0x2f) + 1;
  const dot = fileBytes.lastIndexOf(0x2e);
  return dot >= basenameOffset ? fileBytes.subarray(dot).toString("ascii") : "";
}

function hasReviewAudioHeader(file, bytes) {
  if (file.endsWith(".mp3")) {
    let audioOffset = 0;
    if (bytes.subarray(0, 3).toString("ascii") === "ID3") {
      if (bytes.length < 10 || (bytes[3] !== 3 && bytes[3] !== 4)) return false;
      const size = bytes.subarray(6, 10);
      if ([...size].some((byte) => (byte & 0x80) !== 0)) return false;
      const tagSize = (size[0] << 21) | (size[1] << 14) | (size[2] << 7) | size[3];
      audioOffset = 10 + tagSize + (bytes[3] === 4 && (bytes[5] & 0x10) !== 0 ? 10 : 0);
    }
    if (audioOffset + 4 > bytes.length) return false;
    const [sync, versionAndLayer, bitrateAndRate] = bytes.subarray(audioOffset, audioOffset + 3);
    return sync === 0xff && (versionAndLayer & 0xe0) === 0xe0
      && ((versionAndLayer >> 3) & 0x03) !== 0x01
      && ((versionAndLayer >> 1) & 0x03) !== 0
      && ((bitrateAndRate >> 4) & 0x0f) !== 0 && ((bitrateAndRate >> 4) & 0x0f) !== 0x0f
      && ((bitrateAndRate >> 2) & 0x03) !== 0x03;
  }
  if (file.endsWith(".caf")) {
    return bytes.length >= 8 && bytes.subarray(0, 4).toString("ascii") === "caff"
      && bytes.readUInt16BE(4) === 1;
  }
  if (file.endsWith(".opus")) {
    return bytes.length >= 36 && bytes.subarray(0, 4).toString("ascii") === "OggS"
      && bytes.includes(Buffer.from("OpusHead"));
  }
  return false;
}

function validateExploreNarrationAudio(range) {
  const changed = gitPatch([
    "log", `${range.base}..${range.head}`, "--format=%H", "--full-history", "--", exploreNarrationRoot,
  ]).trim().split("\n").filter(Boolean);
  const revisions = new Set([range.base, ...changed, range.head]);
  const errors = [];
  const checkedBlobs = new Map();
  for (const revision of revisions) {
    const tree = gitBinary(["ls-tree", "-r", "-z", revision, "--", exploreNarrationRoot]);
    for (const {mode, object, fileBytes} of parseNulDelimitedTree(tree, revision)) {
      const file = fileBytes.toString("utf8");
      const extension = extensionFromGitPath(fileBytes);
      if (!exploreNarrationAudioExtensions.has(extension)) continue;
      if (mode !== "100644") {
        errors.push(`${file}@${revision}: excluded narration audio must be a regular, non-executable file`);
        continue;
      }
      if (!checkedBlobs.has(object)) {
        const bytes = gitBlob(object);
        checkedBlobs.set(object, {
          hasMediaHeader: hasReviewAudioHeader(file, bytes),
          containsProtectedFlag: bytes.includes(Buffer.from(protectedFlag, "ascii")),
        });
      }
      const validation = checkedBlobs.get(object);
      if (!validation.hasMediaHeader) errors.push(`${file}@${revision}: excluded narration audio does not have a verified media header`);
      if (validation.containsProtectedFlag) errors.push(`${file}@${revision}: excluded narration audio contains the protected QA build flag`);
    }
  }
  return errors;
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

function inspectHistoricalReference(range) {
  // Include mode-only changes and intermediate/deleted versions. Checking only
  // HEAD would let an executable receipt become trusted after chmod or removal.
  const changed = gitPatch([
    "log", `${range.base}..${range.head}`, "--format=%H", "--full-history",
    "--", historicalReferencePath,
  ]).trim().split("\n").filter(Boolean);
  const head = gitPatch(["rev-parse", "--verify", `${range.head}^{commit}`]).trim();
  const revisions = new Set([range.base, ...changed, head]);
  const versions = [];
  const blobs = new Map();
  for (const revision of revisions) {
    const entry = gitPatch(["ls-tree", revision, "--", historicalReferencePath]).trim();
    if (!entry) continue;
    const match = entry.match(/^(\d+) blob ([0-9a-f]+)\t/);
    if (!match) throw new Error(`unexpected tree entry for ${historicalReferencePath}`);
    const [, mode, object] = match;
    if (!blobs.has(object)) blobs.set(object, gitPatch(["cat-file", "blob", object]));
    versions.push({revision, mode, content: blobs.get(object)});
  }
  if (!versions.some(({content}) => content.includes(protectedFlag))) return [];
  return versions.flatMap(({revision, mode, content}) => {
    const prefix = `${historicalReferencePath}@${revision}:`;
    if (mode !== "100644") return [`${prefix} historical documentation must remain a regular non-executable file`];
    if (!content.includes(protectedFlag)) return [];
    if (revision === head) return [`${prefix} the reviewed invocation is historical only and must be absent at HEAD`];
    if (!content.startsWith("# Round 8 shared editors and native admission\n")
        || !content.includes(historicalReference)
        || protectedFlagIndices(content).length !== 1) {
      return [`${prefix} differs from the reviewed historical QA reference`];
    }
    return [];
  });
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
let historicalReferenceErrors;
let narrationAudioErrors;
try {
  historicalReferenceErrors = inspectHistoricalReference(range);
  narrationAudioErrors = validateExploreNarrationAudio(range);
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
    ...nonTextArtifactPaths,
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
    ...nonTextArtifactPaths,
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
  // A consumer tests a build-provided macro; it cannot define or enable it.
  const conditionalReference = addition.file === conditionalConsumerPath
    && addition.content.trim() === `#if ${protectedFlag}`;
  const reviewedDocumentation = addition.file === historicalReferencePath
    && historicalReferenceErrors.length === 0 && addition.content === historicalFlagLine;
  if (protectedFlagIndices(addition.content).length > 0
      && !pathMayReferenceProtectedFlag(addition.file, baseHasInternalOnlyWorkflow)
      && !conditionalReference && !reviewedDocumentation) {
    const key = `${addition.file}:${addition.line}:${addition.content}`;
    violations.set(key, addition);
  }
}

if (violations.size > 0 || historicalReferenceErrors.length > 0 || narrationAudioErrors.length > 0) {
  for (const error of historicalReferenceErrors) console.error(`check-public-qa-enablement: ${error}`);
  for (const error of narrationAudioErrors) console.error(`check-public-qa-enablement: ${error}`);
  for (const violation of violations.values()) {
    console.error(
      `check-public-qa-enablement: ${violation.file}:${violation.line}: ${protectedFlag} occurrence is outside approved source and analyzer paths`,
    );
  }
  process.exitCode = 1;
} else {
  console.log("check-public-qa-enablement: no newly enabled public QA build flag");
}
