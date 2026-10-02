// Adopt/check a generated snapshot from one immutable canonical commit. No editable
// repository/URL override: a consumer cannot quietly redirect its source of truth.
import {readFileSync, writeFileSync} from 'node:fs';
const args=process.argv.slice(2), target=args[0];
const check=args.length===2 && args[1]==='--check';
const adopt=args.length===3 && args[1]==='--ref';
if(!target || (!check && !adopt)) throw new Error('Usage: sync-filter-catalog.mjs TARGET [--ref COMMIT_SHA | --check]');
const lockPath=`${target}.source.json`;
const ref=check?JSON.parse(readFileSync(lockPath)).commit:args[2];
if(!/^[a-f0-9]{40}$/.test(ref??'')) throw new Error('An immutable 40-character commit SHA is required');
const response=await fetch(`https://raw.githubusercontent.com/lavasecurity/lavasec-filters/${ref}/dist/blocklist-catalog.json`,
  {redirect:'error',signal:AbortSignal.timeout(30000)});
if(!response.ok || !response.body) throw new Error('Canonical catalog unavailable');
let content='';
const chunks=[];let size=0;
for await(const chunk of response.body){size+=chunk.length;if(size>1024*1024)throw new Error('Catalog too large');chunks.push(chunk);}
content=Buffer.concat(chunks).toString('utf8');
const doc=JSON.parse(content);
if(doc.schema_version!==1 || !Array.isArray(doc.sources)) throw new Error('Invalid client projection');
if(check){
  if(readFileSync(target,'utf8')!==content) throw new Error('Vendored catalog differs from canonical commit; adopt it again');
}else{
  writeFileSync(target,content);
  writeFileSync(lockPath,JSON.stringify({repository:'lavasecurity/lavasec-filters',commit:ref},null,2)+'\n');
}
