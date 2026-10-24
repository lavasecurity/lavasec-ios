# App protection follows the foreground session

**Security → Open Lava** alone opts into the app protection cover. A passcode,
biometrics, or another protected action does not opt into a global lock. Scoped
access gates remain enforced independently, including after backgrounding.

The saved display choice is separate from conservative access gates. An unreadable
credential may deny every read without turning a confirmed Open Lava OFF into ON.
Keep the last classified choice if the projection temporarily becomes unreadable.
A cold launch with no readable choice stays conservative until native can classify
it; confirmed credential absence means OFF. The atomic record keeps explicit ON,
OFF and unknown cover consent separately from repaired access gates. A durable
last-known choice survives record corruption; a legacy OFF set can recover OFF.
Repair never materializes unknown cover consent as an explicit ON, including after
an unrelated protected-action edit. Legacy records containing an appUnlock gate
remain unknown unless an independent saved choice verifies consent: an older repair
could have created that gate, even if a later action edit changed the set. Other
unknown gates still fail closed. Known OFF also retires a synthetic global
app-unlock gate, so normal entry cannot be stranded without an unlock prompt;
the remaining scoped gates stay protected.

Security read/publication failures publish a public recovery message even when
Open Lava is OFF. Show the ordinary runtime error and Retry, without enabling a
cover. Retry reclassifies native security before requesting a fresh snapshot;
it admits no app mutation or private result, and retires earlier pending reads.

## Lifecycle ownership

- Cold launch, actual background, and protected-data loss are app privacy boundaries.
  With Open Lava ON, conceal before the system snapshot, revoke the foreground
  grant, and require one app unlock on return. Restore only the same suspended
  visit after successful authentication. Cancellation leaves one usable Retry.
- Transient inactivity is a pause in the current session. System sheets, StoreKit,
  biometric prompts and ordinary navigation cannot start a branded app cover or
  app unlock. Keep the accepted same-owner page inert through that pause so native
  rows do not disappear and clamp the retained scroll position. A changed native
  boundary token or explicit revocation retires this frame immediately, even before
  JS receives its background event. UIKit may protect the switcher preview while inactive; activation
  removes that shield without a new unlock when no background occurred.
- Inactivity always revokes reads, pending query epochs, input and accessibility.
  A display frame grants no read, cache or action authority. With Open Lava OFF,
  an already accepted same-owner frame can remain inert through background/resume
  while a fresh authorized projection is requested. A blocked reply cannot create
  a frame or revive discarded fields.
- Entering Security retains its separate credential authentication. Other selected
  action gates retain their scoped authentication. Neither owns an app-wide lock.
- A Plus detour belongs to its mounted requesting visit. Returning by Back, a
  completed swipe, or a cancelled swipe retains the parent's grant and native
  scroll view. Leaving the requesting visit or changing tabs still retires its turn.

`SecurityController` owns the app lock. `PresentationRevealGate` is armed at launch
and real privacy boundaries, never at `willResignActive`. Its renderer readiness
handoff finishes an existing boundary; mounting a renderer cannot start another.
Capture the Open Lava choice at that boundary. Enabling it during a pending OFF
handoff applies on the next background, even if the previous frame's ACK is late.
Native publishes two separate fields:

| Field | Meaning |
| --- | --- |
| `backgroundPrivacyCoverRequired` | Saved policy: cover actual background/launch when Open Lava is ON. Allows only accepted display continuity when OFF. |
| `appPrivacyCoverRequired` | A native launch/background reveal handoff is currently pending. This is the only permission to select the branded app cover. |

`LavaPresentation` and `LiveRenderBoundary` may hold that native-owned cover while
focused layout and authorized reads prepare. Hydration, missing fields, an error,
a policy edit or a navigation authorization turn cannot independently select it.
Without current authority, conceal private fields and pause interaction using the
existing scaffold/error surface. Missing metadata is never read authority.
After the renderer acknowledges its current reveal token, native republishes the
completed handoff so a later ordinary refresh cannot reuse an old cover flag.

## Retained presentation

Keep the native navigator and each mounted route's ScrollView identity. A cover
is a sibling, never a wrapper inserted around the native scroll root; otherwise
UIKit can lose the scroll view driving a collapsed large title. Route admission
may withhold private rows and disable actions but must not push the route again.

`AppStore`, `useAppQuery` and native authorization own read revocation. Reusable
private query data remains native-owned; accepted JS display frames are not cache
entries. Account/owner replacement, destructive clears, policy and exact data-scope
changes retire incompatible values. Routine grant/read revisions do not turn an
accepted Open Lava OFF frame into empty charts or loading placeholders. Native
confidential inputs may retain only explicitly revealed, same-visit user-entered
drafts; saved credentials are never copied into visible editor drafts.

During a covered resume, wait for the focused authorized viewport and its reads
or explicit errors before revealing. Offscreen or obsolete reads cannot hold the
cover indefinitely. Native sheets need the same sibling cover above their retained
body; the native security window owns authentication above all app presentation.
All callbacks, toolbar items, side effects and gestures retain their current-owner,
foreground, protected-data and authorization checks.

## Qualification

Use the supported full-app RN workspace and isolated simulator. Leave actual VPN
and protection enablement unchanged.

1. With Open Lava OFF, repeat from populated Guard, Activity, Nerd Stats, Security
   and a revealed user-entered VPN draft: Home/return, switcher, Control Center,
   lock/wake, delayed reads and relaunch. No app protection cover or app unlock.
   Repeat with a passcode and each other protected action selected individually.
   A selected scoped action must still require its own authorization.
2. On the free plan, open VPN chaining and toggle “I have a WireGuard configuration”.
   Return from Plus repeatedly using Back and interactive swipes. No cover, duplicate
   push, new app unlock, erased parent content or change in scroll/title geometry.
   Repeat with Open Lava ON and with Change settings protection ON.
3. With Open Lava ON, confirm launch and real background require one app unlock.
   Repeat successful/cancelled biometrics and passcode, explicit Retry, a retained
   Security visit, Activity period selection and a native sheet. No extra prompt
   after a transient inactive/active event; real background during a prompt still
   revokes the old ticket.
4. With Open Lava ON and delayed queries, complete the one resume authentication.
   Cover until the focused query and layout settle, then reveal current content
   together. Query failure reveals its error and permits retry.
5. Toggle Open Lava OFF/ON, remove the passcode, and simulate credential/protected-data
   unavailability. Preserve saved choices; deny unavailable reads; never promote a
   scoped gate into app-wide cover consent.

Package tests cover saved choice vs access fallback, ticket retirement and scoped
resume. RN tests cover explicit lifecycle cover ownership, transient pauses, late
replies, display retention, navigation turns and stable route viewport identity.
Simulator journeys cover native authentication, Plus return and title geometry.
Physical-device qualification is separate; this document does not claim a phone run.
