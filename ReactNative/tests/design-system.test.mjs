import assert from 'node:assert/strict';
import test from 'node:test';
import {readFileSync} from 'node:fs';
import {inspectScreen,inspectDesignModule} from '../scripts/check-design-system.mjs';

test('screen paint and text escapes are rejected, including token-valued local paint',()=>{
  const invalid=`const Screen=()=> <View style={{backgroundColor:colors.cardBackground,borderRadius:20}}><Copy size={17}>Hello</Copy></View>;`;
  assert.equal(inspectScreen(invalid,'Example.tsx').length,3);
});
test('shared compositions and semantic type leave screen arrangement free',()=>{
  assert.deepEqual(inspectScreen(`const Screen=()=> <StoryColumns primary={<Info title="Ready"/>} secondary={<Copy role="body">Hello</Copy>}/>;`,'Example.tsx'),[]);
});

test('the shared lifecycle cover owns paint while the same render pattern remains forbidden in leaf screens',()=>{
  const cover=readFileSync(new URL('../review/PresentationCover.tsx',import.meta.url),'utf8');
  assert.deepEqual(inspectDesignModule(cover,'PresentationCover.tsx'),[]);
  assert.ok(inspectDesignModule(cover,'LeafScreen.tsx').length>0);
});
