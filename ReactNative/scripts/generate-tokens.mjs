import {readFileSync, writeFileSync} from 'node:fs';
import {fileURLToPath} from 'node:url';

export const sourceURL = new URL('../../LavaSecApp/LavaDesignSystem/LavaTokens.swift', import.meta.url);
export const outputURL = new URL('../src/generated/tokens.ts', import.meta.url);

// Swift remains the reference during the parallel UI implementation. This intentionally
// understands only the current token declarations: a new expression must be reviewed,
// not silently omitted or evaluated as arbitrary Swift/JavaScript.
function enumBody(source, name) {
  const marker = `enum ${name} {`;
  const start = source.indexOf(marker);
  if (start < 0) throw new Error(`Missing ${name}`);
  let depth = 1;
  const offset = start + marker.length;
  for (let i = offset; i < source.length; i++) {
    if (source[i] === '{') depth++;
    if (source[i] === '}' && --depth === 0) return source.slice(offset, i);
  }
  throw new Error(`Unclosed ${name}`);
}

function declarations(body) {
  const parsed = [...body.matchAll(/\bstatic\s+let\s+(\w+)(?:\s*:\s*CGFloat)?\s*=\s*([\s\S]*?)(?=\n\s*static\s+let\s+|$)/g)]
    .map(([, name, expression]) => [name, expression.trim()]);
  // Count every static declaration, including modifiers/shapes this subset cannot
  // extract. Counting only supported syntax would silently hide unsupported tokens.
  if (parsed.length !== [...body.matchAll(/\bstatic\b/g)].length) {
    throw new Error('Unsupported token declaration; extend the parser before changing its Swift shape.');
  }
  return parsed;
}

export function parseTokens(swiftSource) {
  const source = swiftSource.replace(/\/\*[\s\S]*?\*\//g, '').replace(/\/\/[^\n]*/g, '');
  const [colorBody, ...helperTail] = enumBody(source, 'LavaStyle').split('private static func adaptiveColor');
  if (helperTail.some(tail => /\bstatic\b/.test(tail))) {
    throw new Error('Static declarations after the adaptiveColor helper require parser support.');
  }
  const colors = {};
  for (const [name, expression] of declarations(colorBody)) {
    const adaptive = expression.match(/^adaptiveColor\(\s*light:\s*\(([^)]+)\),\s*dark:\s*\(([^)]+)\)\s*\)$/);
    const system = expression.match(/^Color\(uiColor: \.(\w+)\)$/);
    const alias = expression.match(/^([a-z]\w*)$/);
    if (adaptive) {
      const rgb = value => {
        const values = value.split(',').map(s => {
          if (!/^\s*(?:\d+(?:\.\d+)?)\s*$/.test(s)) throw new Error(`Invalid RGB in ${name}`);
          return Number(s);
        });
        if (values.length !== 3 || values.some(n => n < 0 || n > 1)) throw new Error(`Invalid RGB in ${name}`);
        return values;
      };
      colors[name] = {light: rgb(adaptive[1]), dark: rgb(adaptive[2])};
    } else if (system) {
      colors[name] = {system: system[1]};
    } else if (alias && Object.hasOwn(colors, alias[1])) {
      colors[name] = {alias: alias[1]};
    } else {
      throw new Error(`Unsupported LavaStyle.${name}: ${expression}`);
    }
  }
  if (Object.keys(colors).length === 0) throw new Error('No colors');

  const scalars = name => {
    const values = {};
    for (const [key, expression] of declarations(enumBody(source, name))) {
      if (/^\d+(?:\.\d+)?$/.test(expression) || name === 'LavaToolbarMetrics' && /^-\d+(?:\.\d+)?$/.test(expression)) {
        values[key] = Number(expression);
        continue;
      }
      // Qualified colors refer to LavaStyle; bare aliases refer to this enum's
      // earlier declarations, even when a LavaStyle color has the same name.
      const color = expression.match(/^LavaStyle\.([a-z]\w*)$/);
      const alias = expression.match(/^([a-z]\w*)$/);
      if (name === 'LavaSurface' && color && Object.hasOwn(colors, color[1])) {
        values[key] = color[1];
      } else if (name === 'LavaSurface' && alias && Object.hasOwn(values, alias[1])) {
        values[key] = values[alias[1]];
      } else {
        throw new Error(`Unsupported ${name}.${key}: ${expression}`);
      }
    }
    return values;
  };

  const typography = Object.fromEntries(declarations(enumBody(source, 'LavaTypography')).map(([name, expression]) => {
    if (expression === 'Font.title2.bold()') return [name, {fontSize:22,fontWeight:'700',dynamicTypeRamp:'title2',allowFontScaling:true}];
    const semantic = expression.match(/^Font\.(footnote|subheadline|headline)(?:\.weight\(\.(semibold)\))?$/);
    if (semantic) return [name, {
      fontSize: {footnote:13,subheadline:15,headline:17}[semantic[1]],
      fontWeight: semantic[1] === 'headline' || semantic[2] ? '600' : '400',
      dynamicTypeRamp: semantic[1],
      allowFontScaling: true,
    }];
    const fixed = expression.match(/^Font\.system\(size: (\d+(?:\.\d+)?), weight: \.bold, design: \.rounded\)$/);
    if (fixed) return [name, {fontSize: Number(fixed[1]), fontWeight: '700', fontFamily: 'ui-rounded', allowFontScaling: false}];
    throw new Error(`Unsupported LavaTypography.${name}: ${expression}`);
  }));
  const outcomeSymbols = Object.fromEntries(declarations(enumBody(source, 'LavaOutcomeSymbol')).map(([key, expression]) => {
    if (!/^"[a-z.]+"$/.test(expression)) throw new Error(`Unsupported outcome symbol ${key}`);
    return [key, JSON.parse(expression)];
  }));
  const glyphSymbols = Object.fromEntries(declarations(enumBody(source, 'LavaGlyphSymbol')).map(([key, expression]) => {
    if (!/^"[a-z.]+"$/.test(expression)) throw new Error(`Unsupported glyph symbol ${key}`);
    return [key, JSON.parse(expression)];
  }));
  return {colors, outcomeSymbols, glyphSymbols, guard: scalars('LavaGuardMetrics'), surface: scalars('LavaSurface'), spacing: scalars('LavaSpacing'), row: scalars('LavaRowHeight'), navigation: scalars('LavaNavigationRowMetrics'), filterIdentity: scalars('LavaFilterIdentityMetrics'), toolbar: scalars('LavaToolbarMetrics'), fullSheet: scalars('LavaFullSheetMetrics'), typography};
}

export function renderTokens(tokens) {
  return '// Generated from LavaSecApp/LavaDesignSystem/LavaTokens.swift. Run npm run tokens.\n'
    + '// Native semantic colors and font ramps are resolved by the iOS implementation.\n'
    + `export const lavaTokens = ${JSON.stringify(tokens, null, 2)} as const;\n`;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const output = renderTokens(parseTokens(readFileSync(sourceURL, 'utf8')));
  if (process.argv.includes('--check')) {
    if (readFileSync(outputURL, 'utf8') !== output) throw new Error('Lava tokens drifted; run npm run tokens and review the diff.');
    console.log('Lava React Native tokens match the Swift reference.');
  } else {
    writeFileSync(outputURL, output);
  }
}
