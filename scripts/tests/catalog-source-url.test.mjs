import assert from 'node:assert/strict';
import test from 'node:test';
import fs from 'node:fs';
import { fetchCatalogSource } from '../check-catalog-sources.mjs';

const good = 'https://raw.githubusercontent.com/owner/list/main/hosts.txt';
test('untrusted source URLs fail before any network request', async () => {
  let requests = 0;
  const fetcher = async () => { requests++; throw new Error('must not fetch'); };
  for (const url of ['http://169.254.169.254/latest', 'https://127.0.0.1/', 'https://[::1]/',
    'https://internal.example/', 'https://user:pass@raw.githubusercontent.com/file',
    'https://raw.githubusercontent.com:8443/file', 'https://raw.githubusercontent.com.attacker.example/file', 'file:///etc/passwd', 'invalid']) {
    await assert.rejects(fetchCatalogSource(url, undefined, fetcher));
  }
  assert.equal(requests, 0);
});

test('redirects are admitted before following, and redirect bodies are released', async () => {
  for (const target of ['http://127.0.0.1/', 'https://169.254.169.254/', 'https://private.example/']) {
    const requests = []; let cancelled = false;
    await assert.rejects(fetchCatalogSource(good, undefined, async (url, options) => {
      requests.push(url); assert.equal(options.redirect, 'manual');
      return { status: 302, headers: new Headers({ location: target }), body: { cancel: async () => { cancelled = true; } } };
    }));
    assert.deepEqual(requests, [good]); assert.equal(cancelled, true);
  }
});

test('relative and reviewed CDN redirects retain timeout and request policy', async () => {
  const controller = new AbortController(); const requests = [];
  const targets = ['../other.txt', 'https://cdn.jsdelivr.net/gh/owner/list/hosts.txt'];
  const final = { status: 200 };
  const result = await fetchCatalogSource(good, controller.signal, async (url, options) => {
    requests.push(url); assert.equal(options.signal, controller.signal);
    assert.equal(options.redirect, 'manual'); assert.equal(options.headers['Accept-Encoding'], 'identity');
    return targets.length ? { status: 307, headers: new Headers({ location: targets.shift() }) } : final;
  });
  assert.equal(result, final);
  assert.deepEqual(requests, [good, 'https://raw.githubusercontent.com/owner/list/other.txt', 'https://cdn.jsdelivr.net/gh/owner/list/hosts.txt']);
});

test('all adopted source and guardrail URLs remain admitted', async () => {
  const catalog = JSON.parse(fs.readFileSync(new URL('../../Catalog/blocklist-catalog.json', import.meta.url), 'utf8'));
  let requests = 0;
  for (const entry of [...catalog.sources, ...(catalog.guardrails || [])]) {
    await fetchCatalogSource(entry.source_url, undefined, async () => { requests++; return { status: 200 }; });
  }
  assert.equal(requests, catalog.sources.length + (catalog.guardrails?.length || 0));
});

test('redirect loops and missing locations fail with bounded requests', async () => {
  let requests = 0;
  await assert.rejects(fetchCatalogSource(good, undefined, async () => {
    requests++; return { status: 301, headers: new Headers({ location: good }) };
  }), /20 redirects/);
  assert.equal(requests, 21);
  await assert.rejects(fetchCatalogSource(good, undefined, async () => ({status: 302, headers: new Headers()})), /Location/);
});
