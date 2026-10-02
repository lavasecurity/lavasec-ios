import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { chmod, mkdir, mkdtemp, rm, symlink, writeFile } from "node:fs/promises";
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
  "ReactNative/native-app",
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

const conditionalConsumerPath = "ReactNative/ios/LavaSecUIReview/LavaReviewModule.mm";
const historicalReferencePath = "docs/design-revamp/2026-09-15-round8-shared-editors.md";
const exploreNarrationRoot = "docs/design-revamp/explore-narration-drafts";

function validReviewAudio(extension) {
  if (extension === ".mp3") {
    return Buffer.from([0x49, 0x44, 0x33, 4, 0, 0, 0, 0, 0, 0, 0xff, 0xfb, 0x90, 0x64]);
  }
  if (extension === ".caf") return Buffer.from([0x63, 0x61, 0x66, 0x66, 0, 1, 0, 0]);
  return Buffer.concat([Buffer.from("OggS"), Buffer.alloc(28), Buffer.from("OpusHead")]);
}
const historicalDocument = [
  "# Round 8 shared editors and native admission",
  "",
  "Command shape (complete local invocations are retained in the private receipt):",
  "`xcodebuild -workspace ReactNative/native-app/LavaSecRN.xcworkspace",
  "-scheme LavaSec -configuration QA -destination 'platform=iOS Simulator,id=<dedicated QA simulator>'",
  `'OTHER_SWIFT_FLAGS=$(inherited) -D ${protectedFlag}' build-for-testing\`, then \`xcodebuild test-without-building -xctestrun <frozen app lane>`,
  "-only-testing:LavaSecUITests/RNFullAppUITests/<selected test>` for the four named",
  "methods in the private receipt. Qualification remains scoped to that receipt.",
  "",
].join("\n");

test("allows only the registered ObjC standalone conditional consumer", async (t) => {
  const root = await makeRepository(t);
  const base = git(root, "rev-parse", "HEAD");
  await writeFixtureFile(root, conditionalConsumerPath, `#if ${protectedFlag}\nvoid diagnostic() {}\n#endif\n`);
  const head = commitAll(root, "add conditional consumer");
  const result = runChecker(root, base, head);
  assert.equal(result.status, 0, result.output);
});

test("rejects ObjC macro definitions, flag strings and broadened conditions even in the registered consumer", async (t) => {
  const root = await makeRepository(t);
  const base = git(root, "rev-parse", "HEAD");
  await writeFixtureFile(root, conditionalConsumerPath, [
    `#define ${protectedFlag} 1`,
    `#undef ${protectedFlag}`,
    `const char *flags = "-D${protectedFlag}";`,
    `#if ${protectedFlag} || 1`,
    "#endif",
  ].join("\n"));
  commitAll(root, "attempt local macro enablement");
  await writeFixtureFile(root, conditionalConsumerPath, "// removed\n");
  const head = commitAll(root, "remove attempted enablement");
  const result = runChecker(root, base, head);
  assert.equal(result.status, 1, result.output);
  for (const line of [1, 2, 3, 4]) assert.ok(result.output.includes(`${conditionalConsumerPath}:${line}:`), result.output);
});

test("allows the exact historical Markdown reference through unrelated prose edits and removal", async (t) => {
  const root = await makeRepository(t);
  const base = git(root, "rev-parse", "HEAD");
  await writeFixtureFile(root, historicalReferencePath, historicalDocument);
  commitAll(root, "record past local qualification");
  await writeFixtureFile(root, historicalReferencePath, `${historicalDocument}\nLater qualification update.\n`);
  commitAll(root, "append receipt update");
  await rm(path.join(root, historicalReferencePath));
  const head = commitAll(root, "remove public command reference");
  const result = runChecker(root, base, head);
  assert.equal(result.status, 0, result.output);
});

test("rejects retaining even the reviewed invocation at HEAD", async (t) => {
  const root = await makeRepository(t);
  const base = git(root, "rev-parse", "HEAD");
  await writeFixtureFile(root, historicalReferencePath, historicalDocument);
  commitAll(root, "retain reviewed historical invocation");
  // Exercise a symbolic head too; history hashes and aliases must be compared
  // as commit identities when enforcing the historical-only restriction.
  const result = runChecker(root, base, "HEAD");
  assert.equal(result.status, 1, result.output);
  assert.match(result.output, /historical only and must be absent at HEAD/);
});

for (const variation of ["different command", "additional occurrence", "missing context", "script header"]) {
  test(`rejects a historical receipt with ${variation}, even after removal`, async (t) => {
    const root = await makeRepository(t);
    const base = git(root, "rev-parse", "HEAD");
    const content = variation === "different command" ? historicalDocument.replace("build-for-testing", "archive")
      : variation === "additional occurrence" ? `${historicalDocument}\nOTHER_SWIFT_FLAGS=-D${protectedFlag}\n`
      : variation === "missing context" ? historicalDocument.replace("Command shape (complete local invocations are retained in the private receipt):", "Run this command:")
      : `#!/bin/sh\n${historicalDocument}`;
    await writeFixtureFile(root, historicalReferencePath, content);
    commitAll(root, "change reference into unreviewed content");
    await rm(path.join(root, historicalReferencePath));
    const head = commitAll(root, "remove unreviewed content");
    const result = runChecker(root, base, head);
    assert.equal(result.status, 1, result.output);
    assert.match(result.output, /differs from the reviewed historical QA reference/);
  });
}

test("rejects mode-only executable history even when the receipt starts in base and is removed at head", async (t) => {
  const root = await makeRepository(t);
  await writeFixtureFile(root, historicalReferencePath, historicalDocument);
  const base = commitAll(root, "reviewed reference baseline");
  await chmod(path.join(root, historicalReferencePath), 0o755);
  commitAll(root, "make historical receipt executable");
  await chmod(path.join(root, historicalReferencePath), 0o644);
  commitAll(root, "restore document mode");
  await rm(path.join(root, historicalReferencePath));
  const head = commitAll(root, "remove receipt");
  const result = runChecker(root, base, head);
  assert.equal(result.status, 1, result.output);
  assert.match(result.output, /must remain a regular non-executable file/);
});

test("rejects symlink history for the reviewed document path", async (t) => {
  const root = await makeRepository(t);
  await writeFixtureFile(root, historicalReferencePath, historicalDocument);
  const base = commitAll(root, "reviewed reference baseline");
  await rm(path.join(root, historicalReferencePath));
  await symlink("../../build.sh", path.join(root, historicalReferencePath));
  const head = commitAll(root, "replace document with symlink");
  const result = runChecker(root, base, head);
  assert.equal(result.status, 1, result.output);
  assert.match(result.output, /must remain a regular non-executable file/);
});

test("reference exceptions do not authorize neighbouring documentation, source or build files", async (t) => {
  const root = await makeRepository(t);
  const base = git(root, "rev-parse", "HEAD");
  for (const file of [
    "docs/design-revamp/another-receipt.md", "scripts/build.md",
    "ReactNative/ios/LavaSecUIReview/OtherModule.mm", "ReactNative/ios/LavaSecUIReview/Build.xcconfig",
  ]) await writeFixtureFile(root, file, file.endsWith(".md") ? historicalDocument : `#if ${protectedFlag}\n#endif\n`);
  const head = commitAll(root, "add reference lookalikes");
  const result = runChecker(root, base, head);
  assert.equal(result.status, 1, result.output);
  for (const name of ["another-receipt.md", "build.md", "OtherModule.mm", "Build.xcconfig"]) assert.ok(result.output.includes(name), result.output);
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

test("excludes only verified, regular, non-executable Explore narration audio", async (t) => {
  const root = await makeRepository(t);
  const base = git(root, "rev-parse", "HEAD");
  for (const extension of [".mp3", ".caf", ".opus"]) {
    await writeFixtureFile(root, `${exploreNarrationRoot}/verified${extension}`, validReviewAudio(extension));
  }
  const head = commitAll(root, "add verified narration media");
  const result = runChecker(root, base, head);
  assert.equal(result.status, 0, result.output);
});

test("validates narration audio paths with newlines, tabs, quotes, and Unicode", async (t) => {
  const root = await makeRepository(t);
  const base = git(root, "rev-parse", "HEAD");
  const cases = [
    ["evil\nname.caf", ".caf"],
    ["evil\tname.opus", ".opus"],
    ['evil"東京.mp3', ".mp3"],
  ];
  for (const [name, extension] of cases) {
    const audio = Buffer.concat([validReviewAudio(extension), Buffer.from(protectedFlag, "ascii")]);
    await writeFixtureFile(root, `${exploreNarrationRoot}/${name}`, audio);
  }
  const head = commitAll(root, "hide protected flag in oddly named narration audio");
  const result = runChecker(root, base, head);
  assert.equal(result.status, 1, result.output);
  assert.equal((result.output.match(/excluded narration audio contains the protected QA build flag/g) ?? []).length, cases.length, result.output);
});

test("rejects text files disguised as narration audio", async (t) => {
  const root = await makeRepository(t);
  const base = git(root, "rev-parse", "HEAD");
  await writeFixtureFile(root, `${exploreNarrationRoot}/build.mp3`, `#!/bin/sh\nswiftc -D${protectedFlag} Sources/Feature.swift\n`);
  const head = commitAll(root, "disguise QA script as narration media");
  const result = runChecker(root, base, head);
  assert.equal(result.status, 1, result.output);
  assert.match(result.output, /does not have a verified media header/);
});

test("rejects executable and symlink narration audio paths", async (t) => {
  for (const kind of ["executable", "symlink"]) {
    const root = await makeRepository(t);
    const base = git(root, "rev-parse", "HEAD");
    const file = path.join(root, exploreNarrationRoot, `${kind}.mp3`);
    await mkdir(path.dirname(file), {recursive: true});
    if (kind === "executable") {
      await writeFile(file, validReviewAudio(".mp3"));
      await chmod(file, 0o755);
    } else {
      await symlink("missing-target.mp3", file);
    }
    const head = commitAll(root, `add ${kind} narration audio path`);
    const result = runChecker(root, base, head);
    assert.equal(result.status, 1, result.output);
    assert.match(result.output, /must be a regular, non-executable file/);
    await rm(root, {recursive: true, force: true});
  }
});

test("RN native Swift sources do not authorize enabling QA in build scripts", async (t) => {
  const root = await makeRepository(t);
  const base = git(root, "rev-parse", "HEAD");
  for (const file of ["ReactNative/native-app/generate-project.rb", "ReactNative/native-app/Podfile", "ReactNative/scripts/build-full-app.sh"]) {
    await writeFixtureFile(root, file, `swiftc -D${protectedFlag} Sources/Feature.swift\n`);
  }
  const head = commitAll(root, "attempt RN build-script enablement");
  const result = runChecker(root, base, head);
  assert.notEqual(result.status, 0);
  assert.match(result.output, /native-app\/generate-project\.rb:1:/);
  assert.match(result.output, /native-app\/Podfile:1:/);
  assert.match(result.output, /scripts\/build-full-app\.sh:1:/);
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

// Only compiled archive paths are excluded; build settings in their directory remain scanned.
test("excludes compiled engine archives while scanning adjacent artifact inputs", async (t) => {
  const root = await makeRepository(t);
  const base = git(root, "rev-parse", "HEAD");

  // Compiled archive bytes cannot enable a Swift compiler condition.
  await writeFixtureFile(
    root,
    "ThirdParty/wireguard-core/build/LavaSecWGCore.xcframework/ios-arm64/liblavasec_wireguard_core.a",
    `${protectedFlag}=1\n`,
  );
  const excludedHead = commitAll(root, "artifact bytes");
  const excluded = runChecker(root, base, excludedHead);
  assert.equal(excluded.status, 0, excluded.output);

  // Adjacent configuration INSIDE the generated directory stays scanned.
  await writeFixtureFile(
    root,
    "ThirdParty/wireguard-core/build/LavaSecWGCore.xcframework/sneaky.xcconfig",
    `OTHER_SWIFT_FLAGS = -D ${protectedFlag}\n`,
  );
  const neighbourHead = commitAll(root, "neighbouring config");
  const neighbour = runChecker(root, excludedHead, neighbourHead);
  assert.notEqual(neighbour.status, 0, neighbour.output);
  assert.match(neighbour.output, /sneaky\.xcconfig/);
});

test("skips only review narration media while scanning its written copy", async (t) => {
  const root = await makeRepository(t);
  const base = git(root, "rev-parse", "HEAD");
  const syncsafe = (value) => Buffer.from([(value >> 21) & 0x7f, (value >> 14) & 0x7f, (value >> 7) & 0x7f, value & 0x7f]);
  const frameBody = Buffer.concat([Buffer.from([3]), Buffer.from("QA note\0review narration")]);
  const frame = Buffer.concat([Buffer.from("TXXX"), syncsafe(frameBody.length), Buffer.from([0, 0]), frameBody]);
  const tag = Buffer.concat([Buffer.from("ID3"), Buffer.from([4, 0, 0]), syncsafe(frame.length), frame]);
  const mp3 = Buffer.concat([tag, Buffer.from([0xff, 0xfb, 0x90, 0x64])]);

  await writeFixtureFile(
    root,
    "docs/design-revamp/explore-narration-drafts/all-locales/draft.mp3",
    mp3,
  );
  const mediaHead = commitAll(root, "add review-only narration media");
  const media = runChecker(root, base, mediaHead);
  assert.equal(media.status, 0, media.output);

  await writeFixtureFile(
    root,
    "docs/design-revamp/explore-narration-drafts/README.md",
    `Narration notes mention ${protectedFlag}.\n`,
  );
  const textHead = commitAll(root, "add flagged text beside narration");
  const text = runChecker(root, mediaHead, textHead);
  assert.notEqual(text.status, 0, text.output);
  assert.match(text.output, /explore-narration-drafts\/README\.md/);
});

test("scans every byte of verified narration media for the protected QA flag", async (t) => {
  for (const extension of [".mp3", ".caf", ".opus"]) {
    const root = await makeRepository(t);
    const base = git(root, "rev-parse", "HEAD");
    const file = `${exploreNarrationRoot}/payload${extension}`;
    const payload = Buffer.concat([validReviewAudio(extension), Buffer.from(`\n${protectedFlag}\n`, "ascii")]);
    await writeFixtureFile(root, file, payload);
    const head = commitAll(root, `append protected QA flag to ${extension} narration payload`);
    const result = runChecker(root, base, head);
    assert.equal(result.status, 1, result.output);
    assert.match(result.output, /contains the protected QA build flag/);
  }
});
