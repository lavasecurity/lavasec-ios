import assert from 'node:assert/strict';
import test from 'node:test';
import {auditSource} from '../scripts/check-i18n-source.mjs';

const scan = (source, keys = []) => auditSource(source,'Fixture.tsx',new Set(keys));
test('source audit finds unrendered errors, JSX copy and one-word display labels', () => {
  for (const source of ['throw new Error("Could not open this page.")','throw new Error("Unavailable")','Alert.alert("Unavailable")','<Copy>Missing copy</Copy>','<View accessibilityLabel="Loading"/>']) {
    assert.equal(scan(source).length,1);
  }
  assert.deepEqual(scan('type State="not user copy"; <View testID="test identifier"/>'),[]);
  assert.deepEqual(scan('<Copy>iOS 26.5</Copy>'),[]);
  assert.equal(scan('<Copy>iOS is unavailable</Copy>').length,1);
});
test('enumerated templates require every realized copy key', () => {
  const source = '`Notes mode ${enabled?"on":"off"}`';
  assert.equal(scan(source,['Notes mode on']).length,1);
  assert.deepEqual(scan(source,['Notes mode on','Notes mode off']),[]);
});
test('runtime prose requires a format key while translated data composition passes', () => {
  assert.equal(scan('`Count ${count} items`').length,1);
  assert.equal(scan('throw new Error(`The request failed: ${status}`)').length,1);
  assert.deepEqual(scan('localizedFormat("%d items",count)',['%d items']),[]);
  assert.deepEqual(scan('`${localized(label)} · ${value}`'),[]);
});
test('vector path and transform data do not suppress real display copy',()=>{
  assert.deepEqual(scan('const path="M110 8 C141 8 193 31 204 50 Z"; <Path d={path} transform={`translate(${x} ${y}) rotate(${angle} 4 4)`}/>'),[]);
  assert.deepEqual(scan('<Svg preserveAspectRatio="xMidYMid meet"/>'),[]);
  assert.equal(scan('<Svg accessibilityLabel="Shield guardian"/>').length,1);
  assert.equal(scan('<Copy>M110 8 C141 8 Z</Copy>').length,1);
  assert.equal(scan('const message="See me"').length,1);
  assert.equal(scan('const message="see see"').length,1);
  for(const message of ['Case 3','Sat 3','Melt 3'])assert.equal(scan(`const message=${JSON.stringify(message)}`).length,1);
  assert.equal(scan('<Copy>none</Copy>').length,1);
  assert.deepEqual(scan('const path="M.5 -1e-3L+2.5,4z"'),[]);
  assert.equal(scan('`Save ${name}`').length,1);
});
