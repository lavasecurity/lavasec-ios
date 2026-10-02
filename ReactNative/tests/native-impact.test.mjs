import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {mkdirSync, mkdtempSync, renameSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import test from 'node:test';
import {inspectChange, requiresNativeBuild} from '../../ci/detect-rn-native-build.mjs';

test('screen, component, state and JS test edits retain fast checks without a native rebuild', () => {
  assert.equal(requiresNativeBuild([
    'ReactNative/review/SettingsScreens.tsx', 'ReactNative/src/components.ios.tsx',
    'ReactNative/app/queries.ts', 'ReactNative/gallery/index.ts',
    'ReactNative/tests/native-build-modes.test.mjs', 'docs/review.png', 'README.md',
    'ReactNative/tests/components.test.tsx', 'ReactNative/tests/native-switch-mock.tsx',
  ]), false);
});

for (const file of [
  'ReactNative/specs/LavaSwitchNativeComponent.ts', 'ReactNative/specs/NativeLavaApp.ts',
  'ReactNative/native-app/LavaAppBridge.swift', 'ReactNative/ios/Podfile',
  'ReactNative/native-app/Podfile.lock', 'ReactNative/package.json', 'ReactNative/package-lock.json',
  'ReactNative/Gemfile.lock', 'ReactNative/scripts/prepare-full-app.sh',
  'ReactNative/native-app/generate-project.rb', 'LavaSecApp/AppViewModel.swift',
  'Shared/TunnelConfiguration.swift', 'project.yml', 'Config/Lava.xcconfig',
  '.github/workflows/react-native-ui.yml', 'ci/detect-rn-native-build.mjs',
  'ReactNative/src/Unexpected.swift', 'ReactNative/future/NewSurface.tsx',
  'ReactNative/tests/full-app-policy.test.mjs', 'ReactNative/tests/new-policy.test.mjs',
  'ReactNative/tests/new-policy.test.cjs',
  'ReactNative/tests/unknown-graph-helper.ts',
]) {
  test(`${file} requires the native compile even alongside UI edits`, () => {
    assert.equal(requiresNativeBuild(['ReactNative/review/SettingsScreens.tsx', file]), true);
  });
}

test('unknown/empty changes and a native input beyond thousands of UI files build', () => {
  assert.equal(requiresNativeBuild([]), true);
  assert.equal(requiresNativeBuild([
    ...Array.from({length: 5000}, (_, i) => `ReactNative/src/generated/${i}.ts`),
    'ReactNative/specs/NativeLavaApp.ts',
  ]), true);
});

test('the actual Git diff handles UI pushes, native renames/deletions and unavailable endpoints', t => {
  const cwd = mkdtempSync(join(tmpdir(), 'lava-native-impact-'));
  t.after(() => rmSync(cwd, {recursive: true, force: true}));
  const git = (...args) => execFileSync('git', args, {cwd, encoding: 'utf8'}).trim();
  const write = (path, text) => {mkdirSync(join(cwd, path, '..'), {recursive: true}); writeFileSync(join(cwd, path), text);};
  const commit = () => {git('add', '-A'); git('-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.com', 'commit', '-qm', 'fixture'); return git('rev-parse', 'HEAD');};
  git('init', '-q');
  write('ReactNative/specs/NativeLavaApp.ts', 'export interface Spec {}\n');
  write('ReactNative/src/example.ts', 'export const value = 1;\n');
  const base = commit();
  write('ReactNative/src/example.ts', 'export const value = 2;\n');
  const ui = commit();
  for (const event of ['pull_request', 'push']) assert.equal(inspectChange({event, base, head: ui, cwd}).required, false);
  mkdirSync(join(cwd, 'docs'));
  renameSync(join(cwd, 'ReactNative/specs/NativeLavaApp.ts'), join(cwd, 'docs/former-spec.md'));
  const renamed = commit();
  assert.equal(inspectChange({event: 'push', base: ui, head: renamed, cwd}).required, true);
  for (const event of ['workflow_dispatch', 'unknown']) assert.equal(inspectChange({event, base, head: ui, cwd}).required, true);
  for (const before of ['', 'invalid', '0'.repeat(40), 'f'.repeat(40), ui]) {
    assert.equal(inspectChange({event: 'push', base: before, head: ui, cwd}).required, true);
  }
});
