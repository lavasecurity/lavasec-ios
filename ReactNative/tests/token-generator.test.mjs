import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import test from 'node:test';
import {parseTokens, sourceURL} from '../scripts/generate-tokens.mjs';

const reference = readFileSync(sourceURL, 'utf8');

test('tracks a changed Swift color, radius, row floor, and type size', () => {
  const changed = reference
    .replace(/(static let safeGreen = adaptiveColor\(\s*)light: \([^)]+\)/, '$1light: (0.10, 0.20, 0.30)')
    .replace(/cardCornerRadius: CGFloat = \d+/, 'cardCornerRadius: CGFloat = 22')
    .replace(/standard: CGFloat = \d+/, 'standard: CGFloat = 60')
    .replace('size: 42, weight:', 'size: 48, weight:');
  const tokens = parseTokens(changed);
  assert.deepEqual(tokens.colors.safeGreen.light, [0.1, 0.2, 0.3]);
  assert.equal(tokens.surface.cardCornerRadius, 22);
  assert.equal(tokens.row.standard, 60);
  assert.equal(tokens.typography.metricNumeral.fontSize, 48);
});

test('preserves native semantic references and aliases instead of baking light-mode values', () => {
  const tokens = parseTokens(reference);
  assert.deepEqual(tokens.colors.primaryText, {alias: 'ink'});
  assert.deepEqual(tokens.colors.errorText, {alias: 'dangerRed'});
  assert.equal(tokens.surface.selectedSelectionBackground, 'softGreen');
  assert.equal(tokens.typography.rowTitle.dynamicTypeRamp, 'subheadline');
  assert.equal(tokens.typography.metricNumeral.allowFontScaling, false);
  assert.deepEqual(tokens.typography.rowTitle, {fontSize:15,fontWeight:'600',dynamicTypeRamp:'subheadline',allowFontScaling:true});
  assert.deepEqual(tokens.typography.rowMetadata, {fontSize:15,fontWeight:'400',dynamicTypeRamp:'subheadline',allowFontScaling:true});
  assert.equal(tokens.glyphSymbols.ranking, 'lava.ranking');
  assert.equal(tokens.outcomeSymbols.blocked, 'xmark.circle.fill');
  // The stroke-only pair is one shared definition; the filter-content lists read
  // it so native and RN cannot drift on the blocked/allowed shape.
  assert.equal(tokens.outcomeSymbols.blockedOutline, 'xmark.circle');
  assert.equal(tokens.outcomeSymbols.allowedOutline, 'arrow.right.circle');
  assert.equal(tokens.typography.actionLabel.fontSize, 17);
  assert.equal(tokens.typography.actionLabel.fontWeight, '600');
});

test('exports field and section roles with their native semantic scaling', () => {
  const tokens = parseTokens(reference).typography;
  assert.deepEqual(tokens.fieldLabel, {fontSize:13,fontWeight:'600',dynamicTypeRamp:'footnote',allowFontScaling:true});
  assert.deepEqual(tokens.sectionLabel, {fontSize:17,fontWeight:'600',dynamicTypeRamp:'headline',allowFontScaling:true});

  // A changed native face must propagate its size, weight and ramp together;
  // field labels must not retain a hardcoded 13pt/footnote interpretation.
  const changed = reference.replace('static let fieldLabel = Font.footnote.weight(.semibold)',
    'static let fieldLabel = Font.subheadline');
  assert.notEqual(changed, reference);
  assert.deepEqual(parseTokens(changed).typography.fieldLabel,
    {fontSize:15,fontWeight:'400',dynamicTypeRamp:'subheadline',allowFontScaling:true});
  assert.throws(() => parseTokens(reference.replace('Font.footnote.weight(.semibold)',
    'Font.footnote.weight(.black)')), /Unsupported LavaTypography.fieldLabel/);
});

test('tracks the exact native toolbar glyph optics and negative offset', () => {
  const changed=reference.replace('xmarkIconPointSize: CGFloat = 15','xmarkIconPointSize: CGFloat = 16')
    .replace('framedIconVerticalOffset: CGFloat = -1','framedIconVerticalOffset: CGFloat = -2');
  const tokens=parseTokens(changed);
  assert.equal(tokens.toolbar.xmarkIconPointSize,16);
  assert.equal(tokens.toolbar.framedIconVerticalOffset,-2);
  assert.equal(tokens.toolbar.buttonSize,44);
});

test('tracks the shared full-sheet header inset contract from Swift', () => {
  const changed = reference.replace('headerInset: CGFloat = 18', 'headerInset: CGFloat = 20')
    .replace('headerBottomInset: CGFloat = 12', 'headerBottomInset: CGFloat = 14');
  assert.deepEqual(parseTokens(changed).fullSheet, {headerInset: 20, headerBottomInset: 14});
  assert.throws(() => parseTokens(reference.replace('enum LavaFullSheetMetrics', 'enum MissingFullSheetMetrics')));
});

test('tracks shared utility-row glyph sizes from the native reference', () => {
  const changed=reference.replace('glyphPointSize: CGFloat = 20','glyphPointSize: CGFloat = 21')
    .replace('accessoryPointSize: CGFloat = 12','accessoryPointSize: CGFloat = 13');
  assert.deepEqual(parseTokens(changed).navigation,{glyphPointSize:21,accessoryPointSize:13});
});

test('resolves surface aliases in their Swift scope when the referenced mapping changes', () => {
  const changed = reference
    .replace('static let cardBackground = LavaStyle.cardBackground', 'static let cardBackground = LavaStyle.cream')
    .replace('static let selectedSelectionBackground = LavaStyle.softGreen',
      'static let selectedSelectionBackground = selectionBackground\n    static let originalBackground = LavaStyle.cardBackground');
  const tokens = parseTokens(changed);
  assert.equal(tokens.surface.cardBackground, 'cream');
  assert.equal(tokens.surface.selectionBackground, 'cream');
  assert.equal(tokens.surface.selectedSelectionBackground, 'cream');
  assert.equal(tokens.surface.originalBackground, 'cardBackground');
  assert.throws(() => parseTokens(reference.replace(
    'static let selectionBackground = cardBackground',
    'static let selectionBackground = cream',
  )), /Unsupported LavaSurface.selectionBackground/);
});

test('rejects unsupported expressions, invalid RGB, and missing reference sections', () => {
  for (const broken of [
    reference.replace('static let errorText = dangerRed', 'static let errorText = dangerRed.opacity(0.5)'),
    reference.replace(/(static let safeGreen = adaptiveColor\(\s*)light: \([^)]+\)/, '$1light: (1.16, 0.47, 0.34)'),
    reference.replace(/standard: CGFloat = \d+/, 'standard: CGFloat = computeRowHeight()'),
    reference.replace('Font.headline', 'Font.custom("Example", size: 17)'),
    reference.replace('enum LavaSpacing', 'enum RemovedSpacing'),
    reference.replace('static let errorText =', 'static let errorText: Color ='),
    reference.replace('static let errorText =', 'static var errorText ='),
  ]) assert.throws(() => parseTokens(broken));
});

test('rejects color declarations after the helper instead of silently dropping them', () => {
  const changed = reference.replace('\n}\n\nenum LavaSurface', '\n    static let missedColor = dangerRed\n}\n\nenum LavaSurface');
  assert.notEqual(changed, reference);
  assert.throws(() => parseTokens(changed), /after.*helper/);
});

test('recognizes Swift whitespace between declaration keywords', () => {
  for (const whitespace of ['  ', '\n    ', '\t']) {
    const changed = reference.replace('    static let safeGreen',
      `    static${whitespace}let newColor = Color(uiColor: .label)\n    static${whitespace}let safeGreen`);
    const tokens = parseTokens(changed);
    assert.deepEqual(tokens.colors.newColor, {system: 'label'});
    assert.deepEqual(tokens.colors.safeGreen, parseTokens(reference).colors.safeGreen);
    assert.throws(() => parseTokens(changed.replace(
      `static${whitespace}let newColor`, `static${whitespace}var newColor`,
    )), /Unsupported token declaration/);
  }
});

test('rejects unparsed static modifiers before tokens and after the color helper', () => {
  for (const declaration of [
    'static private let newColor = Color(uiColor: .label)',
    'static nonisolated(unsafe) let newColor = Color(uiColor: .label)',
    'static private var newColor = Color(uiColor: .label)',
  ]) {
    assert.throws(() => parseTokens(reference.replace('    static let safeGreen',
      `    ${declaration}\n    static let safeGreen`)), /Unsupported token declaration/);
    assert.throws(() => parseTokens(reference.replace('\n}\n\nenum LavaSurface',
      `\n    ${declaration}\n}\n\nenum LavaSurface`)), /after.*helper/);
  }
});


test('rejects inherited Object prototype names as Swift color aliases', () => {
  for (const alias of ['constructor', 'toString', '__proto__']) {
    assert.throws(() => parseTokens(reference.replace('static let errorText = dangerRed',
      `static let errorText = ${alias}`)), /Unsupported LavaStyle.errorText/);
  }
});
