// A liveness + size smoke test for the blocklist catalog's upstreams.
//
// WHY THIS EXISTS. On 2026-08-10 a QA device sat in a total DNS outage for five hours. The
// cause was not in the app. Two catalog entries had rotted and nothing was watching:
//
//   * All 11 `hagezi-*` entries were fine when reviewed 2026-08-03..05. Then GitHub locked
//     the account and `github.com/hagezi/dns-blocklists` began returning a 14-byte
//     "404: Not Found" — a dead source dressed as a fetch that "succeeded".
//   * `blocklistproject-malware` was accepted 2026-06-30 at ~12.9 MB / 435k entries. By
//     2026-07-18 the upstream had grown to ~72 MB / 2.66M entries — over the 45 MB byte cap
//     AND over the 2,000,000 rule cap, so it is inadmissible at every tier.
//
// Either one wedges a device that enables it: the snapshot prepare is all-or-nothing, so one
// bad source denies the device every other source's rules, no artifact is written, coverage
// never holds, and the tunnel serves fail-closed block-all with no path back.
//
// WHAT THIS IS, AND IS NOT. It is a MONITORING script: fetch each upstream, ask "is this still
// a real list, and would the app accept it?", throw the bytes away. It is NOT the device
// fetcher and does not try to be. It runs on an ephemeral CI runner and nothing downstream
// acts on its connections. It restricts source requests and every redirect to reviewed public
// HTTPS distribution hosts so a catalog edit cannot probe runner-local services. It does not
// duplicate the device's connection-pinning machinery. Two questions, answered cheaply:
//   1. reachable, and a real domain list (not a 404, a 200-served error page, or an empty file)
//   2. within the byte + rule caps the app actually enforces
//
// The caps are read out of Swift (not copied) so they cannot silently drift from the code.
//
// WHY IT IS NOT A PR GATE. It talks to the live internet; as a required check, one upstream's
// bad afternoon would block every unrelated PR. Scheduled + on demand, and a human reads it.
//
// Usage:
//   node scripts/check-catalog-sources.mjs                # the SERVED catalog (what devices use)
//   node scripts/check-catalog-sources.mjs --vendored      # the in-repo adopted index
//   node scripts/check-catalog-sources.mjs --json
//   node scripts/check-catalog-sources.mjs --id oisd-big
// --id narrows upstream downloads only. The live catalog consistency verdict is
// always global: a document-level defect can make even the selected list unusable.

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const iosRoot = path.resolve(__dirname, "..");

const SERVED_CATALOG_URL = "https://api.lavasecurity.app/v1/catalog";
const FALLBACK_CATALOG_URL = "https://lavasec-api.lavasec.workers.dev/v1/catalog";
const VENDORED_CATALOG_PATH = path.join(iosRoot, "Catalog", "blocklist-catalog.json");
const BUDGET_PATH = path.join(
  iosRoot, "Sources", "LavaSecFilterPipeline", "BlocklistCatalogSync.swift");
const TIER_PATH = path.join(iosRoot, "Sources", "LavaSecKit", "SubscriptionPolicy.swift");

// A body this small is not a blocklist — it is the shape a 404 page or an emptied file takes,
// both of which read as "fetch succeeded" downstream. `raw.githubusercontent.com` serves
// exactly 14 bytes for a repository that no longer exists.
const MINIMUM_PLAUSIBLE_BYTES = 1024;

// A real list is mostly domain-ish lines. An HTML error document served with a 200 is mostly
// markup. If fewer than this share of the sampled non-comment lines look like a hostname, the
// body is not a blocklist even though the byte count cleared the floor.
const MINIMUM_DOMAIN_LINE_SHARE = 0.5;
const SAMPLE_LINES = 400;

// How far a source may drift from its accepted byte_size before it is worth a look. This is
// the check with actual preventive power: the malware list did not fail the day it crossed
// 45 MB, it spent six weeks growing 2x, 3x, 4x with everything green. A quarter is well clear
// of organic churn between reviews and would have flagged it in week one.
const BYTE_DRIFT_TOLERANCE = 0.25;

const REQUEST_TIMEOUT_MS = 60_000;
// Enough parallelism to finish under a minute, not enough to look like an attack to one host.
const MAX_CONCURRENT = 6;

// Adopted catalogs use these public distribution services. A new host needs an explicit
// checker change alongside curation; PR-supplied URLs cannot expand the network boundary.
const SOURCE_HOSTS = new Set([
  "raw.githubusercontent.com", "cdn.jsdelivr.net", "adguardteam.github.io", "blocklistproject.github.io",
]);

function admittedSourceURL(value) {
  const url = new URL(value);
  if (url.protocol !== "https:" || url.username || url.password || url.port || !SOURCE_HOSTS.has(url.hostname)) {
    throw new Error("source URL must use HTTPS on a reviewed public distribution host without credentials or a custom port");
  }
  return url;
}

// Validate BEFORE each request. Automatic redirects would follow an unreviewed/internal
// target before the final-URL check could reject it; cancel redirect bodies before continuing.
export async function fetchCatalogSource(value, signal, fetcher = fetch) {
  let url = admittedSourceURL(value);
  for (let redirects = 0; ; redirects++) {
    const response = await fetcher(url.href, {
      signal, redirect: "manual",
      headers: { "User-Agent": "lavasec-catalog-check/1", "Accept-Encoding": "identity" },
    });
    if (![301, 302, 303, 307, 308].includes(response.status)) return response;
    await response.body?.cancel();
    if (redirects >= 20) throw new Error("source exceeded 20 redirects");
    const location = response.headers.get("location");
    if (!location) throw new Error("source redirect lacks Location");
    url = admittedSourceURL(new URL(location, url));
  }
}

/// Read a numeric limit out of Swift rather than copying it here. A duplicated limit passes on
/// the day it is written and then silently disagrees with the code forever after. A failed
/// parse is a HARD error: a checker that falls back to a guessed cap reports green against the
/// wrong number, which is worse than not running.
function readSwiftLimit(file, anchor, pattern, describe) {
  const swift = fs.readFileSync(file, "utf8");
  const at = swift.indexOf(anchor);
  if (at === -1) {
    throw new Error(
      `could not find ${describe} in ${file} (anchor: ${anchor}) — it moved; ` +
      "update this checker rather than hardcoding a number");
  }
  const match = swift.slice(at, at + 600).match(pattern);
  if (!match) throw new Error(`found ${describe} but could not parse its value`);
  return match;
}

function readMaximumBlocklistBytes() {
  const m = readSwiftLimit(
    BUDGET_PATH,
    "public static let `default` = BlocklistParseResourceBudget(",
    /maximumBlocklistBytes:\s*(\d+)\s*\*\s*(\d+)\s*\*\s*(\d+)/,
    "BlocklistParseResourceBudget.default");
  return Number(m[1]) * Number(m[2]) * Number(m[3]);
}

/// The cap production enforces is `FeatureLimits.plus.maxFilterRules`
/// (`BlocklistParseResourceBudget.default.maxRulesPerSource` reads `plus`, not `paid`). Today
/// `plus = paid`, so following the alias matters only the day they diverge — at which point a
/// checker anchored on `paid` would silently enforce the wrong cap.
function readPlusRuleCap() {
  const swift = fs.readFileSync(TIER_PATH, "utf8");
  const alias = swift.match(/public static let plus\s*=\s*([A-Za-z_][A-Za-z0-9_]*)\s*$/m);
  const target = alias ? alias[1] : "plus";
  const m = readSwiftLimit(
    TIER_PATH,
    `public static let ${target} = FeatureLimits(`,
    /maxFilterRules:\s*([\d_]+)/,
    `FeatureLimits.${target}${alias ? " (aliased by .plus)" : ""}`);
  return Number(m[1].replace(/_/g, ""));
}

/// The device rejects a catalog DOCUMENT larger than this before decoding it
/// (`BlocklistCatalogRepository.maximumCatalogBytes`), which drops EVERY source at once — the
/// total-outage case this watchdog exists for. Read from Swift like the per-source caps.
function readMaximumCatalogBytes() {
  const m = readSwiftLimit(
    path.join(iosRoot, "Sources", "LavaSecFilterPipeline", "BlocklistCatalogRepository.swift"),
    "static let maximumCatalogBytes",
    /maximumCatalogBytes\s*=\s*(\d+)\s*\*\s*(\d+)\s*\*\s*(\d+)/,
    "BlocklistCatalogRepository.maximumCatalogBytes");
  return Number(m[1]) * Number(m[2]) * Number(m[3]);
}

async function loadCatalog(useVendored, servedCatalogURL = SERVED_CATALOG_URL) {
  const catalogCap = readMaximumCatalogBytes();
  const overCatalogCap = (label, byteLength) => {
    if (byteLength > catalogCap) {
      throw new Error(
        `${label}: catalog document is ${byteLength.toLocaleString()} bytes, over the ` +
        `${catalogCap.toLocaleString()}-byte ceiling the device rejects BEFORE decoding — ` +
        "every source would be dropped at once");
    }
  };

  // The device passes the raw catalog `Data` to `JSONDecoder`, which rejects invalid UTF-8. A
  // lenient `Buffer.toString("utf8")` would replace a bad byte with U+FFFD and parse anyway, so
  // decode strictly and let JSON.parse fail on what the device would reject. (Codex, #530.)
  const decodeStrict = (bytes, label) => {
    try {
      return new TextDecoder("utf-8", { fatal: true }).decode(bytes);
    } catch {
      throw new Error(`${label}: catalog contains invalid UTF-8, which the device's JSONDecoder rejects`);
    }
  };

  if (useVendored) {
    const raw = fs.readFileSync(VENDORED_CATALOG_PATH);
    overCatalogCap(VENDORED_CATALOG_PATH, raw.byteLength);
    return { label: VENDORED_CATALOG_PATH, catalog: JSON.parse(decodeStrict(raw, VENDORED_CATALOG_PATH)) };
  }
  // The device fetches the catalog DOCUMENT itself through PinnedPublicHTTPSFetcher, which
  // requests `identity` and fails closed on any other `Content-Encoding`. So request identity
  // and reject a compressed catalog here too — otherwise Node would transparently decode it and
  // report every source healthy while devices can't fetch the catalog at all. (Codex, #530.)
  const response = await fetch(servedCatalogURL, {
    redirect: "follow", headers: { "Accept-Encoding": "identity" },
  });
  if (!response.ok) throw new Error(`${servedCatalogURL}: served catalog returned HTTP ${response.status}`);
  const encoding = (response.headers.get("content-encoding") ?? "identity").toLowerCase();
  if (encoding !== "identity") {
    throw new Error(
      `served catalog returned Content-Encoding: ${encoding} despite an identity request — ` +
      "the device requests identity and rejects it, so the catalog is unfetchable on device");
  }
  // Size-check the raw bytes before decoding, exactly as the device does. (Codex, #530.)
  const body = Buffer.from(await response.arrayBuffer());
  overCatalogCap(servedCatalogURL, body.byteLength);
  const catalog = JSON.parse(decodeStrict(body, servedCatalogURL));
  // The device's runtime decoder (`BlocklistCatalog.init(from:)`) rejects the whole document —
  // a total outage — unless it is schema_version 2 AND carries every field it decodes
  // non-optionally: `catalog_version`, `generated_at`, `sources`, `guardrails`. A missing key
  // (e.g. `guardrails` omitted, which this checker would otherwise treat as `[]`) fails the
  // device before it fetches a single source.
  //
  // Checked for the SERVED catalog only: the vendored `Catalog/blocklist-catalog.json` is
  // schema 1 BY DESIGN — a build-time input to `generate-blocklist-catalog.mjs` that never goes
  // through this runtime decoder. (Codex, #530.)
  if (catalog.schema_version !== 2) {
    throw new Error(
      `served catalog schema_version is ${catalog.schema_version}, but the device's decoder ` +
      "requires 2 and rejects the whole document — every source would be dropped at once");
  }
  for (const field of ["catalog_version", "generated_at", "sources", "guardrails"]) {
    if (!(field in catalog)) {
      throw new Error(
        `served catalog is missing the required field "${field}" — the device's decoder ` +
        "rejects the whole document, dropping every source at once");
    }
  }
  validateServedCatalog(catalog, servedCatalogURL);
  return { label: servedCatalogURL, catalog };
}

// Required Codable fields in CatalogSourceModels.swift, including nested hash rows.
// This is a metadata/schema check; upstream network safety stays with the device.
export function validateServedCatalog(catalog, label = "served catalog") {
  const requireValue = (valid, field) => {
    if (!valid) throw new Error(`${label}: invalid or missing ${field}`);
  };
  const isObject = value => value !== null && typeof value === "object" && !Array.isArray(value);
  const isDate = value => typeof value === "string"
    && /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2})$/.test(value)
    && Number.isFinite(Date.parse(value));
  const isURL = value => { try { return typeof value === "string" && !!new URL(value).hostname; } catch { return false; } };
  const isCount = (value, maximum = Number.MAX_SAFE_INTEGER) => Number.isSafeInteger(value) && value >= 0 && value <= maximum;
  const maxEntries = readMaximumBlocklistBytes();
  requireValue(isObject(catalog) && catalog.schema_version === 2, "schema_version");
  requireValue(typeof catalog.catalog_version === "string", "catalog_version");
  requireValue(isDate(catalog.generated_at), "generated_at");
  requireValue(Array.isArray(catalog.sources), "sources");
  requireValue(Array.isArray(catalog.guardrails), "guardrails");
  const entries = [...catalog.sources, ...catalog.guardrails];
  requireValue(entries.length <= 512, "source count");
  const ids = new Set();
  for (const [index, source] of entries.entries()) {
    const field = name => `source[${index}].${name}`;
    requireValue(isObject(source), field("row"));
    for (const name of ["id", "name", "category", "risk_level", "license_name", "attribution", "version_id", "source_hash", "normalized_hash", "redistribution_mode"]) {
      requireValue(typeof source[name] === "string", field(name));
    }
    requireValue(/^[A-Za-z0-9._-]{1,128}$/.test(source.id) && ![".", ".."].includes(source.id) && !ids.has(source.id.toLowerCase()), field("id"));
    ids.add(source.id.toLowerCase());
    requireValue(Buffer.byteLength(source.version_id) <= 238, field("version_id"));
    requireValue(typeof source.default_enabled === "boolean", field("default_enabled"));
    requireValue(isCount(source.entry_count, maxEntries), field("entry_count"));
    requireValue(isCount(source.byte_size), field("byte_size"));
    requireValue(isURL(source.project_url), field("project_url"));
    requireValue(isURL(source.source_url) && new URL(source.source_url).protocol === "https:", field("source_url"));
    requireValue(isDate(source.published_at), field("published_at"));
    requireValue(["auto", "plain_domains", "hosts", "adblock", "dnsmasq"].includes(source.parse_format), field("parse_format"));
    for (const name of ["license_text_url", "notice_url"]) {
      requireValue(source[name] == null || isURL(source[name]), field(name));
    }
    requireValue(Array.isArray(source.accepted_source_hashes), field("accepted_source_hashes"));
    for (const hash of source.accepted_source_hashes) {
      requireValue(isObject(hash) && typeof hash.sha256 === "string" && typeof hash.status === "string", field("accepted_source_hashes row"));
      requireValue(hash.byte_size == null || isCount(hash.byte_size), field("accepted_source_hashes.byte_size"));
      requireValue(hash.entry_count == null || isCount(hash.entry_count, maxEntries), field("accepted_source_hashes.entry_count"));
      for (const name of ["reviewed_at", "expires_at"]) {
        requireValue(hash[name] == null || isDate(hash[name]), field(`accepted_source_hashes.${name}`));
      }
    }
  }
}

export async function loadCatalogs(useVendored) {
  if (useVendored) return [await loadCatalog(true)];
  // Check both independent client entry points even while the primary is healthy.
  return Promise.all([SERVED_CATALOG_URL, FALLBACK_CATALOG_URL].map(url => loadCatalog(false, url)));
}

/// Does a cleaned line look like a hostname a blocklist would carry? Deliberately loose and
/// format-agnostic — hosts (`0.0.0.0 domain`), plain domains, adblock (`||domain^`), and
/// dnsmasq (`address=/domain/`) all reduce to a token with a dot, letters, and no interior
/// whitespace. This is not a parser; it only has to tell a domain list apart from an HTML error
/// page and count roughly how many rules a body carries.
function looksLikeDomainLine(line) {
  // dnsmasq: `address=/domain/`, `server=/domain/`, `local=/domain/` — pull the domain out.
  const dnsmasq = line.match(/^(?:address|server|local)=\/([^/]+)\//i);
  // hosts format prefixes an IP; otherwise take the last whitespace token.
  const token = dnsmasq ? dnsmasq[1] : (line.split(/\s+/).filter(Boolean).pop() ?? "");
  const host = token.replace(/^[|@]+/, "").replace(/[\^|].*$/, "");
  return /^[a-z0-9.*_-]+$/i.test(host) && host.includes(".") && host.length >= 4;
}

// How many rules a cleaned line yields, matching `parseHosts`: a hosts line maps one
// null-route address to EVERY domain after it (`0.0.0.0 a b c` = 3 rules), so counting one per
// line UNDER-counts a multi-domain hosts source and could pass one that is over the rule cap on
// device. Every other format is one rule per line. (Codex, #530.)
const NULL_ROUTES = new Set(["0.0.0.0", "127.0.0.1", "::", "::1"]);
function roughRuleCount(line) {
  const tokens = line.split(/\s+/).filter(Boolean);
  if (tokens.length >= 2 && NULL_ROUTES.has(tokens[0])) return tokens.length - 1;
  return 1;
}

function cleanLine(raw) {
  const line = raw.trim();
  if (!line || line.startsWith("#") || line.startsWith("!") || line.startsWith("[")) return "";
  const hash = line.indexOf("#");
  return (hash === -1 ? line : line.slice(0, hash)).trim();
}

async function measure(source, capBytes, ruleCap) {
  const declaredBytes = source.byte_size ?? null;
  const declaredEntries = source.entry_count ?? null;
  const result = {
    id: source.id, url: source.source_url,
    declaredBytes, declaredEntries,
    status: null, bytes: null, rules: null, failures: [], advisories: [],
  };

  // NB: the declared `entry_count`/`byte_size` are curation-time metadata and CANNOT gate a
  // pass/fail. They go stale in both directions — an upstream can grow past a cap after a small
  // measurement, or shrink under it after a large one — and the device enforces neither against
  // the catalog metadata. It fetches the current payload and checks ACTUAL bytes and the
  // deduplicated rule set (`compileSource`). So this checker does the same: the streaming byte
  // and rule caps below are enforced against what is served now, and the drift check surfaces a
  // large divergence from the declared measurement. An earlier revision returned early on a
  // declared over-cap (Kilo's efficiency point); that was wrong — a source that shrank below
  // the cap would be permanently reported inadmissible on stale metadata. (Codex, #530.)

  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), REQUEST_TIMEOUT_MS);
  try {
    // GET, not HEAD: several hosts answer HEAD with no Content-Length, and one answers HEAD 200
    // for paths that GET 404. `identity` because the app refuses a compressed representation,
    // so a source that only serves gzip is dead on device and must not look healthy here.
    const response = await fetchCatalogSource(source.source_url, controller.signal);
    result.status = response.status;
    if (!response.ok) {
      result.failures.push(`HTTP ${response.status}`);
      return result;
    }
    // Defense in depth: every request/redirect was admitted before network I/O above.
    if (!response.url.startsWith("https://")) {
      result.failures.push(`redirected to non-HTTPS ${response.url} — refused on device`);
      return result;
    }
    const encoding = (response.headers.get("content-encoding") ?? "identity").toLowerCase();
    if (encoding !== "identity") {
      result.failures.push(
        `served Content-Encoding: ${encoding} despite an identity request — refused on device`);
      return result;
    }

    // Stream, counting bytes (the HARD cap) and a rough rule count (ADVISORY). The byte cap is
    // exact and aborts the download the moment it is decisively exceeded. The rule count is a
    // deliberately un-deduplicated over-approximation — it does not run the device's dedup,
    // normalization, allow/protected-domain filtering — so it CANNOT gate pass/fail without
    // risking a false failure on a duplicate-heavy list. Matching the device exactly would mean
    // re-adding a Set + DomainName.normalize, the machinery this checker was slimmed to remove.
    // So an over-rule-cap rough count is surfaced as an advisory for a human to confirm, not a
    // CI failure. (Codex + Kilo, #530.)
    let bytes = 0;
    let ruleLines = 0;
    let domainLines = 0;    // of the first SAMPLE_LINES rule lines, how many look domain-ish
    let sampled = 0;
    let pending = "";
    const decoder = new TextDecoder("utf-8");
    let overBytes = false;

    const consume = (text, last) => {
      pending += text;
      const lines = pending.split(/\r\n|\n|\r/);
      pending = last ? "" : (lines.pop() ?? "");
      for (const raw of lines) {
        const line = cleanLine(raw);
        if (!line) continue;
        ruleLines += roughRuleCount(line);
        if (sampled < SAMPLE_LINES) { sampled++; if (looksLikeDomainLine(line)) domainLines++; }
      }
    };

    for await (const chunk of response.body) {
      bytes += chunk.length;
      if (bytes > capBytes) { overBytes = true; controller.abort(); break; }
      consume(decoder.decode(chunk, { stream: true }), false);
    }
    if (!overBytes) consume("", true);
    result.bytes = bytes;
    result.rules = ruleLines;

    if (overBytes) {
      result.failures.push(
        `over the ${(capBytes / 1024 / 1024).toFixed(0)} MB per-source byte cap ` +
        `(still streaming at ${bytes.toLocaleString()} bytes — true size is larger)`);
      return result;
    }
    if (bytes < MINIMUM_PLAUSIBLE_BYTES) {
      result.failures.push(
        `body is only ${bytes} bytes — too small to be a blocklist ` +
        "(a 404 page served with a 200, or an emptied file)");
      return result;
    }
    // A body over the floor that yields NO candidate rule lines is not a list either — it is a
    // file replaced with pure comments/blank lines, which enforces nothing. `sampled === 0`
    // means not one non-comment line was seen. (Codex, #530.)
    if (ruleLines === 0) {
      result.failures.push(
        `${bytes.toLocaleString()} bytes but no rule lines — every line is blank or a comment, ` +
        "so the source enforces nothing (an emptied-but-commented file)");
      return result;
    }
    if (sampled > 0 && domainLines / sampled < MINIMUM_DOMAIN_LINE_SHARE) {
      result.failures.push(
        `only ${domainLines}/${sampled} sampled lines look like hostnames — the body is ` +
        "served with a 200 but is not a blocklist (an HTML error page enforces nothing)");
      return result;
    }

    if (ruleLines > ruleCap) {
      result.advisories.push(
        `rough count ${ruleLines.toLocaleString()} exceeds the ${ruleCap.toLocaleString()} rule ` +
        "cap — VERIFY: this is a non-deduplicated over-count, so confirm the deduplicated rule " +
        "set before acting; the device enforces the exact cap at compile time");
    }

    if (declaredBytes !== null && declaredBytes > 0) {
      const drift = (bytes - declaredBytes) / declaredBytes;
      if (Math.abs(drift) > BYTE_DRIFT_TOLERANCE) {
        const reviewedAt = source.accepted_source_hashes?.[0]?.reviewed_at?.slice(0, 10);
        result.failures.push(
          `${drift > 0 ? "grew" : "shrank"} ${Math.abs(drift * 100).toFixed(0)}% since ` +
          `curation accepted it${reviewedAt ? ` on ${reviewedAt}` : ""}: accepted ` +
          `${declaredBytes.toLocaleString()} bytes, now ${bytes.toLocaleString()}`);
      }
    }
    return result;
  } catch (error) {
    if (result.failures.length === 0) {
      result.failures.push(`fetch failed: ${error.name === "AbortError"
        ? `no response within ${REQUEST_TIMEOUT_MS / 1000}s`
        : error.message}`);
    }
    return result;
  } finally {
    clearTimeout(timer);
  }
}

async function mapBounded(items, limit, worker) {
  const results = new Array(items.length);
  let next = 0;
  await Promise.all(Array.from({ length: Math.min(limit, items.length) }, async () => {
    while (true) {
      const index = next++;
      if (index >= items.length) return;
      results[index] = await worker(items[index]);
    }
  }));
  return results;
}

// Availability is a deployment contract, not merely upstream liveness. A source
// missing from production cannot be discovered by crawling production's rows.
export function catalogConsistencyFindings(expected, served) {
  const findings = [];
  const expectedByID = new Map(expected.sources.map(source => [source.id, source]));
  const servedByID = new Map();
  const seenIdentifiers = new Set();
  for (const source of served.sources) {
    const identifier = source.id.toLowerCase();
    if (seenIdentifiers.has(identifier)) findings.push(`Duplicate published source: ${source.id}`);
    seenIdentifiers.add(identifier);
    // Preserve exact membership/URL comparisons: a casing change must not silently
    // replace an adopted ID even though the decoder rejects case-folded collisions.
    servedByID.set(source.id, source);
  }
  for (const [id, source] of expectedByID) {
    const live = servedByID.get(id);
    if (!live) findings.push(`Missing published source: ${id} — check seed migrations and worker sync`);
    else {
      if (live.source_url !== source.source_url) findings.push(`Source URL differs from adopted catalog: ${id}`);
      if (!live.version_id || !Number.isInteger(live.entry_count) || live.entry_count <= 0) {
        findings.push(`Source lacks a usable published version: ${id}`);
      }
    }
  }
  for (const id of servedByID.keys()) {
    if (!expectedByID.has(id)) findings.push(`Published source absent from adopted catalog: ${id}`);
  }
  return findings;
}

export { looksLikeDomainLine, cleanLine, roughRuleCount, readPlusRuleCap, readMaximumBlocklistBytes };

// Everything below runs only as the entry point, so importing this file for a unit check does
// not kick off a live crawl.
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  await main();
}

async function main() {
  const args = process.argv.slice(2);
  const asJSON = args.includes("--json");
  const useVendored = args.includes("--vendored");
  const onlyIDIndex = args.indexOf("--id");
  const onlyID = onlyIDIndex === -1 ? null : args[onlyIDIndex + 1];

  // In --json mode all human lines go to stderr so stdout stays a parseable JSON document.
  const say = asJSON ? (m) => console.error(m) : (m) => console.log(m);

  const capBytes = readMaximumBlocklistBytes();
  const ruleCap = readPlusRuleCap();
  const catalogs = await loadCatalogs(useVendored);
  const [{ label, catalog }] = catalogs;
  // 🔴 Guardrails are deliberately NOT crawled with the liveness yardstick. Unlike community
  // sources, they are hash-pinned on device: `loadBlocklist` requires the downloaded bytes to
  // match an accepted hash and rejects direct upstream rotation. So the wedge condition unique
  // to a guardrail is "content changed" (hash mismatch), which reachable + in-cap + looks-like-
  // a-list cannot see — reporting a rotated-but-plausible guardrail as healthy is false
  // confidence. Both catalogs carry zero guardrails today.
  //
  // But a silent skip is its own trap: the day a guardrail is added, a scheduled run nobody
  // watches would still exit 0. So encountering ANY guardrail is a HARD FAILURE here, which
  // forces whoever adds one to wire a SHA-256 check against `accepted_source_hashes` (the
  // guardrail-appropriate check) rather than let it pass green. (Codex + Kilo, #530.)
  const expected = useVendored ? null : JSON.parse(fs.readFileSync(VENDORED_CATALOG_PATH, "utf8"));
  const consistencyFindings = useVendored ? [] : catalogs.flatMap(published =>
    catalogConsistencyFindings(expected, published.catalog).map(finding => `${published.label}: ${finding}`)
  );
  for (const finding of consistencyFindings) console.error(`global catalog consistency: ${finding}`);
  const guardrailCount = catalogs.reduce((total, published) => total + (published.catalog.guardrails ?? []).length, 0);
  const sources = catalog.sources.filter((s) => !onlyID || s.id === onlyID);

  if (sources.length === 0) {
    console.error(`check-catalog-sources: no source matches --id ${onlyID}`);
    process.exit(2);
  }

  say(`catalog: ${label}`);
  say(`limits (read from Swift): ${capBytes.toLocaleString()} bytes/source, ` +
    `${ruleCap.toLocaleString()} rules/source\n`);

  const results = await mapBounded(sources, MAX_CONCURRENT, (s) => measure(s, capBytes, ruleCap));
  const failures = results.filter((r) => r.failures.length > 0);
  const advised = results.filter((r) => r.advisories.length > 0);

  if (asJSON) {
    console.log(JSON.stringify({ catalog: label, capBytes, ruleCap, consistencyFindings, results }, null, 2));
  } else {
    for (const r of results.sort((a, b) => (b.bytes ?? 0) - (a.bytes ?? 0))) {
      const size = r.bytes === null ? "—" : `${(r.bytes / 1024 / 1024).toFixed(2)} MB`;
      const rules = r.rules === null ? "—" : `${r.rules.toLocaleString()} rules`;
      const mark = r.failures.length ? "FAIL" : (r.advisories.length ? "warn" : "ok  ");
      console.log(`${mark}  ${size.padStart(10)}  ${rules.padStart(16)}  ${r.id}`);
      for (const failure of r.failures) console.log(`        ${failure}`);
      for (const advisory of r.advisories) console.log(`        ⚠ ${advisory}`);
      if (r.failures.length || r.advisories.length) console.log(`        ${r.url}`);
    }
  }

  if (failures.length > 0) {
    console.error(
      `\ncheck-catalog-sources: ${failures.length} of ${results.length} sources have findings: ` +
      failures.map((f) => f.id).join(", "));
    console.error(
      "A source that cannot be fetched, or is over a cap, wedges any device that enables it. " +
      "A source that has only drifted has not broken anything YET.");
  }

  // A guardrail present is a HARD failure regardless of the source findings: it means this
  // checker no longer covers the catalog it guards (guardrails need a SHA-256 check it does not
  // do), and a scheduled run must go red rather than exit 0 on an unchecked hash-pinned source.
  if (guardrailCount > 0) {
    console.error(
      `\ncheck-catalog-sources: ${guardrailCount} guardrail source(s) present but UNCHECKED — ` +
      "guardrails are hash-pinned; wire a SHA-256 check against accepted_source_hashes before " +
      "they can pass. Failing rather than reporting a catalog this checker no longer covers.");
  }

  // Advisories are surfaced to a human but do NOT fail the run — they are non-deduplicated
  // estimates, and hard-failing CI on them would be crying wolf.
  if (advised.length > 0) {
    console.error(
      `\ncheck-catalog-sources: ${advised.length} source(s) have advisories to VERIFY: ` +
      advised.map((r) => r.id).join(", "));
  }

  if (failures.length > 0 || guardrailCount > 0 || consistencyFindings.length > 0) process.exit(1);

  // `say`, not console.log: in --json mode this success line would otherwise trail the JSON
  // document on stdout and break `jq`. (Codex, #530.)
  say(`\ncheck-catalog-sources: all ${results.length} sources reachable, real, and within caps.`);
}
