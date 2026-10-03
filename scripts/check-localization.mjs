import fs from "node:fs";
import { formatSignature } from "./localization-formats.mjs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { checkSupportedLocaleLayout, loadSupportedLocales } from "./supported-locales.mjs";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const iosRoot = path.resolve(__dirname, "..");
const catalogs = [
  path.join(iosRoot, "LavaSecApp", "Localizable.xcstrings"),
  path.join(iosRoot, "LavaSecApp", "InfoPlist.xcstrings")
];
// NOTE: LavaSecIntents/Localizable.xcstrings (the Focus App Intents extension catalog) is
// intentionally NOT in this list — this gate also enforces app-only requiredReleaseKeys.
// Its completeness (all locales) is guaranteed by construction + the string-coverage gate.
let requiredLocales;
try {
  requiredLocales = loadSupportedLocales(iosRoot);
} catch (error) {
  console.error(error.message);
  process.exit(1);
}
const allowedUntranslatedValues = new Set([
  "Apple",
  "Cloudflare",
  "DNS",
  "DoH",
  "Google",
  "Lava Security",
  "Lava",
  "Quad9",
  "TCP",
  "VPN",
  "WireGuard",
  "LavaSec",
  "Lava Guard",
  "Lava Plus",
  "Lava Filter",
  "Face ID",
  "Touch ID",
  "LF1-…",
  "%@",
  " %@",
  " (%@)",
  "%1$@ %2$@",
  "%@. %@",
  "%@: %@",
  "%@: %@ (%@ %d).",
  "→",
  "iOS",
  "?"
]);
// The compact Live Activity Pause label is duration-only. These locales correctly share
// English's SI minute abbreviation, but the exception must stay scoped to this exact core key so
// the same English value remains a localization failure everywhere else.
const allowedUntranslatedCoreEntries = new Set([
  "es:widget.action.pauseForMinutesShort",
  "fr:widget.action.pauseForMinutesShort",
  "it:widget.action.pauseForMinutesShort",
  "pt-BR:widget.action.pauseForMinutesShort"
]);
// These interface labels are also the normal local words. Scope the exception
// to each catalog key and language so it cannot hide untranslated sentences.
const sharedAppTerms = new Set([
  "it:Account",
  "it:Password",
  "de:Filter",
  "de:Filter: %@",
  "de:Internet",
  "fr:Internet",
  "es:Internet",
  "pt-BR:Internet",
  "it:Internet",
  "it:Feedback",
  "pt-BR:Feedback",
  "it:Provider",
  "it:Social Media",
  "de:Version",
  "de:Build",
  "fr:Source",
  "de:App",
  "es:App",
  "fr:App",
  "it:App",
  "pt-BR:App",
  "de:Passkey",
  "it:Passkey",
  "pt-BR:Passkey",
  "de:Tunnel",
  "fr:Tunnel",
  "it:Tunnel",
  "de:Support",
  "fr:Support",
  "fr:Notifications",
  "de:Start",
  "de:Name",
  "de:Name (optional)",
  "it:Email",
  "de:Domain",
  "de:Details",
  "de:OK",
  "fr:OK",
  "ja:OK",
  "es:OK",
  "pt-BR:OK",
  "it:OK",
  "fr:Protection",
  "de:System",
  "de:Original",
  "es:Original",
  "fr:Original",
  "pt-BR:Original",
  "de:Amethyst",
  "de:Obsidian",
  "fr:Kiwi Crème",
  "de:Normal",
  "es:Normal",
  "fr:Normal",
  "pt-BR:Normal",
  "de:Sudoku",
  "fr:Sudoku",
  "es:Sudoku",
  "pt-BR:Sudoku",
  "it:Sudoku",
  "de:Emoji",
  "fr:Emoji",
  "es:Emoji",
  "pt-BR:Emoji",
  "it:Emoji",
  "fr:Narration"
]);
const requiredReleaseKeys = [
  "Guard",
  "Filter",
  "Filter: %@",
  "Activity",
  "Settings",
  "Close",
  "Cancel",
  "Save",
  "Edit",
  "Back",
  "Continue",
  "Turn On",
  "Turn Off",
  "Reconnect",
  "Protection Off",
  "Turning On",
  "Turning Off",
  "Protected",
  "Tap once to add local protection",
  "Turn on local protection when you are ready",
  "iOS is starting the local VPN",
  "iOS is stopping the local VPN",
  "Controls Lava's local DNS protection.",
  "Internet",
  "DNS",
  "Phone",
  "Not configured",
  "Configured",
  "Open DNS Resolver settings",
  "Blocked Domains",
  "Allowed Exceptions",
  "DNS options",
  "domains protected",
  "Other domains pass through",
  "No blocklists enabled",
  "Add a curated blocklist to start blocking known domains",
  "Add Blocklist",
  "No additional blocked domains",
  "Add Blocked Domain",
  "No allowed exceptions",
  "Add only domains you trust",
  "Add Exception",
  "Be extra careful",
  "Allowed exceptions can let a domain through even when a blocklist catches it. Double-check before saving",
  "Do you know this domain?",
  "Is the domain spelling correct?",
  "Is the domain flagged suspicious?",
  "Review",
  "Confirm Changes",
  "Local Logs",
  "Domain History",
  "Domain Logs",
  "Detailed activity stays on this phone for 7 days and is sent to us only if you include it in a bug report.",
  "Review Privacy & Data",
  "domains blocked",
  "Local history is off",
  "Turn on local history only if you want this searchable list.",
  "Turn On Local History",
  "Search domains",
  "No allowed domains saved yet",
  "No blocked domains saved yet",
  "No domains match this search",
  "No network activity yet",
  "Privacy & Data",
  "Help",
  "Bug Report",
  "DNS Resolver",
  "Use your own resolver",
  "Upgrade to use your own resolver",
  "Legal Notices",
  "Version & Nerd Stats",
  "Encrypted Backup",
  "Backup password",
  "Confirm backup password",
  "Use the iCloud Keychain password suggestion when it appears. Lava never receives this password.",
  "Copy recovery code",
  "Copied",
  "Turn On Backup",
  "Restore Backup",
  "Restore backup",
  "Password",
  "Recovery",
  "A site stopped working",
  "What Happened",
  "Preview",
  "Confirm Send",
  "Send Bug Report",
  "Send feedback?",
  "Send feedback",
  "Not now",
  "Looks like you shook your phone. Want to tell us what went wrong?"
];
let failed = false;

const fail = (message) => {
  console.error(message);
  failed = true;
};

for (const error of checkSupportedLocaleLayout(iosRoot)) {
  fail(error);
}

for (const catalogPath of catalogs) {
  if (!fs.existsSync(catalogPath)) {
    fail(`${path.relative(iosRoot, catalogPath)} is missing`);
    continue;
  }

  let catalog;
  try {
    catalog = JSON.parse(fs.readFileSync(catalogPath, "utf8"));
  } catch (error) {
    fail(`${path.relative(iosRoot, catalogPath)} is not valid JSON: ${error.message}`);
    continue;
  }

  if (catalog.sourceLanguage !== "en") {
    fail(`${path.relative(iosRoot, catalogPath)} must use en as sourceLanguage`);
  }

  for (const [key, value] of Object.entries(catalog.strings || {})) {
    if (!value.comment || value.comment.trim() === "") {
      fail(`${key}: missing translator comment`);
    }

    for (const locale of requiredLocales) {
      const unit = value.localizations?.[locale]?.stringUnit;
      if (!unit) {
        fail(`${key}: missing ${locale} localization`);
        continue;
      }

      if (!["translated", "reviewed"].includes(unit.state)) {
        fail(`${key}: ${locale} must be translated or reviewed`);
      }

      if (!unit.value || unit.value.trim() === "") {
        fail(`${key}: ${locale} value must not be empty`);
      }
    }

    const english = value.localizations?.en?.stringUnit?.value;
    for (const locale of requiredLocales.filter((item) => item !== "en")) {
      const translated = value.localizations?.[locale]?.stringUnit?.value;
      if (english !== undefined && translated !== undefined && formatSignature(english) !== formatSignature(translated)) {
        fail(`${key}: ${locale} format arguments differ from English`);
      }
      if (translated === english && !allowedUntranslatedValues.has(english)
          && !sharedAppTerms.has(`${locale}:${key}`)) {
        fail(`${key}: ${locale} still matches English source`);
      }
    }
  }

  if (catalogPath.endsWith("Localizable.xcstrings")) {
    for (const key of requiredReleaseKeys) {
      if (!catalog.strings?.[key]) {
        fail(`${key}: missing release app localization key`);
      }
    }
  }
}

// LavaSecKit ships widget/Live-Activity/tunnel-notification strings as legacy .strings files
// (loaded via Bundle.module), one .lproj per locale. Those catalogs live outside the two app
// xcstrings checked above, so without this pass a core key added EN-only would clear every gate.
// Enforce key-set parity against the English base + flag values byte-identical to English as
// likely-untranslated, reusing allowedUntranslatedValues so intentional brand/format strings pass.
const coreResourcesDir = path.join(iosRoot, "Sources", "LavaSecKit", "Resources");
// Grammar: "<key>" = "<value>"; — backslash escapes are kept intact so an escaped quote inside a
// value doesn't prematurely close the match. Comment/blank lines simply don't match.
const stringsEntryPattern = /^\s*"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;/;

const parseStringsFile = (filePath) => {
  const entries = new Map();
  for (const line of fs.readFileSync(filePath, "utf8").split(/\r?\n/)) {
    const match = line.match(stringsEntryPattern);
    if (!match && line.trim().startsWith('"')) fail(`${path.relative(iosRoot, filePath)}: malformed strings entry`);
    if (match) {
      if (entries.has(match[1])) fail(`${path.relative(iosRoot, filePath)}: duplicate key ${match[1]}`);
      if (!match[2].trim()) fail(`${path.relative(iosRoot, filePath)}: empty value for ${match[1]}`);
      entries.set(match[1], match[2]);
    }
  }
  return entries;
};

const coreStringsByLocale = new Map();
for (const locale of requiredLocales) {
  const filePath = path.join(coreResourcesDir, `${locale}.lproj`, "Localizable.strings");
  if (!fs.existsSync(filePath)) {
    fail(`LavaSecKit ${locale}.lproj/Localizable.strings is missing`);
    continue;
  }
  coreStringsByLocale.set(locale, parseStringsFile(filePath));
}

const coreBase = coreStringsByLocale.get("en");
if (coreBase) {
  for (const locale of requiredLocales.filter((item) => item !== "en")) {
    const entries = coreStringsByLocale.get(locale);
    if (!entries) {
      continue; // missing-file already reported above
    }

    for (const key of coreBase.keys()) {
      if (!entries.has(key)) {
        fail(`LavaSecKit ${locale}.lproj: missing key ${key}`);
      }
    }
    for (const key of entries.keys()) {
      if (!coreBase.has(key)) {
        fail(`LavaSecKit ${locale}.lproj: extra key not in English base: ${key}`);
      }
    }

    for (const [key, value] of entries) {
      const english = coreBase.get(key);
      if (english !== undefined && formatSignature(english) !== formatSignature(value)) {
        fail(`LavaSecKit ${locale}.lproj: ${key} format arguments differ from English`);
      }
      const scopedException =
        english === "%d min" && allowedUntranslatedCoreEntries.has(`${locale}:${key}`);
      if (
        english !== undefined &&
        value === english &&
        !allowedUntranslatedValues.has(english) &&
        !scopedException
      ) {
        fail(`LavaSecKit ${locale}.lproj: ${key} still matches English source`);
      }
    }
  }
}

// LavaSecIntents (the Focus App Intents extension) ships its own xcstrings, deliberately excluded
// from the `catalogs` list above because it must NOT carry the app-only requiredReleaseKeys. It
// still needs full per-locale coverage, so gate every key the same way as the app catalogs:
// present in all locales, translated/reviewed, non-empty.
const intentsCatalogPath = path.join(iosRoot, "LavaSecIntents", "Localizable.xcstrings");
if (!fs.existsSync(intentsCatalogPath)) {
  fail(`${path.relative(iosRoot, intentsCatalogPath)} is missing`);
} else {
  let intentsCatalog = null;
  try {
    intentsCatalog = JSON.parse(fs.readFileSync(intentsCatalogPath, "utf8"));
  } catch (error) {
    fail(`${path.relative(iosRoot, intentsCatalogPath)} is not valid JSON: ${error.message}`);
  }

  if (intentsCatalog) {
    if (intentsCatalog.sourceLanguage !== "en") {
      fail(`${path.relative(iosRoot, intentsCatalogPath)} must use en as sourceLanguage`);
    }

    for (const [key, value] of Object.entries(intentsCatalog.strings || {})) {
      if (!value.comment?.trim()) fail(`LavaSecIntents ${key}: missing translator comment`);
      for (const locale of requiredLocales) {
        const unit = value.localizations?.[locale]?.stringUnit;
        if (!unit) {
          fail(`LavaSecIntents ${key}: missing ${locale} localization`);
          continue;
        }

        if (!["translated", "reviewed"].includes(unit.state)) {
          fail(`LavaSecIntents ${key}: ${locale} must be translated or reviewed`);
        }

        if (!unit.value || unit.value.trim() === "") {
          fail(`LavaSecIntents ${key}: ${locale} value must not be empty`);
        }

        // Mirror the app-catalog + core `.strings` passes: a non-English value byte-identical
        // to the English source is a likely copied-English string that shipped marked
        // translated/reviewed. Allowlisted brand/format strings (Lava Security, %@, …) pass.
        if (locale !== "en") {
          const english = value.localizations?.en?.stringUnit?.value;
          if (english !== undefined && formatSignature(english) !== formatSignature(unit.value)) {
            fail(`LavaSecIntents ${key}: ${locale} format arguments differ from English`);
          }
          if (english !== undefined && unit.value === english && !allowedUntranslatedValues.has(english) && !sharedAppTerms.has(`${locale}:${key}`)) {
            fail(`LavaSecIntents ${key}: ${locale} still matches English source`);
          }
        }
      }
    }
  }
}

if (failed) {
  process.exit(1);
}

console.log("localization checks passed");
