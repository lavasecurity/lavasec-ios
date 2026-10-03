/**
 * crate-provenance.mjs — deciding where a crate linked into the engine came from.
 *
 * The notices gate asks one question of every crate it finds in a committed archive slice:
 * was this resolved by Cargo, or did it come from the precompiled rust-std the toolchain
 * ships? The two are attributed from different places — the Cargo ones from `cargo metadata`
 * via the generated notices index, the sysroot ones from the committed licence corpus
 * `sysroot-packages.json` — so a crate filed on the wrong side is a crate whose licence
 * obligation is looked for in a file that was never going to carry it.
 *
 *
 * WHY THIS DOES NOT ASK THE COMMITTED INVENTORY
 * ---------------------------------------------
 * `sysroot-crates.json` names the sysroot crates and would answer the question directly. It
 * is also committed alongside the corpus, and that is exactly the problem: with the answer
 * taken from one committed file and the obligation recorded in another, deleting a crate from
 * BOTH in a single commit removes the crate from the question and from the answer at once.
 * Reproduced with `adler2 2.0.1` — statically linked into all three shipped slices, one
 * archive member per slice — where the gate exited 0 and the next regeneration would have
 * dropped its entire attribution (`0BSD OR MIT OR Apache-2.0`, its copyright holder and its
 * three licence bodies) from the redistributed notices.
 *
 * So provenance is decided from two sources the notices generator does not write:
 *
 *   1. THE ARCHIVE. `analyzeStaticLibrary` recovers, per member, the source path strings that
 *      survived into its bytes. `/rust/deps/<pkg>-<version>` and
 *      `/rustc/<commit>/library/<dir>` say "the sysroot shipped this"; `registry/src/...`
 *      says "Cargo resolved this". 18 of the 19 sysroot crates carry one of the first two in
 *      every slice, so for them the binary itself settles it.
 *
 *   2. `Cargo.lock`. Under `strip = "debuginfo"` a crate keeps a member but loses its path
 *      string unless some panic or `#[track_caller]` site of its own survived codegen, so
 *      roughly half the Cargo crates prove nothing about themselves — and `adler2` proves
 *      nothing at all. The lockfile is the closed, exhaustive statement of what Cargo
 *      resolved, and it is written by `cargo` during dependency resolution and reviewed as a
 *      diff, not emitted by this repo's notices generator.
 *
 * Those two make the partition closed. A slice is our own crate, plus the crates Cargo
 * resolved, plus the sysroot; nothing else is linked in. So a crate that is in the archive,
 * is not first-party, carries no Cargo registry path and appears nowhere in `Cargo.lock` can
 * only have come from the sysroot. That is how `adler2` is classified here, with no committed
 * inventory consulted.
 *
 *
 * WHAT THIS IS NOT
 * ----------------
 * It is not unforgeable, and the gate that uses it should not be described as if it were.
 * Adding a fabricated `[[package]]` stanza to `Cargo.lock` moves a sysroot crate to the Cargo
 * side of the partition and out of the corpus requirement. What that costs an editor is a
 * visible, reviewable change to a lockfile — the same standard the generator's
 * `SYSROOT_WITHOUT_PATH_EVIDENCE` constant is held to, and the same one
 * `scripts/check-wireguard-core-drift.sh` backstops by rebuilding the artifact and
 * byte-comparing. What it replaces is a silent one.
 *
 * The direction also matters. Classifying as `sysroot` ADDS an obligation (a corpus package
 * must exist); classifying as `cargo` defers to the existing indexed-name check, which is
 * itself an obligation. Neither branch discharges anything, so a misclassification produces a
 * check pointed at the wrong file rather than a crate that goes unchecked.
 *
 * One case the elimination branch genuinely cannot see: a crate linked from BOTH worlds —
 * `libc` and `cfg-if` are today — whose sysroot copy lost its path string in every slice.
 * The lockfile resolves the name, so the sysroot copy is filed as Cargo's and its corpus
 * obligation is not asserted. What covers that today is the corpus's own `vendoredCrates`
 * declaration, which names the crates every slice MUST carry `rust-sysroot-vendor-path`
 * records for and fails per (slice, crate) when one does not — an expectation deliberately
 * kept independent of the evidence it tests. So the two checks cover each other: this one
 * needs no declaration and misses the dual-linked case, that one is declared and catches it.
 */

/**
 * Crate names as the compiler spells them.
 *
 * Cargo says `cfg-if`, the archive member says `cfg_if`, and both refer to one crate. Every
 * comparison between the two worlds has to normalize or it produces false findings — an
 * earlier reconciliation reported 29 uncited crates, 12 of them purely this. `Cargo.lock`
 * spells package names the Cargo way, so the lockfile side needs it too.
 *
 * @param {string} name
 * @returns {string}
 */
export function normalizeCrateName(name) {
  return String(name).replace(/-/g, "_").toLowerCase();
}

/**
 * Every `[[package]]` stanza in a `Cargo.lock`.
 *
 * Deliberately a line-oriented reader rather than a split on `[[package]]`: the lockfile is
 * TOML, a `dependencies = [...]` array runs over many lines, and any table header ends the
 * stanza it follows. Reading line by line means a `[metadata]` or `[[patch.crates-io]]`
 * section cannot leak a `name` into the package before it, which a naive split would let it
 * do — and this list decides which crates are exempt from the sysroot corpus requirement, so
 * an over-broad read is the direction that loses a licence.
 *
 * @param {string} text  Contents of `Cargo.lock`.
 * @returns {{name: string, version: string|null}[]} in file order
 */
export function parseCargoLockPackages(text) {
  const packages = [];
  let current = null;
  const flush = () => {
    if (current && current.name) packages.push(current);
    current = null;
  };
  for (const rawLine of String(text).split("\n")) {
    const line = rawLine.trim();
    if (line.startsWith("[")) {
      flush();
      if (line === "[[package]]") current = { name: null, version: null };
      continue;
    }
    if (!current) continue;
    const name = /^name\s*=\s*"([^"]*)"$/.exec(line);
    if (name) {
      current.name = name[1];
      continue;
    }
    const version = /^version\s*=\s*"([^"]*)"$/.exec(line);
    if (version) current.version = version[1];
  }
  flush();
  return packages;
}

/** The lockfile's package names, in the identifier spelling the archive yields. */
export function lockedCrateNames(text) {
  return new Set(parseCargoLockPackages(text).map((pkg) => normalizeCrateName(pkg.name)));
}

/**
 * Where a crate found in a committed archive slice came from.
 *
 * `evidence` is the pooled `evidence`/`evidenceDetail` text of a compilation unit's members
 * (or a `CrateRecord`'s evidence tags), matched with the same substring rules the notices gate
 * already uses on it: `evidenceDetail` carries the provenance string itself —
 * `rust-sysroot-vendor-path`, `rustc-sysroot-library-path`, `cargo-registry-path` — while
 * `evidence` carries only HOW the member was attributed.
 *
 * `basis` says WHICH of the two sources decided it, because the caller treats them
 * differently: `elimination` is the branch resting on the lockfile being exhaustive rather
 * than on anything in the binary, so a crate that lands there is required to be one the
 * generator names deliberately.
 *
 * @param {object} args
 * @param {string} args.name  Normalized crate identifier.
 * @param {string} args.evidence  Pooled evidence text; may be empty.
 * @param {Set<string>} args.lockedCrates  Normalized names of every `Cargo.lock` package.
 * @returns {{origin: "sysroot"|"cargo", basis: "path-evidence"|"lockfile"|"elimination"}}
 */
export function classifyCrateOrigin({ name, evidence, lockedCrates }) {
  const text = String(evidence ?? "");
  // Sysroot evidence is tested first and wins outright. A unit can pool both strings when a
  // foreign object inherits a hash-group attribution, and "the sysroot shipped a copy of this"
  // is the claim that creates the corpus obligation.
  if (/sysroot/.test(text)) return { origin: "sysroot", basis: "path-evidence" };
  if (/registry-path/.test(text)) return { origin: "cargo", basis: "path-evidence" };
  if (lockedCrates.has(name)) return { origin: "cargo", basis: "lockfile" };
  return { origin: "sysroot", basis: "elimination" };
}

export default {
  normalizeCrateName,
  parseCargoLockPackages,
  lockedCrateNames,
  classifyCrateOrigin,
};
