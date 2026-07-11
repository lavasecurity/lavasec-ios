#!/usr/bin/env node
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const targetPolicy = new Map([
  [
    "LavaSec",
    {
      productType: "com.apple.product-type.application",
      packageProducts: [
        "GoogleSignIn",
        "LavaSecAppServices",
        "LavaSecDNS",
        "LavaSecFilterPipeline",
        "LavaSecKit",
        "LavaSecNetworking",
        "LavaSecPresentation",
      ],
      additionalCompiledSources: [],
      resources: [
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
      copyPhases: [
        {
          buildActionMask: "2147483647",
          name: "Embed ExtensionKit Extensions",
          dstPath: "$(EXTENSIONS_FOLDER_PATH)",
          dstSubfolderSpec: "16",
          runOnlyForDeploymentPostprocessing: "0",
          entries: [
            {
              path: "LavaSecIntents.appex",
              attributes: ["RemoveHeadersOnCopy"],
            },
          ],
        },
        {
          buildActionMask: "2147483647",
          name: "Embed Foundation Extensions",
          dstPath: "",
          dstSubfolderSpec: "13",
          runOnlyForDeploymentPostprocessing: "0",
          entries: [
            {
              path: "LavaSecTunnel.appex",
              attributes: ["RemoveHeadersOnCopy"],
            },
            {
              path: "LavaSecWidget.appex",
              attributes: ["RemoveHeadersOnCopy"],
            },
          ],
        },
      ],
      targetDependencies: ["LavaSecIntents", "LavaSecTunnel", "LavaSecWidget"],
    },
  ],
  [
    "LavaSecTunnel",
    {
      productType: "com.apple.product-type.app-extension",
      packageProducts: [
        "LavaSecDNS",
        "LavaSecFilterPipeline",
        "LavaSecKit",
        "LavaSecNetworking",
      ],
      additionalCompiledSources: ["LavaSecTunnel/DeviceDNSResolver.c"],
      resources: [],
      copyPhases: [],
      targetDependencies: [],
    },
  ],
  [
    "LavaSecWidget",
    {
      productType: "com.apple.product-type.app-extension",
      packageProducts: ["LavaSecKit", "LavaSecPresentation"],
      additionalCompiledSources: [],
      resources: [],
      copyPhases: [],
      targetDependencies: [],
    },
  ],
  [
    "LavaSecIntents",
    {
      productType: "com.apple.product-type.extensionkit-extension",
      packageProducts: ["LavaSecFilterPipeline", "LavaSecKit"],
      additionalCompiledSources: [],
      resources: ["LavaSecIntents/Localizable.xcstrings"],
      copyPhases: [],
      targetDependencies: [],
    },
  ],
  [
    "LavaSecUITests",
    {
      productType: "com.apple.product-type.bundle.ui-testing",
      packageProducts: ["LavaSecCore"],
      additionalCompiledSources: [],
      resources: [],
      copyPhases: [],
      targetDependencies: ["LavaSec"],
    },
  ],
]);

const allowedBuildPhaseKinds = new Set([
  "PBXCopyFilesBuildPhase",
  "PBXFrameworksBuildPhase",
  "PBXResourcesBuildPhase",
  "PBXSourcesBuildPhase",
]);
const forbiddenObjectKinds = new Set([
  "PBXAggregateTarget",
  "PBXBuildRule",
  "PBXLegacyTarget",
  "PBXShellScriptBuildPhase",
]);
const remotePackageURL = "https://github.com/google/GoogleSignIn-iOS";
const remotePackageRequirement = {
  kind: "upToNextMajorVersion",
  minimumVersion: "9.1.0",
};
// project.yml is input to this guard, not its policy source. Keep approved setting
// keys and executable flag-bearing values here so manifest edits cannot approve themselves.
const commonTargetBuildSettingKeys = [
  "CODE_SIGN_STYLE",
  "CURRENT_PROJECT_VERSION",
  "DEVELOPMENT_TEAM",
  "IPHONEOS_DEPLOYMENT_TARGET",
  "MARKETING_VERSION",
  "PRODUCT_BUNDLE_IDENTIFIER",
  "PRODUCT_NAME",
  "SWIFT_ACTIVE_COMPILATION_CONDITIONS",
  "SWIFT_VERSION",
];
const approvedBuildSettingKeys = new Map([
  [
    "project",
    new Set([
      "ALWAYS_SEARCH_USER_PATHS",
      "CLANG_ANALYZER_NONNULL",
      "CLANG_ENABLE_MODULES",
      "CLANG_ENABLE_OBJC_ARC",
      "CLANG_WARN_BLOCK_CAPTURE_AUTORELEASING",
      "CLANG_WARN_BOOL_CONVERSION",
      "CLANG_WARN_COMMA",
      "CLANG_WARN_CONSTANT_CONVERSION",
      "CLANG_WARN_DEPRECATED_OBJC_IMPLEMENTATIONS",
      "CLANG_WARN_DIRECT_OBJC_ISA_USAGE",
      "CLANG_WARN_DOCUMENTATION_COMMENTS",
      "CLANG_WARN_EMPTY_BODY",
      "CLANG_WARN_ENUM_CONVERSION",
      "CLANG_WARN_INFINITE_RECURSION",
      "CLANG_WARN_INT_CONVERSION",
      "CLANG_WARN_NON_LITERAL_NULL_CONVERSION",
      "CLANG_WARN_OBJC_IMPLICIT_RETAIN_SELF",
      "CLANG_WARN_OBJC_LITERAL_CONVERSION",
      "CLANG_WARN_OBJC_ROOT_CLASS",
      "CLANG_WARN_QUOTED_INCLUDE_IN_FRAMEWORK_HEADER",
      "CLANG_WARN_RANGE_LOOP_ANALYSIS",
      "CLANG_WARN_STRICT_PROTOTYPES",
      "CLANG_WARN_SUSPICIOUS_MOVE",
      "CLANG_WARN_UNGUARDED_AVAILABILITY",
      "CLANG_WARN_UNREACHABLE_CODE",
      "CLANG_WARN__DUPLICATE_METHOD_MATCH",
      "COPY_PHASE_STRIP",
      "DEBUG_INFORMATION_FORMAT",
      "ENABLE_NS_ASSERTIONS",
      "ENABLE_STRICT_OBJC_MSGSEND",
      "ENABLE_TESTABILITY",
      "GCC_C_LANGUAGE_STANDARD",
      "GCC_DYNAMIC_NO_PIC",
      "GCC_NO_COMMON_BLOCKS",
      "GCC_OPTIMIZATION_LEVEL",
      "GCC_PREPROCESSOR_DEFINITIONS",
      "GCC_WARN_64_TO_32_BIT_CONVERSION",
      "GCC_WARN_ABOUT_RETURN_TYPE",
      "GCC_WARN_UNDECLARED_SELECTOR",
      "GCC_WARN_UNINITIALIZED_AUTOS",
      "GCC_WARN_UNUSED_FUNCTION",
      "GCC_WARN_UNUSED_VARIABLE",
      "IPHONEOS_DEPLOYMENT_TARGET",
      "MTL_ENABLE_DEBUG_INFO",
      "ONLY_ACTIVE_ARCH",
      "SDKROOT",
      "SWIFT_ACTIVE_COMPILATION_CONDITIONS",
      "SWIFT_COMPILATION_MODE",
      "SWIFT_EMIT_CONST_VALUE_PROTOCOLS",
      "SWIFT_OPTIMIZATION_LEVEL",
      "SWIFT_VERSION",
      "VALIDATE_PRODUCT",
    ]),
  ],
  [
    "LavaSec",
    new Set([
      ...commonTargetBuildSettingKeys,
      "ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES",
      "ASSETCATALOG_COMPILER_APPICON_NAME",
      "ASSETCATALOG_COMPILER_INCLUDE_ALL_APPICON_ASSETS",
      "CODE_SIGN_ENTITLEMENTS",
      "GENERATE_INFOPLIST_FILE",
      "INFOPLIST_FILE",
      "LAVA_DISPLAY_NAME",
      "LAVA_GOOGLE_IOS_CLIENT_ID",
      "LAVA_GOOGLE_REVERSED_CLIENT_ID",
      "LAVA_GOOGLE_SERVER_CLIENT_ID",
      "LAVA_SUPABASE_ANON_KEY",
      "LAVA_SUPABASE_URL",
      "LD_RUNPATH_SEARCH_PATHS",
      "PROVISIONING_PROFILE_SPECIFIER",
      "SWIFT_EMIT_CONST_VALUE_PROTOCOLS",
      "TARGETED_DEVICE_FAMILY",
    ]),
  ],
  [
    "LavaSecTunnel",
    new Set([
      ...commonTargetBuildSettingKeys,
      "APPLICATION_EXTENSION_API_ONLY",
      "CODE_SIGN_ENTITLEMENTS",
      "INFOPLIST_FILE",
      "LD_RUNPATH_SEARCH_PATHS",
      "LM_SKIP_METADATA_EXTRACTION",
      "OTHER_LDFLAGS",
      "PROVISIONING_PROFILE_SPECIFIER",
      "SKIP_INSTALL",
    ]),
  ],
  [
    "LavaSecWidget",
    new Set([
      ...commonTargetBuildSettingKeys,
      "APPLICATION_EXTENSION_API_ONLY",
      "CODE_SIGN_ENTITLEMENTS",
      "GENERATE_INFOPLIST_FILE",
      "INFOPLIST_FILE",
      "LD_RUNPATH_SEARCH_PATHS",
      "PROVISIONING_PROFILE_SPECIFIER",
      "SKIP_INSTALL",
      "SWIFT_EMIT_CONST_VALUE_PROTOCOLS",
      "TARGETED_DEVICE_FAMILY",
    ]),
  ],
  [
    "LavaSecIntents",
    new Set([
      ...commonTargetBuildSettingKeys,
      "APPLICATION_EXTENSION_API_ONLY",
      "CODE_SIGN_ENTITLEMENTS",
      "GENERATE_INFOPLIST_FILE",
      "INFOPLIST_FILE",
      "LD_RUNPATH_SEARCH_PATHS",
      "PROVISIONING_PROFILE_SPECIFIER",
      "SKIP_INSTALL",
      "SWIFT_EMIT_CONST_VALUE_PROTOCOLS",
      "TARGETED_DEVICE_FAMILY",
    ]),
  ],
  [
    "LavaSecUITests",
    new Set([
      ...commonTargetBuildSettingKeys,
      "GENERATE_INFOPLIST_FILE",
      "TARGETED_DEVICE_FAMILY",
      "TEST_TARGET_NAME",
    ]),
  ],
]);
const requiredBuildSettingValues = new Map([
  ["LavaSecTunnel", new Map([["OTHER_LDFLAGS", "$(inherited) -lresolv"]])],
]);
const projectBaseConfigurationPaths = new Map([
  ["Debug", "Config/Lava.xcconfig"],
  ["QA", "Config/Lava.QA.xcconfig"],
  ["Release", "Config/Lava.xcconfig"],
]);
const trackedXCConfigPolicy = new Map([
  [
    "Config/Lava.xcconfig",
    {
      includes: ["optional:Lava.local.xcconfig"],
      settings: new Map([
        ["MARKETING_VERSION", "version"],
        ["LAVA_SOURCE_REVISION", ""],
        ["DEVELOPMENT_TEAM", ""],
        ["LAVASEC_APP_PROFILE", ""],
        ["LAVASEC_TUNNEL_PROFILE", ""],
        ["LAVASEC_WIDGET_PROFILE", ""],
        ["LAVASEC_INTENTS_PROFILE", ""],
        ["LAVA_SUPABASE_URL", ""],
        ["LAVA_SUPABASE_ANON_KEY", ""],
        ["LAVA_GOOGLE_IOS_CLIENT_ID", ""],
        ["LAVA_GOOGLE_REVERSED_CLIENT_ID", ""],
        ["LAVA_GOOGLE_SERVER_CLIENT_ID", ""],
      ]),
    },
  ],
  [
    "Config/Lava.QA.xcconfig",
    {
      includes: ["required:Lava.xcconfig", "optional:Lava.QA.local.xcconfig"],
      settings: new Map([
        ["LAVA_GOOGLE_IOS_CLIENT_ID", ""],
        ["LAVA_GOOGLE_REVERSED_CLIENT_ID", ""],
      ]),
    },
  ],
]);
const optionalXCConfigPaths = [
  "Config/Lava.local.xcconfig",
  "Config/Lava.QA.local.xcconfig",
];
const approvedGeneratedProjectEntries = [
  "file:project.pbxproj",
  "file:project.xcworkspace/contents.xcworkspacedata",
  "file:project.xcworkspace/xcshareddata/swiftpm/Package.resolved",
  "file:xcshareddata/xcschemes/LavaSec.xcscheme",
];

function sorted(values) {
  return [...values].sort((left, right) => left.localeCompare(right));
}

function sameStrings(actual, expected) {
  return JSON.stringify(sorted(actual)) === JSON.stringify(sorted(expected));
}

function describeDifference(actual, expected) {
  return `expected [${sorted(expected).join(", ")}], got [${sorted(actual).join(", ")}]`;
}

function canonicalJSON(value) {
  if (Array.isArray(value)) {
    return `[${value.map(canonicalJSON).join(",")}]`;
  }
  if (value && typeof value === "object") {
    return `{${Object.keys(value).sort().map((key) => `${JSON.stringify(key)}:${canonicalJSON(value[key])}`).join(",")}}`;
  }
  return JSON.stringify(value);
}

export function validateTrackedXCConfigs(configs, trackedPaths = []) {
  const optionalPathIdentities = new Set(
    optionalXCConfigPaths.map((configPath) => configPath.normalize("NFC").toLowerCase()),
  );
  const trackedOptionalConfigs = trackedPaths
    .filter((trackedPath) => optionalPathIdentities.has(
      trackedPath.normalize("NFC").toLowerCase(),
    ))
    .sort();
  if (trackedOptionalConfigs.length > 0) {
    throw new Error(`optional xcconfig must remain untracked: ${trackedOptionalConfigs.join(", ")}`);
  }
  for (const [configPath, policy] of trackedXCConfigPolicy) {
    const contents = configs[configPath];
    if (typeof contents !== "string") {
      throw new Error(`${configPath} is missing from the tracked xcconfig policy input`);
    }
    if (/\r(?!\n)|[\u2028\u2029]/u.test(contents)) {
      throw new Error(`${configPath} contains an unsupported line separator`);
    }
    const includes = [];
    const assignments = new Map();
    for (const [index, rawLine] of contents.split(/\r?\n/).entries()) {
      const line = rawLine.trim();
      if (line.length === 0 || line.startsWith("//")) {
        continue;
      }
      const include = line.match(/^#include(\?)?\s+"([^"]+)"$/);
      if (include) {
        includes.push(`${include[1] ? "optional" : "required"}:${include[2]}`);
        continue;
      }
      const assignment = line.match(/^([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$/);
      if (!assignment) {
        throw new Error(`${configPath}:${index + 1} contains unsupported xcconfig syntax`);
      }
      const [, key, value] = assignment;
      if (!policy.settings.has(key)) {
        throw new Error(`${configPath} contains unapproved setting ${key}`);
      }
      if (assignments.has(key)) {
        throw new Error(`${configPath} assigns ${key} more than once`);
      }
      const expectedValue = policy.settings.get(key);
      if (expectedValue === "version") {
        if (!/^\d+(?:\.\d+){0,2}$/.test(value)) {
          throw new Error(`${configPath} MARKETING_VERSION differs from policy`);
        }
      } else if (value !== expectedValue) {
        throw new Error(`${configPath} tracked value for ${key} must remain empty`);
      }
      assignments.set(key, value);
    }
    if (!sameStrings(assignments.keys(), policy.settings.keys())) {
      throw new Error(`${configPath} setting set differs from policy`);
    }
    if (canonicalJSON(includes) !== canonicalJSON(policy.includes)) {
      throw new Error(`${configPath} include graph differs from policy`);
    }
  }
}

export function validateTrackedXCConfigFilesystem(rootDirectory) {
  const configDirectory = path.join(rootDirectory, "Config");
  let directoryStatus;
  try {
    directoryStatus = fs.lstatSync(configDirectory);
  } catch {
    throw new Error("Config must be a real directory");
  }
  if (!directoryStatus.isDirectory() || directoryStatus.isSymbolicLink()) {
    throw new Error("Config must be a real directory");
  }
  for (const configPath of trackedXCConfigPolicy.keys()) {
    let fileStatus;
    try {
      fileStatus = fs.lstatSync(path.join(rootDirectory, configPath));
    } catch {
      throw new Error(`${configPath} must be a regular file`);
    }
    if (!fileStatus.isFile() || fileStatus.isSymbolicLink()) {
      throw new Error(`${configPath} must be a regular file`);
    }
  }
}

export function validateGeneratedProjectFilesystem(projectDirectory) {
  let projectStatus;
  try {
    projectStatus = fs.lstatSync(projectDirectory);
  } catch {
    throw new Error("generated project must be a real directory");
  }
  if (!projectStatus.isDirectory() || projectStatus.isSymbolicLink()) {
    throw new Error("generated project must be a real directory");
  }

  const entries = [];
  const visit = (directory, prefix = "") => {
    for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
      const relativePath = prefix ? `${prefix}/${entry.name}` : entry.name;
      const absolutePath = path.join(directory, entry.name);
      if (entry.isSymbolicLink()) {
        throw new Error(`generated project contains symbolic link ${relativePath}`);
      }
      if (entry.isDirectory()) {
        visit(absolutePath, relativePath);
      } else if (entry.isFile()) {
        entries.push(`file:${relativePath}`);
      } else {
        throw new Error(`generated project contains unsupported entry ${relativePath}`);
      }
    }
  };
  visit(projectDirectory);
  if (!sameStrings(entries, approvedGeneratedProjectEntries)) {
    throw new Error(
      `generated project file set differs from policy: ${describeDifference(entries, approvedGeneratedProjectEntries)}`,
    );
  }
}

function requiredObject(objects, identifier, context, errors) {
  const object = objects[identifier];
  if (!object || typeof object !== "object") {
    errors.push(`${context} references missing object ${identifier}`);
    return undefined;
  }
  return object;
}

function buildParentMap(objects, errors) {
  const parents = new Map();
  for (const [identifier, object] of Object.entries(objects)) {
    if (!["PBXGroup", "PBXVariantGroup"].includes(object.isa)) {
      continue;
    }
    for (const child of object.children ?? []) {
      if (parents.has(child)) {
        errors.push(`object ${child} has multiple group parents: ${parents.get(child)}, ${identifier}`);
      } else {
        parents.set(child, identifier);
      }
    }
  }
  return parents;
}

function reachesMainGroup(parents, identifier, mainGroupIdentifier) {
  const seen = new Set();
  let current = identifier;
  while (current !== undefined && !seen.has(current)) {
    if (current === mainGroupIdentifier) {
      return true;
    }
    seen.add(current);
    current = parents.get(current);
  }
  return false;
}

function resolveFilePath(objects, parents, mainGroupIdentifier, identifier, errors) {
  const components = [];
  const seen = new Set();
  let anchored = false;
  let current = identifier;
  while (current !== undefined) {
    if (seen.has(current)) {
      errors.push(`file reference ${identifier} has a parent cycle`);
      return undefined;
    }
    seen.add(current);
    const object = requiredObject(objects, current, `file reference ${identifier}`, errors);
    if (!object) {
      return undefined;
    }
    if (object.sourceTree === "BUILT_PRODUCTS_DIR") {
      errors.push(`source membership uses a built-product reference: ${identifier}`);
      return undefined;
    }
    if (current === mainGroupIdentifier) {
      anchored = true;
      break;
    }
    if (object.path) {
      components.push(object.path);
    }
    if (object.sourceTree === "SOURCE_ROOT") {
      anchored = current === identifier
        || reachesMainGroup(parents, current, mainGroupIdentifier);
      break;
    }
    if (object.sourceTree && object.sourceTree !== "<group>") {
      errors.push(`source membership uses unsupported sourceTree ${object.sourceTree}`);
      return undefined;
    }
    current = parents.get(current);
  }
  if (!anchored) {
    errors.push(`file reference ${identifier} is not anchored to the main group or SOURCE_ROOT`);
    return undefined;
  }
  return components.reverse().join("/");
}

function buildFilePaths(objects, parents, mainGroupIdentifier, phase, context, errors) {
  const paths = [];
  for (const buildFileIdentifier of phase.files ?? []) {
    const buildFile = requiredObject(objects, buildFileIdentifier, context, errors);
    if (!buildFile) {
      continue;
    }
    if (buildFile.isa !== "PBXBuildFile" || !buildFile.fileRef || buildFile.productRef) {
      errors.push(`${context} contains a non-file build entry ${buildFileIdentifier}`);
      continue;
    }
    const executionFields = Object.keys(buildFile)
      .filter((key) => !["fileRef", "isa"].includes(key))
      .sort();
    if (executionFields.length > 0) {
      errors.push(
        `${context} contains execution-affecting build-file fields: ${executionFields.join(", ")}`,
      );
    }
    const resolved = resolveFilePath(
      objects,
      parents,
      mainGroupIdentifier,
      buildFile.fileRef,
      errors,
    );
    if (resolved !== undefined) {
      paths.push(resolved);
    }
  }
  return paths;
}

function frameworkProducts(objects, phase, context, errors) {
  const products = [];
  for (const buildFileIdentifier of phase.files ?? []) {
    const buildFile = requiredObject(objects, buildFileIdentifier, context, errors);
    if (!buildFile) {
      continue;
    }
    if (buildFile.isa !== "PBXBuildFile" || !buildFile.productRef || buildFile.fileRef) {
      errors.push(`${context} contains a non-package framework entry ${buildFileIdentifier}`);
      continue;
    }
    const executionFields = Object.keys(buildFile)
      .filter((key) => !["isa", "productRef"].includes(key))
      .sort();
    if (executionFields.length > 0) {
      errors.push(
        `${context} contains execution-affecting build-file fields: ${executionFields.join(", ")}`,
      );
    }
    const product = requiredObject(objects, buildFile.productRef, context, errors);
    if (product?.productName) {
      products.push(product.productName);
    } else if (product) {
      errors.push(`${context} contains an unnamed package product`);
    }
  }
  return products;
}

function copyPhaseProjection(objects, phase, context, errors) {
  const expectedKeys = [
    "buildActionMask",
    "dstPath",
    "dstSubfolderSpec",
    "files",
    "isa",
    "name",
    "runOnlyForDeploymentPostprocessing",
  ];
  if (!sameStrings(Object.keys(phase), expectedKeys)) {
    errors.push(`${context} contains unsupported phase-level fields`);
  }
  const entries = [];
  for (const buildFileIdentifier of phase.files ?? []) {
    const buildFile = requiredObject(objects, buildFileIdentifier, context, errors);
    const fileReference = buildFile?.fileRef
      ? requiredObject(objects, buildFile.fileRef, context, errors)
      : undefined;
    if (buildFile?.isa !== "PBXBuildFile"
        || buildFile.productRef
        || fileReference?.isa !== "PBXFileReference"
        || fileReference.sourceTree !== "BUILT_PRODUCTS_DIR"
        || !fileReference.path) {
      errors.push(`${context} contains an unsupported copy entry ${buildFileIdentifier}`);
      continue;
    }
    const executionFields = Object.keys(buildFile)
      .filter((key) => !["fileRef", "isa", "settings"].includes(key))
      .sort();
    if (executionFields.length > 0) {
      errors.push(
        `${context} contains execution-affecting build-file fields: ${executionFields.join(", ")}`,
      );
    }
    if (!buildFile.settings
        || !sameStrings(Object.keys(buildFile.settings), ["ATTRIBUTES"])) {
      errors.push(`${context} copy entry ${fileReference.path} has unsupported settings`);
    }
    const attributes = buildFile.settings?.ATTRIBUTES ?? [];
    if (!Array.isArray(attributes)) {
      errors.push(`${context} copy entry ${fileReference.path} has malformed attributes`);
      continue;
    }
    entries.push({
      path: fileReference.path,
      attributes: sorted(attributes),
    });
  }
  entries.sort((left, right) => left.path.localeCompare(right.path));
  return {
    buildActionMask: phase.buildActionMask ?? "",
    name: phase.name ?? "",
    dstPath: phase.dstPath ?? "",
    dstSubfolderSpec: phase.dstSubfolderSpec ?? "",
    runOnlyForDeploymentPostprocessing: phase.runOnlyForDeploymentPostprocessing ?? "",
    entries,
  };
}

function validateStandardPhaseShape(phase, context, errors) {
  const expectedKeys = [
    "buildActionMask",
    "files",
    "isa",
    "runOnlyForDeploymentPostprocessing",
  ];
  if (!sameStrings(Object.keys(phase), expectedKeys)
      || phase.buildActionMask !== "2147483647"
      || phase.runOnlyForDeploymentPostprocessing !== "0") {
    errors.push(`${context} metadata differs from policy`);
  }
}

function validatePackageReferences(project, objects, errors) {
  const localReferences = [];
  const remoteReferences = [];
  for (const identifier of project.packageReferences ?? []) {
    const reference = requiredObject(objects, identifier, "project package references", errors);
    if (!reference) {
      continue;
    }
    if (reference.isa === "XCLocalSwiftPackageReference") {
      localReferences.push({ identifier, path: reference.relativePath });
    } else if (reference.isa === "XCRemoteSwiftPackageReference") {
      remoteReferences.push({
        identifier,
        url: reference.repositoryURL,
        requirement: reference.requirement,
      });
    } else {
      errors.push(`unsupported project package reference kind ${reference.isa}`);
    }
  }

  if (localReferences.length !== 1 || localReferences[0]?.path !== ".") {
    errors.push("generated project must contain exactly one repo-root local package reference");
  }
  if (remoteReferences.length !== 1 || remoteReferences[0]?.url !== remotePackageURL) {
    errors.push(`generated project must contain only the approved remote package ${remotePackageURL}`);
  } else if (canonicalJSON(remoteReferences[0].requirement) !== canonicalJSON(remotePackageRequirement)) {
    errors.push("generated project must use the approved GoogleSignIn requirement");
  }
  return {
    localIdentifier: localReferences[0]?.identifier,
    remoteIdentifier: remoteReferences[0]?.identifier,
  };
}

function validateConfigurationList(
  objects,
  parents,
  mainGroupIdentifier,
  identifier,
  context,
  errors,
) {
  const list = requiredObject(objects, identifier, `${context} configurations`, errors);
  const expectedListKeys = [
    "buildConfigurations",
    "defaultConfigurationIsVisible",
    "defaultConfigurationName",
    "isa",
  ];
  if (!list
      || list.isa !== "XCConfigurationList"
      || !sameStrings(Object.keys(list), expectedListKeys)
      || list.defaultConfigurationIsVisible !== "0"
      || list.defaultConfigurationName !== "Release"
      || !Array.isArray(list.buildConfigurations)) {
    errors.push(`${context} configuration list metadata differs from policy`);
    return;
  }
  const names = [];
  const approvedKeys = approvedBuildSettingKeys.get(context);
  for (const configurationIdentifier of list.buildConfigurations) {
    const configuration = requiredObject(
      objects,
      configurationIdentifier,
      `${context} configurations`,
      errors,
    );
    if (configuration?.isa !== "XCBuildConfiguration"
        || typeof configuration.name !== "string"
        || !configuration.buildSettings
        || typeof configuration.buildSettings !== "object"
        || Array.isArray(configuration.buildSettings)) {
      errors.push(`${context} contains a malformed build configuration`);
    } else {
      names.push(configuration.name);
      const allowedConfigurationFields = [
        "baseConfigurationReference",
        "buildSettings",
        "isa",
        "name",
      ];
      const unsupportedFields = Object.keys(configuration)
        .filter((key) => !allowedConfigurationFields.includes(key))
        .sort();
      if (unsupportedFields.length > 0) {
        errors.push(`${context} ${configuration.name} configuration contains unsupported fields: ${unsupportedFields.join(", ")}`);
      }
      const unapprovedSettings = Object.keys(configuration.buildSettings)
        .filter((key) => !approvedKeys?.has(key))
        .sort();
      if (unapprovedSettings.length > 0) {
        errors.push(`${context} ${configuration.name} build settings contain unapproved keys: ${unapprovedSettings.join(", ")}`);
      }
      for (const [key, value] of requiredBuildSettingValues.get(context) ?? []) {
        if (canonicalJSON(configuration.buildSettings[key]) !== canonicalJSON(value)) {
          errors.push(`${context} ${configuration.name} build setting ${key} differs from policy`);
        }
      }
      const expectedBasePath = context === "project"
        ? projectBaseConfigurationPaths.get(configuration.name)
        : undefined;
      let actualBasePath;
      if (configuration.baseConfigurationReference !== undefined) {
        const reference = requiredObject(
          objects,
          configuration.baseConfigurationReference,
          `${context} ${configuration.name} base configuration`,
          errors,
        );
        if (reference?.isa !== "PBXFileReference") {
          errors.push(`${context} ${configuration.name} base configuration must be a PBXFileReference`);
        } else {
          actualBasePath = resolveFilePath(
            objects,
            parents,
            mainGroupIdentifier,
            configuration.baseConfigurationReference,
            errors,
          );
        }
      }
      if (actualBasePath !== expectedBasePath) {
        errors.push(`${context} ${configuration.name} base configuration differs from policy`);
      }
    }
  }
  if (!sameStrings(names, ["Debug", "QA", "Release"])) {
    errors.push(`${context} configurations must be exactly Debug, QA, and Release`);
  }
}

export function validateGeneratedProject(projectFile, expectedBoundary) {
  const errors = [];
  const objects = projectFile?.objects;
  const rootObject = projectFile?.rootObject;
  if (!objects || typeof objects !== "object" || !rootObject) {
    throw new Error("generated project JSON is missing objects or rootObject");
  }
  const expectedProjectFileFields = [
    "archiveVersion",
    "classes",
    "objectVersion",
    "objects",
    "rootObject",
  ];
  if (!sameStrings(Object.keys(projectFile), expectedProjectFileFields)) {
    errors.push("project-file envelope fields differ from policy");
  }
  if (projectFile.archiveVersion !== "1"
      || canonicalJSON(projectFile.classes) !== canonicalJSON({})
      || projectFile.objectVersion !== "77") {
    errors.push("project-file envelope differs from policy");
  }
  const project = requiredObject(objects, rootObject, "root project", errors);
  const parents = buildParentMap(objects, errors);
  if (!project || project.isa !== "PBXProject") {
    errors.push("rootObject must identify a PBXProject");
  } else {
    const allowedProjectFields = [
      "attributes",
      "buildConfigurationList",
      "developmentRegion",
      "hasScannedForEncodings",
      "isa",
      "knownRegions",
      "mainGroup",
      "minimizedProjectReferenceProxies",
      "packageReferences",
      "preferredProjectObjectVersion",
      "productRefGroup",
      "projectDirPath",
      "projectRoot",
      "targets",
    ];
    const unsupportedProjectFields = Object.keys(project)
      .filter((key) => !allowedProjectFields.includes(key))
      .sort();
    if (unsupportedProjectFields.length > 0) {
      errors.push(`root project contains unsupported fields: ${unsupportedProjectFields.join(", ")}`);
    }
    if (project.projectDirPath !== "" || project.projectRoot !== "") {
      errors.push("root project path fields differ from policy");
    }
    if (project.preferredProjectObjectVersion !== "77") {
      errors.push("root project preferred object version differs from policy");
    }
    const mainGroup = requiredObject(objects, project.mainGroup, "project main group", errors);
    if (!mainGroup
        || mainGroup.isa !== "PBXGroup"
        || !Array.isArray(mainGroup.children)
        || mainGroup.sourceTree !== "<group>"
        || !sameStrings(Object.keys(mainGroup), ["children", "isa", "sourceTree"])
        || parents.has(project.mainGroup)) {
      errors.push("project main group metadata differs from policy");
    }
    validateConfigurationList(
      objects,
      parents,
      project.mainGroup,
      project.buildConfigurationList,
      "project",
      errors,
    );
  }
  const expectedTargets = expectedBoundary?.targets;
  if (!expectedTargets || typeof expectedTargets !== "object" || Array.isArray(expectedTargets)) {
    errors.push("expected boundary JSON must contain a targets mapping");
  }
  const expectedTargetNames = expectedTargets ? Object.keys(expectedTargets) : [];
  const policyTargetNames = [...targetPolicy.keys()];
  if (!sameStrings(expectedTargetNames, policyTargetNames)) {
    errors.push(`manifest target set is not the approved target set: ${describeDifference(expectedTargetNames, policyTargetNames)}`);
  }

  for (const object of Object.values(objects)) {
    if (forbiddenObjectKinds.has(object.isa)
        || object.isa?.startsWith("PBXFileSystemSynchronized")) {
      errors.push(`generated project contains forbidden object kind ${object.isa}`);
    }
  }

  const { localIdentifier, remoteIdentifier } = project
    ? validatePackageReferences(project, objects, errors)
    : {};
  const targetsByName = new Map();
  for (const identifier of project?.targets ?? []) {
    const target = requiredObject(objects, identifier, "project targets", errors);
    if (!target?.name) {
      errors.push(`project target ${identifier} has no name`);
      continue;
    }
    if (targetsByName.has(target.name)) {
      errors.push(`generated project contains duplicate target ${target.name}`);
      continue;
    }
    targetsByName.set(target.name, { identifier, target });
  }
  if (!sameStrings(targetsByName.keys(), policyTargetNames)) {
    errors.push(`generated target set is not approved: ${describeDifference(targetsByName.keys(), policyTargetNames)}`);
  }
  if (project) {
    const targetAttributes = {};
    for (const name of policyTargetNames) {
      const identifier = targetsByName.get(name)?.identifier;
      if (!identifier) {
        continue;
      }
      targetAttributes[identifier] = {
        DevelopmentTeam: "$(inherited)",
        ProvisioningStyle: "Automatic",
        ...(name === "LavaSecUITests"
          ? { TestTargetID: targetsByName.get("LavaSec")?.identifier }
          : {}),
      };
    }
    const expectedAttributes = {
      BuildIndependentTargetsInParallel: "YES",
      LastUpgradeCheck: "2630",
      TargetAttributes: targetAttributes,
    };
    if (canonicalJSON(project.attributes) !== canonicalJSON(expectedAttributes)) {
      errors.push("root project attributes differ from policy");
    }
  }

  for (const [name, policy] of targetPolicy) {
    const entry = targetsByName.get(name);
    if (!entry) {
      continue;
    }
    const { target } = entry;
    const allowedTargetFields = [
      "buildConfigurationList",
      "buildPhases",
      "buildRules",
      "dependencies",
      "isa",
      "name",
      "packageProductDependencies",
      "productName",
      "productReference",
      "productType",
    ];
    const unsupportedTargetFields = Object.keys(target)
      .filter((key) => !allowedTargetFields.includes(key))
      .sort();
    if (unsupportedTargetFields.length > 0) {
      errors.push(`${name} contains unsupported target fields: ${unsupportedTargetFields.join(", ")}`);
    }
    if (target.isa !== "PBXNativeTarget") {
      errors.push(`${name} must be a PBXNativeTarget, got ${target.isa}`);
    }
    if (target.productType !== policy.productType) {
      errors.push(`${name} has product type ${target.productType}; expected ${policy.productType}`);
    }
    if ((target.buildRules ?? []).length !== 0) {
      errors.push(`${name} contains build rules`);
    }
    validateConfigurationList(
      objects,
      parents,
      project.mainGroup,
      target.buildConfigurationList,
      name,
      errors,
    );

    const phases = [];
    for (const identifier of target.buildPhases ?? []) {
      const phase = requiredObject(objects, identifier, `${name} build phases`, errors);
      if (!phase) {
        continue;
      }
      if (!allowedBuildPhaseKinds.has(phase.isa)) {
        errors.push(`${name} contains unsupported build phase ${phase.isa}`);
      }
      phases.push(phase);
    }
    const sourcePhases = phases.filter((phase) => phase.isa === "PBXSourcesBuildPhase");
    for (const phase of sourcePhases) {
      validateStandardPhaseShape(phase, `${name} sources phase`, errors);
    }
    if (sourcePhases.length !== 1) {
      errors.push(`${name} must contain exactly one PBXSourcesBuildPhase`);
    } else {
      const sourcePaths = buildFilePaths(
        objects,
        parents,
        project.mainGroup,
        sourcePhases[0],
        `${name} sources`,
        errors,
      );
      const expectedPaths = [
        ...(Array.isArray(expectedTargets?.[name]) ? expectedTargets[name] : []),
        ...policy.additionalCompiledSources,
      ];
      if (new Set(sourcePaths).size !== sourcePaths.length) {
        errors.push(`${name} contains duplicate compiled source membership`);
      }
      if (!sameStrings(sourcePaths, expectedPaths)) {
        errors.push(`${name} compiled source membership differs from policy: ${describeDifference(sourcePaths, expectedPaths)}`);
      }
    }

    const copyPhases = phases
      .filter((phase) => phase.isa === "PBXCopyFilesBuildPhase")
      .map((phase) => copyPhaseProjection(objects, phase, `${name} copy phase`, errors))
      .sort((left, right) => left.name.localeCompare(right.name));
    const expectedCopyPhases = [...policy.copyPhases]
      .map((phase) => ({
        ...phase,
        entries: [...phase.entries]
          .map((entry) => ({ ...entry, attributes: sorted(entry.attributes) }))
          .sort((left, right) => left.path.localeCompare(right.path)),
      }))
      .sort((left, right) => left.name.localeCompare(right.name));
    if (canonicalJSON(copyPhases) !== canonicalJSON(expectedCopyPhases)) {
      errors.push(`${name} copy phases differ from policy`);
    }
    for (const phase of phases.filter((candidate) => candidate.isa !== "PBXSourcesBuildPhase")) {
      for (const buildFileIdentifier of phase.files ?? []) {
        const buildFile = objects[buildFileIdentifier];
        if (!buildFile?.fileRef) {
          continue;
        }
        const fileReference = objects[buildFile.fileRef];
        const leaf = fileReference?.path ?? fileReference?.name ?? "";
        if (!leaf.endsWith(".swift")) {
          continue;
        }
        const sourcePath = resolveFilePath(
          objects,
          parents,
          project.mainGroup,
          buildFile.fileRef,
          errors,
        );
        if (sourcePath?.endsWith(".swift")) {
          errors.push(`${name} places Swift outside PBXSourcesBuildPhase: ${sourcePath}`);
        }
      }
    }

    const frameworkPhases = phases.filter((phase) => phase.isa === "PBXFrameworksBuildPhase");
    for (const phase of frameworkPhases) {
      validateStandardPhaseShape(phase, `${name} frameworks phase`, errors);
    }
    if (frameworkPhases.length !== 1) {
      errors.push(`${name} must contain exactly one PBXFrameworksBuildPhase`);
    } else {
      const linkedProducts = frameworkProducts(
        objects,
        frameworkPhases[0],
        `${name} frameworks`,
        errors,
      );
      if (!sameStrings(linkedProducts, policy.packageProducts)) {
        errors.push(`${name} linked package products differ from policy: ${describeDifference(linkedProducts, policy.packageProducts)}`);
      }
    }

    const resourcePhases = phases.filter((phase) => phase.isa === "PBXResourcesBuildPhase");
    for (const phase of resourcePhases) {
      validateStandardPhaseShape(phase, `${name} resources phase`, errors);
    }
    const expectedResourcePhaseCount = policy.resources.length === 0 ? 0 : 1;
    if (resourcePhases.length !== expectedResourcePhaseCount) {
      errors.push(`${name} resources phase count differs from policy`);
    } else if (resourcePhases.length === 1) {
      const resourcePaths = buildFilePaths(
        objects,
        parents,
        project.mainGroup,
        resourcePhases[0],
        `${name} resources`,
        errors,
      );
      if (new Set(resourcePaths).size !== resourcePaths.length) {
        errors.push(`${name} contains duplicate resource membership`);
      }
      if (!sameStrings(resourcePaths, policy.resources)) {
        errors.push(`${name} resource membership differs from policy: ${describeDifference(resourcePaths, policy.resources)}`);
      }
    }

    const packageProducts = [];
    for (const identifier of target.packageProductDependencies ?? []) {
      const product = requiredObject(objects, identifier, `${name} package products`, errors);
      if (!product) {
        continue;
      }
      if (product.isa !== "XCSwiftPackageProductDependency" || !product.productName) {
        errors.push(`${name} has malformed package product dependency ${identifier}`);
        continue;
      }
      packageProducts.push(product.productName);
      if (product.productName === "GoogleSignIn") {
        if (product.package !== remoteIdentifier) {
          errors.push("GoogleSignIn must come from the approved remote package reference");
        }
      } else if (product.package !== undefined && product.package !== localIdentifier) {
        errors.push(`${name} product ${product.productName} comes from an unapproved package reference`);
      }
    }
    if (!sameStrings(packageProducts, policy.packageProducts)) {
      errors.push(`${name} package product dependencies differ from policy: ${describeDifference(packageProducts, policy.packageProducts)}`);
    }

    const targetDependencies = [];
    for (const identifier of target.dependencies ?? []) {
      const dependency = requiredObject(objects, identifier, `${name} target dependencies`, errors);
      if (dependency && !sameStrings(
        Object.keys(dependency),
        ["isa", "target", "targetProxy"],
      )) {
        errors.push(`${name} dependency ${identifier} fields differ from policy`);
      }
      if (dependency?.isa !== "PBXTargetDependency") {
        errors.push(`${name} dependency ${identifier} must be a PBXTargetDependency`);
      }
      const dependencyTarget = dependency?.target
        ? requiredObject(objects, dependency.target, `${name} target dependency`, errors)
        : undefined;
      if (!dependencyTarget?.name) {
        errors.push(`${name} has an indirect or malformed target dependency`);
      } else {
        targetDependencies.push(dependencyTarget.name);
        if (dependency.target !== targetsByName.get(dependencyTarget.name)?.identifier) {
          errors.push(`${name} dependency ${identifier} points to a non-canonical target object`);
        }
        const proxy = dependency.targetProxy
          ? requiredObject(objects, dependency.targetProxy, `${name} target dependency proxy`, errors)
          : undefined;
        const expectedProxy = {
          isa: "PBXContainerItemProxy",
          containerPortal: rootObject,
          remoteGlobalIDString: dependency.target,
          remoteInfo: dependencyTarget.name,
          proxyType: "1",
        };
        if (!proxy || canonicalJSON(proxy) !== canonicalJSON(expectedProxy)) {
          errors.push(`${name} dependency ${identifier} proxy differs from policy`);
        }
      }
    }
    if (!sameStrings(targetDependencies, policy.targetDependencies)) {
      errors.push(`${name} target dependencies differ from policy: ${describeDifference(targetDependencies, policy.targetDependencies)}`);
    }
  }

  if (errors.length > 0) {
    throw new Error(errors.join("\n"));
  }
  return Object.fromEntries(
    [...targetsByName].map(([name, entry]) => [name, entry.identifier]),
  );
}

function decodeXMLAttribute(value) {
  return value.replaceAll(/&(?:amp|quot|apos|lt|gt|#\d+|#x[0-9a-fA-F]+);/g, (entity) => {
    const named = {
      "&amp;": "&",
      "&quot;": '"',
      "&apos;": "'",
      "&lt;": "<",
      "&gt;": ">",
    };
    if (named[entity]) {
      return named[entity];
    }
    const radix = entity.startsWith("&#x") ? 16 : 10;
    const digits = entity.slice(radix === 16 ? 3 : 2, -1);
    return String.fromCodePoint(Number.parseInt(digits, radix));
  });
}

function parseXMLAttributes(source) {
  const attributes = {};
  const pattern = /\s+([A-Za-z_][\w.:-]*)\s*=\s*"([^"]*)"/gy;
  let offset = 0;
  while (offset < source.length) {
    pattern.lastIndex = offset;
    const match = pattern.exec(source);
    if (!match) {
      if (source.slice(offset).trim() === "") {
        break;
      }
      throw new Error("shared scheme contains unsupported XML attribute syntax");
    }
    if (attributes[match[1]] !== undefined) {
      throw new Error(`shared scheme contains duplicate XML attribute ${match[1]}`);
    }
    attributes[match[1]] = decodeXMLAttribute(match[2]);
    offset = pattern.lastIndex;
  }
  return attributes;
}

function parseSchemeXML(source) {
  const tokens = source.match(/<[^>]+>|[^<]+/g) ?? [];
  if (tokens.join("") !== source) {
    throw new Error("shared scheme contains malformed XML");
  }
  const stack = [];
  let root;
  for (const token of tokens) {
    if (!token.startsWith("<")) {
      if (token.trim()) {
        throw new Error("shared scheme contains unexpected text content");
      }
      continue;
    }
    if (token.startsWith("<?xml") && token.endsWith("?>")) {
      continue;
    }
    if (token.startsWith("<!")) {
      throw new Error("shared scheme contains unsupported XML declarations");
    }
    const closing = token.match(/^<\/([A-Za-z][\w.-]*)\s*>$/);
    if (closing) {
      const node = stack.pop();
      if (!node || node.name !== closing[1]) {
        throw new Error("shared scheme contains mismatched XML elements");
      }
      continue;
    }
    const opening = token.match(/^<([A-Za-z][\w.-]*)([\s\S]*?)(\/?)>$/);
    if (!opening) {
      throw new Error("shared scheme contains unsupported XML syntax");
    }
    const node = {
      name: opening[1],
      attributes: parseXMLAttributes(opening[2]),
      children: [],
    };
    if (stack.length > 0) {
      stack.at(-1).children.push(node);
    } else if (root === undefined) {
      root = node;
    } else {
      throw new Error("shared scheme contains multiple root elements");
    }
    if (opening[3] !== "/") {
      stack.push(node);
    }
  }
  if (stack.length !== 0 || root?.name !== "Scheme") {
    throw new Error("shared scheme must contain one complete Scheme root");
  }
  return root;
}

function childrenNamed(node, name) {
  return node.children.filter((child) => child.name === name);
}

function exactlyOneChild(node, name, context) {
  const matches = childrenNamed(node, name);
  if (matches.length !== 1) {
    throw new Error(`${context} must contain exactly one ${name}`);
  }
  return matches[0];
}

function validateAllowedChildren(node, allowed, context) {
  const unexpected = node.children.filter((child) => !allowed.has(child.name));
  if (unexpected.length > 0) {
    throw new Error(`${context} contains unsupported element ${unexpected[0].name}`);
  }
}

function validateAttribute(node, name, expected, context) {
  if (node.attributes[name] !== expected) {
    throw new Error(`${context} must set ${name}=${expected}`);
  }
}

function validateExactAttributes(node, expected, context) {
  if (canonicalJSON(node.attributes) !== canonicalJSON(expected)) {
    throw new Error(`${context} attributes differ from policy`);
  }
}

function validateBuildableReference(node, expected, context) {
  validateExactAttributes(node, {
    BuildableIdentifier: "primary",
    BlueprintIdentifier: expected.identifier,
    BuildableName: expected.buildableName,
    BlueprintName: expected.blueprintName,
    ReferencedContainer: "container:LavaSec.xcodeproj",
  }, context);
  validateAttribute(node, "BuildableIdentifier", "primary", context);
  validateAttribute(node, "BlueprintIdentifier", expected.identifier, context);
  validateAttribute(node, "BuildableName", expected.buildableName, context);
  validateAttribute(node, "BlueprintName", expected.blueprintName, context);
  validateAttribute(node, "ReferencedContainer", "container:LavaSec.xcodeproj", context);
  if (node.children.length !== 0) {
    throw new Error(`${context} must not contain nested elements`);
  }
}

function validateAppRunnable(action, targetIdentifiers, context) {
  const runnable = exactlyOneChild(action, "BuildableProductRunnable", context);
  validateExactAttributes(runnable, { runnableDebuggingMode: "0" }, `${context} runnable`);
  validateAllowedChildren(runnable, new Set(["BuildableReference"]), `${context} runnable`);
  const reference = exactlyOneChild(runnable, "BuildableReference", `${context} runnable`);
  validateBuildableReference(reference, {
    identifier: targetIdentifiers.LavaSec,
    buildableName: "LavaSec.app",
    blueprintName: "LavaSec",
  }, `${context} must reference canonical LavaSec target`);
}

function validateEmptyCommandLineArguments(action, context) {
  const arguments_ = exactlyOneChild(action, "CommandLineArguments", context);
  validateExactAttributes(arguments_, {}, `${context} CommandLineArguments`);
  validateAllowedChildren(arguments_, new Set(), `${context} CommandLineArguments`);
}

export function validateGeneratedSchemes(schemes, targetIdentifiers = {}) {
  const names = Object.keys(schemes);
  if (!sameStrings(names, ["LavaSec.xcscheme"])) {
    throw new Error(`generated shared scheme set is not approved: ${describeDifference(names, ["LavaSec.xcscheme"])}`);
  }
  const executableAction = /<(?:PreActions|PostActions|ExecutionAction)\b|\bscriptText\s*=/;
  for (const [name, contents] of Object.entries(schemes)) {
    if (executableAction.test(contents)) {
      throw new Error(`${name} contains an executable scheme action`);
    }
    const scheme = parseSchemeXML(contents);
    validateExactAttributes(scheme, {
      LastUpgradeVersion: "2630",
      version: "1.7",
    }, name);
    const actionNames = [
      "AnalyzeAction",
      "ArchiveAction",
      "BuildAction",
      "LaunchAction",
      "ProfileAction",
      "TestAction",
    ];
    validateAllowedChildren(scheme, new Set(actionNames), name);
    const actions = Object.fromEntries(
      actionNames.map((actionName) => [
        actionName,
        exactlyOneChild(scheme, actionName, name),
      ]),
    );

    const build = actions.BuildAction;
    validateExactAttributes(build, {
      buildImplicitDependencies: "YES",
      parallelizeBuildables: "YES",
      runPostActionsOnFailure: "NO",
    }, "BuildAction");
    validateAllowedChildren(build, new Set(["BuildActionEntries"]), "BuildAction");
    validateAttribute(build, "parallelizeBuildables", "YES", "BuildAction");
    validateAttribute(build, "buildImplicitDependencies", "YES", "BuildAction");
    const entries = exactlyOneChild(build, "BuildActionEntries", "BuildAction");
    validateExactAttributes(entries, {}, "BuildActionEntries");
    validateAllowedChildren(entries, new Set(["BuildActionEntry"]), "BuildActionEntries");
    const entry = exactlyOneChild(entries, "BuildActionEntry", "BuildActionEntries");
    validateExactAttributes(entry, {
      buildForAnalyzing: "YES",
      buildForArchiving: "YES",
      buildForProfiling: "YES",
      buildForRunning: "YES",
      buildForTesting: "YES",
    }, "BuildActionEntry");
    for (const flag of [
      "buildForAnalyzing",
      "buildForArchiving",
      "buildForProfiling",
      "buildForRunning",
      "buildForTesting",
    ]) {
      validateAttribute(entry, flag, "YES", "BuildActionEntry");
    }
    validateAllowedChildren(entry, new Set(["BuildableReference"]), "BuildActionEntry");
    validateBuildableReference(
      exactlyOneChild(entry, "BuildableReference", "BuildActionEntry"),
      {
        identifier: targetIdentifiers.LavaSec,
        buildableName: "LavaSec.app",
        blueprintName: "LavaSec",
      },
      "BuildAction must reference canonical LavaSec target",
    );

    const test = actions.TestAction;
    validateExactAttributes(test, {
      buildConfiguration: "Debug",
      onlyGenerateCoverageForSpecifiedTargets: "NO",
      selectedDebuggerIdentifier: "Xcode.DebuggerFoundation.Debugger.LLDB",
      selectedLauncherIdentifier: "Xcode.DebuggerFoundation.Launcher.LLDB",
      shouldUseLaunchSchemeArgsEnv: "YES",
    }, "TestAction");
    validateAttribute(test, "buildConfiguration", "Debug", "TestAction");
    validateAllowedChildren(
      test,
      new Set(["CommandLineArguments", "MacroExpansion", "Testables"]),
      "TestAction",
    );
    const macro = exactlyOneChild(test, "MacroExpansion", "TestAction");
    validateExactAttributes(macro, {}, "TestAction MacroExpansion");
    validateAllowedChildren(macro, new Set(["BuildableReference"]), "TestAction MacroExpansion");
    validateBuildableReference(
      exactlyOneChild(macro, "BuildableReference", "TestAction MacroExpansion"),
      {
        identifier: targetIdentifiers.LavaSec,
        buildableName: "LavaSec.app",
        blueprintName: "LavaSec",
      },
      "TestAction MacroExpansion must reference canonical LavaSec target",
    );
    const testables = exactlyOneChild(test, "Testables", "TestAction");
    validateExactAttributes(testables, {}, "Testables");
    validateAllowedChildren(testables, new Set(["TestableReference"]), "Testables");
    const testable = exactlyOneChild(testables, "TestableReference", "Testables");
    validateExactAttributes(testable, {
      parallelizable: "NO",
      skipped: "NO",
    }, "TestableReference");
    validateAttribute(testable, "skipped", "NO", "TestableReference");
    validateAllowedChildren(testable, new Set(["BuildableReference"]), "TestableReference");
    validateBuildableReference(
      exactlyOneChild(testable, "BuildableReference", "TestableReference"),
      {
        identifier: targetIdentifiers.LavaSecUITests,
        buildableName: "LavaSecUITests.xctest",
        blueprintName: "LavaSecUITests",
      },
      "TestAction must reference canonical LavaSecUITests target",
    );
    validateEmptyCommandLineArguments(test, "TestAction");

    validateExactAttributes(actions.LaunchAction, {
      allowLocationSimulation: "YES",
      buildConfiguration: "Debug",
      debugDocumentVersioning: "YES",
      debugServiceExtension: "internal",
      ignoresPersistentStateOnLaunch: "NO",
      launchStyle: "0",
      selectedDebuggerIdentifier: "Xcode.DebuggerFoundation.Debugger.LLDB",
      selectedLauncherIdentifier: "Xcode.DebuggerFoundation.Launcher.LLDB",
      useCustomWorkingDirectory: "NO",
    }, "LaunchAction");
    validateAttribute(actions.LaunchAction, "buildConfiguration", "Debug", "LaunchAction");
    validateAllowedChildren(
      actions.LaunchAction,
      new Set(["BuildableProductRunnable", "CommandLineArguments"]),
      "LaunchAction",
    );
    validateAppRunnable(actions.LaunchAction, targetIdentifiers, "LaunchAction");
    validateEmptyCommandLineArguments(actions.LaunchAction, "LaunchAction");
    validateExactAttributes(actions.ProfileAction, {
      buildConfiguration: "Release",
      debugDocumentVersioning: "YES",
      savedToolIdentifier: "",
      shouldUseLaunchSchemeArgsEnv: "YES",
      useCustomWorkingDirectory: "NO",
    }, "ProfileAction");
    validateAttribute(actions.ProfileAction, "buildConfiguration", "Release", "ProfileAction");
    validateAllowedChildren(
      actions.ProfileAction,
      new Set(["BuildableProductRunnable", "CommandLineArguments"]),
      "ProfileAction",
    );
    validateAppRunnable(actions.ProfileAction, targetIdentifiers, "ProfileAction");
    validateEmptyCommandLineArguments(actions.ProfileAction, "ProfileAction");
    validateExactAttributes(actions.AnalyzeAction, {
      buildConfiguration: "Debug",
    }, "AnalyzeAction");
    validateAttribute(actions.AnalyzeAction, "buildConfiguration", "Debug", "AnalyzeAction");
    validateAllowedChildren(actions.AnalyzeAction, new Set(), "AnalyzeAction");
    validateExactAttributes(actions.ArchiveAction, {
      buildConfiguration: "Release",
      revealArchiveInOrganizer: "YES",
    }, "ArchiveAction");
    validateAttribute(actions.ArchiveAction, "buildConfiguration", "Release", "ArchiveAction");
    validateAllowedChildren(actions.ArchiveAction, new Set(), "ArchiveAction");
  }
}

function readSchemes(directory) {
  const result = {};
  for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
    if (!entry.isFile() || !entry.name.endsWith(".xcscheme")) {
      throw new Error(`unexpected entry in generated shared scheme directory: ${entry.name}`);
    }
    result[entry.name] = fs.readFileSync(path.join(directory, entry.name), "utf8");
  }
  return result;
}

function main() {
  const arguments_ = process.argv.slice(2);
  if (arguments_.length !== 3) {
    console.error("usage: check-xcodegen-generated-boundary.mjs EXPECTED.json PROJECT.json PROJECT_DIR");
    process.exit(2);
  }
  try {
    validateTrackedXCConfigFilesystem(process.cwd());
    const trackedResult = spawnSync(
      "git",
      ["ls-files", "-z"],
      { encoding: "utf8", maxBuffer: 1024 * 1024 },
    );
    if (trackedResult.status !== 0) {
      const detail = trackedResult.error?.message
        || trackedResult.stderr.trim()
        || `exit status ${trackedResult.status}`;
      throw new Error(`could not inspect optional xcconfig tracking state: ${detail}`);
    }
    const trackedOptionalConfigs = trackedResult.stdout
      .split("\0")
      .filter((line) => line.length > 0);
    validateTrackedXCConfigs(Object.fromEntries(
      [...trackedXCConfigPolicy.keys()].map((configPath) => [
        configPath,
        fs.readFileSync(configPath, "utf8"),
      ]),
    ), trackedOptionalConfigs);
    const expected = JSON.parse(fs.readFileSync(arguments_[0], "utf8"));
    const project = JSON.parse(fs.readFileSync(arguments_[1], "utf8"));
    const targetIdentifiers = validateGeneratedProject(project, expected);
    validateGeneratedProjectFilesystem(arguments_[2]);
    validateGeneratedSchemes(
      readSchemes(path.join(arguments_[2], "xcshareddata", "xcschemes")),
      targetIdentifiers,
    );
    console.log("check-xcodegen-generated-boundary: project matches the approved boundary");
  } catch (error) {
    console.error(`check-xcodegen-generated-boundary: ${error.message}`);
    process.exitCode = 1;
  }
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main();
}
