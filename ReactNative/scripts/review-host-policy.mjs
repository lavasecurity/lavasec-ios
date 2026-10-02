import assert from 'node:assert/strict';
import {posix} from 'node:path';

export const reviewSources = [
  'LavaSecUIReview/AppDelegate.swift', 'LavaSecUIReview/AppearanceBridge.swift',
  'LavaSecUIReview/ReactReviewViewController.swift', 'LavaSecUIReview/LavaAppearanceModule.h',
  'LavaSecUIReview/LavaAppearanceModule.mm', 'LavaSecUIReview/BridgingHeader.h',
  'LavaSecUIReview/LavaDecorationView.h', 'LavaSecUIReview/LavaDecorationView.mm', 'LavaSecUIReview/LavaDecorationContent.swift', 'LavaSecUIReview/LavaSymbolPalette.swift', 'LavaSecUIReview/LavaNativeContainment.swift', 'LavaSecUIReview/LavaReviewModule.h', 'LavaSecUIReview/LavaReviewModule.mm', 'LavaSecUIReview/BundledNarrationPlayer.swift', '../../Shared/SoftShieldGuardian.swift', '../../Shared/LavaActivityAttributes.swift',
  'LavaSecUIReview/LavaTextFieldView.h', 'LavaSecUIReview/LavaTextFieldView.mm', 'LavaSecUIReview/ReviewDomainValidator.swift',
  'LavaSecUIReview/LavaControlTrackingGuard.h', 'LavaSecUIReview/LavaControlTrackingGuard.m',
  'LavaSecUIReview/LavaChoiceView.h', 'LavaSecUIReview/LavaChoiceView.mm',
  'LavaSecUIReview/ActivityDateBridge.swift', '../../LavaSecApp/DiagnosticsDateControls.swift', '../../LavaSecApp/LavaDesignSystem/LavaTokens.swift', '../../LavaSecApp/LavaDesignSystem/LavaScaffold.swift', '../../LavaSecApp/LavaDesignSystem/LavaSelectableRow.swift', '../../LavaSecApp/LavaStrings.swift',
  '../native-app/LavaAppModule.h', '../native-app/LavaAppModule.mm',
  'LavaSecUIReview/LavaContextMenuView.h', 'LavaSecUIReview/LavaContextMenuView.mm',
  'LavaSecUIReview/LavaNativePageView.h', 'LavaSecUIReview/LavaNativePageView.mm', 'LavaSecUIReview/LavaSwitchView.h', 'LavaSecUIReview/LavaSwitchView.mm', 'LavaSecUIReview/LavaSliderView.h', 'LavaSecUIReview/LavaSliderView.mm', 'LavaSecUIReview/ReviewReferenceContent.swift',
];
export const testSource = 'LavaSecUIReviewUITests/ReviewLifecycleTests.swift';
const sourceEntries = [...reviewSources.slice(0, 5).map(path => ({path})),
  {path: '../.artifacts/LavaUIReview.js', buildPhase: 'resources'},
  {path: reviewSources[5]}, {path: 'PrivacyInfo.xcprivacy', buildPhase: 'resources'},
  ...reviewSources.slice(6).map(path => ({path})), {path: 'Assets.xcassets', buildPhase: 'resources'}, {path:'../assets/ExploreNarration',type:'folder',buildPhase:'resources'}];

/** Closed, review-only XcodeGen input. No production target aliases, extension
 * embedding, arbitrary hooks, package plugins, scheme actions, or caller-selected
 * signing identities. Only QAReview may use the fixed QA app identity. */
export function validateReviewSpec(spec) {
  assert.deepEqual(spec, {
    name: 'LavaSecUIReview',
    options: {deploymentTarget: {iOS: '18.0'}, xcodeVersion: '26.3'},
    configs: {Debug: 'debug', Release: 'release', QAReview: 'release'},
    packages: {LavaSecPackage: {path: '../..'}},
    settings: {base: {
      IPHONEOS_DEPLOYMENT_TARGET: '18.0', SWIFT_VERSION: '6.0', CLANG_CXX_LANGUAGE_STANDARD: 'c++20',
      CODE_SIGNING_ALLOWED: false, ENABLE_USER_SCRIPT_SANDBOXING: false, GENERATE_INFOPLIST_FILE: true,
      TARGETED_DEVICE_FAMILY: '1,2', INFOPLIST_KEY_UILaunchScreen_Generation: true,
      INFOPLIST_KEY_UIApplicationSupportsIndirectInputEvents: true, INFOPLIST_KEY_CFBundleDisplayName: 'Lava UI Review',
      CURRENT_PROJECT_VERSION: '1', MARKETING_VERSION: '0.0.1',
    }},
    targets: {
      LavaSecUIReview: {type: 'application', platform: 'iOS', sources: sourceEntries,
        settings: {base: {PRODUCT_BUNDLE_IDENTIFIER: 'com.lavasecurity.lavasec.ui-review',
          PRODUCT_MODULE_NAME: 'LavaSecUIReview', INFOPLIST_FILE: 'LavaSecUIReview/QAReview-Info.plist',
          SWIFT_OBJC_BRIDGING_HEADER: 'LavaSecUIReview/BridgingHeader.h', ASSETCATALOG_COMPILER_APPICON_NAME: 'AppIcon'},
          configs: {QAReview: {PRODUCT_BUNDLE_IDENTIFIER: 'com.lavasec.dev.qa',
            INFOPLIST_KEY_CFBundleDisplayName: 'Lava RN Review', CODE_SIGNING_ALLOWED: true,
            CODE_SIGN_STYLE: 'Manual', CODE_SIGN_IDENTITY: 'Apple Distribution',
            PROVISIONING_PROFILE_SPECIFIER: '$(LAVASEC_APP_PROFILE)', INFOPLIST_KEY_ITSAppUsesNonExemptEncryption: false,
            INFOPLIST_FILE: 'LavaSecUIReview/QAReview-Info.plist',
            INFOPLIST_KEY_UISupportedInterfaceOrientations: 'UIInterfaceOrientationPortrait UIInterfaceOrientationPortraitUpsideDown UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight'}}},
        // The existing optional demo narration uses public AVSpeech APIs.
        dependencies: [{sdk: 'AVFAudio.framework'}, {package: 'LavaSecPackage', product: 'LavaSecAppServices'}, {package: 'LavaSecPackage', product: 'LavaSecKit'}, {package: 'LavaSecPackage', product: 'LavaSecPresentation'}]},
      LavaSecUIReviewUITests: {type: 'bundle.ui-testing', platform: 'iOS', sources: [{path: testSource}],
        settings: {base: {PRODUCT_BUNDLE_IDENTIFIER: 'com.lavasecurity.lavasec.ui-review.uitests', TEST_TARGET_NAME: 'LavaSecUIReview'}},
        dependencies: [{target: 'LavaSecUIReview'}]},
    },
    schemes: {LavaSecUIReview: {build: {targets: {LavaSecUIReview: 'all'}}, run: {config: 'Debug'},
      test: {config: 'Debug', targets: ['LavaSecUIReviewUITests']}}},
  }, 'Review project must match the explicitly approved non-production boundary.');
}

export function validateGeneratedProjects(projects, policy) {
  assert.deepEqual(projects.map(project => project.project), ['ios/LavaSecUIReview.xcodeproj', 'ios/Pods/Pods.xcodeproj']);
  assert.deepEqual(projects[0].packages, [{type: 'XCLocalSwiftPackageReference', path: '../..', url: null}]);
  assert.deepEqual(projects[1].packages, []);
  const app = projects[0].targets;
  assert.deepEqual(app.map(target => target.name), ['LavaSecUIReview', 'LavaSecUIReviewUITests']);
  assert.deepEqual(app.map(target => target.type), ['com.apple.product-type.application', 'com.apple.product-type.bundle.ui-testing']);
  assert.deepEqual(app[0].sources, reviewSources.filter(path => /\.(swift|m|mm)$/.test(path)).map(path => posix.normalize(path.startsWith('../../') ? path.slice(3) : `ios/${path}`)).sort());
  assert.deepEqual(app[0].resources, ['.artifacts/LavaUIReview.js', 'assets/ExploreNarration', 'ios/Assets.xcassets', 'ios/PrivacyInfo.xcprivacy']);
  assert.deepEqual(app[0].products, ['LavaSecAppServices', 'LavaSecKit', 'LavaSecPresentation']);
  assert.deepEqual(app[0].frameworks, [{path: 'System/Library/Frameworks/AVFAudio.framework', tree: 'SDKROOT'}, {product: 'LavaSecAppServices'}, {product: 'LavaSecKit'}, {product: 'LavaSecPresentation'}, {path: 'libPods-LavaSecUIReview.a', tree: 'BUILT_PRODUCTS_DIR'}]);
  assert.deepEqual(app[1].frameworks, []);
  assert.deepEqual(app[0].dependencies, []);
  assert.deepEqual(app[1].sources, [`ios/${testSource}`]);
  assert.deepEqual(app[1].resources, []);
  assert.deepEqual(app[1].products, []);
  assert.deepEqual(app[1].dependencies, ['LavaSecUIReview']);
  const pods = projects[1].targets;
  assert.equal(new Set(pods.map(target => target.name)).size, pods.length, 'Duplicate generated target');
  assert.deepEqual(Object.fromEntries(pods.map(target => [target.name, target.type])), policy.podTargets);
  for (const target of pods) {
    assert.deepEqual(target.frameworks, policy.podFrameworks[target.name] ?? []);
    for (const path of [...target.sources, ...target.resources]) {
      assert.ok(!path.split('/').includes('..') && ['ios/Pods/', 'node_modules/react-native/', 'node_modules/react-native-screens/', 'node_modules/react-native-safe-area-context/', 'ios/build/generated/ios/']
        .some(root => path.startsWith(root)), `Unexpected dependency source: ${path}`);
    }
    assert.deepEqual(target.products, [], 'Pods may not alias native Lava package products.');
  }
  for (const project of projects) for (const target of project.targets) {
    assert.ok(target.phases.every(phase => ['PBXSourcesBuildPhase', 'PBXResourcesBuildPhase', 'PBXFrameworksBuildPhase', 'PBXHeadersBuildPhase', 'PBXShellScriptBuildPhase'].includes(phase)), 'Unexpected copy or executable build phase.');
    assert.deepEqual(target.entitlements, [], 'The review graph has no application-group or VPN entitlement.');
    assert.deepEqual(target.rules, [], 'Custom generated build rules are forbidden.');
  }
  const scripts = projects.flatMap(project => project.targets.flatMap(target => target.scripts
    .map(script => ({project: project.project, target: target.name, ...script}))));
  assert.deepEqual(scripts, policy.scripts, 'Generated scripts differ from the inspected pinned dependency scripts.');
}
