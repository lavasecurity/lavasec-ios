import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const checkerPath = path.resolve(testDirectory, "..", "check-comment-contracts.mjs");

async function makeFixture(t, files) {
  const root = await mkdtemp(path.join(os.tmpdir(), "lavasec-comment-contracts-"));
  t.after(() => rm(root, { recursive: true, force: true }));

  for (const [relativePath, contents] of Object.entries(files)) {
    const absolutePath = path.join(root, relativePath);
    await mkdir(path.dirname(absolutePath), { recursive: true });
    await writeFile(absolutePath, contents);
  }

  return root;
}

function runChecker(root, args = []) {
  const result = spawnSync(process.execPath, [checkerPath, ...args], {
    cwd: root,
    encoding: "utf8",
    maxBuffer: 8 * 1024 * 1024,
  });
  return {
    ...result,
    output: `${result.stdout ?? ""}${result.stderr ?? ""}`,
  };
}

function git(root, ...args) {
  return execFileSync("git", args, { cwd: root, encoding: "utf8" }).trim();
}

async function writeFixtureFile(root, relativePath, contents) {
  const absolutePath = path.join(root, relativePath);
  await mkdir(path.dirname(absolutePath), { recursive: true });
  await writeFile(absolutePath, contents);
}

const registry = `# Invariants

### INV-DNS-1 — Never fail open
`;

const testCase = `import XCTest

final class CompactFilterSnapshotTests: XCTestCase {
    func testCanServeAsLastKnownGoodToleratesRotatedCatalogHashButNotConfigChange() {}
}
`;

test("rejects newly added review shorthand, deferred work, unknown invariants, and stale pins", async (t) => {
  const root = await makeFixture(t, {
    "docs/invariants.md": registry,
    "project.yml": "targets: {}\n",
    "Tests/LavaSecCoreTests/CompactFilterSnapshotTests.swift": testCase,
  });
  git(root, "init", "-q");
  git(root, "config", "user.name", "Fixture");
  git(root, "config", "user.email", "fixture@example.com");
  git(root, "add", ".");
  git(root, "commit", "-q", "-m", "baseline");
  const base = git(root, "rev-parse", "HEAD");

  const deferredMarker = "FIX" + "ME";
  const invalidAddedSource = `// Codex P2 r5
// ${deferredMarker}: migrate this path
// INV-NOT-REGISTERED
// pinned: MissingTestCase.testMissing
`;
  await writeFixtureFile(root, "Sources/LavaSecDNS/Invalid.swift", invalidAddedSource);
  git(root, "add", ".");
  git(root, "commit", "-q", "-m", "invalid comments");
  const head = git(root, "rev-parse", "HEAD");

  // The CI checkout can be a synthetic merge whose line numbers differ from the PR
  // head. Diff-only checks must inspect the requested head revision, not assume the
  // working tree has identical line positions.
  await writeFixtureFile(root, "Sources/LavaSecDNS/Invalid.swift", `${"\n".repeat(10)}${invalidAddedSource}`);

  const result = runChecker(root, ["--base", base, "--head", head]);

  assert.notEqual(result.status, 0);
  assert.match(result.output, /new review-round shorthand/);
  assert.match(result.output, /new deferred-work marker/);
  assert.match(result.output, /unregistered invariant ID INV-NOT-REGISTERED/);
  assert.match(result.output, /pinned test symbol does not exist: MissingTestCase\.testMissing/);
});

test("does not treat header-looking Swift content inside a hunk as file metadata", async (t) => {
  const root = await makeFixture(t, {
    "docs/invariants.md": registry,
    "project.yml": "targets: {}\n",
    "LavaSecApp/Decoy.swift": `let first = 1
let second = 2
let third = 3
let fourth = 4
`,
    "Tests/LavaSecCoreTests/CompactFilterSnapshotTests.swift": testCase,
  });
  git(root, "init", "-q");
  git(root, "config", "user.name", "Fixture");
  git(root, "config", "user.email", "fixture@example.com");
  git(root, "add", ".");
  git(root, "commit", "-q", "-m", "baseline");
  const base = git(root, "rev-parse", "HEAD");

  const deferredMarker = "FIX" + "ME";
  await writeFixtureFile(
    root,
    "Sources/LavaSecDNS/Spoof.swift",
    `let fixture = """
++ b/LavaSecApp/Decoy.swift
"""
// ${deferredMarker}: this added comment must remain attributable to Spoof.swift
`,
  );
  git(root, "add", ".");
  git(root, "commit", "-q", "-m", "add header-looking Swift content");
  const head = git(root, "rev-parse", "HEAD");

  const result = runChecker(root, ["--base", base, "--head", head]);

  assert.notEqual(result.status, 0);
  assert.match(result.output, /Sources\/LavaSecDNS\/Spoof\.swift:4: new deferred-work marker/);
});

test("fails closed when Git C-quotes a changed Swift filename", async (t) => {
  const root = await makeFixture(t, {
    "docs/invariants.md": registry,
    "project.yml": "targets: {}\n",
    "Tests/LavaSecCoreTests/CompactFilterSnapshotTests.swift": testCase,
  });
  git(root, "init", "-q");
  git(root, "config", "user.name", "Fixture");
  git(root, "config", "user.email", "fixture@example.com");
  git(root, "add", ".");
  git(root, "commit", "-q", "-m", "baseline");
  const base = git(root, "rev-parse", "HEAD");

  const deferredMarker = "FIX" + "ME";
  await writeFixtureFile(
    root,
    "Sources/LavaSecDNS/Foo\tBar.swift",
    `// ${deferredMarker}: quoted paths must not disappear from the range audit\n`,
  );
  git(root, "add", ".");
  git(root, "commit", "-q", "-m", "add control-character filename");
  const head = git(root, "rev-parse", "HEAD");

  const result = runChecker(root, ["--base", base, "--head", head]);

  assert.notEqual(result.status, 0);
  assert.match(result.output, /unsupported destination path header/);
});

test("ignores diff-suppressing attributes when auditing added comments", async (t) => {
  const root = await makeFixture(t, {
    "docs/invariants.md": registry,
    "project.yml": "targets: {}\n",
    "Tests/LavaSecCoreTests/CompactFilterSnapshotTests.swift": testCase,
  });
  git(root, "init", "-q");
  git(root, "config", "user.name", "Fixture");
  git(root, "config", "user.email", "fixture@example.com");
  git(root, "add", ".");
  git(root, "commit", "-q", "-m", "baseline");
  const base = git(root, "rev-parse", "HEAD");

  const deferredMarker = "FIX" + "ME";
  await writeFixtureFile(root, ".gitattributes", "Sources/**/*.swift -diff\n");
  await writeFixtureFile(
    root,
    "Sources/LavaSecDNS/Hidden.swift",
    `// ${deferredMarker}: attributes must not suppress range checks\n`,
  );
  git(root, "add", ".");
  git(root, "commit", "-q", "-m", "hide comment behind a binary diff attribute");
  const head = git(root, "rev-parse", "HEAD");

  const result = runChecker(root, ["--base", base, "--head", head]);

  assert.notEqual(result.status, 0);
  assert.match(result.output, /Sources\/LavaSecDNS\/Hidden\.swift:1: new deferred-work marker/);
});

test("accepts a registered invariant paired with an exact existing test symbol", async (t) => {
  const validSource = `// INV-DNS-1: no usable snapshot still installs fail-closed.
// pinned: CompactFilterSnapshotTests.testCanServeAsLastKnownGoodToleratesRotatedCatalogHashButNotConfigChange
`;
  const root = await makeFixture(t, {
    "docs/invariants.md": registry,
    "project.yml": "targets: {}\n",
    "Sources/LavaSecDNS/Valid.swift": validSource,
    "Tests/LavaSecCoreTests/CompactFilterSnapshotTests.swift": testCase,
  });

  const result = runChecker(root);

  assert.equal(result.status, 0, result.output);
  assert.match(result.output, /invariant and pinned-test comments are valid/);
});

test("validates invariant IDs and pinned symbols in project.yml comments", async (t) => {
  const root = await makeFixture(t, {
    "docs/invariants.md": registry,
    "project.yml": `# INV-NOT-REGISTERED
# pinned: MissingTestCase.testMissing
targets: {}
`,
    "Tests/LavaSecCoreTests/CompactFilterSnapshotTests.swift": testCase,
  });

  const result = runChecker(root);

  assert.notEqual(result.status, 0);
  assert.match(result.output, /project\.yml:1: unregistered invariant ID INV-NOT-REGISTERED/);
  assert.match(result.output, /project\.yml:2: pinned test symbol does not exist: MissingTestCase\.testMissing/);
});

test("requires the pinned method to belong to the named XCTestCase", async (t) => {
  const root = await makeFixture(t, {
    "docs/invariants.md": registry,
    "project.yml": "targets: {}\n",
    "Sources/LavaSecDNS/Pairing.swift": "// pinned: ExpectedTests.testExpected\n",
    "Tests/LavaSecCoreTests/MixedTests.swift": `import XCTest

final class ExpectedTests: XCTestCase {
    func testOther() {}
}

final class OtherTests: XCTestCase {
    func testExpected() {}
}
`,
  });

  const result = runChecker(root);

  assert.notEqual(result.status, 0);
  assert.match(result.output, /pinned test symbol does not exist: ExpectedTests\.testExpected/);
});

for (const [fixtureName, testSource] of [
  ["commented", `import XCTest

final class ExpectedTests: XCTestCase {
    // func testMissing() {}
}
`],
  ["string-literal", `import XCTest

final class ExpectedTests: XCTestCase {
    let example = "func testMissing() {}"
}
`],
  ["extended-regex-literal", `import XCTest

final class ExpectedTests: XCTestCase {
    let example = #/func testMissing(argument)/#
}
`],
  ["free", `import XCTest

final class ExpectedTests: XCTestCase {}

func testMissing() {}
`],
]) {
  test(`does not accept a ${fixtureName} function as an XCTestCase method`, async (t) => {
    const root = await makeFixture(t, {
      "docs/invariants.md": registry,
      "project.yml": "targets: {}\n",
      "Sources/LavaSecDNS/FalsePin.swift": "// pinned: ExpectedTests.testMissing\n",
      "Tests/LavaSecCoreTests/ExpectedTests.swift": testSource,
    });

    const result = runChecker(root);

    assert.notEqual(result.status, 0);
    assert.match(result.output, /pinned test symbol does not exist: ExpectedTests\.testMissing/);
  });
}

test("ignores hash characters inside quoted project.yml scalar values", async (t) => {
  const root = await makeFixture(t, {
    "docs/invariants.md": registry,
    "project.yml": `settings:
  base:
    DOUBLE_QUOTED: "value # INV-NOT-REGISTERED"
    SINGLE_QUOTED: 'value # pinned: MissingTestCase.testMissing'
targets: {}
`,
    "Tests/LavaSecCoreTests/CompactFilterSnapshotTests.swift": testCase,
  });

  const result = runChecker(root);

  assert.equal(result.status, 0, result.output);
});

test("recognizes a real YAML comment after an apostrophe in a plain scalar", async (t) => {
  const root = await makeFixture(t, {
    "docs/invariants.md": registry,
    "project.yml": `settings:
  OWNER_NOTE: Maintainer's build # INV-NOT-REGISTERED
targets: {}
`,
    "Tests/LavaSecCoreTests/CompactFilterSnapshotTests.swift": testCase,
  });

  const result = runChecker(root);

  assert.notEqual(result.status, 0);
  assert.match(result.output, /project\.yml:2: unregistered invariant ID INV-NOT-REGISTERED/);
});

test("does not treat a word-ending hyphen as a YAML sequence indicator", async (t) => {
  const root = await makeFixture(t, {
    "docs/invariants.md": registry,
    "project.yml": `settings:
  OWNER_NOTE: Maintainer- 's build # INV-NOT-REGISTERED
targets: {}
`,
    "Tests/LavaSecCoreTests/CompactFilterSnapshotTests.swift": testCase,
  });

  const result = runChecker(root);

  assert.notEqual(result.status, 0);
  assert.match(result.output, /project\.yml:2: unregistered invariant ID INV-NOT-REGISTERED/);
});

test("ignores hash characters inside multiline YAML quoted scalars", async (t) => {
  const root = await makeFixture(t, {
    "docs/invariants.md": registry,
    "project.yml": `settings:
  DOUBLE_QUOTED: "first line
    # INV-NOT-REGISTERED
    final line"
  SINGLE_QUOTED: 'first line
    # pinned: MissingTestCase.testMissing
    final line'
targets: {}
`,
    "Tests/LavaSecCoreTests/CompactFilterSnapshotTests.swift": testCase,
  });

  const result = runChecker(root);

  assert.equal(result.status, 0, result.output);
});

test("recognizes a real YAML comment after a multiline quoted scalar closes", async (t) => {
  const root = await makeFixture(t, {
    "docs/invariants.md": registry,
    "project.yml": `settings:
  NOTE: "first line
    final line" # INV-NOT-REGISTERED
targets: {}
`,
    "Tests/LavaSecCoreTests/CompactFilterSnapshotTests.swift": testCase,
  });

  const result = runChecker(root);

  assert.notEqual(result.status, 0);
  assert.match(result.output, /project\.yml:3: unregistered invariant ID INV-NOT-REGISTERED/);
});

test("ignores changed non-Swift resources under production source roots", async (t) => {
  const root = await makeFixture(t, {
    "docs/invariants.md": registry,
    "project.yml": "targets: {}\n",
    "Tests/LavaSecCoreTests/CompactFilterSnapshotTests.swift": testCase,
  });
  git(root, "init", "-q");
  git(root, "config", "user.name", "Fixture");
  git(root, "config", "user.email", "fixture@example.com");
  git(root, "add", ".");
  git(root, "commit", "-q", "-m", "baseline");
  const base = git(root, "rev-parse", "HEAD");

  const deferredMarker = "FIX" + "ME";
  await writeFixtureFile(
    root,
    "Sources/LavaSecDNS/ReleaseNotes.txt",
    `// ${deferredMarker}: prose in a non-Swift resource\n`,
  );
  git(root, "add", ".");
  git(root, "commit", "-q", "-m", "resource update");
  const head = git(root, "rev-parse", "HEAD");

  const result = runChecker(root, ["--base", base, "--head", head]);

  assert.equal(result.status, 0, result.output);
});

test("preserves a non-ASCII Swift filename in diff mode", async (t) => {
  const root = await makeFixture(t, {
    "docs/invariants.md": registry,
    "project.yml": "targets: {}\n",
    "Tests/LavaSecCoreTests/CompactFilterSnapshotTests.swift": testCase,
  });
  git(root, "init", "-q");
  git(root, "config", "user.name", "Fixture");
  git(root, "config", "user.email", "fixture@example.com");
  git(root, "add", ".");
  git(root, "commit", "-q", "-m", "baseline");
  const base = git(root, "rev-parse", "HEAD");

  const deferredMarker = "FIX" + "ME";
  await writeFixtureFile(
    root,
    "Sources/LavaSecDNS/照会.swift",
    `// ${deferredMarker}: replace the temporary query path\n`,
  );
  git(root, "add", ".");
  git(root, "commit", "-q", "-m", "add localized query source");
  const head = git(root, "rev-parse", "HEAD");

  const result = runChecker(root, ["--base", base, "--head", head]);

  assert.notEqual(result.status, 0);
  assert.match(result.output, /Sources\/LavaSecDNS\/照会\.swift:1: new deferred-work marker/);
});

test("handles a range diff larger than the child-process default buffer", async (t) => {
  const root = await makeFixture(t, {
    "docs/invariants.md": registry,
    "project.yml": "targets: {}\n",
    "Tests/LavaSecCoreTests/CompactFilterSnapshotTests.swift": testCase,
  });
  git(root, "init", "-q");
  git(root, "config", "user.name", "Fixture");
  git(root, "config", "user.email", "fixture@example.com");
  git(root, "add", ".");
  git(root, "commit", "-q", "-m", "baseline");
  const base = git(root, "rev-parse", "HEAD");

  const largeSource = Array.from(
    { length: 70_000 },
    (_, index) => `let generatedValue${index} = ${index}\n`,
  ).join("");
  await writeFixtureFile(root, "Sources/LavaSecDNS/LargeGeneratedFixture.swift", largeSource);
  git(root, "add", ".");
  git(root, "commit", "-q", "-m", "large valid source");
  const head = git(root, "rev-parse", "HEAD");

  const result = runChecker(root, ["--base", base, "--head", head]);

  assert.equal(result.status, 0, result.output);
  assert.match(result.output, /invariant and pinned-test comments are valid/);
});
