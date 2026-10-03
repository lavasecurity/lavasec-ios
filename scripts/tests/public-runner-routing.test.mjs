import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
function job(workflow, name) {
  const text = fs.readFileSync(path.join(root, '.github/workflows', workflow), 'utf8');
  const block = text.split(`\n  ${name}:\n`)[1].split(/\n  [a-z][\w-]*:\n/)[0];
  return Object.fromEntries(['if', 'runs-on'].map(key => [key, block.match(new RegExp(`^    ${key}: (.+)$`, 'm'))?.[1]]));
}
function evaluate(value, github, cancelled = false) {
  if (!value.startsWith('${{')) return value;
  return Function('github', 'fromJSON', 'cancelled', `return (${value.slice(3, -2)});`)(github, JSON.parse, () => cancelled);
}
function context(repo, kind = 'trusted', event = 'pull_request') {
  return { repository: repo, event_name: event, event: { pull_request: {
    draft: false, head: { repo: { full_name: kind === 'fork' ? 'contributor/lavasec-ios' : repo } },
    user: { login: kind === 'bot' ? 'dependabot[bot]' : 'contributor' }
  } } };
}

const packageJob = job('ios.yml', 'swift-package-tests');
const appJob = job('ios.yml', 'ios-simulator-build');
const linuxJobs = [job('ios.yml', 'changes'), job('ios.yml', 'repo-checks'), job('react-native-ui.yml', 'lava-ui'), job('catalog-health.yml', 'sources')];

test('public source and forks use hosted runners, including dependency PRs', () => {
  for (const repo of ['lavasecurity/lavasec-ios', 'contributor/lavasec-ios', 'contributor/lavasec-ios-internal']) {
    for (const kind of ['trusted', 'fork', 'bot']) {
      const ctx = context(repo, kind);
      assert.equal(evaluate(packageJob.if, ctx), true);
      assert.deepEqual(evaluate(packageJob['runs-on'], ctx), ['macos-26']);
      for (const lane of linuxJobs) assert.equal(evaluate(lane['runs-on'], ctx), 'ubuntu-latest');
      assert.equal(evaluate(appJob.if, ctx), repo === 'lavasecurity/lavasec-ios');
      assert.equal(appJob['runs-on'], 'macos-26');
    }
  }
});

test('trusted internal PRs and pushes retain the fixed owned runner', () => {
  for (const event of ['pull_request', 'push', 'workflow_dispatch']) {
    const ctx = context('lavasecurity/lavasec-ios-internal', 'trusted', event);
    assert.equal(evaluate(packageJob.if, ctx), true);
    assert.deepEqual(evaluate(packageJob['runs-on'], ctx), ['self-hosted', 'macOS']);
    for (const lane of linuxJobs) assert.equal(evaluate(lane['runs-on'], ctx), 'ubicloud-standard-2');
    assert.equal(evaluate(appJob.if, ctx), false);
  }
});

test('untrusted internal PRs cannot enter persistent macOS hosts', () => {
  for (const kind of ['fork', 'bot']) {
    const ctx = context('lavasecurity/lavasec-ios-internal', kind);
    assert.equal(evaluate(packageJob.if, ctx), false);
    assert.deepEqual(evaluate(packageJob['runs-on'], ctx), ['macos-26']);
    assert.equal(evaluate(appJob.if, ctx), false);
    for (const lane of linuxJobs) assert.equal(evaluate(lane['runs-on'], ctx), 'ubuntu-latest');
  }
});

test('draft and cancelled macOS jobs remain inactive', () => {
  for (const repo of ['lavasecurity/lavasec-ios', 'lavasecurity/lavasec-ios-internal']) {
    const ctx = context(repo);
    assert.equal(evaluate(packageJob.if, ctx, true), false);
    assert.equal(evaluate(appJob.if, ctx, true), false);
    ctx.event.pull_request.draft = true;
    assert.equal(evaluate(packageJob.if, ctx), false);
    assert.equal(evaluate(appJob.if, ctx), false);
  }
});

test('public CodeQL main/scheduled analysis uses hosted macOS', () => {
  const codeQL = job('codeql.yml', 'analyze');
  for (const event of ['push', 'schedule', 'workflow_dispatch']) {
    assert.equal(evaluate(codeQL.if, context('lavasecurity/lavasec-ios', 'trusted', event)), true);
    assert.equal(evaluate(codeQL.if, context('lavasecurity/lavasec-ios-internal', 'trusted', event)), false);
    assert.equal(codeQL['runs-on'], 'macos-26');
  }
});
