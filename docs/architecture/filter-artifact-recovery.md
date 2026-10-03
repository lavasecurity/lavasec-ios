# Filter artifact recovery

The catalog publisher shares one warm-readiness check for foreground and background
refresh. `FilterArtifactStore.needsCompactArtifactRepair` checks the current manifest,
configuration, catalog, coverage, parser, recorded tier budget and device budget, then
checks the mapped compact bytes against their SHA-256 checksum in the manifest. The
single publisher records the checksum of the encoded payload before publishing its manifest.
This catches altered rule bytes even when lengths, counts and ordering remain valid,
without decoding resident rule arrays. Legacy artifacts without a stored summary or
checksum require repair on refresh; their existing startup fallback remains available.
The checksum detects corruption and does not authenticate an upstream publisher.

An unchanged identity skips publication only when this check succeeds. A surviving
manifest with a missing or damaged compact file triggers the existing compiler and
atomic publisher. A prepared JSON fallback may keep a tunnel working temporarily;
the publisher still restores the compact form needed for predictable warm startup.
Validation runs off the app's main actor, and a changed configuration or catalog
invalidates its no-publication result. Background cancellation and publication
generation/pointer checks remain authoritative.
Cancellation reaches the validation task and is checked every MiB of checksum input.
Foreground refresh persists accepted sync metadata even when coverage or budget vetoes
the artifact flip. Only a successful artifact publication notifies the tunnel.

This repairs the artifact without requiring a new upstream list version. It does
not change the user's selection, DNS mode, custom-source refresh permissions or
fallback acceptance rules. A failed refresh preserves existing last-known-good
artifacts. Background execution still depends on iOS scheduling and available
network/storage resources; a publication does not itself prove tunnel adoption.

Artifact triage and last-resort user intervention consume this repair foundation;
their owners and evidence requirements are documented in `protection-notifications.md`.
