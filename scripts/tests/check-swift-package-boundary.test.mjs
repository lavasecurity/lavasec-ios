import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const checkerPath = path.resolve(testDirectory, "..", "check-swift-package-boundary.py");
const layers = [
  "LavaSecKit",
  "LavaSecNetworking",
  "LavaSecDNS",
  "LavaSecFilterPipeline",
  "LavaSecPresentation",
  "LavaSecAppServices",
];

const byName = (name) => ({ byName: [name, null] });
const makeTarget = (name, type, dependencies, overrides = {}) => ({
  dependencies: dependencies.map(byName),
  exclude: [],
  name,
  packageAccess: true,
  resources: [],
  settings: [],
  type,
  ...overrides,
});
const makeProduct = (name, targets) => ({
  name,
  settings: [],
  targets,
  type: { library: ["automatic"] },
});

function approvedPackageDump() {
  return {
    cLanguageStandard: null,
    cxxLanguageStandard: null,
    dependencies: [],
    name: "LavaSec",
    packageKind: { root: ["/fixture/LavaSec"] },
    pkgConfig: null,
    platforms: [
      { options: [], platformName: "ios", version: "18.0" },
      { options: [], platformName: "macos", version: "15.0" },
    ],
    traits: [],
    products: [
      makeProduct("LavaSecCore", ["LavaSecCore", ...layers]),
      ...layers.map((name) => makeProduct(name, [name])),
    ],
    providers: null,
    swiftLanguageVersions: null,
    targets: [
      makeTarget("LavaSecKit", "regular", [], {
        resources: [{ path: "Resources", rule: { process: {} } }],
        settings: [{
          kind: { linkedLibrary: { _0: "sqlite3" } },
          tool: "linker",
        }],
      }),
      makeTarget("LavaSecNetworking", "regular", ["LavaSecKit"]),
      makeTarget("LavaSecDNS", "regular", ["LavaSecKit"]),
      makeTarget(
        "LavaSecFilterPipeline",
        "regular",
        ["LavaSecKit", "LavaSecNetworking"],
      ),
      makeTarget("LavaSecPresentation", "regular", ["LavaSecKit"]),
      makeTarget(
        "LavaSecAppServices",
        "regular",
        ["LavaSecKit", "LavaSecFilterPipeline"],
      ),
      makeTarget("LavaSecCore", "regular", layers),
      makeTarget("LavaSecCoreTests", "test", ["LavaSecCore", ...layers]),
      makeTarget("LavaSecCoreFacadeCompileTests", "test", ["LavaSecCore"]),
    ],
    toolsVersion: { _version: "6.0.0" },
  };
}

async function runChecker(t, dump) {
  const root = await mkdtemp(path.join(os.tmpdir(), "lavasec-package-boundary-"));
  t.after(() => rm(root, { recursive: true, force: true }));
  const dumpPath = path.join(root, "dump.json");
  await writeFile(dumpPath, `${JSON.stringify(dump)}\n`);
  const result = spawnSync("python3", [checkerPath, "--input", dumpPath], {
    encoding: "utf8",
  });
  return { ...result, output: `${result.stdout ?? ""}${result.stderr ?? ""}` };
}

async function runDescriptionChecker(t, description) {
  const root = await mkdtemp(path.join(os.tmpdir(), "lavasec-package-description-"));
  t.after(() => rm(root, { recursive: true, force: true }));
  const descriptionPath = path.join(root, "description.json");
  await writeFile(descriptionPath, `${JSON.stringify(description)}\n`);
  const result = spawnSync(
    "python3",
    [checkerPath, "--description-input", descriptionPath],
    { encoding: "utf8" },
  );
  return { ...result, output: `${result.stdout ?? ""}${result.stderr ?? ""}` };
}

test("accepts the exact Swift package target and product graph", async (t) => {
  const result = await runChecker(t, approvedPackageDump());

  assert.equal(result.status, 0, result.output);
  assert.match(result.output, /package graph matches the approved boundary/);
});

test("accepts the Xcode 26.5 dump schema only with the manifest localization", async (t) => {
  const dump = approvedPackageDump();
  dump.defaultLocalization = "en";

  const result = await runChecker(t, dump);

  assert.equal(result.status, 0, result.output);
});

test("pins the semantic package description default localization", async (t) => {
  const accepted = await runDescriptionChecker(t, { default_localization: "en" });
  assert.equal(accepted.status, 0, accepted.output);

  for (const description of [{ default_localization: "fr" }, {}]) {
    const rejected = await runDescriptionChecker(t, description);
    assert.notEqual(rejected.status, 0);
    assert.match(rejected.output, /package default localization differs from policy/);
  }
});

test("rejects package-level language, platform, toolchain, and schema drift", async (t) => {
  const cases = new Map([
    ["unexpected top-level field", (dump) => {
      dump.injectedPolicy = true;
    }],
    ["package name", (dump) => {
      dump.name = "InjectedPackage";
    }],
    ["default localization", (dump) => {
      dump.defaultLocalization = "fr";
    }],
    ["platform floor", (dump) => {
      dump.platforms[0].version = "17.0";
    }],
    ["Swift language version", (dump) => {
      dump.swiftLanguageVersions = [{ v5: {} }];
    }],
    ["C language standard", (dump) => {
      dump.cLanguageStandard = "gnu11";
    }],
    ["C++ language standard", (dump) => {
      dump.cxxLanguageStandard = "gnucxx14";
    }],
    ["tools version", (dump) => {
      dump.toolsVersion = { _version: "5.9.0" };
    }],
    ["pkg-config hook", (dump) => {
      dump.pkgConfig = "injected";
    }],
    ["system package provider", (dump) => {
      dump.providers = [{ brew: ["injected"] }];
    }],
    ["package kind shape", (dump) => {
      dump.packageKind = { root: [] };
    }],
    ["missing top-level field", (dump) => {
      delete dump.providers;
    }],
  ]);

  for (const [name, mutate] of cases) {
    await t.test(name, async (subtest) => {
      const dump = approvedPackageDump();
      mutate(dump);

      const result = await runChecker(subtest, dump);

      assert.notEqual(result.status, 0);
      assert.match(result.output, /package (?:top-level fields|name|default localization|platforms|language|tools version|pkg-config|providers|kind) differ/);
    });
  }
});

test("rejects relocated, hidden, executable, and selectively compiled targets", async (t) => {
  const cases = new Map([
    ["relocated source", (dump) => {
      dump.targets[1].path = "Unlinted/LavaSecNetworking";
    }],
    ["hidden target", (dump) => {
      dump.targets.push(makeTarget("InjectedTarget", "regular", []));
      dump.targets[1].dependencies.push(byName("InjectedTarget"));
    }],
    ["build-tool plugin", (dump) => {
      dump.targets[1].pluginUsages = [{ plugin: "EscapePlugin" }];
    }],
    ["unsafe compiler settings", (dump) => {
      dump.targets[1].settings = [{
        kind: { unsafeFlags: { _0: ["-load-plugin-executable", "/tmp/Escape"] } },
        tool: "swift",
      }];
    }],
    ["explicit sources", (dump) => {
      dump.targets[1].sources = ["../../Unlinted/LavaSecNetworking"];
    }],
  ]);

  for (const [name, mutate] of cases) {
    await t.test(name, async (subtest) => {
      const dump = approvedPackageDump();
      mutate(dump);

      const result = await runChecker(subtest, dump);

      assert.notEqual(result.status, 0);
      assert.match(result.output, /package target .* differs|package target set differs/);
    });
  }
});
