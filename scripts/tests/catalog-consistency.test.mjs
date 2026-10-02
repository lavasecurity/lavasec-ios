import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import { catalogConsistencyFindings, loadCatalogs, validateServedCatalog } from "../check-catalog-sources.mjs";

const sources = ["hagezi-social", "hagezi-anti-piracy"].map(id => ({
  id, source_url: `https://lists.example/${id}.txt`, version_id: `${id}-v1`, entry_count: 898,
  name: id, category: "social", risk_level: "low", default_enabled: false, license_name: "GPL-3.0",
  attribution: "HaGeZi", project_url: "https://lists.example", byte_size: 14226, source_hash: "a".repeat(64),
  normalized_hash: "b".repeat(64), published_at: "2026-09-29T00:00:00Z", redistribution_mode: "source_url_only",
  parse_format: "plain_domains", accepted_source_hashes: [{sha256: "a".repeat(64), status: "accepted"}]
}));
const expected = { sources };
test("schema fixtures cover the required Swift Codable keys", () => {
  const swift = fs.readFileSync(new URL("../../Sources/LavaSecKit/CatalogSourceModels.swift", import.meta.url), "utf8");
  const requiredKeys = name => {
    const marker = `public struct ${name}:`;
    const start = swift.indexOf(marker);
    assert.notEqual(start, -1, `missing ${name}`);
    const body = swift.slice(start).split(/\npublic struct /)[0];
    const properties = body.slice(0, body.indexOf("public init("));
    const required = [...properties.matchAll(/public let (\w+): ([^\n]+)/g)]
      .filter(([, , type]) => !type.includes("?"));
    const codingKeys = body.match(/enum CodingKeys: String, CodingKey \{([\s\S]*?)\n    \}/);
    assert.ok(required.length && codingKeys, `could not read ${name} schema`);
    const names = new Map([...codingKeys[1].matchAll(/case (\w+)(?: = "([^"]+)")?/g)]
      .map(([, property, alias]) => [property, alias ?? property]));
    return required.map(([, property]) => {
      assert.ok(names.has(property), `${name}.${property} lacks a coding key`);
      return names.get(property);
    }).sort();
  };
  assert.deepEqual(Object.keys(sources[0]).sort(), requiredKeys("CatalogBlocklistSource"));
  assert.deepEqual(Object.keys(sources[0].accepted_source_hashes[0]).sort(), requiredKeys("CatalogAcceptedSourceHash"));
});
test("the live checker loads both client endpoints even with a healthy primary", async t => {
  const requested = [];
  t.mock.method(globalThis, "fetch", async url => {
    requested.push(url);
    return new Response(JSON.stringify({schema_version: 2, catalog_version: "test", generated_at: "2026-09-29T00:00:00Z",
      sources: url.includes("workers.dev") ? [] : sources, guardrails: []}));
  });
  const catalogs = await loadCatalogs(false);
  assert.deepEqual(requested, ["https://api.lavasecurity.app/v1/catalog", "https://lavasec-api.lavasec.workers.dev/v1/catalog"]);
  assert.deepEqual(catalogConsistencyFindings(expected, catalogs[0].catalog), []);
  assert.equal(catalogConsistencyFindings(expected, catalogs[1].catalog).length, 2);
});
test("both endpoints reject incomplete source rows, including a malformed fallback", async t => {
  const catalog = {schema_version: 2, catalog_version: "test", generated_at: "2026-09-29T00:00:00Z", sources, guardrails: []};
  validateServedCatalog(catalog);
  for (const key of Object.keys(sources[0])) {
    const source = {...sources[0]}; delete source[key];
    assert.throws(() => validateServedCatalog({...catalog, sources: [source]}), /invalid or missing/, key);
  }
  const malformed = {...sources[0]}; delete malformed.byte_size;
  t.mock.method(globalThis, "fetch", async url => new Response(JSON.stringify(
    url.includes("workers.dev") ? {...catalog, sources: [malformed]} : catalog)));
  await assert.rejects(loadCatalogs(false), /workers\.dev.*byte_size/);
  assert.throws(() => validateServedCatalog({...catalog, sources: [{...sources[0], accepted_source_hashes: [{sha256: "a"}]}]}), /accepted_source_hashes/);
});
test("both published HaGeZi lists satisfy the adopted catalog", () => {
  assert.deepEqual(catalogConsistencyFindings(expected, { sources: [...sources].reverse() }), []);
});
test("all runtime timestamps require an explicit timezone", () => {
  const catalog = {schema_version: 2, catalog_version: "test", generated_at: "2026-09-29T00:00:00Z", sources, guardrails: []};
  const localTime = "2026-09-29T00:00:00";
  assert.throws(() => validateServedCatalog({...catalog, generated_at: localTime}), /generated_at/);
  assert.throws(() => validateServedCatalog({...catalog, sources: [{...sources[0], published_at: localTime}]}), /published_at/);
  for (const key of ["reviewed_at", "expires_at"]) {
    assert.throws(() => validateServedCatalog({...catalog, sources: [{...sources[0],
      accepted_source_hashes: [{...sources[0].accepted_source_hashes[0], [key]: localTime}]}]}), new RegExp(key));
  }
  for (const generated_at of ["2026-09-29T00:00:00.123Z", "2026-09-29T00:00:00+09:00"]) {
    validateServedCatalog({...catalog, generated_at});
  }
});
test("a healthy but incomplete production catalog fails for both missing seeds", () => {
  const findings = catalogConsistencyFindings(expected, { sources: [] });
  assert.equal(findings.length, 2);
  assert.match(findings[0], /Missing published source: hagezi-social/);
  assert.match(findings[1], /Missing published source: hagezi-anti-piracy/);
});
test("partial publication still fails", () => {
  assert.match(catalogConsistencyFindings(expected, { sources: sources.slice(0, 1) })[0], /hagezi-anti-piracy/);
});
test("case-insensitive duplicates match the device decoder while membership stays exact", () => {
  const findings = catalogConsistencyFindings(expected, { sources: [
    ...sources, {...sources[0], id: "HaGeZi-Social"}
  ]});
  assert.ok(findings.some(finding => /Duplicate published source: HaGeZi-Social/.test(finding)));
  const renamed = catalogConsistencyFindings(expected, { sources: [
    {...sources[0], id: "HaGeZi-Social"}, sources[1]
  ]});
  assert.ok(renamed.some(finding => /Missing published source: hagezi-social/.test(finding)));
});
test("URL drift, duplicate IDs, removed sources and unusable versions fail", () => {
  const findings = catalogConsistencyFindings(expected, { sources: [
    {...sources[0], source_url: "https://different.example/list", version_id: null, entry_count: 0},
    sources[1], sources[1], {id: "retired", source_url: "https://lists.example/retired"}
  ]});
  assert.equal(findings.length, 4);
  for (const pattern of [/URL differs/, /Duplicate/, /absent from adopted/, /lacks a usable/]) {
    assert.ok(findings.some(finding => pattern.test(finding)));
  }
});
