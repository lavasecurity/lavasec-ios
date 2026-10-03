# RN phone feedback — September 10, 2026

Baseline: `v1.5.0-rc4-rn`, source `6ced8013aeadecbed57be1e6caae52c9828002e5`,
Lava QA `1.5.0 (1788960943)`. Follow-up to the September 9 device checklist.
The operator authorized these fixes and a new tagged full-app QA build under LAV-168.

## Findings and implementation

| Report | Cause and correction | Evidence / remaining acceptance |
| --- | --- | --- |
| VPN chaining opens as a bottom sheet | Settings called `native.flow`. It now pushes the React-owned `VPNChaining` route containing the existing native settings destination, its controls and nested native navigation. Settings authorization, Back and tab reselection remain integrated. Legacy native redirects resolve to the same pushed route. Fabric recycling tears down the hosted controller so nested navigation and temporary native drafts cannot survive into another visit. | Native push, Back, visible tabs and reselection journey; physical saved-config editing remains device acceptance. |
| Activity structure disappears on child navigation | `useAppQuery` cleared data on blur and Activity conditionally removed the entire digest. The digest now stays mounted; its values update in place. Initial date metadata comes from the native app snapshot so Today does not wait for a separate bridge read. | Deferred-response component identity regression and native repeated child-navigation geometry journey. |
| Domain search/filtering collapses content and moves the title | Search previously sent a native report read per keystroke while also filtering the old result immediately. Search now settles for 200 ms; same-scope accepted rows remain until replacement, and a pending different scope reserves the prior measured content height, including the instruction/error note. Empty states retain their native spacing without a permanent placeholder gap. | Controlled-clock search, scope isolation, reserved-height and cache tests. A real result may resize once; first entry still needs an actual native read. |
| Returning pages show loading again | An app-owned, memory-only TanStack Query cache retains unprotected accepted reads for warm navigation, deduplicates identical pending reads and evicts inactive cache entries after 60 seconds. Focus refreshes in the background; normal five-second polling continues. | Hook tests cover blur/return, actual remount, decision-specific reuse, transient failure and late-result ordering. |

The cache is not persisted. Account/security/log-state changes revoke its scope;
clearing logs revokes before and after the native mutation. Inactivity and app
connection teardown clear cached reads. Protected surfaces keep fresh native
authorization and clear on departure. A JS cancellation cannot dismiss a native
credential prompt, so cache revocation waits for the underlying operation before
retrying; cancellation ends automatic prompts. The existing concealed Share setup
exception remains limited to `share.query`.

The embedded VPN page also rechecks the native Settings authorization when its
root returns from a native child or the app resumes. Its controls remain disabled
until that check succeeds; cancelling returns to Settings. This covers navigation
that stays inside SwiftUI and therefore emits no React authorization event, without
restoring any authentication turn revoked by a child or backgrounding.

This does not change report storage, native query sampling, resolver/tunnel behavior,
WireGuard secret storage, or the original SwiftUI app. RC4 and
`native-ui-reference-2026-09-08` remain immutable rollback/reference anchors.

## Verification record

- RED: the three new warm-navigation/decision-cache/transient-error regressions fail
  against the RC4 hook (13 existing cases pass).
- GREEN: `npm --prefix ReactNative test` passes 230 React tests, type checking,
  localization/token generation and the isolated-host boundary policy.
- `swift test --package-path . -Xswiftc -warnings-as-errors` passes 4,744 tests.
- The generated full-app graph and its 12 accept/reject policy tests pass.
- Initial targeted native run: VPN push/Back/tab reselection passed. Activity stopped
  on an incorrect test selector (`BackButton`; the native item is labelled `Back`),
  not a geometry assertion. The selector was corrected before final qualification.
- The 14-journey local full-app run passed before the final recycling correction.
  An expanded VPN journey then reproduced stale Plus navigation on re-entry after
  native tab pop. Explicit hosted-controller teardown fixes that component lifetime; the same
  expanded VPN journey then passes in 30 seconds.
- Review regressions: changed-query failures were attached to an old identity,
  suppressing errors; the loading flow bar announced false zero counts. Four
  assertions reproduced these problems. Errors now identify the attempted query,
  retained domain rows display the failure, and count accessibility waits for an
  accepted result. All 230 React tests then pass.
- Native authentication RED/GREEN: returning from VPN's Plus child reproduced a
  missing Settings prompt. The corrected passcode journey and unprotected VPN
  navigation journey both pass (2 tests, zero failures, 172 seconds), including
  cancelled return, backgrounding the child, and resuming the VPN root directly.
- CI sampling correction: Activity's height comparison passed, but the following
  stability wait exhausted its deadline while XCTest repeatedly expanded the
  deeply nested accessibility query. The helper now snapshots geometry explicitly
  without using that query as the predicate's diagnostic object, records sampled
  frames, and allows 20 seconds on the VM. It retains visibility and three
  unchanged-sample requirements. Activity and tab-reselection journeys then pass
  locally (2 tests, zero failures, 119 seconds); CI must qualify this correction.
- Final CI qualification and release receipts are recorded when complete in
  the infra portability plan. An initial run or an old RC4 receipt is not new-build
  evidence.

Phone acceptance: warm Activity/Top Domains/History navigation with populated logs,
rapid search and decision changes while traffic arrives, native VPN config editing,
background/foreground and protected-surface cancellation. Simulator checks do not
prove physical tunnel packet behavior. The prior September 9 device-only checks
remain open until tested on a phone.

## VPN configuration row follow-up

The configuration row now uses the shared control-row height and one chevron. The
44-point toolbar buttons previously increased even a single-line row to 64 points.
Delete moves to the editor sheet’s trailing toolbar and appears only for a saved
or unreadable record; deletion confirmation is presented by the sheet itself.
Successful deletion closes the sheet and clears its draft. Failed key cleanup
retains a retry path, including when eligibility has disabled chaining. The saved
label is “Last saved on [date]” with no time, using the native localized date.

Chain and DNS-fallback toggles, successful configuration saves, and full deletion now
schedule a reconnect when Guard is already running. An app-owned coordinator waits
500 ms after the latest successful commit, keeps one restart in flight, and merges
newer input into one follow-up. Failed commits cannot schedule a restart. Guard-off
or a newer explicit lifecycle intent invalidates queued work. The captured durable
external-Restart generation also prevents a Live Activity Restart from being followed
by an older queued apply. The reconnect checks current intent, generation and the
actual manager under the shared lifecycle fence. A successful follow-up clears an
earlier reconnect error.
The existing stop/drain/start path and its protection checks remain the authority.
The VPN page reports applying/error state and keeps the runtime-generation warning
until the tunnel confirms it adopted the saved generation. Saved keys are never
rehydrated into the editor. An editor opened from an ineligible state permits
removal but gates replacement, including after the confirmation is shown.

Initial UI validation passed 4,744 Swift tests, 230 React tests, localization and
string coverage, plus native VPN push/Back/tab-reselection (1 test, 32 seconds).
The buffered apply extension has deterministic burst, busy-lifecycle, in-flight
follow-up, and Guard-intent cancellation tests, with native persistence/fence
wiring checks. Final qualification follows the expanded PR head; the initial UI
run alone does not qualify the later lifecycle changes. Actual reconnection and
physical DNS traffic remain phone acceptance.

The initial buffered-apply Swift suite passed 4,755 tests, React passed 230 tests, and the
full RN app builds for the iOS device target without signing. Final simulator
qualification and PR review are recorded against the expanded source head.

The review follow-up adds two behavioral cases for external Restart before claim and
after claim, including a later settings edit that remains eligible. The native wiring
check also covers strict generation reads and success clearing the previous error.

Review follow-up validation: 4,758 Swift tests passed, including nine debounce/intent
behavior tests and five native wiring checks. The full RN iOS device build passed
without signing. RN simulator lifecycle CI must also qualify the final PR head.

Strict generation-read failures are surfaced even after an apply is claimed; a
transient shared-state lock refusal cannot silently consume the saved change. The
continuation fails closed and the page retains its error until the next apply.
