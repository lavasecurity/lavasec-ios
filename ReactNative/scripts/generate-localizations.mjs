import {readFile, writeFile} from 'node:fs/promises';
const root = new URL('../', import.meta.url);
const catalog = JSON.parse(await readFile(new URL('../LavaSecApp/Localizable.xcstrings', root),'utf8'));
const output = {};
for (const [key,entry] of Object.entries(catalog.strings)) {
  // Native controllers also supply catalog keys dynamically. Pruning by React
  // source text silently drops these labels and composed empty/status keys.
  // Share the full native catalog; user-provided content uses the verbatim path.
  if (!key) continue;
  for (const [locale,translation] of Object.entries(entry.localizations ?? {})) {
    const value = translation.stringUnit?.value;
    if (value) (output[locale] ??= {})[key] = value;
  }
}
const value = '// Generated from the native Localizable.xcstrings catalog. Do not edit.\nexport const translations: Record<string, Record<string,string>> = '+JSON.stringify(output,null,2)+';\n';
const path = new URL('app/translations.ts',root);
if(process.argv.includes('--check')) {
  if(await readFile(path,'utf8') !== value) throw Error('Run node scripts/generate-localizations.mjs');
} else await writeFile(path,value);
