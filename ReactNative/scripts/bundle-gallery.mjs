import './configure-native-tabs.mjs';
import {configureNativeToolbar} from './configure-native-toolbar.mjs';
import './generate-localizations.mjs';
import {mkdir, stat} from 'node:fs/promises';
import {fileURLToPath} from 'node:url';
import {resolve} from 'node:path';
import {getDefaultConfig, mergeConfig} from '@react-native/metro-config';
import Metro from 'metro';

configureNativeToolbar();

const root = resolve(fileURLToPath(new URL('..', import.meta.url)));
const output = fileURLToPath(new URL('../.artifacts/', import.meta.url));
// Metro's programmatic build treats out as a stem and appends .js / .map.
const review = process.argv.includes('--review');
const outputStem = resolve(output, review ? 'LavaUIReview' : 'LavaComponentGallery');
await mkdir(output, {recursive: true});
const config = mergeConfig(getDefaultConfig(root), {
  maxWorkers: 2,
  // The CLI normally adds projectRoot while loading config. runBuild receives an
  // already-resolved config, so its file-map roots must include this package.
  watchFolders: [root],
  // A one-shot CI bundle does not need a resident Watchman server.
  resolver: {useWatchman: false},
});
await Metro.runBuild(config, {
  entry: review ? 'review/index.ts' : 'gallery/index.ts', platform: 'ios', dev: false, minify: true,
  out: outputStem, sourceMap: true,
});
if ((await stat(`${outputStem}.js`)).size === 0) throw new Error('The iOS gallery bundle is empty.');
