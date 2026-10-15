import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import test from 'node:test';
import {verifyScrollOwner} from '../scripts/native-navigation/scroll-owner.mjs';

const owner=readFileSync(new URL('../node_modules/react-native/React/Fabric/Mounting/ComponentViews/ScrollView/RCTScrollViewComponentView.mm',import.meta.url));
test('the inherited scroll hooks belong to the reviewed RN dependency',()=>{
  assert.doesNotThrow(()=>verifyScrollOwner(owner));
});
test('a changed native owner stops workspace preparation until reviewed',()=>{
  assert.throws(()=>verifyScrollOwner(Buffer.concat([owner,Buffer.from('\n')])),/Native scroll owner changed/);
});
