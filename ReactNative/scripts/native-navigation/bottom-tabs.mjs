import {restoreInlineTabs} from './inline-tabs.mjs';

const layout = `// Lava: synchronize native bottom-tab traits before layout.
- (void)viewWillLayoutSubviews
{
  LavaUpdateBottomTabPlacement(self);
  [super viewWillLayoutSubviews];
}
// Lava: end bottom-tab trait layout.

`;
const hooks = [
  ['  [super traitCollectionDidChange:previousTraitCollection];',
   '  [super traitCollectionDidChange:previousTraitCollection];\n  LavaUpdateBottomTabPlacement(self);'],
  ['  [self setViewControllers:_tabScreenControllers animated:[[self viewControllers] count] != 0];',
   '  [self setViewControllers:_tabScreenControllers animated:[[self viewControllers] count] != 0];\n  LavaUpdateBottomTabPlacement(self);'],
];

export function patchNativeBottomTabs(source, adapter) {
  let original = source.replace(/\/\/ Lava: native bottom tabs on iPad\.[\s\S]*?\/\/ Lava: end native bottom tabs on iPad\.\n\n?/, '').replace(layout, '');
  for (const [before, after] of hooks) original = original.replaceAll(after, before);
  let result = restoreInlineTabs(original)
    .replace('@implementation RNSTabBarController {', adapter.trimEnd() + '\n\n@implementation RNSTabBarController {')
    .replace('- (void)traitCollectionDidChange:', layout + '- (void)traitCollectionDidChange:');
  for (const [before, after] of hooks) result = result.replaceAll(before, after);
  return result;
}
