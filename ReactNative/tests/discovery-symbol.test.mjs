import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {patchDiscoverySymbol} from '../scripts/native-navigation/discovery-symbol.mjs';
const source=readFileSync(new URL('../node_modules/react-native-screens/ios/tabs/RNSTabBarAppearanceCoordinator.mm',import.meta.url),'utf8');
const adapter=readFileSync(new URL('../scripts/native-navigation/discovery-symbol.inc',import.meta.url),'utf8');
test('native icon adapter is repeatable and patches both selected states',()=>{
 const result=patchDiscoverySymbol(source,adapter);
 assert.equal(patchDiscoverySymbol(result,adapter),result);
 assert.ok(result.includes('tabBarItem.image = LavaDiscoverySymbol(screenView.iconResourceName)'));
 assert.ok(result.includes('tabBarItem.selectedImage = LavaDiscoverySymbol(screenView.selectedIconResourceName)'));
 assert.equal(result.split('static UIImage *LavaDiscoverySymbol').length,2);
});
test('dependency drift fails instead of silently breaking discovery indicators',()=>{
 assert.throws(()=>patchDiscoverySymbol(source+'\n// upstream change\n',adapter),/Native tab icon owner changed/);
});
test('discovery marks do not use UIKit text badges and preserve ordinary symbols',()=>{
 const component=readFileSync(new URL('../src/LavaDiscoveryDot.tsx',import.meta.url),'utf8');
 assert.doesNotMatch(component,/tabBarBadge|•/);
 assert.match(component,/lavaTokens.colors.lavaOrange\[scheme\]/);
 assert.match(adapter,/CGRectMake\(24, 0, 6, 6\)/);
 assert.match(adapter,/if \(!\[name hasPrefix:@"lava.discovery\|"\]\) return \[UIImage systemImageNamed:name\]/);
 assert.match(adapter,/UIImageRenderingModeAlwaysOriginal/);
});
