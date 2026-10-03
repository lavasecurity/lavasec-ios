import {readFileSync} from 'node:fs';
import {validateFullAppProjects,validateFullAppScriptFiles} from './full-app-policy.mjs';
const root=new URL('../',import.meta.url);
const policy=JSON.parse(readFileSync(new URL('ios/native-dependencies.json',root)));
validateFullAppProjects(JSON.parse(readFileSync(process.argv[2],'utf8')),policy);
validateFullAppScriptFiles(root,policy);
console.log('Full RN app: native targets, identities, extensions, entitlements and pinned dependency scripts verified.');
