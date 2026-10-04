#!/usr/bin/env ruby
# Derive the complete app graph; CocoaPods only opens the generated RN copy.
require 'json'
require 'yaml'
require 'fileutils'
root = File.expand_path('../..', __dir__)
Dir.chdir(root)
spec = YAML.safe_load(File.read('project.yml'))
spec['name'] = 'LavaSecRN'
spec['options'].delete('postGenCommand')
# Settled assertions cannot detect a title/content jump during a passing push.
# Retain native XCTest recordings of successful journeys for transition review.
spec.fetch('schemes').fetch('LavaSec').fetch('test').merge!({
  'captureScreenshotsAutomatically' => true,
  'deleteScreenshotsWhenEachTestSucceeds' => false,
  'preferredScreenCaptureFormat' => 'screenRecording',
})
app = spec.fetch('targets').fetch('LavaSec')
spec.fetch('targets').fetch('LavaSecUITests').fetch('sources') << {'path' => 'ReactNative/native-app/tests/RNFullAppUITests.swift'}
components = %w[LavaNativePageView.h LavaNativePageView.mm LavaSwitchView.h LavaSwitchView.mm LavaContextMenuView.h LavaContextMenuView.mm LavaAppearanceModule.h LavaAppearanceModule.mm LavaDecorationView.h LavaDecorationView.mm LavaDecorationContent.swift LavaSymbolPalette.swift LavaNativeContainment.swift LavaReviewModule.h LavaReviewModule.mm BundledNarrationPlayer.swift LavaTextFieldView.h LavaTextFieldView.mm ReviewDomainValidator.swift LavaControlTrackingGuard.h LavaControlTrackingGuard.m LavaChoiceView.h LavaChoiceView.mm ActivityDateBridge.swift LavaSliderView.h LavaSliderView.mm ReviewReferenceContent.swift]
components.each { |file| app['sources'] << {'path' => "ReactNative/ios/LavaSecUIReview/#{file}"} }
%w[LavaShareCardSurfaceView.h LavaShareCardSurfaceView.mm LavaShareQrView.h LavaShareQrView.mm LavaShareCardCapture.swift].each do |file|
  app['sources'] << {'path' => "ReactNative/ios/LavaSecUIReview/#{file}"}
end
%w[LavaNativePageContent.swift LavaAppGuard.swift LavaAppHost.swift LavaAppPresentation.swift LavaAppBridge.swift LavaAppSettings.swift LavaAppQueries.swift LavaAppShareCard.swift LavaAppFilters.swift LavaAppFlows.swift LavaAppModule.h LavaAppModule.mm AppearanceBridge.swift].each do |file|
  app['sources'] << {'path' => "ReactNative/native-app/#{file}"}
end
app['sources'] << {'path' => 'ReactNative/.artifacts/LavaUIReview.js', 'buildPhase' => 'resources'}
app['sources'] << {'path' => 'ReactNative/assets/ExploreNarration', 'type' => 'folder', 'buildPhase' => 'resources'}
app['sources'] << {'path' => 'ReactNative/native-app/ReactNativeNotices.txt', 'buildPhase' => 'resources'}
app['settings']['base'].merge!({
  'SWIFT_OBJC_INTERFACE_HEADER_NAME' => 'LavaSecUIReview-Swift.h',
  'SWIFT_OBJC_BRIDGING_HEADER' => 'ReactNative/ios/LavaSecUIReview/BridgingHeader.h',
  'CLANG_CXX_LANGUAGE_STANDARD' => 'c++20',
  'ENABLE_USER_SCRIPT_SANDBOXING' => 'NO',
  'OTHER_SWIFT_FLAGS' => '$(inherited) -D LAVA_REACT_NATIVE',
  'GCC_PREPROCESSOR_DEFINITIONS' => '$(inherited) LAVA_REACT_NATIVE=1',
})
# Native ports only: these tests do not claim the shared React tree was mounted.
# Source membership is explicit so no fixture enters the shipping app target.
spec['targets']['LavaRNShareCardTests'] = {
  'type' => 'bundle.unit-test', 'platform' => 'iOS',
  'sources' => [{'path' => 'ReactNative/native-app/tests/share-card/LavaRNShareCardTests.swift'}],
  'dependencies' => [{'target' => 'LavaSec'}, {'package' => 'LavaSecPackage', 'product' => 'LavaSecKit'},
                     {'package' => 'GoogleSignIn', 'product' => 'GoogleSignIn'}],
  'settings' => {'base' => {
    'PRODUCT_NAME' => 'LavaRNShareCardTests',
    'BUNDLE_LOADER' => '$(TEST_HOST)',
    'PRODUCT_BUNDLE_IDENTIFIER' => 'com.lavasecurity.lavasec.rn-share-card-tests',
    'GENERATE_INFOPLIST_FILE' => 'YES', 'TEST_TARGET_NAME' => 'LavaSec',
    'SWIFT_OBJC_BRIDGING_HEADER' => '', 'SWIFT_VERSION' => '6.0',
    # This XCTest-only bundle has no AppIntent declarations and inherits the
    # project's empty protocol list. Do not declare const metadata Swift will not emit.
    'SWIFT_ENABLE_EMIT_CONST_VALUES' => 'NO',
  }},
}
spec['schemes']['LavaRNShareCardTests'] = {
  'build' => {'targets' => {'LavaSec' => 'all', 'LavaRNShareCardTests' => 'test'}},
  'test' => {'config' => 'Debug', 'targets' => ['LavaRNShareCardTests']},
}
File.write('.LavaSecRN.project.json', JSON.pretty_generate(spec))
abort('XcodeGen failed') unless system('xcodegen', 'generate', '--spec', '.LavaSecRN.project.json')
# Apply the same localization/Icon Composer fixups to the generated copy only.
abort('Project fixups failed') unless system('python3', '-B', '-c', <<~PY)
  import importlib.util
  from pathlib import Path
  spec = importlib.util.spec_from_file_location('fixups', 'scripts/xcodegen-fixups.py')
  module = importlib.util.module_from_spec(spec)
  spec.loader.exec_module(module)
  path = Path('LavaSecRN.xcodeproj/project.pbxproj')
  path.write_text(module.fix_icon_composer_types(module.fix_known_regions(path.read_text())))
PY

# Keep the project beside its Pods for codegen, retaining the native source root.
FileUtils.rm_rf('ReactNative/native-app/LavaSecRN.xcodeproj')
FileUtils.mv('LavaSecRN.xcodeproj', 'ReactNative/native-app/LavaSecRN.xcodeproj')
pbx = 'ReactNative/native-app/LavaSecRN.xcodeproj/project.pbxproj'
File.write(pbx, File.read(pbx).sub('projectDirPath = "";', 'projectDirPath = "../..";'))
# Scheme container URLs are resolved against projectDirPath by Xcode.
Dir.glob('ReactNative/native-app/LavaSecRN.xcodeproj/xcshareddata/xcschemes/*.xcscheme').each do |scheme|
  content = File.read(scheme).gsub('container:LavaSecRN.xcodeproj', 'container:ReactNative/native-app/LavaSecRN.xcodeproj')
  File.write(scheme, content)
end
