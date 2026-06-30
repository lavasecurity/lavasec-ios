#!/usr/bin/env node
// Catalog-coverage gate. Three checks, scoped to the bundle each string can actually
// be resolved from at runtime:
//
// (1) User-facing strings at localizing call sites must exist in a bundle the running
//     target can read:
//       - LavaSecApp sources  -> app catalog (Localizable/InfoPlist.xcstrings) OR LavaSecCore .strings
//       - LavaSecWidget + Shared sources -> LavaSecCore .strings ONLY (the widget extension's
//         Resources phase is empty; it reads LavaSecCore via Bundle.module, NOT the app catalog)
//       - AppIntents metadata (LocalizedStringResource / IntentDescription), wherever it lives,
//         -> app catalog (the OS resolves AppIntents metadata from the registering app target)
// (2) Every `LavaCoreStrings.localized("key")` / `.localizedFormat("key")` reference must
//     resolve to a key in LavaSecCore's en Localizable.strings.
// (3) Interpolated `.lavaLocalized` literals fail (they form uncatalogued runtime keys); use
//     a format key (e.g. "Word %lld".lavaLocalizedFormat(n)).
//
// Conservative: only literal arguments at high-confidence localizing sites are checked;
// interpolated literals (except .lavaLocalized), identifiers, URLs, and QA-only UI are skipped.
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const iosRoot = path.resolve(__dirname, "..");
const scanDirs = [
  path.join(iosRoot, "LavaSecApp"),
  path.join(iosRoot, "LavaSecWidget"),
  path.join(iosRoot, "Shared"),
  path.join(iosRoot, "LavaSecIntents"),
];
const coreStringsFile = path.join(
  iosRoot, "Sources", "LavaSecCore", "Resources", "en.lproj", "Localizable.strings"
);

const ALLOWED = new Set([
  "Account", "Password", "Apple", "Cloudflare", "Filter", "DNS", "DoH",
  "Google", "Guard", "Internet", "Lava", "Lava Security", "Lava Security Plus",
  "Lava Guard", "Lava Plus", "Plus", "Core", "Balanced", "Extra", "Quad9", "TCP",
  "VPN", "LavaSec", "OK", "iOS", "Face ID", "Touch ID",
]);

const catalogKeys = new Set();
for (const f of ["Localizable.xcstrings", "InfoPlist.xcstrings"]) {
  const j = JSON.parse(fs.readFileSync(path.join(iosRoot, "LavaSecApp", f), "utf8"));
  for (const k of Object.keys(j.strings ?? {})) catalogKeys.add(k);
}
const coreKeys = new Set();
for (const m of fs.readFileSync(coreStringsFile, "utf8").matchAll(/^\s*"([^"]+)"\s*=/gm)) {
  coreKeys.add(m[1]);
}
// LavaSecIntents has its OWN String Catalog — its AppIntents metadata resolves from the
// extension's bundle at the default lookup, not the app catalog.
const intentsKeys = new Set();
{
  const f = path.join(iosRoot, "LavaSecIntents", "Localizable.xcstrings");
  if (fs.existsSync(f)) for (const k of Object.keys(JSON.parse(fs.readFileSync(f, "utf8")).strings ?? {})) intentsKeys.add(k);
}
const appKnown = new Set([...catalogKeys, ...ALLOWED]);                 // AppIntents metadata + app UI
const coreKnown = new Set([...coreKeys, ...ALLOWED]);                   // widget/extension (Bundle.module)
const appOrCore = new Set([...catalogKeys, ...coreKeys, ...ALLOWED]);   // app UI (app bundle or LavaSecCore)
// LavaSecIntents validates strictly against its own catalog (intentsKeys) — see the loop.

const unesc = (s) =>
  s.replace(/\\(["nt\\])/g, (_, c) => (c === "n" ? "\n" : c === "t" ? "\t" : c));

const L = `"((?:[^"\\\\]|\\\\.)*)"`;
const labels =
  "(?:title|summary|subtitle|footer|label|description|placeholder|actionTitle|disableTitle|disableActionTitle|clearTitle|clearActionTitle|detail|text|reason)";
const sitePatterns = [
  `\\bText\\(\\s*${L}`, `\\bLabel\\(\\s*${L}`, `\\bButton\\(\\s*${L}\\s*[\\),]`,
  `\\.navigation(?:Bar)?Title\\(\\s*${L}`, `\\bToggle\\(\\s*${L}`, `\\bSection\\(\\s*${L}`,
  `\\bTextField\\(\\s*${L}`, `\\bSecureField\\(\\s*${L}`, `\\.accessibilityLabel\\(\\s*${L}`,
  `\\.accessibilityHint\\(\\s*${L}`, `\\.accessibilityValue\\(\\s*${L}`,
  `\\b(?:alert|confirmationDialog)\\(\\s*${L}`, `\\bLink\\(\\s*${L}`, `\\bMenu\\(\\s*${L}`,
  `\\bPicker\\(\\s*${L}`, `\\bStepper\\(\\s*${L}`, `\\.help\\(\\s*${L}`,
  `\\.searchable\\([^)]*?prompt:\\s*${L}`, `\\bLavaSectionGroup\\(\\s*${L}`, `\\b${labels}:\\s*${L}`,
].map((p) => new RegExp(p, "g"));
// AppIntents metadata resolves from the registering app target -> validate against the app catalog.
const appIntentsPatterns = [
  `\\bLocalizedStringResource\\(\\s*${L}`, `\\bLocalizedStringResource\\s*=\\s*${L}`,
  `\\bIntentDescription\\(\\s*${L}`, `\\bDisplayRepresentation\\(\\s*title:\\s*${L}`,
].map((p) => new RegExp(p, "g"));
// `Summary("…")` (AppIntents ParameterSummary) is bundle-scoped to LavaSecIntents and carries a
// parameter KeyPath interpolation `\(\.$name)`, which appintentsmetadataprocessor lowers to the
// catalog token `${name}` — NOT a printf `%@` (verified against the build's
// ExtractedAppShortcutsMetadata.stringsdata / extract.actionsdata). clean() would drop it on the
// `\(` test, so this path handles the transform explicitly and checks the extension catalog.
const summaryPattern = new RegExp(`\\bSummary\\(\\s*${L}`, "g");
const summaryToKey = (raw) =>
  unesc(raw).replace(/\\\(\s*\\\.\$(\w+)\s*\)/g, (_, name) => `\${${name}}`);
const presReturn = new RegExp(`\\breturn\\s+${L}`, "g");
const coreRef = new RegExp(`LavaCoreStrings\\.(?:localized|localizedFormat)\\(\\s*${L}`, "g");
const lavaCall = /\.lavaLocalized(?:Format)?/g;
const LITRE = /"((?:[^"\\]|\\.)*)"/g;
// Harvest string literals from a label arg that is NOT a bare literal (a ternary/computed
// `title: cond ? "A" : "B"`). The named-label site only matches a literal immediately after the
// label, so these branch strings were invisible (this missed "Back Up Now"/"Backing Up"). String-
// aware + bracket-balanced; stops at the arg's terminating comma or its closing paren/bracket.
function litsInArg(txt, start) {
  let depth = 0, end = txt.length;
  for (let j = start; j < txt.length; j++) {
    const c = txt[j];
    if (c === '"') { j++; while (j < txt.length && !(txt[j] === '"' && txt[j - 1] !== "\\")) j++; continue; }
    if (c === "\n") { end = j; break; } // single-line only — avoids over-scanning multi-line closures/exprs
    if (c === "(" || c === "[") depth++;
    else if (c === ")" || c === "]") { if (depth === 0) { end = j; break; } depth--; }
    else if (c === "," && depth === 0) { end = j; break; }
  }
  LITRE.lastIndex = 0;
  return [...txt.slice(start, end).matchAll(LITRE)].map((m) => m[1]);
}
// Negative lookbehind excludes Swift type annotations (`var title: LocalizedStringResource = …`,
// `let detail: String`), which are declarations — not labeled call args — and are already covered
// by the AppIntents patterns where relevant.
const labelTernary = new RegExp(`(?<!\\b(?:var|let)\\s)\\b${labels}:\\s*(?![",\\s])`, "g");

// Release-localization gate: strings compiled ONLY into DEBUG / LAVA_QA_TOOLS builds never ship,
// so drop those branches before scanning (otherwise dev tooling — the live-DNS-smoke harness,
// Protection-States simulator, raw counters — shows up as bogus "untranslated" misses). Keeps the
// `#else` branch (which DOES ship) and handles nesting. Non-debug directives keep both branches.
function stripDebugOnly(src) {
  const out = [];
  const stack = []; // { debugOnly, inElse }
  for (const line of src.split("\n")) {
    const t = line.trim();
    if (/^#if\b/.test(t)) {
      const cond = t.slice(3);
      const debugOnly = (/\bDEBUG\b/.test(cond) && !/!\s*DEBUG\b/.test(cond)) || /\bLAVA_QA_TOOLS\b/.test(cond);
      stack.push({ debugOnly, inElse: false });
      continue;
    }
    if (/^#elseif\b/.test(t) || /^#else\b/.test(t)) { if (stack.length) stack[stack.length - 1].inElse = true; continue; }
    if (/^#endif\b/.test(t)) { stack.pop(); continue; }
    if (!stack.some((s) => s.debugOnly && !s.inElse)) out.push(line);
  }
  return out.join("\n");
}

// Structural filter only — membership is checked per-context by the caller.
function clean(raw) {
  if (raw.includes("\\(")) return null;
  const s = unesc(raw);
  if (/^[a-z0-9_.\-/]+$/.test(s)) return null;
  if (!/[A-Za-z]/.test(s)) return null;
  if (/^(https?:|com\.|group\.)/.test(s)) return null;
  if (/(sslip\.io|QA|systemName)/.test(s)) return null; // Smoke/Probe dropped: dev tooling is excluded by stripDebugOnly; shipped "Smoke Test"/"DNS smoke probes" labels must be catalogued
  return s;
}

// Raw string literals (with escapes) in the primary expression immediately before
// a `.lavaLocalized` call — handles both `"x".lavaLocalized` and a parenthesized/
// ternary expr `(cond ? "a" : "b").lavaLocalized` (balanced parens, so nested
// calls like `isFrozen(id)` don't fool it).
function litsBeforeLava(txt, dotIdx) {
  let j = dotIdx - 1;
  while (j >= 0 && /\s/.test(txt[j])) j--;
  if (j < 0) return [];
  if (txt[j] === ")") {
    let depth = 0, k = j;
    for (; k >= 0; k--) {
      if (txt[k] === ")") depth++;
      else if (txt[k] === "(") { depth--; if (depth === 0) break; }
    }
    if (k < 0) return [];
    LITRE.lastIndex = 0;
    return [...txt.slice(k, j + 1).matchAll(LITRE)].map((m) => m[1]);
  }
  if (txt[j] === '"') {
    let k = j - 1;
    while (k >= 0 && !(txt[k] === '"' && txt[k - 1] !== "\\")) k--;
    return [txt.slice(k + 1, j)];
  }
  return [];
}

function walk(dir) {
  const out = [];
  if (!fs.existsSync(dir)) return out;
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) out.push(...walk(p));
    else if (e.name.endsWith(".swift") && !e.name.includes("AdminQA")) out.push(p);
  }
  return out;
}

const missing = new Map(); // string -> Set("file [needs: bundle]")
const badCoreRefs = new Map();
const badInterp = new Map();
const flag = (map, key, note) => {
  if (!map.has(key)) map.set(key, new Set());
  map.get(key).add(note);
};

for (const file of scanDirs.flatMap(walk)) {
  const txt = stripDebugOnly(fs.readFileSync(file, "utf8"));
  const rel = path.relative(iosRoot, file);
  const isIntents = rel.startsWith("LavaSecIntents");
  const isExt = rel.startsWith("LavaSecWidget") || rel.startsWith("Shared");
  // LavaSecIntents strings resolve ONLY from the extension's own catalog (AppIntents
  // metadata is compile-time bundle-scoped) — not coreKeys/ALLOWED, so e.g. a literal
  // like "Filter" must be in the extension catalog, not merely allowlisted.
  const general = isIntents ? intentsKeys : isExt ? coreKnown : appOrCore;
  const generalLabel = isIntents
    ? "LavaSecIntents catalog"
    : isExt ? "LavaSecCore .strings" : "app catalog or LavaSecCore";

  const patterns = file.endsWith("Presentation.swift") ? [...sitePatterns, presReturn] : sitePatterns;
  for (const re of patterns) {
    re.lastIndex = 0;
    let m;
    while ((m = re.exec(txt)) !== null) {
      const s = clean(m[1]);
      if (s && !general.has(s)) flag(missing, s, `${rel} [needs: ${generalLabel}]`);
    }
  }
  // Ternary/computed args at a localizing label (e.g. `title: cond ? "A" : "B"`) — harvest each
  // branch literal so a non-bare-literal arg can't smuggle an uncatalogued user-facing string.
  labelTernary.lastIndex = 0;
  let tm;
  while ((tm = labelTernary.exec(txt)) !== null) {
    for (const raw of litsInArg(txt, tm.index + tm[0].length)) {
      const s = clean(raw);
      if (s && !general.has(s)) flag(missing, s, `${rel} [needs: ${generalLabel}]`);
    }
  }
  for (const re of appIntentsPatterns) {
    re.lastIndex = 0;
    let m;
    while ((m = re.exec(txt)) !== null) {
      const s = clean(m[1]);
      const aiKnown = isIntents ? intentsKeys : appKnown;
      if (s && !aiKnown.has(s)) flag(missing, s, `${rel} [needs: ${isIntents ? "LavaSecIntents catalog" : "app catalog"}]`);
    }
  }
  // ParameterSummary — LavaSecIntents only; interpolation-aware (yields the `${name}` token form
  // the metadata processor extracts), so it bypasses clean()'s `\(`-drop and validates against the
  // extension catalog. The /[A-Za-z]/ guard skips a hypothetical token-only summary.
  if (isIntents) {
    summaryPattern.lastIndex = 0;
    let sm;
    while ((sm = summaryPattern.exec(txt)) !== null) {
      const key = summaryToKey(sm[1]);
      if (/[A-Za-z]/.test(key) && !intentsKeys.has(key)) {
        flag(missing, key, `${rel} [needs: LavaSecIntents catalog]`);
      }
    }
  }
  lavaCall.lastIndex = 0;
  let lm;
  while ((lm = lavaCall.exec(txt)) !== null) {
    for (const raw of litsBeforeLava(txt, lm.index)) {
      if (raw.includes("\\(")) { flag(badInterp, raw, rel); continue; }
      const s = clean(raw);
      if (s && !general.has(s)) flag(missing, s, `${rel} [needs: ${generalLabel}]`);
    }
  }
  coreRef.lastIndex = 0;
  let cm;
  while ((cm = coreRef.exec(txt)) !== null) {
    const key = unesc(cm[1]);
    if (!coreKeys.has(key)) flag(badCoreRefs, key, rel);
  }
}

let failed = false;
if (missing.size > 0) {
  failed = true;
  console.error(
    `String-coverage check FAILED: ${missing.size} user-facing string(s) at localizing call sites are not in a bundle the running target can read, so they render English for non-English locales:\n`
  );
  for (const [s, notes] of [...missing].sort()) console.error(`  ${JSON.stringify(s)}  — ${[...notes].join(", ")}`);
}
if (badCoreRefs.size > 0) {
  failed = true;
  console.error(`\nLavaCoreStrings reference check FAILED: ${badCoreRefs.size} key(s) missing from LavaSecCore en Localizable.strings:\n`);
  for (const [k, files] of [...badCoreRefs].sort()) console.error(`  ${JSON.stringify(k)}  — ${[...files].join(", ")}`);
}
if (badInterp.size > 0) {
  failed = true;
  console.error(`\nInterpolated .lavaLocalized check FAILED: ${badInterp.size} literal(s) interpolate into the key (uncatalogued runtime keys). Use a format key (e.g. "Word %lld".lavaLocalizedFormat(n)):\n`);
  for (const [k, files] of [...badInterp].sort()) console.error(`  ${JSON.stringify(k)}  — ${[...files].join(", ")}`);
}
if (failed) process.exit(1);
console.log(
  `String-coverage check passed — app + widget + shared localizing call sites resolve from a readable bundle (${catalogKeys.size} app keys, ${coreKeys.size} core keys).`
);
