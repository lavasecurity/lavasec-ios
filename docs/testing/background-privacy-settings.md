# Background privacy follows Security choices

An inactive app with confirmed security OFF keeps its last accepted screen visible
in the app switcher and through phone sleep/wake. Creating a passcode or enabling biometrics alone does not opt
into background concealment: every protected action remains an explicit choice.
Selecting any protected action enables concealment of the entire inactive window,
including when App Unlock itself is OFF. This prevents a snapshot from exposing
an already authorized Activity or Settings page after its page grant is revoked.

Unreadable credentials or unavailable gate publication keep the window covered.
Protected-data loss revokes read and action access, without changing a confirmed
off display choice. The pre-lock callback conceals selected or unknown security
before UIKit changes its bit. These temporary states do not change saved choices.

The display choice grants no background read access. Native queries still require
an active app, protected data, and current authorization. React Native revokes its
authoritative snapshot, reusable query caches and read epoch on inactivity. The
separate display frame can retain only an already accepted snapshot carrying
native-confirmed `backgroundPrivacyCoverRequired: false`; no inactive or blocked
reply can replace it. Returning to the app retains that same display-only frame
until a fresh authorized foreground snapshot arrives. Waiting for the refresh is
not a reason to show a security cover. Reads, actions and accessibility remain
revoked during this wait. Every query-backed page can retain its already painted
values in this same all-off frame; they are not reusable cache entries
or authority to read again. After foreground authorization returns, the same
page retains these values until its fresh query completes. This avoids emptying
populated charts and numbers into loading placeholders on an ordinary resume.
A missing flag, a concealment marker, or disconnect
retires the frame immediately, and a later blocked all-off marker cannot revive
it. Cover visibility follows the latest native security choice independently:
an off marker can remove a cover but cannot restore discarded private fields.
The existing native navigation stack remains mounted.

All-off cold launches mount React with a native-authorized projection rather
than an inactive marker. That initial handoff may paint before JS AppState is
initialized; it grants display only until a fresh active snapshot restores input.
There is no startup spinner or branded loading screen. Protected or unavailable
security uses the branded privacy cover, including during bootstrap. Disabling
the last protected choice also retires an outstanding hydration cover.

Display retention uses the exact query and its data ownership/settings scope,
including opaque account ownership, log choices and native destructive-source
identity. Changing the Activity period, query, account, clearing logs or replacing
filter-library content clears old values rather than relabeling them. Routine
read/grant revisions, account-status messages and unrelated native mutations do
not change the identity of the already painted all-off frame. An ordinary mounted-route blur pauses reads
without discarding a same-scope all-off display; unmount still disposes it.

## Shared procedure

`AppStore`, `LavaPresentation`/`LiveRenderBoundary`, `useAppQuery` and the native
`SecurityController` policy own this procedure for every page. Screens must not
invent a separate background cache or make inactivity alone mean "locked".

1. Native policy classifies the cover choice before any private snapshot fields
   are composed. Only an explicit, healthy all-off result allows continuity.
2. Inactivity revokes readers and pending epochs. Keep the last accepted display
   under all-off; otherwise conceal and dispose it. Inactive events can retire a
   frame, but cannot replace or recreate it with fresh fields.
3. Resume requests an authorized native snapshot while the prior all-off frame
   stays inert. Restore reads and interaction only after that snapshot arrives.
   A delayed blocked all-off marker must not overwrite an already restored
   authoritative snapshot from the same revision.
4. Query hooks refresh after authority returns and keep their same-scope painted
   values until replacement completes. Exact query/data-scope changes still
   clear them immediately. No retained display is an input to a cache lookup.
   If a real concealment boundary disposed the previous page, keep the cover
   while the newly authorized visible queries prepare their first result or
   explicit error. Reveal the completed page together. Cold first loads and a
   deliberately changed period/query retain their normal pending presentation.
   Automatic owner preparation may run under the authorized cover; user actions,
   native toolbar callbacks and back gestures wait for presentation readiness.
   Each UIKit-presented route has its own sibling cover; a root-only overlay
   cannot conceal a native sheet. Native footer pixels follow the same cover
   decision independently, while direct ScrollView geometry stays intact.
   Disposing a body retires its native header/footer renderers and callbacks;
   restoring authority cannot reactivate a former form or Share payload.
5. Screens stop side effects on inactivity: playback, speech, camera capture,
   contact tracking and pending presentation attempts. They retain ordinary
   page/draft/selection content under all-off. A selected/unknown security choice
   remains an immediate concealment boundary. Protected-data loss always revokes
   reads and cache tickets; only the confirmed all-off display can survive it.

This applies to Guard and its summaries, Activity and domain pages, diagnostics,
Settings, account/backup, filter editing/sharing, DNS/VPN editors, Explore and
Sudoku through their shared owners. Saved credentials are never loaded into
visible editor drafts; retaining a user-entered draft does not change that rule.

| Interface family | Shared owner and audit result |
| --- | --- |
| Guard, summaries, Settings, account/backup and filter metadata | `AppStore` + `LavaPresentation` + `LiveRenderBoundary` keep the native navigator and existing all-off body mounted. Missing read authority alone must not choose the cover. |
| Activity, Top Domains/History, Nerd Stats, Network Activity, catalog and sharing | `useAppQuery` + shared display scope keep only already painted same-scope values; polling pauses while inactive or blurred. Query/privacy scope changes and late replies remain fenced. |
| Covered resume of a query page | `PresentationHydration` holds the cover while focused scoped reads settle and the new body completes layout. Offscreen reads cannot indefinitely hold the cover. |
| Native sheets, headers and footers | Route-local cover and scaffold pixel/input/accessibility fences cover UIKit presentation layers; mounted-owner callbacks and renderer cleanup retire erased private bodies. |
| Share reveal and copied state | The shared native all-off policy preserves the current code/QR state; a new code, lost frame or concealment boundary retires it. |
| Native VPN editor | `SecurityPrivacyPolicy` preserves an explicitly revealed user-entered all-off draft through sleep. Imported/unrevealed drafts and selected/unknown security remain covered. Native input waits for protected-data recovery. |
| Explore | Inactivity pauses clocks and speech without erasing the displayed lesson step. Route/routing changes and unmount retain their reset/cancellation ownership. |
| Activity date picker, Sudoku, mascot and held chart/paging gestures | Cancel pending presentation or contact tracking and release scrolling. Keep accepted range/game/service content through the shared all-off frame. |
| Embedded native pages and system-owned import/export/camera flows | Native authorization and interaction gates retain their current owner. Pause capture and retire native presentations where required; do not replace the underlying all-off page with empty data. |

## Qualification

Use the supported full-app RN workspace. Leave VPN/protection controls unchanged;
these cases concern the Security settings, rather than filtering enablement.

1. With Passcode and all six protected actions OFF, open Security, scroll the page,
   then open the app switcher and return. The preview must show the page without
   blur or the Lava Security cover. Return must keep the page visible throughout
   the foreground refresh, without a transient cover. Repeat using Home and
   Control Center, including rapid repeated transitions and a delayed refresh.
   Repeat from a populated Activity chart and Nerd Stats: the current numbers
   must remain visible in the preview, during resume and while their fresh query
   is pending. There must be no intermediate dashes or loading placeholders.
2. Configure a passcode while leaving all protected actions OFF. Repeat case 1.
3. Enable each protected action in turn, including an action with App Unlock OFF.
   The inactive preview must conceal the page. Return, complete any required
   authentication, and check that the saved choice survives.
4. Disable the last selected action, then immediately open the app switcher.
   Concealment must stop. Repeat after removing the passcode and after relaunch.
5. With protection selected, open an authorized Activity page or native sheet.
   Background during an authentication prompt; real backgrounding must revoke its
   grant and conceal the snapshot. Returning must require the appropriate current
   authorization. Repeat a cancelled and successful biometric prompt.
6. With all security options off, lock the phone with a populated page or an
   explicitly revealed user-entered VPN draft. On wake, the accepted display must
   remain visible without a cover or empty-number reload; input waits for protected
   data and fresh native authority. Repeat with a protected action selected: the
   pre-lock frame must conceal and the required authorization must return before
   private content. No case may clear or auto-enable a saved security choice.

Executable package tests cover the opt-in/availability matrix and platform wiring.
RN tests cover all-off display retention, concealment/default policy, late replies,
read revocation and navigation identity. Physical-device qualification is separate
from those tests; no post-change phone capture is claimed by this document.
