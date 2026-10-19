import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import test from 'node:test';
import {restoreNativeTabTransition} from '../scripts/native-navigation/native-tab-baseline.mjs';
import {patchInlineTabs} from '../scripts/native-navigation/inline-tabs.mjs';
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
test('inline iPad controls preserve the native selection gates and migrate the known legacy owner',()=>{
  const adapter=readFileSync(new URL('../scripts/native-navigation/inline-tab-control.inc',import.meta.url),'utf8');
  const patched=patchInlineTabs(pristine,adapter);
  assert.equal(patchInlineTabs(patched,adapter),patched);
  assert.equal(patchInlineTabs(legacy,adapter),patched);
  const oldTintAdapter=adapter.replace('owner.tabBar.tintColor','owner.view.tintColor');
  assert.notEqual(oldTintAdapter,adapter);
  const migrated=patchInlineTabs(patchInlineTabs(pristine,oldTintAdapter),adapter);
  assert.equal(migrated,patched);
  assert.equal(patchInlineTabs(migrated,adapter),migrated);
  for(const method of ['- (BOOL)tabBarController:', '- (void)userDidRepeatViewControllerSelection:', '- (void)userDidSelectViewController:']){
    const body=source=>source.slice(source.indexOf(method),source.indexOf('\n}',source.indexOf(method))+2);
    assert.equal(body(patched),body(pristine));
  }
  for(const source of [patched+'\n// dependency change\n',patched.replace('[super viewDidLayoutSubviews];','[super viewDidAppear:NO];')]){
    assert.throws(()=>patchInlineTabs(source,adapter),/changed or is partially patched/);
  }
});
