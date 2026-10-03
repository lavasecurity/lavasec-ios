# Protection notification ownership

Artifact recovery triage precedes notification delivery. `FilterArtifactRecoveryAssessment`
combines current tunnel service, reload progress and app-owned repair outcomes. The app
records attempts in `filter-artifact-repair.json`; concurrent attempts for the same configuration
remain repairing until they finish. Work on a superseded generation cannot strand a completed
refresh or overwrite its evidence. Evidence is scoped to the filter fingerprint, persisted configuration
generation and current limits, excluding catalog freshness. A completed foreground refresh
binds its result to the configuration it persisted. Evidence must follow the current
incident's first blocked client query. Unknown,
prior-incident, future-dated or older-than-ten-minute evidence cannot request action.

| Repair evidence | Result while DNS remains blocked |
| --- | --- |
| A usable resident or configuration-matched last-known-good artifact | Serve silently |
| Reload or app repair running | Wait silently |
| Source/network failure, cancellation, publication contention or unknown cause | Keep automatic retry; no user-action claim |
| Artifact published | Await tunnel adoption; publication alone is not recovery |
| Refresh completed but selected rules exceed the tier limit | Ask the user to review the selection |
| Background custom-cache loading failed and foreground custom refresh is permitted | Ask the user to open Lava to refresh custom sources |

The last two outcomes are specific remedies unavailable to the background path while
preserving current user choices. They are not inferred from elapsed time or retry counts.
An app wake delayed by iOS is not itself a reason to notify. Cached reconstruction and
curated downloads keep their existing execution owners. PR #682 repairs unchanged-input
artifacts through that same publisher. The tunnel exhausts candidate and last-known-good
checks before failing closed, enforcing each candidate's memory/tier limits before use.
A resident for a different user selection cannot substitute for the selected filter.

Three package boundaries then own notification behavior:

- `ProtectionConnectivityNotificationPolicy` decides whether current evidence warrants a
  notice, its priority, recovery and cooldown. Warm artifact reuse stays silent. A filter
  repair notice requires an explicit triage intervention, actual client DNS impact and a
  30-second debounce. The delay is not evidence of exhausted recovery. Resumed repair
  invalidates pending delivery; a retry or aging evidence does not resolve a delivered
  incident or renew its notification eligibility. Actual recovery clears it silently.
  Resolver recovery preserves a lower-priority banner while filtering still blocks DNS,
  allowing an actionable filter notice to escalate after its grace period.
- `ProtectionNotificationDeliveryState` owns one process's latest posture, authorization and
  submission attempt, retry deadline and shutdown invalidation. Every completion carries an
  attempt token. Final submission and history claims must match the current incident ID,
  including its failure timestamp. Recovery during either asynchronous boundary prevents a claim.
  Submission failures and unavailable history back off for 60 seconds; a more serious incident
  can preempt that retry once history is readable. Each attempt owns a unique system request
  ID, separate from the incident ID used for deduplication.
  Contended history reconciliation retains a cleanup retry even after recovery, with an older
  submission in flight, or when notification preferences are disabled. Successful history access
  clears cleanup backoff without shortening failed-delivery backoff. Shutdown invalidates both.
- `ProtectionConnectivityNotificationStore` owns the shared history file. Both producers use
  the same nonblocking transaction to reconcile recovery and claim successful delivery.
  Legacy defaults are read only until the history file is first written.

The app controller runs the state on the main actor; the provider owns its state on the DNS
queue. Their adapters read current permissions/preferences, invoke system notification APIs,
schedule the returned retry deadline and remove obsolete requests. The provider refreshes
its live posture and configuration-scoped repair evidence before asynchronous completions.
Completion of the current reload reevaluates triage after releasing in-flight ownership.
The existing 60-second configuration poll also rechecks outstanding filter incidents before
its generation guards. Completed app evidence is therefore observed in both modes even
without a resolver probe, new configuration, or further client query. No extra timer is added.
App health publications update the same state observed by its pending task.
Teardown invalidates attempts and cancels submitted IDs;
a completion after provider release can still remove its unowned request.

Cleanup removes the attempt's unique request directly, without acquiring the history lock.
An old callback therefore cannot remove a new producer's submission for the same incident,
and lock contention cannot drop teardown cleanup. History retains the winning request ID for
later recovery or escalation. The shared lock is never held during authorization, submission
or removal. Actual system delivery and removal timing remain OS-controlled and need
physical-device verification.

`ProtectionNotificationDeliveryStateTests` exercise lifecycle transitions and late callbacks.
`ProtectionConnectivityNotificationPolicyTests` cover evidence, priority, cooldown and atomic
cross-process claims. `FilterArtifactRecoveryTests` cover remedies, current intent, overlapping
attempts, stale completions, invalid evidence and the distinction between publication and
adoption. A filter incident uses its fixed outage start and current remedy; continued blocked
traffic proves freshness without replacing its pending request. Source tests pin adapter wiring.

Before this change, an app-background filter outage had only in-app guidance. This change
adds an outside-app notice only for the two evidenced remedies above; it does not notify
for every outage or guarantee immediate background execution. Notification taps navigate
to Guard without changing protection, DNS routing or the user's selected lists. Both
DNS-only and chained mode use the same artifact triage; DNS recovery retains its existing
mode-specific authority. The existing incident ledger records fail-closed entry and actual
recovery; catalog action traces include the typed repair outcome. Neither reads historical
incidents as authority to perform a repair or notify.
