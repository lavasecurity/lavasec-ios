import {posix} from 'node:path';
import assert from 'node:assert/strict';
import {existsSync, readFileSync} from 'node:fs';
import {createRequire} from 'node:module';
import {fileURLToPath} from 'node:url';
import test from 'node:test';
import {validateReviewSpec, validateGeneratedProjects, reviewSources, testSource} from '../scripts/review-host-policy.mjs';
const spec = JSON.parse(readFileSync(new URL('../ios/project.json', import.meta.url)));
const policy = JSON.parse(readFileSync(new URL('../ios/native-dependencies.json', import.meta.url)));

test('installed codegen discovers both card ports without a platform suffix or duplicate alias', () => {
  const require = createRequire(import.meta.url);
  const {combineSchemasInFileList} = require('@react-native/codegen/lib/cli/combine/combine-js-to-schema');
  const names = ['LavaShareCardSurfaceNativeComponent', 'LavaShareQrNativeComponent'];
  const files = names.map(name => fileURLToPath(new URL(`../specs/${name}.ts`, import.meta.url)));
  for (const name of names) assert.equal(existsSync(new URL(`../specs/${name}.ios.ts`, import.meta.url)), false);
  // Match the installed RN artifact executor, which does not forward an iOS platform string.
  // Parse in memory: no generated headers or native project files are written by this test.
  const schema = combineSchemasInFileList(files);
  const components = Object.assign({}, ...Object.values(schema.modules).map(module => module.components ?? {}));
  assert.deepEqual(Object.keys(components).sort(), ['LavaShareCardSurface', 'LavaShareQr']);
  const propTypes = component => Object.fromEntries(components[component].props.map(prop => [prop.name, prop.typeAnnotation.type]));
  assert.deepEqual(propTypes('LavaShareCardSurface'), {token: 'StringTypeAnnotation', payload: 'StringTypeAnnotation', ready: 'BooleanTypeAnnotation'});
  assert.deepEqual(propTypes('LavaShareQr'), {payload: 'StringTypeAnnotation', moduleCount: 'Int32TypeAnnotation'});
});

test('classifies the review app and UI test without changing production target policy', () => {
  validateReviewSpec(spec);
});

for (const source of ['LavaSecUIReview/LavaShareCardSurfaceView.h',
                      'LavaSecUIReview/LavaShareCardSurfaceView.mm',
                      'LavaSecUIReview/LavaShareQrView.h',
                      'LavaSecUIReview/LavaShareQrView.mm',
                      'LavaSecUIReview/LavaShareCardCapture.swift']) {
  test(`pins the approved review card port exactly once: ${source}`, () => {
    assert.equal(reviewSources.filter(path => path === source).length, 1);
    assert.equal(spec.targets.LavaSecUIReview.sources.filter(entry => entry.path === source).length, 1);
    const missing = structuredClone(spec);
    missing.targets.LavaSecUIReview.sources = missing.targets.LavaSecUIReview.sources.filter(entry => entry.path !== source);
    assert.throws(() => validateReviewSpec(missing));
    const duplicate = structuredClone(spec);
    duplicate.targets.LavaSecUIReview.sources.push({path: source});
    assert.throws(() => validateReviewSpec(duplicate));
    if (/\.(swift|mm)$/.test(source)) {
      const missingCompiled = graph();
      missingCompiled[0].targets[0].sources = missingCompiled[0].targets[0].sources.filter(path => path !== `ios/${source}`);
      assert.throws(() => validateGeneratedProjects(missingCompiled, policy));
    }
  });
}

test('the isolated scaffold source closure includes each canonical setup row and surface owner once',()=>{
  const swift=reviewSources.filter(path=>path.endsWith('.swift'))
    .map(path=>readFileSync(new URL(`../ios/${path}`,import.meta.url),'utf8')).join('\n');
  for(const type of ['LavaCondensedRowButtonStyle','LavaPlainCard','LavaSelectableRow','LavaSelectionAccessory']) {
    assert.equal([...swift.matchAll(new RegExp(`struct ${type}(?:<|:)`,'g'))].length,1,
      `${type} must be compiled from its canonical shared owner, not missing or duplicated in a fixture.`);
  }
  assert.ok(!reviewSources.includes('../../LavaSecApp/LavaDesignSystem/LavaComponents.swift'),
    'The review target only needs shared low-level atoms, not the app composition dependency tree.');
});

test('rejects extra targets, production identities, package aliases, hooks, entitlements, and scheme actions', () => {
  for (const mutate of [
    value => { value.targets.LavaSecTunnel = structuredClone(value.targets.LavaSecUIReview); },
    value => { value.targets.LavaSecUIReview.settings.base.PRODUCT_BUNDLE_IDENTIFIER = 'com.lavasecurity.lavasec'; },
    value => { value.targets.LavaSecUIReview.settings.configs.QAReview.PRODUCT_BUNDLE_IDENTIFIER = 'com.lavasec.app'; },
    value => { value.targets.LavaSecUIReview.settings.configs.QAReview.PROVISIONING_PROFILE_SPECIFIER = 'unreviewed-profile'; },
    value => { value.settings.base.CODE_SIGNING_ALLOWED = true; },
    value => { value.packages.Other = {path: '../..'}; },
    value => { value.packages.LavaSecPackage.path = '../../Other'; },
    value => { value.options.postGenCommand = 'echo surprise'; },
    value => { value.targets.LavaSecUIReview.preBuildScripts = [{script: 'echo surprise'}]; },
    value => { value.targets.LavaSecUIReview.settings.base.CODE_SIGN_ENTITLEMENTS = '../../LavaSecApp/LavaSecApp.entitlements'; },
    value => { value.schemes.LavaSecUIReview.run.preActions = [{script: 'echo surprise'}]; },
    value => { value.targets.LavaSecUIReview.dependencies.push({target: 'LavaSecTunnel'}); },
    value => { value.targets.LavaSecUIReview.dependencies[0] = {sdk: 'Unapproved.framework'}; },
    value => { value.targets.LavaSecUIReview.dependencies[0] = {framework: 'AVFAudio.framework'}; },
    value => { value.targets.LavaSecUIReview.sources.push({path: '../../LavaSecTunnel'}); },
  ]) {
    const changed = structuredClone(spec);
    mutate(changed);
    assert.throws(() => validateReviewSpec(changed));
  }
});

function graph() {
  const target = (name, type, sources = [], resources = [], products = [], dependencies = []) =>
    ({name, type, sources, resources, products, dependencies, scripts: [], entitlements: [], rules: [], frameworks: [], phases: []});
  const projects = [
    {project: 'ios/LavaSecUIReview.xcodeproj', packages: [{type: 'XCLocalSwiftPackageReference', path: '../..', url: null}], targets: [
      target('LavaSecUIReview', 'com.apple.product-type.application',
        reviewSources.filter(path => /\.(swift|m|mm)$/.test(path)).map(path => posix.normalize(path.startsWith('../../') ? path.slice(3) : `ios/${path}`)).sort(),
        ['.artifacts/LavaUIReview.js', 'assets/ExploreNarration', 'ios/Assets.xcassets', 'ios/PrivacyInfo.xcprivacy'], ['LavaSecAppServices', 'LavaSecKit', 'LavaSecPresentation']),
      target('LavaSecUIReviewUITests', 'com.apple.product-type.bundle.ui-testing', [`ios/${testSource}`], [], [], ['LavaSecUIReview']),
    ]},
    {project: 'ios/Pods/Pods.xcodeproj', packages: [], targets: Object.entries(policy.podTargets).map(([name, type]) => target(name, type))},
  ];
  projects[0].targets[0].frameworks = [{path: 'System/Library/Frameworks/AVFAudio.framework', tree: 'SDKROOT'}, {product: 'LavaSecAppServices'}, {product: 'LavaSecKit'}, {product: 'LavaSecPresentation'}, {path: 'libPods-LavaSecUIReview.a', tree: 'BUILT_PRODUCTS_DIR'}];
  for (const target of projects[1].targets) target.frameworks = policy.podFrameworks[target.name] ?? [];
  for (const script of policy.scripts) {
    const {project, target: name, ...phase} = script;
    projects.find(item => item.project === project).targets.find(item => item.name === name).scripts.push(phase);
  }
  return projects;
}

test('accepts the inspected dependency graph and rejects generated privilege or source changes', () => {
  validateGeneratedProjects(graph(), policy);
  for (const mutate of [
    value => { value[0].packages[0].path = '../../../Other'; },
    value => { value[0].targets[0].frameworks.push({path: 'Unexpected.a', tree: 'BUILT_PRODUCTS_DIR'}); },
    value => { value[0].targets[0].frameworks[0].tree = 'BUILT_PRODUCTS_DIR'; },
    value => { value[0].targets[0].frameworks[0].path = 'AVFAudio.framework'; },
    value => { value[0].targets[0].phases.push('PBXCopyFilesBuildPhase'); },
    value => { value[0].targets[0].products.push('LavaSecChainedUpstream'); },
    value => { value[0].targets[0].sources.push('ios/Unexpected.swift'); },
    value => { value[1].targets[0].sources.push('../LavaSecTunnel/PacketTunnelProvider.swift'); },
    value => { value[1].targets[0].rules.push({script: 'echo surprise'}); },
    value => { value[1].targets[0].entitlements.push('VPN.entitlements'); },
    value => { value[1].targets[0].type = 'com.apple.product-type.app-extension'; },
    value => { value[0].targets[0].scripts[0].body += '\necho surprise'; },
    value => { value[1].targets.push(structuredClone(value[1].targets[0])); },
  ]) {
    const changed = graph();
    mutate(changed);
    assert.throws(() => validateGeneratedProjects(changed, policy));
  }
});
