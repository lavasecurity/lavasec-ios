import assert from 'node:assert/strict';
import {execFileSync, spawnSync} from 'node:child_process';
import {chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, renameSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import test from 'node:test';
import {fileURLToPath} from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const workflowPath = path.join(root, '.github/workflows/light-build.yml');
const workflow = existsSync(workflowPath) ? readFileSync(workflowPath, 'utf8') : null;
const internalTest = (name, body) => test(name, {skip: workflow === null ? 'Internal workflow is absent from the public source export' : false}, body);
function step(name) {
  const start = workflow.indexOf(`      - name: ${name}\n`);
  assert.ok(start >= 0, name);
  const tail = workflow.slice(start).split('\n      - name: ')[0];
  const script = tail.match(/        run: \|\n((?:          .*\n|\n)+)/)?.[1];
  assert.ok(script, name);
  return script.split('\n').map(line => line.startsWith('          ') ? line.slice(10) : line).join('\n');
}
function temporary(t) {
  const cwd = mkdtempSync(path.join(tmpdir(), 'lava-push-ci-'));
  t.after(() => rmSync(cwd, {recursive: true, force: true}));
  return cwd;
}

internalTest('iOS completion observers reconcile only trusted main pushes and never schedule builds', () => {
  const repository = 'lavasecurity/lavasec-ios-internal';
  function condition(id, github) {
    const block = workflow.split(`\n  ${id}:\n`)[1].split(/\n  [a-z][\w-]*:\n/)[0];
    let expression = block.match(/^    if: (.+)$/m)?.[1];
    if (expression === '>-') expression = block.match(/^    if: >-\n((?:      .*\n)+)/m)[1].trim();
    assert.ok(expression?.startsWith('${{'), `An observer must explicitly gate ${id}.`);
    return Function('github', 'always', 'cancelled', 'needs', `return (${expression.slice(3, -2)});`)(
      github, () => true, () => false, {changes: {outputs: {engine_changed: 'true'}}});
  }
  const context = (event = 'workflow_run', override = {}) => ({
    repository, event_name: event, event: {workflow_run: {
      event: 'push', head_branch: 'main', head_repository: {full_name: repository}, ...override,
    }, pull_request: {draft: false}},
  });
  const observer = context();
  const ids = [...workflow.split('\njobs:\n')[1].matchAll(/^  ([a-z][\w-]*):$/gm)].map(match => match[1]);
  for (const id of ids.filter(id => id !== 'main-red-alarm')) {
    assert.equal(condition(id, observer), false, `The completion observer must not schedule ${id}.`);
  }
  assert.equal(condition('main-red-alarm', observer), true);
  assert.equal(condition('main-red-alarm', context('push')), true);
  for (const github of [context('pull_request'), context('workflow_run', {event: 'pull_request'}),
    context('workflow_run', {head_branch: 'feature'}),
    context('workflow_run', {head_repository: {full_name: 'outsider/fork'}}),
    {...observer, repository: 'outsider/lavasec-ios-internal', event: {...observer.event,
      workflow_run: {...observer.event.workflow_run, head_repository: {full_name: 'outsider/lavasec-ios-internal'}}}}]) {
    assert.equal(condition('main-red-alarm', github), false, 'Untrusted/non-main completion cannot write the alarm.');
  }
  const alarm = workflow.split('\n  main-red-alarm:\n')[1];
  assert.match(alarm, /uses: actions\/checkout@v7\n\s+with:\n\s+fetch-depth: 0\n\s+ref: main/);
  assert.match(step('Select the current main build result'), /light-build\.yml\/runs\?event=push&branch=main/);
});

internalTest('engine scope handles real PR/push diffs without rebuilding unrelated changes', t => {
  const cwd = temporary(t);
  const git = (...args) => execFileSync('git', args, {cwd, encoding: 'utf8'}).trim();
  const write = (file, text) => {mkdirSync(path.dirname(path.join(cwd, file)), {recursive: true}); writeFileSync(path.join(cwd, file), text);};
  const commit = () => {git('add', '-A'); git('-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.com', 'commit', '-qm', 'fixture'); return git('rev-parse', 'HEAD');};
  git('init', '-q');
  write('ThirdParty/wireguard-core/source.rs', 'fn first() {}\n');
  write('docs/README.md', 'first\n');
  const base = commit();
  write('docs/README.md', 'second\n');
  const docs = commit();
  write('App/Feature.swift', 'struct Feature {}\n');
  const app = commit();
  write('ThirdParty/wireguard-core/source.rs', 'fn second() {}\n');
  const engine = commit();
  renameSync(path.join(cwd, 'ThirdParty/wireguard-core/source.rs'), path.join(cwd, 'docs/old-source.md'));
  const renamed = commit();
  // BOTH copies of the engine classifier must reach the same verdict: the Linux
  // `changes` job copy (which gates scheduling of the Mac drift job) and the Mac job's
  // own fail-safe copy (the authority once the job is running). They are duplicated by
  // design — one runs on cheap Linux without cargo, the other on the Mac — so the only
  // thing keeping them honest is this matrix running against both.
  for (const name of ['Detect whether the WireGuard engine inputs changed', 'Skip when the engine is untouched']) {
    const script = step(name);
    for (const [event, before, after, expected] of [
      ['push', base, docs, false], ['push', docs, app, false], ['pull_request', base, app, false],
      ['push', app, engine, true], ['pull_request', app, engine, true], ['push', engine, renamed, true],
      ['push', '', app, true], ['push', '0'.repeat(40), app, true], ['workflow_dispatch', base, docs, true],
    ]) {
      const output = path.join(cwd, 'output'); writeFileSync(output, '');
      const run = spawnSync('bash', ['-c', script], {cwd, encoding: 'utf8', env: {...process.env, EVENT: event, BASE: before, HEAD: after, GITHUB_OUTPUT: output}});
      assert.equal(run.status, 0, run.stderr);
      assert.equal(readFileSync(output, 'utf8').trim(), `changed=${expected}`, `${name}: ${event} ${before}..${after}`);
    }
  }
});

internalTest('docs-only or unknown build results never clear a standing main alarm', t => {
  const cwd = temporary(t);
  const calls = path.join(cwd, 'calls');
  const gh = path.join(cwd, 'gh');
  writeFileSync(gh, '#!/bin/bash\nprintf "%s\\n" "$*" >> "$CALLS"\nif [ "$1 $2" = "issue list" ]; then printf "42\\n"; fi\n');
  chmodSync(gh, 0o755);
  const script = step('Raise or clear the alarm');
  assert.match(workflow, /needs: \[changes, app-compile, wireguard-core-drift, version-guard\]/);
  assert.match(workflow, /DOCS_ONLY: \$\{\{ needs.changes.outputs.docs_only \}\}/);
  for (const [docsOnly, compile, version, shouldClose, shouldReportFailure] of [
    ['true', 'success', 'success', false, false], ['', 'success', 'success', false, false],
    ['false', 'success', 'success', true, false], ['false', 'cancelled', 'success', false, false],
    ['true', 'failure', 'success', false, true], ['false', 'failure', 'success', false, true],
    ['false', 'success', 'failure', false, true], ['false', 'success', 'cancelled', false, false],
    ['false', 'success', 'unknown', false, false], ['false', 'success', 'skipped', false, false],
  ]) {
    writeFileSync(calls, '');
    const run = spawnSync('bash', ['-c', script], {cwd, encoding: 'utf8', env: {...process.env, PATH: `${cwd}:${process.env.PATH}`, CALLS: calls, DOCS_ONLY: docsOnly, APP_COMPILE: compile, ENGINE_DRIFT: 'success', VERSION_GUARD: version, LAVA_UI: 'success', COMMIT: 'fixture', RUN_URL: 'https://example.test/run'}});
    assert.equal(run.status, 0, run.stderr);
    const commands = readFileSync(calls, 'utf8');
    assert.equal(commands.includes('issue close'), shouldClose, `${docsOnly}/${compile}/${version}`);
    if (shouldReportFailure) assert.match(commands, /Failing jobs:/);
    if (!shouldClose && !shouldReportFailure) assert.ok(!commands.includes('issue comment'));
  }
});

internalTest('a surviving alarm reports current build results after pending eviction and docs pushes', t => {
  const cwd = temporary(t);
  const git = (...args) => execFileSync('git', args, {cwd, encoding: 'utf8'}).trim();
  const write = (file, text) => {mkdirSync(path.dirname(path.join(cwd, file)), {recursive: true}); writeFileSync(path.join(cwd, file), text);};
  const commit = () => {git('add', '-A'); git('-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.com', 'commit', '-qm', 'fixture'); return git('rev-parse', 'HEAD');};
  git('init', '-q', '-b', 'main');
  write('ci/detect-docs-only.sh', readFileSync(path.join(root, 'ci/detect-docs-only.sh'), 'utf8'));
  chmodSync(path.join(cwd, 'ci/detect-docs-only.sh'), 0o755);
  write('ci/detect-rn-native-build.mjs', readFileSync(path.join(root, 'ci/detect-rn-native-build.mjs'), 'utf8'));
  write('App/Feature.swift', 'first\n');
  const first = commit();
  write('App/Feature.swift', 'second\n');
  const second = commit();
  write('docs/README.md', 'documentation\n');
  const docs = commit();
  write('ReactNative/src/label.ts', 'export const label = 1;\n');
  const javascript = commit();
  git('remote', 'add', 'origin', cwd);
  const script = step('Select the current main build result');
  assert.match(workflow, /group: light-build-main-alarm\n\s+cancel-in-progress: false/);
  assert.doesNotMatch(workflow, /queue: max/);
  // A queued docs-only app job can temporarily hide its skip result. Its own
  // finished alarm must reconcile too, rather than leaving no future observer.
  assert.match(workflow, /workflow_run:\n\s+workflows: \[iOS CI\]\n\s+types: \[completed\]\n\s+branches: \[main\]/);
  assert.match(workflow, /if: \$\{\{ steps.relevant.outputs.current == 'true' \}\}/);
  const gh = path.join(cwd, 'gh');
  writeFileSync(gh, `#!/bin/bash
set -euo pipefail
if [ "$1" != api ]; then
  printf '%s\\n' "$*" >> "$CALLS"
  if [ "$1 $2" = 'issue list' ]; then printf '42\\n'; fi
  exit 0
fi
case "$2" in
  *"workflows/ios.yml/runs?"*) cat "$FIXTURE/ios-runs.json" ;;
  *"/runs?"*) page="\${2##*&page=}"; cat "$FIXTURE/runs-$page.json" ;;
  *"/jobs?"*) id="\${2#*/actions/runs/}"; id="\${id%%/*}"; jq -c '.[]' "$FIXTURE/jobs-$id.json" ;;
  *) exit 1 ;;
esac
`);
  chmodSync(gh, 0o755);
  const item = (id, source) => ({id, head_sha: source, html_url: `https://example.test/runs/${id}`});
  const compileSteps = (conclusion = 'success') => [
    'Compile app + extensions (simulator, no signing)',
    'Compile app + extensions (QA configuration, simulator, no signing)',
    'App compile (device, Release, no signing)',
  ].map(name => ({name, status: 'completed', conclusion}));
  const gates = (compile = 'success', status = 'completed') => [
    {name: 'App compile (simulator, no signing)', status, conclusion: compile, steps: compileSteps()},
    {name: 'WireGuard engine xcframework matches source', status: 'completed', conclusion: 'success'},
    {name: 'Marketing version ahead of latest public release', status: 'completed', conclusion: 'success'},
  ];
  const uiJob = (conclusion = 'success', status = 'completed') => ({
    name: 'Lava UI tokens, contracts, and iOS bundle', conclusion, status,
  });
  function evaluate(pages, jobs, source = first, ui = {runs: [item(140, javascript)], jobs: {140: [uiJob()]}}) {
    const fixture = mkdtempSync(path.join(cwd, 'api-'));
    [...pages, []].forEach((runs, i) => writeFileSync(path.join(fixture, `runs-${i + 1}.json`), JSON.stringify({workflow_runs: runs})));
    writeFileSync(path.join(fixture, 'ios-runs.json'), JSON.stringify({workflow_runs: ui.runs}));
    for (const [id, rows] of Object.entries({...jobs, ...ui.jobs})) writeFileSync(path.join(fixture, `jobs-${id}.json`), JSON.stringify(rows));
    const output = path.join(fixture, 'output'); writeFileSync(output, '');
    const environment = path.join(fixture, 'environment'); writeFileSync(environment, '');
    const run = spawnSync('bash', ['-c', script], {cwd, encoding: 'utf8', env: {...process.env, PATH: `${cwd}:${process.env.PATH}`, FIXTURE: fixture, COMMIT: source, GH_REPO: 'fixture/repo', GITHUB_OUTPUT: output, GITHUB_ENV: environment}});
    return {...run, fixture, output: readFileSync(output, 'utf8').trim(), environment: readFileSync(environment, 'utf8')};
  }
  function reconcile(result) {
    const calls = path.join(result.fixture, 'alarm-calls');
    writeFileSync(calls, '');
    const selected = Object.fromEntries(result.environment.trim().split('\n').map(line => {
      const split = line.indexOf('=');
      return [line.slice(0, split), line.slice(split + 1)];
    }));
    const run = spawnSync('bash', ['-c', step('Raise or clear the alarm')], {cwd, encoding: 'utf8',
      env: {...process.env, ...selected, PATH: `${cwd}:${process.env.PATH}`, CALLS: calls}});
    assert.equal(run.status, 0, run.stderr);
    return readFileSync(calls, 'utf8');
  }
  // An old finishing run displaced the failed current run's pending alarm.
  // Read the current gates even though the overall current workflow is pending.
  const docsGates = gates();
  docsGates[0].steps = compileSteps('skipped');
  // The light-build push alarm may run before iOS CI finishes. Its later
  // workflow_run observer must query again and use the newly completed result.
  for (const [conclusion, status, expected] of [
    ['success', 'completed', 'success'], ['failure', 'completed', 'failure'],
    [null, 'in_progress', 'unknown'], ['cancelled', 'completed', 'cancelled'],
    ['skipped', 'completed', 'skipped'], ['timed_out', 'completed', 'failure'],
  ]) {
    const result = evaluate([[item(40, javascript), item(20, second)]], {40: docsGates, 20: gates()}, first,
      {runs: [item(140, javascript)], jobs: {140: [uiJob(conclusion, status)]}});
    assert.equal(result.status, 0, result.stderr);
    assert.equal(result.output, 'current=true');
    assert.match(result.environment, new RegExp(`LAVA_UI=${expected}\\n`));
    assert.match(result.environment, /LAVA_UI_RUN_URL=https:\/\/example.test\/runs\/140/);
    const commands = reconcile(result);
    assert.equal(commands.includes('issue close'), expected === 'success');
    assert.equal(commands.includes('Failing jobs:'), expected === 'failure');
    if (expected === 'failure') assert.match(commands, /Lava UI tokens, contracts, and iOS bundle/);
  }
  for (const ui of [
    {runs: [], jobs: {}},
    {runs: [item(140, javascript)], jobs: {140: []}},
    {runs: [item(140, second)], jobs: {140: [uiJob()]}},
  ]) {
    const result = evaluate([[item(40, javascript), item(20, second)]], {40: docsGates, 20: gates()}, first, ui);
    assert.equal(result.status, 0, result.stderr);
    assert.match(result.environment, /LAVA_UI=unknown\n/);
    assert.ok(!reconcile(result).includes('issue close'), 'Missing current JS evidence must preserve a standing alarm.');
  }
  const newestUI = evaluate([[item(40, javascript), item(20, second)]], {40: docsGates, 20: gates()}, first,
    {runs: [item(141, javascript), item(140, javascript)], jobs: {141: [uiJob('cancelled')], 140: [uiJob()]}});
  assert.match(newestUI.environment, /LAVA_UI=cancelled\n/);
  assert.ok(!reconcile(newestUI).includes('issue close'), 'Never fall back to an older green UI run for the same SHA.');
  const pendingUI = evaluate([[item(40, javascript), item(20, second)]], {40: docsGates, 20: gates()}, first,
    {runs: [item(140, javascript)], jobs: {140: [uiJob(null, 'in_progress')]}});
  assert.ok(!reconcile(pendingUI).includes('issue close'));
  const completedUI = evaluate([[item(40, javascript), item(20, second)]], {40: docsGates, 20: gates()});
  assert.ok(reconcile(completedUI).includes('issue close'), 'Completion observer must reevaluate the previously pending JS result.');
  const pendingNative = evaluate([[item(40, javascript), item(20, second)]], {40: docsGates, 20: gates(null, 'in_progress')});
  assert.equal(pendingNative.output, 'current=false', 'UI finishing first cannot turn incomplete native evidence green.');
  const recovered = evaluate([[item(40, javascript), item(30, docs), item(20, second), item(10, first)]], {40: docsGates, 30: docsGates, 20: gates('failure')});
  assert.equal(recovered.status, 0, recovered.stderr);
  assert.equal(recovered.output, 'current=true');
  assert.match(recovered.environment, new RegExp(`COMMIT=${second}`));
  assert.match(recovered.environment, /APP_COMPILE=failure/);
  assert.match(recovered.environment, /RUN_URL=https:\/\/example.test\/runs\/20/);
  assert.match(recovered.environment, /DOCS_ONLY=false/);
  // Native-equivalent JS pushes may reuse the previous compile, but their
  // version check reads the current public release floor and must stay current.
  for (const [conclusion, status, expected] of [
    ['success', 'completed', 'success'], ['failure', 'completed', 'failure'],
    ['cancelled', 'completed', 'cancelled'], [null, 'in_progress', 'unknown'],
    ['timed_out', 'completed', 'failure'], ['startup_failure', 'completed', 'failure'],
  ]) {
    const latest = gates();
    latest[0].steps = compileSteps('skipped');
    latest[2] = {...latest[2], conclusion, status};
    const result = evaluate([[item(40, javascript), item(20, second)]], {40: latest, 20: gates()});
    assert.equal(result.status, 0, result.stderr);
    assert.equal(result.output, 'current=true');
    assert.match(result.environment, /APP_COMPILE=success/);
    assert.match(result.environment, new RegExp(`VERSION_GUARD=${expected}\\n`));
    assert.match(result.environment, /VERSION_GUARD_RUN_URL=https:\/\/example.test\/runs\/40/);
  }
  const missingVersion = gates().slice(0, 2);
  missingVersion[0].steps = compileSteps('skipped');
  const missing = evaluate([[item(40, javascript), item(20, second)]], {40: missingVersion, 20: gates()});
  assert.equal(missing.status, 0, missing.stderr);
  assert.match(missing.environment, /APP_COMPILE=success/);
  assert.match(missing.environment, /VERSION_GUARD=unknown\n/);
  // A newer incomplete check must not fall back to an older green run of the
  // same latest SHA, either.
  const cancelledVersion = gates();
  cancelledVersion[0].steps = compileSteps('skipped');
  cancelledVersion[2].conclusion = 'cancelled';
  const sameSource = evaluate([[item(41, javascript), item(40, javascript), item(20, second)]], {41: cancelledVersion, 40: docsGates, 20: gates()});
  assert.equal(sameSource.status, 0, sameSource.stderr);
  assert.match(sameSource.environment, /VERSION_GUARD=cancelled\n/);
  const unbuilt = gates(); unbuilt[0].steps = [];
  const partiallyBuilt = gates(); partiallyBuilt[0].steps[2].conclusion = 'skipped';
  for (const incomplete of [unbuilt, partiallyBuilt]) {
    const result = evaluate([[item(30, docs), item(20, second)]], {30: incomplete, 20: gates()});
    assert.equal(result.status, 0, result.stderr);
    assert.equal(result.output, 'current=false');
    assert.equal(result.environment, '');
  }

  const paged = evaluate([[item(10, first)], [item(20, second)]], {20: gates()});
  assert.equal(paged.status, 0, paged.stderr);
  assert.match(paged.environment, /APP_COMPILE=success/);
  for (const jobs of [gates(null, 'in_progress'), gates().slice(1)]) {
    const waiting = evaluate([[item(21, second), item(20, second)]], {21: jobs, 20: gates()});
    assert.equal(waiting.status, 0, waiting.stderr);
    assert.equal(waiting.output, 'current=false');
    assert.equal(waiting.environment, '');
  }
  const stale = evaluate([[item(10, first)]], {});
  assert.equal(stale.status, 0, stale.stderr);
  assert.equal(stale.output, 'current=false');
  for (const [conclusion, expected] of [['cancelled', 'cancelled'], ['timed_out', 'failure']]) {
    const result = evaluate([[item(20, second)]], {20: gates(conclusion)});
    assert.equal(result.status, 0, result.stderr);
    assert.match(result.environment, new RegExp(`APP_COMPILE=${expected}`));
  }
  const apiFailure = evaluate([[item(20, second)]], {});
  assert.notEqual(apiFailure.status, 0);
  assert.equal(apiFailure.environment, '');
});
