# Catalog input boundary

`BlocklistCatalog` validates decoded remote and cached metadata before it reaches snapshot
identity maps, cache paths or budget arithmetic. The catalog contains at most 512 combined
community/guardrail sources. IDs are unique ignoring case across both tiers, contain 1–128 ASCII letters,
digits, dots, underscores or hyphens, and cannot be `.` or `..`. This prevents duplicate-key
traps, parent-directory IDs and collisions from path sanitization or case-insensitive storage.
Version IDs are limited to 238 UTF-8 bytes, reserving 17 bytes for the cache filename's hash
suffix and extension within the 255-byte component limit.

Rule/byte counts, including accepted-hash metadata, must be nonnegative. Rule counts cannot
exceed the existing source-download byte ceiling: even a one-byte rule cannot produce more
entries than that. Together with the 512-source cap, this leaves headroom for local-rule
counts and background warm-pass totals, including estimates for unresolved sources. Source URLs must be absolute public HTTPS URLs without credentials,
using the same endpoint validator as custom lists. The existing pinned HTTPS fetcher still
validates resolved addresses and redirects when downloading; metadata checks do not replace
that connection boundary. The repository retains its 8 MiB decode ceiling and tries valid
remote metadata, valid cached metadata, then the bundled source-URL catalog.

These are input-safety checks. Production catalog authorization is not yet activated:
a compromised catalog publisher can still substitute a different public HTTPS source or
its content metadata. No production signing key or licensed threat-guardrail dataset is
provisioned here.
Catalog definition authorization is described below; per-update community-content signing
is outside its scope. Runtime filtering still requires a usable artifact or
successful preparation; catalog fallback does not permit unfiltered DNS.

## Catalog definition authorization (staged)

The additive `catalog_authorization` field binds the complete source and guardrail
inventories plus cumulative `withdrawn_sources`. Ed25519 verification uses only public
keys pinned in `CatalogTrustPolicy`; a catalog cannot supply a trusted key. The signed
payload is domain-separated (`Lava catalog definitions v1\n`) and carries its own format,
key ID, inventory revision and issuance/expiry. Decoder schema remains 2 so existing
clients can ignore the additions. A shared Node-generated fixture pins interoperability.

This authenticates Lava's directory, not each provider content update. URL, parser,
membership/tier, redistribution, display and legal fields are signed. Selection policy
is owned by each app; the legacy `default_enabled` field is not signed. The source
hashes/counts/version/published-at remain advisory for ordinary community lists. Existing
upstream rotation, custom lists and strict guardrail hash checks are unchanged. This does
not authenticate an upstream provider's bytes or introduce an approved domain list.

Resolved catalogs retain the exact authorization while updating local source observations.
The repository revalidates authorization on network and cached reads and before writes.
Successful catalog commits record the signed inventory in a separately locked, atomic checkpoint;
older revisions, conflicting same-revision definitions and removal of withdrawal history
are refused. A same-revision renewal may extend validity without changing source definitions.
Every source/guardrail removed in a newer revision must be recorded in its withdrawals.
Expiry comes from signed seconds, not cache mtime. A retired key may remain in checkpoint-only
pins to permit migration; it cannot authorize new incoming catalogs. Resetting app storage
resets local replay history. The clock and same-team app-group boundary remain assumptions.
With configured pins, cache freshness requires valid authorization as well as recent mtime;
unsigned upgrade caches and expired signatures trigger a network refresh immediately.

Network admission reads do not advance the checkpoint: a cancelled background refresh or
publication-only import check cannot invalidate the last committed catalog. A valid committed
latest catalog also supplies the replay floor after a crash between its rename and checkpoint
persistence. Foreground commits follow successful compilation; background commits use the same
authorization boundary immediately before the artifact pointer flip.

Production currently has **no public keys and compatibility mode remains enabled**. Envelopes
are ignored until keys are configured, preserving the pre-pin rollout's old-reader behavior. This PR
must not claim active publisher-compromise protection. Commission the signer and signed
publications first, then ship a reviewed pin/enforcement change. Strict mode never admits
unsigned remote/cache metadata or the unsigned bundled fallback. Compatibility mode also
refuses unsigned downgrade once it has committed a signed catalog with configured pins. Still-valid signed cache
can cover a bad remote update; no catalog signature failure is converted into a custom list.
Existing already-prepared artifacts are not retroactively deleted by this admission layer;
withdrawal takes effect through the existing source-selection and preparation pipeline.

Activation requires candidate/device upgrade testing, signing-key provisioning and regular
renewal. Runtime protection must not be described as having an immediate revocation channel:
offline devices cannot learn new withdrawals, and retained filtering artifacts have their
existing lifecycle. Key retirement and expired-catalog availability need explicit rollout
review. No new threat-guardrail rules or signing secrets are included here.
