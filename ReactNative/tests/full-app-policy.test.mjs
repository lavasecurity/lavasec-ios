import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import test from 'node:test';
import {validateFullAppProjects} from '../scripts/full-app-policy.mjs';

// Run after XcodeGen/CocoaPods against their actual graph, including the unchanged
// native reference project. Mutation checks must not use a fabricated project.
const projects = JSON.parse(readFileSync(process.env.LAVA_FULL_APP_GRAPH, 'utf8'));
const policy = JSON.parse(readFileSync(new URL('../ios/native-dependencies.json', import.meta.url)));
test('accepts the full app graph produced by the pinned toolchain', () => {
  validateFullAppProjects(projects, policy);
});
for (const [name, mutate] of [
  ['missing tunnel', p => { p[1].targets = p[1].targets.filter(t => t.name !== 'LavaSecTunnel'); }],
  ['missing native service source', p => { p[1].targets[0].sources.shift(); }],
  ['fixture entry point', p => { p[1].targets[0].sources.push('ios/LavaSecUIReview/AppDelegate.swift'); }],
  ['changed QA identity', p => { p[1].targets[0].settings.QA.PRODUCT_BUNDLE_IDENTIFIER = 'com.lavasec.app'; }],
  ['removed entitlements', p => { p[1].targets[0].entitlements = []; }],
  ['missing embedded extension', p => { p[1].targets[0].copies = []; }],
  ['unreviewed shell hook', p => { p[1].targets[0].scripts.push({script: 'unreviewed'}); }],
  ['missing RN notices', p => { p[1].targets[0].resources = p[1].targets[0].resources.filter(r => !r.endsWith('ReactNativeNotices.txt')); }],
  ['extra dependency entitlement', p => { p[2].targets[0].entitlements.push('unexpected.entitlements'); }],
  ['dependency traversal', p => { p[2].targets[0].sources.push('../LavaSecApp/AppViewModel.swift'); }],
  ['unreviewed dependency hook', p => { p[2].targets[0].scripts.push({script: 'unreviewed'}); }],
]) {
  test(`rejects ${name}`, () => {
    const changed = structuredClone(projects);
    mutate(changed);
    assert.throws(() => validateFullAppProjects(changed, policy));
  });
}
