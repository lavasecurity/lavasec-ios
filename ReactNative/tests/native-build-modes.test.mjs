import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import test from 'node:test';

// Execute the real orchestration script with fake native tools. This exercises
// mode selection, failure propagation and cleanup without Xcode or a simulator.
function run(t, args, options = {}) {
  const root = mkdtempSync(join(tmpdir(), 'lava-build-mode-test-'));
  t.after(() => rmSync(root, {recursive: true, force: true}));
  const app = join(root, 'ReactNative');
  const evidence = join(app, '.artifacts/full-app');
  const bin = join(root, 'bin');
  const trace = join(root, 'trace.jsonl');
  mkdirSync(join(app, 'scripts'), {recursive: true});
  mkdirSync(evidence, {recursive: true});
  mkdirSync(bin);
  copyFileSync(new URL('../scripts/build-full-app.sh', import.meta.url), join(app, 'scripts/build-full-app.sh'));
  copyFileSync(new URL('../scripts/simulator-cleanup.sh', import.meta.url), join(app, 'scripts/simulator-cleanup.sh'));
  writeFileSync(join(app, 'scripts/prepare-full-app.sh'), 'set -eu\nprintf prepared > "$2/prepared"\n');
  writeFileSync(join(app, 'scripts/test-native-containment.sh'), 'set -eu\nprintf \'{"passed":true,"checks":26}\' > "$2/native-scaffold-results.json"\nexit "${LAVA_CI_TEST_SCAFFOLD_EXIT:-0}"\n');
  // Old journey evidence must never survive a compile or failed retry.
  writeFileSync(join(evidence, 'test-summary.json'), '{}');
  writeFileSync(join(evidence, 'Lava-RN-Full-Simulator.zip'), 'stale');
  const toolBody = `
import {appendFileSync, mkdirSync, writeFileSync} from 'node:fs';
import {join} from 'node:path';
const args=process.argv.slice(2);
appendFileSync(process.env.LAVA_CI_TEST_TRACE, JSON.stringify({tool,args})+'\\n');
const value = flag => args[args.indexOf(flag)+1];
if (tool==='xcodebuild') {
  mkdirSync(value('-resultBundlePath'), {recursive:true});
  if (!process.env.LAVA_CI_TEST_MISSING_APP) mkdirSync(join(value('-derivedDataPath'),'Build/Products/Debug-iphonesimulator/LavaSec.app'), {recursive:true});
  process.exit(Number((args.includes('test-without-building') ? process.env.LAVA_CI_TEST_IPAD_XCODE_EXIT : process.env.LAVA_CI_TEST_XCODE_EXIT) || 0));
}
if (tool==='ditto') writeFileSync(args.at(-1), 'simulator app');
if (tool==='xcrun' && args[0]==='simctl' && args[1]==='list') console.log(JSON.stringify({runtimes:[{isAvailable:true,identifier:'com.apple.CoreSimulator.SimRuntime.iOS-26-0',version:'26.0'}],devicetypes:[{name:'iPad Pro 11-inch (M4)',identifier:'com.apple.CoreSimulator.SimDeviceType.iPad-Pro-11-inch-M4'}]}));
if (tool==='xcrun' && args[0]==='simctl' && args[1]==='create') console.log(args[2].includes('iPad') ? 'isolated-ipad-simulator' : 'isolated-test-simulator');
if (tool==='xcrun' && args[0]==='xcresulttool' && args[1]==='get') console.log(value('--path').includes('ipad.xcresult') ? process.env.LAVA_CI_TEST_IPAD_SUMMARY : process.env.LAVA_CI_TEST_SUMMARY);
if (tool==='xcrun' && args[0]==='xcresulttool' && args[1]==='export') mkdirSync(value('--output-path'),{recursive:true});
`;
  for (const tool of ['xcrun', 'xcodebuild', 'ditto']) {
    writeFileSync(join(bin, tool), `#!${process.execPath}\nconst tool=${JSON.stringify(tool)};\n${toolBody}`, {mode: 0o755});
  }
  const result = spawnSync('bash', [join(app, 'scripts/build-full-app.sh'), ...args], {
    encoding: 'utf8', timeout: 120000,
    env: {...process.env, PATH: `${bin}:${process.env.PATH}`, TMPDIR: root,
      LAVA_CI_TEST_TRACE: trace,
      LAVA_CI_TEST_SUMMARY: JSON.stringify({result: 'Passed', passedTests: 19, failedTests: 0, skippedTests: 0}),
      LAVA_CI_TEST_IPAD_SUMMARY: JSON.stringify({result: 'Passed', passedTests: 2, failedTests: 0, skippedTests: 0}),
      ...options},
  });
  assert.ifError(result.error);
  const calls = existsSync(trace) ? readFileSync(trace, 'utf8').trim().split('\n').map(line => JSON.parse(line)) : [];
  return {result, evidence, calls};
}

function assertCleaned(calls) {
  assert.ok(calls.some(call => call.tool === 'xcrun' && call.args.join(' ') === 'simctl delete isolated-test-simulator'));
  if(calls.some(call=>call.tool==='xcrun'&&call.args[1]==='create'&&call.args[2].includes('iPad'))) {
    assert.ok(calls.some(call=>call.tool==='xcrun'&&call.args.join(' ')==='simctl delete isolated-ipad-simulator'));
  }
  const build = calls.find(call => call.tool === 'xcodebuild');
  if (build) assert.equal(existsSync(build.args[build.args.indexOf('-derivedDataPath') + 1]), false);
}

test('routine compile keeps UIKit regressions and produces no journey or app ZIP evidence', t => {
  const {result, evidence, calls} = run(t, ['--compile']);
  assert.equal(result.status, 0, result.stderr);
  const build = calls.find(call => call.tool === 'xcodebuild').args;
  assert.equal(build.at(-1), 'build');
  assert.ok(build.includes('native-app/LavaSecRN.xcworkspace'));
  assert.ok(!build.some(arg => arg.includes('only-testing')));
  assert.ok(existsSync(join(evidence, 'native-scaffold-results.json')));
  assert.ok(!existsSync(join(evidence, 'test-summary.json')));
  assert.ok(!existsSync(join(evidence, 'Lava-RN-Full-Simulator.zip')));
  assert.deepEqual(JSON.parse(readFileSync(join(evidence, 'validation.json'))).journeysExecuted, false);
  assertCleaned(calls);
});

test('existing local default still runs journeys and retains review evidence', t => {
  const {result, evidence, calls} = run(t, []);
  assert.equal(result.status, 0, result.stderr);
  const build = calls.find(call => call.tool === 'xcodebuild').args;
  assert.equal(build.at(-1), 'test');
  assert.ok(build.includes('-only-testing:LavaSecUITests/RNFullAppUITests'));
  assert.ok(existsSync(join(evidence, 'native-scaffold-results.json')));
  assert.ok(existsSync(join(evidence, 'test-summary.json')));
  assert.ok(existsSync(join(evidence, 'Lava-RN-Full-Simulator.zip')));
  assert.ok(existsSync(join(evidence, 'ipad/test-summary.json')));
  assert.ok(existsSync(join(evidence, 'ipad/screenshots')));
  const builds = calls.filter(call=>call.tool==='xcodebuild');
  assert.equal(builds.length, 2);
  const tablet = builds[1].args;
  assert.equal(tablet.at(-1), 'test-without-building');
  assert.equal(tablet[tablet.indexOf('-derivedDataPath')+1],build[build.indexOf('-derivedDataPath')+1]);
  assert.deepEqual(tablet.filter(arg=>arg.startsWith('-only-testing:')), [
    '-only-testing:LavaSecUITests/RNFullAppUITests/testStoryJourneyLightPreservesConnectionAlignmentAcrossRotation',
    '-only-testing:LavaSecUITests/RNFullAppUITests/testStoryJourneyDarkPreservesConnectionAlignmentAcrossRotation',
  ]);
  const phoneShutdown = calls.findIndex(call=>call.tool==='xcrun'&&call.args.join(' ')==='simctl shutdown isolated-test-simulator');
  const tabletBoot = calls.findIndex(call=>call.tool==='xcrun'&&call.args.join(' ')==='simctl boot isolated-ipad-simulator');
  assert.ok(phoneShutdown>=0&&tabletBoot>phoneShutdown, 'Only one private simulator may be booted at once.');
  const finalSummary = calls.findLastIndex(call=>call.tool==='xcrun'&&call.args[0]==='xcresulttool'&&call.args[1]==='get');
  assert.ok(calls.findIndex(call=>call.tool==='ditto')>finalSummary, 'The deliverable ZIP follows both accepted device results.');
  assert.equal(JSON.parse(readFileSync(join(evidence, 'validation.json'))).journeysExecuted, true);
  assertCleaned(calls);
});

for (const [name, args, options] of [
  ['compile failure', ['--compile'], {LAVA_CI_TEST_XCODE_EXIT: '65'}],
  ['missing full app', ['--compile'], {LAVA_CI_TEST_MISSING_APP: '1'}],
  ['native scaffold failure', ['--compile'], {LAVA_CI_TEST_SCAFFOLD_EXIT: '1'}],
  ['failed journeys', ['--journeys'], {LAVA_CI_TEST_SUMMARY: JSON.stringify({result: 'Failed', passedTests: 16, failedTests: 1, skippedTests: 0})}],
  ['skipped journeys', ['--journeys'], {LAVA_CI_TEST_SUMMARY: JSON.stringify({result: 'Passed', passedTests: 17, failedTests: 0, skippedTests: 1})}],
  ['tablet execution failure', ['--journeys'], {LAVA_CI_TEST_IPAD_XCODE_EXIT: '65'}],
  ['failed tablet journeys', ['--journeys'], {LAVA_CI_TEST_IPAD_SUMMARY: JSON.stringify({result: 'Failed', passedTests: 1, failedTests: 1, skippedTests: 0})}],
  ['skipped tablet journeys', ['--journeys'], {LAVA_CI_TEST_IPAD_SUMMARY: JSON.stringify({result: 'Passed', passedTests: 1, failedTests: 0, skippedTests: 1})}],
  ['missing tablet journey', ['--journeys'], {LAVA_CI_TEST_IPAD_SUMMARY: JSON.stringify({result: 'Passed', passedTests: 1, failedTests: 0, skippedTests: 0})}],
]) {
  test(`${name} cannot produce a passing receipt and cleans its isolated build`, t => {
    const {result, evidence, calls} = run(t, args, options);
    assert.notEqual(result.status, 0);
    assert.ok(!existsSync(join(evidence, 'validation.json')));
    assert.ok(!existsSync(join(evidence, 'Lava-RN-Full-Simulator.zip')));
    assertCleaned(calls);
  });
}

test('unknown modes are rejected before dependency preparation or native execution', t => {
  const {result, evidence, calls} = run(t, ['--typo']);
  assert.equal(result.status, 64);
  assert.equal(calls.length, 0);
  assert.ok(!existsSync(join(evidence, 'prepared')));
});

test('native job runs after prerequisite failure while preserving cancellation, docs, label and same-repo isolation', () => {
  const workflow = readFileSync(new URL('../../.github/workflows/react-native-ui.yml', import.meta.url), 'utf8');
  // The condition's draft and label terms only work if the workflow actually
  // receives the lifecycle events: `ready_for_review` flips `draft` false after the
  // skip, `converted_to_draft` cancels an in-flight run on the way back, and
  // `unlabeled` cancels a withdrawn `full-build` request.
  assert.match(workflow, /types: \[opened, synchronize, reopened, labeled, unlabeled, ready_for_review, converted_to_draft\]/);
  const job = workflow.split('\n  native-full-app:\n')[1];
  const condition = job.match(/^    if: \$\{\{ (.+) \}\}$/m)?.[1];
  assert.ok(condition, 'native job condition must be explicit');
  // GitHub adds success() implicitly unless the expression uses a status
  // function. Model that rule so removing !cancelled() reproduces the skip.
  const hasStatusFunction = /\b(?:cancelled|always|success|failure)\(/.test(condition);
  // `contains(github.event.pull_request.labels.*.name, 'full-build')` is GitHub
  // expression syntax, not JS: translate the wildcard path to a plain map so the
  // condition can be evaluated exactly as the workflow states it.
  const expression = condition
    .replaceAll('needs.lava-ui', 'needs.lavaUI')
    .replaceAll("contains(github.event.pull_request.labels.*.name, 'full-build')",
      "contains((github.event.pull_request.labels ?? []).map(label => label.name), 'full-build')");
  const contains = (list, value) => list.includes(value);
  const evaluate = new Function('github', 'needs', 'cancelled', 'contains', `return (${expression});`);
  const runs = ({repository = 'lavasecurity/lavasec-ios-internal', fork = false,
    headRepo = fork ? 'someone/lavasec-ios-internal' : repository, labels = [], draft = false,
    author = 'maintainer',
    event = 'pull_request', dependency = 'success', docs = '', native = '', cancelled = false} = {}) =>
    (hasStatusFunction || dependency === 'success') && evaluate(
      {repository, event_name: event, event: {pull_request: {draft, user: {login: author},
        head: {repo: {fork, full_name: headRepo}}, labels: labels.map(name => ({name}))}}},
      {lavaUI: {outputs: {docs_only: docs, native_required: native}}}, () => cancelled, contains);
  assert.equal(runs({labels: ['full-build'], dependency: 'failure'}), true, 'still fail-safe after a prerequisite failure');
  assert.equal(runs({labels: ['full-build'], docs: 'false'}), true);
  assert.equal(runs({labels: ['full-build'], native: 'false'}), false);
  assert.equal(runs({labels: ['full-build'], native: 'true', dependency: 'failure'}), true);
  assert.equal(runs({labels: ['full-build'], native: 'unexpected', dependency: 'failure'}), true);
  assert.equal(runs({event: 'workflow_dispatch'}), true);
  assert.equal(runs({event: 'workflow_dispatch', docs: 'true'}), false);
  assert.equal(runs({labels: ['full-build'], cancelled: true}), false);
  assert.equal(runs({fork: true, dependency: 'failure'}), false);
  // The label and dependency terms only matter together: without the label the lane
  // is off anyway, so the bot case must carry it to exercise the predicate (Kilo, PR #780).
  assert.equal(runs({labels: ['full-build'], author: 'dependabot[bot]', dependency: 'failure'}), false, 'the label cannot admit a dependency bot');
  assert.equal(runs({repository: 'lavasecurity/lavasec-ios'}), false);
  assert.equal(runs({repository: 'someone/lavasec-ios-internal'}), false);
  // Routine PRs are off this lane now; the `full-build` label is the on-demand switch.
  assert.equal(runs({}), false, 'an unlabelled PR must not schedule the native build');
  assert.equal(runs({labels: ['other']}), false);
  assert.equal(runs({labels: ['full-build']}), true);
  assert.equal(runs({labels: ['full-build'], fork: true}), false, 'the label cannot admit another repo');
  assert.equal(runs({labels: ['full-build'], headRepo: 'someone/lavasec-ios-internal'}), false);
  assert.equal(runs({labels: ['full-build'], docs: 'true'}), false);
  assert.equal(runs({labels: ['full-build'], native: 'false'}), false);
  // Drafts are inert: the label does not make a draft run, and `ready_for_review`
  // is the event that flips `draft` false (the workflow subscribes to it).
  assert.equal(runs({draft: true}), false);
  assert.equal(runs({draft: true, labels: ['full-build']}), false, 'a labelled draft still must not run');
  // A main push keeps the classifier as its only scope: no label, no PR context.
  assert.equal(runs({event: 'push'}), true);
  assert.equal(runs({event: 'push', native: 'false'}), false);
});

for (const prepare of ['prepare-full-app.sh','prepare-review-host.sh']) {
  for (const yogaFails of [true,false]) {
    test(`${prepare} requires the real-layout gate before bundling (${yogaFails?'failure':'success'})`, t => {
      const root=mkdtempSync(join(tmpdir(),'lava-prepare-layout-'));
      t.after(()=>rmSync(root,{recursive:true,force:true}));
      const app=join(root,'ReactNative'),bin=join(root,'bin'),trace=join(root,'trace.jsonl');
      mkdirSync(join(app,'scripts'),{recursive:true});mkdirSync(bin);
      copyFileSync(new URL(`../scripts/${prepare}`,import.meta.url),join(app,'scripts',prepare));
      for(const tool of ['npm','node','bundle']) {
        writeFileSync(join(bin,tool),`#!${process.execPath}\nimport {appendFileSync} from 'node:fs';\nconst tool=${JSON.stringify(tool)},args=process.argv.slice(2);\nappendFileSync(${JSON.stringify(trace)},JSON.stringify({tool,args})+'\\n');\nif(tool==='node')process.exit(${yogaFails?42:0});\nif(tool==='bundle')process.exit(43);\n`,{mode:0o755});
      }
      const result=spawnSync('bash',[join(app,'scripts',prepare),join(root,'build'),join(root,'evidence')],{encoding:'utf8',timeout:30000,env:{...process.env,PATH:`${bin}:${process.env.PATH}`}});
      const calls=readFileSync(trace,'utf8').trim().split('\n').map(line=>JSON.parse(line));
      assert.equal(result.status,yogaFails?42:43,result.stderr);
      const layout=calls.findIndex(call=>call.tool==='node'&&call.args[0]==='scripts/test-story-columns-layout.mjs');
      assert.ok(layout>=0,'Native preparation must execute the Yoga gate.');
      const bundle=calls.findIndex(call=>call.tool==='npm'&&call.args.join(' ')==='run bundle:review');
      assert.ok(yogaFails?bundle<0:bundle>layout,'A failed layout gate must stop preparation before bundling.');
    });
  }
}
