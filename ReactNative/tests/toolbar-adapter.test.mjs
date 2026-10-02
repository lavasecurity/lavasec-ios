import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {renderToolbarAdapter} from '../scripts/native-navigation/toolbar-adapter.mjs';
import {parseTokens, sourceURL} from '../scripts/generate-tokens.mjs';
const source = readFileSync(new URL('../scripts/native-navigation/labeled-toolbar.inc', import.meta.url), 'utf8');
const metrics = parseTokens(readFileSync(sourceURL, 'utf8')).toolbar;

test('native mode canvas, glyph and target consume the actual canonical metrics', () => {
  const result = renderToolbarAdapter(source, metrics);
  assert.ok(!result.includes('__LAVA_MODE_'));
  assert.ok(result.includes(`configurationWithPointSize:${metrics.checkmarkIconPointSize}`));
  assert.ok(result.includes(`CGSizeMake(${metrics.iconFrameSize}, ${metrics.iconFrameSize})`));
  assert.ok(result.includes(`CGRectMake(0, 0, ${metrics.buttonSize}, ${metrics.buttonSize})`));
  assert.ok(result.includes(`modeInset = (${metrics.buttonSize} - ${metrics.iconFrameSize}) / 2.0`));
});
test('changing source metrics updates every target dimension and cannot silently omit a slot', () => {
  const result = renderToolbarAdapter(source, {checkmarkIconPointSize:19, iconFrameSize:28, buttonSize:48});
  assert.ok(result.includes('CGSizeMake(28, 28)'));
  assert.ok(result.includes('CGRectMake(0, 0, 48, 48)'));
  assert.ok(result.includes('modeInset = (48 - 28) / 2.0'));
  assert.equal(result.match(/constraintEqualToConstant:48/g)?.length, 2);
  assert.throws(() => renderToolbarAdapter(source, {...metrics, buttonSize:NaN}), /Invalid toolbar metric/);
  assert.throws(() => renderToolbarAdapter(source.replaceAll('__LAVA_MODE_GLYPH__', '17'), metrics), /Missing toolbar metric slot/);
});
