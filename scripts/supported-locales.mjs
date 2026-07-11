import fs from "node:fs";
import path from "node:path";

const manifestRelativePath = "Config/supported-locales.json";
const catalogRelativePaths = [
  "LavaSecApp/Localizable.xcstrings",
  "LavaSecApp/InfoPlist.xcstrings",
  "LavaSecIntents/Localizable.xcstrings"
];

/** Loads and validates the ordered locale manifest shared by localization tooling. */
export function loadSupportedLocales(iosRoot) {
  const manifestPath = path.join(iosRoot, manifestRelativePath);
  const manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8"));
  const locales = manifest.locales;

  if (!Array.isArray(locales) || locales.length === 0) {
    throw new Error(`${manifestRelativePath} must contain a non-empty locales array`);
  }
  if (locales.some((locale) => typeof locale !== "string" || locale.trim() === "")) {
    throw new Error(`${manifestRelativePath} locales must be non-empty strings`);
  }
  if (new Set(locales).size !== locales.length) {
    throw new Error(`${manifestRelativePath} locales must be unique`);
  }
  if (locales[0] !== "en") {
    throw new Error(`${manifestRelativePath} must list source locale en first`);
  }
  if (locales.includes("Base")) {
    throw new Error(`${manifestRelativePath} must not include Xcode-only region Base`);
  }

  return locales;
}

function compareLocaleSets(label, expectedLocales, actualLocales) {
  const expected = new Set(expectedLocales);
  const actual = new Set(actualLocales);
  const missing = [...expected].filter((locale) => !actual.has(locale)).sort();
  const extra = [...actual].filter((locale) => !expected.has(locale)).sort();
  const errors = [];
  if (missing.length > 0) {
    errors.push(`${label}: missing locales: ${missing.join(", ")}`);
  }
  if (extra.length > 0) {
    errors.push(`${label}: unsupported locales: ${extra.join(", ")}`);
  }
  return errors;
}

function catalogLocaleErrors(iosRoot, relativePath, supportedLocales) {
  const filePath = path.join(iosRoot, relativePath);
  if (!fs.existsSync(filePath)) {
    return [`${relativePath} is missing`];
  }

  let catalog;
  try {
    catalog = JSON.parse(fs.readFileSync(filePath, "utf8"));
  } catch (error) {
    return [`${relativePath} is not valid JSON: ${error.message}`];
  }

  const errors = [];
  for (const [key, entry] of Object.entries(catalog.strings || {})) {
    errors.push(...compareLocaleSets(
      `${relativePath} ${JSON.stringify(key)}`,
      supportedLocales,
      Object.keys(entry.localizations || {})
    ));
  }
  return errors;
}

function kitLocaleErrors(iosRoot, supportedLocales) {
  const relativePath = "Sources/LavaSecKit/Resources";
  const resourcesPath = path.join(iosRoot, relativePath);
  if (!fs.existsSync(resourcesPath)) {
    return [`${relativePath} is missing`];
  }
  const actualLocales = fs.readdirSync(resourcesPath, { withFileTypes: true })
    .filter((entry) => entry.isDirectory() && entry.name.endsWith(".lproj"))
    .map((entry) => entry.name.slice(0, -".lproj".length));
  return compareLocaleSets("LavaSecKit .lproj resources", supportedLocales, actualLocales);
}

function knownRegionErrors(iosRoot, supportedLocales) {
  const relativePath = "LavaSec.xcodeproj/project.pbxproj";
  const projectPath = path.join(iosRoot, relativePath);
  if (!fs.existsSync(projectPath)) {
    return [`${relativePath} is missing`];
  }
  const project = fs.readFileSync(projectPath, "utf8");
  const block = project.match(/knownRegions = \(([^)]*)\);/s)?.[1];
  if (block === undefined) {
    return [`${relativePath} knownRegions block is missing`];
  }
  const actualRegions = block
    .split("\n")
    .map((line) => line.replace(/\/\*.*?\*\//g, "").trim().replace(/,$/, ""))
    .map((line) => line.replace(/^"|"$/g, ""))
    .filter(Boolean);
  return compareLocaleSets(
    "LavaSec.xcodeproj knownRegions",
    ["Base", ...supportedLocales],
    actualRegions
  );
}

/** Returns every exact locale-layout mismatch without hiding later products after one failure. */
export function checkSupportedLocaleLayout(iosRoot) {
  let supportedLocales;
  try {
    supportedLocales = loadSupportedLocales(iosRoot);
  } catch (error) {
    return [`${manifestRelativePath}: ${error.message}`];
  }

  return [
    ...catalogRelativePaths.flatMap((relativePath) => (
      catalogLocaleErrors(iosRoot, relativePath, supportedLocales)
    )),
    ...kitLocaleErrors(iosRoot, supportedLocales),
    ...knownRegionErrors(iosRoot, supportedLocales)
  ];
}
