import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import {
  chmod,
  lstat,
  mkdir,
  mkdtemp,
  readFile,
  readlink,
  rm,
  symlink,
  writeFile,
} from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const snapshotScript = path.resolve(testDirectory, "..", "xcodegen-filesystem-snapshot.py");

function runSnapshot(root, ...arguments_) {
  const result = spawnSync("python3", [snapshotScript, ...arguments_], {
    cwd: root,
    encoding: "utf8",
  });
  return { ...result, output: `${result.stdout ?? ""}${result.stderr ?? ""}` };
}

async function makeFixture(t) {
  const container = await mkdtemp(path.join(os.tmpdir(), "lavasec-xcodegen-snapshot-"));
  const root = path.join(container, "repo");
  const backup = path.join(container, "backup");
  const snapshot = path.join(container, "snapshot.json");
  await mkdir(path.join(root, "Config"), { recursive: true });
  await mkdir(path.join(root, ".build"), { recursive: true });
  await writeFile(path.join(root, "Source.swift"), "original\n", { mode: 0o640 });
  await writeFile(path.join(root, "Config", "Lava.local.xcconfig"), "SECRET=original\n");
  await writeFile(path.join(root, ".build", "cache"), "ignored original\n");
  await symlink("Source.swift", path.join(root, "Linked.swift"));
  t.after(() => rm(container, { recursive: true, force: true }));
  return { backup, root, snapshot };
}

test("detects and restores tracked, untracked, ignored-secret, mode, and symlink changes", async (t) => {
  const fixture = await makeFixture(t);
  const written = runSnapshot(fixture.root, "write", fixture.snapshot, fixture.backup);
  assert.equal(written.status, 0, written.output);

  await writeFile(path.join(fixture.root, "Source.swift"), "mutated\n");
  await chmod(path.join(fixture.root, "Source.swift"), 0o777);
  await writeFile(path.join(fixture.root, "Config", "Lava.local.xcconfig"), "SECRET=mutated\n");
  await rm(path.join(fixture.root, "Linked.swift"));
  await symlink("Config/Lava.local.xcconfig", path.join(fixture.root, "Linked.swift"));
  await writeFile(path.join(fixture.root, "Generated.swift"), "generated\n");
  // Simulates a path that was already deleted in the dirty tree, then recreated by generation.
  await writeFile(path.join(fixture.root, "PreexistingDeletion.swift"), "recreated\n");
  await writeFile(path.join(fixture.root, ".build", "cache"), "ignored mutation\n");

  const compared = runSnapshot(fixture.root, "compare", fixture.snapshot);
  assert.notEqual(compared.status, 0);
  assert.match(compared.output, /Config\/Lava\.local\.xcconfig/);
  assert.match(compared.output, /Generated\.swift/);
  assert.match(compared.output, /PreexistingDeletion\.swift/);

  const restored = runSnapshot(
    fixture.root,
    "restore",
    fixture.snapshot,
    fixture.backup,
  );
  assert.equal(restored.status, 0, restored.output);
  assert.equal(await readFile(path.join(fixture.root, "Source.swift"), "utf8"), "original\n");
  assert.equal((await lstat(path.join(fixture.root, "Source.swift"))).mode & 0o777, 0o640);
  assert.equal(
    await readFile(path.join(fixture.root, "Config", "Lava.local.xcconfig"), "utf8"),
    "SECRET=original\n",
  );
  assert.equal(await readlink(path.join(fixture.root, "Linked.swift")), "Source.swift");
  await assert.rejects(() => lstat(path.join(fixture.root, "Generated.swift")), /ENOENT/);
  await assert.rejects(() => lstat(path.join(fixture.root, "PreexistingDeletion.swift")), /ENOENT/);
  assert.equal(
    await readFile(path.join(fixture.root, ".build", "cache"), "utf8"),
    "ignored mutation\n",
  );
  const clean = runSnapshot(fixture.root, "compare", fixture.snapshot);
  assert.equal(clean.status, 0, clean.output);
});

test("preflights missing backups without partially destroying the dirty tree", async (t) => {
  const fixture = await makeFixture(t);
  const written = runSnapshot(fixture.root, "write", fixture.snapshot, fixture.backup);
  assert.equal(written.status, 0, written.output);
  await writeFile(path.join(fixture.root, "Source.swift"), "mutated\n");
  await rm(path.join(fixture.backup, "Source.swift"));

  const restored = runSnapshot(
    fixture.root,
    "restore",
    fixture.snapshot,
    fixture.backup,
  );

  assert.notEqual(restored.status, 0);
  assert.match(restored.output, /snapshot backup is missing Source\.swift/);
  assert.equal(await readFile(path.join(fixture.root, "Source.swift"), "utf8"), "mutated\n");
});

test("restoring a replaced directory symlink never follows it outside the repository", async (t) => {
  const container = await mkdtemp(path.join(os.tmpdir(), "lavasec-xcodegen-symlink-"));
  const root = path.join(container, "repo");
  const outside = path.join(container, "outside");
  const backup = path.join(container, "backup");
  const snapshot = path.join(container, "snapshot.json");
  await mkdir(root);
  await mkdir(outside);
  await writeFile(path.join(outside, "keep.txt"), "outside must survive\n");
  await symlink(outside, path.join(root, "LinkedDirectory"));
  t.after(() => rm(container, { recursive: true, force: true }));

  const written = runSnapshot(root, "write", snapshot, backup);
  assert.equal(written.status, 0, written.output);
  await rm(path.join(root, "LinkedDirectory"));
  await mkdir(path.join(root, "LinkedDirectory"));
  await writeFile(path.join(root, "LinkedDirectory", "keep.txt"), "generated\n");

  const restored = runSnapshot(root, "restore", snapshot, backup);

  assert.equal(restored.status, 0, restored.output);
  assert.equal(await readFile(path.join(outside, "keep.txt"), "utf8"), "outside must survive\n");
  assert.equal(await readlink(path.join(root, "LinkedDirectory")), outside);
  const clean = runSnapshot(root, "compare", snapshot);
  assert.equal(clean.status, 0, clean.output);
});
