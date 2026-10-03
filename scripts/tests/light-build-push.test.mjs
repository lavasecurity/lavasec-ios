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
  for (const [docsOnly, compile, shouldClose, shouldReportFailure] of [
    ['true', 'success', false, false], ['', 'success', false, false],
    ['false', 'success', true, false], ['false', 'cancelled', false, false],
    ['true', 'failure', false, true], ['false', 'failure', false, true],
  ]) {
    writeFileSync(calls, '');
    const run = spawnSync('bash', ['-c', script], {cwd, encoding: 'utf8', env: {...process.env, PATH: `${cwd}:${process.env.PATH}`, CALLS: calls, DOCS_ONLY: docsOnly, APP_COMPILE: compile, ENGINE_DRIFT: 'success', VERSION_GUARD: 'success', COMMIT: 'fixture', RUN_URL: 'https://example.test/run'}});
    assert.equal(run.status, 0, run.stderr);
    const commands = readFileSync(calls, 'utf8');
    assert.equal(commands.includes('issue close'), shouldClose, `${docsOnly}/${compile}`);
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
  write('App/Feature.swift', 'first\n');
  const first = commit();
  write('App/Feature.swift', 'second\n');
  const second = commit();
  write('docs/README.md', 'documentation\n');
  const docs = commit();
  git('remote', 'add', 'origin', cwd);
  const script = step('Select the current main build result');
  assert.match(workflow, /group: light-build-main-alarm\n\s+cancel-in-progress: false/);
  assert.doesNotMatch(workflow, /queue: max/);
  // A queued docs-only app job can temporarily hide its skip result. Its own
  // finished alarm must reconcile too, rather than leaving no future observer.
  assert.match(workflow, /if: \$\{\{ always\(\) && github.event_name == 'push' \}\}/);
  assert.match(workflow, /if: \$\{\{ steps.relevant.outputs.current == 'true' \}\}/);
  const gh = path.join(cwd, 'gh');
  writeFileSync(gh, `#!/bin/bash
set -euo pipefail
[ "$1" = api ]
case "$2" in
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
  function evaluate(pages, jobs, source = first) {
    const fixture = mkdtempSync(path.join(cwd, 'api-'));
    [...pages, []].forEach((runs, i) => writeFileSync(path.join(fixture, `runs-${i + 1}.json`), JSON.stringify({workflow_runs: runs})));
    for (const [id, rows] of Object.entries(jobs)) writeFileSync(path.join(fixture, `jobs-${id}.json`), JSON.stringify(rows));
    const output = path.join(fixture, 'output'); writeFileSync(output, '');
    const environment = path.join(fixture, 'environment'); writeFileSync(environment, '');
    const run = spawnSync('bash', ['-c', script], {cwd, encoding: 'utf8', env: {...process.env, PATH: `${cwd}:${process.env.PATH}`, FIXTURE: fixture, COMMIT: source, GH_REPO: 'fixture/repo', GITHUB_OUTPUT: output, GITHUB_ENV: environment}});
    return {...run, output: readFileSync(output, 'utf8').trim(), environment: readFileSync(environment, 'utf8')};
  }
  // An old finishing run displaced the failed current run's pending alarm.
  // Read the current gates even though the overall current workflow is pending.
  const docsGates = gates();
  docsGates[0].steps = compileSteps('skipped');
  const recovered = evaluate([[item(30, docs), item(20, second), item(10, first)]], {30: docsGates, 20: gates('failure')});
  assert.equal(recovered.status, 0, recovered.stderr);
  assert.equal(recovered.output, 'current=true');
  assert.match(recovered.environment, new RegExp(`COMMIT=${second}`));
  assert.match(recovered.environment, /APP_COMPILE=failure/);
  assert.match(recovered.environment, /RUN_URL=https:\/\/example.test\/runs\/20/);
  assert.match(recovered.environment, /DOCS_ONLY=false/);
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
