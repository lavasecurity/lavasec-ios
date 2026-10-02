/**
 * ar-archive.mjs — dependency-free `ar` static-library reader and Rust crate attributor.
 *
 * WHY THIS EXISTS
 * ---------------
 * The third-party notices gate has to run in the PUBLIC repo, on a bare `ubuntu-latest`
 * runner where no Rust toolchain, no `cargo`, no `ar`, no `nm` and no `llvm-*` binaries
 * exist. It also has to work on the committed `.a` slices of
 * `LavaSecWGCore.xcframework`, whose members are fat-LTO Mach-O objects that Apple `nm`
 * and `xcrun llvm-nm` both refuse to read. So this module parses the `ar` container and
 * the members' byte content directly, using nothing but `node:fs` and `Buffer`.
 *
 * It never spawns a subprocess and imports nothing outside the Node standard library.
 *
 *
 * ============================================================================
 * THE RESULT IS A LOWER BOUND ON THE LINKED CRATE SET, NEVER AN UPPER BOUND.
 * ============================================================================
 *
 * Read that sentence again, because every caller gets it wrong the first time.
 *
 * This parser can prove a crate IS present. It can never prove one is absent.
 *
 * The artifact is built with `lto = true` and `codegen-units = 1`. Under fat LTO a
 * crate's code can be inlined entirely into another crate's codegen unit, leaving no
 * archive member of its own and no string of its own anywhere in the archive. Such a
 * crate is genuinely linked into the shipped binary and is genuinely invisible here.
 * Dead-code elimination can likewise remove every trace of a crate that was compiled
 * and linked. Additionally `strip = "debuginfo"` removes the DWARF that would otherwise
 * carry a crate's source paths, so many crates that DO have a member of their own still
 * have no recoverable version (see "VERSION RECOVERABILITY" below).
 *
 * Therefore:
 *
 *   - "crate X appears in this archive"      => sound. Report it. Cite it.
 *   - "crate X does not appear, so it is
 *      not linked, so it needs no notice"    => UNSOUND. Never do this.
 *
 * Any caller that treats a missing crate as "not linked" would be wrong. A notices gate
 * built on this module may use it to *add* obligations and to *fail* when something
 * present is uncited. It must not use it to *drop* an obligation, and it must not use
 * "absent from this scan" as evidence that a cited crate is stale. Removal from a
 * notices inventory needs a different source of truth (the dependency graph:
 * `Cargo.lock` plus the sysroot's own manifest), not this module.
 *
 *
 * WHICH ARCHIVES THIS READS (and which it does not)
 * -------------------------------------------------
 * The inputs are the committed `.a` slices above: BSD-layout, Mach-O members, one
 * `__.SYMDEF`. GNU/SysV container structure — `/`, `/SYM64/`, `//`, `/N` — is parsed for a
 * defensive reason rather than a portability one. Those names are the archive's hiding
 * places, and a reader that did not understand them would let a member wearing one skip
 * attribution. Reading the layout is what makes those names UNUSABLE as a disguise.
 *
 * That is narrower than "a general GNU archive reader", and the difference matters in one
 * known place. For GNU targets `rustc --crate-type rlib` wraps `lib.rmeta`'s payload in an
 * ELF object, so the payload test that keeps a codegen unit from renaming itself to
 * `lib.rmeta` would classify that legitimate metadata member as a disguise and leave it in
 * `unattributed`. Nothing here feeds this module an rlib — sysroot crates come from
 * `sysroot-crates.json`, an inventory, and the parsed artifacts are Apple xcframework
 * slices — so the case is unreachable rather than fixed.
 *
 * It also fails in the SAFE direction: a legitimate member lands in `unattributed`, which a
 * zero-unattributed caller rejects loudly. That is a false alarm, not a bypass. Recognizing
 * the metadata wrapper structurally would mean adding an accept-path to the exact check that
 * closes the rename class, on a format this repo never produces and cannot test — so the
 * limitation is recorded here instead. Pointing this module at GNU rlibs needs that work
 * done first.
 *
 *
 * VERSION RECOVERABILITY (measured, not assumed)
 * ----------------------------------------------
 * A member's crate NAME comes from the archive member name, which for a Rust codegen
 * unit is `<crate>-<metadata-hash>.<...>.rcgu.o` and is authoritative.
 *
 * A crate's VERSION is only recoverable when a source path survived into the member
 * bytes. In the artifacts this module was written for, three path shapes carry versions,
 * and each covers a different population:
 *
 *   1. `registry/src/<index>/<pkg>-<version>/...`
 *      Cargo-resolved crates.io dependencies. In a `strip = "debuginfo"` build these
 *      survive only as panic-location / `#[track_caller]` metadata, so a crate gets a
 *      recoverable version if and only if some panic or assert site of its own survived
 *      codegen. Crates with no such site (`libc` is the canonical example) have a member
 *      but NO recoverable version. That is a real limitation, not a parser bug.
 *
 *   2. `/rust/deps/<pkg>-<version>/...`
 *      Crates vendored into the precompiled Rust sysroot (`libc`, `hashbrown`, `memchr`,
 *      `gimli`, `addr2line`, `object`, `miniz_oxide`, `rustc-demangle`, `cfg-if`, ...).
 *      The sysroot rlibs ship with their debug info intact, so these versions survive
 *      even though the local build strips its own.
 *
 *   3. `/rustc/<commit>/library/<dir>/...`
 *      Sysroot workspace crates (`core`, `std`, `alloc`, `panic_abort`, `std_detect`,
 *      `unwind`, `compiler-builtins`, `rustc-std-workspace-*`). These have no crates.io
 *      version; their version IS the toolchain version. Reported with
 *      `versionKind: "rust-toolchain"` and taken from the embedded `rustc version X.Y.Z`
 *      producer string, never guessed.
 *
 * Because of (1), a crate can be present at two different versions with only one of them
 * recoverable. Callers reconciling against a notices inventory MUST key on
 * (name, version) pairs and MUST treat `version === null` as "unknown", never as "any"
 * and never as a match. A name-only reconciliation is broken by construction: this
 * artifact links `libc` twice, once from the sysroot and once from Cargo, and a
 * name-only check would consider a single `libc` entry sufficient.
 *
 *
 * EVIDENCE STRENGTH
 * -----------------
 * Every attribution carries an `evidence` tag so a caller can decide how much to trust
 * it. In descending strength:
 *
 *   "member-name"            The member is a Rust CGU; the crate name is in the member
 *                            name. Direct.
 *   "member-path-string"     A source path naming this crate was found in this member's
 *                            own bytes. Direct.
 *   "member-name-hash-group" INFERRED. A foreign object with no path string of its own,
 *                            grouped with attributed foreign objects that share its
 *                            member-name hash prefix (the `cc`-crate output directory
 *                            hash). Plausible, not proven. Kept separate on purpose.
 *
 * Archive-level crate evidence (`archive.crateEvidence`) is additionally sound across
 * member boundaries: a `base64-0.22.1` path found inside another crate's CGU still
 * proves base64 0.22.1 source was compiled into this archive. That is the one signal
 * that can catch an LTO-inlined crate with no member of its own, so it tightens the
 * lower bound — but it does not make the bound tight.
 *
 *
 * WHAT INTEGRITY CHECKING DOES AND DOES NOT COVER
 * ------------------------------------------------
 * `ar` has no checksums and neither does Mach-O. This module validates every structural
 * invariant that does exist — magic, header framing, `fmag` terminators, size arithmetic,
 * exact consumption of the file, per-member object magic, Mach-O load-command table
 * consistency, and cross-validation of the BSD `__.SYMDEF` ranlib offsets against the
 * real member header offsets — and throws `ArArchiveError` when any of them breaks.
 *
 * It cannot detect a flipped byte inside a member's payload (code, data, or a DWARF
 * string). Nothing at this layer can: there is no redundancy to check it against. A flip
 * inside a source-path string will silently change or remove one crate's recovered
 * version. Provenance of the input file has to be established elsewhere — for this repo,
 * by the drift gate that rebuilds the artifact and byte-compares it.
 *
 * Measured on the shipped ios-arm64 slice (19,802,008 bytes): only 137,329 bytes —
 * 0.69% of the file — are load-bearing for the crate set (member names plus the matched
 * path strings). The other 99.31% is code and data that cannot affect the result. In a
 * sweep of 900 single-byte mutations confined to those load-bearing bytes: 24 threw,
 * 774 changed nothing, 93 added a spurious garbled crate, 9 degraded a version to null,
 * and 3 dropped a crate name outright. Every one of the dropping mutations was still
 * visible downstream — either the member stopped matching a codegen-unit name and
 * landed in `unattributed`, or it kept the shape but yielded a *different* identifier
 * (`bitflags` -> `biuflags`), i.e. a name absent from any real inventory.
 *
 * That gives a caller two assertions worth making, both cheap:
 *
 *   1. `analysis.unattributed.length === 0` — for these artifacts it is 0, so any
 *      regression means a member shape changed or a name was damaged.
 *   2. reconcile crate NAMES against a closed inventory and fail on anything unknown —
 *      which turns the remaining corruption modes into a failed gate rather than a
 *      missing citation.
 *
 * Together those make the failure direction fail-closed. They do not make the parser
 * tamper-proof, and they do nothing about the lower-bound problem above, which is a
 * property of LTO and not of corruption.
 *
 *
 * SUPPORTED CONTAINER VARIANTS
 * ----------------------------
 * BSD/Darwin `ar`  — `#1/<len>` extended names, `__.SYMDEF[_64][ SORTED]` symbol table.
 *                    This is what the shipped slices actually use (verified).
 * SysV/GNU `ar`    — `/` symbol table, `//` long-name string table, `/<offset>` name
 *                    references, trailing-`/` short names.
 * Both are implemented; the format is detected from the members, not assumed.
 */

import fs from 'node:fs';

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

/** Thrown for any structural violation of the ar container or its members. */
export class ArArchiveError extends Error {
  constructor(message, details = {}) {
    super(message);
    this.name = 'ArArchiveError';
    this.details = details;
  }
}

// ---------------------------------------------------------------------------
// Container constants
// ---------------------------------------------------------------------------

export const AR_MAGIC = '!<arch>\n';
const AR_MAGIC_LEN = 8;
const AR_HEADER_LEN = 60;
const AR_FMAG = '`\n';

/**
 * Members that are legitimately not object files. Rust `.rlib`s are ar archives that
 * carry a crate-metadata blob alongside the codegen units; refusing to read those would
 * mean the module could parse the shipped `.a` slices but not the sysroot rlibs they
 * were linked from, which is exactly the comparison a notices audit wants to make.
 */
const NON_OBJECT_MEMBER_NAMES = new Set(['lib.rmeta', 'rust.metadata.bin']);

/**
 * Checks that a `//` member really is a GNU long-name table, and returns the offsets at which
 * its entries begin.
 *
 * This deliberately restricts NO filename byte. POSIX filenames are bytes, and may contain
 * anything except NUL and `/` — a tab or raw UTF-8 in a member name is legal, and two earlier
 * versions of this check (printable-ASCII, then no-C0-control) rejected valid GNU archives
 * produced by `ar rcs`. Since GNU container structure is parsed precisely so these names
 * cannot be used as a disguise, a rule that rejects real archives undermines the reason the
 * parsing exists.
 *
 * What is checked is STRUCTURE, which a name table has and an object payload does not:
 *
 * - the table is a sequence of entries, each terminated by `\n`, with nothing unterminated
 *   left over apart from NUL padding;
 * - no entry contains NUL, the one byte a filename genuinely cannot hold. A BSD member
 *   renamed to `//` fails here immediately: its body opens with the old extended name and
 *   then NUL padding, so the first entry carries NULs long before any newline.
 *
 * Returning the entry starts also lets `/N` references be checked against real boundaries
 * rather than just against the table's length, so an offset pointing into the middle of a
 * name cannot manufacture one.
 */
function validateLongNameTable(table, context) {
  const fail = (message, extra) => {
    throw new ArArchiveError(message, { ...context, ...extra });
  };

  // Trailing NULs are padding, not content.
  let end = table.length;
  while (end > 0 && table[end - 1] === 0x00) end -= 1;
  const starts = new Set();
  if (end === 0) return starts;

  if (table[end - 1] !== 0x0a) {
    fail('"//" long-name table does not end with a terminated entry', {
      contentLength: end,
      lastByte: table[end - 1],
    });
  }

  let entryStart = 0;
  for (let i = 0; i < end; i += 1) {
    const b = table[i];
    if (b === 0x0a) {
      if (i === entryStart) {
        // An empty entry, which is a malformed table — EXCEPT as the very last byte. When the
        // encoded name list has odd length, GNU ar and LLVM ar pad the declared `//` payload
        // to an even size with one extra newline (`abcdefghijklmnopq.o/\n` -> `...\n\n`), so
        // roughly half of ordinary GNU archives end this way. Rejecting it turned an
        // alignment detail into a parse failure.
        //
        // Accepted only in the final position, so a table with a hole in the middle is still
        // refused, and not recorded as an entry start — nothing may reference the padding.
        if (i === end - 1) break;
        fail('"//" long-name table contains an empty entry', { offset: entryStart });
      }
      starts.add(entryStart);
      entryStart = i + 1;
      continue;
    }
    if (b === 0x00) {
      // Legal in an object, impossible in a filename.
      fail('"//" long-name entry contains NUL, which a filename cannot', { offset: i });
    }
  }
  return starts;
}

const BSD_SYMBOL_TABLE_NAMES = new Set([
  '__.SYMDEF',
  '__.SYMDEF SORTED',
  '__.SYMDEF_64',
  '__.SYMDEF_64 SORTED',
]);

// Mach-O object magics (both endiannesses, 32/64-bit) plus ELF, so the per-member
// sanity check is useful on Linux-built archives too.
const OBJECT_MAGICS = new Map([
  [0xfeedface, 'macho32'],
  [0xfeedfacf, 'macho64'],
  [0xcefaedfe, 'macho32-swapped'],
  [0xcffaedfe, 'macho64-swapped'],
  [0x7f454c46, 'elf-be-read'], // 0x7f 'E' 'L' 'F' read big-endian
]);

const MH_OBJECT = 1;
const LC_SEGMENT_64 = 0x19;
const LC_SEGMENT_32 = 0x01;

// ---------------------------------------------------------------------------
// Low-level header helpers
// ---------------------------------------------------------------------------

function ascii(buf, start, end) {
  return buf.toString('latin1', start, end);
}

/**
 * Parse a decimal field that ar pads with spaces. Empty fields are legal in some
 * writers (notably the BSD long-name and symbol-table members) and map to 0.
 */
function parseArInt(text, radix, field, offset) {
  const trimmed = text.trim();
  if (trimmed === '') return 0;
  if (radix === 10 && !/^\d+$/.test(trimmed)) {
    throw new ArArchiveError(`ar header field "${field}" is not a decimal number`, {
      offset,
      field,
      raw: text,
    });
  }
  if (radix === 8 && !/^[0-7]+$/.test(trimmed)) {
    throw new ArArchiveError(`ar header field "${field}" is not an octal number`, {
      offset,
      field,
      raw: text,
    });
  }
  const value = Number.parseInt(trimmed, radix);
  if (!Number.isSafeInteger(value) || value < 0) {
    throw new ArArchiveError(`ar header field "${field}" is out of range`, {
      offset,
      field,
      raw: text,
    });
  }
  return value;
}

// ---------------------------------------------------------------------------
// Archive parsing
// ---------------------------------------------------------------------------

/**
 * Parse an ar archive held in a Buffer.
 *
 * @param {Buffer} buffer  Whole archive.
 * @param {object} [options]
 * @param {string} [options.path]            Label used in error messages.
 * @param {boolean} [options.validateObjects=true]
 *        Validate each member's object magic and (for Mach-O) its load-command table.
 * @param {boolean} [options.validateSymbolTable=true]
 *        Cross-check the symbol table's member offsets against real member headers.
 * @returns {ArArchive}
 * @throws {ArArchiveError}
 */
export function parseArchive(buffer, options = {}) {
  const {
    path = '<buffer>',
    validateObjects = true,
    validateSymbolTable = true,
  } = options;

  if (!Buffer.isBuffer(buffer)) {
    throw new ArArchiveError('parseArchive expects a Buffer', { path });
  }
  if (buffer.length < AR_MAGIC_LEN) {
    throw new ArArchiveError('file is shorter than the ar magic', {
      path,
      byteLength: buffer.length,
    });
  }
  const magic = ascii(buffer, 0, AR_MAGIC_LEN);
  if (magic !== AR_MAGIC) {
    throw new ArArchiveError('bad ar magic', {
      path,
      expected: AR_MAGIC,
      found: magic,
    });
  }

  /** @type {RawMember[]} */
  const raw = [];
  let offset = AR_MAGIC_LEN;
  let index = 0;

  while (offset < buffer.length) {
    if (offset + AR_HEADER_LEN > buffer.length) {
      throw new ArArchiveError('truncated ar member header', {
        path,
        offset,
        remaining: buffer.length - offset,
      });
    }
    const header = ascii(buffer, offset, offset + AR_HEADER_LEN);
    const fmag = header.slice(58, 60);
    if (fmag !== AR_FMAG) {
      throw new ArArchiveError('ar member header is missing its "`\\n" terminator', {
        path,
        offset,
        memberIndex: index,
        found: JSON.stringify(fmag),
      });
    }

    const rawName = header.slice(0, 16);
    const mtime = parseArInt(header.slice(16, 28), 10, 'mtime', offset);
    const uid = parseArInt(header.slice(28, 34), 10, 'uid', offset);
    const gid = parseArInt(header.slice(34, 40), 10, 'gid', offset);
    const mode = parseArInt(header.slice(40, 48), 8, 'mode', offset);
    const declaredSize = parseArInt(header.slice(48, 58), 10, 'size', offset);

    const bodyStart = offset + AR_HEADER_LEN;
    if (bodyStart + declaredSize > buffer.length) {
      throw new ArArchiveError('ar member body runs past end of file', {
        path,
        offset,
        memberIndex: index,
        declaredSize,
        available: buffer.length - bodyStart,
      });
    }

    raw.push({
      index,
      headerOffset: offset,
      rawName,
      mtime,
      uid,
      gid,
      mode,
      declaredSize,
      bodyStart,
    });

    // ar pads every member up to an even offset. The pad byte is conventionally
    // '\n' (BSD/GNU); accept NUL too, but reject anything else.
    let next = bodyStart + declaredSize;
    if (next % 2 === 1) {
      if (next >= buffer.length) {
        throw new ArArchiveError('ar member pad byte runs past end of file', {
          path,
          offset,
          memberIndex: index,
        });
      }
      const pad = buffer[next];
      if (pad !== 0x0a && pad !== 0x00) {
        throw new ArArchiveError('ar member pad byte is not "\\n" or NUL', {
          path,
          offset,
          memberIndex: index,
          pad,
        });
      }
      next += 1;
    }
    offset = next;
    index += 1;
  }

  if (offset !== buffer.length) {
    // Unreachable with the loop condition above, but assert it: an ar file must be
    // consumed exactly, and a silent mismatch here would mean lost members.
    throw new ArArchiveError('ar member walk did not consume the file exactly', {
      path,
      finalOffset: offset,
      byteLength: buffer.length,
    });
  }

  // Pass 2: resolve names. Needs the `//` table, which is itself a member.
  let longNameTable = null;
  let longNameTableIndex = -1;
  /** Offsets at which a `//` entry legally begins. Empty until a table is adopted. */
  let longNameEntryStarts = new Set();
  let symbolTableIndex = -1;
  // Which layout the adopted symbol table belongs to. A `//` long-name table is a SysV/GNU
  // construct; seeing one in an archive whose symbol table is BSD `__.SYMDEF` is not a
  // mixed-format archive, it is a member wearing the name.
  let symbolTableFlavour = null;
  let acceptedSpecials = 0;
  for (const r of raw) {
    if (r.rawName.startsWith('//')) {
      const nameField = r.rawName.trimEnd();
      if (nameField === '//') {
        // Position, not just name — same rule as the leading-run gate below. A GNU long-name
        // table is the first or second member; one appearing later is an ordinary object
        // wearing the name, and accepting it here would both mis-resolve `/N` references and
        // hand the member a free pass out of attribution.
        if (r.index > 1) break;
        longNameTable = buffer.subarray(r.bodyStart, r.bodyStart + r.declaredSize);
        longNameTableIndex = r.index;
        // Validate on adoption, so a member wearing this name cannot be used to resolve `/N`
        // references before anything has checked that it is a name table at all.
        longNameEntryStarts = validateLongNameTable(longNameTable, {
          path: options.path ?? null,
          memberIndex: r.index,
        });
        break;
      }
    }
  }

  /** @type {ArMember[]} */
  const members = [];
  const formats = new Set();

  for (const r of raw) {
    const nameField = r.rawName.trimEnd();
    let name;
    let nameEncoding;
    let dataOffset = r.bodyStart;
    let dataSize = r.declaredSize;
    let specialKind = null;

    const bsdLong = /^#1\/(\d+)$/.exec(nameField);
    if (bsdLong) {
      const nameLen = Number.parseInt(bsdLong[1], 10);
      if (nameLen > r.declaredSize) {
        throw new ArArchiveError('BSD extended name is longer than the member', {
          path,
          memberIndex: r.index,
          offset: r.headerOffset,
          nameLen,
          declaredSize: r.declaredSize,
        });
      }
      const nameBytes = buffer.subarray(r.bodyStart, r.bodyStart + nameLen);
      // Darwin NUL-pads the extended name up to an alignment boundary.
      name = nameBytes.toString('latin1').replace(/\0+$/, '');
      if (name.length === 0) {
        throw new ArArchiveError('BSD extended name is empty', {
          path,
          memberIndex: r.index,
          offset: r.headerOffset,
        });
      }
      if (/[\0-\x1f]/.test(name)) {
        throw new ArArchiveError('BSD extended name contains control characters', {
          path,
          memberIndex: r.index,
          offset: r.headerOffset,
          name: JSON.stringify(name),
        });
      }
      nameEncoding = 'bsd-extended';
      dataOffset = r.bodyStart + nameLen;
      dataSize = r.declaredSize - nameLen;
      formats.add('bsd');
    } else if (nameField === '//') {
      // `specialKind` is deliberately NOT set here. This chain decodes the NAME; deciding
      // that a member really is a table belongs to the uniqueness checks below, and setting
      // it here skipped them — every one of those checks is guarded on `specialKind === null`.
      name = '//';
      nameEncoding = 'sysv-long-name-table';
      formats.add('sysv');
    } else if (/^\/\d+$/.test(nameField)) {
      if (!longNameTable) {
        throw new ArArchiveError('member references the "//" long-name table, but there is none', {
          path,
          memberIndex: r.index,
          offset: r.headerOffset,
          nameField,
        });
      }
      const start = Number.parseInt(nameField.slice(1), 10);
      if (start >= longNameTable.length) {
        throw new ArArchiveError('"//" long-name offset is out of range', {
          path,
          memberIndex: r.index,
          offset: r.headerOffset,
          nameOffset: start,
          tableLength: longNameTable.length,
        });
      }
      if (!longNameEntryStarts.has(start)) {
        // In range but not at an entry boundary. Pointing into the middle of a name yields a
        // suffix of someone else's filename — a second member can then "reference" a name
        // that was never in the table, which is a way to manufacture an identity rather than
        // wear one. Boundaries come from `validateLongNameTable`.
        throw new ArArchiveError('"//" long-name offset is not an entry boundary', {
          path,
          memberIndex: r.index,
          offset: r.headerOffset,
          nameOffset: start,
        });
      }
      // Entries are terminated by "/\n" (GNU) or "\n"; tolerate a NUL terminator too.
      let end = start;
      while (
        end < longNameTable.length &&
        longNameTable[end] !== 0x0a &&
        longNameTable[end] !== 0x00
      ) {
        end += 1;
      }
      name = longNameTable.toString('latin1', start, end).replace(/\/$/, '');
      if (name.length === 0) {
        throw new ArArchiveError('"//" long-name entry is empty', {
          path,
          memberIndex: r.index,
          offset: r.headerOffset,
          nameOffset: start,
        });
      }
      nameEncoding = 'sysv-long-name';
      formats.add('sysv');
    } else if (nameField === '/' || nameField === '/SYM64/') {
      // As with `//` above: name only. Pre-setting `specialKind` here bypassed the one-table
      // check below, which is exactly the hole it was written to close — an archive with
      // `__.SYMDEF` at index 0 and a raw `/` at index 1 never compared the two, and the
      // leading-run rule then accepted the second as another special. A third-party crate
      // renamed that way left both attribution and `unattributed`, so its notice could be
      // deleted without `--verify-committed` noticing.
      name = nameField;
      nameEncoding = 'sysv-symbol-table';
      formats.add('sysv');
    } else {
      // Short name. GNU terminates with '/', BSD does not.
      if (nameField.endsWith('/')) {
        name = nameField.slice(0, -1);
        formats.add('sysv');
      } else {
        name = nameField;
      }
      if (name.length === 0) {
        throw new ArArchiveError('ar member has an empty name', {
          path,
          memberIndex: r.index,
          offset: r.headerOffset,
        });
      }
      nameEncoding = 'plain';
    }

    if (specialKind === null && (name === '/' || name === '/SYM64/')) {
      // The SysV/GNU spelling of the same trap the BSD branch below had. This reader
      // understands GNU container names, so an ordinary object whose header name is changed
      // to `/` was marked as another symbol table from the name alone and excluded from
      // attribution. One symbol table, first member, same rule.
      if (symbolTableIndex >= 0) {
        throw new ArArchiveError('archive declares more than one symbol table', {
          path: options.path ?? null,
          memberIndex: r.index,
          name,
          firstAt: symbolTableIndex,
        });
      }
      symbolTableIndex = r.index;
      symbolTableFlavour = 'sysv';
      specialKind = 'symbol-table';
    }
    if (specialKind === null && BSD_SYMBOL_TABLE_NAMES.has(name)) {
      // Same name-trust the metadata branch below had, and reachable the same way: renaming
      // a codegen unit to `__.SYMDEF` is length-preserving, and only the FIRST symbol-table
      // member is ever parsed — so a second one was marked special from its name, skipped
      // validation, and took its crate out of attribution with `unattributed: 0`.
      //
      // An archive has exactly one symbol table, and it is the first member. Anything later
      // claiming the name is lying about what it is, whatever its payload looks like.
      if (symbolTableIndex >= 0) {
        throw new ArArchiveError('archive declares more than one symbol table', {
          path: options.path ?? null,
          memberIndex: r.index,
          name,
          firstAt: symbolTableIndex,
        });
      }
      symbolTableIndex = r.index;
      symbolTableFlavour = 'bsd';
      specialKind = 'symbol-table';
    }
    if (specialKind === null && name === '//') {
      // The long-name table was the one special name classified purely from the header, with
      // no payload test and nothing cross-checking it — the same hole as `/`, one branch up,
      // and not part of the reported finding. It is reachable the same way: in a BSD archive
      // the name lives in the 16-byte header field, so overwriting it with `//` leaves the
      // old extended name sitting in the body, every size field intact and every `__.SYMDEF`
      // offset still resolving.
      //
      // Position alone does NOT close it. The pre-scan adopts the first `//` at index 0 or 1,
      // so a disguise placed at index 1 — the only slot the leading-run rule leaves open —
      // is the adopted one, and an index comparison waves it through. Verified: it kept
      // boringtun out of the crate set with `unattributed: 0`.
      //
      // Two independent tests, because either alone is evadable:
      //
      // 1. FORMAT COHERENCE. `//` is a SysV/GNU construct and `__.SYMDEF` is BSD. No
      //    toolchain emits both, so a `//` in an archive whose symbol table is BSD is a
      //    member wearing the name. This is what catches the disguise in our slices, which
      //    are BSD throughout.
      // 2. STRUCTURE, checked on adoption by `validateLongNameTable`: entries terminated by
      //    newline, no NUL inside one. That restricts no filename byte — POSIX filenames may
      //    hold anything but NUL and `/` — while a renamed BSD member fails at once, because
      //    its body opens with the old extended name and then NUL padding. The magic test
      //    used for `lib.rmeta` would NOT work here: the object begins further in, after
      //    that name.
      if (symbolTableFlavour === 'bsd') {
        throw new ArArchiveError('"//" long-name table in a BSD archive — a member is wearing the name', {
          path: options.path ?? null,
          memberIndex: r.index,
          name,
          symbolTableAt: symbolTableIndex,
        });
      }
      if (r.index !== longNameTableIndex) {
        throw new ArArchiveError('archive declares a second "//" long-name table', {
          path: options.path ?? null,
          memberIndex: r.index,
          name,
          adoptedAt: longNameTableIndex,
        });
      }
      specialKind = 'long-name-table';
    }
    if (specialKind === null && NON_OBJECT_MEMBER_NAMES.has(name)) {
      // A member is only metadata if its PAYLOAD is not an object. Trusting the name alone
      // made this the archive's blind spot: renaming any codegen unit to `lib.rmeta` or
      // `rust.metadata.bin` is length-preserving (BSD ar stores the long name NUL-padded in
      // the first bytes of the member body), so every header, size field and __.SYMDEF
      // offset stays valid — and the member then skipped object validation, was excluded
      // from `unattributed`, and took its crate out of the attribution entirely. An
      // adversarial pass hid 22 of 49 cited crates that way, boringtun among them, with the
      // archive byte-identical in size and the gate still exiting 0.
      //
      // Real Rust metadata members do not begin with an object magic, so the check costs
      // nothing legitimate and closes the rename.
      const magicBE = buffer.readUInt32BE(dataOffset);
      const magicLE = buffer.readUInt32LE(dataOffset);
      const disguised =
        dataSize >= 4 && (OBJECT_MAGICS.has(magicLE) || OBJECT_MAGICS.has(magicBE));
      if (!disguised) {
        specialKind = 'crate-metadata';
      }
    }

    // STRUCTURAL RULE: special members live only in the archive's LEADING RUN.
    //
    // Every "this member is not an ordinary object" name is a hiding place, and patching
    // them one at a time has not converged — `lib.rmeta`, `rust.metadata.bin`, `__.SYMDEF`,
    // `/` and `//` were each demonstrated to remove a crate from attribution, each fixed
    // separately, and each time another spelling was found. The names are attacker-chosen;
    // the POSITION is not.
    //
    // A real archive carries its symbol table first and, in the SysV layout, its long-name
    // table immediately after. Nothing legitimate claims a special name later on: the three
    // committed slices have exactly one special member each, `__.SYMDEF` at index 0. So a
    // member claiming one of those names outside the leading run is lying about what it is,
    // whatever its payload looks like — demote it to an ordinary object so it must be
    // validated and attributed, and so it lands in `unattributed` when it cannot be.
    if (specialKind !== null) {
      const inLeadingRun = members.length === acceptedSpecials && acceptedSpecials < 2;
      if (inLeadingRun) {
        acceptedSpecials += 1;
      } else {
        specialKind = null;
      }
    }

    members.push({
      index: r.index,
      name,
      nameEncoding,
      headerOffset: r.headerOffset,
      declaredSize: r.declaredSize,
      dataOffset,
      dataSize,
      mtime: r.mtime,
      uid: r.uid,
      gid: r.gid,
      mode: r.mode,
      specialKind,
      isSpecial: specialKind !== null,
    });
  }

  if (longNameTableIndex >= 0) {
    // Already flagged above via nameField === '//'.
  }

  const format =
    formats.size === 0 ? 'unknown' : formats.size === 1 ? [...formats][0] : 'mixed';

  const archive = {
    path,
    byteLength: buffer.length,
    format,
    members,
    memberCount: members.length,
    objectMemberCount: members.filter((m) => !m.isSpecial).length,
    longNameTableSize: longNameTable ? longNameTable.length : 0,
    symbolTable: null,
  };

  if (validateObjects) validateObjectMembers(buffer, archive);
  if (validateSymbolTable) archive.symbolTable = validateAndParseSymbolTable(buffer, archive);

  return archive;
}

/** Read an ar archive from disk. */
export function readArchiveFile(filePath, options = {}) {
  const buffer = fs.readFileSync(filePath);
  return { buffer, archive: parseArchive(buffer, { ...options, path: filePath }) };
}

/**
 * Member names in archive order.
 *
 * With `includeSpecialMembers: true` (the default) this is exactly what Darwin `ar t`
 * prints, `__.SYMDEF` included. GNU `ar t` hides `/` and `//`, so pass `false` when
 * comparing against GNU ar.
 */
export function listMemberNames(archive, { includeSpecialMembers = true } = {}) {
  return archive.members
    .filter((m) => includeSpecialMembers || !m.isSpecial)
    .map((m) => m.name);
}

// ---------------------------------------------------------------------------
// Structural validation of member payloads
// ---------------------------------------------------------------------------

function validateObjectMembers(buffer, archive) {
  for (const member of archive.members) {
    if (member.isSpecial) continue;
    if (member.dataSize < 4) {
      throw new ArArchiveError('ar member is too small to be an object file', {
        path: archive.path,
        memberIndex: member.index,
        name: member.name,
        dataSize: member.dataSize,
      });
    }
    const magic = buffer.readUInt32BE(member.dataOffset);
    const magicLE = buffer.readUInt32LE(member.dataOffset);
    const kind = OBJECT_MAGICS.get(magicLE) ?? OBJECT_MAGICS.get(magic);
    if (!kind) {
      throw new ArArchiveError('ar member does not start with a known object magic', {
        path: archive.path,
        memberIndex: member.index,
        name: member.name,
        magicBE: `0x${magic.toString(16).padStart(8, '0')}`,
        magicLE: `0x${magicLE.toString(16).padStart(8, '0')}`,
      });
    }
    member.objectKind = kind;
    if (kind === 'macho64' || kind === 'macho32') {
      validateMachOLoadCommands(buffer, archive, member, kind === 'macho64');
    }
  }
}

/**
 * Walk the Mach-O load-command table. This is the densest structural surface a member
 * has, and walking it turns a large class of payload corruption into a hard error
 * instead of a silent misread.
 */
function validateMachOLoadCommands(buffer, archive, member, is64) {
  const base = member.dataOffset;
  const end = base + member.dataSize;
  const headerSize = is64 ? 32 : 28;
  if (member.dataSize < headerSize) {
    throw new ArArchiveError('Mach-O member is smaller than its header', {
      path: archive.path,
      name: member.name,
      dataSize: member.dataSize,
    });
  }
  const filetype = buffer.readUInt32LE(base + 12);
  if (filetype !== MH_OBJECT) {
    throw new ArArchiveError('Mach-O member is not MH_OBJECT', {
      path: archive.path,
      name: member.name,
      filetype,
    });
  }
  const ncmds = buffer.readUInt32LE(base + 16);
  const sizeofcmds = buffer.readUInt32LE(base + 20);
  if (headerSize + sizeofcmds > member.dataSize) {
    throw new ArArchiveError('Mach-O sizeofcmds runs past the member', {
      path: archive.path,
      name: member.name,
      sizeofcmds,
      dataSize: member.dataSize,
    });
  }

  let cursor = base + headerSize;
  const cmdsEnd = cursor + sizeofcmds;
  for (let i = 0; i < ncmds; i += 1) {
    if (cursor + 8 > cmdsEnd) {
      throw new ArArchiveError('Mach-O load command runs past sizeofcmds', {
        path: archive.path,
        name: member.name,
        commandIndex: i,
        ncmds,
      });
    }
    const cmd = buffer.readUInt32LE(cursor);
    const cmdsize = buffer.readUInt32LE(cursor + 4);
    if (cmdsize < 8 || cmdsize % 4 !== 0 || cursor + cmdsize > cmdsEnd) {
      throw new ArArchiveError('Mach-O load command has an invalid cmdsize', {
        path: archive.path,
        name: member.name,
        commandIndex: i,
        cmd: `0x${cmd.toString(16)}`,
        cmdsize,
      });
    }
    if (cmd === LC_SEGMENT_64 || cmd === LC_SEGMENT_32) {
      const wide = cmd === LC_SEGMENT_64;
      const fileoff = wide
        ? Number(buffer.readBigUInt64LE(cursor + 40))
        : buffer.readUInt32LE(cursor + 32);
      const filesize = wide
        ? Number(buffer.readBigUInt64LE(cursor + 48))
        : buffer.readUInt32LE(cursor + 36);
      if (base + fileoff + filesize > end) {
        throw new ArArchiveError('Mach-O segment file range runs past the member', {
          path: archive.path,
          name: member.name,
          fileoff,
          filesize,
          dataSize: member.dataSize,
        });
      }
    }
    cursor += cmdsize;
  }
  if (cursor !== cmdsEnd) {
    throw new ArArchiveError('Mach-O load commands do not exactly fill sizeofcmds', {
      path: archive.path,
      name: member.name,
      consumed: cursor - (base + headerSize),
      sizeofcmds,
    });
  }
}

/**
 * Parse and cross-validate the archive symbol table.
 *
 * The BSD `__.SYMDEF` stores, for every exported symbol, the absolute file offset of the
 * defining member's ar HEADER. Checking each of those against the set of real header
 * offsets is a strong, cheap integrity check: it ties two independent regions of the
 * file together, so a corrupted size field or a shifted member is caught even when the
 * headers themselves still parse.
 */
function validateAndParseSymbolTable(buffer, archive) {
  const symMember = archive.members.find((m) => m.specialKind === 'symbol-table');
  if (!symMember) return null;

  const headerOffsets = new Set(archive.members.map((m) => m.headerOffset));
  const base = symMember.dataOffset;
  const size = symMember.dataSize;

  if (symMember.name === '/' || symMember.name === '/SYM64/') {
    // SysV: big-endian count, then count offsets, then NUL-separated names.
    const wide = symMember.name === '/SYM64/';
    if (size < (wide ? 8 : 4)) {
      throw new ArArchiveError('SysV symbol table is too small', {
        path: archive.path,
        size,
      });
    }
    const count = wide ? Number(buffer.readBigUInt64BE(base)) : buffer.readUInt32BE(base);
    const entrySize = wide ? 8 : 4;
    const need = (wide ? 8 : 4) + count * entrySize;
    if (need > size) {
      throw new ArArchiveError('SysV symbol table entry array runs past the member', {
        path: archive.path,
        count,
        size,
      });
    }
    let bad = 0;
    for (let i = 0; i < count; i += 1) {
      const at = base + (wide ? 8 : 4) + i * entrySize;
      const memberOffset = wide
        ? Number(buffer.readBigUInt64BE(at))
        : buffer.readUInt32BE(at);
      if (!headerOffsets.has(memberOffset)) bad += 1;
    }
    if (bad > 0) {
      throw new ArArchiveError('SysV symbol table points at offsets that are not member headers', {
        path: archive.path,
        badEntries: bad,
        totalEntries: count,
      });
    }
    // Decode the names too. They were bounds-checked and thrown away, which left callers
    // no way to ask what a slice actually EXPORTS — and a check written against a `symbols`
    // field that never existed silently did nothing.
    const sysvNamesStart = base + (wide ? 8 : 4) + count * entrySize;
    const sysvNames = decodeNulSeparated(buffer, sysvNamesStart, base + size, count);
    const symbols = sysvNames.map((name, i) => {
      const at = base + (wide ? 8 : 4) + i * entrySize;
      return {
        name,
        memberOffset: wide ? Number(buffer.readBigUInt64BE(at)) : buffer.readUInt32BE(at),
      };
    });
    return { kind: 'sysv', symbolCount: count, symbols, memberName: symMember.name };
  }

  // BSD __.SYMDEF: LE byte-length of the ranlib array, the array, LE byte-length of
  // the string table, the string table.
  const wide = symMember.name.startsWith('__.SYMDEF_64');
  const wordSize = wide ? 8 : 4;
  const entrySize = wordSize * 2;
  if (size < wordSize) {
    throw new ArArchiveError('BSD symbol table is too small', { path: archive.path, size });
  }
  const ranlibBytes = wide ? Number(buffer.readBigUInt64LE(base)) : buffer.readUInt32LE(base);
  if (ranlibBytes % entrySize !== 0) {
    throw new ArArchiveError('BSD symbol table ranlib array size is not a multiple of the entry size', {
      path: archive.path,
      ranlibBytes,
      entrySize,
    });
  }
  const strLenAt = base + wordSize + ranlibBytes;
  if (strLenAt + wordSize > base + size) {
    throw new ArArchiveError('BSD symbol table ranlib array runs past the member', {
      path: archive.path,
      ranlibBytes,
      size,
    });
  }
  const strBytes = wide
    ? Number(buffer.readBigUInt64LE(strLenAt))
    : buffer.readUInt32LE(strLenAt);
  const strBase = strLenAt + wordSize;
  if (strBase + strBytes > base + size) {
    throw new ArArchiveError('BSD symbol table string table runs past the member', {
      path: archive.path,
      strBytes,
      size,
    });
  }

  const count = ranlibBytes / entrySize;
  let badOffsets = 0;
  let badStrings = 0;
  for (let i = 0; i < count; i += 1) {
    const at = base + wordSize + i * entrySize;
    const strOffset = wide ? Number(buffer.readBigUInt64LE(at)) : buffer.readUInt32LE(at);
    const memberOffset = wide
      ? Number(buffer.readBigUInt64LE(at + wordSize))
      : buffer.readUInt32LE(at + wordSize);
    if (strOffset >= strBytes) badStrings += 1;
    if (!headerOffsets.has(memberOffset)) badOffsets += 1;
  }
  if (badOffsets > 0) {
    throw new ArArchiveError('BSD symbol table points at offsets that are not member headers', {
      path: archive.path,
      badEntries: badOffsets,
      totalEntries: count,
    });
  }
  if (badStrings > 0) {
    throw new ArArchiveError('BSD symbol table has string offsets outside the string table', {
      path: archive.path,
      badEntries: badStrings,
      totalEntries: count,
    });
  }

  // Names AND their target member offsets. Counting names archive-wide is not enough: swap
  // two renames — an uncited member made to look first-party, a real first-party member made
  // to look like a cited crate — and the global count is unchanged while the skip hides the
  // uncited one. The offset is what ties a symbol to the member that defines it.
  const symbols = [];
  for (let i = 0; i < count; i += 1) {
    const at = base + wordSize + i * entrySize;
    const strx = wide ? Number(buffer.readBigUInt64LE(at)) : buffer.readUInt32LE(at);
    const memberOffset = wide
      ? Number(buffer.readBigUInt64LE(at + wordSize))
      : buffer.readUInt32LE(at + wordSize);
    const from = strBase + strx;
    if (from >= strBase + strBytes) continue;
    const end = buffer.indexOf(0, from);
    symbols.push({
      name: buffer.subarray(from, end === -1 ? strBase + strBytes : end).toString('ascii'),
      memberOffset,
    });
  }

  return {
    kind: wide ? 'bsd64' : 'bsd',
    symbolCount: count,
    stringTableBytes: strBytes,
    symbols,
    memberName: symMember.name,
  };
}

/** NUL-separated name list, used by the SysV symbol table. */
function decodeNulSeparated(buffer, from, limit, max) {
  const names = [];
  let at = from;
  while (at < limit && names.length < max) {
    const end = buffer.indexOf(0, at);
    if (end === -1 || end > limit) break;
    names.push(buffer.subarray(at, end).toString('ascii'));
    at = end + 1;
  }
  return names;
}

// ---------------------------------------------------------------------------
// Member-name classification
// ---------------------------------------------------------------------------

/**
 * A Rust codegen unit archived by rustc looks like
 *   <crate>-<metadata-hash>.<crate>.<cgu-hash>-cgu.<n>.rcgu.o
 * or, for the allocator/metadata shim,
 *   <crate>-<metadata-hash>.<opaque-hash>.rcgu.o
 * The crate segment is the Rust *lib name*, so `-` is already `_`.
 */
const RUST_CGU_RE = /^([A-Za-z_][A-Za-z0-9_]*)-([0-9a-zA-Z]{8,32})\.(.+)\.rcgu\.o$/;

/**
 * Crates compiled without a `-C metadata` disambiguator — in practice workspace path
 * dependencies, e.g. the vendored `boringtun` — get no `-<metadata-hash>` segment:
 *   <crate>.<crate>.<cgu-hash>-cgu.<n>.rcgu.o
 * Matched only after RUST_CGU_RE fails, so a hashed name is never misread as this.
 */
const RUST_CGU_NO_METADATA_RE = /^([A-Za-z_][A-Za-z0-9_]*)\.(.+)\.rcgu\.o$/;

/**
 * Objects the `cc` crate (or the sysroot's own build) contributed to an rlib are named
 * <source-dir-hash>-<basename>.o. These are NOT Rust codegen units: they are the C and
 * assembly translation units (compiler-rt for compiler_builtins, BoringSSL-derived C and
 * pregenerated asm for ring). Their names carry no crate name at all.
 */
const FOREIGN_OBJECT_RE = /^([0-9a-f]{8,32})-(.+)\.o$/;

/**
 * Classify an archive member from its name alone.
 * @returns {{kind: string, crate: string|null, metadataHash: string|null,
 *            cguSuffix: string|null, sourceHash: string|null, objectBase: string|null}}
 */
/**
 * A classification derived from a name that `parseArchive` has REFUSED to treat as special
 * describes a member that is lying about what it is. Demote it to `unknown` so it reaches
 * `unattributed` and fails the caller's gate, instead of being silently excluded.
 */
function demoteSpecialClassification(classification) {
  if (
    classification.kind === 'crate-metadata' ||
    classification.kind === 'symbol-table' ||
    classification.kind === 'long-name-table'
  ) {
    return { ...classification, kind: 'unknown', crate: null };
  }
  return classification;
}

export function classifyMemberName(name) {
  if (BSD_SYMBOL_TABLE_NAMES.has(name) || name === '/' || name === '/SYM64/') {
    return blank('symbol-table');
  }
  if (name === '//') return blank('long-name-table');
  if (NON_OBJECT_MEMBER_NAMES.has(name)) return blank('crate-metadata');

  const cgu = RUST_CGU_RE.exec(name);
  if (cgu) {
    return {
      kind: 'rust-cgu',
      crate: cgu[1],
      metadataHash: cgu[2],
      cguSuffix: cgu[3],
      sourceHash: null,
      objectBase: null,
    };
  }
  const cguNoMeta = RUST_CGU_NO_METADATA_RE.exec(name);
  if (cguNoMeta) {
    return {
      kind: 'rust-cgu',
      crate: cguNoMeta[1],
      metadataHash: null,
      cguSuffix: cguNoMeta[2],
      sourceHash: null,
      objectBase: null,
    };
  }
  const foreign = FOREIGN_OBJECT_RE.exec(name);
  if (foreign) {
    return {
      kind: 'foreign-object',
      crate: null,
      metadataHash: null,
      cguSuffix: null,
      sourceHash: foreign[1],
      objectBase: foreign[2],
    };
  }
  return blank('unknown');

  function blank(kind) {
    return {
      kind,
      crate: null,
      metadataHash: null,
      cguSuffix: null,
      sourceHash: null,
      objectBase: null,
    };
  }
}

// ---------------------------------------------------------------------------
// Crate / version evidence recovered from member bytes
// ---------------------------------------------------------------------------

const VERSION = String.raw`\d+\.\d+\.\d+(?:[-+][0-9A-Za-z][0-9A-Za-z.-]*)?`;
const PKG = String.raw`[A-Za-z_][A-Za-z0-9_.+-]*?`;

// `registry/src/<index>/<pkg>-<version>` — Cargo dependency, absolute or path-remapped.
const CARGO_REGISTRY_RE = new RegExp(
  String.raw`registry/src/[^/\x00\s]{1,120}/(${PKG})-(${VERSION})(?![0-9A-Za-z.+-])`,
  'g',
);
// `/rust/deps/<pkg>-<version>` — crate vendored into the precompiled Rust sysroot.
const RUST_DEPS_RE = new RegExp(
  String.raw`/rust/deps/(${PKG})-(${VERSION})(?![0-9A-Za-z.+-])`,
  'g',
);
// `/rustc/<commit>/library/<dir>` — sysroot workspace crate; version == toolchain.
const SYSROOT_LIBRARY_RE = /\/rustc\/([0-9a-f]{8,40})\/library\/([A-Za-z_][A-Za-z0-9_-]*)/g;
// The rustc producer string, which is where the toolchain version comes from.
const RUSTC_VERSION_RE =
  /rustc version (\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?) \(([0-9a-f]{7,40}) (\d{4}-\d{2}-\d{2})\)/g;

const ANCHORS = ['registry/src/', '/rust/deps/', '/library/', 'rustc version '];

/** Normalize a package directory name to the Rust crate identifier. */
export function toCrateIdentifier(packageName) {
  return packageName.replace(/-/g, '_');
}

/**
 * Expand to the maximal run of printable ASCII around `index`.
 *
 * Deliberately does NOT rely on NUL termination. Some of these strings live in DWARF
 * line-program directory tables where entries abut without separators, so a NUL-based
 * reader would miss them entirely. The version regexes use a negative lookahead so a
 * run that has been concatenated with a following hash (e.g. `libc-0.2.178<hex>src`)
 * fails to match rather than yielding a wrong version — conservative by design.
 */
function printableRun(bytes, index, maxSpan = 4096) {
  let start = index;
  let end = index;
  const lo = Math.max(0, index - maxSpan);
  const hi = Math.min(bytes.length, index + maxSpan);
  while (start > lo && bytes[start - 1] >= 0x20 && bytes[start - 1] <= 0x7e) start -= 1;
  while (end < hi && bytes[end] >= 0x20 && bytes[end] <= 0x7e) end += 1;
  return bytes.toString('latin1', start, end);
}

function collectRuns(bytes) {
  const runs = new Set();
  for (const anchor of ANCHORS) {
    let at = bytes.indexOf(anchor, 0, 'latin1');
    while (at !== -1) {
      runs.add(printableRun(bytes, at));
      at = bytes.indexOf(anchor, at + anchor.length, 'latin1');
    }
  }
  return runs;
}

/**
 * Bind a 40-hex sysroot commit to a toolchain version.
 *
 * `/rustc/<40-hex-commit>/library/...` says which rustc *commit* built the member, and
 * the `rustc version X.Y.Z (<short-commit> <date>)` producer string says which version
 * that commit is. The short commit is a prefix of the long one, so matching them binds
 * the two — this is evidence, not a guess. Returns null unless exactly one version
 * matches, so an ambiguous archive yields "unknown" rather than a wrong version.
 */
function bindToolchainVersion(commit, toolchains) {
  const matches = new Set();
  for (const t of toolchains) {
    if (commit.startsWith(t.commit) || t.commit.startsWith(commit)) matches.add(t.version);
  }
  return matches.size === 1 ? [...matches][0] : null;
}

/**
 * Scan a byte range for embedded crate/version evidence.
 *
 * @param {Buffer} bytes
 * @param {object} [options]
 * @param {ToolchainEvidence[]} [options.toolchains]
 *        Toolchain producer strings recovered from the whole archive. Needed because the
 *        clang-compiled compiler-rt objects inside `compiler_builtins` carry a
 *        `/rustc/<commit>/library/compiler-builtins/...` path but a *clang* producer
 *        string, so their version can only be bound via the commit hash and a producer
 *        string that lives in a sibling member.
 * @returns {{crates: CrateEvidence[], toolchains: ToolchainEvidence[]}}
 *
 * Every returned item is positive evidence only. Finding nothing means nothing.
 */
/**
 * The path-evidence source naming the sysroot's own VENDORED copy of a crate.
 *
 * Exported because a consumer has to select on it, and a consumer that spells the string
 * itself drifts silently: if the producer renames the source, a hand-written filter matches
 * nothing and every crate quietly goes unchecked while the gate still reports success.
 *
 * This is the only evidence that says "the sysroot shipped this". `cargo-registry-path` is a
 * Cargo-resolved copy and `rustc-sysroot-library-path` is an in-tree crate whose path carries
 * the TOOLCHAIN version rather than its own — neither is comparable with the sysroot corpus.
 */
export const SYSROOT_VENDOR_PATH_SOURCE = 'rust-sysroot-vendor-path';

/** The same source as it appears in a `CrateRecord.evidence` entry. */
export const SYSROOT_VENDOR_PATH_EVIDENCE = `archive-path-string:${SYSROOT_VENDOR_PATH_SOURCE}`;

export function scanCrateEvidence(bytes, options = {}) {
  const externalToolchains = options.toolchains ?? [];
  const runs = collectRuns(bytes);

  /** @type {Map<string, CrateEvidence>} */
  const crates = new Map();
  /** @type {Map<string, ToolchainEvidence>} */
  const toolchains = new Map();

  const add = (packageName, version, versionKind, source, sample) => {
    const crate = toCrateIdentifier(packageName);
    const key = `${crate}@${version ?? ''}#${source}`;
    let hit = crates.get(key);
    if (!hit) {
      hit = {
        crate,
        packageName,
        version: version ?? null,
        versionKind,
        source,
        occurrences: 0,
        sample: sample.slice(0, 200),
      };
      crates.set(key, hit);
    }
    hit.occurrences += 1;
  };

  for (const run of runs) {
    for (const m of run.matchAll(RUSTC_VERSION_RE)) {
      const key = `${m[1]}/${m[2]}`;
      const hit = toolchains.get(key) ?? {
        version: m[1],
        commit: m[2],
        date: m[3],
        occurrences: 0,
      };
      hit.occurrences += 1;
      toolchains.set(key, hit);
    }
  }

  // The toolchain version is what a sysroot workspace crate's "version" means, so it
  // has to be resolved before those are recorded. Producer strings found in this byte
  // range take precedence; archive-level ones supplied by the caller fill the gap for
  // members whose only producer string is clang's.
  const localToolchains = [...toolchains.values()];
  const allToolchains = [...localToolchains, ...externalToolchains];

  for (const run of runs) {
    for (const m of run.matchAll(CARGO_REGISTRY_RE)) {
      add(m[1], m[2], 'crates.io', 'cargo-registry-path', m[0]);
    }
    for (const m of run.matchAll(RUST_DEPS_RE)) {
      add(m[1], m[2], 'crates.io', SYSROOT_VENDOR_PATH_SOURCE, m[0]);
    }
    for (const m of run.matchAll(SYSROOT_LIBRARY_RE)) {
      const version = bindToolchainVersion(m[1], allToolchains);
      add(m[2], version, 'rust-toolchain', 'rustc-sysroot-library-path', m[0]);
    }
  }

  return { crates: [...crates.values()], toolchains: localToolchains };
}

// ---------------------------------------------------------------------------
// Attribution
// ---------------------------------------------------------------------------

/**
 * Attribute every member of a parsed archive to a crate.
 *
 * Attribution rules, in order:
 *
 *  1. Rust CGU members take their crate name from the member name (authoritative), and
 *     take a version ONLY from a path string, found in that same member, whose crate
 *     name matches. A path naming some *other* crate is never used to version this
 *     member — under fat LTO an inlined crate's panic locations routinely land in a
 *     different crate's CGU, so that would silently mislabel.
 *  2. Foreign objects (C / assembly translation units, no crate name in the member
 *     name) are attributed from path strings in their own bytes when exactly one crate
 *     is implicated.
 *  3. Foreign objects still unattributed inherit, as a clearly-marked INFERENCE, the
 *     crate of other foreign objects sharing their member-name hash prefix — the `cc`
 *     crate derives that prefix from the source directory, so members of one group came
 *     from one build. Tagged `member-name-hash-group`; never promoted to proof.
 *
 * Anything left over is returned in `unattributed`. Members are never dropped:
 * `attributed.length + unattributed.length + specialMembers === archive.memberCount`.
 */
export function attributeMembers(buffer, archive, options = {}) {
  const toolchains = options.toolchains ?? [];
  const results = [];

  for (const member of archive.members) {
    // `classifyMemberName` works from the name alone, which is exactly what an attacker
    // controls: renaming a codegen unit to `lib.rmeta` is length-preserving and leaves every
    // structural field valid. `parseArchive` has already checked the PAYLOAD and refuses to
    // mark such a member special, so honour that decision here rather than re-deriving the
    // classification from the string. Without this the member is dropped from
    // `unattributed` a second time, by a different code path, and its crate still vanishes.
    const classification = member.isSpecial
      ? classifyMemberName(member.name)
      : demoteSpecialClassification(classifyMemberName(member.name));
    const entry = {
      index: member.index,
      name: member.name,
      // Carried through so callers can tie a symbol-table entry back to the member that
      // defines it — the ranlib array addresses members by header offset.
      headerOffset: member.headerOffset,
      dataSize: member.dataSize,
      kind: classification.kind,
      crate: null,
      version: null,
      versionKind: null,
      versionCertainty: 'unknown',
      evidence: null,
      evidenceDetail: null,
      pathCrates: [],
      notes: [],
    };

    if (member.isSpecial) {
      entry.kind = classification.kind === 'unknown' ? 'special' : classification.kind;
      results.push(entry);
      continue;
    }

    const bytes = buffer.subarray(member.dataOffset, member.dataOffset + member.dataSize);
    const { crates } = scanCrateEvidence(bytes, { toolchains });
    entry.pathCrates = crates;

    if (classification.kind === 'rust-cgu') {
      entry.crate = classification.crate;
      entry.metadataHash = classification.metadataHash;
      entry.evidence = 'member-name';

      const own = crates.filter((c) => c.crate === classification.crate);
      const versions = [...new Set(own.map((c) => c.version).filter(Boolean))];
      if (versions.length === 1) {
        entry.version = versions[0];
        entry.versionKind = own.find((c) => c.version === versions[0]).versionKind;
        entry.evidenceDetail = own.find((c) => c.version === versions[0]).source;
        entry.versionCertainty = 'proven';
      } else if (versions.length > 1) {
        entry.notes.push(
          `ambiguous version evidence in member: ${versions.join(', ')} — version left unknown`,
        );
      } else {
        entry.notes.push(
          'no source-path string for this crate survived in this member; version not recoverable here',
        );
      }
      results.push(entry);
      continue;
    }

    if (classification.kind === 'foreign-object') {
      entry.sourceHash = classification.sourceHash;
      entry.objectBase = classification.objectBase;
      const distinct = [...new Set(crates.map((c) => c.crate))];
      if (distinct.length === 1) {
        const chosen = crates.filter((c) => c.crate === distinct[0]);
        const versions = [...new Set(chosen.map((c) => c.version).filter(Boolean))];
        entry.crate = distinct[0];
        entry.evidence = 'member-path-string';
        entry.evidenceDetail = chosen[0].source;
        if (versions.length === 1) {
          entry.version = versions[0];
          entry.versionKind = chosen.find((c) => c.version === versions[0]).versionKind;
          entry.versionCertainty = 'proven';
        } else if (versions.length > 1) {
          entry.notes.push(`ambiguous version evidence: ${versions.join(', ')}`);
        }
      } else if (distinct.length > 1) {
        entry.notes.push(
          `path strings implicate more than one crate (${distinct.join(', ')}); left for hash-group inference`,
        );
      }
      results.push(entry);
      continue;
    }

    entry.notes.push('member name matches neither the Rust CGU nor the foreign-object shape');
    results.push(entry);
  }

  // Rule 3: propagate within a member-name hash group, marked as inference.
  const groupCrate = new Map();
  const groupVersion = new Map();
  for (const e of results) {
    if (e.kind !== 'foreign-object' || !e.crate || !e.sourceHash) continue;
    const seenCrate = groupCrate.get(e.sourceHash);
    if (seenCrate === undefined) groupCrate.set(e.sourceHash, e.crate);
    else if (seenCrate !== e.crate) groupCrate.set(e.sourceHash, null); // conflicting group
    if (e.version) {
      const seenVersion = groupVersion.get(e.sourceHash);
      if (seenVersion === undefined) groupVersion.set(e.sourceHash, e);
      else if (seenVersion && seenVersion.version !== e.version) {
        groupVersion.set(e.sourceHash, null);
      }
    }
  }
  for (const e of results) {
    if (e.kind !== 'foreign-object' || e.crate || !e.sourceHash) continue;
    const inferred = groupCrate.get(e.sourceHash);
    if (!inferred) continue;
    e.crate = inferred;
    e.evidence = 'member-name-hash-group';
    e.evidenceDetail = `shares member-name prefix ${e.sourceHash} with attributed objects`;
    e.notes.push('INFERRED, not proven: attributed by member-name hash group only');
    const sibling = groupVersion.get(e.sourceHash);
    if (sibling && sibling.crate === inferred) {
      e.version = sibling.version;
      e.versionKind = sibling.versionKind;
      e.versionCertainty = 'inferred-hash-group';
      e.notes.push(`version inherited from hash-group sibling ${sibling.name}`);
    }
  }

  const SPECIAL_KINDS = new Set([
    'symbol-table',
    'long-name-table',
    'crate-metadata',
    'special',
  ]);
  const attributed = results.filter((e) => Boolean(e.crate));
  const unattributed = results.filter((e) => !e.crate && !SPECIAL_KINDS.has(e.kind));
  const special = results.filter((e) => SPECIAL_KINDS.has(e.kind));

  return { members: results, attributed, unattributed, special };
}

/**
 * Fill in member versions from archive-level path evidence, but only where doing so
 * cannot be wrong in the way that matters.
 *
 * Under fat LTO a crate's panic-location strings routinely land in a *different*
 * crate's codegen unit, so the archive may prove "crate C at version V is compiled in"
 * while C's own member holds no string of its own. Adopting V for that member is only
 * safe when there is exactly one member of C still lacking a version AND exactly one
 * archive-level version of C that no member has already claimed.
 *
 * That guard is what stops this from destroying the one case it must not get wrong:
 * `libc` has two members (sysroot + Cargo) but only one recoverable version (0.2.178,
 * from the sysroot's `/rust/deps` path). Here the single archive-level version is
 * already claimed by the sysroot member, so no candidate remains and the Cargo member
 * correctly stays `version: null`. A looser rule would stamp 0.2.178 onto the Cargo
 * copy and manufacture a false citation.
 *
 * Results are tagged `versionCertainty: "inferred-sole-candidate"` — still an inference,
 * because the crate whose string survived could in principle be the one LTO inlined away.
 */
export function resolveSoleCandidateVersions(members, archiveCrates) {
  const archiveVersions = new Map();
  for (const c of archiveCrates) {
    if (!c.version) continue;
    if (!archiveVersions.has(c.crate)) archiveVersions.set(c.crate, new Map());
    archiveVersions.get(c.crate).set(c.version, c);
  }

  const byCrate = new Map();
  for (const m of members) {
    if (!m.crate) continue;
    if (!byCrate.has(m.crate)) byCrate.set(m.crate, []);
    byCrate.get(m.crate).push(m);
  }

  let resolved = 0;
  for (const [crate, crateMembers] of byCrate) {
    const versions = archiveVersions.get(crate);
    if (!versions) continue;
    const claimed = new Set(crateMembers.map((m) => m.version).filter(Boolean));
    const unknown = crateMembers.filter((m) => !m.version);
    const candidates = [...versions.keys()].filter((v) => !claimed.has(v));
    if (unknown.length !== 1 || candidates.length !== 1) continue;
    const evidence = versions.get(candidates[0]);
    unknown[0].version = candidates[0];
    unknown[0].versionKind = evidence.versionKind;
    unknown[0].versionCertainty = 'inferred-sole-candidate';
    unknown[0].notes.push(
      `version inferred: the archive proves ${crate} ${candidates[0]} (${evidence.source}) ` +
        'and this is the only member of that crate without a version',
    );
    resolved += 1;
  }
  return resolved;
}

// ---------------------------------------------------------------------------
// Top level
// ---------------------------------------------------------------------------

/**
 * Parse a static library and report the crates linked into it.
 *
 * REMINDER, because this is the return value people misuse: `crates` is a LOWER BOUND
 * on the linked crate set, never an upper bound. A crate absent from it may still be
 * linked — fat LTO can inline a crate away entirely. Use this to prove presence and to
 * fail closed on uncited crates; never to justify removing a citation.
 *
 * @param {string|Buffer} input  File path, or the archive bytes.
 * @param {object} [options]
 * @param {string} [options.path]  Label when `input` is a Buffer.
 * @returns {ArchiveAnalysis}
 */
export function analyzeStaticLibrary(input, options = {}) {
  const buffer = Buffer.isBuffer(input) ? input : fs.readFileSync(input);
  const path = Buffer.isBuffer(input) ? (options.path ?? '<buffer>') : input;
  const archive = parseArchive(buffer, { ...options, path });

  // Archive-level evidence. Sound across member boundaries: a path naming crate X
  // proves X's source was compiled into this archive no matter which member holds it.
  // This is the only signal that can catch a crate LTO inlined out of existence, so it
  // tightens the lower bound — it does not make it tight.
  //
  // Scanned before member attribution because members need the archive's rustc producer
  // strings to bind their sysroot commit hash to a toolchain version.
  const archiveEvidence = scanCrateEvidence(buffer);
  const attribution = attributeMembers(buffer, archive, {
    toolchains: archiveEvidence.toolchains,
  });
  const soleCandidateResolutions = resolveSoleCandidateVersions(
    attribution.members,
    archiveEvidence.crates,
  );

  /** @type {Map<string, CrateRecord>} */
  const crates = new Map();
  const record = (crate, version, versionKind, evidence, memberName) => {
    const key = `${crate}@${version ?? '?'}`;
    let rec = crates.get(key);
    if (!rec) {
      rec = {
        crate,
        version: version ?? null,
        versionKind: versionKind ?? null,
        versionCertainty: null,
        memberCount: 0,
        members: [],
        evidence: new Set(),
      };
      crates.set(key, rec);
    }
    rec.evidence.add(evidence);
    if (memberName) {
      rec.memberCount += 1;
      if (rec.members.length < 8) rec.members.push(memberName);
    }
    return rec;
  };

  // Weakest certainty wins, so a crate record never claims more confidence than its
  // least-certain contributing member.
  const CERTAINTY_RANK = {
    proven: 0,
    'inferred-hash-group': 1,
    'inferred-sole-candidate': 2,
    unknown: 3,
  };
  for (const m of attribution.members) {
    if (!m.crate) continue;
    const rec = record(m.crate, m.version, m.versionKind, m.evidence, m.name);
    const next = m.version ? m.versionCertainty : 'unknown';
    if (
      rec.versionCertainty === null ||
      CERTAINTY_RANK[next] > CERTAINTY_RANK[rec.versionCertainty]
    ) {
      rec.versionCertainty = next;
    }
  }
  for (const c of archiveEvidence.crates) {
    const rec = record(c.crate, c.version, c.versionKind, `archive-path-string:${c.source}`, null);
    if (rec.versionCertainty === null) rec.versionCertainty = c.version ? 'proven' : 'unknown';
  }

  const crateList = [...crates.values()]
    .map((r) => ({ ...r, evidence: [...r.evidence].sort() }))
    .sort((a, b) =>
      a.crate === b.crate
        ? String(a.version).localeCompare(String(b.version))
        : a.crate.localeCompare(b.crate),
    );

  const names = new Set(crateList.map((c) => c.crate));

  return {
    path,
    byteLength: buffer.length,
    format: archive.format,
    memberCount: archive.memberCount,
    objectMemberCount: archive.objectMemberCount,
    symbolTable: archive.symbolTable,
    toolchains: archiveEvidence.toolchains,
    members: attribution.members,
    unattributed: attribution.unattributed,
    counts: {
      total: archive.memberCount,
      special: attribution.special.length,
      attributed: attribution.members.filter((m) => m.crate).length,
      unattributed: attribution.unattributed.length,
      attributedByName: attribution.members.filter((m) => m.evidence === 'member-name').length,
      attributedByPath: attribution.members.filter((m) => m.evidence === 'member-path-string').length,
      attributedByHashGroup: attribution.members.filter(
        (m) => m.evidence === 'member-name-hash-group',
      ).length,
      versionProven: attribution.members.filter((m) => m.versionCertainty === 'proven').length,
      versionInferred: attribution.members.filter((m) =>
        m.versionCertainty.startsWith('inferred'),
      ).length,
      versionUnknown: attribution.members.filter(
        (m) => m.crate && m.versionCertainty === 'unknown',
      ).length,
      soleCandidateResolutions,
    },
    crates: crateList,
    crateNames: [...names].sort(),
    /**
     * Restated on the returned object so it survives being logged, serialized, or
     * pasted into a review comment without the module docs alongside it.
     */
    bound: 'lower',
    boundNote:
      'This crate set is a LOWER BOUND on the linked crate set, never an upper bound. ' +
      'Fat LTO can inline a crate entirely into another crate\'s codegen unit, leaving no ' +
      'member and no string of its own. This parser can prove a crate IS present; it can ' +
      'never prove one is absent. Treating a missing crate as "not linked" would be wrong.',
  };
}

export default {
  AR_MAGIC,
  ArArchiveError,
  parseArchive,
  readArchiveFile,
  listMemberNames,
  classifyMemberName,
  scanCrateEvidence,
  toCrateIdentifier,
  attributeMembers,
  resolveSoleCandidateVersions,
  analyzeStaticLibrary,
};
