import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

import { checkSupportedLocaleLayout } from "../supported-locales.mjs";

const scriptsDir = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const fixupsScript = path.join(scriptsDir, "xcodegen-fixups.py");
const fixtureLocales = ["en", "ja"];

function catalog(locales = fixtureLocales) {
  return {
    sourceLanguage: "en",
    strings: {
      Example: {
        localizations: Object.fromEntries(
          locales.map((locale) => [
            locale,
            { stringUnit: { state: "translated", value: `Example ${locale}` } }
          ])
        )
      }
    }
  };
}

function writeJSON(filePath, value) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, `${JSON.stringify(value, null, 2)}\n`);
}

function writeProject(root, locales = ["en", "Base", "ja"]) {
  const regions = locales.map((locale) => `\t\t\t\t${locale},`).join("\n");
  const project = `knownRegions = (\n${regions}\n\t\t\t);\nlastKnownFileType = folder.iconcomposer.icon;\n`;
  const projectPath = path.join(root, "LavaSec.xcodeproj", "project.pbxproj");
  fs.mkdirSync(path.dirname(projectPath), { recursive: true });
  fs.writeFileSync(projectPath, project);
}

function makeFixture() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "lavasec-locales-"));
  writeJSON(path.join(root, "Config", "supported-locales.json"), { locales: fixtureLocales });
  for (const relativePath of [
    "LavaSecApp/Localizable.xcstrings",
    "LavaSecApp/InfoPlist.xcstrings",
    "LavaSecIntents/Localizable.xcstrings"
  ]) {
    writeJSON(path.join(root, relativePath), catalog());
  }
  for (const locale of fixtureLocales) {
    const stringsPath = path.join(
      root,
      "Sources",
      "LavaSecKit",
      "Resources",
      `${locale}.lproj`,
      "Localizable.strings"
    );
    fs.mkdirSync(path.dirname(stringsPath), { recursive: true });
    fs.writeFileSync(stringsPath, '"Example" = "Example";\n');
  }
  writeProject(root);
  return root;
}

function mutateCatalog(root, relativePath, mutation) {
  const filePath = path.join(root, relativePath);
  const value = JSON.parse(fs.readFileSync(filePath, "utf8"));
  mutation(value.strings.Example.localizations);
  writeJSON(filePath, value);
}

function withFixture(action) {
  const root = makeFixture();
  try {
    return action(root);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
}

test("matching locale layouts pass every supported product", () => {
  withFixture((root) => {
    assert.deepEqual(checkSupportedLocaleLayout(root), []);
  });
});

test("missing locales are reported for every supported product", async (t) => {
  const catalogCases = [
    ["app catalog", "LavaSecApp/Localizable.xcstrings"],
    ["InfoPlist catalog", "LavaSecApp/InfoPlist.xcstrings"],
    ["Intents catalog", "LavaSecIntents/Localizable.xcstrings"]
  ];
  for (const [name, relativePath] of catalogCases) {
    await t.test(name, () => withFixture((root) => {
      mutateCatalog(root, relativePath, (localizations) => delete localizations.ja);
      assert.match(checkSupportedLocaleLayout(root).join("\n"), new RegExp(`${relativePath}.*missing locales: ja`));
    }));
  }

  await t.test("LavaSecKit resources", () => withFixture((root) => {
    fs.rmSync(path.join(root, "Sources/LavaSecKit/Resources/ja.lproj"), { recursive: true });
    assert.match(checkSupportedLocaleLayout(root).join("\n"), /LavaSecKit .*missing locales: ja/);
  }));

  await t.test("Xcode knownRegions", () => withFixture((root) => {
    writeProject(root, ["en", "Base"]);
    assert.match(checkSupportedLocaleLayout(root).join("\n"), /knownRegions.*missing locales: ja/);
  }));
});

test("unsupported extra locales are reported for every supported product", async (t) => {
  const catalogCases = [
    ["app catalog", "LavaSecApp/Localizable.xcstrings"],
    ["InfoPlist catalog", "LavaSecApp/InfoPlist.xcstrings"],
    ["Intents catalog", "LavaSecIntents/Localizable.xcstrings"]
  ];
  for (const [name, relativePath] of catalogCases) {
    await t.test(name, () => withFixture((root) => {
      mutateCatalog(root, relativePath, (localizations) => {
        localizations.zz = { stringUnit: { state: "translated", value: "Extra" } };
      });
      assert.match(checkSupportedLocaleLayout(root).join("\n"), new RegExp(`${relativePath}.*unsupported locales: zz`));
    }));
  }

  await t.test("LavaSecKit resources", () => withFixture((root) => {
    fs.mkdirSync(path.join(root, "Sources/LavaSecKit/Resources/zz.lproj"));
    assert.match(checkSupportedLocaleLayout(root).join("\n"), /LavaSecKit .*unsupported locales: zz/);
  }));

  await t.test("Xcode knownRegions", () => withFixture((root) => {
    writeProject(root, ["en", "Base", "ja", "zz"]);
    assert.match(checkSupportedLocaleLayout(root).join("\n"), /knownRegions.*unsupported locales: zz/);
  }));
});

test("XcodeGen fixups derive knownRegions order from the manifest", () => {
  withFixture((root) => {
    writeJSON(path.join(root, "Config", "supported-locales.json"), {
      locales: ["en", "fr", "ja"]
    });
    writeProject(root, ["en", "Base"]);

    const result = spawnSync("python3", [fixupsScript], {
      cwd: root,
      encoding: "utf8",
      env: { ...process.env, LAVASEC_IOS_ROOT: root }
    });

    assert.equal(result.status, 0, result.stderr || result.stdout);
    const project = fs.readFileSync(path.join(root, "LavaSec.xcodeproj/project.pbxproj"), "utf8");
    assert.match(project, /knownRegions = \(\s+en,\s+Base,\s+fr,\s+ja,\s+\);/);
  });
});
