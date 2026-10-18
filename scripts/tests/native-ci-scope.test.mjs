import assert from 'node:assert/strict';
import {readFileSync, existsSync, mkdtempSync, rmSync} from 'node:fs';
import {spawnSync} from 'node:child_process';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import test from 'node:test';

const root = new URL('../../', import.meta.url);
const read = file => readFileSync(new URL(file, root), 'utf8');
const job = (file, name) => read(`.github/workflows/${file}`).split(`\n  ${name}:\n`)[1].split(/\n  [a-z][\w-]*:\n/)[0];
const step = (block, name) => block.split(`      - name: ${name}\n`)[1].split(/\n      - /)[0];
function evaluate(expression, needs) {
  return Function('needs', 'fromJSON', `return (${expression.slice(3, -2).replaceAll('needs.lava-ui', 'needs.lavaUI')});`)(needs, JSON.parse);
}
function needs(native, docs = 'false', javascript = 'success', classification = 'success') {
  return {changes: {result: classification, outputs: {native_required: native, docs_only: docs}}, lavaUI: {result: javascript}};
}
const publicBuild = job('ios.yml', 'ios-simulator-build');
const condition = block => block.match(/^        if: (.+)$/m)[1];

test('required public app check fails when JS or classification failed, even on a JS-only diff', () => {
  const guard = step(publicBuild, 'Require successful classification and JavaScript validation');
  const script = guard.split('        run: |\n')[1].split('\n').map(line => line.slice(10)).join('\n');
  for (const result of ['failure', 'cancelled', 'skipped', '']) {
    for (const n of [needs('false', 'false', result), needs('false', 'false', 'success', result)]) {
      assert.equal(evaluate(condition(guard), n), true);
      assert.equal(spawnSync('bash', ['-c', script]).status, 1);
    }
  }
  assert.equal(evaluate(condition(guard), needs('false')), false);
  assert.match(publicBuild, /needs: \[changes, lava-ui\]/);
});

test('JS and docs receipts never allocate a public Mac, while unknown/native inputs do', () => {
  const runner = publicBuild.match(/^    runs-on: (.+)$/m)[1];
  const prepare = condition(step(publicBuild, 'Prepare canonical RN app workspace'));
  for (const n of [needs('false'), needs('', 'true')]) {
    assert.equal(evaluate(runner, n), 'ubuntu-latest');
    assert.equal(evaluate(prepare, n), false);
  }
  for (const native of ['true', '', 'unexpected']) {
    assert.equal(evaluate(runner, needs(native)), 'macos-26');
    assert.equal(evaluate(prepare, needs(native)), true);
  }
  const ui = job('ios.yml', 'lava-ui');
  assert.match(ui, /name: Lava UI tokens, contracts, and iOS bundle/);
  for (const command of ['npm test', 'npm run bundle:ios', 'npm run bundle:review']) assert.ok(ui.includes(`run: ${command}\n`));
  assert.ok(!read('.github/workflows/react-native-ui.yml').includes('run: npm test'));
});

test('internal JS receipts use Linux and unknown/native inputs retain owned Macs', {skip: !existsSync(new URL('.github/workflows/light-build.yml', root))}, () => {
  const app = job('light-build.yml', 'app-compile');
  const runner = app.match(/^    runs-on: (.+)$/m)[1];
  const prepare = condition(step(app, 'Prepare canonical RN app workspace'));
  assert.equal(evaluate(runner, needs('false')), 'ubicloud-standard-2');
  assert.equal(evaluate(prepare, needs('false')), false);
  for (const native of ['true', '', 'unexpected']) {
    assert.deepEqual(evaluate(runner, needs(native)), ['self-hosted', 'macOS']);
    assert.equal(evaluate(prepare, needs(native)), true);
  }
});

test('full-build explicitly forces native classification without consulting an unavailable diff', t => {
  const temporary = mkdtempSync(join(tmpdir(), 'lava-force-native-'));
  t.after(() => rmSync(temporary, {recursive: true, force: true}));
  for (const file of ['light-build.yml', 'react-native-ui.yml']) {
    if (!existsSync(new URL(`.github/workflows/${file}`, root))) continue;
    const block = step(job(file, file === 'light-build.yml' ? 'changes' : 'lava-ui'), 'Classify native build inputs');
    const script = block.split('        run: |\n')[1].split('\n').map(line => line.slice(10)).join('\n');
    assert.match(block, /FORCE_NATIVE: .*contains\(github.event.pull_request.labels\.\*\.name, 'full-build'\)/);
    const output = join(temporary, file);
    const result = spawnSync('bash', ['-c', script], {encoding: 'utf8', cwd: temporary, env: {...process.env, FORCE_NATIVE: 'true', GITHUB_OUTPUT: output}});
    assert.equal(result.status, 0, result.stderr);
    assert.match(readFileSync(output, 'utf8'), /required=true/);
  }
});
