import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import {
  mkdirSync,
  mkdtempSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const detectorPath = path.resolve(testDirectory, "..", "..", "ci", "detect-docs-only.sh");

function makeTemporaryDirectory(t, prefix) {
  const root = mkdtempSync(path.join(os.tmpdir(), prefix));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  return root;
}

function writeFixtureFile(root, relativePath, contents) {
  const absolutePath = path.join(root, relativePath);
  mkdirSync(path.dirname(absolutePath), { recursive: true });
  writeFileSync(absolutePath, contents);
}

function git(root, ...args) {
  return execFileSync("git", args, {
    cwd: root,
    encoding: "utf8",
    env: { ...process.env, LC_ALL: "C" },
  }).trim();
}

function commitAll(root, message) {
  git(root, "add", "-A");
  git(root, "commit", "-q", "-m", message);
  return git(root, "rev-parse", "HEAD");
}

function makeRepository(t, files = { "README.md": "fixture\n" }) {
  const root = makeTemporaryDirectory(t, "lavasec-docs-only-");
  git(root, "init", "-q");
  git(root, "config", "user.name", "Fixture");
  git(root, "config", "user.email", "fixture@example.com");
  git(root, "config", "diff.renames", "true");
  for (const [relativePath, contents] of Object.entries(files)) {
    writeFixtureFile(root, relativePath, contents);
  }
  commitAll(root, "baseline");
  return root;
}

function runDetector(root, event, base = "", head = "", env = {}) {
  return spawnSync(
    detectorPath,
    ["--event", event, "--base", base, "--head", head],
    {
      cwd: root,
      encoding: "utf8",
      env: { ...process.env, ...env },
      maxBuffer: 8 * 1024 * 1024,
    },
  );
}

function assertClassification(result, expected) {
  const output = `${result.stdout ?? ""}${result.stderr ?? ""}`;
  assert.equal(result.status, 0, result.error?.message ?? output);
  assert.equal(result.stdout, `${expected}\n`, output);
  assert.notEqual(result.stderr, "", "classification diagnostics must stay on stderr");
}

test("non-pull-request events fail safe without consulting Git", (t) => {
  const root = makeTemporaryDirectory(t, "lavasec-docs-only-push-");
  const fakeBin = path.join(root, "bin");
  const marker = path.join(root, "git-was-called");
  mkdirSync(fakeBin);
  writeFixtureFile(
    fakeBin,
    "git",
    `#!/bin/sh\ntouch ${JSON.stringify(marker)}\nexit 99\n`,
  );
  execFileSync("chmod", ["+x", path.join(fakeBin, "git")]);

  const result = runDetector(root, "push", "missing-base", "missing-head", {
    PATH: `${fakeBin}:${process.env.PATH}`,
  });

  assertClassification(result, "false");
  assert.equal(spawnSync("test", ["-e", marker]).status, 1);
});

test("a PR containing only docs paths and markdown files is docs-only", (t) => {
  const root = makeRepository(t);
  const base = git(root, "rev-parse", "HEAD");
  writeFixtureFile(root, "docs/operations.txt", "operations\n");
  writeFixtureFile(root, "guides/Contributor Notes.md", "notes\n");
  const head = commitAll(root, "add docs");

  assertClassification(runDetector(root, "pull_request", base, head), "true");
});

test("a mixed documentation and source PR runs fully", (t) => {
  const root = makeRepository(t);
  const base = git(root, "rev-parse", "HEAD");
  writeFixtureFile(root, "docs/operations.txt", "operations\n");
  writeFixtureFile(root, "Sources/Feature.swift", "struct Feature {}\n");
  const head = commitAll(root, "add docs and source");

  assertClassification(runDetector(root, "pull_request", base, head), "false");
});

test("empty and invalid PR ranges fail safe", async (t) => {
  const root = makeRepository(t);
  const head = git(root, "rev-parse", "HEAD");

  await t.test("empty range", () => {
    assertClassification(runDetector(root, "pull_request", head, head), "false");
  });
  await t.test("invalid range", () => {
    assertClassification(
      runDetector(root, "pull_request", "missing-base", "missing-head"),
      "false",
    );
  });
});

test("renaming source into docs remains a full-build change", (t) => {
  const root = makeRepository(t, {
    "Sources/Feature.swift": "struct Feature {}\n",
  });
  const base = git(root, "rev-parse", "HEAD");
  mkdirSync(path.join(root, "docs"), { recursive: true });
  git(root, "mv", "Sources/Feature.swift", "docs/Feature.md");
  const head = commitAll(root, "move source into docs");

  assertClassification(runDetector(root, "pull_request", base, head), "false");
});

test("deleting a file under docs remains docs-only", (t) => {
  const root = makeRepository(t, { "docs/obsolete.txt": "obsolete\n" });
  const base = git(root, "rev-parse", "HEAD");
  rmSync(path.join(root, "docs", "obsolete.txt"));
  const head = commitAll(root, "remove obsolete docs");

  assertClassification(runDetector(root, "pull_request", base, head), "true");
});

test("lookalike documentation paths do not short-circuit", async (t) => {
  for (const relativePath of ["GUIDE.MD", "docs", "documentation/guide.txt"]) {
    await t.test(relativePath, () => {
      const root = makeRepository(t);
      const base = git(root, "rev-parse", "HEAD");
      writeFixtureFile(root, relativePath, "not classified as docs\n");
      const head = commitAll(root, `add ${relativePath}`);

      assertClassification(runDetector(root, "pull_request", base, head), "false");
    });
  }
});

test("a large mixed diff cannot be misclassified after an early non-doc match", (t) => {
  const root = makeTemporaryDirectory(t, "lavasec-docs-only-large-");
  const fakeBin = path.join(root, "bin");
  const changedFiles = path.join(root, "changed-files.txt");
  mkdirSync(fakeBin);
  writeFileSync(
    changedFiles,
    [
      "Sources/Feature.swift",
      ...Array.from({ length: 50_000 }, (_, index) => `docs/generated-${index}.txt`),
      "",
    ].join("\n"),
  );
  writeFixtureFile(
    fakeBin,
    "git",
    `#!/bin/sh\nexec /bin/cat "$DOCS_ONLY_CHANGED_FILES"\n`,
  );
  execFileSync("chmod", ["+x", path.join(fakeBin, "git")]);

  const result = runDetector(root, "pull_request", "base", "head", {
    DOCS_ONLY_CHANGED_FILES: changedFiles,
    PATH: `${fakeBin}:${process.env.PATH}`,
  });

  assertClassification(result, "false");
});
