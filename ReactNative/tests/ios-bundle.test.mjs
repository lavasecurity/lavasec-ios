import assert from 'node:assert/strict';
import {copyFileSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, realpathSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {dirname, join} from 'node:path';
import {createRequire} from 'node:module';
import {spawnSync} from 'node:child_process';
import test from 'node:test';
import Metro from 'metro';
import {getDefaultConfig, mergeConfig} from 'metro-config';
import {buildIOSBundle, verifyBundleArtifacts, verifyPackagedJavaScript,verifyIOSFlowAdapters} from '../scripts/ios-bundle.mjs';

const require = createRequire(import.meta.url);
const sourceOnly = '// Private source-map regression fixture; this comment must stay outside the app.\n';
function fixture(t) {
  const root = realpathSync(mkdtempSync(join(tmpdir(), 'lava-ios-bundle-')));
  t.after(() => rmSync(root, {recursive: true, force: true}));
  return root;
}
function mapFor(source, sourcePath = 'entry.js') {
  return {version: 3, sources: [sourcePath], sourcesContent: [source], names: [], mappings: ''};
}

test('real Metro keeps review and gallery source contents in private sidecars', {timeout: 60000}, async t => {
  const root = fixture(t);
  const source = `${sourceOnly}globalThis.lavaBundleFixture = 'ready';\n`;
  writeFileSync(join(root, 'entry.js'), source);
  mkdirSync(join(root, 'cache'));
  const runtime = dirname(require.resolve('metro-runtime/package.json'));
  const config = mergeConfig(await getDefaultConfig(root), {
    projectRoot: root,
    watchFolders: [root, runtime],
    maxWorkers: 1, cacheStores: [], fileMapCacheDirectory: join(root, 'cache'),
    resolver: {useWatchman: false, extraNodeModules: {'metro-runtime': runtime}}, reporter: {update() {}},
  });
  for (const name of ['LavaUIReview', 'LavaComponentGallery']) {
    const outputStem = join(root, name);
    const result = await buildIOSBundle(Metro.runBuild, config, {entry: 'entry.js', outputStem});
    const code = readFileSync(`${outputStem}.js`, 'utf8');
    const map = readFileSync(`${outputStem}.map`, 'utf8');
    assert.ok(code.includes("lavaBundleFixture"));
    assert.ok(!code.includes(sourceOnly.trim()));
    assert.ok(!code.includes('sourcesContent'));
    assert.ok(!code.includes('sourceMappingURL=data:'));
    assert.ok(map.includes(JSON.stringify(source)));
    assert.ok(result.bundleBytes > 0 && result.sourceMapBytes > 0 && result.sources > 0);
  }
});

test('real Metro selects production flow adapter filenames ahead of their portable fallbacks', {timeout:60000}, async t=>{
  const root=fixture(t);
  const adapters=join(root,'src/flows');mkdirSync(adapters,{recursive:true});mkdirSync(join(root,'cache'));
  // Use the production filenames, not Jest's ios.tsx-first extension order.
  // Minimal exports isolate resolver behavior from unrelated native UI modules.
  const production=new URL('../src/flows/',import.meta.url);
  for(const file of readdirSync(production).filter(name=>/^(ui|info-ui)(\.ios)?\.tsx?$/.test(name)))
    writeFileSync(join(adapters,file),`module.exports = {adapter:${JSON.stringify(file)}};\n`);
  writeFileSync(join(root,'entry.js'),"const ui=require('./src/flows/ui'); const info=require('./src/flows/info-ui'); globalThis.lavaFlowAdapters=[ui.adapter,info.adapter];\n");
  const runtime=dirname(require.resolve('metro-runtime/package.json'));
  const config=mergeConfig(await getDefaultConfig(root),{
    projectRoot:root,watchFolders:[root,runtime],maxWorkers:1,cacheStores:[],fileMapCacheDirectory:join(root,'cache'),
    resolver:{useWatchman:false,extraNodeModules:{'metro-runtime':runtime}},reporter:{update(){}},
  });
  const outputStem=join(root,'FlowAdapters');
  await buildIOSBundle(Metro.runBuild,config,{entry:'entry.js',outputStem});
  assert.doesNotThrow(()=>verifyIOSFlowAdapters(`${outputStem}.map`));
  // The old mixed .ts/.ios.tsx layout selected a fallback. Keep both failure
  // modes executable even if a later file rename changes the good graph.
  const bad=join(root,'bad.map');
  for(const sources of [['src/flows/ui.ts','src/flows/info-ui.ios.ts'],['src/flows/ui.ios.ts','src/flows/info-ui.ts']]){
    writeFileSync(bad,JSON.stringify({version:3,sources,names:[],mappings:''}));
    assert.throws(()=>verifyIOSFlowAdapters(bad),/unsupported platform fallback/);
  }
});

test('bundle guard rejects embedded, absent and unexpected source-map references', t => {
  const root = fixture(t);
  const bundle = join(root, 'LavaUIReview.js');
  const inlineMap = Buffer.from(JSON.stringify(mapFor(sourceOnly))).toString('base64');
  for (const reference of [
    `//# sourceMappingURL=data:application/json;base64,${inlineMap}`,
    `/*# sourceMappingURL=data:application/json;base64,${inlineMap} */`,
    '//@ sourceMappingURL=data:application/json,%7B%22sourcesContent%22%3A%5B%5D%7D',
    '', '//# sourceMappingURL=/private/build/LavaUIReview.map',
    '//# sourceMappingURL=LavaUIReview.map\n//# sourceMappingURL=data:application/json;base64,e30=',
  ]) {
    writeFileSync(bundle, `globalThis.fixture = true;\n${reference}\n`);
    assert.throws(() => verifyPackagedJavaScript(bundle, 'LavaUIReview.map'), /must not embed a source map/);
  }
});

test('bundle guard requires a source-bearing sidecar', t => {
  const root = fixture(t);
  const bundle = join(root, 'LavaUIReview.js');
  const mapPath = join(root, 'LavaUIReview.map');
  writeFileSync(bundle, 'globalThis.fixture = true;\n//# sourceMappingURL=LavaUIReview.map\n');
  assert.throws(() => verifyBundleArtifacts(bundle, mapPath), /ENOENT/);
  writeFileSync(mapPath, JSON.stringify({...mapFor(sourceOnly), sourcesContent: []}));
  assert.throws(() => verifyBundleArtifacts(bundle, mapPath), /must retain source contents/);
  writeFileSync(mapPath, JSON.stringify({version: 3, sections: [{offset: {line: 0, column: 0}, map: mapFor(sourceOnly)}]}));
  assert.equal(verifyBundleArtifacts(bundle, mapPath).sources, 1);
});

test('packaged verification preserves source freshness and excludes the private sidecar', t => {
  const root = fixture(t);
  const scripts = join(root, 'scripts');
  const artifacts = join(root, '.artifacts');
  const app = join(root, 'LavaSec.app');
  mkdirSync(scripts); mkdirSync(artifacts); mkdirSync(app); mkdirSync(join(root, 'review'));
  for (const name of ['ios-bundle.mjs', 'verify-review-bundle.mjs']) {
    copyFileSync(new URL(`../scripts/${name}`, import.meta.url), join(scripts, name));
  }
  const sourcePath = join(root, 'review/entry.ts');
  const source = `${sourceOnly}export const fixture = true;\n`;
  writeFileSync(sourcePath, source);
  const code = 'globalThis.fixture = true;\n//# sourceMappingURL=LavaUIReview.map\n';
  const bundlePath = join(artifacts, 'LavaUIReview.js');
  const mapPath = join(artifacts, 'LavaUIReview.map');
  writeFileSync(bundlePath, code);
  writeFileSync(mapPath, JSON.stringify(mapFor(source, sourcePath)));
  copyFileSync(bundlePath, join(app, 'LavaUIReview.js'));
  const verify = () => spawnSync(process.execPath, [join(scripts, 'verify-review-bundle.mjs'), app], {encoding: 'utf8'});
  const initial = verify();
  assert.equal(initial.status, 0, initial.stderr);
  writeFileSync(sourcePath, source + '// changed after bundling\n');
  assert.match(verify().stderr, /UI bundle source mismatch/);
  writeFileSync(sourcePath, source);
  copyFileSync(mapPath, join(app, 'LavaUIReview.map'));
  assert.match(verify().stderr, /private UI source map must not be packaged/);
  rmSync(join(app, 'LavaUIReview.map'));
  writeFileSync(join(app, 'LavaUIReview.js'), `${code}//# sourceMappingURL=data:application/json;base64,e30=\n`);
  assert.match(verify().stderr, /must not embed a source map/);
});
