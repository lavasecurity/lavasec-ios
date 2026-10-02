import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {readFileSync,writeFileSync} from 'node:fs';
export function patchDiscoverySymbol(source,adapter) {
  const original=source.replace(/\/\/ Lava: discovery symbol adapter\.[\s\S]*?\/\/ Lava: end discovery symbol adapter\.\n\n/,'')
    .replaceAll('LavaDiscoverySymbol(screenView.iconResourceName)','[UIImage systemImageNamed:screenView.iconResourceName]')
    .replaceAll('LavaDiscoverySymbol(screenView.selectedIconResourceName)','[UIImage systemImageNamed:screenView.selectedIconResourceName]');
  assert.equal(createHash('sha256').update(original).digest('hex'),'b99ef5187412f17ed55ca3d01f889cadbc3787fb55cd4905237d7367b9fc3f5c','Native tab icon owner changed; review discovery composition.');
  return original.replace('@implementation RNSTabBarAppearanceCoordinator',adapter+'@implementation RNSTabBarAppearanceCoordinator')
    .replace('[UIImage systemImageNamed:screenView.iconResourceName]','LavaDiscoverySymbol(screenView.iconResourceName)')
    .replace('[UIImage systemImageNamed:screenView.selectedIconResourceName]','LavaDiscoverySymbol(screenView.selectedIconResourceName)');
}
const url=new URL('../../node_modules/react-native-screens/ios/tabs/RNSTabBarAppearanceCoordinator.mm',import.meta.url);
const source=readFileSync(url,'utf8');
const result=patchDiscoverySymbol(source,readFileSync(new URL('discovery-symbol.inc',import.meta.url),'utf8'));
if(result!==source)writeFileSync(url,result);
