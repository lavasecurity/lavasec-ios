import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import test from 'node:test';

// Exercise the actual preparation script with isolated native-tool fixtures.
// Production project hashes and shell failure propagation remain real.
function prepare(t, {nativeOnly = false, failure = '', mutateProject = false, args} = {}) {
  const root = realpathSync(mkdtempSync(join(tmpdir(), 'lava-native-preparation-')));
  t.after(() => rmSync(root, {recursive: true, force: true}));
  const app = join(root, 'ReactNative');
  const bin = join(root, 'bin');
  const trace = join(root, 'trace.jsonl');
  const build = join(root, 'build');
  const evidence = join(root, 'evidence');
  const cargoHome = join(root, 'cargo-home');
  const cargoBin = join(root, 'pinned-toolchain/bin');
  mkdirSync(join(app, 'scripts'), {recursive: true});
  mkdirSync(join(app, 'native-app'));
  mkdirSync(join(root, 'LavaSec.xcodeproj'));
  mkdirSync(join(root, 'scripts'));
  mkdirSync(join(root, 'ThirdParty/wireguard-core'), {recursive: true});
  mkdirSync(join(cargoHome, 'bin'), {recursive: true});
  mkdirSync(cargoBin, {recursive: true});
  mkdirSync(bin);
  mkdirSync(evidence);
  writeFileSync(join(root, 'project.yml'), 'production project specification\n');
  writeFileSync(join(root, 'LavaSec.xcodeproj/project.pbxproj'), 'production project\n');
  writeFileSync(join(evidence, 'javascript-tests.log'), 'stale passing tests\n');
  writeFileSync(join(evidence, 'story-columns-layout.log'), 'stale passing layout\n');
  copyFileSync(new URL('../scripts/prepare-full-app.sh', import.meta.url), join(app, 'scripts/prepare-full-app.sh'));
  const toolPaths = ['npm', 'bundle', 'xcodegen', 'ruby', 'python3', 'node'].map(tool => join(bin, tool));
  toolPaths.push(join(root, 'scripts/build-wireguard-core.sh'), join(cargoHome, 'bin/rustup'), join(cargoBin, 'cargo'));
  for (const toolPath of toolPaths) {
    writeFileSync(toolPath, `#!/bin/bash
set -eu
tool=\${0##*/}
printf '%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\n' "$tool" "$*" "$PWD" "\${LAVA_FULL_APP_GRAPH:-}" "$BUNDLE_PATH" "$BUNDLE_FROZEN" "$PATH" >> "$LAVA_PREPARATION_TRACE"
stage="$tool $*"
if [ -n "$LAVA_PREPARATION_FAILURE" ]; then
  case "$stage" in "$LAVA_PREPARATION_FAILURE"|"$LAVA_PREPARATION_FAILURE "*) exit 42 ;; esac
fi
if [ "$stage" = 'npm test' ]; then printf 'JavaScript and Yoga layout validation passed\\n'; fi
if [ "$tool" = xcodegen ]; then printf 'Version: 2.45.4\\n'; fi
if [ "$tool" = build-wireguard-core.sh ]; then printf 'Fresh source engine built\\n'; fi
if [ "$stage" = 'rustup which cargo' ]; then printf '%s\\n' "$LAVA_PREPARATION_CARGO"; fi
if [ "$tool" = ruby ] && [ "$LAVA_PREPARATION_MUTATE_PROJECT" = true ]; then
  printf 'unapproved production mutation\\n' > ../project.yml
fi
if [ "$stage" = 'bundle exec ruby scripts/inspect-full-app.rb' ]; then printf '{"reviewedNativeGraph":true}\\n'; fi
`, {mode: 0o755});
  }
  const result = spawnSync('bash', [join(app, 'scripts/prepare-full-app.sh'),
    ...(args ?? [...(nativeOnly ? ['--native-only'] : []), build, evidence])], {
    encoding: 'utf8', timeout: 120000,
    env: {...process.env, PATH: `${bin}:${process.env.PATH}`, CARGO_HOME: cargoHome,
      LAVA_PREPARATION_CARGO: join(cargoBin, 'cargo'),
      LAVA_PREPARATION_TRACE: trace, LAVA_PREPARATION_FAILURE: failure,
      LAVA_PREPARATION_MUTATE_PROJECT: String(mutateProject)},
  });
  assert.ifError(result.error);
  const calls = existsSync(trace) ? readFileSync(trace, 'utf8').trim().split('\n').map(line => {
    const [tool, argumentsString, cwd, graph, bundlePath, frozen, commandPath] = line.split('\t');
    return {tool, args: argumentsString ? argumentsString.split(' ') : [], cwd, graph, bundlePath, frozen, commandPath};
  }) : [];
  return {result, calls, build, evidence, app, cargoBin};
}

const stage = call => `${call.tool} ${call.args.join(' ')}`.trimEnd();

function assertSourceEnginePrepared({calls, evidence, app, cargoBin}) {
  const stages = calls.map(stage);
  const engine = stages.indexOf('build-wireguard-core.sh');
  const rustup = stages.indexOf('rustup which cargo');
  const notices = stages.indexOf('node ../scripts/generate-wireguard-core-notices.mjs --check');
  const dependencies = stages.indexOf('npm ci --ignore-scripts --no-audit --no-fund');
  assert.ok(engine >= 0 && rustup > engine && notices > rustup && dependencies > notices,
    'Build the source engine and verify its notices with the pinned toolchain before installing RN dependencies.');
  assert.equal(calls[rustup].cwd, join(app, '../ThirdParty/wireguard-core'));
  assert.equal(calls[notices].commandPath.split(':')[0], cargoBin,
    'The notices gate must resolve Cargo from rustup, independently of a runner default.');
  assert.match(readFileSync(join(evidence, 'wireguard-build.log'), 'utf8'), /Fresh source engine built/);
}

test('native-only preparation retains source engine, bundle, Pods, notices and generated graph validation', t => {
  const prepared = prepare(t, {nativeOnly: true});
  const {result, calls, build, evidence, app} = prepared;
  assert.equal(result.status, 0, result.stderr);
  assertSourceEnginePrepared(prepared);
  const stages = calls.map(stage);
  assert.ok(stages.includes('npm ci --ignore-scripts --no-audit --no-fund'));
  assert.ok(!stages.includes('npm test'), 'Required Linux validation owns the full JS suite in this mode.');
  assert.ok(!stages.includes('node scripts/test-story-columns-layout.mjs'));
  for (const required of [
    'npm run bundle:review', 'bundle install', 'ruby native-app/generate-project.rb',
    'bundle exec pod install --deployment', 'python3 scripts/generate-rn-notices.py --check',
    'bundle exec ruby scripts/inspect-full-app.rb',
    `node scripts/check-full-app.mjs ${join(evidence, 'generated-graph.json')}`,
    'node --test tests/full-app-policy.test.mjs',
  ]) assert.ok(stages.includes(required), `Missing native preparation gate: ${required}`);
  assert.equal(calls.find(call => stage(call) === 'bundle exec pod install --deployment').cwd, join(app, 'native-app'));
  assert.equal(calls.find(call => stage(call) === 'node --test tests/full-app-policy.test.mjs').graph,
    join(evidence, 'generated-graph.json'));
  assert.ok(calls.every(call => call.bundlePath === join(build, 'gems') && call.frozen === 'true'));
  assert.deepEqual(JSON.parse(readFileSync(join(evidence, 'generated-graph.json'))), {reviewedNativeGraph: true});
  assert.ok(!existsSync(join(evidence, 'javascript-tests.log')), 'A skipped suite must not retain stale passing evidence.');
  assert.ok(!existsSync(join(evidence, 'story-columns-layout.log')));
});

test('existing two-path callers retain full JS validation once before bundling', t => {
  const prepared = prepare(t);
  const {result, calls, evidence} = prepared;
  assert.equal(result.status, 0, result.stderr);
  assertSourceEnginePrepared(prepared);
  const stages = calls.map(stage);
  assert.equal(stages.filter(value => value === 'npm test').length, 1);
  assert.ok(stages.indexOf('npm test') < stages.indexOf('npm run bundle:review'));
  assert.ok(!stages.includes('node scripts/test-story-columns-layout.mjs'), 'npm test already includes Yoga layout validation.');
  assert.match(readFileSync(join(evidence, 'javascript-tests.log'), 'utf8'), /JavaScript and Yoga layout validation passed/);
});

test('a failed default JS suite stops preparation before bundling', t => {
  const {result, calls} = prepare(t, {failure: 'npm test'});
  assert.equal(result.status, 42, result.stderr);
  assert.ok(!calls.some(call => stage(call) === 'npm run bundle:review'));
});

for (const failure of ['build-wireguard-core.sh', 'rustup which cargo',
  'node ../scripts/generate-wireguard-core-notices.mjs --check']) {
  test(`native-only preparation stops before npm when ${failure} fails`, t => {
    const {result, calls} = prepare(t, {nativeOnly: true, failure});
    assert.equal(result.status, 42, result.stderr);
    assert.ok(!calls.some(call => call.tool === 'npm'), 'Source engine failures must block all RN preparation.');
  });
}

for (const failure of [
  'npm run bundle:review', 'bundle exec pod install --deployment',
  'python3 scripts/generate-rn-notices.py --check', 'node scripts/check-full-app.mjs',
  'node --test tests/full-app-policy.test.mjs',
]) {
  test(`native-only preparation still blocks on ${failure}`, t => {
    const {result} = prepare(t, {nativeOnly: true, failure});
    assert.equal(result.status, 42, result.stderr);
  });
}

test('native-only preparation detects a production-project mutation', t => {
  const {result} = prepare(t, {nativeOnly: true, mutateProject: true});
  assert.notEqual(result.status, 0, 'The production project byte-stability proof must remain blocking.');
});

for (const args of [[], ['--unknown'], ['--native-only'], ['relative/build', '/absolute/evidence'],
  ['/absolute/build', '/absolute/evidence', '--unknown']]) {
  test(`invalid preparation arguments fail before invoking dependency tools: ${args.join(' ') || '(none)'}`, t => {
    const {result, calls} = prepare(t, {args});
    assert.notEqual(result.status, 0);
    assert.equal(calls.length, 0);
  });
}
