import test from 'node:test';
import assert from 'node:assert/strict';
import { runId, waitForBuild } from '../wait-rc-build.mjs';
const url = 'https://github.com/lavasecurity/lavasec-runner/actions/runs/123';
function fixture(states) {
  let clock = 0;
  return { read: () => { const next = states.shift(); if (next instanceof Error) throw next; return { id: 123, ...next }; }, sleep: async ms => { clock += ms; }, now: () => clock, timeoutMs: 90000, report: () => {} };
}
test('uses only the exact runner URL returned by dispatch', () => {
  assert.equal(runId(url), '123');
  for (const value of [url + '/jobs', url + '\n', url.replace('lavasecurity', 'attacker'), '123', '']) assert.throws(() => runId(value));
});
test('queued and running do not count as success', async () => {
  await waitForBuild(url, fixture([{status:'queued'}, {status:'in_progress'}, {status:'completed', conclusion:'success'}]));
});
for (const conclusion of ['failure', 'cancelled', 'timed_out', 'skipped', null]) test(`rejects ${conclusion}`, async () => {
  await assert.rejects(waitForBuild(url, fixture([{status:'completed', conclusion}])));
});
test('retries transient reads without dispatching another build', async () => {
  await waitForBuild(url, fixture([new Error('network'), {status:'completed', conclusion:'success'}]));
});
test('fails after repeated read errors', async () => {
  await assert.rejects(waitForBuild(url, fixture([new Error(), new Error(), new Error()])), /three attempts/);
});
test('times out an indefinitely queued build', async () => {
  await assert.rejects(waitForBuild(url, fixture(Array(3).fill({status:'queued'}))), /Timed out/);
});
test('cannot accept another build ID', async () => {
  await assert.rejects(waitForBuild(url, fixture(Array(3).fill({id:456, status:'completed', conclusion:'success'}))), /three attempts/);
});
