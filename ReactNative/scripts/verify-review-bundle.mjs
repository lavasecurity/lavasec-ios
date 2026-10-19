// Reject a fresh native build carrying JavaScript from older application sources.
import {readFileSync,existsSync} from 'node:fs';
import {createHash} from 'node:crypto';
import {resolve,relative,isAbsolute,sep} from 'node:path';
import {fileURLToPath} from 'node:url';
import {verifyBundleArtifacts,verifyPackagedJavaScript} from './ios-bundle.mjs';
const root=fileURLToPath(new URL('..',import.meta.url));
const bundle=resolve(root,'.artifacts/LavaUIReview.js');
const mapPath=resolve(root,'.artifacts/LavaUIReview.map');
verifyBundleArtifacts(bundle,mapPath);
const map=JSON.parse(readFileSync(mapPath,'utf8'));
let checked=0;
const stale=[];
function inspect(map){
  for(const section of map.sections??[])inspect(section.map);
  (map.sources??[]).forEach((source,index)=>{
    const path=isAbsolute(source)?source:resolve(root,source);
    const local=relative(root,path);
    if(!['review','app','src','specs'].some(folder=>local.startsWith(folder+sep)))return;
    checked++;
    if(!existsSync(path)||readFileSync(path,'utf8')!==map.sourcesContent?.[index])stale.push(local);
  });
}
inspect(map);
if(checked===0||stale.length)throw new Error(`UI bundle source mismatch (${checked} sources): ${stale.join(', ')}. Run npm run bundle:review.`);
const hash=path=>createHash('sha256').update(readFileSync(path)).digest('hex');
const sha256=hash(bundle);
const app=process.argv[2];
if(app){
  verifyPackagedJavaScript(resolve(app,'LavaUIReview.js'),'LavaUIReview.map');
  if(existsSync(resolve(app,'LavaUIReview.map')))throw new Error('The private UI source map must not be packaged in the app.');
  if(hash(resolve(app,'LavaUIReview.js'))!==sha256)throw new Error('Packaged UI bundle differs from verified current bundle. Rebuild the app.');
}
console.log(JSON.stringify({verifiedSources:checked,sha256,packagedApp:app??null}));
