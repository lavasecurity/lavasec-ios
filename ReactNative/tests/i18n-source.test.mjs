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
