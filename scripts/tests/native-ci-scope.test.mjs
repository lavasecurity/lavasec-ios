import assert from 'node:assert/strict';
import {readFileSync, existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync} from 'node:fs';
import {spawnSync} from 'node:child_process';
import {tmpdir} from 'node:os';
import {dirname, join} from 'node:path';
import test from 'node:test';

const root = new URL('../../', import.meta.url);
const read = file => readFileSync(new URL(file, root), 'utf8');
const job = (file, name) => read(`.github/workflows/${file}`).split(`\n  ${name}:\n`)[1].split(/\n  [a-z][\w-]*:\n/)[0];
const step = (block, name) => block.split(`      - name: ${name}\n`)[1].split(/\n      - /)[0];
function shellScript(block) {
  const lines = block.split('        run: |\n')[1].split('\n');
  const end = lines.findIndex(line => line.trim() !== '' && !line.startsWith('          '));
  return lines.slice(0, end < 0 ? undefined : end).map(line => line.slice(10)).join('\n');
}
function evaluate(expression, needs) {
  return Function('needs', 'fromJSON', `return (${expression.slice(3, -2).replaceAll('needs.lava-ui', 'needs.lavaUI')});`)(needs, JSON.parse);
}
function needs(native, docs = 'false', javascript = 'success', classification = 'success') {
  return {changes: {result: classification, outputs: {native_required: native, docs_only: docs}}, lavaUI: {result: javascript}};
}
const publicBuild = job('ios.yml', 'ios-simulator-build');
const condition = block => block.match(/^        if: (.+)$/m)[1];

test('shared iOS checks keep a read-only token and react to full-build label changes', () => {
  const workflow = read('.github/workflows/ios.yml');
  const header = workflow.split('\njobs:\n')[0];
  assert.match(header, /^permissions:\n  contents: read$/m);
  const events = header.match(/^    types: \[([^\]]+)\]/m)[1].split(',').map(value => value.trim());
  for (const event of ['labeled', 'unlabeled']) assert.ok(events.includes(event), event);
  const classifier = step(job('ios.yml', 'changes'), 'Classify native build inputs');
  const expression = classifier.match(/^          FORCE_NATIVE: (.+)$/m)[1].slice(3, -2)
    .replace('github.event.pull_request.labels.*.name', 'github.event.pull_request.labels.map(label => label.name)');
  const force = Function('github', 'contains', `return (${expression});`);
  for (const repository of ['lavasecurity/lavasec-ios', 'lavasecurity/lavasec-ios-internal']) {
    for (const [event, labels, expected] of [
      ['pull_request', ['full-build'], true],
      ['pull_request', [], false],
      ['pull_request', ['other-label'], false],
      ['push', ['full-build'], false],
      ['workflow_dispatch', [], false],
    ]) {
      assert.equal(force({repository, event_name: event, event: {pull_request: {labels: labels.map(name => ({name}))}}},
        (values, value) => values.includes(value)), expected);
    }
  }
});

test('required public app check fails when JS or classification failed, even on a JS-only diff', () => {
  const guard = step(publicBuild, 'Require successful classification and JavaScript validation');
  const script = shellScript(guard);
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
  for (const file of ['ios.yml', 'light-build.yml', 'react-native-ui.yml']) {
    if (!existsSync(new URL(`.github/workflows/${file}`, root))) continue;
    const block = step(job(file, file === 'react-native-ui.yml' ? 'lava-ui' : 'changes'), 'Classify native build inputs');
    const script = shellScript(block);
    assert.match(block, /FORCE_NATIVE: .*contains\(github.event.pull_request.labels\.\*\.name, 'full-build'\)/);
    const output = join(temporary, file);
    const result = spawnSync('bash', ['-c', script], {encoding: 'utf8', cwd: temporary, env: {...process.env, FORCE_NATIVE: 'true', GITHUB_OUTPUT: output}});
    assert.equal(result.status, 0, result.stderr);
    assert.match(readFileSync(output, 'utf8'), /required=true/);
  }
});

test('full-build overrides a real docs-only diff through classification and native guards', t => {
  const temporary = mkdtempSync(join(tmpdir(), 'lava-docs-native-'));
  t.after(() => rmSync(temporary, {recursive: true, force: true}));
  const env = {...process.env, GIT_CONFIG_GLOBAL: '/dev/null', PATH: `${dirname(process.execPath)}:${process.env.PATH}`};
  const git = (...args) => {
    const result = spawnSync('git', ['-c', 'user.name=CI fixture', '-c', 'user.email=ci@example.invalid',
      '-c', 'commit.gpgsign=false', '-c', 'core.hooksPath=/dev/null', ...args], {cwd: temporary, env, encoding: 'utf8'});
    assert.equal(result.status, 0, result.stderr);
    return result.stdout.trim();
  };
  mkdirSync(join(temporary, 'ci'));
  mkdirSync(join(temporary, 'docs'));
  for (const file of ['detect-docs-only.sh', 'detect-rn-native-build.mjs']) {
    writeFileSync(join(temporary, 'ci', file), read(`ci/${file}`), {mode: 0o755});
  }
  writeFileSync(join(temporary, 'docs/fixture.md'), 'before\n');
  git('init', '--quiet');
  git('add', '.');
  git('commit', '--quiet', '-m', 'baseline');
  const base = git('rev-parse', 'HEAD');
  writeFileSync(join(temporary, 'docs/fixture.md'), 'after\n');
  git('add', '.');
  git('commit', '--quiet', '-m', 'documentation only');
  const head = git('rev-parse', 'HEAD');
  let invocation = 0;
  const evaluateWith = (expression, context) => {
    const source = expression.slice(3, -2).replaceAll('needs.lava-ui', 'needs.lavaUI')
      .replaceAll('github.event.pull_request.labels.*.name', 'github.event.pull_request.labels.map(label => label.name)');
    return Function('github', 'steps', 'needs', 'fromJSON', 'contains', 'cancelled', `return (${source});`)(
      context.github, context.steps ?? {}, context.needs ?? {}, JSON.parse,
      (values, value) => values.includes(value), () => false);
  };
  const runStep = (block, context) => {
    const force = evaluateWith(block.match(/^          FORCE_NATIVE: (.+)$/m)[1], context);
    const output = join(temporary, `output-${invocation++}`);
    const script = shellScript(block);
    const result = spawnSync('bash', ['-c', script], {cwd: temporary, encoding: 'utf8',
      env: {...env, FORCE_NATIVE: String(force), EVENT: 'pull_request', BASE: base, HEAD: head,
        GITHUB_OUTPUT: output, GITHUB_STEP_SUMMARY: join(temporary, 'summary')}});
    assert.equal(result.status, 0, result.stderr);
    return Object.fromEntries(readFileSync(output, 'utf8').trim().split('\n').map(line => line.split('=')));
  };
  for (const file of ['ios.yml', 'light-build.yml', 'react-native-ui.yml']) {
    if (!existsSync(new URL(`.github/workflows/${file}`, root))) continue;
    const classification = job(file, file === 'react-native-ui.yml' ? 'lava-ui' : 'changes');
    const detect = step(classification, 'Detect docs-only diff');
    const native = step(classification, 'Classify native build inputs');
    for (const repository of ['lavasecurity/lavasec-ios', 'lavasecurity/lavasec-ios-internal']) {
      if (file === 'light-build.yml' && repository !== 'lavasecurity/lavasec-ios-internal') continue;
      for (const scenario of [
        {labels: ['full-build']}, {labels: []}, {labels: [], action: 'unlabeled'},
        {labels: ['full-build'], draft: true}, {labels: ['full-build'], fork: true},
        {labels: ['full-build'], author: 'dependabot[bot]'},
      ]) {
        const forced = scenario.labels.includes('full-build');
        const context = {github: {repository, event_name: 'pull_request', event: {
          action: scenario.action ?? 'labeled',
          pull_request: {draft: scenario.draft ?? false, labels: scenario.labels.map(name => ({name})),
            user: {login: scenario.author ?? 'maintainer'},
            head: {repo: {full_name: scenario.fork ? 'outsider/repo' : repository, fork: scenario.fork ?? false}}},
        }}};
        const allowed = evaluateWith(classification.match(/^    if: (.+)$/m)[1], context);
        let scope = {docs_only: '', native_required: ''};
        if (allowed) {
          const detected = runStep(detect, context);
          assert.equal(detected.docs_only, forced ? 'false' : 'true');
          context.steps = {[file === 'react-native-ui.yml' ? 'changes' : 'detect']: {outputs: detected}};
          const classify = evaluateWith(condition(native), context);
          assert.equal(classify, forced);
          scope = {docs_only: detected.docs_only, native_required: classify ? runStep(native, context).required : ''};
          if (forced) assert.equal(scope.native_required, 'true');
        }
        context.needs = {changes: {result: allowed ? 'success' : 'skipped', outputs: scope},
          lavaUI: {result: allowed ? 'success' : 'skipped', outputs: scope}};
        const trusted = !scenario.draft && !scenario.fork && scenario.author !== 'dependabot[bot]';
        if (file === 'react-native-ui.yml') {
          const lane = job(file, 'native-full-app');
          assert.equal(evaluateWith(lane.match(/^    if: (.+)$/m)[1], context),
            repository === 'lavasecurity/lavasec-ios-internal' && forced && trusted);
        } else if (file === 'light-build.yml' || repository === 'lavasecurity/lavasec-ios') {
          const app = file === 'ios.yml' ? publicBuild : job(file, 'app-compile');
          const runs = evaluateWith(app.match(/^    if: (.+)$/m)[1], context);
          assert.equal(runs, file === 'ios.yml' ? !scenario.draft : trusted);
          if (runs) {
            const runner = evaluateWith(app.match(/^    runs-on: (.+)$/m)[1], context);
            assert.deepEqual(runner, forced ? (file === 'ios.yml' ? 'macos-26' : ['self-hosted', 'macOS'])
              : (file === 'ios.yml' ? 'ubuntu-latest' : 'ubicloud-standard-2'));
            assert.equal(evaluateWith(condition(step(app, 'Prepare canonical RN app workspace')), context), forced);
          }
        } else {
          const swift = job('ios.yml', 'swift-package-tests');
          assert.equal(evaluateWith(swift.match(/^    if: (.+)$/m)[1], context), trusted);
        }
      }
    }
  }
});
