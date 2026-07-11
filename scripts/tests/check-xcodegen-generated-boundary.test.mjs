import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

import {
  validateGeneratedProject,
  validateGeneratedSchemes,
} from "../check-xcodegen-generated-boundary.mjs";
import * as generatedBoundary from "../check-xcodegen-generated-boundary.mjs";

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const repositoryRoot = path.resolve(testDirectory, "..", "..");
const boundaryCheckerPath = path.resolve(
  testDirectory,
  "..",
  "check-xcodegen-generated-boundary.mjs",
);
const driftCheckerPath = path.resolve(testDirectory, "..", "check-xcodegen-drift.sh");
const lightBuildWorkflowPath = path.resolve(
  testDirectory,
  "..",
  "..",
  ".github",
  "workflows",
  "light-build.yml",
);

function isExplicitPublicSourceContext() {
  if (process.env.LAVASEC_PUBLIC_EXPORT === "1"
      || process.env.GITHUB_REPOSITORY === "lavasecurity/lavasec-ios") {
    return true;
  }
  const remote = spawnSync("git", ["remote", "get-url", "origin"], {
    cwd: repositoryRoot,
    encoding: "utf8",
  });
  return remote.status === 0
    && /github\.com[:/]lavasecurity\/lavasec-ios(?:\.git)?$/.test(remote.stdout.trim());
}

function skipMissingInternalWorkflow(context, workflowPath, reason) {
  if (fs.existsSync(workflowPath)) {
    return false;
  }
  assert.ok(
    isExplicitPublicSourceContext(),
    `${path.relative(repositoryRoot, workflowPath)} is missing outside an explicit public-source context`,
  );
  context.skip(reason);
  return true;
}
const internalPromotionWorkflowPath = path.resolve(
  testDirectory,
  "..",
  "..",
  ".github",
  "workflows",
  "internal-promotion.yml",
);

const policies = new Map([
  ["LavaSec", ["com.apple.product-type.application", ["GoogleSignIn", "LavaSecAppServices", "LavaSecDNS", "LavaSecFilterPipeline", "LavaSecKit", "LavaSecNetworking", "LavaSecPresentation"], ["LavaSecIntents", "LavaSecTunnel", "LavaSecWidget"]]],
  ["LavaSecTunnel", ["com.apple.product-type.app-extension", ["LavaSecDNS", "LavaSecFilterPipeline", "LavaSecKit", "LavaSecNetworking"], []]],
  ["LavaSecWidget", ["com.apple.product-type.app-extension", ["LavaSecKit", "LavaSecPresentation"], []]],
  ["LavaSecIntents", ["com.apple.product-type.extensionkit-extension", ["LavaSecFilterPipeline", "LavaSecKit"], []]],
  ["LavaSecUITests", ["com.apple.product-type.bundle.ui-testing", ["LavaSecCore"], ["LavaSec"]]],
]);
const approvedResources = new Map([
  [
    "LavaSec",
    [
      "LavaSecApp/AppIcon-QA.icon",
      "LavaSecApp/AppIcon.icon",
      "LavaSecApp/AppIconAmethyst.icon",
      "LavaSecApp/AppIconCherryQuartz.icon",
      "LavaSecApp/AppIconEmerald.icon",
      "LavaSecApp/AppIconFireOpal.icon",
      "LavaSecApp/AppIconKiwiCreme.icon",
      "LavaSecApp/AppIconObsidian.icon",
      "LavaSecApp/Assets.xcassets",
      "LavaSecApp/InfoPlist.xcstrings",
      "LavaSecApp/Localizable.xcstrings",
    ],
  ],
  ["LavaSecIntents", ["LavaSecIntents/Localizable.xcstrings"]],
]);
const trackedXCConfigs = {
  "Config/Lava.xcconfig": `MARKETING_VERSION = 1.2.1
LAVA_SOURCE_REVISION =
DEVELOPMENT_TEAM =
LAVASEC_APP_PROFILE =
LAVASEC_TUNNEL_PROFILE =
LAVASEC_WIDGET_PROFILE =
LAVASEC_INTENTS_PROFILE =
LAVA_SUPABASE_URL =
LAVA_SUPABASE_ANON_KEY =
LAVA_GOOGLE_IOS_CLIENT_ID =
LAVA_GOOGLE_REVERSED_CLIENT_ID =
LAVA_GOOGLE_SERVER_CLIENT_ID =
#include? "Lava.local.xcconfig"
`,
  "Config/Lava.QA.xcconfig": `#include "Lava.xcconfig"
LAVA_GOOGLE_IOS_CLIENT_ID =
LAVA_GOOGLE_REVERSED_CLIENT_ID =
#include? "Lava.QA.local.xcconfig"
`,
};

function makeBoundaryFixture() {
  const objects = {
    PROJECT: {
      isa: "PBXProject",
      mainGroup: "MAIN_GROUP",
      packageReferences: ["LOCAL_PACKAGE", "REMOTE_PACKAGE"],
      preferredProjectObjectVersion: "77",
      projectDirPath: "",
      projectRoot: "",
      targets: [],
    },
    MAIN_GROUP: { isa: "PBXGroup", children: [], sourceTree: "<group>" },
    LOCAL_PACKAGE: { isa: "XCLocalSwiftPackageReference", relativePath: "." },
    REMOTE_PACKAGE: {
      isa: "XCRemoteSwiftPackageReference",
      repositoryURL: "https://github.com/google/GoogleSignIn-iOS",
      requirement: {
        kind: "upToNextMajorVersion",
        minimumVersion: "9.1.0",
      },
    },
    PROJECT_XCCONFIG: {
      isa: "PBXFileReference",
      path: "Config/Lava.xcconfig",
      sourceTree: "SOURCE_ROOT",
    },
    PROJECT_QA_XCCONFIG: {
      isa: "PBXFileReference",
      path: "Config/Lava.QA.xcconfig",
      sourceTree: "SOURCE_ROOT",
    },
  };
  const expected = { targets: {} };
  const addConfigurationList = (owner, prefix) => {
    const listIdentifier = `CONFIG_LIST_${prefix}`;
    const configurationIdentifiers = ["Debug", "QA", "Release"].map((name) => {
      const identifier = `CONFIG_${prefix}_${name}`;
      objects[identifier] = {
        isa: "XCBuildConfiguration",
        name,
        buildSettings: prefix === "LavaSecTunnel"
          ? { OTHER_LDFLAGS: "$(inherited) -lresolv" }
          : {},
        ...(prefix === "PROJECT"
          ? {
            baseConfigurationReference: name === "QA"
              ? "PROJECT_QA_XCCONFIG"
              : "PROJECT_XCCONFIG",
          }
          : {}),
      };
      return identifier;
    });
    objects[listIdentifier] = {
      isa: "XCConfigurationList",
      defaultConfigurationIsVisible: "0",
      defaultConfigurationName: "Release",
      buildConfigurations: configurationIdentifiers,
    };
    owner.buildConfigurationList = listIdentifier;
  };
  addConfigurationList(objects.PROJECT, "PROJECT");
  const targetIdentifiers = new Map(
    [...policies.keys()].map((name) => [name, `TARGET_${name}`]),
  );

  for (const [name, [productType, products]] of policies) {
    const targetIdentifier = targetIdentifiers.get(name);
    const sourcePhase = `SOURCES_${name}`;
    const frameworkPhase = `FRAMEWORKS_${name}`;
    const sourceReference = `SOURCE_REF_${name}`;
    const sourceBuildFile = `SOURCE_BUILD_${name}`;
    const sourcePath = `${name}/Main.swift`;
    objects.PROJECT.targets.push(targetIdentifier);
    objects.MAIN_GROUP.children.push(sourceReference);
    objects[sourceReference] = {
      isa: "PBXFileReference",
      path: sourcePath,
      sourceTree: "SOURCE_ROOT",
    };
    objects[sourceBuildFile] = { isa: "PBXBuildFile", fileRef: sourceReference };
    objects[sourcePhase] = {
      isa: "PBXSourcesBuildPhase",
      buildActionMask: "2147483647",
      runOnlyForDeploymentPostprocessing: "0",
      files: [sourceBuildFile],
    };
    objects[frameworkPhase] = {
      isa: "PBXFrameworksBuildPhase",
      buildActionMask: "2147483647",
      runOnlyForDeploymentPostprocessing: "0",
      files: [],
    };
    objects[targetIdentifier] = {
      isa: "PBXNativeTarget",
      name,
      productType,
      buildPhases: [sourcePhase, frameworkPhase],
      buildRules: [],
      dependencies: [],
      packageProductDependencies: [],
    };
    addConfigurationList(objects[targetIdentifier], name);
    expected.targets[name] = [sourcePath];
    for (const productName of products) {
      const productIdentifier = `PRODUCT_${name}_${productName}`;
      const frameworkBuildFile = `FRAMEWORK_${name}_${productName}`;
      objects[productIdentifier] = {
        isa: "XCSwiftPackageProductDependency",
        productName,
        ...(productName === "GoogleSignIn" ? { package: "REMOTE_PACKAGE" } : {}),
      };
      objects[frameworkBuildFile] = { isa: "PBXBuildFile", productRef: productIdentifier };
      objects[targetIdentifier].packageProductDependencies.push(productIdentifier);
      objects[frameworkPhase].files.push(frameworkBuildFile);
    }
  }

  for (const [name, [, , dependencies]] of policies) {
    for (const dependencyName of dependencies) {
      const dependencyIdentifier = `DEPENDENCY_${name}_${dependencyName}`;
      const proxyIdentifier = `PROXY_${name}_${dependencyName}`;
      objects[proxyIdentifier] = {
        isa: "PBXContainerItemProxy",
        containerPortal: "PROJECT",
        remoteGlobalIDString: targetIdentifiers.get(dependencyName),
        remoteInfo: dependencyName,
        proxyType: "1",
      };
      objects[dependencyIdentifier] = {
        isa: "PBXTargetDependency",
        target: targetIdentifiers.get(dependencyName),
        targetProxy: proxyIdentifier,
      };
      objects[targetIdentifiers.get(name)].dependencies.push(dependencyIdentifier);
    }
  }
  objects.PROJECT.attributes = {
    BuildIndependentTargetsInParallel: "YES",
    LastUpgradeCheck: "2630",
    TargetAttributes: Object.fromEntries(
      [...targetIdentifiers].map(([name, identifier]) => [
        identifier,
        {
          DevelopmentTeam: "$(inherited)",
          ProvisioningStyle: "Automatic",
          ...(name === "LavaSecUITests"
            ? { TestTargetID: targetIdentifiers.get("LavaSec") }
            : {}),
        },
      ]),
    ),
  };
  // The real tunnel target also compiles a C shim, and the app embeds extension products.
  // Neither belongs in the Swift-only manifest boundary emitted by the source checker.
  objects.C_SOURCE = {
    isa: "PBXFileReference",
    path: "LavaSecTunnel/DeviceDNSResolver.c",
    sourceTree: "SOURCE_ROOT",
  };
  objects.C_BUILD = { isa: "PBXBuildFile", fileRef: "C_SOURCE" };
  objects.SOURCES_LavaSecTunnel.files.push("C_BUILD");
  for (const product of ["LavaSecTunnel", "LavaSecWidget", "LavaSecIntents"]) {
    objects[`EMBEDDED_${product}`] = {
      isa: "PBXFileReference",
      path: `${product}.appex`,
      sourceTree: "BUILT_PRODUCTS_DIR",
    };
    objects[`EMBED_BUILD_${product}`] = {
      isa: "PBXBuildFile",
      fileRef: `EMBEDDED_${product}`,
      settings: { ATTRIBUTES: ["RemoveHeadersOnCopy"] },
    };
  }
  objects.EMBED_FOUNDATION_PHASE = {
    isa: "PBXCopyFilesBuildPhase",
    buildActionMask: "2147483647",
    name: "Embed Foundation Extensions",
    dstPath: "",
    dstSubfolderSpec: "13",
    runOnlyForDeploymentPostprocessing: "0",
    files: ["EMBED_BUILD_LavaSecTunnel", "EMBED_BUILD_LavaSecWidget"],
  };
  objects.EMBED_EXTENSIONKIT_PHASE = {
    isa: "PBXCopyFilesBuildPhase",
    buildActionMask: "2147483647",
    name: "Embed ExtensionKit Extensions",
    dstPath: "$(EXTENSIONS_FOLDER_PATH)",
    dstSubfolderSpec: "16",
    runOnlyForDeploymentPostprocessing: "0",
    files: ["EMBED_BUILD_LavaSecIntents"],
  };
  objects.TARGET_LavaSec.buildPhases.push(
    "EMBED_FOUNDATION_PHASE",
    "EMBED_EXTENSIONKIT_PHASE",
  );
  for (const name of ["LavaSec", "LavaSecIntents"]) {
    objects[`RESOURCES_${name}`] = {
      isa: "PBXResourcesBuildPhase",
      buildActionMask: "2147483647",
      runOnlyForDeploymentPostprocessing: "0",
      files: [],
    };
    objects[`TARGET_${name}`].buildPhases.push(`RESOURCES_${name}`);
    for (const [index, resourcePath] of approvedResources.get(name).entries()) {
      const referenceIdentifier = `RESOURCE_REF_${name}_${index}`;
      const buildIdentifier = `RESOURCE_BUILD_${name}_${index}`;
      objects[referenceIdentifier] = {
        isa: "PBXFileReference",
        path: resourcePath,
        sourceTree: "SOURCE_ROOT",
      };
      objects[buildIdentifier] = {
        isa: "PBXBuildFile",
        fileRef: referenceIdentifier,
      };
      objects[`RESOURCES_${name}`].files.push(buildIdentifier);
    }
  }
  return {
    expected,
    project: {
      archiveVersion: "1",
      classes: {},
      objectVersion: "77",
      rootObject: "PROJECT",
      objects,
    },
  };
}

function makeScheme({ appID = "TARGET_LavaSec", uiTestID = "TARGET_LavaSecUITests" } = {}) {
  return `<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2630" version="1.7">
  <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES" runPostActionsOnFailure="NO">
    <BuildActionEntries>
      <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">
        <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="${appID}" BuildableName="LavaSec.app" BlueprintName="LavaSec" ReferencedContainer="container:LavaSec.xcodeproj"></BuildableReference>
      </BuildActionEntry>
    </BuildActionEntries>
  </BuildAction>
  <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.DebuggerFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES" onlyGenerateCoverageForSpecifiedTargets="NO">
    <MacroExpansion>
      <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="${appID}" BuildableName="LavaSec.app" BlueprintName="LavaSec" ReferencedContainer="container:LavaSec.xcodeproj"></BuildableReference>
    </MacroExpansion>
    <Testables>
      <TestableReference skipped="NO" parallelizable="NO">
        <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="${uiTestID}" BuildableName="LavaSecUITests.xctest" BlueprintName="LavaSecUITests" ReferencedContainer="container:LavaSec.xcodeproj"></BuildableReference>
      </TestableReference>
    </Testables>
    <CommandLineArguments></CommandLineArguments>
  </TestAction>
  <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES">
    <BuildableProductRunnable runnableDebuggingMode="0">
      <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="${appID}" BuildableName="LavaSec.app" BlueprintName="LavaSec" ReferencedContainer="container:LavaSec.xcodeproj"></BuildableReference>
    </BuildableProductRunnable>
    <CommandLineArguments></CommandLineArguments>
  </LaunchAction>
  <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES">
    <BuildableProductRunnable runnableDebuggingMode="0">
      <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="${appID}" BuildableName="LavaSec.app" BlueprintName="LavaSec" ReferencedContainer="container:LavaSec.xcodeproj"></BuildableReference>
    </BuildableProductRunnable>
    <CommandLineArguments></CommandLineArguments>
  </ProfileAction>
  <AnalyzeAction buildConfiguration="Debug"></AnalyzeAction>
  <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"></ArchiveAction>
</Scheme>`;
}

test("accepts the exact generated target, source, package, and dependency graph", () => {
  const fixture = makeBoundaryFixture();
  const identifiers = validateGeneratedProject(fixture.project, fixture.expected);
  assert.doesNotThrow(() => validateGeneratedSchemes({
    "LavaSec.xcscheme": makeScheme(),
  }, identifiers));
});

test("rejects project-file envelope and preferred-object-version drift", () => {
  for (const [name, mutate, expected] of [
    [
      "archive version",
      (fixture) => { fixture.project.archiveVersion = "2"; },
      /project-file envelope differs from policy/,
    ],
    [
      "classes mapping",
      (fixture) => { fixture.project.classes = { Injected: {} }; },
      /project-file envelope differs from policy/,
    ],
    [
      "object version",
      (fixture) => { fixture.project.objectVersion = "90"; },
      /project-file envelope differs from policy/,
    ],
    [
      "unknown top-level field",
      (fixture) => { fixture.project.injected = true; },
      /project-file envelope fields differ from policy/,
    ],
    [
      "preferred project object version",
      (fixture) => {
        fixture.project.objects.PROJECT.preferredProjectObjectVersion = "90";
      },
      /root project preferred object version differs from policy/,
    ],
  ]) {
    const fixture = makeBoundaryFixture();
    mutate(fixture);

    assert.throws(
      () => validateGeneratedProject(fixture.project, fixture.expected),
      expected,
      name,
    );
  }
});

test("rejects generated debugger artifacts outside the exact project file set", (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "lavasec-generated-project-files-"));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  for (const directory of [
    "project.xcworkspace/xcshareddata/swiftpm",
    "xcshareddata/xcschemes",
  ]) {
    fs.mkdirSync(path.join(root, directory), { recursive: true });
  }
  for (const file of [
    "project.pbxproj",
    "project.xcworkspace/contents.xcworkspacedata",
    "project.xcworkspace/xcshareddata/swiftpm/Package.resolved",
    "xcshareddata/xcschemes/LavaSec.xcscheme",
  ]) {
    fs.writeFileSync(path.join(root, file), "fixture\n");
  }

  assert.doesNotThrow(() => generatedBoundary.validateGeneratedProjectFilesystem(root));

  fs.mkdirSync(path.join(root, "xcshareddata", "xcdebugger"));
  fs.writeFileSync(
    path.join(root, "xcshareddata", "xcdebugger", "Breakpoints_v2.xcbkptlist"),
    '<BreakpointActionProxy ActionExtensionID="Xcode.BreakpointAction.ShellCommand"/>\n',
  );

  assert.throws(
    () => generatedBoundary.validateGeneratedProjectFilesystem(root),
    /generated project file set differs from policy[\s\S]*xcdebugger/,
  );
});

test("rejects executable and non-native generated targets", () => {
  const fixture = makeBoundaryFixture();
  fixture.project.objects.ESCAPE = { isa: "PBXAggregateTarget", name: "Escape" };
  fixture.project.objects.PROJECT.targets.push("ESCAPE");

  assert.throws(
    () => validateGeneratedProject(fixture.project, fixture.expected),
    /forbidden object kind PBXAggregateTarget/,
  );
});

test("rejects duplicate build-configuration names before Xcode can select the first", () => {
  const fixture = makeBoundaryFixture();
  fixture.project.objects.CONFIG_LavaSec_DebugInjected = {
    ...fixture.project.objects.CONFIG_LavaSec_Debug,
    buildSettings: {
      SWIFT_EXEC: "$(SRCROOT)/Payloads/InjectedCompiler",
    },
  };
  fixture.project.objects.CONFIG_LIST_LavaSec.buildConfigurations.unshift(
    "CONFIG_LavaSec_DebugInjected",
  );

  assert.throws(
    () => validateGeneratedProject(fixture.project, fixture.expected),
    /LavaSec configurations must be exactly Debug, QA, and Release/,
  );
});

test("rejects executable tool overrides in build configurations", () => {
  const fixture = makeBoundaryFixture();
  fixture.project.objects.CONFIG_LavaSec_Debug.buildSettings.SWIFT_EXEC =
    "$(SRCROOT)/Payloads/InjectedCompiler";

  assert.throws(
    () => validateGeneratedProject(fixture.project, fixture.expected),
    /LavaSec Debug build settings contain unapproved keys: SWIFT_EXEC/,
  );
});

test("rejects modified linker flags on the one target allowed to define them", () => {
  const fixture = makeBoundaryFixture();
  fixture.project.objects.CONFIG_LavaSecTunnel_Debug.buildSettings.OTHER_LDFLAGS =
    "$(inherited) -lresolv -Wl,-alias,_main,_injected";

  assert.throws(
    () => validateGeneratedProject(fixture.project, fixture.expected),
    /LavaSecTunnel Debug build setting OTHER_LDFLAGS differs from policy/,
  );
});

test("rejects redirected base configuration files", () => {
  const fixture = makeBoundaryFixture();
  fixture.project.objects.INJECTED_XCCONFIG = {
    isa: "PBXFileReference",
    path: "Payloads/Injected.xcconfig",
    sourceTree: "SOURCE_ROOT",
  };
  fixture.project.objects.CONFIG_PROJECT_Debug.baseConfigurationReference =
    "INJECTED_XCCONFIG";

  assert.throws(
    () => validateGeneratedProject(fixture.project, fixture.expected),
    /project Debug base configuration differs from policy/,
  );
});

test("rejects file references with ambiguous group parents", () => {
  const fixture = makeBoundaryFixture();
  fixture.project.objects.PROJECT_XCCONFIG.path = "Lava.xcconfig";
  fixture.project.objects.PROJECT_XCCONFIG.sourceTree = "<group>";
  fixture.project.objects.PAYLOAD_CONFIG_GROUP = {
    isa: "PBXGroup",
    path: "Payloads",
    sourceTree: "<group>",
    children: ["PROJECT_XCCONFIG"],
  };
  fixture.project.objects.APPROVED_CONFIG_GROUP = {
    isa: "PBXGroup",
    path: "Config",
    sourceTree: "<group>",
    children: ["PROJECT_XCCONFIG"],
  };
  fixture.project.objects.MAIN_GROUP.children.push(
    "APPROVED_CONFIG_GROUP",
    "PAYLOAD_CONFIG_GROUP",
  );

  assert.throws(
    () => validateGeneratedProject(fixture.project, fixture.expected),
    /object PROJECT_XCCONFIG has multiple group parents/,
  );
});

test("rejects group-relative references outside the main group tree", () => {
  const fixture = makeBoundaryFixture();
  fixture.project.objects.PROJECT_XCCONFIG.path = "Lava.xcconfig";
  fixture.project.objects.PROJECT_XCCONFIG.sourceTree = "<group>";
  fixture.project.objects.UNREACHABLE_CONFIG_GROUP = {
    isa: "PBXGroup",
    path: "Config",
    sourceTree: "<group>",
    children: ["PROJECT_XCCONFIG"],
  };

  assert.throws(
    () => validateGeneratedProject(fixture.project, fixture.expected),
    /file reference PROJECT_XCCONFIG is not anchored to the main group or SOURCE_ROOT/,
  );

  const sourceRootGroupFixture = makeBoundaryFixture();
  sourceRootGroupFixture.project.objects.PROJECT_XCCONFIG.path = "Lava.xcconfig";
  sourceRootGroupFixture.project.objects.PROJECT_XCCONFIG.sourceTree = "<group>";
  sourceRootGroupFixture.project.objects.UNREACHABLE_CONFIG_GROUP = {
    isa: "PBXGroup",
    path: "Config",
    sourceTree: "SOURCE_ROOT",
    children: ["PROJECT_XCCONFIG"],
  };
  assert.throws(
    () => validateGeneratedProject(
      sourceRootGroupFixture.project,
      sourceRootGroupFixture.expected,
    ),
    /file reference PROJECT_XCCONFIG is not anchored to the main group or SOURCE_ROOT/,
  );
});

test("rejects project source-root redirection", () => {
  const directoryFixture = makeBoundaryFixture();
  directoryFixture.project.objects.PROJECT.projectDirPath = "Payloads";
  assert.throws(
    () => validateGeneratedProject(directoryFixture.project, directoryFixture.expected),
    /root project path fields differ from policy/,
  );

  const rootFixture = makeBoundaryFixture();
  rootFixture.project.objects.PROJECT.projectRoot = "Payloads";
  assert.throws(
    () => validateGeneratedProject(rootFixture.project, rootFixture.expected),
    /root project path fields differ from policy/,
  );
});

test("rejects unsupported root-project fields and target attributes", () => {
  const fieldFixture = makeBoundaryFixture();
  fieldFixture.project.objects.PROJECT.projectReferences = [];
  assert.throws(
    () => validateGeneratedProject(fieldFixture.project, fieldFixture.expected),
    /root project contains unsupported fields: projectReferences/,
  );

  const attributeFixture = makeBoundaryFixture();
  attributeFixture.project.objects.PROJECT.attributes.TargetAttributes
    .TARGET_LavaSec.SystemCapabilities = { "com.apple.Push": { enabled: "1" } };
  assert.throws(
    () => validateGeneratedProject(attributeFixture.project, attributeFixture.expected),
    /root project attributes differ from policy/,
  );
});

test("rejects executable assignments and unapproved includes in tracked xcconfigs", () => {
  const directInjection = {
    ...trackedXCConfigs,
    "Config/Lava.xcconfig": `${trackedXCConfigs["Config/Lava.xcconfig"]}SWIFT_EXEC = $(SRCROOT)/Payloads/InjectedCompiler\n`,
  };
  assert.throws(
    () => generatedBoundary.validateTrackedXCConfigs(directInjection),
    /Config\/Lava\.xcconfig contains unapproved setting SWIFT_EXEC/,
  );

  const includedInjection = {
    ...trackedXCConfigs,
    "Config/Lava.xcconfig": trackedXCConfigs["Config/Lava.xcconfig"].replace(
      '#include? "Lava.local.xcconfig"',
      '#include "Injected.xcconfig"',
    ),
    "Config/Injected.xcconfig": "SWIFT_EXEC = $(SRCROOT)/Payloads/InjectedCompiler\n",
  };
  assert.throws(
    () => generatedBoundary.validateTrackedXCConfigs(includedInjection),
    /Config\/Lava\.xcconfig include graph differs from policy/,
  );
});

test("rejects xcconfig line separators that Xcode interprets differently", () => {
  for (const [name, separator] of [
    ["lone CR", "\r"],
    ["Unicode line separator", "\u2028"],
    ["Unicode paragraph separator", "\u2029"],
  ]) {
    const injected = {
      ...trackedXCConfigs,
      "Config/Lava.xcconfig": `${trackedXCConfigs["Config/Lava.xcconfig"]}// approved comment${separator}SWIFT_EXEC = $(SRCROOT)/Payloads/InjectedCompiler\n`,
    };
    assert.throws(
      () => generatedBoundary.validateTrackedXCConfigs(injected),
      /Config\/Lava\.xcconfig contains an unsupported line separator/,
      name,
    );
  }
});

test("accepts the exact tracked xcconfig policy and rejects missing assignments", () => {
  assert.doesNotThrow(
    () => generatedBoundary.validateTrackedXCConfigs(trackedXCConfigs),
  );

  const missingAssignment = {
    ...trackedXCConfigs,
    "Config/Lava.xcconfig": trackedXCConfigs["Config/Lava.xcconfig"].replace(
      "LAVA_SOURCE_REVISION =\n",
      "",
    ),
  };
  assert.throws(
    () => generatedBoundary.validateTrackedXCConfigs(missingAssignment),
    /Config\/Lava\.xcconfig setting set differs from policy/,
  );
});

test("rejects optional local xcconfigs when they become tracked", () => {
  assert.throws(
    () => generatedBoundary.validateTrackedXCConfigs(
      trackedXCConfigs,
      ["Config/Lava.local.xcconfig"],
    ),
    /optional xcconfig must remain untracked: Config\/Lava\.local\.xcconfig/,
  );
  assert.throws(
    () => generatedBoundary.validateTrackedXCConfigs(
      trackedXCConfigs,
      ["Config/lava.local.xcconfig"],
    ),
    /optional xcconfig must remain untracked: Config\/lava\.local\.xcconfig/,
  );
  assert.throws(
    () => generatedBoundary.validateTrackedXCConfigs(
      trackedXCConfigs,
      ["config/lava.local.xcconfig"],
    ),
    /optional xcconfig must remain untracked: config\/lava\.local\.xcconfig/,
  );
});

test("enumerates tracked paths without a case-sensitive directory scope", () => {
  const source = fs.readFileSync(boundaryCheckerPath, "utf8");
  assert.match(source, /\["ls-files", "-z"\]/);
});

test("rejects symlinked tracked xcconfig directories and files", (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "lavasec-xcconfig-paths-"));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  fs.mkdirSync(path.join(root, "Payloads"));
  fs.writeFileSync(
    path.join(root, "Payloads", "Lava.xcconfig"),
    trackedXCConfigs["Config/Lava.xcconfig"],
  );
  fs.writeFileSync(
    path.join(root, "Payloads", "Lava.QA.xcconfig"),
    trackedXCConfigs["Config/Lava.QA.xcconfig"],
  );
  fs.symlinkSync("Payloads", path.join(root, "Config"));

  assert.throws(
    () => generatedBoundary.validateTrackedXCConfigFilesystem(root),
    /Config must be a real directory/,
  );

  fs.rmSync(path.join(root, "Config"));
  fs.mkdirSync(path.join(root, "Config"));
  fs.symlinkSync(
    path.join("..", "Payloads", "Lava.xcconfig"),
    path.join(root, "Config", "Lava.xcconfig"),
  );
  fs.writeFileSync(
    path.join(root, "Config", "Lava.QA.xcconfig"),
    trackedXCConfigs["Config/Lava.QA.xcconfig"],
  );
  assert.throws(
    () => generatedBoundary.validateTrackedXCConfigFilesystem(root),
    /Config\/Lava\.xcconfig must be a regular file/,
  );
});

test("rejects Xcode synchronized folders with implicit source membership", () => {
  const fixture = makeBoundaryFixture();
  fixture.project.objects.SYNCHRONIZED_PAYLOAD = {
    isa: "PBXFileSystemSynchronizedRootGroup",
    path: "Payload",
    sourceTree: "<group>",
  };
  fixture.project.objects.TARGET_LavaSec.fileSystemSynchronizedGroups = [
    "SYNCHRONIZED_PAYLOAD",
  ];

  assert.throws(
    () => validateGeneratedProject(fixture.project, fixture.expected),
    /forbidden object kind PBXFileSystemSynchronizedRootGroup[\s\S]*unsupported target fields: fileSystemSynchronizedGroups/,
  );
});

test("rejects shell phases and build rules anywhere in the generated graph", () => {
  const fixture = makeBoundaryFixture();
  fixture.project.objects.SHELL = { isa: "PBXShellScriptBuildPhase", files: [] };
  fixture.project.objects.RULE = { isa: "PBXBuildRule" };

  assert.throws(
    () => validateGeneratedProject(fixture.project, fixture.expected),
    /PBXShellScriptBuildPhase[\s\S]*PBXBuildRule/,
  );
});

test("rejects generated source membership that differs from the direct manifest", () => {
  const fixture = makeBoundaryFixture();
  fixture.expected.targets.LavaSec.push("LavaSecApp/Missing.swift");

  assert.throws(
    () => validateGeneratedProject(fixture.project, fixture.expected),
    /LavaSec compiled source membership differs from policy/,
  );
});

test("rejects unapproved non-Swift compiled source membership", () => {
  const fixture = makeBoundaryFixture();
  fixture.project.objects.INJECTED_SOURCE = {
    isa: "PBXFileReference",
    path: "Payloads/Injected.m",
    sourceTree: "SOURCE_ROOT",
  };
  fixture.project.objects.INJECTED_BUILD = {
    isa: "PBXBuildFile",
    fileRef: "INJECTED_SOURCE",
  };
  fixture.project.objects.SOURCES_LavaSec.files.push("INJECTED_BUILD");

  assert.throws(
    () => validateGeneratedProject(fixture.project, fixture.expected),
    /LavaSec compiled source membership differs from policy/,
  );
});

test("rejects per-file compiler settings on approved source membership", () => {
  const fixture = makeBoundaryFixture();
  fixture.project.objects.C_BUILD.settings = {
    COMPILER_FLAGS: "-include Payloads/Injected.h",
  };

  assert.throws(
    () => validateGeneratedProject(fixture.project, fixture.expected),
    /LavaSecTunnel sources contains execution-affecting build-file fields: settings/,
  );
});

test("rejects Swift files assigned to a non-source phase", () => {
  const fixture = makeBoundaryFixture();
  fixture.project.objects.RESOURCES = {
    isa: "PBXResourcesBuildPhase",
    files: ["SOURCE_BUILD_LavaSec"],
  };
  fixture.project.objects.TARGET_LavaSec.buildPhases.push("RESOURCES");

  assert.throws(
    () => validateGeneratedProject(fixture.project, fixture.expected),
    /places Swift outside PBXSourcesBuildPhase/,
  );
});

test("rejects unapproved resource membership", () => {
  const fixture = makeBoundaryFixture();
  fixture.project.objects.INJECTED_RESOURCE = {
    isa: "PBXFileReference",
    path: "LavaSecApp/InjectedPayload.json",
    sourceTree: "SOURCE_ROOT",
  };
  fixture.project.objects.INJECTED_RESOURCE_BUILD = {
    isa: "PBXBuildFile",
    fileRef: "INJECTED_RESOURCE",
  };
  fixture.project.objects.RESOURCES_LavaSec.files.push("INJECTED_RESOURCE_BUILD");

  assert.throws(
    () => validateGeneratedProject(fixture.project, fixture.expected),
    /LavaSec resource membership differs from policy/,
  );
});

test("rejects resource build-file settings, wrong-target membership, and duplicates", () => {
  const settingsFixture = makeBoundaryFixture();
  settingsFixture.project.objects.RESOURCE_BUILD_LavaSec_0.settings = {
    ASSET_TAGS: ["Injected"],
  };
  assert.throws(
    () => validateGeneratedProject(settingsFixture.project, settingsFixture.expected),
    /LavaSec resources contains execution-affecting build-file fields: settings/,
  );

  const wrongTargetFixture = makeBoundaryFixture();
  wrongTargetFixture.project.objects.RESOURCES_LavaSecIntents.files.push(
    "RESOURCE_BUILD_LavaSec_0",
  );
  assert.throws(
    () => validateGeneratedProject(wrongTargetFixture.project, wrongTargetFixture.expected),
    /LavaSecIntents resource membership differs from policy/,
  );

  const duplicateFixture = makeBoundaryFixture();
  duplicateFixture.project.objects.RESOURCES_LavaSec.files.push(
    "RESOURCE_BUILD_LavaSec_0",
  );
  assert.throws(
    () => validateGeneratedProject(duplicateFixture.project, duplicateFixture.expected),
    /LavaSec contains duplicate resource membership/,
  );
});

test("rejects unapproved package products even when the framework phase also links them", () => {
  const fixture = makeBoundaryFixture();
  fixture.project.objects.PRODUCT_ESCAPE = {
    isa: "XCSwiftPackageProductDependency",
    productName: "plugin:LavaSecCore",
  };
  fixture.project.objects.FRAMEWORK_ESCAPE = {
    isa: "PBXBuildFile",
    productRef: "PRODUCT_ESCAPE",
  };
  fixture.project.objects.TARGET_LavaSec.packageProductDependencies.push("PRODUCT_ESCAPE");
  fixture.project.objects.FRAMEWORKS_LavaSec.files.push("FRAMEWORK_ESCAPE");

  assert.throws(
    () => validateGeneratedProject(fixture.project, fixture.expected),
    /linked package products differ from policy[\s\S]*package product dependencies differ from policy/,
  );
});

test("rejects arbitrary payloads and attributes in copy phases", () => {
  const fixture = makeBoundaryFixture();
  fixture.project.objects.INJECTED_PAYLOAD = {
    isa: "PBXFileReference",
    path: "Payloads/Injected.appex",
    sourceTree: "SOURCE_ROOT",
  };
  fixture.project.objects.INJECTED_COPY = {
    isa: "PBXBuildFile",
    fileRef: "INJECTED_PAYLOAD",
    settings: { ATTRIBUTES: ["CodeSignOnCopy"] },
  };
  fixture.project.objects.EMBED_FOUNDATION_PHASE.files.push("INJECTED_COPY");

  assert.throws(
    () => validateGeneratedProject(fixture.project, fixture.expected),
    /LavaSec copy phase contains an unsupported copy entry/,
  );

  const attributeFixture = makeBoundaryFixture();
  attributeFixture.project.objects.EMBED_BUILD_LavaSecWidget.settings.ATTRIBUTES = [
    "CodeSignOnCopy",
  ];
  assert.throws(
    () => validateGeneratedProject(attributeFixture.project, attributeFixture.expected),
    /LavaSec copy phases differ from policy/,
  );

  const maskFixture = makeBoundaryFixture();
  maskFixture.project.objects.EMBED_FOUNDATION_PHASE.buildActionMask = "0";
  assert.throws(
    () => validateGeneratedProject(maskFixture.project, maskFixture.expected),
    /LavaSec copy phases differ from policy/,
  );

  const filterFixture = makeBoundaryFixture();
  filterFixture.project.objects.EMBED_BUILD_LavaSecWidget.platformFilter = "macos";
  assert.throws(
    () => validateGeneratedProject(filterFixture.project, filterFixture.expected),
    /LavaSec copy phase contains execution-affecting build-file fields: platformFilter/,
  );
});

test("rejects local package identity replacement", () => {
  const fixture = makeBoundaryFixture();
  fixture.project.objects.LOCAL_PACKAGE.relativePath = "Evil/LavaSecPackage";

  assert.throws(
    () => validateGeneratedProject(fixture.project, fixture.expected),
    /exactly one repo-root local package reference/,
  );
});

test("rejects an unpinned remote package requirement", () => {
  const fixture = makeBoundaryFixture();
  fixture.project.objects.REMOTE_PACKAGE.requirement = {
    kind: "branch",
    branch: "attacker-controlled",
  };

  assert.throws(
    () => validateGeneratedProject(fixture.project, fixture.expected),
    /approved GoogleSignIn requirement/,
  );
});

test("rejects malformed dependencies and orphan same-name target clones", () => {
  const fixture = makeBoundaryFixture();
  fixture.project.objects.ORPHAN = {
    ...fixture.project.objects.TARGET_LavaSecWidget,
  };
  fixture.project.objects.DEPENDENCY_LavaSec_LavaSecWidget = {
    isa: "PBXContainerItemProxy",
    target: "ORPHAN",
  };

  assert.throws(
    () => validateGeneratedProject(fixture.project, fixture.expected),
    /must be a PBXTargetDependency[\s\S]*non-canonical target object/,
  );

  const filterFixture = makeBoundaryFixture();
  filterFixture.project.objects.DEPENDENCY_LavaSec_LavaSecWidget.platformFilter = "macos";
  assert.throws(
    () => validateGeneratedProject(filterFixture.project, filterFixture.expected),
    /LavaSec dependency DEPENDENCY_LavaSec_LavaSecWidget fields differ from policy/,
  );
});

test("rejects scheme execution actions and extra shared schemes", () => {
  assert.throws(
    () => validateGeneratedSchemes({
      "LavaSec.xcscheme": "<Scheme><BuildAction><PreActions><ExecutionAction scriptText=\"echo hacked\"/></PreActions></BuildAction></Scheme>",
    }),
    /contains an executable scheme action/,
  );
  assert.throws(
    () => validateGeneratedSchemes({
      "Escape.xcscheme": "<Scheme/>",
      "LavaSec.xcscheme": "<Scheme/>",
    }),
    /shared scheme set is not approved/,
  );
});

test("rejects empty schemes and schemes redirected away from canonical targets", () => {
  const fixture = makeBoundaryFixture();
  const identifiers = validateGeneratedProject(fixture.project, fixture.expected);
  assert.throws(
    () => validateGeneratedSchemes({
      "LavaSec.xcscheme": '<Scheme LastUpgradeVersion="2630" version="1.7"></Scheme>',
    }, identifiers),
    /must contain exactly one (?:Analyze|Archive|Build|Launch|Profile|Test)Action/,
  );
  assert.throws(
    () => validateGeneratedSchemes({
      "LavaSec.xcscheme": makeScheme({ appID: "TARGET_LavaSecWidget" }),
    }, identifiers),
    /BuildAction must reference canonical LavaSec target/,
  );
});

test("rejects scheme command-line argument injection", () => {
  const fixture = makeBoundaryFixture();
  const identifiers = validateGeneratedProject(fixture.project, fixture.expected);
  const injected = makeScheme().replace(
    "<CommandLineArguments></CommandLineArguments>",
    '<CommandLineArguments><CommandLineArgument argument="-Injected" isEnabled="YES"></CommandLineArgument></CommandLineArguments>',
  );

  assert.throws(
    () => validateGeneratedSchemes({ "LavaSec.xcscheme": injected }, identifiers),
    /CommandLineArguments contains unsupported element CommandLineArgument/,
  );
});

test("rejects executable debugger-init attributes in shared schemes", () => {
  const fixture = makeBoundaryFixture();
  const identifiers = validateGeneratedProject(fixture.project, fixture.expected);
  const injected = makeScheme().replace(
    "<LaunchAction ",
    '<LaunchAction customLLDBInitFile="$(SRCROOT)/Payloads/Injected.lldb" ',
  );

  assert.throws(
    () => validateGeneratedSchemes({ "LavaSec.xcscheme": injected }, identifiers),
    /LaunchAction attributes differ from policy/,
  );
});

test("drift integration validates raw, post-generated, and committed project trees", () => {
  const source = fs.readFileSync(driftCheckerPath, "utf8");
  assert.equal(
    source.match(/check-xcodegen-generated-boundary\.mjs/g)?.length,
    3,
    "raw, post-generated, and committed projects must cross the authoritative boundary",
  );
  assert.match(source, /"\$tmp\/committed\.json"/);
  assert.match(source, /"\$tmp\/raw\.xcodeproj"/);
  assert.match(source, /"\$tmp\/generated\.xcodeproj"/);
  assert.match(source, /"\$tmp\/committed\.xcodeproj"/);
});

test("drift integration arms temporary cleanup before allocation can fail", () => {
  const source = fs.readFileSync(driftCheckerPath, "utf8");
  const emptyTmpIndex = source.indexOf('tmp=""');
  const mktempIndex = source.indexOf("tmp=$(mktemp -d)");
  const cleanupTrapIndex = source.indexOf("trap cleanup_tmp EXIT");
  const firstBackupIndex = source.indexOf("cp -R LavaSec.xcodeproj");
  const restoreTrapIndex = source.indexOf("trap restore EXIT");

  assert.ok(emptyTmpIndex >= 0);
  assert.ok(mktempIndex >= 0);
  assert.ok(emptyTmpIndex < cleanupTrapIndex);
  assert.ok(cleanupTrapIndex < mktempIndex);
  assert.ok(cleanupTrapIndex < firstBackupIndex);
  assert.ok(firstBackupIndex < restoreTrapIndex);
});

test("light-build provisions Node before running the XcodeGen drift check", (context) => {
  if (skipMissingInternalWorkflow(
    context,
    lightBuildWorkflowPath,
    "light-build is internal-only and intentionally absent from public exports",
  )) {
    return;
  }

  const source = fs.readFileSync(lightBuildWorkflowPath, "utf8");
  const setupNodeIndex = source.indexOf("uses: actions/setup-node@v6");
  const driftCheckIndex = source.indexOf("scripts/check-xcodegen-drift.sh");

  assert.ok(setupNodeIndex >= 0, "light-build must install Node on self-hosted runners");
  assert.ok(
    setupNodeIndex < driftCheckIndex,
    "light-build must install Node before invoking the drift checker",
  );
  assert.match(source.slice(setupNodeIndex, driftCheckIndex), /node-version: ["']24["']/);
});

test("internal promotion runs guardrail fixtures inside the exported public tree", (context) => {
  if (skipMissingInternalWorkflow(
    context,
    internalPromotionWorkflowPath,
    "internal promotion is intentionally absent from public exports",
  )) {
    return;
  }

  const source = fs.readFileSync(internalPromotionWorkflowPath, "utf8");
  const exportIndex = source.indexOf("scripts/export-public-source.sh --check");
  const fixtureIndex = source.indexOf("- name: Test public-source guardrail fixtures");

  assert.ok(exportIndex >= 0, "internal promotion must build the public export first");
  assert.ok(fixtureIndex > exportIndex, "exported fixtures must run after export readiness");
  assert.match(
    source.slice(fixtureIndex),
    /env:\n\s+LAVASEC_PUBLIC_EXPORT: ["']1["']\n\s+working-directory: build\/public-source\n\s+run: node --test scripts\/tests\/\*\.test\.mjs/,
  );
});
