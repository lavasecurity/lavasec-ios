// Fails the run when a screen looked up UI copy that is written in production RN
// source but missing from LavaSecApp/Localizable.xcstrings: that copy renders in
// English for every locale. Values that only exist in test fixtures (native
// snapshot data, user data) are ignored, so fixtures never need an allowlist.
const fs=require('node:fs');const path=require('node:path');
const allowlist=require('./allowlist.json');

const root=path.resolve(__dirname,'../..');
const sourceDirs=['app','review','src'];
function sources(dir){
  return fs.readdirSync(dir,{withFileTypes:true}).flatMap(entry=>{
    const full=path.join(dir,entry.name);
    if(entry.isDirectory())return sources(full);
    return /\.(ts|tsx)$/.test(entry.name)&&entry.name!=='translations.ts'?[full]:[];
  });
}
// A template literal can carry catalogued copy in its static chunks when its
// interpolations are enumerable string literals, e.g. `Notes mode ${on?'on':'off'}`.
// Expand those to their realized values so a missing catalog entry is still caught.
// Templates whose interpolations are runtime data (numbers, ids) compose a value
// rather than a source string, and stay subject to the format-key path instead.
function templateValues(text){
  const found=new Set();
  for(const match of text.matchAll(/`((?:\\[\s\S]|\$\{[^{}]*\}|[^`\\])*)`/g)){
    const parts=match[1].split(/\$\{([^{}]*)\}/);
    let variants=[''];
    for(let index=0;index<parts.length;index+=2){
      const stat=parts[index];const expr=parts[index+1];
      if(expr===undefined){variants=variants.map(value=>value+stat);continue;}
      const choices=[...expr.matchAll(/'((?:\\.|[^'\\\n])*)'|"((?:\\.|[^"\\\n])*)"/g)].map(choice=>(choice[1]??choice[2]).replace(/\\(['"\\])/g,'$1'));
      if(!choices.length){variants=[];break;}
      variants=variants.flatMap(value=>choices.map(choice=>value+stat+choice));
    }
    for(const value of variants){const trimmed=value.replace(/\\(['"\\])/g,'$1').trim();if(trimmed)found.add(trimmed);}
  }
  return found;
}
function literals(){
  const found=new Set();
  for(const file of sourceDirs.flatMap(dir=>sources(path.join(root,dir)))){
    const text=fs.readFileSync(file,'utf8');
    for(const value of templateValues(text))found.add(value);
    for(const match of text.matchAll(/'((?:\\.|[^'\\\n])*)'|"((?:\\.|[^"\\\n])*)"|>([^<>{}\n]+)</g)){
      const value=(match[1]??match[2]??match[3]).replace(/\\(['"\\])/g,'$1').trim();
      if(value)found.add(value);
    }
  }
  return found;
}
module.exports=async()=>{
  const file=process.env.LAVA_I18N_MISSES;
  if(!file||!fs.existsSync(file))return;
  const misses=new Set(fs.readFileSync(file,'utf8').split('\n').filter(Boolean).map(line=>JSON.parse(line)));
  fs.rmSync(path.dirname(file),{recursive:true,force:true});
  const source=literals();
  const allowed=new Set(Object.entries(allowlist).filter(([key])=>!key.startsWith('_')).flatMap(([,values])=>values));
  // An iOS version is a product name plus numeric data, not translatable wording.
  const untranslated=[...misses].filter(value=>/[A-Za-z]/.test(value)&&source.has(value)&&!allowed.has(value)&&!/^iOS \d+(?:\.\d+)*$/.test(value)).sort();
  if(untranslated.length)throw new Error(`UI copy missing from LavaSecApp/Localizable.xcstrings (renders in English in every locale):\n${untranslated.map(value=>`  ${JSON.stringify(value)}`).join('\n')}\nAdd each key with all locales, then run node scripts/generate-localizations.mjs. Only proper names, protocol acronyms and QA-only copy belong in tests/i18n-coverage/allowlist.json.`);
};
