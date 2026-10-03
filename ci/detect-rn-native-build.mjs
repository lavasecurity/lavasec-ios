#!/usr/bin/env node
// Only skip native compilation when every changed path is known to be JS-only
// or documentation. Codegen specs, native sources, dependencies, generators and
// unknown paths always rebuild. Read Git locally without event/API diff limits.
import {spawnSync} from 'node:child_process';
import {resolve} from 'node:path';
import {fileURLToPath} from 'node:url';

const fastNodeTests = new Set([
  'ReactNative/tests/token-generator.test.mjs',
  'ReactNative/tests/review-host-policy.test.mjs',
  'ReactNative/tests/native-build-modes.test.mjs',
  'ReactNative/tests/native-impact.test.mjs',
]);
const fastTestHelpers = new Set([
  'ReactNative/tests/native-context-menu-mock.tsx',
  'ReactNative/tests/native-switch-mock.tsx',
  'ReactNative/tests/native-choice-mock.tsx',
]);

export function requiresNativeBuild(files) {
  if (!files.length) return true;
  return files.some(file => {
    if (file.startsWith('docs/') || file.endsWith('.md')) return false;
    if (file.startsWith('ReactNative/tests/')) {
      // Match Jest's discovered tests and known mocks. Other helpers may belong
      // to generated-graph policy suites and must retain native preparation.
      return !(/\.test\.[jt]sx?$/.test(file) || fastNodeTests.has(file) || fastTestHelpers.has(file));
    }
    return !/^ReactNative\/(?:app|review|src|gallery)\/.+\.(?:ts|tsx|js|jsx|mjs|cjs)$/.test(file);
  });
}

export function inspectChange({event, base, head, cwd}) {
  if (!['pull_request', 'push'].includes(event)) return {required: true, reason: 'manual or unknown event'};
  const sha = /^(?:[0-9a-f]{40}|[0-9a-f]{64})$/;
  if (!sha.test(base ?? '') || !sha.test(head ?? '')) return {required: true, reason: 'missing or invalid diff endpoint'};
  const result = spawnSync('git', ['diff', '--no-ext-diff', '--no-textconv', '--no-renames', '--name-only', '-z', `${base}..${head}`, '--'], {
    cwd, encoding: 'utf8', maxBuffer: 64 * 1024 * 1024,
  });
  if (result.status !== 0 || result.error) return {required: true, reason: 'unavailable diff'};
  const files = result.stdout.split('\0').filter(Boolean);
  const required = requiresNativeBuild(files);
  return {required, reason: required ? 'native inputs, unknown paths or empty diff' : 'only RN JavaScript/tests or documentation'};
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const args = {};
  const values = process.argv.slice(2);
  for (let i = 0; i < values.length; i += 2) {
    if (!['--event', '--base', '--head'].includes(values[i]) || values[i + 1] === undefined) {
      console.error('usage: detect-rn-native-build.mjs --event EVENT --base SHA --head SHA');
      process.exit(64);
    }
    args[values[i].slice(2)] = values[i + 1];
  }
  const verdict = inspectChange(args);
  console.error(`RN native build: ${verdict.required} (${verdict.reason})`);
  console.log(String(verdict.required));
}
