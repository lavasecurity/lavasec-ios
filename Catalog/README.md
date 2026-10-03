# Catalog and app selection policy

`blocklist-catalog.json` is a generated snapshot of `lavasecurity/lavasec-filters/catalog/lists.json`, pinned by the neighboring source file and checked against that immutable commit in CI. The shared catalog has no `default_enabled` policy.

`default-selection.json` is iOS-owned onboarding recommendation policy. The generator combines those IDs with available sources while keeping the existing legal guards. Users still choose lists; saved selections are not overwritten by catalog updates.

Adopt with `node scripts/sync-filter-catalog.mjs Catalog/blocklist-catalog.json --ref COMMIT_SHA`, then run `node scripts/generate-blocklist-catalog.mjs`. Edit recommendations here, list definitions in filters.
