import {readFileSync} from 'node:fs';
import {join} from 'node:path';

test('inline native text resolves the authoritative semantic headline font before applying size and weight',()=>{
  const source=readFileSync(join(__dirname,'../ios/LavaSecUIReview/LavaInlineSymbolTextContent.swift'),'utf8');
  expect(source).toContain('LavaInlineSemanticFont.resolve(size: fontSize, weight: fontWeight, traits: traitCollection,');
  expect(source).toContain('.font(Font(font))');
  expect(source).not.toContain('.font(.system(');
  expect(source).toContain('matches(current) ? current : categories.lazy.map');
  expect(source).toContain('.first(where: matches) ?? current');
  for(const category of ['extraSmall','small','medium','large','extraLarge','extraExtraLarge','extraExtraExtraLarge',
    'accessibilityMedium','accessibilityLarge','accessibilityExtraLarge','accessibilityExtraExtraLarge','accessibilityExtraExtraExtraLarge']){
    expect(source).toMatch(new RegExp(`\\.${category}\\b`));
  }
  expect(source).toContain('let font = semantic.withSize(pointSize)');
  expect(source).toContain('if weight == "semibold" { return font }');
  expect(source).toContain('weight == "bold" ? .bold : .regular');
  expect(source).toContain('.traits: [UIFontDescriptor.TraitKey.weight: requestedWeight.rawValue]');
});
