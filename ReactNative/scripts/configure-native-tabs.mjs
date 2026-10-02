import './configure-native-navigation.mjs';
// Keep native pop-to-root and scroll-to-top. Guard alone disables root scrolling.
// A protected tab still permits native reselection once it is active.
import {readFileSync,writeFileSync} from 'node:fs';
import {createHash} from 'node:crypto';
import assert from 'node:assert/strict';
const root=new URL('../',import.meta.url);
const files=[
  {
    "path": "node_modules/@react-navigation/bottom-tabs/src/unstable/NativeBottomTabView.native.tsx",
    "before": "533dca40feebb889f1f7948f99165dcae01beedc19c8e1d585dd1ff5ca4b6db0",
    "previous": "a740d101b2b7818a16449c4e9e82d1f8d921fa5bbf92bd5bd147bcface43338d",
    "after": "e5fc6fcc242df6488640a6f7d8fba0c8698d5016bf460915184f39c37cd45753"
  },
  {
    "path": "node_modules/@react-navigation/bottom-tabs/lib/module/unstable/NativeBottomTabView.native.js",
    "before": "0bec553334b23f16fa56cd3f5e40b3d2919a36c2a3358b0f50cc2a7f0994e7bd",
    "previous": "8374e9659b11271770ba43a91f5f03396715153996019db35236d0310a54eb9e",
    "after": "e72de949c3fd49533c85e7ca86d42cbcfb16057456274025428d1683c550c177"
  }
];
const hash=value=>createHash('sha256').update(value).digest('hex');
export function configureNativeTabs() {
  for(const file of files) {
    const url=new URL(file.path,root),source=readFileSync(url,'utf8'),digest=hash(source);
    if(digest===file.after)continue;
    assert.ok(digest===file.before||digest===file.previous,`Native tab dependency changed: ${file.path}`);
    const original=source.replace('popToRoot: false','popToRoot: true').replace('scrollToTop: false','scrollToTop: true');
    const patched=original.replace('scrollToTop: true',"scrollToTop: route.name !== 'GuardTab'").replace('tabBarSelectionEnabled === false','tabBarSelectionEnabled === false && !isFocused');
    assert.equal(hash(patched),file.after);
    writeFileSync(url,patched);
  }
}
configureNativeTabs();
