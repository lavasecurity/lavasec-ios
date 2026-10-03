import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {configuredToolbar} from '../scripts/configure-native-toolbar.mjs';
import {parseTokens,sourceURL} from '../scripts/generate-tokens.mjs';

const source=readFileSync(new URL('../node_modules/react-native-screens/ios/RNSBarButtonItem.mm',import.meta.url),'utf8');
const metrics=parseTokens(readFileSync(sourceURL,'utf8')).toolbar;
test('native toolbar adaptation is repeatable and preserves the menu image resolver',()=>{
  const configured=configuredToolbar(source,metrics);
  assert.equal(configuredToolbar(configured,metrics),configured);
  assert.equal(configured.slice(configured.indexOf('+ (void)resolveImageFromConfig:')),source.slice(source.indexOf('+ (void)resolveImageFromConfig:')));
  assert.equal(configured.split('// Lava fixed toolbar symbol metrics.').length,2);
});
test('dependency changes and unsafe optical metrics require review',()=>{
  assert.throws(()=>configuredToolbar(source.replace('self = [super init];','self = [super initWithTitle:@"Changed"];'),metrics),/dependency changed/);
  assert.throws(()=>configuredToolbar(source,{...metrics,checkmarkIconPointSize:44}),/Invalid toolbar metric/);
});
