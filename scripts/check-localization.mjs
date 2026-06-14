import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const iosRoot = path.resolve(__dirname, "..");
const catalogs = [
  path.join(iosRoot, "LavaSecApp", "Localizable.xcstrings"),
  path.join(iosRoot, "LavaSecApp", "InfoPlist.xcstrings")
];
const requiredLocales = ["en", "ja", "zh-Hant", "zh-Hans", "de", "fr"];
const allowedUntranslatedValues = new Set([
  "Apple",
  "Cloudflare",
  "DNS",
  "DoH",
  "Google",
  "Internet",
  "Lava Security",
  "Quad9",
  "TCP",
  "VPN",
  "LavaSec",
  "%@",
  " %@",
  "%1$@ %2$@",
  "%@. %@",
  "OK",
  "→",
  "iOS"
]);
const requiredReleaseKeys = [
  "Guard",
  "Filters",
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
  "Local filters",
  "Phone",
  "Not configured",
  "Configured",
  "Open DNS Resolver settings",
  "Open Filters",
  "Manage filters",
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
  "All local logs stay on this phone and are sent to us only if you include them in a bug report.",
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
  "Send Bug Report"
];
let failed = false;

const fail = (message) => {
  console.error(message);
  failed = true;
};

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
      if (translated === english && !allowedUntranslatedValues.has(english)) {
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

if (failed) {
  process.exit(1);
}

console.log("localization checks passed");
