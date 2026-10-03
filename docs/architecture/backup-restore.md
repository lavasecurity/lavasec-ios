# Reviewed backup restore

`BackupRestorePlan` in AppServices owns resolver validation, the effective restored pair
and its before/after review. It normalizes the whole library and projects its active filter
into the configuration. `FilterReplacementSummary` in Kit reuses `FilterConfigurationDiff`
for filter changes, including custom source definitions replaced under an existing ID.
Custom names resolve from the reviewed filter, and changed accepted-content versions get
a separate notice because they can change which cached rules are usable.

`BackupController` owns the transient envelope and unlock material. **Review Backup** only
unlocks and prepares a review. **Restore Backup** consumes that review once, validates its
current basis and calls the hub's persistence owner under a maintenance lease. The reviewed
envelope and any new unlock key remain in memory during that asynchronous write. Closing
the review discards it. A cancelled unlock cannot leave a later review pending.

After a durable configuration write, the controller rechecks account, lifecycle,
replacement token, deletion intent and the exact previous local backup state. A changed
account, pre-commit failure or newer local backup discards the review without persisting its
ciphertext or key. This also holds after relaunch: no uncommitted envelope exists to be
mistaken for enabled backup. The controller reconciles normalized configuration in memory,
then commits the local key/envelope and explicit enablement without another suspension.
A synchronous commit failure restores the prior envelope and upload evidence before any
fallible key rollback. Configuration already committed by the hub is not rolled back. The hub returns a distinct
completion when the pair landed but later artifact publication failed; the controller still
commits its working key/envelope and the UI says “Backup restored” with “Filtering could
not update.” Cancellation before apply prevents the write; cancellation after a durable
pair cannot discard its working key for the same account. Account replacement still
prevents the old review from enabling backup for the new account.

Every restore method follows this boundary. Changed DNS settings require a separate
acknowledgement. Invalid primary/fallback endpoints, including dormant saved values, are
refused using the interactive resolver validator. Selected custom DNS is refused on Free;
restore does not substitute another resolver to satisfy the tier. Protection state, device
entitlement, chaining preferences, QA settings and the current persistence generation stay
local. A backup protection hint cannot start or stop the VPN or replace this device's saved intent.

The review labels protection as belonging to this iPhone and shows effective and saved DNS
settings, all recording preferences, earned Lava Guard unlocks, active filter and library
changes. The library comparison preserves numbered filter order, including reorder-only
changes that affect which non-active filters fit the current tier. Added and removed domain
rules are listed separately, so an added exception
cannot disappear among unchanged entries. Confirmation checks the in-memory pair and on-disk
configuration generation. The shared writer repeats the generation fence under its lock,
so an extension commit cannot be overwritten between review and persistence.

No phrase-derived verifier is stored on a server. Account access plus a phished recovery
phrase cannot be distinguished cryptographically from legitimate recovery; the validated,
explicit review is the binding defense. Backup metadata is not trusted device provenance.

`BackupRestorePlanTests` exercises validation, changes, stale confirmation and the actual
write fence. The executable native controller harness covers account changes, failed writes, relaunch
and local-backup ownership. App source checks cover commit order, separate UI actions, cancellation and
recording/DNS presentation. Simulator compilation verifies target wiring; it does not
establish physical-device consent, VoiceOver or VPN behavior.

## Import replacement

Shared imports use `ShareableFilterConfiguration.replacementSummary(for:)` and the same
`FilterReplacementSummary` to review removed/added blocklists, blocked domains and custom
source definitions. Allowed exceptions and DNS settings remain local. Selecting any
replacement target opens the review before authentication or mutation; active replacement
also carries removal counts into the existing destructive confirmation. After authentication,
the app rechecks the target and reconciled subset and requires a fresh review if either changed.
The existing active/inactive persistence and current-active-target guards remain the writers.
The unused onboarding-only direct-replacement mode has been removed.

## Confirmed account-deletion cleanup

Account removal acknowledges its Keychain preparation before the server request.
New preparations include a unique operation ID. If the server succeeds but the
Keychain becomes unreadable or rejects promotion to local cleanup, the controller
retains that confirmation in memory and attempts a supplemental local receipt.
Reload accepts the receipt only beside the exact readable version-3 preparation,
with matching account and operation IDs. It grants local cleanup only, never an
upload, enablement, or another account's remote deletion. This keeps partial key
retirement retryable after sign-out and, when the receipt is retained, relaunch.
Missing/corrupt proof or failure of all persistent confirmation writes remains
conservatively fenced after restart; defaults never replace the primary durable
fence. Completed Off and a later operation cannot inherit an old receipt.
