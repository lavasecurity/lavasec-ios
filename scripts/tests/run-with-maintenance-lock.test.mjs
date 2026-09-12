import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import {
  chmodSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const lockHelperPath = path.resolve(testDirectory, "..", "..", "ci", "run-with-maintenance-lock.sh");

function makeFixture(t) {
  const root = mkdtempSync(path.join(os.tmpdir(), "lavasec-maintenance-lock-"));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const home = path.join(root, "home with spaces");
  const childLog = path.join(root, "child.json");
  const flockLog = path.join(root, "flock-arguments");
  const childScript = path.join(root, "capture-child.mjs");
  const fakeFlock = path.join(root, "flock");
  mkdirSync(home, { recursive: true });
  writeFileSync(
    childScript,
    `import fs from "node:fs";\nfs.writeFileSync(process.env.CHILD_LOG, JSON.stringify(process.argv.slice(2)));\nprocess.exit(Number(process.env.CHILD_EXIT ?? 0));\n`,
  );
  writeFileSync(
    fakeFlock,
    `#!/bin/bash\nset -euo pipefail\nprintf '%s\\0' "$@" > "$FLOCK_LOG"\n[ "$1" = -s ]\n[ "$2" = -o ]\nshift 3\nexec "$@"\n`,
  );
  chmodSync(fakeFlock, 0o755);
  return { root, home, childLog, flockLog, childScript, fakeFlock };
}

function runHelper(fixture, {
  runnerEnvironment,
  childExit = 0,
  flockOverride,
  commandArguments = ["two words", "literal *", "$(not executed)"],
  extraEnvironment = {},
} = {}) {
  const env = {
    ...process.env,
    CHILD_EXIT: String(childExit),
    CHILD_LOG: fixture.childLog,
    FLOCK_LOG: fixture.flockLog,
    HOME: fixture.home,
    RUNNER_ENVIRONMENT: runnerEnvironment,
    ...extraEnvironment,
  };
  if (flockOverride !== undefined) {
    env.LAVA_CI_FLOCK_BIN = flockOverride;
  }
  return spawnSync(
    lockHelperPath,
    ["--", process.execPath, fixture.childScript, ...commandArguments],
    { encoding: "utf8", env },
  );
}

function output(result) {
  return `${result.stdout ?? ""}${result.stderr ?? ""}`;
}

test("hosted runners execute directly and preserve command arguments", (t) => {
  const fixture = makeFixture(t);
  const result = runHelper(fixture, {
    runnerEnvironment: "github-hosted",
    flockOverride: "",
  });

  assert.equal(result.status, 0, result.error?.message ?? output(result));
  assert.deepEqual(
    JSON.parse(readFileSync(fixture.childLog, "utf8")),
    ["two words", "literal *", "$(not executed)"],
  );
  assert.equal(existsSync(fixture.flockLog), false);
  assert.equal(
    existsSync(path.join(fixture.home, ".lava-ci", "maintenance.lock")),
    false,
  );
  assert.equal(existsSync(path.join(fixture.home, ".lava-ci")), true);
});

test("self-hosted runners take the shared maintenance lock and preserve arguments", (t) => {
  const fixture = makeFixture(t);
  const result = runHelper(fixture, {
    runnerEnvironment: "self-hosted",
    extraEnvironment: { PATH: `${fixture.root}:${process.env.PATH}` },
  });

  assert.equal(result.status, 0, result.error?.message ?? output(result));
  assert.deepEqual(
    JSON.parse(readFileSync(fixture.childLog, "utf8")),
    ["two words", "literal *", "$(not executed)"],
  );
  const flockArguments = readFileSync(fixture.flockLog)
    .toString("utf8")
    .split("\0")
    .filter(Boolean);
  assert.deepEqual(flockArguments, [
    "-s",
    "-o",
    path.join(fixture.home, ".lava-ci", "maintenance.lock"),
    process.execPath,
    fixture.childScript,
    "two words",
    "literal *",
    "$(not executed)",
  ]);
});

test("child exit status is preserved on hosted and self-hosted runners", async (t) => {
  await t.test("hosted", () => {
    const fixture = makeFixture(t);
    const result = runHelper(fixture, {
      runnerEnvironment: "github-hosted",
      childExit: 23,
      flockOverride: "",
    });
    assert.equal(result.status, 23, output(result));
  });

  await t.test("self-hosted", () => {
    const fixture = makeFixture(t);
    const result = runHelper(fixture, {
      runnerEnvironment: "self-hosted",
      childExit: 37,
      flockOverride: fixture.fakeFlock,
    });
    assert.equal(result.status, 37, output(result));
  });
});

test("self-hosted runners fail before executing when flock is unavailable", (t) => {
  const fixture = makeFixture(t);
  const result = runHelper(fixture, {
    runnerEnvironment: "self-hosted",
    flockOverride: "",
  });

  assert.equal(result.status, 1, output(result));
  assert.match(output(result), /flock required on self-hosted runner/);
  assert.equal(existsSync(fixture.childLog), false);
});

test("the command separator and a command are required", async (t) => {
  const fixture = makeFixture(t);
  const env = { ...process.env, HOME: fixture.home };

  for (const args of [[], [process.execPath], ["--"]]) {
    await t.test(args.join(" ") || "no arguments", () => {
      const result = spawnSync(lockHelperPath, args, { encoding: "utf8", env });
      assert.equal(result.status, 64, result.error?.message ?? output(result));
      assert.match(output(result), /usage:/);
    });
  }
});

test("background descendants cannot retain the lock after the foreground command exits", async (t) => {
  const candidates = [process.env.LAVA_CI_TEST_FLOCK, '/usr/bin/flock', '/opt/homebrew/bin/flock', '/usr/local/bin/flock'].filter(Boolean);
  const flock = candidates.find(candidate => existsSync(candidate));
  if (!flock) { t.skip('Real flock is required; Linux CI and the Mac runner execute this regression'); return; }
  const fixture = makeFixture(t);
  const ready = path.join(fixture.root, 'ready');
  const finish = path.join(fixture.root, 'finish');
  const pidFile = path.join(fixture.root, 'background-pid');
  const command = path.join(fixture.root, 'foreground.sh');
  writeFileSync(command, 'set -eu\nsleep 30 >/dev/null 2>&1 &\nprintf "%s" "$!" > "$3"\ntouch "$1"\nwhile [ ! -f "$2" ]; do sleep 0.02; done\n');
  const processUnderLock = spawn(lockHelperPath, ['--', 'bash', command, ready, finish, pidFile], {
    stdio: 'ignore', env: {...process.env, HOME: fixture.home, RUNNER_ENVIRONMENT: 'self-hosted', LAVA_CI_FLOCK_BIN: flock},
  });
  let backgroundPid;
  t.after(() => {
    if (processUnderLock.exitCode === null) processUnderLock.kill('SIGTERM');
    if (backgroundPid) try { process.kill(backgroundPid, 'SIGTERM'); } catch {}
  });
  const waitFor = async predicate => {
    const deadline = Date.now() + 5000;
    while (!predicate() && Date.now() < deadline) await new Promise(resolve => setTimeout(resolve, 20));
    assert.ok(predicate(), 'Foreground fixture did not reach the expected state');
  };
  await waitFor(() => existsSync(ready));
  backgroundPid = Number(readFileSync(pidFile, 'utf8'));
  const acquire = () => spawnSync(flock, ['-n', '-x', path.join(fixture.home, '.lava-ci/maintenance.lock'), 'true']);
  assert.notEqual(acquire().status, 0, 'The foreground command must keep maintenance excluded');
  writeFileSync(finish, 'finish');
  await waitFor(() => processUnderLock.exitCode !== null);
  assert.equal(processUnderLock.exitCode, 0);
  process.kill(backgroundPid, 0); // The background descendant is deliberately still alive.
  assert.equal(acquire().status, 0, 'Exclusive lock unavailable after the foreground command finished');
});
