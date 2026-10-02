import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import {
  classifyCrateOrigin,
  lockedCrateNames,
  normalizeCrateName,
  parseCargoLockPackages,
} from "../lib/crate-provenance.mjs";

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..", "..");
const cargoLockPath = join(repoRoot, "ThirdParty", "wireguard-core", "Cargo.lock");

test("reads every [[package]] stanza in the committed lockfile", () => {
  const packages = parseCargoLockPackages(readFileSync(cargoLockPath, "utf8"));
  assert.ok(packages.length > 50, `expected the real lockfile, got ${packages.length} packages`);
  const byName = new Map(packages.map((p) => [p.name, p.version]));
  // These pin the PARSER, not the classifier. `classifyCrateOrigin` never sees a version at all:
  // `lockedCrateNames` keeps only `pkg.name`, and the classifier asks nothing of the set but
  // membership. So a bump here moves these assertions and changes no classification — what they
  // catch is `parseCargoLockPackages` misreading the `version` field of a real stanza.
  //
  // The two crates are these two because they are the ones linked TWICE — once by Cargo, once
  // from the sysroot — which is why provenance is a per-COPY question, and they fail differently:
  //   libc   — the copies DIFFER (0.2.189 here, 0.2.178 in the sysroot corpus), which is why the
  //            corpus is keyed on (name, version); a name-only reconciliation would call a single
  //            entry sufficient for both.
  //   cfg-if — the copies AGREE at 1.0.4, so no version comparison can separate them and only
  //            per-unit path evidence can. Matching versions are not evidence of a single copy.
  // The sysroot side of each is `sysroot-packages.json`'s to state; nothing in this file reads it.
  assert.equal(byName.get("libc"), "0.2.189");
  assert.equal(byName.get("cfg-if"), "1.0.4");
  // A path dependency has no `source` key but is still a Cargo package; missing it would file
  // the vendored engine itself as a sysroot crate.
  assert.equal(byName.get("boringtun"), "0.7.1");
  // And the crate the whole archive-anchored check exists for is NOT here: adler2 reaches the
  // shipped binary through the precompiled rust-std, never through Cargo.
  assert.equal(byName.has("adler2"), false);
});

test("a table header ends the stanza before it, so no later key leaks into a package", () => {
  const packages = parseCargoLockPackages(`
version = 4

[[package]]
name = "boringtun"
version = "0.7.1"
dependencies = [
 "aead",
 "libc",
]

[[package]]
name = "libc"
version = "0.2.189"
source = "registry+https://github.com/rust-lang/crates.io-index"

[metadata]
name = "not-a-package"
version = "9.9.9"
`);
  assert.deepEqual(packages, [
    { name: "boringtun", version: "0.7.1" },
    { name: "libc", version: "0.2.189" },
  ]);
});

test("a stanza with no name is not a package", () => {
  // Defensive: `name` is what every lookup keys on, so a nameless stanza must not become an
  // entry whose normalized name is the empty string — that would exempt any crate the archive
  // reports under a damaged name from the sysroot corpus requirement.
  const packages = parseCargoLockPackages(`[[package]]\nversion = "1.0.0"\n`);
  assert.deepEqual(packages, []);
});

test("lockfile names are normalized to the identifier spelling the archive yields", () => {
  const names = lockedCrateNames(`
[[package]]
name = "pin-project-lite"
version = "0.2.17"
`);
  assert.ok(names.has("pin_project_lite"));
  assert.equal(names.has("pin-project-lite"), false);
  assert.equal(normalizeCrateName("Curve25519-Dalek"), "curve25519_dalek");
});

const LOCKED = new Set(["libc", "cfg_if", "subtle", "boringtun"]);
const classify = (name, evidence) =>
  classifyCrateOrigin({ name, evidence, lockedCrates: LOCKED });

test("a sysroot path string settles provenance even for a crate Cargo also resolved", () => {
  // libc is in the lockfile AND in the sysroot. The copy carrying the vendor path is the
  // sysroot's, and a lockfile entry must not be able to talk it out of its corpus obligation.
  assert.deepEqual(classify("libc", "member-name rust-sysroot-vendor-path"), {
    origin: "sysroot",
    basis: "path-evidence",
  });
  assert.deepEqual(classify("core", "member-name rustc-sysroot-library-path"), {
    origin: "sysroot",
    basis: "path-evidence",
  });
});

test("the sysroot claim wins when a unit pools both provenance strings", () => {
  // compiler_builtins' C and assembly objects inherit a hash-group attribution, so one unit
  // can carry more than one detail string. "The sysroot shipped a copy of this" is the claim
  // that creates the obligation, so it has to be the one that survives pooling.
  assert.equal(
    classify("compiler_builtins", "member-path-string rustc-sysroot-library-path shares prefix")
      .origin,
    "sysroot",
  );
  assert.equal(
    classify("hashbrown", "cargo-registry-path rust-sysroot-vendor-path").origin,
    "sysroot",
  );
});

test("a registry path settles the Cargo side without consulting the lockfile", () => {
  // `once_cell` is deliberately absent from LOCKED here: the archive proved it, and a check
  // that also demanded a lockfile entry would fail on a correct tree the moment the two
  // sources disagreed about spelling.
  assert.deepEqual(classify("once_cell", "member-name cargo-registry-path"), {
    origin: "cargo",
    basis: "path-evidence",
  });
});

test("a crate whose path string did not survive is Cargo's if the lockfile resolves it", () => {
  // Roughly half the Cargo crates are in this state: `strip = "debuginfo"` leaves them a
  // member but no path of their own. Classifying those by elimination would report the whole
  // Cargo graph as unlicensed sysroot crates.
  assert.deepEqual(classify("subtle", "member-name "), {
    origin: "cargo",
    basis: "lockfile",
  });
  assert.deepEqual(classify("boringtun", "member-name "), {
    origin: "cargo",
    basis: "lockfile",
  });
});

test("a crate with neither a path string nor a lockfile entry is the sysroot's", () => {
  // This is the case the archive-anchored corpus check exists for. adler2 is statically linked
  // into all three shipped slices, proves nothing about itself, and Cargo never resolved it —
  // so the partition leaves only the sysroot, and the answer does not come from either
  // committed sysroot file.
  assert.deepEqual(classify("adler2", "member-name "), {
    origin: "sysroot",
    basis: "elimination",
  });
  assert.deepEqual(classify("adler2", ""), { origin: "sysroot", basis: "elimination" });
  assert.deepEqual(classify("adler2", null), { origin: "sysroot", basis: "elimination" });
});
