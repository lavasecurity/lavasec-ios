import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {readFileSync} from 'node:fs';
export const fullAppSources = [
  ...['LavaNativePageView.mm','LavaSwitchView.mm','ActivityDateBridge.swift','LavaAppearanceModule.mm','LavaChoiceView.mm','LavaControlTrackingGuard.m','LavaContextMenuView.mm','LavaDecorationContent.swift','LavaSymbolPalette.swift','LavaNativeContainment.swift','LavaDecorationView.mm','LavaReviewModule.mm','BundledNarrationPlayer.swift','LavaSliderView.mm','LavaTextFieldView.mm','ReviewDomainValidator.swift','ReviewReferenceContent.swift','LavaShareCardSurfaceView.mm','LavaShareQrView.mm','LavaShareCardCapture.swift'].map(file=>`ios/LavaSecUIReview/${file}`),
  ...['LavaNativePageContent.swift','AppearanceBridge.swift','LavaAppBridge.swift','LavaAppGuard.swift','LavaAppFilters.swift','LavaAppFlows.swift','LavaAppFeedback.swift','LavaAppWireGuardEditor.swift','LavaAppOnboarding.swift','LavaAppHost.swift','LavaAppModule.mm','LavaAppPresentation.swift','LavaAppQueries.swift','LavaAppSettings.swift','LavaAppShareCard.swift'].map(file=>`native-app/${file}`),
];
const shareCardTestName='LavaRNShareCardTests';
function reviewedShareCardTestTarget(policy){
  const check=policy.scripts.find(s=>s.project==='ios/LavaSecUIReview.xcodeproj'&&s.name==='[CP] Check Pods Manifest.lock');
  assert.ok(check,'The hosted test must reuse the reviewed CocoaPods lock check.');
  const {project,target,...script}=check;
  return {
    name:shareCardTestName,
    settings:Object.fromEntries(['Debug','QA','Release'].map(config=>[config,{
      GENERATE_INFOPLIST_FILE:'YES',PRODUCT_NAME:shareCardTestName,PRODUCT_BUNDLE_IDENTIFIER:'com.lavasecurity.lavasec.rn-share-card-tests',
      SWIFT_OBJC_BRIDGING_HEADER:'',SWIFT_VERSION:'6.0',
      SWIFT_ENABLE_EMIT_CONST_VALUES:'NO',
      BUNDLE_LOADER:'$(TEST_HOST)',
      TEST_HOST:'$(BUILT_PRODUCTS_DIR)/LavaSec.app/LavaSec',TEST_TARGET_NAME:'LavaSec',
    }])),
    baseConfigurations:Object.fromEntries(['Debug','QA','Release'].map(config=>[config,
      `Target Support Files/Pods-${shareCardTestName}/Pods-${shareCardTestName}.${config.toLowerCase()}.xcconfig`])),
    copies:[],type:'com.apple.product-type.bundle.unit-test',
    sources:['native-app/tests/share-card/LavaRNShareCardTests.swift'],resources:[],
    phases:['PBXShellScriptBuildPhase','PBXSourcesBuildPhase','PBXFrameworksBuildPhase','PBXResourcesBuildPhase'],
    frameworks:[{product:'LavaSecKit'},{product:'GoogleSignIn'},{path:`libPods-${shareCardTestName}.a`,tree:'BUILT_PRODUCTS_DIR'}],
    rules:[],products:['GoogleSignIn','LavaSecKit'],dependencies:['LavaSec'],scripts:[script],entitlements:[],
  };
}
function reviewedShareCardPodTarget(){
  const name=`Pods-${shareCardTestName}`;
  return {
    name,
    settings:Object.fromEntries(['Debug','QA','Release'].map(config=>[config,{
      ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES:'NO',CLANG_ENABLE_OBJC_WEAK:'NO',
      'CODE_SIGN_IDENTITY[sdk=appletvos*]':'','CODE_SIGN_IDENTITY[sdk=iphoneos*]':'','CODE_SIGN_IDENTITY[sdk=watchos*]':'',
      ENABLE_MODULE_VERIFIER:'NO',ENABLE_USER_SCRIPT_SANDBOXING:'NO',IPHONEOS_DEPLOYMENT_TARGET:'18.0',
      MACH_O_TYPE:'staticlib',OTHER_LDFLAGS:'',OTHER_LIBTOOLFLAGS:'',PODS_ROOT:'$(SRCROOT)',
      PRODUCT_BUNDLE_IDENTIFIER:'org.cocoapods.${PRODUCT_NAME:rfc1034identifier}',SDKROOT:'iphoneos',
      SKIP_INSTALL:'YES',TARGETED_DEVICE_FAMILY:'1,2',...(config==='Debug'?{}:{VALIDATE_PRODUCT:'YES'}),
    }])),
    baseConfigurations:Object.fromEntries(['Debug','QA','Release'].map(config=>[config,`${name}.${config.toLowerCase()}.xcconfig`])),
    copies:[],type:'com.apple.product-type.library.static',
    sources:[`native-app/Pods/Target Support Files/${name}/${name}-dummy.m`],resources:[],
    phases:['PBXHeadersBuildPhase','PBXSourcesBuildPhase','PBXFrameworksBuildPhase','PBXResourcesBuildPhase'],
    frameworks:[],rules:[],products:[],dependencies:['Pods-LavaSec'],scripts:[],entitlements:[],
  };
}
export function validateFullAppProjects(projects, policy) {
  assert.deepEqual(projects.map(p=>p.project),['../LavaSec.xcodeproj','native-app/LavaSecRN.xcodeproj','native-app/Pods/Pods.xcodeproj']);
  const [native,full,pods]=projects;
  const names=['LavaSec','LavaSecIntents','LavaSecTunnel','LavaSecUITests','LavaSecWidget'];
  assert.deepEqual(native.targets.map(t=>t.name),names);
  assert.deepEqual(full.targets.map(t=>t.name),[shareCardTestName,...names]);
  const expected=structuredClone(native);
  expected.project=full.project;
  const app=expected.targets.find(t=>t.name==='LavaSec');
  app.sources.push(...fullAppSources);app.sources.sort();
  // The generated full-app project nests the shared narration pack under its ReactNative source
  // root; keep the expected resource path aligned with generate-project.rb.
  app.resources.push('.artifacts/LavaUIReview.js','native-app/ReactNative/assets/ExploreNarration','native-app/PrivacyInfo.xcprivacy','native-app/ReactNativeNotices.txt');app.resources.sort();
  app.frameworks.push({path:'libPods-LavaSec.a',tree:'BUILT_PRODUCTS_DIR'});
  app.phases=['PBXShellScriptBuildPhase',...app.phases,'PBXShellScriptBuildPhase','PBXShellScriptBuildPhase'];
  const rename=value=>value.replaceAll('LavaSecUIReview','LavaSec').replaceAll('ios/','native-app/');
  app.scripts=policy.scripts.filter(s=>s.project==='ios/LavaSecUIReview.xcodeproj').map(({project,target,...s})=>JSON.parse(rename(JSON.stringify(s))));
  // CocoaPods/xcodeproj rewrites these list settings to arrays in the integrated
  // RN project. The untouched native project retains its original string shape.
  for(const config of ['Debug','QA','Release']){
    Object.assign(app.settings[config],{CLANG_CXX_LANGUAGE_STANDARD:'c++20',ENABLE_USER_SCRIPT_SANDBOXING:'NO',GCC_PREPROCESSOR_DEFINITIONS:['$(inherited)','LAVA_REACT_NATIVE=1'],OTHER_SWIFT_FLAGS:'$(inherited) -D LAVA_REACT_NATIVE',SWIFT_OBJC_BRIDGING_HEADER:'ReactNative/ios/LavaSecUIReview/BridgingHeader.h',SWIFT_OBJC_INTERFACE_HEADER_NAME:'LavaSecUIReview-Swift.h'});
    app.baseConfigurations[config]=`Target Support Files/Pods-LavaSec/Pods-LavaSec.${config.toLowerCase()}.xcconfig`;
    expected.targets.find(t=>t.name==='LavaSecTunnel').settings[config].OTHER_LDFLAGS=['$(inherited)','-lresolv'];
  }
  expected.targets.find(t=>t.name==='LavaSecUITests').sources.push('native-app/tests/RNFullAppUITests.swift');
  expected.targets.find(t=>t.name==='LavaSecUITests').sources.sort();
  // This exact hosted native-port test graph was inspected after pinned XcodeGen/CocoaPods.
  // It has no alternate application entry point, resource bundle, entitlement or unreviewed shell hook.
  expected.targets.unshift(reviewedShareCardTestTarget(policy));
  // Every native source/resource, entitlement, dependency, embedded extension,
  // signing setting and package is preserved. Additional hooks fail closed.
  assert.deepEqual(full,expected,'The full RN graph must preserve the complete native app with only the reviewed presentation additions.');
  assert.deepEqual(pods.packages,[]);
  const reviewedPodTargets=JSON.parse(rename(JSON.stringify(policy.podTargets)));
  reviewedPodTargets[`Pods-${shareCardTestName}`]='com.apple.product-type.library.static';
  assert.deepEqual(Object.fromEntries(pods.targets.map(t=>[t.name,t.type])),reviewedPodTargets);
  assert.deepEqual(pods.targets.find(t=>t.name===`Pods-${shareCardTestName}`),reviewedShareCardPodTarget(),
    'The hosted-test Pods aggregate must contain only the inspected dummy source and parent dependency.');
  for(const target of pods.targets){
    assert.deepEqual(target.frameworks,policy.podFrameworks[target.name.replace('Pods-LavaSec','Pods-LavaSecUIReview')]??policy.podFrameworks[target.name]??[]);
    assert.deepEqual(target.entitlements,[]);assert.deepEqual(target.rules,[]);assert.deepEqual(target.products,[]);assert.deepEqual(target.copies,[]);
    assert.ok(target.phases.every(p=>['PBXSourcesBuildPhase','PBXResourcesBuildPhase','PBXFrameworksBuildPhase','PBXHeadersBuildPhase','PBXShellScriptBuildPhase'].includes(p)));
    for(const path of [...target.sources,...target.resources])assert.ok(!path.split('/').includes('..')&&['native-app/Pods/','native-app/build/generated/ios/','node_modules/react-native/','node_modules/react-native-screens/','node_modules/react-native-safe-area-context/','node_modules/react-native-svg/'].some(prefix=>path.startsWith(prefix)),`Unexpected dependency source: ${path}`);
  }
  const scripts=pods.targets.flatMap(t=>t.scripts.map(s=>({project:pods.project,target:t.name,...s})));
  // Script bodies contain RN's literal generated/ios paths, so rename only the
  // project field (not arbitrary 'ios/' occurrences within executable code).
  const allowed=policy.scripts.filter(s=>s.project==='ios/Pods/Pods.xcodeproj').map(s=>({...s,project:pods.project}));
  assert.deepEqual(scripts,allowed);
}
export function validateFullAppScriptFiles(root,policy){
  for(const [path,hash] of Object.entries(policy.scriptFiles)){
    const fullPath=path.replace(/^ios\//,'native-app/').replaceAll('LavaSecUIReview','LavaSec');
    let content=readFileSync(new URL(fullPath,root));
    if(path.includes('Pods-LavaSecUIReview/')){
      // CocoaPods emits identical scripts for the complete app, with the native
      // QA configuration name. Verify them against the already reviewed pins.
      content=Buffer.from(content.toString().replaceAll('Pods-LavaSec/','Pods-LavaSecUIReview/').replaceAll('Pods-LavaSec-', 'Pods-LavaSecUIReview-').replaceAll('"QA"','"QAReview"'));
    }
    assert.equal(createHash('sha256').update(content).digest('hex'),hash,`Unreviewed executable dependency: ${fullPath}`);
  }
}
