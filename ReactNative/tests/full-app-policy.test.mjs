import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import test from 'node:test';
import {validateFullAppProjects} from '../scripts/full-app-policy.mjs';

// Run after XcodeGen/CocoaPods against their actual graph, including the unchanged
// native reference project. Mutation checks must not use a fabricated project.
const projects = JSON.parse(readFileSync(process.env.LAVA_FULL_APP_GRAPH, 'utf8'));
const policy = JSON.parse(readFileSync(new URL('../ios/native-dependencies.json', import.meta.url)));
const app = p => p[1].targets.find(t => t.name === 'LavaSec');
const hosted = p => p[1].targets.find(t => t.name === 'LavaRNShareCardTests');
const hostedPods = p => p[2].targets.find(t => t.name === 'Pods-LavaRNShareCardTests');
test('accepts the full app graph produced by the pinned toolchain', () => {
  validateFullAppProjects(projects, policy);
});
test('the hosted bundle has an explicit distinct product name in every build configuration', () => {
  for (const config of ['Debug', 'QA', 'Release']) {
    assert.equal(hosted(projects).settings[config].PRODUCT_NAME, 'LavaRNShareCardTests');
  }
});
test('the hosted bundle resolves internal app symbols through its exact test host', () => {
  for (const config of ['Debug', 'QA', 'Release']) {
    assert.equal(hosted(projects).settings[config].BUNDLE_LOADER, '$(TEST_HOST)');
    assert.equal(hosted(projects).settings[config].TEST_HOST, '$(BUILT_PRODUCTS_DIR)/LavaSec.app/LavaSec');
  }
});
test('only the XCTest bundle disables unused supplementary const-value output', () => {
  for (const config of ['Debug', 'QA', 'Release']) {
    assert.equal(hosted(projects).settings[config].SWIFT_ENABLE_EMIT_CONST_VALUES, 'NO');
    assert.equal(app(projects).settings[config].SWIFT_ENABLE_EMIT_CONST_VALUES, undefined);
    assert.ok(app(projects).settings[config].SWIFT_EMIT_CONST_VALUE_PROTOCOLS.includes('AppIntent'));
  }
});
test('the hosted test explicitly links the existing package module imported by its app host', () => {
  assert.deepEqual(hosted(projects).products, ['GoogleSignIn', 'LavaSecKit']);
  assert.deepEqual(hosted(projects).frameworks.filter(entry => entry.product),
    [{product: 'LavaSecKit'}, {product: 'GoogleSignIn'}]);
});
for (const [name, mutate] of [
  ['missing tunnel', p => { p[1].targets = p[1].targets.filter(t => t.name !== 'LavaSecTunnel'); }],
  ['missing native service source', p => { app(p).sources.shift(); }],
  ['fixture entry point', p => { app(p).sources.push('ios/LavaSecUIReview/AppDelegate.swift'); }],
  ['changed QA identity', p => { app(p).settings.QA.PRODUCT_BUNDLE_IDENTIFIER = 'com.lavasec.app'; }],
  ['removed entitlements', p => { app(p).entitlements = []; }],
  ['missing embedded extension', p => { app(p).copies = []; }],
  ['unreviewed shell hook', p => { app(p).scripts.push({script: 'unreviewed'}); }],
  ['missing RN notices', p => { app(p).resources = app(p).resources.filter(r => !r.endsWith('ReactNativeNotices.txt')); }],
  ['extra dependency entitlement', p => { p[2].targets[0].entitlements.push('unexpected.entitlements'); }],
  ['dependency traversal', p => { p[2].targets[0].sources.push('../LavaSecApp/AppViewModel.swift'); }],
  ['unreviewed dependency hook', p => { p[2].targets[0].scripts.push({script: 'unreviewed'}); }],
  ['missing hosted card tests', p => { p[1].targets = p[1].targets.filter(t => t.name !== 'LavaRNShareCardTests'); }],
  ['alternate hosted test application', p => { hosted(p).settings.Debug.TEST_HOST = '$(BUILT_PRODUCTS_DIR)/Fixture.app/Fixture'; }],
  ['missing hosted bundle loader', p => { delete hosted(p).settings.Debug.BUNDLE_LOADER; }],
  ['empty hosted bundle loader', p => { hosted(p).settings.QA.BUNDLE_LOADER = ''; }],
  ['foreign hosted bundle loader', p => { hosted(p).settings.Release.BUNDLE_LOADER = '$(BUILT_PRODUCTS_DIR)/Fixture.app/Fixture'; }],
  ['missing hosted const-output setting', p => { delete hosted(p).settings.Debug.SWIFT_ENABLE_EMIT_CONST_VALUES; }],
  ['enabled unused hosted const outputs', p => { hosted(p).settings.QA.SWIFT_ENABLE_EMIT_CONST_VALUES = 'YES'; }],
  ['empty hosted const-output setting', p => { hosted(p).settings.Release.SWIFT_ENABLE_EMIT_CONST_VALUES = ''; }],
  ['disabled shipping app const outputs', p => { app(p).settings.Debug.SWIFT_ENABLE_EMIT_CONST_VALUES = 'NO'; }],
  ['changed hosted test identity', p => { hosted(p).settings.Release.PRODUCT_BUNDLE_IDENTIFIER = 'com.lavasec.app'; }],
  ['empty hosted test product name', p => { hosted(p).settings.Debug.PRODUCT_NAME = ''; }],
  ['missing hosted test product name', p => { delete hosted(p).settings.QA.PRODUCT_NAME; }],
  ['colliding hosted test product name', p => { hosted(p).settings.Release.PRODUCT_NAME = 'LavaSec'; }],
  ['missing hosted GoogleSignIn product', p => { hosted(p).products = hosted(p).products.filter(product => product !== 'GoogleSignIn'); }],
  ['missing hosted GoogleSignIn module link', p => { hosted(p).frameworks = hosted(p).frameworks.filter(entry => entry.product !== 'GoogleSignIn'); }],
  ['unreviewed hosted package module', p => { hosted(p).frameworks.push({product: 'GoogleSignInSwift'}); }],
  ['fixture source in hosted tests', p => { hosted(p).sources.push('ios/LavaSecUIReview/AppDelegate.swift'); }],
  ['hosted-test entitlement', p => { hosted(p).entitlements.push('unexpected.entitlements'); }],
  ['changed hosted lock-check body', p => { hosted(p).scripts[0].body += '\nunreviewed'; }],
  ['missing hosted-test Pods aggregate', p => { p[2].targets = p[2].targets.filter(t => t.name !== 'Pods-LavaRNShareCardTests'); }],
  ['unreviewed hosted-test Pods dependency', p => { hostedPods(p).dependencies.push('Unreviewed'); }],
  ['executable source in hosted-test Pods aggregate', p => { hostedPods(p).sources.push('native-app/Pods/unreviewed.m'); }],
  ['hosted-test Pods shell hook', p => { hostedPods(p).scripts.push({name: 'unreviewed', shell: '/bin/sh', body: 'unreviewed'}); }],
  ['changed hosted-test Pods deployment', p => { hostedPods(p).settings.Debug.IPHONEOS_DEPLOYMENT_TARGET = '17.0'; }],
]) {
  test(`rejects ${name}`, () => {
    const changed = structuredClone(projects);
    mutate(changed);
    assert.throws(() => validateFullAppProjects(changed, policy));
  });
}
for (const source of ['ios/LavaSecUIReview/LavaShareCardSurfaceView.mm',
                      'ios/LavaSecUIReview/LavaShareQrView.mm',
                      'ios/LavaSecUIReview/LavaShareCardCapture.swift',
                      'native-app/LavaAppShareCard.swift']) {
  test(`rejects missing reviewed card port ${source}`, () => {
    const changed = structuredClone(projects);
    assert.ok(app(changed).sources.includes(source), 'The actual graph must contain the reviewed port before mutation');
    app(changed).sources = app(changed).sources.filter(path => path !== source);
    assert.throws(() => validateFullAppProjects(changed, policy));
  });
}
