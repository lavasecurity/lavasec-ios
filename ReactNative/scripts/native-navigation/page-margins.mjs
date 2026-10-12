import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {readFileSync,writeFileSync} from 'node:fs';

// Native-stack has no public title-margin option. Extend only the pinned header
// bridge; the adapter uses public UINavigationBar directionalLayoutMargins.
export const pageMarginFiles=JSON.parse(readFileSync(new URL('page-margins.json',import.meta.url),'utf8'));
const digest=source=>createHash('sha256').update(source).digest('hex');
export function patchPageMargins(source,file){
  if(digest(source)===file.after)return source;
  assert.equal(digest(source),file.before,`Native page-margin owner changed or is partially patched: ${file.path}`);
  let next=source;
  for(const [before,after] of file.replacements){
    assert.equal(next.split(before).length,2,`Page-margin anchor changed: ${file.path}`);
    next=next.replace(before,after);
  }
  assert.equal(digest(next),file.after,`Page-margin output changed: ${file.path}`);
  return next;
}
export function configurePageMargins(){
  const updates=pageMarginFiles.map(file=>{
    const url=new URL(`../../${file.path}`,import.meta.url),source=readFileSync(url,'utf8');
    const next=patchPageMargins(source,file);
    return {url,source,next};
  });
  for(const {url,source,next} of updates)if(next!==source)writeFileSync(url,next);
}
