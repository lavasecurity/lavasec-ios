import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, readdirSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import test from 'node:test';
import {fileURLToPath} from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const archive = 'LavaSecWGCore.xcframework/macos-arm64/liblavasec_wireguard_core.a';
// Execute the real shell scripts with deterministic compiler/packager fixtures.
// No Rust download or Apple toolchain is needed by the Linux repository checks.
const compiler = String.raw`#!${process.execPath}
const fs = require('node:fs');
const path = require('node:path');
const tool = path.basename(process.argv[1]);
const args = process.argv.slice(2);
const env = process.env;
const mode = env.MOCK_CASE;
const slices = ['ios-arm64', 'ios-arm64-simulator', 'macos-arm64'];
const write = (p, s) => {fs.mkdirSync(path.dirname(p), {recursive:true}); fs.writeFileSync(p, s);};
if (tool === 'xcodebuild') {
  if (args[0] === '-version') {
    console.log('Xcode fixture\nBuild version ' + env.MOCK_XCODE);
  } else {
    const out = args[args.indexOf('-output') + 1];
    const count = fs.existsSync(env.MOCK_COUNT) ? Number(fs.readFileSync(env.MOCK_COUNT)) + 1 : 1;
    write(env.MOCK_COUNT, String(count));
    const libs = args.flatMap((a, i) => a === '-library' ? [args[i+1]] : []);
    const headers = args[args.indexOf('-headers')+1];
    slices.forEach((slice, i) => {
      const lib = path.join(out, slice, 'liblavasec_wireguard_core.a');
      write(lib, fs.readFileSync(libs[i]));
      write(path.join(out, slice, 'Headers/lavasec_wireguard_core.h'), fs.readFileSync(path.join(headers, 'lavasec_wireguard_core.h')));
      if (mode === 'nondeterministic') fs.appendFileSync(lib, '\n' + count);
    });
    write(path.join(out, 'Info.plist'), JSON.stringify({AvailableLibraries:
      (count % 2 ? slices : [...slices].reverse()).map(LibraryIdentifier => ({LibraryIdentifier}))}));
    if (mode === 'unexpected') write(path.join(out, 'unverified.txt'), 'unexpected');
    if (mode === 'symlink') fs.symlinkSync(env.MOCK_COUNT, path.join(out, 'linked-file'));
    if (mode === 'missing-slice') fs.rmSync(path.join(out, 'macos-arm64'), {recursive:true});
    if (mode === 'output-race') write(path.join(env.MOCK_OUTPUT, 'keep.txt'), 'concurrent output');
    if (mode === 'output-parent-race') fs.symlinkSync(env.MOCK_PARENT_TARGET, env.MOCK_OUTPUT_PARENT);
  }
} else throw Error(tool);
`;

const shellCompiler = String.raw`#!/bin/bash
set -euo pipefail
tool="$(basename "$0")"
case "$tool" in
  rustup)
    if [ "$1" = which ]; then printf '%s/%s\n' "$(dirname "$0")" "$2"; fi
    if [ "$*" = 'target list --installed' ]; then
      printf '%s\n' aarch64-apple-ios aarch64-apple-ios-sim aarch64-apple-darwin
    fi ;;
  rustc)
    if [ "$1" = --print ]; then echo "$HOME/sysroot"; else echo 'rustc fixture'; fi ;;
  cargo)
    [ "$1 $2 $3 $4" = 'build --locked --release --target' ]
    printf '%s\n' "$CARGO_TARGET_DIR" >> "$MOCK_LOG"
    # Model Cargo's encoded argument boundary and the pinned cc crate's
    # shell-escaped CFLAGS mode, rather than accepting a malformed flag string.
    python3 - "$MOCK_FLAGS" <<'PYEOF'
import json, os, shlex, sys
assert os.environ['CC_SHELL_ESCAPED_FLAGS'] == '1'
with open(sys.argv[1], 'a') as output:
    output.write(json.dumps({'rust': os.environ['CARGO_ENCODED_RUSTFLAGS'].split('\x1f'),
                             'c': shlex.split(os.environ['CFLAGS']),
                             'scratch': os.path.dirname(os.environ['CARGO_TARGET_DIR'])}) + '\n')
PYEOF
    [ "$MOCK_CASE" != cargo-fails ] || exit 42
    dir="$CARGO_TARGET_DIR/$5/release"; mkdir -p "$dir"
    printf '%s:%s' "$MOCK_XCODE" "$5" > "$dir/liblavasec_wireguard_core.a"
    if [ "$MOCK_CASE" = path-leak ]; then printf '\n%s' "$HOME" >> "$dir/liblavasec_wireguard_core.a"; fi ;;
  plutil) cp "$5" "$4" ;;
  xcrun)
    if [ "$1" = clang ]; then echo 'Apple clang fixture'; else
      [ "$MOCK_CASE" != sdk-fails ] || exit 1
      echo 'fixture-sdk'
    fi ;;
esac
`;

function fixture(t, spaced = false) {
  const dir = realpathSync(mkdtempSync(path.join(tmpdir(), spaced ? 'wg portable ' : 'wg-portable-')));
  t.after(() => rmSync(dir, {recursive:true, force:true}));
  const write = (p, s, options) => {mkdirSync(path.dirname(p), {recursive:true}); writeFileSync(p, s, options);};
  for (const script of ['build-wireguard-core.sh', 'check-wireguard-core-drift.sh']) {
    write(path.join(dir, 'scripts', script), readFileSync(path.join(root, 'scripts', script)));
  }
  const build = path.join(dir, 'ThirdParty/wireguard-core/build');
  write(path.join(build, archive), 'historical compiler bytes');
  write(path.join(build, 'BUILD-TOOLCHAIN.txt'), 'xcode-build: historical\n');
  write(path.join(dir, 'ThirdParty/wireguard-core/include/lavasec_wireguard_core.h'), 'fixture ABI\n');
  for (const tool of ['cargo', 'rustup', 'rustc', 'xcodebuild', 'xcrun', 'plutil']) {
    write(path.join(dir, 'bin', tool), tool === 'xcodebuild' ? compiler : shellCompiler, {mode:0o755});
  }
  const temporary = path.join(dir, spaced ? 'temporary builds' : 'tmp');
  mkdirSync(temporary);
  const env = {...process.env, PATH:`${dir}/bin:${process.env.PATH}`,
    HOME:path.join(dir, spaced ? "home's [1]" : 'home[1]'), CARGO_HOME:path.join(dir, spaced ? 'cargo home' : 'cargo'),
    TMPDIR:temporary, MOCK_XCODE:'current-compiler', MOCK_CASE:'',
    MOCK_COUNT:path.join(dir, 'packager-count'), MOCK_LOG:path.join(dir, 'cargo-calls'),
    MOCK_FLAGS:path.join(dir, 'compiler-flags'),
    GITHUB_PATH:path.join(dir, 'github-path'), CARGO_ENCODED_RUSTFLAGS:'', RUSTFLAGS:'', CFLAGS:''};
  const run = (script = 'check-wireguard-core-drift.sh', extraEnv = {}, args = []) => spawnSync('bash',
    [path.join(dir, 'scripts', script), ...args], {cwd:dir, env:{...env, ...extraEnv}, encoding:'utf8', timeout:60000});
  return {dir, build, env, run};
}

for (const version of ['first-host-compiler', 'upgraded-host-compiler']) {
  test(`historical bytes do not block ${version}; both independent builds consume current source`, t => {
    const f = fixture(t);
    const result = f.run(undefined, {MOCK_XCODE:version});
    assert.equal(result.status, 0, result.stdout + result.stderr);
    assert.equal(readFileSync(path.join(f.build, archive), 'utf8'), `${version}:aarch64-apple-darwin`);
    assert.match(readFileSync(path.join(f.build, 'BUILD-TOOLCHAIN.txt'), 'utf8'), new RegExp(version));
    const calls = readFileSync(f.env.MOCK_LOG, 'utf8').trim().split('\n');
    assert.equal(calls.length, 6);
    assert.equal(new Set(calls).size, 2, 'rebuilds must not reuse Cargo outputs');
    // Apple's strings launcher may also cache xcrun_db here; only our builds own cleanup.
    assert.deepEqual(readdirSync(path.join(f.dir, 'tmp')).filter(name => name.startsWith('lavasec-wireguard')), [], 'temporary builds must be cleaned');
  });
}

test('consumer build replaces the snapshot only after a successful source build', t => {
  const f = fixture(t);
  const result = f.run('build-wireguard-core.sh');
  assert.equal(result.status, 0, result.stdout + result.stderr);
  assert.equal(readFileSync(path.join(f.build, archive), 'utf8'), 'current-compiler:aarch64-apple-darwin');
});

for (const encoded of [false, true]) {
  test(`space-containing paths preserve compiler argument boundaries with ${encoded ? 'encoded' : 'ordinary'} caller flags`, t => {
    const f = fixture(t, true);
    const callerRust = encoded ? ['--remap-path-prefix=/caller path=/caller'] : ['-C', 'debuginfo=0'];
    const callerC = encoded ? ['-DUSER=two words'] : ['-DUSER=1'];
    const result = f.run('build-wireguard-core.sh', {
      CARGO_ENCODED_RUSTFLAGS: encoded ? callerRust.join('\x1f') : undefined,
      RUSTFLAGS: encoded ? '--ignored-by-cargo' : callerRust.join(' '),
      CFLAGS: encoded ? "-DUSER='two words'" : callerC.join(' '),
      CC_SHELL_ESCAPED_FLAGS: encoded ? '1' : '0',
    });
    assert.equal(result.status, 0, result.stdout + result.stderr);
    const calls = readFileSync(f.env.MOCK_FLAGS, 'utf8').trim().split('\n').map(line => JSON.parse(line));
    assert.equal(calls.length, 3, 'all shipped targets must receive the mappings');
    const crate = path.join(f.dir, 'ThirdParty/wireguard-core');
    for (const call of calls) {
      assert.deepEqual(call.rust, [...callerRust,
        `--remap-path-prefix=${crate}=/lavasec-wireguard-core`,
        `--remap-path-prefix=${f.env.CARGO_HOME}=/cargo`,
        `--remap-path-prefix=${f.env.HOME}/sysroot=/rustc`,
        `--remap-path-prefix=${call.scratch}=/wireguard-build`,
      ]);
      assert.deepEqual(call.c, [...callerC,
        `-ffile-prefix-map=${f.env.CARGO_HOME}=/cargo`,
        `-ffile-prefix-map=${crate}=/lavasec-wireguard-core`,
        `-ffile-prefix-map=${call.scratch}=/wireguard-build`,
      ]);
    }
    assert.deepEqual(readdirSync(f.env.TMPDIR).filter(name => name.startsWith('lavasec-wireguard')), []);
  });
}

for (const [mode, error] of [
  ['nondeterministic', /clean builds differ/],
  ['unexpected', /unexpected WireGuard artifact contents/],
  ['missing-slice', /unexpected WireGuard artifact contents/],
  ['symlink', /non-regular entry/],
  ['path-leak', /absolute build path embedded/],
  ['cargo-fails', null],
  ['sdk-fails', null],
]) {
  test(`${mode} fails without publishing unverified output`, t => {
    const f = fixture(t);
    const result = f.run(undefined, {MOCK_CASE:mode});
    assert.notEqual(result.status, 0, result.stdout + result.stderr);
    if (error) assert.match(result.stderr, error);
    assert.equal(readFileSync(path.join(f.build, archive), 'utf8'), 'historical compiler bytes');
    // Apple's strings launcher may also cache xcrun_db here; only our builds own cleanup.
    assert.deepEqual(readdirSync(path.join(f.dir, 'tmp')).filter(name => name.startsWith('lavasec-wireguard')), []);
  });
}

test('explicit output is isolated and cannot overwrite an existing directory', t => {
  const f = fixture(t, true);
  const output = path.join(f.dir, 'new output parent', 'isolated output');
  const result = f.run('build-wireguard-core.sh', {}, ['--output', output]);
  assert.equal(result.status, 0, result.stdout + result.stderr);
  assert.equal(readFileSync(path.join(f.build, archive), 'utf8'), 'historical compiler bytes');
  assert.ok(existsSync(path.join(output, archive)));
  assert.notEqual(f.run('build-wireguard-core.sh', {}, ['--output', output]).status, 0);
});

test('an unresolved parent traversal cannot delete an existing explicit output', t => {
  const f = fixture(t);
  const existing = path.join(f.dir, 'existing');
  mkdirSync(existing);
  writeFileSync(path.join(existing, 'keep.txt'), 'existing output');
  // path.join would normalize away the missing component that hid the existing
  // destination from the original shell existence check.
  const output = `${f.dir}/missing/../existing`;
  const result = f.run('build-wireguard-core.sh', {}, ['--output', output]);
  assert.notEqual(result.status, 0, result.stdout + result.stderr);
  assert.match(result.stderr, /explicit output already exists/);
  assert.equal(readFileSync(path.join(existing, 'keep.txt'), 'utf8'), 'existing output');
  assert.equal(existsSync(path.join(f.dir, 'missing')), false);
  assert.equal(existsSync(f.env.MOCK_LOG), false, 'Reject the hidden destination before compiling.');
});

test('an explicit output created during compilation is preserved', t => {
  const f = fixture(t);
  const output = path.join(f.dir, 'concurrent-output');
  const result = f.run('build-wireguard-core.sh', {MOCK_CASE:'output-race', MOCK_OUTPUT:output}, ['--output', output]);
  assert.notEqual(result.status, 0, result.stdout + result.stderr);
  assert.match(result.stderr, /explicit output appeared during the build/);
  assert.equal(readFileSync(path.join(output, 'keep.txt'), 'utf8'), 'concurrent output');
  assert.deepEqual(readdirSync(output), ['keep.txt']);
  assert.equal(readFileSync(path.join(f.build, archive), 'utf8'), 'historical compiler bytes');
  assert.deepEqual(readdirSync(f.dir).filter(name => name.startsWith('.lavasec-wireguard-publish-')), []);
});

test('an explicit output parent replaced by a symlink cannot redirect publication', t => {
  const f = fixture(t);
  const target = path.join(f.dir, 'other-parent');
  mkdirSync(path.join(target, 'isolated'), {recursive:true});
  writeFileSync(path.join(target, 'isolated/keep.txt'), 'unrelated data');
  const parent = path.join(f.dir, 'future-parent');
  const output = path.join(parent, 'isolated');
  const result = f.run('build-wireguard-core.sh', {
    MOCK_CASE:'output-parent-race', MOCK_PARENT_TARGET:target, MOCK_OUTPUT_PARENT:parent,
  }, ['--output', output]);
  assert.notEqual(result.status, 0, result.stdout + result.stderr);
  assert.match(result.stderr, /explicit output parent changed during the build/);
  assert.equal(readFileSync(path.join(target, 'isolated/keep.txt'), 'utf8'), 'unrelated data');
  assert.deepEqual(readdirSync(path.join(target, 'isolated')), ['keep.txt']);
});

test('app/release preparation and Swift CI build the artifact before consumers run', () => {
  const prep = readFileSync(path.join(root, 'ReactNative/scripts/prepare-full-app.sh'), 'utf8');
  const build = prep.indexOf('bash ../scripts/build-wireguard-core.sh');
  const notices = prep.indexOf('node ../scripts/generate-wireguard-core-notices.mjs --check');
  const generate = prep.indexOf('ruby native-app/generate-project.rb');
  assert.ok(build >= 0, 'App preparation must build the WireGuard artifact.');
  assert.ok(notices >= 0, 'App preparation must check source-built notices.');
  assert.ok(generate >= 0, 'App preparation must generate the native project.');
  assert.ok(build < notices && notices < generate, 'Source and notices must pass before project generation.');
  assert.match(prep, /set -euo pipefail/);
  const workflow = readFileSync(path.join(root, '.github/workflows/ios.yml'), 'utf8').split('  swift-package-tests:')[1].split('  ios-simulator-build:')[0];
  assert.match(workflow, /ci\/run-with-maintenance-lock\.sh -- bash scripts\/build-wireguard-core\.sh/);
  const packageBuild = workflow.indexOf('scripts/build-wireguard-core.sh');
  const packageTests = workflow.indexOf('cmd=(swift test');
  assert.ok(packageBuild >= 0, 'Swift CI must build the WireGuard artifact.');
  assert.ok(packageTests >= 0, 'Swift CI must execute the package tests.');
  assert.ok(packageBuild < packageTests, 'Source compilation must precede Swift package tests.');
});
