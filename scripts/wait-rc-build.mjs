#!/usr/bin/env node
// Actions:write on the existing runner-scoped PAT includes the Actions read used here.
// gh run watch requires checks access with some token types; query the run API directly.
import { execFileSync } from 'node:child_process';
import { appendFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';

export function runId(url) {
  const match = /^https:\/\/github\.com\/lavasecurity\/lavasec-runner\/actions\/runs\/([1-9][0-9]*)$/.exec(url);
  if (!match) throw new Error('Expected an exact lavasec-runner Actions run URL.');
  return match[1];
}

export async function waitForBuild(url, {
  read = id => JSON.parse(execFileSync('gh', ['api', `repos/lavasecurity/lavasec-runner/actions/runs/${id}`], { encoding: 'utf8', timeout: 30000 })),
  sleep = ms => new Promise(resolve => setTimeout(resolve, ms)),
  now = Date.now,
  timeoutMs = 145 * 60 * 1000,
  report = console.log,
} = {}) {
  const id = runId(url);
  const deadline = now() + timeoutMs;
  let errors = 0;
  let previous;
  while (now() < deadline) {
    let run;
    try {
      run = read(id);
      if (String(run.id) !== id) throw new Error('Run ID mismatch');
      errors = 0;
    } catch (error) {
      if (++errors >= 3) throw new Error(`Cannot read build status after three attempts: ${url}`, { cause: error });
      await sleep(30000);
      continue;
    }
    const state = `${run.status}: ${run.conclusion || 'pending'}`;
    if (state !== previous) report(`${state} — ${url}`);
    previous = state;
    if (run.status === 'completed') {
      if (run.conclusion !== 'success') throw new Error(`Build ${run.conclusion || 'has no successful conclusion'}: ${url}`);
      return;
    }
    await sleep(30000);
  }
  throw new Error(`Timed out waiting for build; inspect the downstream run before retrying: ${url}`);
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const url = process.argv[2];
  try {
    await waitForBuild(url);
    if (process.env.GITHUB_STEP_SUMMARY) appendFileSync(process.env.GITHUB_STEP_SUMMARY, `Build succeeded: ${url}\n`);
  } catch (error) {
    console.error(`::error::${error.message}`);
    if (process.env.GITHUB_STEP_SUMMARY) appendFileSync(process.env.GITHUB_STEP_SUMMARY, `${error.message}\n`);
    process.exitCode = 1;
  }
}
