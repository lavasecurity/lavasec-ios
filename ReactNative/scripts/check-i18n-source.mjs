import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import ts from 'typescript';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const copyProperties = new Set(['title','label','summary','subtitle','description','note','placeholder','text','caption','accessibilityLabel','accessibilityHint']);
// These are programmer invariants or stable control-flow signals, never display copy.
const internalStrings = new Set([
  'Read access changed.', 'Review screen must be inside its isolated review provider.',
  'AppearanceStore is already connected.', 'scroll interaction', 'left center',
  'LavaChoice needs this platform’s native component mapping.',
  'Lava UI currently has an iOS implementation only. This platform needs its native component mapping.'
]);

function isCopyArgument(node) {
  let current = node;
  while (current.parent) {
    const parent = current.parent;
    if (ts.isJsxAttribute(parent) || ts.isPropertyAssignment(parent)) return copyProperties.has(parent.name.getText());
    if (ts.isNewExpression(parent) && parent.expression.getText() === 'Error') return parent.arguments?.[0] === current;
    if (ts.isCallExpression(parent)) {
      const name = parent.expression.getText();
      return /^(localized|localizedFormat|toolbarButton|nativeSearchOptions)$/.test(name) && parent.arguments[0] === current
        || /^Alert\.(alert|prompt)$/.test(name) && parent.arguments.slice(0,2).includes(current);
    }
    if (!ts.isConditionalExpression(parent) && !ts.isParenthesizedExpression(parent) && !ts.isJsxExpression(parent)) break;
    current = parent;
  }
  return false;
}

function templateChoices(expression) {
  if (ts.isStringLiteral(expression)) return [expression.text];
  if (ts.isConditionalExpression(expression)) {
    const yes = templateChoices(expression.whenTrue), no = templateChoices(expression.whenFalse);
    return yes && no ? [...yes, ...no] : null;
  }
  return null;
}

/** Audit source copy even when no test has rendered the screen or error branch. */
export function auditSource(text, file, known, allowed = new Set()) {
  const source = ts.createSourceFile(file, text, ts.ScriptTarget.Latest, true);
  const misses = [];
  const check = (value, node, force = false) => {
    value = value.trim();
    if (!/[A-Za-z]/.test(value) || (!force && !/\s/.test(value))) return;
    if (known.has(value) || allowed.has(value) || internalStrings.has(value) || /^iOS \d+(?:\.\d+)*$/.test(value)) return;
    misses.push(`${file}:${source.getLineAndCharacterOfPosition(node.getStart(source)).line + 1}: ${JSON.stringify(value)}`);
  };
  const visit = node => {
    if (ts.isStringLiteral(node) || ts.isNoSubstitutionTemplateLiteral(node)) {
      const parent = node.parent;
      // Types, source identifiers and test IDs have no user-visible wording.
      const attribute = ts.isJsxAttribute(parent) ? parent.name.getText() : undefined;
      if (!ts.isLiteralTypeNode(parent) && !ts.isImportDeclaration(parent)
          && !(ts.isPropertyAssignment(parent) && parent.name === node)
          && !['testID','key','name'].includes(attribute)) {
        check(node.text, node, isCopyArgument(node));
      }
    } else if (ts.isJsxText(node)) {
      check(node.text.replace(/\s+/g, ' '), node, true);
    } else if (ts.isTemplateExpression(node)) {
      let values = [node.head.text];
      for (const span of node.templateSpans) {
        const choices = templateChoices(span.expression);
        if (!choices) { values = null; break; }
        values = values.flatMap(value => choices.map(choice => value + choice + span.literal.text));
      }
      if (values) for (const value of values) check(value, node, true);
      else {
        const prose = [node.head.text, ...node.templateSpans.map(span => span.literal.text)].join('');
        // Numbers, user names, IDs and already translated fragments may be composed.
        // English prose around runtime values needs a catalogued format instead.
        const developerError = ts.isNewExpression(node.parent) && node.parent.expression.getText() === 'Error'
          && ['Unknown Lava color ', 'Unregistered toolbar glyph: '].includes(node.head.text)
          && node.templateSpans.length === 1 && node.templateSpans[0].literal.text === '';
        if (!developerError && /[A-Za-z]{2}/.test(prose) && /\s/.test(prose)) {
          misses.push(`${file}:${source.getLineAndCharacterOfPosition(node.getStart(source)).line + 1}: dynamic English template ${node.getText(source)}`);
        }
      }
    }
    ts.forEachChild(node, visit);
  };
  visit(source);
  return misses;
}

function sources(directory) {
  return fs.readdirSync(directory, {withFileTypes:true}).flatMap(entry => {
    const full = path.join(directory, entry.name);
    return entry.isDirectory() ? sources(full) : /\.tsx?$/.test(entry.name) && entry.name !== 'translations.ts' ? [full] : [];
  });
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const catalog = JSON.parse(fs.readFileSync(path.join(root,'../LavaSecApp/Localizable.xcstrings'),'utf8'));
  const known = new Set(Object.keys(catalog.strings));
  const allowlist = JSON.parse(fs.readFileSync(path.join(root,'tests/i18n-coverage/allowlist.json'),'utf8'));
  const allowed = new Set(Object.entries(allowlist).filter(([key]) => !key.startsWith('_')).flatMap(([,values]) => values));
  // Provider and upstream list names identify external projects, not translatable copy.
  for (const file of ['../Sources/LavaSecKit/Generated/DefaultCatalog+Generated.swift','../Sources/LavaSecKit/DNSResolverPreset.swift']) {
    for (const match of fs.readFileSync(path.join(root,file),'utf8').matchAll(/(?:name|displayName): "([^"\n]+)"/g)) allowed.add(match[1]);
  }
  allowed.add('Extra');
  const files = ['app','review','src'].flatMap(directory => sources(path.join(root,directory)));
  const misses = files.flatMap(file => auditSource(fs.readFileSync(file,'utf8'),path.relative(root,file),known,allowed));
  if (misses.length) {
    console.error(`Source i18n check failed:\n${misses.join('\n')}\nAdd all locales to the native catalog and regenerate translations. Use localizedFormat for runtime prose.`);
    process.exitCode = 1;
  } else console.log(`Source i18n check passed — ${files.length} React Native files, ${known.size} catalog keys.`);
}
