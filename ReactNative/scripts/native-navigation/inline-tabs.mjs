import {restoreNativeTabTransition} from './native-tab-baseline.mjs';

const layout = `// Lava: lay out the regular-width iPad's inline native tab labels.
- (void)viewDidLayoutSubviews
{
  [super viewDidLayoutSubviews];
  LavaUpdateInlineTabControl(self);
}
// Lava: end inline tab layout.

`;
const hooks = [
  ['    [self reconcileNavigationStateWithUIKitState];\n  }\n}',
   '    [self reconcileNavigationStateWithUIKitState];\n  }\n  LavaUpdateInlineTabControl(self);\n}'],
  ['  [super traitCollectionDidChange:previousTraitCollection];',
   '  [super traitCollectionDidChange:previousTraitCollection];\n  LavaUpdateInlineTabControl(self);'],
  ['  [self updateOrientationIfNeeded];\n}',
   '  [self updateOrientationIfNeeded];\n  LavaUpdateInlineTabControl(self);\n}'],
  ['                                             imageLoader:[self.tabsHostComponentView reactImageLoader]];\n}',
   '                                             imageLoader:[self.tabsHostComponentView reactImageLoader]];\n  LavaUpdateInlineTabControl(self);\n}'],
];

export function restoreInlineTabs(source) {
  let original = source.replace(/\/\/ Lava: inline iPad tab control\.[\s\S]*?\/\/ Lava: end inline iPad tab control\.\n\n?/, '')
    .replace(layout, '');
  for (const [before, after] of hooks) original = original.replaceAll(after, before);
  return restoreNativeTabTransition(original);
}

export function patchInlineTabs(source, adapter) {
  // Keep the complete pinned owner check, including its native selection gates,
  // stack retention and reselection behavior. Only presentation hooks are added.
  let result = restoreInlineTabs(source)
    .replace('@implementation RNSTabBarController {', adapter.trimEnd() + '\n\n@implementation RNSTabBarController {')
    .replace('- (void)traitCollectionDidChange:', layout + '- (void)traitCollectionDidChange:');
  for (const [before, after] of hooks) result = result.replaceAll(before, after);
  return result;
}
