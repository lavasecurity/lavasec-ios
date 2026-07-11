import assert from "node:assert/strict";
import { mkdir, mkdtemp, rm, symlink, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";
import { fileURLToPath } from "node:url";

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const checkerPath = path.resolve(testDirectory, "..", "check-xcodegen-sources.mjs");

async function makeFixture(t, files) {
  const root = await mkdtemp(path.join(os.tmpdir(), "lavasec-xcodegen-sources-"));
  t.after(() => rm(root, { recursive: true, force: true }));

  for (const [relativePath, contents] of Object.entries(files)) {
    const absolutePath = path.join(root, relativePath);
    await mkdir(path.dirname(absolutePath), { recursive: true });
    await writeFile(absolutePath, contents);
  }

  return root;
}

function runChecker(root, arguments_ = []) {
  const result = spawnSync(process.execPath, [checkerPath, ...arguments_], {
    cwd: root,
    encoding: "utf8",
  });
  return {
    ...result,
    output: `${result.stdout ?? ""}${result.stderr ?? ""}`,
  };
}

test("rejects a Swift source that is absent from every Xcode target", async (t) => {
  const root = await makeFixture(t, {
    "project.yml": `targets:
  LavaSec:
    sources:
      - path: LavaSecApp/Main.swift
`,
    "LavaSecApp/Main.swift": "struct Main {}\n",
    "LavaSecApp/Orphan.swift": "struct Orphan {}\n",
  });

  const result = runChecker(root);

  assert.notEqual(result.status, 0);
  assert.match(result.output, /unregistered Swift source: LavaSecApp\/Orphan\.swift/);
});

test("rejects a manifest Swift path that does not exist", async (t) => {
  const root = await makeFixture(t, {
    "project.yml": `targets:
  LavaSec:
    sources:
      - path: LavaSecApp/Missing.swift
`,
  });

  const result = runChecker(root);

  assert.notEqual(result.status, 0);
  assert.match(result.output, /manifest Swift path does not exist: LavaSecApp\/Missing\.swift/);
});

test("rejects a duplicate Swift path inside one Xcode target", async (t) => {
  const root = await makeFixture(t, {
    "project.yml": `targets:
  LavaSec:
    sources:
      - path: LavaSecApp/Main.swift
      - path: LavaSecApp/Main.swift
`,
    "LavaSecApp/Main.swift": "struct Main {}\n",
  });

  const result = runChecker(root);

  assert.notEqual(result.status, 0);
  assert.match(result.output, /duplicate Swift path in target LavaSec: LavaSecApp\/Main\.swift/);
});

test("allows one Shared Swift source to belong to multiple Xcode targets", async (t) => {
  const root = await makeFixture(t, {
    "project.yml": `targets:
  LavaSec:
    sources:
      - path: Shared/AppGroup.swift
  LavaSecWidget:
    sources:
      - path: Shared/AppGroup.swift
`,
    "Shared/AppGroup.swift": "struct AppGroup {}\n",
  });

  const result = runChecker(root);

  assert.equal(result.status, 0, result.output);
  assert.match(result.output, /all Swift sources have valid explicit target membership/);
});

test("rejects an orphan under a source root introduced by a new extension target", async (t) => {
  const root = await makeFixture(t, {
    "project.yml": `targets:
  LavaSecShare:
    type: app-extension
    sources:
      - path: BrandNewShareExtension/Main.swift
`,
    "BrandNewShareExtension/Main.swift": "struct Main {}\n",
    "BrandNewShareExtension/Orphan.swift": "struct Orphan {}\n",
  });

  const result = runChecker(root);

  assert.notEqual(result.status, 0);
  assert.match(
    result.output,
    /unregistered Swift source: BrandNewShareExtension\/Orphan\.swift/,
  );
});

test("rejects a directory source entry that would implicitly register Swift", async (t) => {
  const root = await makeFixture(t, {
    "project.yml": `targets:
  LavaSecShare:
    type: app-extension
    sources:
      - path: BrandNewShareExtension
`,
    "BrandNewShareExtension/Main.swift": "struct Main {}\n",
  });

  const result = runChecker(root);

  assert.notEqual(result.status, 0);
  assert.match(
    result.output,
    /directory source path must list Swift files explicitly: BrandNewShareExtension/,
  );
});

for (const [name, manifest] of [
  [
    "three-space target indentation",
    `targets:
   LavaSec:
     sources:
       - path: App/Main.swift
`,
  ],
  [
    "seven-space source indentation",
    `targets:
  LavaSec:
    sources:
       - path: App/Main.swift
`,
  ],
  [
    "whitespace before the targets colon",
    `targets :
  LavaSec:
    sources:
      - path: App/Main.swift
`,
  ],
]) {
  test(`audits valid XcodeGen YAML with ${name}`, async (t) => {
    const root = await makeFixture(t, {
      "project.yml": manifest,
      "App/Main.swift": "struct Main {}\n",
      "App/Orphan.swift": "struct Orphan {}\n",
    });

    const result = runChecker(root);

    assert.notEqual(result.status, 0);
    assert.match(result.output, /unregistered Swift source: App\/Orphan\.swift/);
  });
}

test("rejects source symlinks instead of omitting Xcode-compiled Swift", async (t) => {
  const root = await makeFixture(t, {
    "project.yml": `targets:
  LavaSec:
    type: application
    sources:
      - path: App
`,
    "App/README.txt": "fixture\n",
    "External.swift": "struct External {}\n",
  });
  await symlink("../External.swift", path.join(root, "App/Linked.swift"));

  const result = runChecker(root);

  assert.notEqual(result.status, 0);
  assert.match(result.output, /source tree contains symbolic link: App\/Linked\.swift/);
});

test("rejects top-level source files whose sibling coverage is ambiguous", async (t) => {
  const root = await makeFixture(t, {
    "project.yml": `targets:
  LavaSec:
    type: application
    sources:
      - path: Main.swift
`,
    "Main.swift": "struct Main {}\n",
    "Orphan.swift": "struct Orphan {}\n",
  });

  const result = runChecker(root);

  assert.notEqual(result.status, 0);
  assert.match(result.output, /top-level source path is unsupported: Main\.swift/);
});

test("rejects Swift explicitly excluded from the target sources build phase", async (t) => {
  const root = await makeFixture(t, {
    "project.yml": `targets:
  LavaSec:
    type: application
    sources:
      - path: LavaSecApp/Main.swift
        buildPhase: none
`,
    "LavaSecApp/Main.swift": "struct Main {}\n",
  });

  const result = runChecker(root);

  assert.notEqual(result.status, 0);
  assert.match(
    result.output,
    /Swift source is not in the sources build phase for LavaSec: LavaSecApp\/Main\.swift/,
  );
});

test("rejects a Swift source registered only in the wrong production target", async (t) => {
  const root = await makeFixture(t, {
    "project.yml": `targets:
  LavaSecWidget:
    type: app-extension
    sources:
      - path: LavaSecApp/WidgetLeak.swift
`,
    "LavaSecApp/WidgetLeak.swift": "struct WidgetLeak {}\n",
  });

  const result = runChecker(root);

  assert.notEqual(result.status, 0);
  assert.match(
    result.output,
    /source root LavaSecApp is not allowed in target LavaSecWidget/,
  );
});

test("scans known source roots even when a target loses every source entry", async (t) => {
  const root = await makeFixture(t, {
    "project.yml": `targets:
  LavaSecWidget:
    type: app-extension
`,
    "LavaSecWidget/Orphan.swift": "struct Orphan {}\n",
  });

  const result = runChecker(root);

  assert.notEqual(result.status, 0);
  assert.match(result.output, /unregistered Swift source: LavaSecWidget\/Orphan\.swift/);
});

test("rejects included specs instead of auditing only the root project file", async (t) => {
  const root = await makeFixture(t, {
    "project.yml": `include: extra.yml
targets:
  LavaSec:
    type: application
    sources:
      - path: LavaSecApp/Main.swift
`,
    "extra.yml": `targets:
  LavaSec:
    sources:
      - path: Escaped/Bad.swift
`,
    "LavaSecApp/Main.swift": "struct Main {}\n",
    "Escaped/Bad.swift": "import LavaSecCore\n",
  });

  const result = runChecker(root);

  assert.notEqual(result.status, 0);
  assert.match(result.output, /unsupported top-level XcodeGen expansion key: include/);
});

test("rejects target templates that can inject unaudited sources", async (t) => {
  const root = await makeFixture(t, {
    "project.yml": `targetTemplates:
  EscapeTemplate:
    sources:
      - path: Escaped/Bad.swift
targets:
  LavaSec:
    templates:
      - EscapeTemplate
    type: application
    sources:
      - path: LavaSecApp/Main.swift
`,
    "LavaSecApp/Main.swift": "struct Main {}\n",
    "Escaped/Bad.swift": "import LavaSecCore\n",
  });

  const result = runChecker(root);

  assert.notEqual(result.status, 0);
  assert.match(result.output, /unsupported top-level XcodeGen expansion key: targetTemplates/);
});

test("rejects YAML target merges that bypass direct source inspection", async (t) => {
  const root = await makeFixture(t, {
    "project.yml": `escape: &escape
  dependencies:
    - package: LavaSecPackage
      product: LavaSecCore
targets:
  LavaSec:
    <<: *escape
    type: application
    sources:
      - path: LavaSecApp/Main.swift
`,
    "LavaSecApp/Main.swift": "struct Main {}\n",
  });

  const result = runChecker(root);

  assert.notEqual(result.status, 0);
  assert.match(result.output, /unsupported top-level XcodeGen key: escape/);
});

test("rejects XcodeGen merge modifiers on target source mappings", async (t) => {
  const root = await makeFixture(t, {
    "project.yml": `targets:
  LavaSec:
    type: application
    "sources:REPLACE":
      - path: Escaped/Bad.swift
    sources:
      - path: LavaSecApp/Main.swift
`,
    "LavaSecApp/Main.swift": "struct Main {}\n",
    "Escaped/Bad.swift": "import LavaSecCore\n",
  });

  const result = runChecker(root);

  assert.notEqual(result.status, 0);
  assert.match(result.output, /unsupported XcodeGen expansion key in target LavaSec: sources:REPLACE/);
});

test("rejects multi-platform target expansion into unclassified native targets", async (t) => {
  const root = await makeFixture(t, {
    "project.yml": `targets:
  LavaSec:
    type: application
    platform: [iOS, macOS]
    sources:
      - path: LavaSecApp/Main.swift
`,
    "LavaSecApp/Main.swift": "struct Main {}\n",
  });

  const result = runChecker(root);

  assert.notEqual(result.status, 0);
  assert.match(result.output, /target LavaSec must use exactly platform iOS/);
});

test("rejects XcodeGen environment substitution in source paths", async (t) => {
  const root = await makeFixture(t, {
    "project.yml": `targets:
  LavaSec:
    type: application
    platform: iOS
    sources:
      - path: LavaSecApp/\${ESCAPE}/Bad.swift
`,
    "LavaSecApp/${ESCAPE}/Bad.swift": "struct CleanDecoy {}\n",
    "Escaped/Bad.swift": "import LavaSecCore\n",
  });

  const result = runChecker(root);

  assert.notEqual(result.status, 0);
  assert.match(result.output, /XcodeGen environment substitution is unsupported/);
});

test("rejects target properties that rename the generated native target", async (t) => {
  const root = await makeFixture(t, {
    "project.yml": `targets:
  LavaSec:
    name: RenamedNativeTarget
    type: application
    platform: iOS
    sources:
      - path: LavaSecApp/Main.swift
`,
    "LavaSecApp/Main.swift": "struct Main {}\n",
  });

  const result = runChecker(root);

  assert.notEqual(result.status, 0);
  assert.match(result.output, /unsupported XcodeGen identity key in target LavaSec: name/);
});

for (const [name, option, expected] of [
  [
    "pre-generation commands",
    "preGenCommand: python3 scripts/mutate-sources.py",
    /XcodeGen preGenCommand is unsupported/,
  ],
  [
    "an unapproved post-generation command",
    "postGenCommand: python3 scripts/mutate-project.py",
    /XcodeGen postGenCommand must be exactly python3 scripts\/xcodegen-fixups\.py/,
  ],
]) {
  test(`rejects ${name}`, async (t) => {
    const root = await makeFixture(t, {
      "project.yml": `options:
  ${option}
targets:
  LavaSec:
    type: application
    platform: iOS
    sources:
      - path: LavaSecApp/Main.swift
`,
      "LavaSecApp/Main.swift": "struct Main {}\n",
    });

    const result = runChecker(root);

    assert.notEqual(result.status, 0);
    assert.match(result.output, expected);
  });
}

test("rejects project-format and unknown generator options outside the pinned policy", async (t) => {
  for (const [name, option, xcodeVersion, expected] of [
    [
      "project format override",
      "projectFormat: xcode16_3",
      "26.3",
      /unsupported XcodeGen option: projectFormat/,
    ],
    [
      "unknown option",
      "futureGeneratorEscape: true",
      "26.3",
      /unsupported XcodeGen option: futureGeneratorEscape/,
    ],
    [
      "changed Xcode version",
      "",
      "16.3",
      /XcodeGen option xcodeVersion differs from policy/,
    ],
  ]) {
    const root = await makeFixture(t, {
      "project.yml": `options:
  settingPresets: none
  xcodeVersion: "${xcodeVersion}"
  developmentLanguage: en
  defaultConfig: Release
  postGenCommand: python3 scripts/xcodegen-fixups.py
  fileTypes:
    icon:
      file: true
      buildPhase: resources
  ${option}
targets:
  LavaSec:
    type: application
    platform: iOS
    sources:
      - path: LavaSecApp/Main.swift
`,
      "LavaSecApp/Main.swift": "struct Main {}\n",
    });

    const result = runChecker(root);

    assert.notEqual(result.status, 0, name);
    assert.match(result.output, expected, name);
  }
});

test("rejects shared shell-command breakpoint artifacts", async (t) => {
  const root = await makeFixture(t, {
    "project.yml": `name: LavaSec
breakpoints:
  - type: Symbolic
    symbol: malloc
    enabled: true
    continueAfterRunningActions: true
    actions:
      - type: ShellCommand
        path: /usr/bin/touch
        arguments: /tmp/lavasec-breakpoint-pwned
        waitUntilDone: true
targets:
  LavaSec:
    type: application
    platform: iOS
    sources:
      - path: LavaSecApp/Main.swift
`,
    "LavaSecApp/Main.swift": "struct Main {}\n",
  });

  const result = runChecker(root);

  assert.notEqual(result.status, 0);
  assert.match(result.output, /unsupported top-level XcodeGen key: breakpoints/);
});

test("rejects YAML line separators that hide executable generator commands", async (t) => {
  for (const [name, separator] of [
    ["lone CR", "\r"],
    ["NEL", "\u0085"],
    ["line separator", "\u2028"],
    ["paragraph separator", "\u2029"],
  ]) {
    const root = await makeFixture(t, {
      "project.yml": `options:
  # approved comment${separator}  preGenCommand: touch /tmp/injected
  postGenCommand: python3 scripts/xcodegen-fixups.py
  fileTypes:
    icon:
      file: true
      buildPhase: resources
targets:
  LavaSec:
    type: application
    platform: iOS
    sources:
      - path: LavaSecApp/Main.swift
`,
      "LavaSecApp/Main.swift": "struct Main {}\n",
    });

    const result = runChecker(root);

    assert.notEqual(result.status, 0, name);
    assert.match(result.output, /unsupported YAML line separator/, name);
  }
});

test("rejects YAML byte-order marks before semantic parsing", async (t) => {
  const root = await makeFixture(t, {
    "project.yml": `\uFEFFtargets:
  LavaSec:
    type: application
    platform: iOS
    sources:
      - path: LavaSecApp/Main.swift
`,
    "LavaSecApp/Main.swift": "struct Main {}\n",
  });

  const result = runChecker(root);

  assert.notEqual(result.status, 0);
  assert.match(result.output, /unsupported YAML byte-order mark/);
});

test("rejects deprecated localPackages that can replace package identity", async (t) => {
  const root = await makeFixture(t, {
    "project.yml": `localPackages:
  - Evil/LavaSecPackage
targets:
  LavaSec:
    type: application
    platform: iOS
    sources:
      - path: LavaSecApp/Main.swift
`,
    "LavaSecApp/Main.swift": "struct Main {}\n",
  });

  const result = runChecker(root);

  assert.notEqual(result.status, 0);
  assert.match(result.output, /unsupported top-level XcodeGen expansion key: localPackages/);
});

test("rejects transitive dependency linking that expands direct product edges", async (t) => {
  const root = await makeFixture(t, {
    "project.yml": `targets:
  LavaSecWidget:
    type: app-extension
    platform: iOS
    transitivelyLinkDependencies: true
    sources:
      - path: LavaSecWidget/Main.swift
`,
    "LavaSecWidget/Main.swift": "struct Main {}\n",
  });

  const result = runChecker(root);

  assert.notEqual(result.status, 0);
  assert.match(result.output, /transitive dependency linking is unsupported in target LavaSecWidget/);
});

test("rejects global Swift file-type build-phase overrides", async (t) => {
  const root = await makeFixture(t, {
    "project.yml": `options:
  postGenCommand: python3 scripts/xcodegen-fixups.py
  fileTypes:
    swift:
      buildPhase: resources
targets:
  LavaSec:
    type: application
    platform: iOS
    sources:
      - path: LavaSecApp/Main.swift
`,
    "LavaSecApp/Main.swift": "struct Main {}\n",
  });

  const result = runChecker(root);

  assert.notEqual(result.status, 0);
  assert.match(result.output, /options\.fileTypes must contain only the approved icon override/);
});

for (const [name, manifest, expected] of [
  [
    "legacy targets",
    `targets:
  LavaSec:
    type: application
    platform: iOS
    legacy:
      toolPath: /usr/bin/true
    sources:
      - path: LavaSecApp/Main.swift
`,
    /unsupported XcodeGen identity key in target LavaSec: legacy/,
  ],
  [
    "target build-tool plugins",
    `targets:
  LavaSec:
    type: application
    platform: iOS
    buildToolPlugins:
      - plugin: EscapePlugin
        package: LavaSecPackage
    sources:
      - path: LavaSecApp/Main.swift
`,
    /unsupported executable graph key in target LavaSec: buildToolPlugins/,
  ],
  [
    "target build scripts",
    `targets:
  LavaSec:
    type: application
    platform: iOS
    preBuildScripts:
      - name: Escape
        script: echo hacked
    sources:
      - path: LavaSecApp/Main.swift
`,
    /unsupported executable graph key in target LavaSec: preBuildScripts/,
  ],
  [
    "generated Info.plist files",
    `targets:
  LavaSec:
    type: application
    platform: iOS
    info:
      path: LavaSecApp/Main.swift
    sources:
      - path: LavaSecApp/Main.swift
`,
    /unsupported generated-file key in target LavaSec: info/,
  ],
  [
    "generated entitlements files",
    `targets:
  LavaSec:
    type: application
    platform: iOS
    entitlements:
      path: LavaSecApp/Main.swift
    sources:
      - path: LavaSecApp/Main.swift
`,
    /unsupported generated-file key in target LavaSec: entitlements/,
  ],
  [
    "target-local scheme actions",
    `targets:
  LavaSec:
    type: application
    platform: iOS
    scheme:
      preActions:
        - script: echo hacked
    sources:
      - path: LavaSecApp/Main.swift
`,
    /unsupported executable graph key in target LavaSec: scheme/,
  ],
]) {
  test(`rejects ${name}`, async (t) => {
    const root = await makeFixture(t, {
      "project.yml": manifest,
      "LavaSecApp/Main.swift": "struct Main {}\n",
    });

    const result = runChecker(root);

    assert.notEqual(result.status, 0);
    assert.match(result.output, expected);
  });
}

for (const [name, section] of [
  [
    "aggregate targets",
    `aggregateTargets:
  EscapeAggregate:
    buildScripts:
      - script: echo hacked
`,
  ],
  [
    "scheme templates",
    `schemeTemplates:
  EscapeTemplate:
    preActions:
      - script: echo hacked
`,
  ],
]) {
  test(`rejects top-level ${name}`, async (t) => {
    const root = await makeFixture(t, {
      "project.yml": `${section}targets:
  LavaSec:
    type: application
    platform: iOS
    sources:
      - path: LavaSecApp/Main.swift
`,
      "LavaSecApp/Main.swift": "struct Main {}\n",
    });

    const result = runChecker(root);

    assert.notEqual(result.status, 0);
    assert.match(result.output, new RegExp(`unsupported top-level XcodeGen expansion key: ${name === "aggregate targets" ? "aggregateTargets" : "schemeTemplates"}`));
  });
}

for (const action of ["preActions", "postActions"]) {
  test(`rejects shared-scheme ${action}`, async (t) => {
    const root = await makeFixture(t, {
      "project.yml": `targets:
  LavaSec:
    type: application
    platform: iOS
    sources:
      - path: LavaSecApp/Main.swift
schemes:
  LavaSec:
    build:
      targets:
        LavaSec: all
      ${action}:
        - name: Escape
          script: echo hacked
`,
      "LavaSecApp/Main.swift": "struct Main {}\n",
    });

    const result = runChecker(root);

    assert.notEqual(result.status, 0);
    assert.match(result.output, new RegExp(`unsupported executable scheme key: ${action}`));
  });
}

test("emits the exact validated Swift membership for generated-project validation", async (t) => {
  const root = await makeFixture(t, {
    "project.yml": `targets:
  LavaSec:
    type: application
    platform: iOS
    sources:
      - path: Shared/Common.swift
      - path: LavaSecApp/Main.swift
`,
    "LavaSecApp/Main.swift": "struct Main {}\n",
    "Shared/Common.swift": "struct Common {}\n",
  });

  const result = runChecker(root, ["--emit-boundary-json"]);

  assert.equal(result.status, 0, result.output);
  assert.deepEqual(JSON.parse(result.stdout), {
    targets: {
      LavaSec: ["LavaSecApp/Main.swift", "Shared/Common.swift"],
    },
  });
});

test("rejects an inline-commented manifest Swift path that does not exist", async (t) => {
  const root = await makeFixture(t, {
    "project.yml": `targets:
  LavaSec:
    sources:
      - path: LavaSecApp/Missing.swift # stale source
`,
  });

  const result = runChecker(root);

  assert.notEqual(result.status, 0);
  assert.match(result.output, /manifest Swift path does not exist: LavaSecApp\/Missing\.swift/);
});

test("rejects inline-commented duplicate Swift paths in one target", async (t) => {
  const root = await makeFixture(t, {
    "project.yml": `targets:
  LavaSec:
    sources:
      - path: LavaSecApp/Main.swift # first membership
      - path: LavaSecApp/Main.swift # duplicate membership
`,
    "LavaSecApp/Main.swift": "struct Main {}\n",
  });

  const result = runChecker(root);

  assert.notEqual(result.status, 0);
  assert.match(result.output, /duplicate Swift path in target LavaSec: LavaSecApp\/Main\.swift/);
});

test("preserves a hash inside a quoted Swift path while stripping its YAML comment", async (t) => {
  const root = await makeFixture(t, {
    "project.yml": `targets:
  LavaSec:
    sources:
      - path: "LavaSecApp/Hash#View.swift" # reviewed membership
`,
    "LavaSecApp/Hash#View.swift": "struct HashView {}\n",
  });

  const result = runChecker(root);

  assert.equal(result.status, 0, result.output);
  assert.match(result.output, /all Swift sources have valid explicit target membership/);
});

test("still rejects a stale inline path after an apostrophe in a plain scalar", async (t) => {
  const root = await makeFixture(t, {
    "project.yml": `name: Maintainer's build
targets:
  LavaSec:
    sources:
      - path: LavaSecApp/Missing.swift # stale source
`,
  });

  const result = runChecker(root);

  assert.notEqual(result.status, 0);
  assert.match(result.output, /manifest Swift path does not exist: LavaSecApp\/Missing\.swift/);
});

test("rejects an unquoted stale Swift path containing an apostrophe", async (t) => {
  const root = await makeFixture(t, {
    "project.yml": `targets:
  LavaSec:
    sources:
      - path: LavaSecApp/What'sNew.swift # stale
`,
  });

  const result = runChecker(root);

  assert.notEqual(result.status, 0);
  assert.match(result.output, /manifest Swift path does not exist: LavaSecApp\/What'sNew\.swift/);
});
