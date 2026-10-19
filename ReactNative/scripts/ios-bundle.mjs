import {readFileSync} from 'node:fs';
import {basename} from 'node:path';

// Metro's programmatic API embeds a map when sourceMap is true without a URL.
// Keep the full source-bearing sidecar for freshness checks and symbolication,
// while the app resource contains only code and a relative map reference.
export async function buildIOSBundle(runBuild, config, {entry, outputStem}) {
  const bundlePath = `${outputStem}.js`;
  const mapPath = `${outputStem}.map`;
  await runBuild(config, {
    entry, platform: 'ios', dev: false, minify: true,
    out: outputStem, sourceMap: true,
    sourceMapOut: mapPath, sourceMapUrl: basename(mapPath),
  });
  return verifyBundleArtifacts(bundlePath, mapPath);
}

export function verifyPackagedJavaScript(bundlePath, mapName) {
  const code = readFileSync(bundlePath, 'utf8');
  if (!code.trim()) throw new Error(`The iOS bundle is empty: ${bundlePath}`);
  const references = [...code.matchAll(/(?:\/\/[@#]|\/\*[@#])\s*sourceMappingURL\s*=\s*([^\s*]+)/g)];
  if (references.length !== 1 || references[0][1] !== mapName) {
    throw new Error(`The iOS bundle must reference the separate ${mapName} sidecar and must not embed a source map: ${bundlePath}`);
  }
  return Buffer.byteLength(code);
}

export function verifyBundleArtifacts(bundlePath, mapPath) {
  const bundleBytes = verifyPackagedJavaScript(bundlePath, basename(mapPath));
  const contents = readFileSync(mapPath, 'utf8');
  const sourceMap = JSON.parse(contents);
  let sources = 0;
  const inspect = map => {
    if (map.version !== 3) throw new Error(`Invalid iOS source map: ${mapPath}`);
    for (const section of map.sections ?? []) inspect(section.map);
    for (const [index] of (map.sources ?? []).entries()) {
      if (typeof map.sourcesContent?.[index] !== 'string') {
        throw new Error(`The private iOS source map must retain source contents: ${mapPath}`);
      }
      sources++;
    }
  };
  inspect(sourceMap);
  if (!sources) throw new Error(`The private iOS source map has no sources: ${mapPath}`);
  return {bundleBytes, sourceMapBytes: Buffer.byteLength(contents), sources};
}

/** Jest and Metro use different extension precedence. Check the actual iOS
 * graph so a portable throwing fallback cannot ship inside migrated flows. */
export function verifyIOSFlowAdapters(mapPath) {
  const paths=[];
  const inspect=map=>{
    paths.push(...(map.sources??[]).map(path=>path.replaceAll('\\','/')));
    for(const section of map.sections??[])inspect(section.map);
  };
  inspect(JSON.parse(readFileSync(mapPath,'utf8')));
  for(const name of ['ui','info-ui']){
    const platform=new RegExp(`(?:^|/)src/flows/${name}\\.ios\\.tsx?$`);
    const fallback=new RegExp(`(?:^|/)src/flows/${name}\\.tsx?$`);
    if(!paths.some(path=>platform.test(path))||paths.some(path=>fallback.test(path)))
      throw new Error(`The iOS flow bundle must select ${name}.ios and exclude its unsupported platform fallback: ${mapPath}`);
  }
}
