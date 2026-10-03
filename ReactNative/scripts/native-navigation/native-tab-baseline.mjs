import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';

// Only these two complete owners have been reviewed. Reject partial or unknown
// patches before removing the legacy slide, including edits inside its regions.
const pristine='6bf91ac113b77fd454057983f0c98d863687a3ad99a0656117fb441b65591694';
const legacy='a71d72a4e626036e889e21fad9aff8b9780b74bd3ebf6584c13efe002ef574f1';
const hash=source=>createHash('sha256').update(source).digest('hex');
export function restoreNativeTabTransition(source){
  if(hash(source)===pristine)return source;
  assert.equal(hash(source),legacy,'Native tab owner changed or is partially patched; review before migration.');
  const restored=source.replace(/\/\/ Lava: UITabBarController remains[\s\S]*?@end\n@implementation LavaPeerTabTransition[\s\S]*?@end\n\n/,'')
    .replace(/(#pragma mark - UITabBarControllerDelegate)\n- \(id<UIViewControllerAnimatedTransitioning>\)[\s\S]*?\n}\n/,'$1');
  assert.equal(hash(restored),pristine,'Native tab restoration did not match the pinned owner.');
  return restored;
}
