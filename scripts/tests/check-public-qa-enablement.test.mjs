import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const checkerPath = path.resolve(testDirectory, "..", "check-public-qa-enablement.mjs");
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

async function makeRepository(t) {
  const root = await mkdtemp(path.join(os.tmpdir(), "lavasec-public-qa-enablement-"));
  t.after(() => rm(root, { recursive: true, force: true }));
  git(root, "init", "-q");
  git(root, "config", "user.name", "Fixture");
  git(root, "config", "user.email", "fixture@example.com");
  await writeFixtureFile(root, "README.md", "fixture\n");
  commitAll(root, "baseline");
  return root;
}

async function writeFixtureFile(root, relativePath, contents) {
  const absolutePath = path.join(root, relativePath);
  await mkdir(path.dirname(absolutePath), { recursive: true });
  await writeFile(absolutePath, contents);
}

function git(root, ...args) {
  return execFileSync("git", args, { cwd: root, encoding: "utf8" }).trim();
}

function commitAll(root, message) {
  git(root, "add", "-A");
  git(root, "commit", "-q", "-m", message);
  return git(root, "rev-parse", "HEAD");
}

function runChecker(root, base, head) {
  const result = spawnSync(
    process.execPath,
    [checkerPath, "--base", base, "--head", head],
    { cwd: root, encoding: "utf8", maxBuffer: 4 * 1024 * 1024 },
  );
  return {
    ...result,
    output: `${result.stdout ?? ""}${result.stderr ?? ""}`,
  };
}

test("allows Swift condition directives and source-test strings that pin them", async (t) => {
  const root = await makeRepository(t);
  const base = git(root, "rev-parse", "HEAD");
  await writeFixtureFile(
    root,
    "Sources/Feature.swift",
    `#if DEBUG || ${protectedFlag}
func internalDiagnostics() {}
#elseif ${protectedFlag}
func alternateDiagnostics() {}
#endif
`,
  );
  await writeFixtureFile(
    root,
    "Tests/FeatureSourceTests.swift",
    `let boundary = "#if DEBUG || ${protectedFlag}"
let alternative = "#elseif ${protectedFlag}"
`,
  );
  const head = commitAll(root, "add guarded source");

  const result = runChecker(root, base, head);

  assert.equal(result.status, 0, result.output);
  assert.match(result.output, /no newly enabled public QA build flag/);
});

test("allows protected-flag occurrences in every approved Swift source root regardless of lexical context", async (t) => {
  const root = await makeRepository(t);
  const base = git(root, "rev-parse", "HEAD");
  for (const allowedRoot of allowedSwiftRoots) {
    await writeFixtureFile(
      root,
      `${allowedRoot}/Reference.swift`,
      `let protectedFlagReference = "${protectedFlag}"\n`,
    );
  }
  await writeFixtureFile(
    root,
    "Sources/LexicalContexts.swift",
    `let sourceExcerpt = """
#if ${protectedFlag}
"""
// ${protectedFlag}
`,
  );
  const head = commitAll(root, "add ordinary Swift flag references");

  const result = runChecker(root, base, head);

  assert.equal(result.status, 0, result.output);
});

test("rejects public workflow enablement, including a newly added internal-only path", async (t) => {
  const root = await makeRepository(t);
  const base = git(root, "rev-parse", "HEAD");
  for (const relativePath of [
    ".github/workflows/build.yml",
    ".github/workflows/light-build.yml",
  ]) {
    await writeFixtureFile(
      root,
      relativePath,
      `steps:\n  - run: swiftc -D '${protectedFlag}' Sources/Feature.swift\n`,
    );
  }
  const head = commitAll(root, "add workflow-only build command");

  const result = runChecker(root, base, head);

  assert.notEqual(result.status, 0);
  assert.match(result.output, /\.github\/workflows\/build\.yml:2:/);
  assert.match(result.output, /\.github\/workflows\/light-build\.yml:2:/);
});

test("allows the internal-only workflow when it already exists in the base tree", async (t) => {
  const root = await makeRepository(t);
  await writeFixtureFile(root, ".github/workflows/light-build.yml", "steps: []\n");
  const base = commitAll(root, "add internal-only workflow baseline");
  await writeFixtureFile(
    root,
    ".github/workflows/light-build.yml",
    `steps:\n  - run: swiftc -D '${protectedFlag}' Sources/Feature.swift\n`,
  );
  const head = commitAll(root, "exercise internal QA configuration");

  const result = runChecker(root, base, head);

  assert.equal(result.status, 0, result.output);
});

test("allows protected-flag references in guard analyzers and test fixtures", async (t) => {
  const root = await makeRepository(t);
  const base = git(root, "rev-parse", "HEAD");
  for (const relativePath of [
    "scripts/check-public-qa-enablement.mjs",
    "scripts/check-string-coverage.mjs",
    "scripts/tests/guard-fixture.test.mjs",
  ]) {
    await writeFixtureFile(
      root,
      relativePath,
      `const protectedFlagFixture = "${protectedFlag}";\n`,
    );
  }
  const head = commitAll(root, "add guard fixture references");

  const result = runChecker(root, base, head);

  assert.equal(result.status, 0, result.output);
});

test("rejects protected-flag references outside flat Node test fixtures", async (t) => {
  const root = await makeRepository(t);
  const base = git(root, "rev-parse", "HEAD");
  for (const relativePath of [
    "scripts/tests/build.sh",
    "scripts/tests/helper.mjs",
    "scripts/tests/nested/guard.test.mjs",
  ]) {
    await writeFixtureFile(
      root,
      relativePath,
      `const protectedFlagFixture = "${protectedFlag}";\n`,
    );
  }
  const head = commitAll(root, "add executable and nested guard lookalikes");

  const result = runChecker(root, base, head);

  assert.notEqual(result.status, 0);
  assert.match(result.output, /scripts\/tests\/build\.sh:1:/);
  assert.match(result.output, /scripts\/tests\/helper\.mjs:1:/);
  assert.match(result.output, /scripts\/tests\/nested\/guard\.test\.mjs:1:/);
});

test("handles a promotion patch larger than the child-process default buffer", async (t) => {
  const root = await makeRepository(t);
  const base = git(root, "rev-parse", "HEAD");
  await writeFixtureFile(
    root,
    "Sources/LargeFeature.swift",
    `${"let value = 0\n".repeat(90_000)}#if DEBUG || ${protectedFlag}\n#endif\n`,
  );
  const head = commitAll(root, "add a large guarded source file");

  const result = runChecker(root, base, head);

  assert.equal(result.status, 0, result.error?.message ?? result.output.slice(-1_000));
});

test("does not treat header-looking added content inside a hunk as diff metadata", async (t) => {
  const root = await makeRepository(t);
  const base = git(root, "rev-parse", "HEAD");
  await writeFixtureFile(
    root,
    "scripts/build.sh",
    `cat <<'EOF'
++ b/LavaSecApp/Decoy.swift
EOF
swiftc -D${protectedFlag} Sources/Feature.swift
`,
  );
  const head = commitAll(root, "hide QA enablement behind header-looking content");

  const result = runChecker(root, base, head);

  assert.notEqual(result.status, 0);
  assert.match(result.output, /scripts\/build\.sh:4:/);
});

test("rejects a CRLF-carried header spoof before a QA enablement", async (t) => {
  const root = await makeRepository(t);
  const base = git(root, "rev-parse", "HEAD");
  await writeFixtureFile(
    root,
    "scripts/build.sh",
    [
      "cat <<'EOF'",
      "++ b/LavaSecApp/Decoy.swift",
      "EOF",
      `swiftc -D${protectedFlag} Sources/Feature.swift`,
      "",
    ].join("\r\n"),
  );
  const head = commitAll(root, "hide QA enablement behind CRLF header-looking content");

  const result = runChecker(root, base, head);

  assert.notEqual(result.status, 0);
  assert.match(result.output, /scripts\/build\.sh:4:/);
});

test("counts added content beginning with plus signs when reporting later lines", async (t) => {
  const root = await makeRepository(t);
  const base = git(root, "rev-parse", "HEAD");
  await writeFixtureFile(
    root,
    "scripts/build.sh",
    `cat <<'EOF'
+++not-a-header
EOF
swiftc -D${protectedFlag} Sources/Feature.swift
`,
  );
  const head = commitAll(root, "add plus-prefixed fixture content");

  const result = runChecker(root, base, head);

  assert.notEqual(result.status, 0);
  assert.match(result.output, /scripts\/build\.sh:4:/);
});

test("ignores diff-suppressing attributes and still rejects workflow enablement", async (t) => {
  const root = await makeRepository(t);
  const base = git(root, "rev-parse", "HEAD");
  await writeFixtureFile(
    root,
    ".gitattributes",
    ".github/workflows/*.yml -diff\n",
  );
  await writeFixtureFile(
    root,
    ".github/workflows/build.yml",
    `steps:\n  - run: swiftc -D${protectedFlag} Sources/Feature.swift\n`,
  );
  const head = commitAll(root, "hide QA workflow behind a binary diff attribute");

  const result = runChecker(root, base, head);

  assert.notEqual(result.status, 0);
  assert.match(result.output, /\.github\/workflows\/build\.yml:2:/);
});

test("rejects executable mjs and Python invocations", async (t) => {
  const root = await makeRepository(t);
  const base = git(root, "rev-parse", "HEAD");
  await writeFixtureFile(
    root,
    "scripts/build.mjs",
    `import { spawnSync } from "node:child_process";
spawnSync("swiftc", ["-D", "${protectedFlag}", "Sources/Feature.swift"]);
`,
  );
  await writeFixtureFile(
    root,
    "scripts/build.py",
    `import subprocess
subprocess.run(["swiftc", "-D", "${protectedFlag}", "Sources/Feature.swift"], check=True)
`,
  );
  const head = commitAll(root, "enable QA build flag from executable scripts");

  const result = runChecker(root, base, head);

  assert.notEqual(result.status, 0);
  assert.match(result.output, /scripts\/build\.mjs:2:/);
  assert.match(result.output, /scripts\/build\.py:2:/);
});

test("rejects multiline SwiftPM unsafeFlags and define enablement", async (t) => {
  const root = await makeRepository(t);
  const base = git(root, "rev-parse", "HEAD");
  await writeFixtureFile(
    root,
    "Package.swift",
    `let settings: [SwiftSetting] = [
  .unsafeFlags([
    "-D",
    "${protectedFlag}",
  ]),
  .define(
    "${protectedFlag}"
  ),
]
`,
  );
  const head = commitAll(root, "enable QA build flag from SwiftPM");

  const result = runChecker(root, base, head);

  assert.notEqual(result.status, 0);
  assert.match(result.output, /Package\.swift:4:/);
  assert.match(result.output, /Package\.swift:7:/);
});

test("rejects a valid Package.swift multiline-string bypass into define", async (t) => {
  const root = await makeRepository(t);
  const base = git(root, "rev-parse", "HEAD");
  await writeFixtureFile(
    root,
    "Package.swift",
    `// swift-tools-version: 6.0
import PackageDescription

let directive = """
#if ${protectedFlag}
"""
let token = String(directive.split(separator: " ").last!)
let package = Package(
  name: "Fixture",
  targets: [
    .target(name: "Feature", swiftSettings: [.define(token)]),
  ]
)
`,
  );
  const head = commitAll(root, "enable QA flag through a multiline manifest string");

  const result = runChecker(root, base, head);

  assert.notEqual(result.status, 0);
  assert.match(result.output, /Package\.swift:5:/);
});

test("rejects protected-flag occurrences in Swift files outside approved roots", async (t) => {
  const root = await makeRepository(t);
  const base = git(root, "rev-parse", "HEAD");
  for (const relativePath of [
    "Plugins/BuildPlugin.swift",
    "scripts/Build.swift",
    "Unknown/Feature.swift",
  ]) {
    await writeFixtureFile(
      root,
      relativePath,
      `#if ${protectedFlag}\n#endif\n`,
    );
  }
  const head = commitAll(root, "add Swift flag references outside source roots");

  const result = runChecker(root, base, head);

  assert.notEqual(result.status, 0);
  assert.match(result.output, /Plugins\/BuildPlugin\.swift:1:/);
  assert.match(result.output, /scripts\/Build\.swift:1:/);
  assert.match(result.output, /Unknown\/Feature\.swift:1:/);
});

test("rejects enablement added and removed inside the commit range", async (t) => {
  const root = await makeRepository(t);
  const base = git(root, "rev-parse", "HEAD");
  await writeFixtureFile(
    root,
    "scripts/build.sh",
    `swiftc -D${protectedFlag} Sources/Feature.swift\n`,
  );
  commitAll(root, "temporarily enable QA build flag");
  await rm(path.join(root, "scripts/build.sh"));
  const head = commitAll(root, "remove temporary flag");

  const result = runChecker(root, base, head);

  assert.notEqual(result.status, 0);
  assert.match(result.output, /scripts\/build\.sh:1:/);
});

test("rejects merge-resolution enablement removed later in the commit range", async (t) => {
  const root = await makeRepository(t);
  const base = git(root, "rev-parse", "HEAD");
  const targetBranch = git(root, "branch", "--show-current");

  git(root, "switch", "-q", "-c", "feature");
  await writeFixtureFile(root, "scripts/build.sh", "swiftc Sources/Feature.swift\n");
  commitAll(root, "add feature build command");

  git(root, "switch", "-q", targetBranch);
  await writeFixtureFile(root, "scripts/build.sh", "swiftc Sources/Main.swift\n");
  commitAll(root, "add main build command");

  const mergeResult = spawnSync(
    "git",
    ["merge", "--no-ff", "feature", "-m", "merge feature build command"],
    { cwd: root, encoding: "utf8" },
  );
  const mergeOutput = `${mergeResult.stdout ?? ""}${mergeResult.stderr ?? ""}`;
  assert.equal(mergeResult.status, 1, mergeOutput);
  assert.match(mergeOutput, /CONFLICT \(add\/add\)/);

  await writeFixtureFile(
    root,
    "scripts/build.sh",
    `swiftc -D${protectedFlag} Sources/Feature.swift\n`,
  );
  const mergeCommit = commitAll(root, "resolve build command conflict");
  assert.equal(
    git(root, "rev-list", "--parents", "-n", "1", mergeCommit).split(/\s+/).length,
    3,
  );

  await rm(path.join(root, "scripts/build.sh"));
  const head = commitAll(root, "remove resolved build command");

  const result = runChecker(root, base, head);

  assert.notEqual(result.status, 0);
  assert.match(result.output, /scripts\/build\.sh:1:/);
});
