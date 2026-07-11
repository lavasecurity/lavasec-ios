import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const scriptsDir = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const checkerSource = fs.readFileSync(path.join(scriptsDir, "check-string-coverage.mjs"), "utf8");

function catalog(keys = []) {
  return { strings: Object.fromEntries(keys.map((key) => [key, {}])) };
}

function writeJSON(filePath, value) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, `${JSON.stringify(value, null, 2)}\n`);
}

function runFixture({ appKeys = [], infoKeys = [], intentsKeys = [], coreStrings = "", sources = {} }) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "lavasec-string-coverage-"));
  try {
    const checkerPath = path.join(root, "scripts", "check-string-coverage.mjs");
    fs.mkdirSync(path.dirname(checkerPath), { recursive: true });
    fs.writeFileSync(checkerPath, checkerSource);
    writeJSON(path.join(root, "LavaSecApp", "Localizable.xcstrings"), catalog(appKeys));
    writeJSON(path.join(root, "LavaSecApp", "InfoPlist.xcstrings"), catalog(infoKeys));
    writeJSON(path.join(root, "LavaSecIntents", "Localizable.xcstrings"), catalog(intentsKeys));

    const corePath = path.join(root, "Sources/LavaSecKit/Resources/en.lproj/Localizable.strings");
    fs.mkdirSync(path.dirname(corePath), { recursive: true });
    fs.writeFileSync(corePath, coreStrings);
    for (const [relativePath, source] of Object.entries(sources)) {
      const sourcePath = path.join(root, relativePath);
      fs.mkdirSync(path.dirname(sourcePath), { recursive: true });
      fs.writeFileSync(sourcePath, source);
    }

    return spawnSync(process.execPath, [checkerPath], {
      cwd: root,
      encoding: "utf8"
    });
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
}

function assertPassed(result) {
  assert.equal(result.status, 0, result.stderr || result.stdout);
}

function assertFailed(result, pattern) {
  assert.notEqual(result.status, 0, "expected string coverage to fail");
  assert.match(result.stderr, pattern);
}

test("literal sites and every labeled ternary branch are checked", () => {
  assertPassed(runFixture({
    appKeys: ["Known"],
    sources: { "LavaSecApp/Fixture.swift": 'Text("Known")\n' }
  }));

  assertFailed(runFixture({
    appKeys: ["First"],
    sources: {
      "LavaSecApp/Fixture.swift": 'LavaInfoPanel(title: condition ? "First" : "Second")\n'
    }
  }), /"Second".*needs: app catalog or LavaSecCore/);
});

test("interpolated localized keys fail while localized formats pass", () => {
  const interpolated = runFixture({
    sources: {
      "LavaSecApp/Fixture.swift": String.raw`Text("Count \(count)".lavaLocalized)`
    }
  });
  assertFailed(interpolated, /Interpolated \.lavaLocalized check FAILED/);

  assertPassed(runFixture({
    appKeys: ["Count %lld"],
    sources: {
      "LavaSecApp/Fixture.swift": 'Text("Count %lld".lavaLocalizedFormat(count))\n'
    }
  }));
});

test("debug-only branches are stripped but the release else branch is checked", () => {
  const result = runFixture({
    sources: {
      "LavaSecApp/Fixture.swift": `
#if DEBUG
Text("Debug only")
#else
Text("Release text")
#endif
#if LAVA_QA_TOOLS
Text("QA only")
#endif
`
    }
  });

  assertFailed(result, /"Release text"/);
  assert.doesNotMatch(result.stderr, /Debug only|QA only/);
});

test("AppIntent summaries resolve from the catalog of their registering target", () => {
  const appKey = "Switch app to ${filter}";
  const intentsKey = "Switch focus to ${filter}";
  const sources = {
    "LavaSecApp/SwitchFilterShortcut.swift": String.raw`let summary = Summary("Switch app to \(\.$filter)")`,
    "LavaSecIntents/FocusFilterIntent.swift": String.raw`let summary = Summary("Switch focus to \(\.$filter)")`
  };

  const wrongBundles = runFixture({
    appKeys: [intentsKey],
    intentsKeys: [appKey],
    sources
  });
  assertFailed(wrongBundles, /Switch app to \$\{filter\}.*needs: app catalog/);
  assert.match(wrongBundles.stderr, /Switch focus to \$\{filter\}.*needs: LavaSecIntents catalog/);

  assertPassed(runFixture({ appKeys: [appKey], intentsKeys: [intentsKey], sources }));
});

test("bundle scoping prevents extensions from borrowing app catalog keys", () => {
  const result = runFixture({
    appKeys: ["App only"],
    coreStrings: '"Core shared" = "Core shared";\n',
    sources: {
      "LavaSecApp/AppView.swift": 'Text("Core shared")\n',
      "LavaSecWidget/WidgetView.swift": 'Text("App only")\n',
      "LavaSecIntents/IntentView.swift": 'Text("Filter")\n'
    }
  });

  assertFailed(result, /"App only".*needs: LavaSecCore \.strings/);
  assert.match(result.stderr, /"Filter".*needs: LavaSecIntents catalog/);
});

test("escaped quotes in legacy strings keys are decoded before matching", () => {
  assertPassed(runFixture({
    coreStrings: String.raw`"Tap \"Guard\"" = "Tap \"Guard\"";` + "\n",
    sources: {
      "LavaSecWidget/WidgetView.swift": String.raw`Text("Tap \"Guard\"")`
    }
  }));
});

test("registered render-bound assignments reject raw literals and accept localized formats", () => {
  const raw = runFixture({
    appKeys: ["Could not save plan state: %@"],
    sources: {
      "LavaSecApp/Controller.swift": String.raw`
lavaSecurityPlusMessage = "Could not save plan state: \(error.localizedDescription)"
otherMessage = "Raw diagnostic"
`
    }
  });
  assertFailed(raw, /Render-bound message localization check FAILED/);
  assert.match(raw.stderr, /lavaSecurityPlusMessage.*Could not save plan state/);
  assert.doesNotMatch(raw.stderr, /otherMessage|Raw diagnostic/);

  const rawSwiftString = runFixture({
    sources: {
      "LavaSecApp/Controller.swift": 'lavaSecurityPlusMessage = #"Visible raw message"#\n'
    }
  });
  assertFailed(rawSwiftString, /lavaSecurityPlusMessage = <raw Swift string literal>/);

  assertPassed(runFixture({
    appKeys: ["Could not save plan state: %@"],
    sources: {
      "LavaSecApp/Controller.swift": `
// lavaSecurityPlusMessage = "Documentation example"
/*
lavaSecurityPlusMessage = "Block-comment example"
lavaSecurityPlusMessage = #"Raw block-comment example"#
*/
let documentation = #"""
lavaSecurityPlusMessage = "Embedded raw-string example"
"""#
self.lavaSecurityPlusMessage = "Could not save plan state: %@".lavaLocalizedFormat(error.localizedDescription)
otherMessage = "Raw diagnostic"
`
    }
  }));
});

test("registered render-bound ordinary literals are checked inside inline braces", () => {
  const result = runFixture({
    sources: {
      "LavaSecApp/Controller.swift":
        'if shouldReport { self.lavaSecurityPlusMessage = "Inline visible message" }\n'
    }
  });

  assertFailed(result, /lavaSecurityPlusMessage.*Inline visible message/);
});

test("registered render-bound raw literals are checked inside inline braces", () => {
  const result = runFixture({
    sources: {
      "LavaSecApp/Controller.swift":
        'if shouldReport { self.lavaSecurityPlusMessage = #"Inline raw message"# }\n'
    }
  });

  assertFailed(result, /lavaSecurityPlusMessage = <raw Swift string literal>/);
});
