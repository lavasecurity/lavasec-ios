import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { mkdir, mkdtemp, rm, symlink, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const checkerPath = path.resolve(testDirectory, "..", "check-missing-docs-baseline.mjs");
const baselinePath = ".swiftlint-missing-docs-baseline.json";
const configPath = ".swiftlint-missing-docs.yml";
const includedRoots = [
  "Sources/LavaSecKit",
  "Sources/LavaSecNetworking",
  "Sources/LavaSecDNS",
  "Sources/LavaSecFilterPipeline",
  "Sources/LavaSecPresentation",
  "Sources/LavaSecAppServices",
];

async function makeRepository(t, baselineContents) {
  const root = await mkdtemp(path.join(os.tmpdir(), "lavasec-missing-docs-baseline-"));
  t.after(() => rm(root, { recursive: true, force: true }));
  git(root, "init", "-q");
  git(root, "config", "user.name", "Fixture");
  git(root, "config", "user.email", "fixture@example.com");
  await writeFixtureFile(root, "README.md", "fixture\n");
  await writeFixtureFile(root, configPath, missingDocsConfig());
  await writeFixtureFile(
    root,
    "Sources/LavaSecKit/Generated/DefaultCatalog+Generated.swift",
    "// Generated fixture intentionally excluded from the missing-doc ratchet.\n",
  );
  if (baselineContents !== undefined) {
    await writeFixtureFile(root, baselinePath, baselineContents);
  }
  return root;
}

function missingDocsConfig({
  included = includedRoots,
  excluded = ["Sources/LavaSecKit/Generated/DefaultCatalog+Generated.swift"],
} = {}) {
  return `included:\n${included.map((entry) => `  - ${entry}`).join("\n")}\nexcluded:\n${excluded.map((entry) => `  - ${entry}`).join("\n")}\n\nopt_in_rules:\n  - missing_docs\nmissing_docs:\n  warning: [open, public]\n  excludes_extensions: true\n  excludes_inherited_types: true\n  excludes_trivial_init: false\n  evaluate_effective_access_control_level: false\n`;
}

async function writeFixtureFile(root, relativePath, contents) {
  const absolutePath = path.join(root, relativePath);
  await mkdir(path.dirname(absolutePath), { recursive: true });
  await writeFile(absolutePath, contents);
}

function baselineFromFiles(files) {
  return `${JSON.stringify(files.map((file, index) => ({
    violation: {
      ruleIdentifier: "missing_docs",
      location: { file, line: index + 1, character: index + 2 },
      reason: "public declarations should be documented",
    },
    text: `public struct ${path.basename(file, ".swift")} {}`,
  })))}\n`;
}

function baseline(count) {
  return baselineFromFiles(
    Array.from({ length: count }, (_, index) => `Sources/Fixture${index}.swift`),
  );
}

function git(root, ...args) {
  return execFileSync("git", args, { cwd: root, encoding: "utf8" }).trim();
}

function commitAll(root, message) {
  git(root, "add", "-A");
  git(root, "commit", "-q", "-m", message);
  return git(root, "rev-parse", "HEAD");
}

function runChecker(root, args = []) {
  const result = spawnSync(process.execPath, [checkerPath, ...args], {
    cwd: root,
    encoding: "utf8",
  });
  return {
    ...result,
    output: `${result.stdout ?? ""}${result.stderr ?? ""}`,
  };
}

test("allows the initial baseline seed when the base revision has no baseline", async (t) => {
  const root = await makeRepository(t);
  const base = commitAll(root, "baseline without missing-doc debt file");
  await writeFixtureFile(root, baselinePath, baseline(2));
  const head = commitAll(root, "seed missing-doc baseline");

  const result = runChecker(root, ["--base", base, "--head", head]);

  assert.equal(result.status, 0, result.output);
  assert.match(result.output, /initial baseline seed accepted: 2 entries/);
});

test("allows equal and decreased baseline counts", async (t) => {
  const root = await makeRepository(t, baseline(2));
  const base = commitAll(root, "two baseline entries");
  await writeFixtureFile(root, "README.md", "equal count\n");
  const equalHead = commitAll(root, "leave baseline count unchanged");
  await writeFixtureFile(root, baselinePath, baseline(1));
  const decreasedHead = commitAll(root, "reduce missing-doc debt");

  const equalResult = runChecker(root, ["--base", base, "--head", equalHead]);
  const decreasedResult = runChecker(root, ["--base", base, "--head", decreasedHead]);

  assert.equal(equalResult.status, 0, equalResult.output);
  assert.match(equalResult.output, /baseline count did not increase: 2 -> 2/);
  assert.equal(decreasedResult.status, 0, decreasedResult.output);
  assert.match(decreasedResult.output, /baseline count did not increase: 2 -> 1/);
});

test("rejects replacing an existing baseline identity at equal count", async (t) => {
  const root = await makeRepository(
    t,
    baselineFromFiles(["Sources/ExistingA.swift", "Sources/ExistingB.swift"]),
  );
  const base = commitAll(root, "two existing baseline identities");
  await writeFixtureFile(
    root,
    baselinePath,
    baselineFromFiles(["Sources/ExistingB.swift", "Sources/NewDebt.swift"]),
  );
  const head = commitAll(root, "replace one baseline identity");

  const result = runChecker(root, ["--base", base, "--head", head]);

  assert.notEqual(result.status, 0);
  assert.match(result.output, /baseline contains 1 new missing-doc identity/);
  assert.match(result.output, /Sources\/NewDebt\.swift/);
});

test("rejects duplicate JSON keys before parser ordering can split identity", async (t) => {
  const root = await makeRepository(
    t,
    baselineFromFiles(["Sources/Existing.swift"]),
  );
  const base = commitAll(root, "baseline with one canonical identity");
  await writeFixtureFile(
    root,
    baselinePath,
    `[{
  "violation": {
    "ruleIdentifier": "missing_docs",
    "location": {
      "file": "Sources/NewDebt.swift",
      "\\u0066ile": "Sources/Existing.swift",
      "line": 1,
      "character": 2
    },
    "reason": "public declarations should be documented"
  },
  "text": "public struct Existing {}"
}]\n`,
  );
  const head = commitAll(root, "split baseline identity with a duplicate file key");

  const result = runChecker(root, ["--base", base, "--head", head]);

  assert.notEqual(result.status, 0);
  assert.match(result.output, /head baseline contains duplicate JSON object key file/);
});

test("rejects duplicate keys at every baseline identity nesting level", async (t) => {
  const canonicalLocation = `{
    "file": "Sources/Existing.swift",
    "line": 1,
    "character": 2
  }`;
  const canonicalViolation = `{
    "ruleIdentifier": "missing_docs",
    "location": ${canonicalLocation},
    "reason": "public declarations should be documented"
  }`;
  const cases = [
    [
      "text",
      `[{"violation": ${canonicalViolation}, "text": "new", "text": "public struct Existing {}"}]\n`,
    ],
    [
      "reason",
      `[{
        "violation": {
          "ruleIdentifier": "missing_docs",
          "location": ${canonicalLocation},
          "reason": "new",
          "reason": "public declarations should be documented"
        },
        "text": "public struct Existing {}"
      }]\n`,
    ],
    [
      "location",
      `[{
        "violation": {
          "ruleIdentifier": "missing_docs",
          "location": {"file": "Sources/NewDebt.swift"},
          "location": ${canonicalLocation},
          "reason": "public declarations should be documented"
        },
        "text": "public struct Existing {}"
      }]\n`,
    ],
    [
      "violation",
      `[{
        "violation": {"ruleIdentifier": "missing_docs"},
        "violation": ${canonicalViolation},
        "text": "public struct Existing {}"
      }]\n`,
    ],
  ];

  for (const [duplicateKey, headBaseline] of cases) {
    await t.test(duplicateKey, async (subtest) => {
      const root = await makeRepository(
        subtest,
        baselineFromFiles(["Sources/Existing.swift"]),
      );
      const base = commitAll(root, "baseline with canonical JSON keys");
      await writeFixtureFile(root, baselinePath, headBaseline);
      const head = commitAll(root, `duplicate ${duplicateKey} baseline key`);

      const result = runChecker(root, ["--base", base, "--head", head]);

      assert.notEqual(result.status, 0);
      assert.match(
        result.output,
        new RegExp(`head baseline contains duplicate JSON object key ${duplicateKey}`),
      );
    });
  }
});

test("rejects a symlinked baseline that Git and SwiftLint read differently", async (t) => {
  const root = await makeRepository(t, baseline(1));
  const base = commitAll(root, "regular missing-doc policy files");
  await writeFixtureFile(root, "[]", baseline(2));
  await rm(path.join(root, baselinePath), { force: true });
  await symlink("[]", path.join(root, baselinePath));
  await writeFixtureFile(
    root,
    "Sources/LavaSecKit/SymlinkBaselineUndocumented.swift",
    "public struct SymlinkBaselineUndocumented {}\n",
  );
  const head = commitAll(root, "split Git and SwiftLint baseline views");

  const result = runChecker(root, ["--base", base, "--head", head]);
  const noRangeResult = runChecker(root);

  assert.notEqual(result.status, 0);
  assert.match(
    result.output,
    /head missing-doc policy file is not a regular 100644 blob \.swiftlint-missing-docs-baseline\.json \(120000 blob\)/,
  );
  assert.notEqual(noRangeResult.status, 0);
  assert.match(
    noRangeResult.output,
    /head missing-doc policy file is not a regular 100644 blob \.swiftlint-missing-docs-baseline\.json \(120000 blob\)/,
  );
});

test("rejects a symlinked missing-doc configuration before following it", async (t) => {
  const root = await makeRepository(t, baseline(1));
  const base = commitAll(root, "regular missing-doc configuration");
  await writeFixtureFile(root, "Policy.yml", missingDocsConfig());
  await rm(path.join(root, configPath), { force: true });
  await symlink("Policy.yml", path.join(root, configPath));
  const head = commitAll(root, "replace missing-doc configuration with a symlink");

  const result = runChecker(root, ["--base", base, "--head", head]);

  assert.notEqual(result.status, 0);
  assert.match(
    result.output,
    /head missing-doc policy file is not a regular 100644 blob \.swiftlint-missing-docs\.yml \(120000 blob\)/,
  );
});

test("rejects broadening the missing-doc exclusion scope", async (t) => {
  const root = await makeRepository(t, baseline(1));
  const base = commitAll(root, "approved missing-doc scope");
  await writeFixtureFile(root, configPath, missingDocsConfig({
    excluded: [
      "Sources/LavaSecKit/Generated/DefaultCatalog+Generated.swift",
      "Sources/LavaSecDNS",
    ],
  }));
  const head = commitAll(root, "exclude an additional source layer");

  const result = runChecker(root, ["--base", base, "--head", head]);

  assert.notEqual(result.status, 0);
  assert.match(
    result.output,
    /head missing-doc excluded scope contains unapproved paths: Sources\/LavaSecDNS/,
  );
});

test("rejects replacing the approved excluded file with a directory", async (t) => {
  const root = await makeRepository(t, baseline(1));
  const base = commitAll(root, "approved exclusion is a regular generated file");
  await rm(
    path.join(root, "Sources/LavaSecKit/Generated/DefaultCatalog+Generated.swift"),
    { force: true },
  );
  await writeFixtureFile(
    root,
    "Sources/LavaSecKit/Generated/DefaultCatalog+Generated.swift/Injected.swift",
    "public struct InjectedUndocumented {}\n",
  );
  const head = commitAll(root, "replace the excluded file with a directory");

  const result = runChecker(root, ["--base", base, "--head", head]);

  assert.notEqual(result.status, 0);
  assert.match(
    result.output,
    /head missing-doc exclusion path contains tracked descendant Sources\/LavaSecKit\/Generated\/DefaultCatalog\+Generated\.swift\/Injected\.swift/,
  );
});

test("rejects weakening the effective missing-doc rule options", async (t) => {
  const root = await makeRepository(t, baseline(1));
  const base = commitAll(root, "approved missing-doc rule options");
  await writeFixtureFile(
    root,
    configPath,
    missingDocsConfig().replace("warning: [open, public]", "warning: [open]"),
  );
  const head = commitAll(root, "stop warning on undocumented public declarations");

  const result = runChecker(root, ["--base", base, "--head", head]);

  assert.notEqual(result.status, 0);
  assert.match(result.output, /head missing-doc rule options differ from policy/);
});

test("rejects SwiftLint config composition that can override the rule policy", async (t) => {
  const root = await makeRepository(t, baseline(1));
  const base = commitAll(root, "standalone missing-doc config");
  await writeFixtureFile(
    root,
    configPath,
    `child_config: weak.yml\n${missingDocsConfig()}`,
  );
  await writeFixtureFile(
    root,
    "weak.yml",
    "missing_docs:\n  warning: [open]\n",
  );
  const head = commitAll(root, "compose a weaker missing-doc rule");

  const result = runChecker(root, ["--base", base, "--head", head]);

  assert.notEqual(result.status, 0);
  assert.match(
    result.output,
    /head missing-doc config contains unsupported top-level key child_config/,
  );
});

test("rejects a byte-order mark that can hide config composition", async (t) => {
  const root = await makeRepository(t, baseline(1));
  const base = commitAll(root, "missing-doc config without a byte-order mark");
  await writeFixtureFile(
    root,
    configPath,
    `\uFEFFchild_config: weak.yml\n${missingDocsConfig()}`,
  );
  await writeFixtureFile(
    root,
    "weak.yml",
    "missing_docs:\n  warning: [open]\n",
  );
  const head = commitAll(root, "hide config composition behind a byte-order mark");

  const result = runChecker(root, ["--base", base, "--head", head]);

  assert.notEqual(result.status, 0);
  assert.match(
    result.output,
    /head missing-doc config contains an unsupported byte-order mark/,
  );
});

test("rejects YAML line separators that can hide config composition", async (t) => {
  const root = await makeRepository(t, baseline(1));
  const base = commitAll(root, "canonical YAML line separators");
  await writeFixtureFile(
    root,
    configPath,
    `${missingDocsConfig()}# hidden\u0085child_config: weak.yml\n`,
  );
  await writeFixtureFile(
    root,
    "weak.yml",
    "missing_docs:\n  warning: [open]\n",
  );
  const head = commitAll(root, "hide config composition behind YAML NEL");

  const result = runChecker(root, ["--base", base, "--head", head]);

  assert.notEqual(result.status, 0);
  assert.match(
    result.output,
    /head missing-doc config contains an unsupported line separator/,
  );
});

test("rejects newly added source directives that suppress missing-doc findings", async (t) => {
  const root = await makeRepository(t, baseline(1));
  const base = commitAll(root, "no missing-doc suppression directives");
  await writeFixtureFile(
    root,
    "Sources/LavaSecKit/InjectedUndocumented.swift",
    "// swiftlint:disable:next missing_docs\npublic struct InjectedUndocumented {}\n",
  );
  const head = commitAll(root, "suppress missing docs on a new public declaration");

  const result = runChecker(root, ["--base", base, "--head", head]);

  assert.notEqual(result.status, 0);
  assert.match(
    result.output,
    /head introduces missing-doc suppression in Sources\/LavaSecKit\/InjectedUndocumented\.swift:1/,
  );
});

test("rejects missing-doc directives hidden behind a comment prefix", async (t) => {
  const root = await makeRepository(t, baseline(1));
  const base = commitAll(root, "no prefixed suppression directives");
  await writeFixtureFile(
    root,
    "Sources/LavaSecKit/InjectedUndocumented.swift",
    "// # swiftlint:disable:next missing_docs\npublic struct InjectedUndocumented {}\n",
  );
  const head = commitAll(root, "prefix an active SwiftLint command");

  const result = runChecker(root, ["--base", base, "--head", head]);

  assert.notEqual(result.status, 0);
  assert.match(
    result.output,
    /head introduces missing-doc suppression in Sources\/LavaSecKit\/InjectedUndocumented\.swift:1/,
  );
});

test("rejects suppression directives hidden by a Swift line separator", async (t) => {
  const root = await makeRepository(t, baseline(1));
  const base = commitAll(root, "ordinary Swift line separators");
  await writeFixtureFile(
    root,
    "Sources/LavaSecKit/InjectedUndocumented.swift",
    "// swiftlint:disable:next\u2028public struct InjectedUndocumented {}\n",
  );
  const head = commitAll(root, "hide a suppression before a Swift line separator");

  const result = runChecker(root, ["--base", base, "--head", head]);

  assert.notEqual(result.status, 0);
  assert.match(
    result.output,
    /head introduces missing-doc suppression in Sources\/LavaSecKit\/InjectedUndocumented\.swift:1/,
  );
});

test("rejects tracked symlinks under the protected missing-doc roots", async (t) => {
  const root = await makeRepository(t, baseline(1));
  const base = commitAll(root, "regular protected source tree");
  await writeFixtureFile(
    root,
    "Payloads/SymlinkedUndocumented.swift",
    "// swiftlint:disable:next missing_docs\npublic struct SymlinkedUndocumented {}\n",
  );
  await mkdir(path.join(root, "Sources", "LavaSecKit"), { recursive: true });
  await symlink(
    "../../Payloads/SymlinkedUndocumented.swift",
    path.join(root, "Sources", "LavaSecKit", "SymlinkedUndocumented.swift"),
  );
  const head = commitAll(root, "link protected source to suppressed payload");

  const result = runChecker(root, ["--base", base, "--head", head]);

  assert.notEqual(result.status, 0);
  assert.match(
    result.output,
    /head protected missing-doc scope contains non-regular entry Sources\/LavaSecKit\/SymlinkedUndocumented\.swift \(120000 blob\)/,
  );
});

test("rejects a tracked symlink that is an ancestor of a protected root", async (t) => {
  const root = await makeRepository(t, baseline(1));
  const base = commitAll(root, "regular repository root");
  await writeFixtureFile(
    root,
    "Payloads/LavaSecKit/AncestorSymlinkedUndocumented.swift",
    "// swiftlint:disable:next missing_docs\npublic struct AncestorSymlinkedUndocumented {}\n",
  );
  await rm(path.join(root, "Sources"), { recursive: true, force: true });
  await symlink("Payloads", path.join(root, "Sources"));
  const head = commitAll(root, "link an ancestor of protected source scope");

  const result = runChecker(root, ["--base", base, "--head", head]);
  const noRangeResult = runChecker(root);

  assert.notEqual(result.status, 0);
  assert.match(
    result.output,
    /head protected missing-doc scope contains non-regular entry Sources \(120000 blob\)/,
  );
  assert.notEqual(noRangeResult.status, 0);
  assert.match(
    noRangeResult.output,
    /head protected missing-doc scope contains non-regular entry Sources \(120000 blob\)/,
  );
});

test("rejects an existing suppression when no comparison range is provided", async (t) => {
  const root = await makeRepository(t, baseline(1));
  await writeFixtureFile(
    root,
    "Sources/LavaSecKit/ExistingSuppression.swift",
    "// swiftlint:disable:next missing_docs\npublic struct ExistingSuppression {}\n",
  );
  commitAll(root, "commit a suppression before a no-range check");

  const result = runChecker(root);

  assert.notEqual(result.status, 0);
  assert.match(
    result.output,
    /working tree contains missing-doc suppression in Sources\/LavaSecKit\/ExistingSuppression\.swift/,
  );
});

test("no-range mode scans uncommitted working-tree source changes", async (t) => {
  const root = await makeRepository(t, baseline(1));
  await writeFixtureFile(
    root,
    "Sources/LavaSecKit/Tracked.swift",
    "public struct Tracked {}\n",
  );
  commitAll(root, "tracked protected source without suppressions");
  await writeFixtureFile(
    root,
    "Sources/LavaSecKit/Tracked.swift",
    "// swiftlint:disable:next missing_docs\npublic struct Tracked {}\n",
  );

  const result = runChecker(root);

  assert.notEqual(result.status, 0);
  assert.match(
    result.output,
    /working tree contains missing-doc suppression in Sources\/LavaSecKit\/Tracked\.swift/,
  );
});

test("rejects suppression directives renamed into a protected root", async (t) => {
  const root = await makeRepository(t, baseline(1));
  await writeFixtureFile(
    root,
    "Payloads/RenamedUndocumented.swift",
    "// swiftlint:disable:next missing_docs\npublic struct RenamedUndocumented {}\n",
  );
  const base = commitAll(root, "suppressed fixture outside protected roots");
  await mkdir(path.join(root, "Sources", "LavaSecKit"), { recursive: true });
  git(
    root,
    "mv",
    "Payloads/RenamedUndocumented.swift",
    "Sources/LavaSecKit/RenamedUndocumented.swift",
  );
  const head = commitAll(root, "rename suppressed source into protected scope");

  const result = runChecker(root, ["--base", base, "--head", head]);

  assert.notEqual(result.status, 0);
  assert.match(
    result.output,
    /head introduces missing-doc suppression in Sources\/LavaSecKit\/RenamedUndocumented\.swift:1/,
  );
});

test("rejects a new identity even when the total baseline count decreases", async (t) => {
  const root = await makeRepository(
    t,
    baselineFromFiles([
      "Sources/ExistingA.swift",
      "Sources/ExistingB.swift",
      "Sources/ExistingC.swift",
    ]),
  );
  const base = commitAll(root, "three existing baseline identities");
  await writeFixtureFile(
    root,
    baselinePath,
    baselineFromFiles(["Sources/ExistingA.swift", "Sources/NewDebt.swift"]),
  );
  const head = commitAll(root, "shrink count while introducing new debt");

  const result = runChecker(root, ["--base", base, "--head", head]);

  assert.notEqual(result.status, 0);
  assert.match(result.output, /baseline contains 1 new missing-doc identity/);
  assert.match(result.output, /Sources\/NewDebt\.swift/);
});

test("allows identity reordering and source-location shifts", async (t) => {
  const original = baselineFromFiles(["Sources/ExistingA.swift", "Sources/ExistingB.swift"]);
  const root = await makeRepository(t, original);
  const base = commitAll(root, "two baseline identities");
  const shifted = JSON.parse(original).reverse();
  shifted[0].violation.location.line = 500;
  shifted[0].violation.location.character = 40;
  shifted[1].violation.location.line = 700;
  shifted[1].violation.location.character = 12;
  await writeFixtureFile(root, baselinePath, `${JSON.stringify(shifted)}\n`);
  const head = commitAll(root, "move declarations without changing identity");

  const result = runChecker(root, ["--base", base, "--head", head]);

  assert.equal(result.status, 0, result.output);
  assert.match(result.output, /baseline count did not increase: 2 -> 2/);
});

test("treats duplicate baseline identities as a multiset", async (t) => {
  const root = await makeRepository(
    t,
    baselineFromFiles(["Sources/ExistingA.swift", "Sources/ExistingB.swift"]),
  );
  const base = commitAll(root, "two distinct baseline identities");
  await writeFixtureFile(
    root,
    baselinePath,
    baselineFromFiles(["Sources/ExistingA.swift", "Sources/ExistingA.swift"]),
  );
  const head = commitAll(root, "duplicate one identity in place of another");

  const result = runChecker(root, ["--base", base, "--head", head]);

  assert.notEqual(result.status, 0);
  assert.match(result.output, /baseline contains 1 new missing-doc identity/);
  assert.match(result.output, /Sources\/ExistingA\.swift/);
});

test("rejects an increased baseline count", async (t) => {
  const root = await makeRepository(t, baseline(1));
  const base = commitAll(root, "one baseline entry");
  await writeFixtureFile(root, baselinePath, baseline(2));
  const head = commitAll(root, "grow missing-doc debt");

  const result = runChecker(root, ["--base", base, "--head", head]);

  assert.notEqual(result.status, 0);
  assert.match(result.output, /baseline grew: 1 -> 2/);
});

test("rejects malformed baseline JSON in the base revision", async (t) => {
  const root = await makeRepository(t, "{\n");
  const base = commitAll(root, "malformed base baseline");
  await writeFixtureFile(root, baselinePath, baseline(1));
  const head = commitAll(root, "valid head baseline");

  const result = runChecker(root, ["--base", base, "--head", head]);

  assert.notEqual(result.status, 0);
  assert.match(result.output, /base baseline is not valid JSON/);
});

test("rejects a non-array baseline in the head revision", async (t) => {
  const root = await makeRepository(t, baseline(1));
  const base = commitAll(root, "valid base baseline");
  await writeFixtureFile(root, baselinePath, "{}\n");
  const head = commitAll(root, "non-array head baseline");

  const result = runChecker(root, ["--base", base, "--head", head]);

  assert.notEqual(result.status, 0);
  assert.match(result.output, /head baseline must be a JSON array/);
});

test("rejects array entries that are not missing-doc violations", async (t) => {
  const root = await makeRepository(t, baseline(1));
  const base = commitAll(root, "valid base baseline");
  await writeFixtureFile(root, baselinePath, "[{}]\n");
  const head = commitAll(root, "malformed baseline entry");

  const result = runChecker(root, ["--base", base, "--head", head]);

  assert.notEqual(result.status, 0);
  assert.match(result.output, /head baseline entry 1 must be a missing_docs violation/);
});

test("validate-only mode accepts a valid baseline and rejects malformed content", async (t) => {
  const root = await makeRepository(t, baseline(1));
  commitAll(root, "valid working tree baseline");

  const validResult = runChecker(root);
  assert.equal(validResult.status, 0, validResult.output);
  assert.match(validResult.output, /working-tree baseline is valid: 1 entry/);

  await writeFixtureFile(root, baselinePath, "[\n");
  const malformedResult = runChecker(root);
  assert.notEqual(malformedResult.status, 0);
  assert.match(malformedResult.output, /working-tree baseline is not valid JSON/);
});
