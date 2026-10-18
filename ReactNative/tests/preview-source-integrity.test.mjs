import assert from 'node:assert/strict';
import {execFileSync, spawnSync} from 'node:child_process';
import {chmodSync, copyFileSync, mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {dirname, join} from 'node:path';
import test from 'node:test';

const artifact = 'ThirdParty/wireguard-core/build';
const archive = `${artifact}/LavaSecWGCore.xcframework/ios-arm64/liblavasec_wireguard_core.a`;
function fixture(t) {
  const temporary = mkdtempSync(join(tmpdir(), 'lava-preview-source-'));
  t.after(() => rmSync(temporary, {recursive: true, force: true}));
  const root = join(temporary, 'source');
  const manifest = join(temporary, 'evidence/wireguard-artifact-manifest.json');
  mkdirSync(join(root, 'ReactNative/scripts'), {recursive: true});
  copyFileSync(new URL('../scripts/verify-preview-source.py', import.meta.url), join(root, 'ReactNative/scripts/verify-preview-source.py'));
  const write = (path, contents) => {mkdirSync(dirname(join(root, path)), {recursive: true}); writeFileSync(join(root, path), contents);};
  write('.gitignore', `${artifact}/\n`);
  write('Sources/Client.swift', 'struct Client {}\n');
  write(`${artifact}/BUILD-TOOLCHAIN.txt`, 'historical toolchain\n');
  write(`${artifact}/LavaSecWGCore.xcframework/Info.plist`, 'framework membership\n');
  for (const platform of ['ios-arm64', 'ios-arm64-simulator', 'macos-arm64']) {
    for (const path of ['Headers/lavasec_wireguard_core.h', 'liblavasec_wireguard_core.a']) {
      write(`${artifact}/LavaSecWGCore.xcframework/${platform}/${path}`, `historical ${platform} ${path}\n`);
    }
  }
  const git = (...args) => execFileSync('git', args, {cwd: root, encoding: 'utf8'}).trim();
  git('init', '-q');
  git('add', '-A');
  git('add', '-f', artifact);
  git('-c', 'user.name=Preview Fixture', '-c', 'user.email=fixture@example.com', 'commit', '-qm', 'immutable preview source');
  const revision = git('rev-parse', 'HEAD');
  const run = (command, ...args) => spawnSync('python3', [join(root, 'ReactNative/scripts/verify-preview-source.py'), command, ...args], {cwd: root, encoding: 'utf8', timeout: 30000});
  const capture = () => {
    write(`${artifact}/BUILD-TOOLCHAIN.txt`, 'fresh rustc, clang, Xcode and SDK metadata\n');
    write(archive, 'fresh source-built engine bytes\n');
    const result = run('capture-engine', manifest);
    assert.equal(result.status, 0, result.stderr);
  };
  return {root, manifest, revision, write, git, run, capture};
}

test('fresh preview source stays immutable while exact prepared engine bytes are accepted', t => {
  const f = fixture(t);
  assert.equal(f.run('verify-clean', f.revision).status, 0);
  f.capture();
  assert.notEqual(f.run('verify-clean', f.revision).status, 0, 'Preparation really dirties the historical snapshot.');
  const receipt = JSON.parse(readFileSync(f.manifest, 'utf8'));
  assert.equal(Object.keys(receipt.files).length, 8);
  assert.ok(receipt.files[archive].sha256);
  const verified = f.run('verify-prepared', f.revision, f.manifest);
  assert.equal(verified.status, 0, verified.stderr);
});

for (const [name, mutate] of [
  ['tracked source changes', f => f.write('Sources/Client.swift', 'struct Changed {}\n')],
  ['untracked source additions', f => f.write('Sources/Unexpected.swift', 'struct Unexpected {}\n')],
  ['changed generated archive bytes', f => f.write(archive, 'substituted archive\n')],
  ['changed generated file permissions', f => chmodSync(join(f.root, archive), 0o755)],
  ['missing generated outputs', f => rmSync(join(f.root, archive))],
  ['additional ignored generated outputs', f => f.write(`${artifact}/unapproved.a`, 'unapproved archive\n')],
  ['generated output symlinks', f => {rmSync(join(f.root, archive)); symlinkSync(join(f.root, 'Sources/Client.swift'), join(f.root, archive));}],
  ['staged generated outputs', f => f.git('add', '-f', artifact)],
  ['a different source commit', f => {f.git('add', '-f', artifact); f.git('-c', 'user.name=Preview Fixture', '-c', 'user.email=fixture@example.com', 'commit', '-qm', 'different source');}],
]) {
  test(`prepared preview rejects ${name}`, t => {
    const f = fixture(t);
    f.capture();
    mutate(f);
    assert.notEqual(f.run('verify-prepared', f.revision, f.manifest).status, 0);
  });
}

test('prepared preview requires a valid artifact manifest rather than falling back to a clean snapshot', t => {
  const f = fixture(t);
  assert.notEqual(f.run('verify-prepared', f.revision, f.manifest).status, 0);
  f.capture();
  writeFileSync(f.manifest, '{}');
  assert.notEqual(f.run('verify-prepared', f.revision, f.manifest).status, 0);
});

test('manifest capture rejects symlinked or unexpected engine outputs', t => {
  const f = fixture(t);
  f.write(`${artifact}/unexpected.a`, 'not an approved generated output\n');
  assert.notEqual(f.run('capture-engine', f.manifest).status, 0);
  rmSync(join(f.root, `${artifact}/unexpected.a`));
  rmSync(join(f.root, archive));
  symlinkSync(join(f.root, 'Sources/Client.swift'), join(f.root, archive));
  assert.notEqual(f.run('capture-engine', f.manifest).status, 0);
});
