#!/usr/bin/env node
// Generates the third-party notice file for the vendored WireGuard engine.
//
// Why this is generated and not written by hand: the engine's static library is a BINARY
// REDISTRIBUTION of ~55 Rust crates, and every license in the tree (MIT, Apache-2.0, BSD-3,
// ISC) requires the copyright notice to travel with that binary. A hand-maintained list
// silently rots the first time a transitive dependency moves, and the artifact reaches the
// public mirror whether or not anyone remembered.
//
// The crate set is derived from `cargo tree -e normal` for each SHIPPED target triple, which
// excludes build-dependencies, dev-dependencies, and the `windows_*` crates the lock carries
// for other platforms. It still includes proc-macro crates, whose own code does not land in
// the artifact — that over-inclusion is deliberate. Attribution that is too broad costs a few
// paragraphs; attribution that is too narrow is the failure that matters.
//
// Usage:
//   node scripts/generate-wireguard-core-notices.mjs            # write
//   node scripts/generate-wireguard-core-notices.mjs --check    # fail if the committed file is stale
//
// Requires cargo on PATH (rustup lives at /opt/homebrew/opt/rustup/bin on the dev machines
// and is provisioned explicitly in the CI job).

import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { readdirSync, readFileSync, writeFileSync, existsSync } from "node:fs";
import { basename, dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import {
  analyzeStaticLibrary,
  SYSROOT_VENDOR_PATH_EVIDENCE,
} from "./lib/ar-archive.mjs";
import {
  classifyCrateOrigin,
  lockedCrateNames,
  normalizeCrateName,
} from "./lib/crate-provenance.mjs";

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const crateDir = join(repoRoot, "ThirdParty", "wireguard-core");
const noticesPath = join(crateDir, "THIRD-PARTY-NOTICES.txt");
// A second, byte-identical copy inside the app's own source root.
//
// The app target cannot reference ThirdParty/ — check-xcodegen-sources rejects that root
// for app targets, correctly: vendored engine source is not app material. But the licenses
// require the notice text to travel with the BINARY, so it has to be a bundle resource.
// Emitting both from one generator keeps the repo copy authoritative and makes drift
// impossible: --check verifies BOTH, so an edit to either fails the gate.
const appNoticesPath = join(repoRoot, "LavaSecApp", "THIRD-PARTY-NOTICES.txt");
const indexPath = join(crateDir, "third-party-notices-index.json");
const sysrootCratesPath = join(crateDir, "sysroot-crates.json");
// The licence corpus for the sysroot crates. `sysroot-crates.json` is an INVENTORY — it
// names what the archive is expected to contain so the reconciliation does not flag it as
// unknown, and says in its own words that listing a crate there does not discharge the
// obligation. This file is what discharges it: the licence texts, copyright holders and
// SPDX expressions for crates `cargo metadata` cannot see, because they come from the
// precompiled rust-std the toolchain ships rather than from `Cargo.lock`.
const sysrootPackagesPath = join(crateDir, "sysroot-packages.json");
// The Cargo side of the linked set, stated exhaustively and not by this generator.
//
// Needed because provenance cannot be read off the archive alone for every crate: under
// `strip = "debuginfo"` a Cargo crate keeps a member but loses its `registry/src/...` path
// unless a panic site of its own survived codegen, and one sysroot crate (`adler2`) carries
// no path string either. The lockfile is what closes that gap — see
// `scripts/lib/crate-provenance.mjs` for why the committed sysroot INVENTORY cannot be
// the thing that closes it.
const cargoLockPath = join(crateDir, "Cargo.lock");
const xcframeworkDir = join(crateDir, "build", "LavaSecWGCore.xcframework");

// The triples the xcframework actually ships. macOS is included because the package's
// executable tests drive the real engine there, so that slice is redistributed too.
const TARGETS = ["aarch64-apple-ios", "aarch64-apple-ios-sim", "aarch64-apple-darwin"];

// Our own crate is the thing being licensed, not a third party.
const OWN_CRATES = new Set(["lavasec-wireguard-core"]);

/**
 * The pinned toolchain channel.
 *
 * Parses the CHANNEL, not the file. Searching the whole TOML lets a comment satisfy the
 * check: `rust-toolchain.toml`'s own header explains the pin and names the version, so
 * bumping `channel` while leaving that prose intact would keep a substring search happy and
 * accept a stale inventory.
 */
function pinnedChannel() {
  const pinned = readFileSync(join(crateDir, "rust-toolchain.toml"), "utf8");
  return (
    /^\s*channel\s*=\s*"([^"]+)"/m.exec(pinned.slice(pinned.indexOf("[toolchain]")))?.[1] ?? null
  );
}
// The crates whose sysroot identity rests on ELIMINATION rather than on archive evidence.
//
// 18 of the 19 sysroot crates carry a sysroot path string in their own bytes, so the archive
// itself proves where they came from and no list can overrule it. adler2 is the lone
// exception: its path string does not survive. `classifyCrateOrigin` still reaches the right
// answer for it without asking any committed sysroot file — it is in the archive, it is not
// ours, it carries no Cargo registry path and `Cargo.lock` has no package of that name, and
// the partition leaves nowhere else for it to have come from.
//
// So this is no longer the thing that GRANTS the classification; that moved to the archive
// and the lockfile, which the notices generator does not write. What it is now is the
// register of which crates are ALLOWED to land in that branch. A crate arriving there
// unnamed here is either a toolchain bump that vendors something new or a Cargo crate that
// has gone missing from the lockfile, and both are decisions a human should make explicitly
// rather than have absorbed — so the gate reports it and the new name is added here
// deliberately, alongside its member bound below.
//
// It stays a constant in the reviewed generator rather than a field in sysroot-crates.json
// for the reason that predates this: trusting the JSON meant any crate added to that
// inventory was exempted from attribution, and Codex reproduced dropping `subtle` from the
// notices by adding it there. That does NOT make it unforgeable (see the trust note on the
// digest check) — it puts the decision somewhere a reviewer expects to find one.
const SYSROOT_WITHOUT_PATH_EVIDENCE = new Set(["adler2"]);

// How many members each evidence-free sysroot classification may cover.
//
// Same hiding place as the first-party skip, one level down: `adler2` is classified on the
// strength of an absence — no path string, no lockfile entry — so a third-party member
// renamed to `adler2.<x>.rcgu.o` inherits that classification and its own crate disappears
// from attribution. Bounding the member count means the rename shows up as an extra member
// rather than as nothing. A tripwire like its sibling, not an anchor.
const SYSROOT_EXEMPT_MEMBERS_PER_SLICE = new Map([["adler2", 1]]);

// How many compilation units our own crate contributes to each slice.
//
// The first-party skip is what an impersonation hides inside: rename any third-party
// member to `lavasec_wireguard_core.<something>.rcgu.o` and the reconciliation passes over
// it, because our own crate is the thing being licensed rather than a third party. The
// payload is a real object and the name is well-formed, so nothing about the member itself
// gives it away.
//
// Bounding the skip does. The crate compiles to exactly two codegen units per slice — one
// exporting the seven `lava_wg_*` ABI entry points, one exporting five internal symbols —
// so a member smuggled in under that name makes three, and the count is checked rather
// than assumed. This is a TRIPWIRE, not an anchor: it is committed like everything else and
// an editor who knows about it can change it too. What it buys is that hiding a crate now
// requires editing this file as well as the archive, which is a visible, reviewable change
// rather than a silent one — and unlike the from-source byte-compare it costs no toolchain,
// so it runs on the public mirror where that gate does not exist.
//
// If a toolchain bump changes the crate's CGU count, this fails loudly and the new number
// goes here deliberately.
const OWN_CRATE_MEMBERS_PER_SLICE = 2;

// The C ABI the engine exists to export. Their presence proves the real entry points are in
// the slice; a member impersonating the first-party crate carries someone else's symbols.
const OWN_CRATE_ABI_SYMBOL_PREFIX = "_lava_wg_";
const OWN_CRATE_ABI_SYMBOL_COUNT = 7;

// Same set as OWN_CRATES, in the crate-identifier spelling the archive yields.
const OWN_CRATES_NORMALIZED = new Set(
  [...OWN_CRATES].map((n) => n.replace(/-/g, "_").toLowerCase())
);

const LICENSE_FILE_PATTERN = /^(LICEN[CS]E|COPYING|NOTICE|UNLICENSE)/i;
// Files that sit alongside real license text but are not themselves a grant.
const LICENSE_FILE_DENY = /\.(rs|toml|md~)$/i;

// Crates whose published tarball omits the license text the license field names.
//
// boringtun 0.7.1 ships no LICENSE file. Its Cargo.toml declares BSD-3-Clause, and clause 2
// of that license requires binary redistribution to REPRODUCE the condition list and
// disclaimer — a URL is not reproduction. The text at the mapped path was assembled from an
// authentic on-disk BSD-3 distribution plus Cloudflare's copyright line, rather than recalled,
// and lives outside the vendored tree so that tree stays a verbatim copy of the tarball.
// Paths are relative to the crate directory.
const LICENSE_OVERRIDES = new Map([["boringtun 0.7.1", ["LICENSE-boringtun.txt"]]]);

function cargo(args) {
  return execFileSync("cargo", args, {
    cwd: crateDir,
    encoding: "utf8",
    maxBuffer: 64 * 1024 * 1024,
  });
}

function linkedCrateKeys() {
  const keys = new Set();
  for (const target of TARGETS) {
    const out = cargo(["tree", "-e", "normal", "--target", target, "--prefix", "none"]);
    for (const rawLine of out.split("\n")) {
      const line = rawLine.trim();
      if (!line) continue;
      // Lines look like: "name v1.2.3", optionally followed by " (*)", " (proc-macro)",
      // or " (/abs/path)" for path dependencies.
      const match = /^([A-Za-z0-9_.+-]+) v([0-9][^\s]*)/.exec(line);
      if (!match) continue;
      const [, name, version] = match;
      if (OWN_CRATES.has(name)) continue;
      keys.add(`${name} ${version}`);
    }
  }
  return keys;
}

function packageIndex() {
  const metadata = JSON.parse(cargo(["metadata", "--format-version", "1"]));
  const index = new Map();
  for (const pkg of metadata.packages) {
    index.set(`${pkg.name} ${pkg.version}`, pkg);
  }
  return index;
}

function licenseDocuments(pkg) {
  const override = LICENSE_OVERRIDES.get(`${pkg.name} ${pkg.version}`);
  if (override) {
    return override.map((relative) => {
      const path = join(crateDir, relative);
      if (!existsSync(path)) {
        throw new Error(
          `license override for ${pkg.name} ${pkg.version} points at a missing file: ${relative}`
        );
      }
      return {
        filename: relative,
        text: readFileSync(path, "utf8").replace(/\r\n/g, "\n").trimEnd(),
      };
    });
  }

  const dir = dirname(pkg.manifest_path);
  if (!existsSync(dir)) return [];
  const documents = [];
  for (const entry of readdirSync(dir).sort()) {
    if (!LICENSE_FILE_PATTERN.test(entry) || LICENSE_FILE_DENY.test(entry)) continue;
    const text = readFileSync(join(dir, entry), "utf8").replace(/\r\n/g, "\n").trimEnd();
    if (!text) continue;
    documents.push({ filename: entry, text });
  }
  return documents;
}

function copyrightLines(documents) {
  const lines = new Set();
  for (const doc of documents) {
    for (const line of doc.text.split("\n")) {
      // Some crates ship their license as a source-comment header (untrusted uses `// `),
      // so strip a leading comment marker before deciding.
      const trimmed = line.trim().replace(/^(\/\/+|#+|\*+|;+)\s*/, "").trim();

      // A real notice NAMES a holder. Requiring the line to BEGIN with "Copyright" already
      // rejects Apache-2.0's section headings ("2. Grant of Copyright License") and its
      // definitions, which merely contain the word.
      if (!/^copyright\b/i.test(trimmed)) continue;
      // A real notice carries a copyright MARK or a year. Apache-2.0 is hard-wrapped, so
      // its own prose produces lines that genuinely begin with the word — "copyright
      // license to reproduce,", "copyright notice that is included in or attached to" —
      // and those name no holder. Requiring (c)/© or a concrete year separates a grant of
      // rights from a sentence about grants, which "begins with copyright" cannot.
      if (!/\(c\)|©/i.test(trimmed) && !/\b(19|20)\d{2}\b/.test(trimmed)) continue;
      // Apache-2.0's appendix carries an unfilled template that attributes nobody.
      // Both bracket styles appear across crates: [yyyy] and {yyyy}.
      if (/[[{]yyyy[\]}]|[[{]name of copyright owner[\]}]/i.test(trimmed)) continue;
      // Deliberately NOT requiring a year: libc's notice is "Copyright (c) The Rust Project
      // Developers", with no year at all. What makes a notice real is the holder, so test
      // for a name — anything left once the word, the (c)/© marks, years and punctuation go.
      const holder = trimmed
        .replace(/^copyright\b/i, "")
        .replace(/\(c\)|©/gi, "")
        .replace(/\b(19|20)\d{2}\b(\s*[-–,]\s*\b(19|20)?\d{2}\b)*/g, "")
        .replace(/[^A-Za-z]/g, "");
      if (holder.length < 2) continue;
      if (trimmed.length > 200) continue;
      lines.add(trimmed.replace(/\s+/g, " "));
    }
  }
  return [...lines].sort();
}

/**
 * Versions the committed archives actually prove for sysroot crates.
 *
 * Only `proven` certainty is used — an inferred hash-group version is a guess, and a licence
 * corpus is the wrong place to act on one.
 *
 * @returns {{observations: Map<string, Set<string>>, evidenceBySlice: Map<string, Set<string>>}}
 *   `evidenceBySlice` is the raw per-slice record of which crates carried sysroot vendor path
 *   evidence there. It is deliberately returned RATHER than a ready-made list of gaps, because
 *   the expectation those gaps are measured against must not come from this function — see the
 *   caller, which measures them against the corpus's declared `vendoredCrates`.
 *
 *   Per (slice, crate) rather than per slice or archive-wide, because both coarser
 *   granularities were masks. Archive-wide: two healthy slices excused a third that had lost
 *   all its vendor-path records. Per slice: a single BOOLEAN per slice was set by any one of
 *   the nine vendored crates, so a slice that lost the markers for just `addr2line` still
 *   counted as having evidence, while `observations` — which is archive-wide by design, so
 *   that two slices proving DIFFERENT versions is itself caught — was populated for
 *   `addr2line` by the sibling slices. The rebuilt slice could then carry a divergent version
 *   of that one crate behind a green gate.
 *
 *   The expectation was briefly the UNION of crates vendored across slices, on the reasoning
 *   that a hand-kept list rots at the next toolchain bump. That was circular: the union is
 *   derived from the very records being tested, so a crate that lost its markers in ALL THREE
 *   slices dropped out of the expectation and went unchecked across the whole xcframework —
 *   the other eight kept `observations` non-empty and the gate stayed green. An expectation
 *   has to be independent of its evidence, so it now lives in the corpus as a declared
 *   `vendoredCrates` list, tied to the pinned toolchain that determines it, and is compared in
 *   both directions so neither a missing crate nor an undeclared new one can pass.
 */
function provenSysrootVersions() {
  /** @type {Map<string, Set<string>>} slice id -> crate keys with vendor-path evidence there */
  const evidenceBySlice = new Map();
  const inventory = existsSync(sysrootCratesPath)
    ? new Set((JSON.parse(readFileSync(sysrootCratesPath, "utf8")).crates ?? []).map(normalizeCrateName))
    : new Set();
  // Every observation is kept, not the last one seen.
  //
  // `found.set` overwrote silently, which loses two different things. Slices can prove
  // DIFFERENT versions for the same crate, and only the last one was compared — a stale
  // version in an earlier slice went unnoticed. And a crate present twice in one slice, as
  // `libc` is (a sysroot copy and a Cargo-resolved copy), had whichever record came last
  // decide the comparison, so the corpus could be checked against the wrong copy entirely.
  /** @type {Map<string, Set<string>>} */
  const observations = new Map();
  const plistPath = join(xcframeworkDir, "Info.plist");
  // Same SHAPE on every path. This early return handed back a bare Map while the normal exit
  // returns an object, so a caller destructuring it got `undefined` for both fields — the
  // per-slice evidence list silently became empty and the comparison it drives reported
  // nothing to check.
  if (!existsSync(plistPath)) return { observations, evidenceBySlice };
  // The slice set comes from Info.plist for the same reason `reconcileAgainstArchives` uses
  // it: a glob reads whatever is on disk, and what SHIPS is what the manifest declares.
  const slices = [];
  for (const entry of readFileSync(plistPath, "utf8").split("<dict>")) {
    const identifier = /<key>LibraryIdentifier<\/key>\s*<string>([^<]+)<\/string>/.exec(entry);
    const binary = /<key>LibraryPath<\/key>\s*<string>([^<]+)<\/string>/.exec(entry);
    // The slice IDENTIFIER, not the binary's basename — every slice's binary has the same
    // name, so a message naming the basename cannot say which slice to look at.
    if (identifier && binary) {
      slices.push({ id: identifier[1], path: join(xcframeworkDir, identifier[1], binary[1]) });
    }
  }
  for (const { id, path: slice } of slices) {
    // A declared slice that cannot be read is recorded as present-with-no-evidence rather
    // than skipped. `continue` on a missing or unparseable archive removed the slice from the
    // comparison entirely, which is the permissive branch: deleting a slice file made its
    // crates unverifiable AND silenced the complaint about them.
    const found = new Set();
    evidenceBySlice.set(id, found);
    if (!existsSync(slice)) continue;
    let analysis;
    try {
      analysis = analyzeStaticLibrary(readFileSync(slice), { path: slice });
    } catch {
      continue;
    }
    for (const crate of analysis.crates) {
      const key = normalizeCrateName(crate.crate);
      if (!inventory.has(key)) continue;
      if (!crate.version || crate.versionCertainty !== "proven") continue;
      // Selected by the EVIDENCE that proved the version, which is the only thing that
      // actually distinguishes the sysroot's copy of a crate from any other copy.
      //
      // `versionKind` was the wrong signal and is the third wrong signal for this one filter.
      // It answers "is this a toolchain version or a package version", not "did this come
      // from the sysroot": a Cargo-resolved copy whose registry path survives stripping also
      // reports `crates.io`, so an inventory-named crate resolved by Cargo would have its
      // Cargo version compared against the SYSROOT corpus and fail a correct corpus. Today
      // the two coincide — every `crates.io` record in the shipped slices carries
      // `rust-sysroot-vendor-path` — which is exactly why the mistake was invisible.
      //
      // Positive selection rather than exclusion, so the failure mode of an unrecognised
      // evidence string is a crate that goes UNCHECKED-but-reported rather than one wrongly
      // compared; the `evidenceBySlice` bookkeeping below, and the comparison the caller makes
      // between it and the corpus's declared `vendoredCrates`, turn the silent-nothing case
      // into a per-(slice, crate) problem so it cannot pass as success.
      if (!crate.evidence?.includes(SYSROOT_VENDOR_PATH_EVIDENCE)) continue;
      found.add(key);
      if (!observations.has(key)) observations.set(key, new Set());
      observations.get(key).add(crate.version);
    }
  }
  // No expectation is formed here, deliberately — see the doc comment. What each slice carried
  // is a measurement; what it OUGHT to carry is a declaration, and deriving the second from
  // the first is what let a crate vanish from both at once.
  return { observations, evidenceBySlice };
}


/**
 * Splits an SPDX expression on one operator at PAREN DEPTH ZERO.
 *
 * `OR` also splits on `/`, the deprecated disjunction form: `rustc_demangle` carries
 * `MIT/Apache-2.0` verbatim from its manifest, and treating that as one opaque operand would
 * hide a whole branch from every caller below.
 *
 * @param {string} expr
 * @param {"AND"|"OR"} keyword
 * @param {{keepEmpty?: boolean}} [options] `keepEmpty` returns empty operands instead of
 *   dropping them, which is how `spdxSyntaxProblem` sees a dangling `/` or `AND`
 * @returns {string[]} operands, trimmed
 */
function splitTopLevel(expr, keyword, { keepEmpty = false } = {}) {
  const text = String(expr);
  const parts = [];
  let depth = 0;
  let start = 0;
  let i = 0;
  while (i < text.length) {
    const ch = text[i];
    if (ch === "(") depth += 1;
    // FLOORED at zero. A bare counter went NEGATIVE on an unmatched `)` and never came back,
    // so every subsequent `depth === 0` test failed and a real top-level `OR` became
    // invisible: `Unicode-3.0 AND MIT) OR Apache-2.0` split into one branch and the
    // every-branch rule accepted an obligation binding in only one of them. Clamping keeps
    // the splitter honest on its own; `spdxSyntaxProblem` rejects the input outright, and
    // both exist because a malformed expression must not be silently reinterpreted.
    else if (ch === ")") depth = Math.max(0, depth - 1);
    else if (depth === 0) {
      if (keyword === "OR" && ch === "/") {
        parts.push(text.slice(start, i));
        i += 1;
        start = i;
        continue;
      }
      const match = /^\s+(AND|OR)\s+/.exec(text.slice(i));
      if (match && match[1] === keyword) {
        parts.push(text.slice(start, i));
        i += match[0].length;
        start = i;
        continue;
      }
    }
    i += 1;
  }
  parts.push(text.slice(start));
  const trimmed = parts.map((part) => part.trim());
  return keepEmpty ? trimmed : trimmed.filter((part) => part.length > 0);
}

/**
 * Whether an SPDX expression is well-formed enough to be REASONED about.
 *
 * Every caller below decides something legally load-bearing from the structure of these
 * expressions, and structure can only be read off an expression that parses. The evaluator
 * used to accept whatever it was handed and interpret it charitably, which turned three
 * different malformations into the same silent outcome — a disjunction the evaluator could not
 * see, an obligation credited to every branch, and a gate that passed:
 *
 *   `Unicode-3.0 AND MIT) OR Apache-2.0`   unmatched `)` drove the depth counter negative, so
 *                                          the top-level `OR` was never recognised
 *   `Unicode-3.0 AND (Apache-2.0 OR MIT)/` the empty operand after `/` was filtered away, so
 *                                          a visibly unnamed alternative vanished
 *   `... AND MIT or Apache-2.0`            a lowercase `or` is not an operator, so both sides
 *                                          were swallowed into one leaf
 *
 * All three were false ACCEPTS. Charity is the wrong instinct here: an expression a machine
 * cannot parse is one a human must look at, so this reports rather than guesses. Operators are
 * upper-case in SPDX, and a miscased one is called out by name because it is the likeliest
 * honest typo.
 *
 * @param {unknown} expr
 * @returns {string|null} a problem phrase, or null when the expression is well-formed
 */
function spdxSyntaxProblem(expr) {
  if (typeof expr !== "string" || expr.trim().length === 0) return "is empty or not a string";
  const text = expr.trim();
  let depth = 0;
  for (const ch of text) {
    if (ch === "(") depth += 1;
    else if (ch === ")") {
      depth -= 1;
      if (depth < 0) return "closes a parenthesis that was never opened";
    }
  }
  if (depth !== 0) return `leaves ${depth} parenthesis/es unclosed`;
  if (/\(\s*\)/.test(text)) return "contains an empty parenthesised group";
  const miscased = text.match(/(?<![A-Za-z0-9.+-])(?:and|or|with)(?![A-Za-z0-9.+-])/g) ?? [];
  if (miscased.length > 0) {
    return `uses the miscased operator "${miscased[0]}" — SPDX operators are AND, OR and WITH`;
  }
  /** Recursively: every operand must itself be well-formed, and every leaf a licence id. */
  const leafProblem = (part) => {
    const inner = stripOuterParens(part);
    if (inner.length === 0) return "contains an empty operand";
    for (const keyword of /** @type {const} */ (["OR", "AND"])) {
      const operands = splitTopLevel(inner, keyword, { keepEmpty: true });
      if (operands.length > 1) {
        for (const operand of operands) {
          const problem = leafProblem(operand);
          if (problem) return problem;
        }
        return null;
      }
    }
    // A leaf is a licence id, optionally granted WITH an exception id. Anything else — a
    // dangling operator, stray prose, a swallowed miscased operator — lands here and is
    // reported instead of being treated as an opaque identifier that matches nothing.
    const leaf = /^([A-Za-z0-9.+-]+)(?:\s+WITH\s+([A-Za-z0-9.+-]+))?$/.exec(inner);
    if (!leaf) return `contains "${inner}", which is not a licence identifier`;
    // A RESERVED WORD is not an identifier, even though it is spelled like one. The leaf
    // pattern is `[A-Za-z0-9.+-]+`, which `AND`, `OR` and `WITH` all match, so a trailing
    // operator that the splitter turned into its own operand — `MIT AND AND` splits to
    // ["MIT", "AND"] — was accepted as a licence name. The miscased check above catches only
    // the lower-case spellings in the raw text, so the canonical ones slipped through it too.
    // Both identifier positions are checked, not just the whole leaf: `MIT WITH AND` puts the
    // reserved word in the exception slot, where testing the leaf as a single string misses it.
    for (const token of [leaf[1], leaf[2]]) {
      if (token !== undefined && ["AND", "OR", "WITH"].includes(token)) {
        return `uses the reserved operator "${token}" where a licence identifier belongs — ` +
          `AND, OR and WITH are not licence names`;
      }
    }
    return null;
  };
  return leafProblem(text);
}

/**
 * Strips parentheses that wrap the WHOLE expression, leaving inner groups alone.
 *
 * `(A OR B)` becomes `A OR B`; `(A OR B) AND C` is returned untouched, because its leading
 * `(` does not pair with its trailing `)`.
 *
 * @param {string} expr
 * @returns {string}
 */
function stripOuterParens(expr) {
  let text = String(expr).trim();
  while (text.startsWith("(") && text.endsWith(")")) {
    let depth = 0;
    let wrapsWhole = true;
    for (let i = 0; i < text.length; i += 1) {
      if (text[i] === "(") depth += 1;
      else if (text[i] === ")") depth -= 1;
      if (depth === 0 && i < text.length - 1) {
        wrapsWhole = false;
        break;
      }
    }
    if (!wrapsWhole) break;
    text = text.slice(1, -1).trim();
  }
  return text;
}

/**
 * Whether a licensee taking `declared` necessarily takes `required` — i.e. whether the declared
 * expression imposes that obligation no matter which branch they choose.
 *
 * This descends both expressions rather than splitting either flat, because SPDX gives `AND`
 * tighter precedence than `OR`, and that precedence is exactly what a flat split cannot see:
 * `Apache-2.0 OR MIT AND Unicode-3.0` groups as `Apache-2.0 OR (MIT AND Unicode-3.0)`, so
 * splitting on `AND` produced a `Unicode-3.0` conjunct and accepted an expression whose Apache
 * branch carries no Unicode obligation at all.
 *
 * BOTH sides, because a cited licence document can itself stand for a compound expression.
 * While `required` was assumed to be a single operand this function compared leaves of the
 * declaration against the whole requirement string, so a cited text whose own expression
 * contained a disjunction — `(MIT OR Apache-2.0) AND Unicode-3.0` — could not be satisfied by
 * ANY declaration, including a byte-identical one. That is a false reject with no escape, and
 * the fix is not a special case: the requirement is decomposed first, so a grouped requirement
 * is matched by descending into it rather than by comparing strings that will never be equal.
 *
 * NECESSARILY is the operative word, and it is not a slip. `MIT OR Apache-2.0` does NOT require
 * `MIT`, because a licensee may elect Apache-2.0 and owe nothing to the MIT terms — so `false`
 * is the correct answer there even though one branch does carry it. That is the whole point of
 * the rule this feeds: an ADDITIONAL obligation is one taken whichever alternative is chosen,
 * and an obligation recorded as additional but present in only some branches is a misstatement
 * of what the package requires.
 *
 * SOUND BUT INCOMPLETE, and the incompleteness is the dangerous direction, so it is stated
 * rather than left to be discovered. A true result means the requirement really is imposed on
 * every branch. A false result means this could not PROVE it — which for a correct corpus is a
 * false reject, and a rule that rejects correct input is one the next maintainer disables. Two
 * such gaps have already been found here (a grouped requirement compared as an opaque string,
 * and a requirement in disjunctive normal form never matched against an identical declaration);
 * both were real corpora that could not be written any other way. If a third appears, the fix
 * is to make this more complete, not to relax the callers.
 *
 * A standing comment here warned that a partial SPDX parser is trusted further than it
 * deserves, and that reasoning held while the check was "does this operand appear in a conjunct
 * position". It does not hold for entailment, which splitting cannot express at any
 * granularity. What is written here is the smallest thing that answers the question: five
 * cases, total, terminating because every recursion is on a strictly shorter operand of one
 * side or the other. It knows nothing about licence identifiers, `WITH`, or SPDX semantics
 * beyond operator precedence.
 *
 * @param {string} declared the package's declared expression
 * @param {string} required a required expression, a single operand or a compound one
 * @returns {boolean} true only when the requirement is provably imposed on every branch
 */
/**
 * Whether any grant ANYWHERE in `expr` is made `WITH` the given exception.
 *
 * Descends the expression for the same reason `declarationRequires` does — a flat split
 * cannot see inside a parenthesised group — but answers a deliberately weaker question. An
 * exception modifies one specific grant rather than binding every alternative, so
 * `Apache-2.0 WITH LLVM-exception OR MIT` legitimately reproduces the exception text even
 * though a licensee electing MIT has no use for it. "Somewhere" is the correct quantifier
 * here; "every branch" would reject that expression, which is a real and common one.
 *
 * @param {string} expr declared expression
 * @param {string} exception exception identifier, e.g. `LLVM-exception`
 * @returns {boolean}
 */
function grantsExceptionSomewhere(expr, exception) {
  const text = stripOuterParens(expr);
  for (const keyword of /** @type {const} */ (["OR", "AND"])) {
    const operands = splitTopLevel(text, keyword);
    if (operands.length > 1) {
      return operands.some((operand) => grantsExceptionSomewhere(operand, exception));
    }
  }
  const leaf = /^[A-Za-z0-9.+-]+\s+WITH\s+([A-Za-z0-9.+-]+)$/.exec(text);
  return leaf !== null && leaf[1] === String(exception).trim();
}

function declarationRequires(declared, required) {
  const d = stripOuterParens(declared);
  const r = stripOuterParens(required);
  // REQUIRED side first, so a compound requirement is decomposed before the declaration is.
  // A conjunctive requirement imposes all of its parts, so all must be entailed.
  const requiredConjuncts = splitTopLevel(r, "AND");
  if (requiredConjuncts.length > 1) {
    return requiredConjuncts.every((part) => declarationRequires(d, part));
  }
  // EVERY branch of the declaration, because the licensee picks the branch, not us.
  const branches = splitTopLevel(d, "OR");
  if (branches.length > 1) return branches.every((branch) => declarationRequires(branch, r));
  // A disjunctive requirement is met by any ONE of its alternatives — and this is tried BEFORE
  // decomposing the declaration, but must FALL THROUGH rather than return on failure.
  //
  // Both halves of that were wrong before. Tried only after the declaration was reduced to a
  // leaf, it could never fire for a requirement in disjunctive normal form: with
  // `(MIT AND Unicode-3.0) OR (Apache-2.0 AND Unicode-3.0)` on both sides, each branch of the
  // declaration was tested against the WHOLE requirement, no single conjunct of a branch
  // entailed that disjunction, and two byte-identical expressions came back false. Entailment
  // is reflexive; anything that says otherwise is broken, and this one rejected a correct
  // corpus with no way for the corpus to be written differently.
  //
  // Falling through matters just as much: a requirement can be disjunctive AND be carried
  // whole by one conjunct of the declaration, as `(MIT OR Apache-2.0) AND Unicode-3.0`
  // carries `MIT OR Apache-2.0`. Returning the `some` result directly would answer false
  // there — neither alternative is required on its own — and never reach the conjunct rule
  // that proves it.
  const alternatives = splitTopLevel(r, "OR");
  if (alternatives.length > 1
    && alternatives.some((alternative) => declarationRequires(d, alternative))) {
    return true;
  }
  // ANY conjunct, because a conjunction imposes all of its parts at once — so one of them
  // carrying the requirement is enough. This is also what lets a GROUPED requirement be
  // matched: the conjunct `(MIT OR Apache-2.0)` entails the requirement `MIT OR Apache-2.0`
  // by descending into both, which comparing strings could never do.
  const conjuncts = splitTopLevel(d, "AND");
  if (conjuncts.length > 1) return conjuncts.some((part) => declarationRequires(part, r));
  return d === r;
}


/**
 * Every licence a package REPRODUCES must be named in the licence it DECLARES.
 *
 * `core` shipped with `Apache-2.0 OR MIT` while citing the Unicode-3.0 text and carrying
 * Unicode, Inc.'s copyright, because `library/core/src/unicode/unicode_data.rs` is a
 * separately-licensed exception. Reproducing the body without naming it understates the licence
 * of the crate that actually links, which is the kind of error a reader of the notices cannot
 * detect — the text is right there, and the summary above it is wrong.
 *
 * Returned as problems rather than thrown, and called from `reconcileSysrootCorpus`, so BOTH
 * gates run it. It previously lived inside `sysrootPackageEntries`, which only `--check`
 * reaches — so a corpus-only SPDX or role edit passed the cargo-free public gate untouched.
 * That is the same misplacement this file has now made three times: the public gate is where
 * the redistribution happens, so it is the one that must be complete.
 */
function validateLicenceTextRoles(doc) {
  const problems = [];
  const knownRoles = new Set(["alternative", "additional", "exception"]);
  for (const pkg of doc.packages ?? []) {
    // A stanza with no licence text and no declared expression is an attribution that says
    // nothing, and these two checks used to live in `sysrootPackageEntries` — reachable only
    // from `--check`. That is the same misplacement as the role validation above, found by
    // sweeping this file for it rather than by waiting for it to be reported: the public gate
    // is where the redistribution happens, so a corpus entry emptied of its obligations has to
    // fail THERE.
    if ((pkg.licenseTexts ?? []).length === 0) {
      problems.push(
        `${pkg.name} carries no licence text in ${basename(sysrootPackagesPath)} — a package ` +
          `stanza with no reproduced text discharges no obligation`
      );
    }
    if (!pkg.spdx) {
      problems.push(
        `${pkg.name} declares no SPDX expression in ${basename(sysrootPackagesPath)} — the ` +
          `notices would name the licences it reproduces without saying which apply`
      );
    }
    // A stanza with no holder discharges no attribution. The generator emits a generic
    // "no copyright holder stated" line for it, and the corpus-to-notices comparison has zero
    // expected lines to check — so an emptied `copyright` array survived a coordinated
    // regeneration and the public gate called it self-consistent.
    // TYPE and CONTENT, not just `length`. Three shapes passed a `length === 0` test and all
    // three produce an attribution-free stanza: `[""]` is nonzero-length and then satisfies
    // `stanza.includes("")` in the notices comparison, because every string contains the empty
    // string; a bare STRING has a `length` too and the generator spreads it into individual
    // characters; and a whitespace-only holder renders as a blank line.
    const holders = pkg.copyright;
    if (holders !== undefined && !Array.isArray(holders)) {
      problems.push(
        `${pkg.name} records \`copyright\` as ${typeof holders} in ` +
          `${basename(sysrootPackagesPath)}, not an array — a string is spread into single ` +
          `characters by the generator`
      );
    } else if (!(holders ?? []).some((line) => String(line).trim().length > 0)) {
      problems.push(
        `${pkg.name} records no copyright holder in ${basename(sysrootPackagesPath)} — the ` +
          `notices would reproduce its licence text while attributing it to nobody`
      );
    } else if (holders.some((line) => String(line).trim().length === 0)) {
      problems.push(
        `${pkg.name} records a blank copyright holder in ${basename(sysrootPackagesPath)} — ` +
          `it renders as an empty line and satisfies any containment check`
      );
    }
    for (const id of pkg.licenseTexts ?? []) {
      if (!doc.licenseTexts?.[id]) {
        problems.push(
          `${pkg.name} references licence text ${id}, which ` +
            `${basename(sysrootPackagesPath)} does not define`
        );
      }
    }
    const declared = pkg.spdx ?? "";
    // No flat conjunct split survives here. Each of the three roles now asks its own question
    // of the expression, with its own quantifier: `additional` needs the operand in EVERY
    // branch (`declarationRequires`), `exception` needs a grant SOMEWHERE
    // (`grantsExceptionSomewhere`), and `alternative` needs the licence named as a complete
    // operand. Group-blanking answered none of them correctly — it was the shared cause of two
    // false accepts and one false reject — so it is gone rather than left as a fourth,
    // unreferenced notion of what this expression means.
    for (const id of pkg.licenseTexts ?? []) {
      const spdx = doc.licenseTexts?.[id]?.spdx;
      // A cited body with no SPDX is MALFORMED, not exempt. `continue` disabled the whole
      // role/expression invariant for that text, so deleting one field let a package move a
      // required licence into a disjunction unnoticed — the same fail-open shape as the two
      // role defaults, reached by removing metadata instead of by supplying the wrong value.
      if (!spdx) {
        problems.push(
          `${pkg.name} cites licence text ${id}, whose corpus definition records no \`spdx\` ` +
            `— without it the declared expression cannot be checked against what the package ` +
            `reproduces`
        );
        continue;
      }
      // MISSING is not `alternative`. Defaulting an absent role to the weakest one meant
      // deleting a role entry silently downgraded the check: removing `core`'s Unicode-3.0
      // role and writing `Apache-2.0 OR MIT OR Unicode-3.0` passed, though Unicode-3.0 is an
      // additional obligation that must stay conjoined. An omission is missing data, and
      // missing data about which obligations apply is exactly what must not be guessed.
      const role = pkg.licenseTextRoles?.[id];
      if (role === undefined) {
        problems.push(
          `${pkg.name} cites licence text ${id} without recording its role in ` +
            `${basename(sysrootPackagesPath)} — whether a reproduced text is an alternative, ` +
            `an additional obligation or an exception cannot be inferred from the expression`
        );
        continue;
      }
      // An unknown role must not fall through either. A misspelling — `aditional` — silently
      // became `alternative` and took the substring path, so the conjunct requirement the
      // field exists to enforce was skipped by a typo.
      if (!knownRoles.has(role)) {
        problems.push(
          `${pkg.name} gives licence text ${id} the role "${role}", which is not one of ` +
            `${[...knownRoles].join(", ")} — an unrecognised role must not be treated as the ` +
            `weakest one`
        );
        continue;
      }
      // An EXCEPTION is neither of the other two. `LLVM-exception` is not a licence the
      // licensor offers as an alternative and not a standalone conjunct — it is the operand of
      // a `WITH`, and it can only be satisfied by a conjunct that carries it.
      //
      // Deliberately SOMEWHERE, not the every-branch rule that governs `additional` above.
      // The asymmetry is the semantics: an additional obligation binds whichever alternative is
      // taken, while an exception modifies one specific grant — `Apache-2.0 WITH LLVM-exception
      // OR MIT` legitimately reproduces the exception text even though the MIT branch has no
      // use for it, so requiring it in every branch would reject a correct corpus.
      //
      // It used to keep the flat, group-blanked split as well, and a comment here argued that
      // was safe: a `WITH` moved inside a parenthesised group becomes `#GROUP#`, matches
      // nothing, and REPORTS — "the direction that asks a human rather than the one that waves
      // the expression through". That argument was wrong, and wrong in a way this file has
      // already been bitten by twice. `(Apache-2.0 WITH LLVM-exception OR MIT) AND Unicode-3.0`
      // is a valid expression, so what the blanked group produces is not a question for a human
      // but a rejection of a correct corpus — and the comment two checks below records what
      // happens to a rule that does that: it gets reverted to the permissive thing it replaced.
      // Reporting is only the safe direction when the thing reported is actually suspect.
      if (role === "exception") {
        if (!grantsExceptionSomewhere(declared, spdx)) {
          problems.push(
            `${pkg.name} reproduces the ${spdx} exception (licence text ${id}), but no grant ` +
              `anywhere in "${declared}" is made WITH it — an exception text without the grant ` +
              `it modifies documents terms the package does not actually take`
          );
        }
        continue;
      }
      // An ADDITIONAL obligation has to bind in EVERY alternative, not merely appear somewhere
      // in the string and not merely hold one top-level conjunct position. Substring presence
      // cannot establish it, because a dual-licensed crate legitimately reproduces both texts
      // of an `OR` — so reproducing a text is not evidence of conjunction, and
      // `(Apache-2.0 OR MIT) OR Unicode-3.0` passes a presence check while understating what
      // the package requires. A flat AND-split cannot establish it either: `AND` binds tighter
      // than `OR`, so `Apache-2.0 OR MIT AND Unicode-3.0` means `Apache-2.0 OR (MIT AND
      // Unicode-3.0)` — splitting on `AND` yields a `Unicode-3.0` conjunct and passes, though a
      // licensee taking the Apache branch never takes the Unicode obligation. Precedence is not
      // observable without descending the expression, so this one descends it.
      if (role === "additional") {
        // A cited text can itself carry a COMPOUND expression: compiler-builtins' LICENSE.txt
        // stands for `MIT AND Apache-2.0 WITH LLVM-exception`, two obligations in one file, so
        // requiring the whole string as a single conjunct would fail on a correct corpus. Each
        // part must bind in EVERY alternative instead — see `declarationRequires`.
        const requiredParts = splitTopLevel(spdx, "AND");
        const missing = requiredParts.filter((part) => !declarationRequires(declared, part));
        if (missing.length > 0) {
          problems.push(
            `${pkg.name} reproduces ${spdx} (licence text ${id}) as an ADDITIONAL obligation, ` +
              `but "${declared}" does not require ${missing.join(" or ")} in EVERY ` +
              `alternative — a licensee taking one of the other branches never takes this ` +
              `obligation, so recording it as additional misstates what that branch requires`
          );
        }
        continue;
      }
      // Complete OPERANDS, not substring containment. `MIT` is a substring of `MIT-0`, so a
      // package could cite an MIT body while declaring `MIT-0 OR Apache-2.0` and pass — and
      // after regeneration the corpus and notices stay mutually consistent, so nothing else
      // catches it. They are distinct licences.
      // `/` is an operand separator too: `rustc_demangle` carries the deprecated
      // `MIT/Apache-2.0` form, which the corpus records verbatim from its manifest and
      // translates in `spdxNormalized`. Splitting only on AND/OR made the whole expression one
      // operand and failed a correct package — a rule that rejects the committed corpus would
      // have been reverted to the permissive `includes` it replaced.
      // A `WITH` leaf names its BASE licence as well as the qualified grant. Splitting only on
      // AND/OR// leaves `Apache-2.0 WITH LLVM-exception` whole, so a package declaring the very
      // common `Apache-2.0 WITH LLVM-exception OR MIT` and citing the Apache-2.0 body as an
      // alternative was told its expression "does not name it". The expression plainly does
      // name it — the exception qualifies the grant, it does not replace the licence.
      //
      // The committed corpus does not hit this today: `compiler_builtins` is the only entry
      // with a `WITH`, and its trailing `(MIT OR Apache-2.0)` group happens to contribute a
      // bare `Apache-2.0` anyway. So this is a latent false REJECT rather than a live one —
      // which is the failure mode this file treats as the more dangerous, because a check that
      // rejects a correct corpus is one the next maintainer disables.
      //
      // Only the base id is added, never the exception id: an exception is not an alternative
      // licence, and role `exception` returns above without reaching this check, so crediting
      // `LLVM-exception` here would let a mis-roled citation through the one rule that catches
      // it.
      const operands = new Set();
      for (const part of declared.split(/\s+(?:AND|OR)\s+|\//)) {
        const operand = part.replace(/[()]/g, "").trim();
        if (operand.length === 0) continue;
        operands.add(operand);
        const withClause = /^([A-Za-z0-9.+-]+)\s+WITH\s+[A-Za-z0-9.+-]+$/.exec(operand);
        if (withClause) operands.add(withClause[1]);
      }
      if (!operands.has(spdx)) {
        problems.push(
          `${pkg.name} reproduces ${spdx} (licence text ${id}) but declares "${declared}", ` +
            `which does not name it — the aggregate expression has to include every licence ` +
            `the package carries`
        );
      }
    }
  }
  return problems;
}

/**
 * Checks the corpus's compiler identity against the SHIPPED BINARIES.
 *
 * Every other rule in this file compares committed declarations with each other, so a
 * toolchain bump that updates `rust-toolchain.toml` and both `toolchain` fields WITHOUT
 * rebuilding the xcframework passed everything: the corpus then describes a compiler that did
 * not build the archive, and its 19-crate licence set is for the wrong toolchain's sysroot.
 * Reproduced by setting all three declarations to 9.99.0 against slices built by 1.94.0.
 *
 * The archives are the independent authority, and they are committed — so unlike re-deriving
 * the SPDX expressions from `COPYRIGHT*.html`, this one is available to the cargo-free gate,
 * which is the gate that governs redistribution. rustc embeds its own version, commit and date
 * in the object files; `analyzeStaticLibrary` already recovers them.
 *
 * The commit is compared as a PREFIX because the embedded form is the short hash (9 chars)
 * while the corpus records the full 40.
 */
function reconcileCorpusAgainstArchiveToolchain(doc) {
  const problems = [];
  if (!existsSync(xcframeworkDir)) return problems;
  const plistPath = join(xcframeworkDir, "Info.plist");
  if (!existsSync(plistPath)) return problems;

  // PER SLICE. An archive-wide flag meant one slice supplying evidence excused the others, so
  // a rebuilt or stripped slice could carry no producer strings, receive no comparison at all,
  // and still pass the redistribution gate — reproduced by removing every marker from
  // `ios-arm64` alone. Each declared slice must answer for itself.
  for (const entry of readFileSync(plistPath, "utf8").split("<dict>")) {
    const identifier = /<key>LibraryIdentifier<\/key>\s*<string>([^<]+)<\/string>/.exec(entry);
    const binary = /<key>LibraryPath<\/key>\s*<string>([^<]+)<\/string>/.exec(entry);
    if (!identifier || !binary) continue;
    const slice = join(xcframeworkDir, identifier[1], binary[1]);
    if (!existsSync(slice)) continue;
    let analysis;
    try {
      analysis = analyzeStaticLibrary(readFileSync(slice), { path: slice });
    } catch {
      continue;
    }
    const embeddedToolchains = analysis.toolchains ?? [];
    if (embeddedToolchains.length === 0) {
      problems.push(
        `${identifier[1]} carries no embedded rustc version, so the compiler that built it ` +
          `cannot be checked against ${basename(sysrootPackagesPath)} — a slice with its ` +
          `producer strings stripped is exactly the one whose toolchain is unverifiable`
      );
      continue;
    }
    for (const embedded of embeddedToolchains) {
      if (embedded.version && embedded.version !== doc.toolchain) {
        problems.push(
          `${identifier[1]} was built by rustc ${embedded.version}, but ` +
            `${basename(sysrootPackagesPath)} records ${doc.toolchain} — the corpus describes ` +
            `a different compiler's sysroot, so its licence set is for crates this archive ` +
            `does not contain`
        );
      }
      if (embedded.commit && !String(doc.rustcCommitHash ?? "").startsWith(embedded.commit)) {
        problems.push(
          `${identifier[1]} was built by rustc commit ${embedded.commit}…, but ` +
            `${basename(sysrootPackagesPath)} records ${doc.rustcCommitHash} — same version ` +
            `number, different build, and the vendored crate versions can differ between them`
        );
      }
      if (embedded.date && embedded.date !== doc.rustcCommitDate) {
        problems.push(
          `${identifier[1]} was built by a rustc dated ${embedded.date}, but ` +
            `${basename(sysrootPackagesPath)} records ${doc.rustcCommitDate}`
        );
      }
    }
  }
  return problems;
}

/**
 * Validates the SHAPE of the sysroot licence corpus, before anything reads it.
 *
 * ## Why one pass instead of guards at each read
 *
 * Eight defects were reported against this file in a single day, and all eight were the same
 * thing: a field whose type, presence or content was ASSUMED at the point it is used. An
 * unknown role defaulted to the weakest one; then a missing role did; then a cited text with
 * no `spdx` was skipped, disabling the role check for it; then an empty `copyright` array was
 * accepted; then `[""]`, a bare string, and `["  "]` each passed the emptiness test; then a
 * definition with its `text` deleted skipped the corpus-to-notices comparison entirely.
 *
 * Each was fixed where it was found, and the next one appeared somewhere else, because the
 * corpus had a schema in prose and none in code. Absent data kept taking the permissive
 * branch. This is that schema, in one place, run from `reconcileSysrootCorpus` so BOTH gates
 * get it — and the cargo-free gate is the one that matters, because it runs where the
 * redistribution that creates the obligation happens.
 *
 * ## What a defect here costs
 *
 * Nothing crashes. The app ships with licence notices that name the wrong holder, omit a
 * required licence, or reproduce a text that has been altered since it was recovered. No test
 * elsewhere catches it and no user can report it.
 *
 * ## What this deliberately does NOT do
 *
 * It does not parse SPDX. One recorded expression is the compound
 * `MIT AND Apache-2.0 WITH LLVM-exception`, and a half-correct parser in a licence gate is
 * trusted further than it deserves.
 *
 * It cannot catch two things, stated here rather than left to be discovered:
 *   - Under-counted copyright HOLDERS. Nothing records how many a package should have, so
 *     deleting eight of ten is structurally identical to deleting none. Closing it needs a
 *     committed expectation outside this document.
 *   - Lockstep licence NARROWING: rewrite `spdx`, drop the citation and delete the role in one
 *     edit and the corpus stays internally consistent. Both gates are blind to it by
 *     construction, because neither re-derives the expression from an out-of-repo source.
 * pinned: none — this function's rules are verified by mutation against the committed corpus
 */
function validateSysrootCorpus(doc, raw) {
  const problems = [];
  const say = (path, message) => problems.push(`${path}: ${message}`);
  const isFilledString = (value) => typeof value === "string" && value.trim().length > 0;
  // What remains of a copyright line once the boilerplate is removed: the holder. Deliberately
  // permissive about the shape — holders here include "Rich Felker, et al.", "The Rust Project
  // Developers" and "RAD Game Tools and Valve Software" — and strict only about there being
  // something left at all.
  const namedHolderIn = (line) => {
    const remainder = String(line)
      .replace(/^\s*copyright\b/i, "")
      .replace(/\((c|©)\)/gi, "")
      .replace(/[©]/g, "")
      .replace(/\b\d{4}(\s*[-–,]\s*\d{2,4})*/g, "")
      .replace(/[\s.,;:_-]+/g, " ")
      .trim();
    // An UNFILLED PLACEHOLDER is not a name. `Copyright (c) <copyright holders>` — the literal
    // template text of the MIT licence — survived every strip above as the non-empty string
    // `<copyright holders>`, so the corpus validated, the notices regenerated consistently, and
    // the package shipped a reproduced licence attributing the work to nobody. That is the
    // exact failure this whole holder rule exists to prevent, reached by copying the template
    // instead of by leaving the field blank.
    //
    // Rejected when the remainder is placeholder tokens AND NOTHING ELSE, however many.
    //
    // The first attempt required the whole remainder to be ONE bracketed token, which the real
    // template forms defeat by having two: MIT ships `Copyright (c) <year> <copyright holders>`
    // and Apache `Copyright [yyyy] [name of copyright owner]`. `<year>` is not a four-digit
    // number so the year strip above leaves it, and two tokens are not one, so both passed as
    // named holders — the same defect the single-token rule was written to close, reached by
    // copying the template more faithfully.
    //
    // Still not a blanket bracket rule: what is required is that removing every bracketed group
    // leaves nothing behind. `adler2` legitimately records `Jonas Schievink
    // <jonasschievink@gmail.com>`, whose remainder is a real name plus one bracketed address,
    // so it survives — verified against all 35 committed holder lines.
    if (remainder.replace(/[<[{(][^<>[\]{}()]*[>\]})]/g, "").trim().length === 0) return "";
    if (/^(copyright holders?|name of copyright owner|copyright owner|owner|author|your name|yyyy|xxxx)$/i
      .test(remainder)) {
      return "";
    }
    return remainder;
  };
  const digestOf = (text) => createHash("sha256").update(text, "utf8").digest("hex");
  // Every rule below was checked against the committed corpus before being written. The
  // recipes are MEASURED, not assumed: bodies are compared without normalization because 17
  // of 23 do not end in a newline and 4 begin with whitespace, and byte counts use UTF-8
  // because two bodies contain U+00A9 and would fail a `text.length` comparison.

  if (!doc || typeof doc !== "object" || Array.isArray(doc)) {
    say("$", "the corpus is not a JSON object");
    return problems;
  }

  // The file is committed and reviewed by humans, so its bytes matter: a CR inside a licence
  // body, or a reformat, changes what users receive while looking identical in a diff.
  if (typeof raw === "string") {
    if (raw.charCodeAt(0) === 0xfeff) say("$", "the file begins with a byte-order mark");
    if (raw.includes("\r")) say("$", "the file contains a carriage return");
    if (`${JSON.stringify(doc, null, 2)}\n` !== raw) {
      say("$", "the file is not byte-identical to its re-serialised form — it was hand-edited "
        + "or written by another tool, so a licence body may differ from what review saw");
    }
  }

  // The compiler identity. Required and type-checked HERE, because
  // `reconcileCorpusAgainstArchiveToolchain` compares these against the shipped binaries and a
  // missing field would make it SKIP the comparison rather than fail it — deleting
  // `rustcCommitHash` alone removed the same-version/different-build binding entirely.
  if (!/^\d+\.\d+\.\d+$/.test(String(doc.toolchain ?? ""))) {
    say("$.toolchain", "is not a version string — the notices would claim licences recovered " +
      "from a toolchain that cannot be identified");
  }
  if (!/^[0-9a-f]{40}$/.test(String(doc.rustcCommitHash ?? ""))) {
    say("$.rustcCommitHash", "is not 40 lowercase hex — this is the only field that " +
      "distinguishes two builds of one rustc release, whose vendored crate versions can " +
      "differ, so without it a same-version corpus for a different build is accepted");
  }
  if (!/^\d{4}-\d{2}-\d{2}$/.test(String(doc.rustcCommitDate ?? ""))) {
    say("$.rustcCommitDate", "is not an ISO date, so the corpus cannot be audited against a " +
      "toolchain release");
  }

  // --- licence text definitions -------------------------------------------------------
  const texts = doc.licenseTexts;
  if (!texts || typeof texts !== "object" || Array.isArray(texts)) {
    say("$.licenseTexts", "missing or not an object");
    return problems;
  }
  const textFields = ["spdx", "title", "sha256", "bytes", "provenance", "text"];
  const bodyOwners = new Map();
  const titles = new Map();
  // Claims a title makes about the world, checked after the citing set is known.
  const sharedTextClaims = new Map();
  const perCrateClaims = new Map();
  for (const id of Object.keys(texts)) {
    const at = `$.licenseTexts["${id}"]`;
    const entry = texts[id];
    if (!entry || typeof entry !== "object" || Array.isArray(entry)) {
      say(at, "is not an object");
      continue;
    }
    for (const field of textFields) {
      if (!Object.hasOwn(entry, field)) {
        say(at, `has no \`${field}\` — a half-formed definition, and every reader of this ` +
          `corpus is lenient about exactly that`);
      }
    }
    if (!isFilledString(entry.spdx)) {
      say(at, "records no `spdx`, which disables the role check for every package citing it");
    } else {
      const problem = spdxSyntaxProblem(entry.spdx);
      if (problem) say(at, `\`spdx\` "${entry.spdx}" ${problem}`);
    }
    // The title is the heading users read above the reproduced text. Blank ships a nameless
    // licence section; an `L<n>` token forges a citation the package does not have.
    if (!isFilledString(entry.title)) {
      say(at, "records no `title` — the notices would name this licence file `undefined`");
    } else {
      if (/\bL\d+\b/.test(entry.title)) {
        say(at, `title "${entry.title}" contains an L-number, which is how the notices cite ` +
          `bodies — it would read as a citation this package does not have`);
      }
      if (/[\r\n]/.test(entry.title)) say(at, "title spans more than one line");
      const clash = titles.get(entry.title.trim());
      if (clash) {
        say(at, `title is byte-identical to ${clash}'s — two reproduced texts cannot be told ` +
          `apart in the shipped notices`);
      }
      titles.set(entry.title.trim(), id);
      // TITLE ↔ SPDX. Two title conventions hold across every entry, and binding them costs
      // nothing while closing a mutation no other rule can see: transposing two titles leaves
      // every digest, id and citation valid, and ships each reproduced text under the other's
      // name. Users are told which licence they are reading, and it is the wrong one.
      const shared = /^(.+?) — shared text, identical across (\d+) packages \((.+)\)$/
        .exec(entry.title.trim());
      // A NEAR MISS is reported, not silently exempted. The pattern carries a literal em-dash,
      // so a title written with an ASCII hyphen matched nothing, `sharedTextClaims` was never
      // populated, and every check it feeds — the title↔SPDX binding here, the count and the
      // package list downstream — was skipped for that text. A licence body could then ship
      // under another licence's name with a fabricated package list, and the only thing
      // standing between that and the gate was one punctuation character.
      //
      // Keyed on the distinctive phrase rather than the punctuation. Four titles in the corpus
      // are legitimately free-form ("Unicode License v3", the two compiler-builtins files),
      // and none of them contains it, so this costs no false failures — verified against the
      // committed corpus. Free-form titles remain bound to nothing, which is a real remaining
      // gap and is stated as one rather than papered over with a heuristic that would reject
      // those four.
      if (!shared && /shared text, identical across/.test(entry.title)) {
        say(at, `title "${entry.title.trim()}" is nearly the shared-text form but does not ` +
          `match it — the shared-text checks are keyed on that exact shape, so a title one ` +
          `character off silently disables the title↔SPDX binding, the package count and the ` +
          `package list all at once`);
      }
      if (shared) {
        if (shared[1] !== entry.spdx) {
          say(at, `title announces "${shared[1]}" but \`spdx\` records "${entry.spdx}" — the ` +
            `reproduced text would be presented to users as a licence it is not`);
        }
        sharedTextClaims.set(id, {
          count: Number(shared[2]),
          names: shared[3].split(",").map((name) => name.trim()).filter(Boolean),
        });
      }
      // TITLE ↔ PACKAGE, for the per-crate files: `libc-0.2.178 :: LICENSE-MIT`. The named
      // crate and version must be one that actually cites this body, or the notices reproduce
      // one crate's licence document under another crate's heading.
      const perCrate = /^([A-Za-z0-9_.+-]+)-(\d+\.\d+\.\d+) :: /.exec(entry.title.trim());
      if (perCrate) perCrateClaims.set(id, { crate: perCrate[1], version: perCrate[2] });
    }
    if (typeof entry.text !== "string" || entry.text.trim().length === 0) {
      say(at, "has a blank `text` — the notices would show a licence heading followed by " +
        "nothing, which is visibly undischarged to a lawyer and invisible to this gate");
      continue;
    }
    // A floor, because "non-empty" admits a single character. The smallest real body here is
    // 0BSD at 664 bytes over 5 lines.
    const bodyBytes = Buffer.byteLength(entry.text, "utf8");
    const bodyLines = entry.text.split("\n").filter((line) => line.trim().length > 0).length;
    if (bodyBytes < 200 || bodyLines < 3) {
      say(at, `\`text\` is ${bodyBytes} bytes over ${bodyLines} non-blank lines, below any ` +
        `real licence — it was truncated`);
    }
    if (!/^[0-9a-f]{64}$/.test(entry.sha256 ?? "")) {
      say(at, "`sha256` is not 64 lowercase hex characters");
    } else if (entry.sha256 !== digestOf(entry.text)) {
      say(at, "`sha256` does not match the body beside it — the licence text users receive " +
        "has been altered since it was recovered from the toolchain");
    }
    if (!Number.isInteger(entry.bytes) || entry.bytes <= 0) {
      say(at, "`bytes` is not a positive integer");
    } else if (entry.bytes !== bodyBytes) {
      say(at, `\`bytes\` records ${entry.bytes} but the body is ${bodyBytes} — it was ` +
        `truncated or padded`);
    }
    // The id encodes the licence AND the digest, so it is a second, independent binding: a
    // body swapped underneath an existing citation breaks it even if someone updates sha256.
    if (typeof entry.sha256 === "string" && isFilledString(entry.spdx)) {
      const slug = entry.spdx.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "");
      const expected = `${slug}-${entry.sha256.slice(0, 12)}`;
      if (id !== expected) {
        say(at, `id is not derived from its own spdx and digest (expected \`${expected}\`) — ` +
          `either the body was swapped under an existing citation, or a body was relabelled ` +
          `as a different licence`);
      }
    }
    // Distinct, but NOT non-containing: eight real pairs embed another body verbatim, because
    // compiler-builtins' LICENSE.txt carries the whole Apache-2.0 text inside it.
    const twin = bodyOwners.get(entry.text);
    if (twin) {
      say(at, `\`text\` is byte-identical to ${twin}'s — two ids for one body means a ` +
        `citation can be redirected without changing what is reproduced`);
    }
    bodyOwners.set(entry.text, id);
    if (!Array.isArray(entry.provenance) || entry.provenance.length === 0
      || !entry.provenance.every(isFilledString)) {
      say(at, "`provenance` is not a non-empty array of non-blank strings — a body with no " +
        "stated origin cannot be re-derived, so its digest proves self-consistency and never " +
        "authenticity");
    }
  }

  // --- packages -----------------------------------------------------------------------
  const packages = doc.packages;
  if (!Array.isArray(packages) || packages.length === 0) {
    say("$.packages", "missing or not a non-empty array");
    return problems;
  }
  const roles = new Set(["alternative", "additional", "exception"]);
  const cited = new Set();
  const seenKeys = new Set();
  packages.forEach((pkg, index) => {
    const at = `$.packages[${index}](${pkg?.name ?? "?"})`;
    if (!pkg || typeof pkg !== "object" || Array.isArray(pkg)) {
      say(at, "is not an object");
      return;
    }
    if (!isFilledString(pkg.name) || !/^[A-Za-z0-9_.+-]+$/.test(pkg.name)) {
      say(at, "`name` is outside the character set the notices' own stanza parser matches, so " +
        "this package's attribution checks would silently never run");
    }
    if (!/^\d+\.\d+\.\d+$/.test(pkg.version ?? "")) {
      say(at, "`version` is not a version string — the stanza heading will not parse");
    }
    // `crateName` is an OVERRIDE, so it is held to the identity that makes it safe.
    //
    // It is read at exactly one place — the per-crate title binding — where it decides which
    // package a licence document titled `<crate>-<version> :: …` is allowed to belong to.
    // Nothing validated it, and every one of the 19 entries sets it to its own name, so the
    // field was pure latent authority: pointing gimli's `crateName` at `libc` let gimli's MIT
    // document ship under a `libc-0.32.3` heading, at a version libc has never had, while
    // libc's own stanza cited a different body. An override nobody diverges from should be
    // pinned to the thing it overrides; if a real divergence is ever needed, this makes it an
    // explicit change rather than a silent one.
    if (Object.hasOwn(pkg, "crateName")
      && (!isFilledString(pkg.crateName)
        || normalizeCrateName(pkg.crateName) !== normalizeCrateName(pkg.name ?? ""))) {
      say(at, `\`crateName\` is "${pkg.crateName}" but \`name\` is "${pkg.name}" — this field ` +
        `decides which package may claim a per-crate licence document, so a divergence lets ` +
        `one crate's licence ship under another crate's heading`);
    }
    // Keyed on the PAIR: libc legitimately links twice, a Cargo copy and a sysroot copy, and
    // merging on name alone drops one crate's attribution.
    const key = `${pkg.name}@${pkg.version}`;
    if (seenKeys.has(key)) say(at, `is a duplicate of an earlier entry for ${key}`);
    seenKeys.add(key);
    if (!isFilledString(pkg.spdx)) {
      say(at, "records no `spdx` — the legal claim for this package is absent");
    } else {
      // Syntax before semantics. `declarationRequires` reads STRUCTURE off this string to
      // decide whether an additional obligation binds in every alternative, and structure is
      // only readable from an expression that parses — three malformations each produced a
      // silent false accept there before this check existed.
      const problem = spdxSyntaxProblem(pkg.spdx);
      if (problem) {
        say(at, `\`spdx\` "${pkg.spdx}" ${problem} — the obligations a licensee takes cannot ` +
          `be read off an expression that does not parse`);
      }
    }

    // The holders. The shared MIT body these cite is the SPDX TEMPLATE, with an unfilled
    // "<copyright holders>" placeholder — so the filled holder travels in this stanza or it
    // travels nowhere, and MIT clause 1 requires it to accompany the binary.
    if (!Array.isArray(pkg.copyright)) {
      say(at, `\`copyright\` is ${typeof pkg.copyright}, not an array — a string is spread ` +
        `into single characters and an object renders as "[object Object]"`);
    } else {
      const filled = pkg.copyright.filter(
        (line) => typeof line === "string" && line.trim().length > 0);
      if (filled.length === 0) {
        say(at, "records no copyright holder — the notices would reproduce its licence text " +
          "while attributing it to nobody");
      }
      pkg.copyright.forEach((line, j) => {
        if (typeof line !== "string") {
          say(`${at}.copyright[${j}]`, `is ${typeof line}, which renders as "[object Object]" ` +
            `in the shipped notices`);
        } else if (line.trim().length === 0) {
          say(`${at}.copyright[${j}]`, "is blank — it renders as an empty line and satisfies " +
            "any containment check");
        } else if (/[\r\n\t]/.test(line)) {
          say(`${at}.copyright[${j}]`, "contains a newline or tab, which splits the stanza so " +
            "the verify gate re-parses it wrongly");
        } else if (namedHolderIn(line).length === 0) {
          // A line can be well-formed and name NOBODY. `Copyright (c)` passes every structural
          // test — non-blank, a string, single-line, begins with "Copyright" — and renders into
          // the notices as an attribution to no one. Distinct from the under-counting this
          // pass cannot catch: that leaves real holders, this leaves a husk.
          say(`${at}.copyright[${j}]`, `is "${line.trim()}", which names no holder — strip the ` +
            `marker, year and punctuation and nothing remains, so the notices would attribute ` +
            `the reproduced licence to nobody while looking like they attribute it to someone`);
        }
      });
      if (new Set(filled).size !== filled.length) {
        say(at, "lists the same copyright holder twice");
      }
    }

    // The citations, and their roles. `licenseTexts` must be an ARRAY: a string passes a
    // `.length` test and is then iterated per character, and an object passes it outright.
    if (!Array.isArray(pkg.licenseTexts) || pkg.licenseTexts.length === 0) {
      say(at, "`licenseTexts` is not a non-empty array — a package reproducing no licence " +
        "text discharges no obligation");
      return;
    }
    if (new Set(pkg.licenseTexts).size !== pkg.licenseTexts.length) {
      say(at, "cites the same licence text twice");
    }
    for (const id of pkg.licenseTexts) {
      // Own-property, so an id like "toString" cannot resolve through the prototype chain.
      if (typeof id !== "string" || !Object.hasOwn(texts, id)) {
        say(at, `cites licence text \`${id}\`, which the corpus does not define`);
        continue;
      }
      cited.add(id);
    }
    const declaredRoles = pkg.licenseTextRoles;
    if (!declaredRoles || typeof declaredRoles !== "object" || Array.isArray(declaredRoles)) {
      say(at, "`licenseTextRoles` is not an object, so no cited text has a recorded role and " +
        "every one of them would default to the weakest");
      return;
    }
    // Exact correspondence in BOTH directions. A missing role defaults to the weakest one; an
    // orphan role is dead policy left behind by a dropped citation, reading as though it still
    // enforced something.
    const roleKeys = new Set(Object.keys(declaredRoles));
    for (const id of pkg.licenseTexts) {
      if (!roleKeys.has(id)) {
        say(at, `cites licence text \`${id}\` without recording its role — whether a ` +
          `reproduced text is an alternative, an additional obligation or an exception ` +
          `cannot be inferred from the expression`);
      }
    }
    for (const id of roleKeys) {
      if (!pkg.licenseTexts.includes(id)) {
        say(at, `records a role for \`${id}\`, which it does not cite — dead policy that ` +
          `reads as though it still enforced something`);
      }
      if (!roles.has(declaredRoles[id])) {
        say(at, `gives \`${id}\` the role "${declaredRoles[id]}", which is not one of ` +
          `${[...roles].join(", ")}`);
      }
    }
  });

  // The title claims, now that the citing set is known.
  const citersOf = new Map();
  for (const pkg of packages) {
    for (const id of Array.isArray(pkg?.licenseTexts) ? pkg.licenseTexts : []) {
      if (!citersOf.has(id)) citersOf.set(id, []);
      citersOf.get(id).push(pkg);
    }
  }
  for (const [id, claim] of sharedTextClaims) {
    const citers = citersOf.get(id) ?? [];
    const at = `$.licenseTexts["${id}"]`;
    if (citers.length !== claim.count) {
      say(at, `title says this text is shared across ${claim.count} packages, but ` +
        `${citers.length} cite it — the count users read is wrong`);
    }
    const actual = new Set(citers.map((pkg) => normalizeCrateName(pkg.name)));
    const claimed = new Set(claim.names.map(normalizeCrateName));
    const missing = [...claimed].filter((name) => !actual.has(name));
    const extra = [...actual].filter((name) => !claimed.has(name));
    if (missing.length > 0 || extra.length > 0) {
      say(at, `title names a package set that is not the citing set` +
        `${missing.length ? ` (named but not citing: ${missing.join(", ")})` : ""}` +
        `${extra.length ? ` (citing but not named: ${extra.join(", ")})` : ""}`);
    }
  }
  for (const [id, claim] of perCrateClaims) {
    const citers = citersOf.get(id) ?? [];
    const at = `$.licenseTexts["${id}"]`;
    const matches = citers.some(
      (pkg) => normalizeCrateName(pkg.crateName ?? pkg.name) === normalizeCrateName(claim.crate)
        && pkg.version === claim.version);
    if (!matches) {
      say(at, `title names ${claim.crate}-${claim.version}, but the packages citing it are ` +
        `[${citers.map((pkg) => `${pkg.name}@${pkg.version}`).join(", ") || "none"}] — the ` +
        `notices would reproduce one crate's licence document under another crate's heading`);
    }
  }

  // A definition nothing cites has dropped out of the shipped notices. If a package's declared
  // licence still names it, that licence is now reproduced nowhere.
  for (const id of Object.keys(texts)) {
    if (!cited.has(id)) {
      say(`$.licenseTexts["${id}"]`, "is defined but cited by no package — it no longer " +
        "appears in the shipped notices");
    }
  }

  // --- unfinished attribution ---------------------------------------------------------
  // Must be an ARRAY. Written as the `{count, packages}` object used elsewhere in this same
  // file, `.length` is undefined and the emptiness guard passes while the corpus says in its
  // own words that an attribution is unfinished.
  if (Object.hasOwn(doc, "unresolved") && !Array.isArray(doc.unresolved)) {
    say("$.unresolved", `is ${typeof doc.unresolved}, not an array — an emptiness check on it ` +
      `passes whatever it contains, including a recorded open item`);
  }

  return problems;
}

/**
 * Reconciles the sysroot licence corpus against the inventory.
 *
 * Returned as problems rather than thrown so BOTH modes can use it. `--verify-committed`
 * exits before `build()` runs, so a check living only inside `sysrootPackageEntries` never
 * reached the cargo-free gate — which is the public one, and the only one that runs where the
 * redistribution actually happens. A corpus deletion would have been caught internally and
 * waved through publicly, which is the wrong way round.
 */
function reconcileSysrootCorpus(doc, { channel, raw } = {}) {
  // SHAPE first: every rule below reads fields this pass has already type-checked, so a
  // malformed corpus produces one clear list of shape errors rather than a cascade of
  // confusing consequences from reading a string as an array.
  const problems = [
    ...validateSysrootCorpus(doc, raw),
    ...reconcileCorpusAgainstArchiveToolchain(doc),
    ...validateLicenceTextRoles(doc),
  ];
  // Corpus-wide invariants, here rather than in `sysrootPackageEntries`, because that is
  // reached only from `build()` and therefore only from `--check`. This is the THIRD sweep
  // for this pattern on this PR: each time I moved the instances I could see and left others,
  // so the rule is now stated rather than applied case by case — a check that decides whether
  // a licence corpus may be REDISTRIBUTED belongs in the gate that runs where redistribution
  // happens, which is the cargo-free one.
  if (channel !== undefined && doc.toolchain !== channel) {
    // Same rule the inventory is held to. A licence corpus recovered from a different
    // toolchain describes different crates at different versions, and reproducing those would
    // be worse than reproducing none: it is a confident, wrong attribution.
    problems.push(
      `${basename(sysrootPackagesPath)} was recovered from toolchain ${doc.toolchain}, but ` +
        `this build pins ${channel} — a corpus from another compiler describes different ` +
        `crates at different versions`
    );
  }
  const unresolved = doc.unresolved ?? [];
  if (unresolved.length > 0) {
    problems.push(
      `${basename(sysrootPackagesPath)} records unfinished attribution: ` +
        unresolved.map((u) => u.name ?? String(u)).join(", ")
    );
  }
  // The archive reconciliation cannot do this. `reconcileAgainstArchives` checks a unit with
  // sysroot evidence against `sysroot-crates.json` and then continues, so it never reaches the
  // indexed-name test for these crates — which means a package quietly deleted or renamed HERE
  // would leave both `--check` and `--verify-committed` green while its licence stopped being
  // reproduced. That is the same silent-deletion shape this gate exists to prevent, one file
  // over.
  const inventory = existsSync(sysrootCratesPath)
    ? (JSON.parse(readFileSync(sysrootCratesPath, "utf8")).crates ?? [])
    : [];
  const corpusNames = new Map();
  for (const pkg of doc.packages) {
    const key = normalizeCrateName(pkg.name);
    if (corpusNames.has(key)) {
      problems.push(
        `${basename(sysrootPackagesPath)} lists ${pkg.name} twice — a duplicate can mask a ` +
          `deletion, because the count still matches while one entry is wrong`
      );
    }
    corpusNames.set(key, pkg.name);
  }
  const uncovered = inventory.filter((name) => !corpusNames.has(normalizeCrateName(name)));
  if (uncovered.length > 0) {
    problems.push(
      `${basename(sysrootCratesPath)} lists ${uncovered.length} crate(s) with no licence in ` +
        `${basename(sysrootPackagesPath)}: ${uncovered.join(", ")}`
    );
  }
  // Versions are compared against ARCHIVE EVIDENCE where the archive actually proves one.
  //
  // Names alone would accept a stale or mistyped version, and the archive can do better for
  // the vendored crates: their member path strings carry the crate's own version, so `libc
  // 0.2.178` is proven rather than asserted.
  //
  // It cannot for the IN-TREE crates. `std`, `core`, `alloc`, `unwind`, `panic_abort`,
  // `std_detect` and the workspace shims live under a sysroot path that carries the TOOLCHAIN
  // version, so the archive reports 1.94.0 for all of them while the corpus records each
  // crate's own declared version (`0.0.0` for the in-tree ones). Comparing those would
  // manufacture nine mismatches that are not wrong, and a check that cries wolf on correct
  // input gets disabled — which is worse than not having it.
  //
  // Those crates never reach this loop: `provenSysrootVersions` admits only records carrying
  // sysroot VENDOR path evidence, so the in-tree ones are absent from what it returns rather
  // than skipped here.
  const { observations, evidenceBySlice } = provenSysrootVersions();
  // The expectation comes from the CORPUS, not from the archives being tested.
  //
  // Deriving it from the archives — the union of what the slices carried — was circular, and
  // the circularity was invisible while only one slice was damaged. Strip a crate's vendor
  // path records from ALL THREE slices and the union no longer contains it, so nothing is
  // missing, the other eight keep `observations` non-empty, and that crate's corpus version
  // goes unchecked across the entire xcframework. An expectation that moves with its evidence
  // is not an expectation.
  //
  // `vendoredCrates` is therefore declared in the corpus alongside the toolchain identity that
  // determines it, and is compared BOTH ways below: a declared crate missing from a slice is a
  // gap, and a crate observed as vendored but not declared is an undeclared addition. Without
  // the second direction the list would be a floor rather than a specification, and a
  // toolchain bump that pulled in a new vendored crate would slip past unrecorded.
  // The SLICE SET is anchored the same way, and for the same reason.
  //
  // Every archive-reading check takes its list of slices from the xcframework's Info.plist and
  // holds it to no lower bound, so deleting one key from one `<dict>` removed an entire
  // shipping slice from the evidence while the archive stayed on disk and stayed
  // redistributed. Nothing failed: the remaining slices were consistent, and a check that
  // examines two of three archives cannot tell it was meant to examine three. The three
  // enumerating functions do not even agree on the key — two read `LibraryPath`, the
  // Cargo-side one reads `BinaryPath` — so either key alone was enough to hide a slice from
  // half the gate.
  //
  // `appliesTo.slices` already states which slices this corpus claims to cover, so it is the
  // expectation, and both keys are required to be present and to name a file that exists. The
  // reverse direction too: a slice in the manifest that the corpus does not claim to cover is
  // an unlicensed binary, not a bonus.
  const declaredSlices = Array.isArray(doc.appliesTo?.slices)
    ? doc.appliesTo.slices.map(String)
    : null;
  if (declaredSlices === null || declaredSlices.length === 0) {
    problems.push(
      `${basename(sysrootPackagesPath)} declares no \`appliesTo.slices\`, so the set of ` +
        `archives this corpus covers would be whatever the manifest happens to list — and a ` +
        `slice deleted from the manifest would silently stop being checked`
    );
  } else {
    const plistPath = join(xcframeworkDir, "Info.plist");
    if (!existsSync(plistPath)) {
      problems.push(`${plistPath} is missing, so no declared slice could be located`);
    } else {
      const plist = readFileSync(plistPath, "utf8");
      const entries = new Map();
      for (const chunk of plist.split("<dict>")) {
        const id = /<key>LibraryIdentifier<\/key>\s*<string>([^<]+)<\/string>/.exec(chunk);
        if (!id) continue;
        entries.set(id[1], {
          libraryPath: /<key>LibraryPath<\/key>\s*<string>([^<]+)<\/string>/.exec(chunk)?.[1],
          binaryPath: /<key>BinaryPath<\/key>\s*<string>([^<]+)<\/string>/.exec(chunk)?.[1],
        });
      }
      for (const slice of declaredSlices) {
        const entry = entries.get(slice);
        if (entry === undefined) {
          problems.push(
            `${basename(sysrootPackagesPath)} declares slice ${slice}, but the xcframework ` +
              `manifest does not list it — a slice the corpus licenses and the manifest omits ` +
              `is one no archive check will ever read`
          );
          continue;
        }
        for (const [key, value] of [["LibraryPath", entry.libraryPath], ["BinaryPath", entry.binaryPath]]) {
          if (value === undefined) {
            problems.push(
              `slice ${slice} has no \`${key}\` in the xcframework manifest — the archive ` +
                `checks that key on drop the slice silently, so its contents stop being ` +
                `verified while it continues to ship`
            );
          } else if (!existsSync(join(xcframeworkDir, slice, value))) {
            problems.push(
              `slice ${slice} names ${value} via \`${key}\`, but that file does not exist`
            );
          }
        }
        // The two keys must name the SAME archive, not merely both name something.
        //
        // Requiring presence and existence was one step short, and the step it missed is the
        // one that matters: the gate reads `LibraryPath` in two places and `BinaryPath` in a
        // third, so two keys pointing at DIFFERENT existing archives split the gate against
        // itself. A decoy could satisfy the crate-attribution pass while the binary that
        // actually ships — the one Xcode links, named by `LibraryPath` — went unexamined for
        // that same crate set. This is not hypothetical here: an untracked `libLavaSecWGCore.a`
        // sits beside the real archive in these very directories and would serve as the decoy.
        //
        // Agreement rather than picking a canonical field, because the disagreement is the
        // signal. Both keys are xcodebuild's own output and are identical in every manifest it
        // writes; a manifest where they diverge has been edited, and that is worth reporting
        // rather than silently resolving in favour of whichever field this file happens to
        // prefer today.
        if (entry.libraryPath !== undefined
          && entry.binaryPath !== undefined
          && entry.libraryPath !== entry.binaryPath) {
          problems.push(
            `slice ${slice} names ${entry.libraryPath} via \`LibraryPath\` but ` +
              `${entry.binaryPath} via \`BinaryPath\` — different parts of this gate read ` +
              `different keys, so two archives here means the one that ships can go unchecked ` +
              `while a decoy satisfies the checks in its place`
          );
        }
      }
      for (const slice of entries.keys()) {
        if (declaredSlices.includes(slice)) continue;
        problems.push(
          `the xcframework manifest lists slice ${slice}, which ` +
            `${basename(sysrootPackagesPath)} does not claim to cover — a redistributed ` +
            `binary outside the corpus's stated scope is an unlicensed one`
        );
      }
    }
  }
  const declaredVendored = Array.isArray(doc.vendoredCrates?.crates)
    ? doc.vendoredCrates.crates.map(normalizeCrateName)
    : null;
  if (declaredVendored === null) {
    problems.push(
      `${basename(sysrootPackagesPath)} declares no \`vendoredCrates.crates\` array — without ` +
        `it the set of crates whose versions the archives must prove would have to be derived ` +
        `from those same archives, which cannot detect a crate disappearing from all of them`
    );
  } else if (declaredVendored.length === 0) {
    // Vacuity guard. An empty list satisfies every per-crate loop below and would report
    // success while checking nothing — the same shape as the empty-comparison case this
    // function already guards against elsewhere.
    problems.push(
      `${basename(sysrootPackagesPath)} declares an EMPTY \`vendoredCrates.crates\` list, so ` +
        `no crate version would be compared against the archives at all`
    );
  } else if (inventory.length > 0) {
    const inventoryKeys = new Set(inventory.map(normalizeCrateName));
    for (const crate of declaredVendored) {
      if (!inventoryKeys.has(crate)) {
        problems.push(
          `${basename(sysrootPackagesPath)} declares ${crate} as vendored, but ` +
            `${basename(sysrootCratesPath)} does not list it as linked at all — a declaration ` +
            `about a crate we do not ship cannot be evidence about one we do`
        );
        continue;
      }
      for (const [slice, found] of evidenceBySlice) {
        if (found.has(crate)) continue;
        problems.push(
          `${slice} carried no ${SYSROOT_VENDOR_PATH_EVIDENCE} evidence for ${crate}, which ` +
            `${basename(sysrootPackagesPath)} declares vendored, so that crate's version in ` +
            `that slice could not be compared against the corpus — sibling slices proving a ` +
            `version for it is not evidence about THIS slice, which is exactly the one that ` +
            `may have been rebuilt or stripped differently`
        );
      }
    }
    // The other direction, so the declaration is a specification and not merely a floor.
    const declaredSet = new Set(declaredVendored);
    const undeclared = new Set();
    for (const found of evidenceBySlice.values()) {
      for (const crate of found) if (!declaredSet.has(crate)) undeclared.add(crate);
    }
    for (const crate of [...undeclared].sort()) {
      problems.push(
        `${crate} carries ${SYSROOT_VENDOR_PATH_EVIDENCE} evidence in the archives but is not ` +
          `declared in \`vendoredCrates\` — a toolchain bump that vendors a new crate has to ` +
          `be recorded, not absorbed silently`
      );
    }
  }
  for (const [crate, versions] of observations) {
    const entry = doc.packages.find((pkg) => normalizeCrateName(pkg.name) === crate);
    if (!entry) continue;
    // Nothing is excluded here. Two earlier attempts filtered at this point and both were
    // wrong: comparing against the channel VALUE would silently exempt a vendored crate that
    // legitimately happened to be versioned `1.94.0`, and `requiredRustSrc.packages` records
    // every package whose version needed `rust-src` — which includes vendored crates like
    // `addr2line`, `memchr`, `miniz_oxide` and `object`, so using it as an in-tree list
    // exempted four crates that CAN be checked.
    //
    // The distinction only exists where the evidence is read, so it is made there.
    for (const proven of versions) {
      if (entry.version === proven) continue;
      problems.push(
        `${entry.name} is recorded as ${entry.version} in ${basename(sysrootPackagesPath)}, ` +
          `but the committed archive proves ${proven}`
      );
    }
  }

  // The other direction too. A corpus entry for a crate the archive does not contain is not a
  // missing obligation, but it is a licence claim about something we do not ship — which is
  // how a stale corpus survives a toolchain bump unnoticed.
  const inventoryNames = new Set(inventory.map(normalizeCrateName));
  const extra = [...corpusNames.entries()]
    .filter(([key]) => !inventoryNames.has(key))
    .map(([, name]) => name);
  if (extra.length > 0) {
    problems.push(
      `${basename(sysrootPackagesPath)} licenses ${extra.length} crate(s) absent from ` +
        `${basename(sysrootCratesPath)}: ${extra.join(", ")}`
    );
  }

  return problems;
}

/**
 * The sysroot crates, in the same shape `build` produces for Cargo packages.
 *
 * These cannot come through `packageIndex`: `cargo metadata` reports zero of them, because
 * they are linked from the precompiled standard library rather than resolved from the lock.
 * Until this landed they appeared in no notice at all — 17 crates statically linked into a
 * redistributed binary with nothing reproducing their licences.
 *
 * The corpus is committed rather than derived at generate time on purpose. Recovering it
 * needs the toolchain's own notice files and `rust-src`, neither of which exists on the bare
 * runner where the public gate runs, and both of which move when the toolchain pin moves —
 * which is why the file is keyed on `toolchain` and checked against the pin below.
 */
function sysrootPackageEntries(channel) {
  if (!existsSync(sysrootPackagesPath)) {
    throw new Error(`missing ${sysrootPackagesPath}`);
  }
  const raw = readFileSync(sysrootPackagesPath, "utf8");
  const doc = JSON.parse(raw);
  if (doc.toolchain !== channel) {
    // Same rule the inventory is held to. A licence corpus recovered from a different
    // toolchain describes different crates at different versions, and reproducing those
    // would be worse than reproducing none: it is a confident, wrong attribution.
    throw new Error(
      `${sysrootPackagesPath} was derived from Rust ${doc.toolchain}, but the pinned channel is ${channel}`
    );
  }
  const unresolved = doc.unresolved ?? [];
  if (unresolved.length > 0) {
    throw new Error(
      `${basename(sysrootPackagesPath)} still has ${unresolved.length} unresolved package(s): ` +
        unresolved.map((u) => u.name ?? String(u)).join(", ")
    );
  }

  for (const problem of reconcileSysrootCorpus(doc, { channel, raw })) throw new Error(problem);

  return doc.packages.map((pkg) => {
    const documents = (pkg.licenseTexts ?? []).map((id) => {
      const body = doc.licenseTexts[id];
      if (!body) {
        throw new Error(`${pkg.name} references licence text ${id}, which the corpus does not define`);
      }
      return { filename: body.title, text: body.text };
    });
    if (documents.length === 0) {
      throw new Error(`${pkg.name} carries no licence text in ${basename(sysrootPackagesPath)}`);
    }

    return {
      name: pkg.name,
      version: pkg.version,
      license: pkg.spdx ?? null,
      repository: pkg.repository ?? null,
      // The corpus records holders explicitly. `copyrightLines` is not reused here: it
      // recovers holders by scanning a licence file, and these texts are shared, deduplicated
      // bodies serving up to six packages — scanning one would attribute every package that
      // shares it to whichever holder happened to be in the text.
      copyrights: [...(pkg.copyright ?? [])].sort(),
      documents,
    };
  });
}

function build() {
  const keys = [...linkedCrateKeys()].sort((a, b) => a.localeCompare(b, "en"));
  const packages = packageIndex();

  const bodies = new Map(); // hash -> { id, text }
  const crates = [];
  const missing = [];

  for (const key of keys) {
    const pkg = packages.get(key);
    if (!pkg) {
      missing.push(`${key} (absent from cargo metadata)`);
      continue;
    }
    const documents = licenseDocuments(pkg);
    if (documents.length === 0) missing.push(`${key} (no license file in the published crate)`);

    const bodyIDs = [];
    for (const doc of documents) {
      const hash = createHash("sha256").update(doc.text).digest("hex");
      if (!bodies.has(hash)) {
        bodies.set(hash, { id: `L${String(bodies.size + 1).padStart(2, "0")}`, text: doc.text });
      }
      bodyIDs.push({ id: bodies.get(hash).id, filename: doc.filename });
    }

    crates.push({
      name: pkg.name,
      version: pkg.version,
      license: pkg.license ?? null,
      licenseFile: pkg.license_file ?? null,
      repository: pkg.repository ?? null,
      copyrights: copyrightLines(documents),
      texts: bodyIDs,
    });
  }

  // The sysroot crates, merged into the SAME body table so a licence text shared with a
  // Cargo crate is stored once and cited by both. Appended after the Cargo pass rather than
  // interleaved, so body IDs stay stable for the packages that already had them.
  const cited = new Set(crates.map((c) => `${normalizeCrateName(c.name)} ${c.version}`));
  for (const pkg of sysrootPackageEntries(pinnedChannel())) {
    // Keyed on name AND version, because a crate can be linked twice at two versions. `libc`
    // is exactly that: 0.2.189 resolved by Cargo and 0.2.178 from the precompiled std, both
    // present as their own members. Skipping on name alone would drop one of two genuinely
    // redistributed copies; not skipping at all would list `cfg_if 1.0.4` twice, since it is
    // the same version from both sources.
    if (cited.has(`${normalizeCrateName(pkg.name)} ${pkg.version}`)) continue;

    const bodyIDs = [];
    for (const doc of pkg.documents) {
      const hash = createHash("sha256").update(doc.text).digest("hex");
      if (!bodies.has(hash)) {
        bodies.set(hash, { id: `L${String(bodies.size + 1).padStart(2, "0")}`, text: doc.text });
      }
      bodyIDs.push({ id: bodies.get(hash).id, filename: doc.filename });
    }
    if (pkg.copyrights.length === 0) {
      missing.push(`${pkg.name} ${pkg.version} (no copyright holder in the sysroot corpus)`);
    }

    crates.push({
      name: pkg.name,
      version: pkg.version,
      license: pkg.license,
      licenseFile: null,
      repository: pkg.repository,
      copyrights: pkg.copyrights,
      texts: bodyIDs,
      origin: "rust-sysroot",
    });
  }

  crates.sort(
    (a, b) => a.name.localeCompare(b.name, "en") || a.version.localeCompare(b.version, "en")
  );

  return { crates, bodies: [...bodies.values()], missing };
}

function render({ crates, bodies, missing }) {
  const out = [];
  out.push("THIRD-PARTY NOTICES — LavaSec WireGuard engine");
  out.push("=".repeat(78));
  out.push("");
  out.push(
    "The prebuilt static library in ThirdParty/wireguard-core/build/ is compiled from the",
    "Rust crates listed below. Their licenses require this notice to accompany any binary",
    "redistribution, which includes the committed xcframework and any app that links it.",
    "",
    "GENERATED FILE — do not edit. Regenerate with:",
    "    node scripts/generate-wireguard-core-notices.mjs",
    "",
    "The set is every crate in the normal dependency graph of the shipped target triples",
    "(" + TARGETS.join(", ") + "). It excludes build- and dev-dependencies and the crates",
    "the lock carries only for non-Apple platforms. It still includes proc-macro crates,",
    "whose own code is not present in the artifact — deliberate over-inclusion.",
    ""
  );

  if (missing.length > 0) {
    out.push("UNRESOLVED — these need manual attention before public redistribution:");
    for (const item of missing) out.push(`  - ${item}`);
    out.push("");
  }

  out.push("-".repeat(78));
  out.push(`PACKAGES (${crates.length})`);
  out.push("-".repeat(78));
  out.push("");
  for (const crate of crates) {
    out.push(`${crate.name} ${crate.version}`);
    if (crate.license) out.push(`  License:    ${crate.license}`);
    if (crate.repository) out.push(`  Repository: ${crate.repository}`);
    for (const line of crate.copyrights) out.push(`  ${line}`);
    if (crate.copyrights.length === 0) {
      // Stated rather than left blank. Some crates publish license text with no holder
      // line filled in — an upstream omission, not a gap in this inventory, and the
      // license TEXT (which is the actual obligation) is still reproduced below. Saying so
      // keeps "upstream named nobody" distinguishable from "we failed to extract it".
      out.push("  (no copyright holder stated in the crate's own license file)");
    }
    if (crate.texts.length > 0) {
      out.push(`  Text:       ${crate.texts.map((t) => `${t.id} (${t.filename})`).join(", ")}`);
    } else {
      out.push("  Text:       NONE PROVIDED BY THE CRATE");
    }
    out.push("");
  }

  out.push("-".repeat(78));
  out.push(`LICENSE TEXTS (${bodies.length} unique)`);
  out.push("-".repeat(78));
  out.push("");
  for (const body of bodies) {
    out.push(`[${body.id}]`);
    out.push("");
    out.push(body.text);
    out.push("");
    out.push("=".repeat(78));
    out.push("");
  }

  return out.join("\n").replace(/\n{4,}/g, "\n\n\n") + "\n";
}

// ============================================================================
// WHAT EACH MODE PROVES — read this before trusting either of them
// ============================================================================
//
// The obligation: this engine ships as a binary containing code from ~57 open-source
// crates, and their licences require the copyright notices to travel with it. The failure
// that matters is a crate being LINKED but NOT CREDITED.
//
// Three checks guard that, and they are not equally strong.
//
//   1. `--check` (this file, cargo required)        THE AUTHORITY
//      Asks cargo what is in the dependency graph, re-reads each licence from the crate's
//      OWN published source, regenerates, byte-compares. Its expectation comes from
//      OUTSIDE this repository, so nothing committed here can forge it.
//      Runs: light-build.yml (path-filtered) AND internal-promotion.yml (not
//      path-filtered: every non-draft PR and every push to main; drafts skip until
//      `ready_for_review`, PR #784). The not-path-filtered one is why the notices cannot
//      reach the public mirror without a cargo-backed regeneration.
//
//   2. `scripts/check-wireguard-core-drift.sh` (Rust + Xcode required)
//      Rebuilds the whole engine from source and byte-compares the archives. Catches ANY
//      byte change, including every member rename described below.
//      Runs: light-build.yml only — self-hosted, fork-guarded, internal repo. It does NOT
//      run on the public mirror.
//
//   3. `--verify-committed` (this file, Node only)   BEST EFFORT
//      Reads the committed archives and cross-checks them against the notices. Runs
//      anywhere, which is the point: it is the only one of the three present on the public
//      mirror.
//
// WHY 3 IS "BEST EFFORT", IN ONE SENTENCE: it learns what a binary contains by reading
// MEMBER NAMES, and member names are editable text.
//
// Nothing inside compiled machine code records which crate produced it. The member name is
// the only label, and anyone who can edit the archive can edit the label — the rename is
// even length-preserving, because BSD ar stores long names NUL-padded inside the member
// body, so every header, size field and symbol-table offset stays valid. It is auditing a
// shipping container by reading the labels on the boxes.
//
// Adversarial review demonstrated that repeatedly. Renaming a crate's member to
// `lib.rmeta`, `rust.metadata.bin`, `__.SYMDEF`, `/`, `//`, to our own first-party crate,
// or to an exempted sysroot crate each removed a crate from attribution. Those are closed
// (position gate, payload checks, member-count bounds, ABI-symbol binding) EXCEPT the
// sysroot-exemption spelling, which is still open and tracked on the PR. No claim is made
// that the list is complete — it cannot be, because the underlying trust is in a string.
//
// SO, HONESTLY:
//   - Accidental omission — a dependency added without regenerating, a partial
//     regeneration, a hand-edit, a bad merge — is caught, usually by more than one check.
//     That is the failure that actually happens, and it is well covered.
//   - Deliberate tampering inside this repo is caught by 1 and 2, both of which rebuild
//     from outside sources.
//   - Deliberate tampering in a pull request against the PUBLIC mirror faces only 3. There
//     it raises the cost and makes the edit visible in review; it does not make it
//     impossible.
//
// Do not extend 3 in the belief that it can become authoritative. It cannot. If more
// assurance is wanted on the public side, the lever is making 1 or 2 run there, not adding
// another name-based rule here.
//
// --verify-committed: everything that can be checked WITHOUT cargo.
//
// The full --check re-derives the crate set from `cargo tree`, so it can only run where the
// pinned Rust toolchain is — the internal, self-hosted engine lane. That left the gate
// absent from the PUBLIC mirror, which is where the binary redistribution creating the
// obligation actually happens. This mode closes that: it verifies the two emitted copies
// are byte-identical, that the rendered file agrees with the committed index, and that no
// crate was left unresolved. It cannot notice a crate JOINING the graph — only the cargo
// mode can — but it catches every way the committed artefacts can be edited or drift apart,
// and it runs anywhere node does, including forks and the public repo.
// Declared as hoisted functions, not const arrows: --verify-committed runs before the
// index is constructed further down the file, and a const would be in its temporal dead
// zone there.
function sha256(text) {
  return createHash("sha256").update(text, "utf8").digest("hex");
}

function sectionOf(text, from, to) {
  const start = text.indexOf(from);
  const end = to === null ? text.length : text.indexOf(to);
  return start === -1 || end === -1 ? null : text.slice(start, end);
}

/// Reconciles the crates actually present in the committed archives against the crates the
/// notices cite. Returns problem strings; empty means clean.
///
/// `indexedKeys` is the set of "name version" strings from the committed index.
function reconcileAgainstArchives(indexedKeys) {
  const problems = [];

  // The slice set comes from Info.plist, not from whatever happens to be on disk.
  //
  // Globbing for `.a` files and requiring at least one meant a slice that went missing,
  // was renamed, or stopped matching simply dropped out of the reconciliation while the
  // remaining ones kept the gate green — so a crate present only in the vanished target
  // would go uncited and unreported. The xcframework declares what it ships; that is the
  // list to hold it to.
  const plistPath = join(xcframeworkDir, "Info.plist");
  if (!existsSync(plistPath)) {
    return [`missing ${plistPath} — cannot establish which slices should exist`];
  }
  const plist = readFileSync(plistPath, "utf8");
  const declared = [];
  for (const entry of plist.split("<dict>")) {
    const identifier = /<key>LibraryIdentifier<\/key>\s*<string>([^<]+)<\/string>/.exec(entry);
    const binary = /<key>BinaryPath<\/key>\s*<string>([^<]+)<\/string>/.exec(entry);
    if (identifier && binary) {
      declared.push({ identifier: identifier[1], binary: binary[1] });
    }
  }
  if (declared.length === 0) {
    return [`${plistPath} declares no libraries — the xcframework is malformed or unreadable`];
  }

  const normalize = normalizeCrateName;
  const indexedNames = new Set([...indexedKeys].map((k) => normalize(k.split(" ")[0])));
  const indexedVersions = new Map();
  for (const key of indexedKeys) {
    const at = key.lastIndexOf(" ");
    const name = normalize(key.slice(0, at));
    if (!indexedVersions.has(name)) indexedVersions.set(name, new Set());
    indexedVersions.get(name).add(key.slice(at + 1));
  }

  const sysroot = new Set();
  if (existsSync(sysrootCratesPath)) {
    const doc = JSON.parse(readFileSync(sysrootCratesPath, "utf8"));
    for (const name of doc.crates ?? []) sysroot.add(normalize(name));
    const channel = pinnedChannel();
    if (channel === null) {
      problems.push("could not read [toolchain].channel from rust-toolchain.toml");
    } else if (doc.toolchain !== channel) {
      problems.push(
        `${sysrootCratesPath} was derived from Rust ${doc.toolchain}, but the pinned channel is ${channel}`
      );
    }
  } else {
    problems.push(`missing ${sysrootCratesPath}`);
  }

  // THE LOCKFILE, which is what makes the provenance question answerable at all.
  //
  // Without it every crate whose own path string did not survive `strip = "debuginfo"` —
  // roughly half the Cargo ones — falls to the elimination branch and is reported as an
  // unlicensed sysroot crate. That is a wall of false findings, and a check that cries wolf
  // on a correct tree gets disabled. So an unusable lockfile stops the reconciliation with
  // one clear reason, the same way a missing Info.plist does, rather than running it on a
  // partition it cannot form.
  if (!existsSync(cargoLockPath)) {
    return [
      ...problems,
      `missing ${cargoLockPath} — without it the crates Cargo resolved cannot be told from ` +
        `the crates the sysroot shipped, and every archive crate would be judged as the wrong ` +
        `kind`,
    ];
  }
  const lockedCrates = lockedCrateNames(readFileSync(cargoLockPath, "utf8"));
  if (lockedCrates.size === 0) {
    // Vacuity guard, the same shape as the empty-`vendoredCrates` one: an empty set satisfies
    // every lookup below while classifying the entire Cargo graph as sysroot.
    return [
      ...problems,
      `${basename(cargoLockPath)} yielded no [[package]] entries — it is empty, truncated or ` +
        `no longer the format this reader parses, so nothing could be classified as ` +
        `Cargo-resolved`,
    ];
  }

  // THE LICENCE CORPUS, held to the archives DIRECTLY rather than through the inventory.
  //
  // Every pre-existing path from the binaries to the attribution ran through
  // `sysroot-crates.json`: a unit with sysroot evidence was checked against that inventory and
  // then `continue`d, and `reconcileSysrootCorpus` compares the inventory and the corpus to
  // each other. Both files are committed, so deleting a crate from BOTH in one commit removed
  // it from the question and from the answer at once and every comparison still held.
  // Reproduced with `adler2 2.0.1` — one archive member in each of the three shipped slices —
  // where this gate exited 0 while the next regeneration would have dropped its whole
  // attribution (`0BSD OR MIT OR Apache-2.0`, its copyright holder, its three licence bodies)
  // out of the redistributed notices.
  //
  // The archives are the independent witness: they are the artefact the obligation attaches
  // to, and nothing in this generator writes them. So what they prove is held to the corpus.
  const corpusNames = new Set();
  let corpusReadable = false;
  if (existsSync(sysrootPackagesPath)) {
    try {
      const doc = JSON.parse(readFileSync(sysrootPackagesPath, "utf8"));
      // SHAPE-CHECKED before it is believed. `for...of` over a string iterates CHARACTERS and
      // over an object throws, so `doc.packages ?? []` would turn a corpus whose package list
      // had been replaced by a scalar into a set of nonsense names — and then report all
      // nineteen real crates as unlicensed. `validateSysrootCorpus` is what names the shape
      // fault; this only has to decline to guess.
      if (Array.isArray(doc.packages)) {
        for (const pkg of doc.packages) {
          if (typeof pkg?.name === "string" && pkg.name !== "") corpusNames.add(normalize(pkg.name));
        }
        corpusReadable = true;
      }
    } catch {
      corpusReadable = false;
    }
  }
  if (!corpusReadable) {
    // Reported from here as well, and phrased for what THIS check loses. The caller reports
    // the same file as missing or unreadable, but that message says nothing about the
    // archive-to-corpus comparison silently not having run — and "a different check reports
    // this" is the assumption that left two earlier holes in this file.
    problems.push(
      `${basename(sysrootPackagesPath)} could not be read here, so no crate the archives prove ` +
        `came from the sysroot was checked against a licence`
    );
  }

  /**
   * What a crate the archives place in the sysroot obliges, whatever the inventory says.
   *
   * Both files are asserted, because they answer different questions: the inventory is what
   * stops the reconciliation reporting the crate as uncited, and the corpus is what actually
   * reproduces its licence. Versions are deliberately NOT compared here —
   * `reconcileSysrootCorpus` already compares every vendored crate's proven version against
   * the corpus entry, and with presence now anchored on both sides that comparison can no
   * longer be skipped by deleting the crate from either file. A second version check would
   * only report the same fault twice.
   */
  const sysrootObligations = (identifier, crateName, name) => {
    const out = [];
    if (!sysroot.has(name)) {
      out.push(
        `${identifier}: ${crateName} resolves to the Rust sysroot but is not listed in ` +
          `${basename(sysrootCratesPath)}`
      );
    }
    if (corpusReadable && !corpusNames.has(name)) {
      out.push(
        `${identifier}: ${crateName} is linked in from the Rust sysroot but ` +
          `${basename(sysrootPackagesPath)} carries no licence for it — the corpus is what the ` +
          `next regeneration renders, so this crate's attribution would stop being reproduced`
      );
    }
    return out;
  };

  for (const { identifier, binary } of declared) {
    const slice = join(xcframeworkDir, identifier, binary);
    if (!existsSync(slice)) {
      problems.push(`${identifier}/${binary} is declared in Info.plist but absent from disk`);
      continue;
    }

    let analysis;
    try {
      analysis = analyzeStaticLibrary(slice);
    } catch (error) {
      problems.push(`could not read ${identifier}/${binary}: ${error.message}`);
      continue;
    }

    // A slice that parses to nothing is a parser or artefact failure, not a clean bill.
    // Proven necessary: a file containing only the 8-byte ar magic yields zero members and
    // throws nothing.
    if (analysis.members.length === 0) {
      problems.push(`${identifier} yielded no members — the archive or the reader is broken`);
      continue;
    }

    // A member the attributor could not classify is an attribution FAILURE, and silence is
    // exactly the wrong response: the affected crate simply vanishes from the analysis while
    // the hundreds that still parse keep any non-empty check green, and its notice becomes
    // deletable.
    if (analysis.unattributed.length > 0) {
      problems.push(
        `${identifier}: ${analysis.unattributed.length} archive member(s) could not be attributed ` +
          `(first: ${analysis.unattributed[0]?.name ?? analysis.unattributed[0]})`
      );
    }

    // Grouped by COMPILATION UNIT — (crate, metadata hash) — not by (crate, version).
    //
    // `analyzeStaticLibrary` coalesces records by (crate, version) and unions their evidence,
    // so when a Cargo copy and a sysroot copy share a name AND a version they become one
    // record carrying both provenances, and a sysroot exemption applied to that aggregate
    // silently covers the Cargo copy too. `cfg-if` is already 1.0.4 on both sides; it escapes
    // today only because its Cargo path string does not survive `strip = "debuginfo"`, and a
    // rebuild where it does survive would merge them and drop the Cargo attribution.
    //
    // The metadata hash is what actually separates them: the two copies come from different
    // rlibs (`libcfg_if-0b754f5c….rlib` vs `cfg_if-fa0d401c…`), so their hashes differ even
    // when their versions do not.
    //
    // Judging each MEMBER alone would be too fine: provenance is a property of the rlib, and
    // most members carry no path string — only some do. So evidence is pooled within a
    // compilation unit and nowhere wider.
    const units = new Map();
    for (const member of analysis.members) {
      if (member.crate == null) continue; // already reported via `unattributed`
      const named = /^([A-Za-z0-9_]+)-([0-9a-f]{16})\./.exec(member.name ?? "");
      // Foreign objects (compiler-rt, ring's C and assembly) carry no crate-hash prefix, so
      // they group under the crate the attributor resolved them to.
      const key = named ? `${named[1]}-${named[2]}` : `crate:${member.crate}`;
      if (!units.has(key)) units.set(key, { crate: member.crate, members: [] });
      units.get(key).members.push(member);
    }

    for (const unit of units.values()) {
      const name = normalize(unit.crate);
      if (OWN_CRATES_NORMALIZED.has(name)) continue;

      // `evidence` names HOW the member was attributed ("member-name"); the provenance
      // string itself is in `evidenceDetail` ("rustc-sysroot-library-path",
      // "cargo-registry-path"). Both are pooled, because the question is what this
      // compilation unit as a whole proves about where it came from.
      const evidence = unit.members
        .map((m) => `${m.evidence ?? ""} ${m.evidenceDetail ?? ""}`)
        .join(" ");
      // Provenance is decided from the archive and the lockfile, never from the two committed
      // sysroot files — those are what the answer is then measured against. See
      // `scripts/lib/crate-provenance.mjs` for why the inventory cannot be the source.
      const origin = classifyCrateOrigin({ name, evidence, lockedCrates });

      if (origin.origin === "sysroot") {
        if (origin.basis === "elimination" && !SYSROOT_WITHOUT_PATH_EVIDENCE.has(name)) {
          // Reported BEFORE the obligations below, because it is the cause and they are the
          // consequence: neither source explains this crate — the archive proves no path of
          // its own for it and no lockfile package resolves it — so "it is a sysroot crate
          // with no licence" is the conclusion of a classification that is itself in doubt.
          // Absorbing it as an ordinary sysroot crate would swallow a toolchain bump; treating
          // it as Cargo would swallow a crate that has fallen out of the lock. Both are
          // decisions for a human, and the obligations still print so the reader knows what
          // recording it as sysroot would then require.
          problems.push(
            `${identifier}: ${unit.crate} carries no source path of its own and no ` +
              `${basename(cargoLockPath)} package resolves it, so neither the archive nor the ` +
              `lockfile says where it came from — a toolchain bump that vendors a new crate ` +
              `has to be recorded in SYSROOT_WITHOUT_PATH_EVIDENCE deliberately`
          );
        }
        problems.push(...sysrootObligations(identifier, unit.crate, name));
        if (origin.basis === "elimination") {
          // Bounded, for the same reason the first-party skip is. This classification rests on
          // an ABSENCE — no path string, no lockfile entry — so a member renamed to
          // `adler2.<x>.rcgu.o` inherits it and its real crate disappears. Counting members
          // across every unit for this name — not just this one — is what catches it: the
          // disguise lands in its own unit (no metadata hash in the name), so a per-unit count
          // would still see one member each and pass.
          const expected = SYSROOT_EXEMPT_MEMBERS_PER_SLICE.get(name);
          if (expected !== undefined) {
            const actual = [...units.values()]
              .filter((u) => normalize(u.crate) === name)
              .reduce((n, u) => n + u.members.length, 0);
            if (actual !== expected) {
              problems.push(
                `${identifier} attributes ${actual} members to the evidence-free sysroot crate ` +
                  `${unit.crate}, expected ${expected} — a member may be impersonating it`
              );
            }
          }
        }
        continue;
      }

      if (!indexedNames.has(name)) {
        problems.push(
          `${unit.crate} is linked into ${identifier} but is not cited in the notices`
        );
        continue;
      }

      // Where the archive PROVES a version, hold the notices to it. Records whose version is
      // unrecoverable fall back to the name, because `strip = "debuginfo"` leaves roughly
      // half the Cargo crates with no version string at all.
      const proven = unit.members.find(
        (m) => m.versionCertainty === "proven" && m.version
      );
      if (proven) {
        const versions = indexedVersions.get(name);
        if (versions && !versions.has(proven.version)) {
          problems.push(
            `${identifier} ships ${unit.crate} ${proven.version}, but the notices cite it as ` +
              `${[...versions].join(", ")}`
          );
        }
      }
    }

    // ARCHIVE-LEVEL EVIDENCE, which the loop above cannot see.
    //
    // Units are built from members, so a crate with no member of its own is invisible to
    // them — and that is exactly what fat LTO produces when it inlines a dependency wholly
    // into another crate's codegen unit. The reader still recovers such a crate when its
    // source path survives as a string inside the host member, and records it in
    // `analysis.crates`; discarding that would throw away the one piece of evidence that
    // covers the inlining case, and the crate's notice would be freely deletable.
    //
    // No crate is in this position in the current artefacts (all 57 names own at least one
    // member), so this path is unexercised rather than verified. It is here because the
    // condition that triggers it is a property of the optimizer, not of the source.
    // Bound the first-party skip — see OWN_CRATE_MEMBERS_PER_SLICE.
    const ownMembers = [...units.values()]
      .filter((u) => OWN_CRATES_NORMALIZED.has(normalize(u.crate)))
      .reduce((n, u) => n + u.members.length, 0);
    if (ownMembers !== OWN_CRATE_MEMBERS_PER_SLICE) {
      problems.push(
        `${identifier} attributes ${ownMembers} members to the first-party crate, expected ` +
          `${OWN_CRATE_MEMBERS_PER_SLICE} — a member may be impersonating it to skip attribution`
      );
    }
    // No optional chaining on the symbol list. The previous version read
    // `analysis.symbolTable?.symbols`, a field that did not exist, so `?? []` made the
    // count zero and the truthiness guard skipped the branch — the whole check was dead
    // code that read as if it were protecting something. A slice with no symbol table is a
    // failure to report, not a reason to fall silent.
    const symbols = analysis.symbolTable?.symbols;
    if (!Array.isArray(symbols)) {
      problems.push(`${identifier} has no readable symbol table`);
    } else {
      // BOUND TO THE DEFINING MEMBER, not counted archive-wide. A global count survives a
      // swap: rename an uncited member to look first-party AND a real first-party member to
      // look like a cited crate, and the count is unchanged while the skip hides the uncited
      // one. Requiring each `lava_wg_*` symbol to resolve to a member that is actually
      // attributed to our crate breaks that, because the ranlib offsets do not move.
      const ownOffsets = new Set(
        analysis.members
          .filter((m) => m.crate && OWN_CRATES_NORMALIZED.has(normalize(m.crate)))
          .map((m) => m.headerOffset)
      );
      const abi = symbols.filter((sym) =>
        sym.name.startsWith(OWN_CRATE_ABI_SYMBOL_PREFIX)
      );
      if (abi.length !== OWN_CRATE_ABI_SYMBOL_COUNT) {
        problems.push(
          `${identifier} exports ${abi.length} ${OWN_CRATE_ABI_SYMBOL_PREFIX}* symbols, ` +
            `expected ${OWN_CRATE_ABI_SYMBOL_COUNT}`
        );
      }
      const misbound = abi.filter((sym) => !ownOffsets.has(sym.memberOffset));
      if (misbound.length > 0) {
        problems.push(
          `${identifier}: ${misbound.length} ${OWN_CRATE_ABI_SYMBOL_PREFIX}* symbol(s) are ` +
            `defined by members not attributed to the first-party crate ` +
            `(first: ${misbound[0].name}) — the first-party skip may be hiding a member`
        );
      }
    }

    const judged = new Set([...units.values()].map((u) => normalize(u.crate)));
    for (const record of analysis.crates) {
      const name = normalize(record.crate);
      if (judged.has(name) || OWN_CRATES_NORMALIZED.has(name)) continue;

      // Classified by the same rule as a unit, deliberately. Fixing one of these two loops
      // and leaving the other is the pattern that has produced most of this file's history —
      // the member-name traps were each closed in one path and left open in a second — so the
      // decision lives in one function and both callers ask it.
      //
      // The member-count tripwire has no counterpart here: a record in this loop has no member
      // of its own by construction, so there is nothing to count and nothing to impersonate.
      const evidence = `${record.evidence ?? ""}`;
      const origin = classifyCrateOrigin({ name, evidence, lockedCrates });
      if (origin.origin === "sysroot") {
        if (origin.basis === "elimination" && !SYSROOT_WITHOUT_PATH_EVIDENCE.has(name)) {
          problems.push(
            `${identifier}: ${record.crate} is linked in (inlined, no member of its own) with ` +
              `no source path of its own and no ${basename(cargoLockPath)} package resolving ` +
              `it, so neither the archive nor the lockfile says where it came from`
          );
        }
        problems.push(...sysrootObligations(identifier, record.crate, name));
        continue;
      }
      if (!indexedNames.has(name)) {
        problems.push(
          `${record.crate} is linked into ${identifier} (inlined, no member of its own) ` +
            `but is not cited in the notices`
        );
      }
    }
  }
  return [...new Set(problems)];
}

if (process.argv.includes("--verify-committed")) {
  const problems = [];
  const repoText = existsSync(noticesPath) ? readFileSync(noticesPath, "utf8") : null;
  const appText = existsSync(appNoticesPath) ? readFileSync(appNoticesPath, "utf8") : null;
  if (repoText === null) problems.push(`missing ${noticesPath}`);
  if (appText === null) problems.push(`missing ${appNoticesPath}`);
  if (repoText !== null && appText !== null && repoText !== appText) {
    problems.push("the repo and app notice copies differ — regenerate, never hand-edit either");
  }
  if (!existsSync(indexPath)) {
    problems.push(`missing ${indexPath}`);
  } else {
    const committedIndex = JSON.parse(readFileSync(indexPath, "utf8"));
    // TYPE-CHECKED, not `.length`-tested. `unresolved` is the register of crates redistributed
    // with no licence text recovered, and refusing to pass while it is non-empty is one of the
    // few things this mode is FOR. `(x ?? []).length > 0` asks a question a non-array answers
    // `undefined`, and `undefined > 0` is false — so recording the same information as
    // `{count: 2, packages: [...]}` disabled the check while leaving the record in the file,
    // which reads as diligence. `validateSysrootCorpus` fixes exactly this shape for the
    // corpus and names it in its own comment; the index had no schema validation at all, so
    // the identical hole sat one file over from the fix for it.
    if (Object.hasOwn(committedIndex, "unresolved") && !Array.isArray(committedIndex.unresolved)) {
      problems.push(
        `the committed index records \`unresolved\` as ${typeof committedIndex.unresolved}, ` +
          `not an array — the unfinished-attribution check reads \`.length\`, which any other ` +
          `shape answers with undefined, so the register would be carried but never enforced`
      );
    } else if ((committedIndex.unresolved ?? []).length > 0) {
      problems.push(`index records unresolved attribution: ${committedIndex.unresolved.join(", ")}`);
    }
    // BIDIRECTIONAL. Walking the index and checking each entry appears in the notices only
    // proves the index is a subset — delete a crate from BOTH and it still passes, so an
    // existing attribution can disappear silently. That is distinct from the acknowledged
    // gap around crates JOINING the graph, and unlike that one it is fully detectable here.
    // Parse the rendered inventory and require exact set equality.
    const indexed = new Set((committedIndex.crates ?? []).map((c) => `${c.name} ${c.version}`));
    if (indexed.size === 0) problems.push("the committed index is empty");
    if (repoText !== null) {
      const section = repoText.slice(
        repoText.indexOf("PACKAGES ("),
        repoText.indexOf("LICENSE TEXTS (")
      );
      const declared = /PACKAGES \((\d+)\)/.exec(section)?.[1];
      const rendered = new Set(
        section
          .split("\n")
          .map((line) => /^([A-Za-z0-9_.+-]+) ([0-9][^\s]*)$/.exec(line.trim()))
          .filter(Boolean)
          .map((m) => `${m[1]} ${m[2]}`)
      );
      for (const key of indexed) {
        if (!rendered.has(key)) problems.push(`${key} is indexed but absent from the notices`);
      }
      for (const key of rendered) {
        if (!indexed.has(key)) problems.push(`${key} is in the notices but absent from the index`);
      }
      if (declared !== undefined && Number(declared) !== rendered.size) {
        problems.push(`the notices declare ${declared} packages but render ${rendered.size}`);
      }
    }

    // WHAT MAKES THE ARCHIVE INDEPENDENT — and what does not.
    //
    // Member NAMES are the archive's soft spot. BSD ar stores a long name NUL-padded in the
    // member body, so renaming a codegen unit preserves every header, size field and
    // __.SYMDEF offset. Two such renames have already been demonstrated against this reader
    // (`lib.rmeta` and `__.SYMDEF`), and both are now rejected because the payload
    // contradicts the claimed name.
    //
    // One shape CANNOT be closed here: renaming a member to another ORDINARY crate-shaped
    // name — in particular to our own first-party crate, which this reconciliation skips.
    // The payload is a genuine object, the name is well-formed, and nothing inside a Mach-O
    // CGU binds it to the crate that produced it. No amount of reading the archive
    // distinguishes it from the real thing.
    //
    // What does: `scripts/check-wireguard-core-drift.sh` rebuilds the xcframework from
    // source with the pinned toolchain and BYTE-COMPARES. Any rename changes the archive
    // bytes, so it fails there — and light-build.yml scopes that job to the whole of
    // `ThirdParty/wireguard-core`, which is precisely where a member rename has to be
    // committed. So member-name integrity is anchored by the reproducible build, not by
    // this reader, and this reader should not be read as if it were the last line.
    //
    // THE INDEPENDENT SOURCE.
    //
    // Everything above compares generated artefacts to each other. They are all emitted by
    // one `cargo` run, so editing them consistently passes every one of those checks — a
    // package can be deleted from the index, from both notice copies and from the rendered
    // count, and nothing here notices. That is not hypothetical; it was reproduced on this
    // PR by removing `subtle 2.6.1` and changing the header from 49 to 48.
    //
    // So the expected inventory has to come from something the generator did not write. The
    // committed static libraries are that something: they are the artefact the licence
    // obligation actually attaches to, and their crate list is recoverable without cargo.
    //
    // DIRECTION IS LOAD-BEARING, and it is not the accidental one-directional check that has
    // bitten this file before. The archive is a LOWER bound — under fat LTO a crate can be
    // inlined wholly into another crate's codegen unit, leaving no member of its own — while
    // the cargo-derived index is an UPPER bound, since it deliberately over-includes
    // proc-macro crates whose code never ships. So `archive ⊆ index` is the only sound
    // relation. Asserting the reverse would fail on every crate that legitimately has no
    // member, which is why this loop runs one way ON PURPOSE.
    // THE NOTICE CONTENT ITSELF.
    //
    // Everything above validates the package HEADINGS. The license bodies and copyright
    // lines - which are the actual obligation - went unchecked, so editing a copyright
    // string or emptying a license block identically in both copies passed: the two files
    // still matched each other and the parsed package set was unchanged.
    if (repoText !== null) {
      const committedSections = committedIndex.sections;
      if (committedSections === undefined) {
        problems.push("the committed index carries no section digests — regenerate it");
      } else {
        const actual = {
          packages: sha256(sectionOf(repoText, "PACKAGES (", "LICENSE TEXTS (") ?? ""),
          licenseTexts: sha256(sectionOf(repoText, "LICENSE TEXTS (", null) ?? ""),
        };
        for (const key of ["packages", "licenseTexts"]) {
          if (committedSections[key] !== actual[key]) {
            problems.push(
              `the ${key} section of the notices does not match the digest in the index — ` +
                `it was edited by hand, or the index is stale`
            );
          }
        }
      }

      // Per-body digests too, so the failure names the license that changed rather than
      // only the section containing it.
      const committedBodies = committedIndex.bodies ?? [];
      if (committedBodies.length === 0) {
        problems.push("the committed index carries no license body digests — regenerate it");
      }
      const textsSection = sectionOf(repoText, "LICENSE TEXTS (", null) ?? "";
      const renderedBodies = new Map();
      for (const match of textsSection.matchAll(/^\[(L\d+)\]\n\n([\s\S]*?)\n\n={78}$/gm)) {
        renderedBodies.set(match[1], match[2]);
      }
      for (const body of committedBodies) {
        const text = renderedBodies.get(body.id);
        if (text === undefined) {
          problems.push(`license body ${body.id} is in the index but absent from the notices`);
        } else if (sha256(text) !== body.sha256) {
          problems.push(`license body ${body.id} does not match its digest — the text was altered`);
        }
      }
      for (const id of renderedBodies.keys()) {
        if (!committedBodies.some((b) => b.id === id)) {
          problems.push(`license body ${id} is in the notices but absent from the index`);
        }
      }
    }

    // THE ATTRIBUTION ITSELF — that a cited crate actually carries licence text.
    //
    // Everything above checks that the right NAMES are present. Nothing tied a name to a
    // licence body or a copyright line, so a package could be reduced to a bare heading and
    // still pass. An adversarial pass took the notices from 174,498 bytes to 13,051 — every
    // copyright holder line and 50 of 51 licence bodies deleted — and the gate reported them
    // self-consistent. That is not the digest limitation: the digests were honestly
    // recomputed and correct. The gate simply had no expectation for this content, which is
    // the entire obligation the file exists to discharge.
    if (repoText !== null) {
      const packagesSection = sectionOf(repoText, "PACKAGES (", "LICENSE TEXTS (") ?? "";
      const bodyIDs = new Set(
        [...(sectionOf(repoText, "LICENSE TEXTS (", null) ?? "").matchAll(/^\[(L\d+)\]$/gm)]
          .map((m) => m[1])
      );
      // Split the section into per-package stanzas: a heading line, then its indented detail.
      const stanzas = packagesSection.split("\n\n").filter((s) => /^[A-Za-z0-9_.+-]+ [0-9]/.test(s.trim()));
      const seen = new Set();
      for (const stanza of stanzas) {
        const lines = stanza.trim().split("\n");
        const heading = lines[0].trim();
        seen.add(heading);
        const detail = lines.slice(1);

        // Either the crate names licence bodies that exist, or it says outright that the
        // crate published none. Both are legitimate; silence is not.
        const textLine = detail.find((l) => l.trim().startsWith("Text:"));
        if (textLine === undefined) {
          problems.push(`${heading} cites no license text at all`);
        } else if (!textLine.includes("NONE PROVIDED BY THE CRATE")) {
          const referenced = [...textLine.matchAll(/\b(L\d+)\b/g)].map((m) => m[1]);
          if (referenced.length === 0) {
            problems.push(`${heading} has a Text: line naming no license body`);
          }
          for (const id of referenced) {
            if (!bodyIDs.has(id)) {
              problems.push(`${heading} cites license body ${id}, which is not in the notices`);
            }
          }
        }

        // A copyright line, or the generator's explicit statement that upstream named
        // nobody. BSD-3 clause 2 and the MIT notice both require the holder to travel with
        // the binary, so a stanza that quietly has neither is an unmet obligation.
        const hasHolder = detail.some((l) => /^\s*Copyright\b/i.test(l));
        const statesNone = detail.some((l) => l.includes("no copyright holder stated"));
        if (!hasHolder && !statesNone) {
          problems.push(`${heading} names no copyright holder and does not say why`);
        }
      }
      // Every indexed crate must actually have a stanza — the heading check above only sees
      // what is present.
      for (const key of indexed) {
        if (!seen.has(key)) problems.push(`${key} has no package entry in the notices`);
      }
    }

    const archiveProblems = reconcileAgainstArchives(indexed);
    problems.push(...archiveProblems);

    // The corpus reconciliation has to run HERE too, not only inside `sysrootPackageEntries`.
    // That function is reached from `build()`, which this mode exits before — so a check
    // living only there was inherited by the cargo-backed gate and skipped by the cargo-free
    // one. The cargo-free one is the PUBLIC gate, running where the redistribution that
    // creates the obligation actually happens, so a corpus deletion would have been caught
    // internally and waved through publicly. That is the wrong way round.
    if (existsSync(sysrootPackagesPath)) {
      try {
        const corpusRaw = readFileSync(sysrootPackagesPath, "utf8");
        const corpus = JSON.parse(corpusRaw);
        // The pinned channel is read from `rust-toolchain.toml`, a COMMITTED file, so the
        // toolchain invariant is checkable without cargo — the reason it lived in the
        // cargo-backed path was inattention, not necessity. Passing it here is what makes the
        // corpus-from-another-compiler case fail in the gate that governs redistribution.
        problems.push(
          ...reconcileSysrootCorpus(corpus, { channel: pinnedChannel(), raw: corpusRaw }));
        // And that what the corpus RECORDS is what the notices SHIP, in the stanza that
        // records it.
        //
        // Everything above compares the notices to the index — both written by the same
        // generator run. The corpus is an INPUT to that run and was never compared to the
        // output, so a corpus that gained an obligation which was then not regenerated left
        // this gate green while the shipped file omitted the attribution.
        //
        // The first version of this check searched the whole PACKAGES and LICENSE TEXTS
        // sections, which proves only that the text exists SOMEWHERE. Since these bodies are
        // deduplicated across up to eight packages, an obligation added to one package was
        // satisfied by another package's identical Apache-2.0 body, and a copyright line
        // added to `compiler_builtins` was satisfied by `adler2` carrying it. Both were
        // reproduced against this gate and both passed. Attribution is per-package, so the
        // check has to be too.
        if (repoText !== null) {
          const packagesSection = sectionOf(repoText, "PACKAGES (", "LICENSE TEXTS (") ?? "";
          const textsSection = sectionOf(repoText, "LICENSE TEXTS (", null) ?? "";
          // `[Lnn]` label -> rendered body. Labels are assigned at render time and renumber
          // whenever the set changes, so the corpus is matched on TEXT and the stanza on
          // label — each on the identifier that is stable for it.
          const renderedBodies = new Map();
          for (const match of textsSection.matchAll(/^\[(L\d+)\]\n\n([\s\S]*?)\n\n={78}$/gm)) {
            renderedBodies.set(match[1], match[2]);
          }
          // Keyed on the NORMALIZED name, because the same package legitimately appears under
          // two spellings: the corpus records the crate identifier (`cfg_if`) while the notices
          // render the package name (`cfg-if`), and where a crate is reachable from both the
          // sysroot and Cargo at one version the two collapse into a single stanza under the
          // Cargo spelling. Matching raw names reported `cfg_if 1.0.4` as unrendered when it
          // is rendered — the same normalization every other comparison in this file uses.
          const stanzaByKey = new Map();
          for (const stanza of packagesSection.split("\n\n")) {
            const heading = stanza.trim().split("\n")[0]?.trim() ?? "";
            const parsed = /^([A-Za-z0-9_.+-]+) ([0-9][^\s]*)$/.exec(heading);
            if (!parsed) continue;
            const key = `${normalizeCrateName(parsed[1])} ${parsed[2]}`;
            // LAST WINS was silent, and silence is the whole attack. Two chunks sharing one
            // heading meant only the last was ever compared against the corpus — SPDX, holders
            // and cited bodies all keyed off this map — while a reader looking the package up
            // at its alphabetical position found the FIRST. The rendered-package count is a
            // Set, so it did not notice either. A duplicate heading has no legitimate cause in
            // generated output.
            if (stanzaByKey.has(key)) {
              problems.push(
                `the notices carry more than one stanza headed "${parsed[1]} ${parsed[2]}" — ` +
                  `only one of them is compared against ${basename(sysrootPackagesPath)}, so ` +
                  `the other can state any licence, holder or citation it likes`
              );
            }
            stanzaByKey.set(key, stanza);
          }

          for (const pkg of corpus.packages ?? []) {
            const heading = `${pkg.name} ${pkg.version}`;
            const stanza = stanzaByKey.get(`${normalizeCrateName(pkg.name)} ${pkg.version}`);
            if (stanza === undefined) {
              problems.push(
                `${heading} is licensed in ${basename(sysrootPackagesPath)} but has no stanza ` +
                  `in the notices — regenerate`
              );
              continue;
            }
            const citedLabels = [
              ...(stanza.split("\n").find((l) => l.trim().startsWith("Text:")) ?? "")
                .matchAll(/\b(L\d+)\b/g),
            ].map((m) => m[1]);
            for (const id of pkg.licenseTexts ?? []) {
              const body = corpus.licenseTexts?.[id]?.text;
              if (body === undefined) {
                // NOT skipped, and the comment that used to sit here was wrong: it said
                // `reconcileSysrootCorpus` reports this, and it does not — that function
                // checks the definition EXISTS, not that it carries a body. So deleting just
                // the `text` field left the definition "valid", skipped this comparison, and
                // the public gate called the notices self-consistent.
                problems.push(
                  `${heading} cites licence text ${id}, whose definition in ` +
                    `${basename(sysrootPackagesPath)} has no \`text\` — there is nothing to ` +
                    `compare against the notices, so its reproduction cannot be verified`
                );
                continue;
              }
              // Exact body match, not `includes`. Several of these texts EMBED others —
              // compiler-builtins' LICENSE.txt carries the whole Apache-2.0 text inside it —
              // so a substring test let a different package's Apache body count as cited here.
              // That was reproduced against this gate: adding miniz_oxide's Apache text to
              // `compiler_builtins` passed, because it appears verbatim inside a text the
              // package legitimately cites.
              const citedHere = citedLabels.some(
                (label) => (renderedBodies.get(label) ?? "").trim() === body.trim()
              );
              if (!citedHere) {
                problems.push(
                  `${heading} cites licence text ${id} in ` +
                    `${basename(sysrootPackagesPath)}, but its stanza in the notices does not ` +
                    `reference that text — regenerate`
                );
              }
            }
            // BOTH directions here too. The loop above only asks whether each text the corpus
            // cites is reproduced in the stanza; it says nothing about a body the stanza
            // reproduces that the corpus no longer cites. Removing a package's citation, its
            // role entry and the now-unused definition together left the corpus internally
            // consistent and every remaining citation satisfied, so the gate passed while the
            // committed notices still carried the orphaned body — which the next regeneration
            // would then silently drop. Same asymmetry as the copyright comparison below, in
            // the check one line up from it.
            //
            // Matched on rendered TEXT rather than label, because labels renumber whenever the
            // text set changes; verified against the committed notices, where every package's
            // cited-label count equals its corpus text count, so symmetry costs no false
            // failures.
            const corpusBodies = (pkg.licenseTexts ?? [])
              .map((id) => corpus.licenseTexts?.[id]?.text)
              .filter((text) => typeof text === "string")
              .map((text) => text.trim());
            for (const label of citedLabels) {
              const rendered = (renderedBodies.get(label) ?? "").trim();
              // An empty or unparseable body is REPORTED, not skipped. The `continue` that
              // stood here assumed "a different check reports this", and that assumption was
              // wrong in the way assumptions about other checks usually are: `renderedBodies`
              // only admits well-formed `[Lnn]`-delimited blocks, so a body emptied or
              // corrupted in the notices simply never enters the map, and skipping absent
              // entries here meant the citation stayed valid while the licence text it cites
              // had stopped being reproduced at all. Absence of the text is the most complete
              // form of the failure this loop exists to catch, so it cannot be the one case
              // that passes quietly.
              if (rendered.length === 0) {
                problems.push(
                  `${heading} cites ${label}, but the notices carry no readable body for that ` +
                    `label — the licence text it points at is empty or malformed, so the ` +
                    `stanza claims a reproduction that does not ship`
                );
                continue;
              }
              if (!corpusBodies.includes(rendered)) {
                problems.push(
                  `${heading} reproduces licence text ${label} in its stanza, but ` +
                    `${basename(sysrootPackagesPath)} does not cite any text with that body — ` +
                    `the corpus is what the next regeneration renders, so this licence would ` +
                    `silently stop being reproduced`
                );
              }
            }
            // The declared expression, compared with the one that SHIPS. The corpus-to-notices
            // reconciliation checked cited bodies and copyright lines and never this — so
            // changing a package's `spdx` without regenerating left the stanza claiming the
            // old licence while the gate reported the pair self-consistent. It is the single
            // most legally load-bearing line in each stanza: it is the claim about what terms
            // the user receives the code under.
            const declared = (stanza.split("\n").find((l) => l.trim().startsWith("License:")) ?? "")
              .replace(/^\s*License:\s*/, "")
              .trim();
            if (declared !== String(pkg.spdx ?? "").trim()) {
              problems.push(
                `${heading} declares "${pkg.spdx}" in ${basename(sysrootPackagesPath)}, but its ` +
                  `stanza in the notices ships "${declared}" — the licence users are told they ` +
                  `receive the code under is not the one the corpus records`
              );
            }
            // Complete LINES, not substring containment. A holder that is a PREFIX of the
            // rendered one satisfied `includes` — changing gimli's holder from
            // "…The Rust Project Developers" to "…The Rust Project" left the stale notices
            // passing, so a corpus attribution change could reach redistribution without ever
            // appearing in what ships.
            const stanzaLines = new Set(stanza.split("\n").map((l) => l.trim()));
            const corpusHolders = new Set((pkg.copyright ?? []).map((l) => String(l).trim()));
            for (const line of corpusHolders) {
              if (!stanzaLines.has(line)) {
                problems.push(
                  `${heading} records the copyright "${line}" in ` +
                    `${basename(sysrootPackagesPath)}, but its own stanza does not carry it — ` +
                    `regenerate`
                );
              }
            }
            // BOTH directions. Corpus-to-stanza alone only catches attributions being ADDED
            // without regenerating; a holder REMOVED from a multi-holder corpus entry left every
            // remaining line present, so the loop found nothing missing and the gate passed
            // while the stanza still carried the deleted line. Deleting the Arm Limited holder
            // from `compiler_builtins` was accepted on exactly that asymmetry — and the
            // direction it misses is the one that ends in attribution DISAPPEARING at the next
            // regeneration, which is the failure this whole gate exists to prevent.
            //
            // Selected STRUCTURALLY — everything that is not a known field — rather than by a
            // `Copyright` prefix.
            //
            // Two prefix attempts were both wrong, in the same direction. `startsWith`
            // ("Copyright") missed the lowercase form; `/^copyright\b/i` still missed a holder
            // written with a bare `©` or `(c)` and no `Copyright` word — which `namedHolderIn`
            // ACCEPTS into the corpus, because it only strips a leading `copyright` if one
            // happens to be there and never requires it. A comment here previously claimed the
            // case-insensitive filter "matched `namedHolderIn`"; it did not, and the claim was
            // the reason the gap looked closed.
            //
            // Any prefix rule has that shape of failure: it enumerates what an attribution
            // looks like, and an attribution the corpus accepts but the rule does not recognise
            // is invisible to the deletion check. Enumerating the FIELDS instead is closed —
            // the renderer emits exactly `License:`, `Repository:` and `Text:` for these
            // stanzas (measured across all 67 rendered packages) — so anything else on a line
            // is an attribution and must still be recorded in the corpus. A new field would be
            // reported rather than skipped, which is the direction that asks a human.
            //
            // Licence BODIES live in the LICENSE TEXTS section, not in a stanza, so no body's
            // own copyright line is caught here. Verified against the committed notices: for
            // all 19 packages the two sets are already equal, so symmetry costs no false
            // failures.
            const stanzaHeading = stanza.trim().split("\n")[0]?.trim() ?? "";
            for (const line of stanzaLines) {
              if (line.length === 0 || line === stanzaHeading) continue;
              if (/^(?:License|Repository|Text):/.test(line)) continue;
              if (/^-{3,}$/.test(line)) continue;
              if (corpusHolders.has(line)) continue;
              problems.push(
                `${heading} ships the attribution line "${line}" in its stanza, but ` +
                  `${basename(sysrootPackagesPath)} does not record it — the corpus is what the ` +
                  `next regeneration renders, so this line would silently vanish`
              );
            }
          }
        }
      } catch (error) {
        problems.push(`${basename(sysrootPackagesPath)} is unreadable: ${error.message}`);
      }
    } else {
      problems.push(`missing ${sysrootPackagesPath}`);
    }
  }
  if (problems.length > 0) {
    console.error("generate-wireguard-core-notices --verify-committed: failed");
    for (const p of problems) console.error(`  - ${p}`);
    process.exit(1);
  }
  console.log("generate-wireguard-core-notices: committed notices are self-consistent");
  process.exit(0);
}

const model = build();
const rendered = render(model);
// Digests over the RENDERED text, so --verify-committed can check the notice CONTENT and
// not merely its table of contents. Without these, editing a copyright line or gutting a
// license body identically in both copies passed every check: the two files still matched
// each other, and the package headings the regex parses were untouched. The license text is
// the entire obligation, so it is the last thing that should have gone unverified.
//
// WHAT THESE DO AND DO NOT PROVE. An earlier version of this comment claimed recomputing
// them required cargo and the pinned toolchain. That was wrong, and Codex demonstrated it:
// they are plain SHA-256 over the rendered text, so anyone editing the notices can
// recompute them with any hashing tool and commit both halves together.
//
// So they are a DRIFT check, not an authenticity one. They catch the notices and the index
// falling out of step — a hand-edit, a partial regeneration, a bad merge — which is the
// realistic failure. They do not stop a contributor who edits every file in one change,
// and no comparison between committed artefacts can, because on the public mirror all of
// them are equally editable.
//
// The authority is `--check`, which regenerates from `cargo tree` and the crates' own
// published licence files and byte-compares. Its expectation comes from OUTSIDE the repo,
// so nothing committed here can forge it: a coordinated edit passes this mode and fails
// that one.
//
// That is only worth anything if `--check` is unavoidable on the way to the public mirror,
// which is where the binary redistribution creating the obligation happens. It runs in two
// places, and the distinction matters:
//
//   - `.github/workflows/light-build.yml` — path-filtered. A PR that edits the notices
//     without touching the engine SKIPS it. Useful, not a gate.
//   - `.github/workflows/internal-promotion.yml` — not path-filtered: every non-draft PR
//     and every push to main (drafts skip until `ready_for_review`, PR #784), and
//     internal-only so it cannot be edited from the public side. This is the gate:
//     nothing reaches the mirror without a cargo-backed regeneration.
//
// So this mode's job is narrower than it looks: keep the public repo from drifting silently
// between those runs, and make any deliberate edit large and obvious rather than invisible.
const index = {
  targets: TARGETS,
  generator: "scripts/generate-wireguard-core-notices.mjs",
  crates: model.crates.map((c) => ({ name: c.name, version: c.version, license: c.license })),
  bodies: model.bodies.map((b) => ({ id: b.id, sha256: sha256(b.text) })),
  sections: {
    packages: sha256(sectionOf(rendered, "PACKAGES (", "LICENSE TEXTS (") ?? ""),
    licenseTexts: sha256(sectionOf(rendered, "LICENSE TEXTS (", null) ?? ""),
  },
  unresolved: model.missing,
};
const indexJSON = JSON.stringify(index, null, 2) + "\n";

const checkOnly = process.argv.includes("--check");

if (checkOnly) {
  const staleness = [];
  for (const [path, expected] of [
    [noticesPath, rendered],
    [appNoticesPath, rendered],
    [indexPath, indexJSON],
  ]) {
    const actual = existsSync(path) ? readFileSync(path, "utf8") : null;
    if (actual !== expected) staleness.push(path.replace(`${repoRoot}/`, ""));
  }
  if (staleness.length > 0) {
    console.error("generate-wireguard-core-notices: committed notices are stale:");
    for (const path of staleness) console.error(`  - ${path}`);
    console.error("Regenerate with: node scripts/generate-wireguard-core-notices.mjs");
    process.exit(1);
  }
  if (model.missing.length > 0) {
    console.error("generate-wireguard-core-notices: unresolved attribution:");
    for (const item of model.missing) console.error(`  - ${item}`);
    process.exit(1);
  }
  console.log(
    `generate-wireguard-core-notices: up to date (${model.crates.length} crates, ${model.bodies.length} license texts)`
  );
} else {
  writeFileSync(noticesPath, rendered);
  writeFileSync(appNoticesPath, rendered);
  writeFileSync(indexPath, indexJSON);
  console.log(
    `generate-wireguard-core-notices: wrote ${model.crates.length} crates, ${model.bodies.length} unique license texts`
  );
  if (model.missing.length > 0) {
    console.log("unresolved:");
    for (const item of model.missing) console.log(`  - ${item}`);
  }
}
