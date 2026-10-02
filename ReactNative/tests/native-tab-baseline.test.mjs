import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import test from 'node:test';
import {restoreNativeTabTransition} from '../scripts/native-navigation/native-tab-baseline.mjs';
const read=name=>readFileSync(new URL('./fixtures/native-navigation/'+name,import.meta.url),'utf8');
const pristine=read('RNSTabBarController-4.27.0.mm');
const legacy=read('RNSTabBarController-legacy-slide.mm');
test('clean and previously patched native tabs converge without a custom animator',()=>{
  assert.equal(restoreNativeTabTransition(pristine),pristine);
  assert.equal(restoreNativeTabTransition(legacy),pristine);
  assert.equal(restoreNativeTabTransition(restoreNativeTabTransition(legacy)),pristine);
});
test('unknown edits inside or outside the legacy transition fail closed',()=>{
  for(const source of [legacy.replace('return 0.32','return 0.4'),legacy+'\n// changed',pristine+'\n// changed']){
    assert.throws(()=>restoreNativeTabTransition(source),/changed or is partially patched/);
  }
});
