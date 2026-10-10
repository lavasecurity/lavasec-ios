# App authentication gates

`SecurityProtectedSurfaceStorage` in Kit owns the shared effective gate set. The app owns
its passcode keychain, migration and user choices; extensions read the same gate without
writing preferences. Credential setup selects no protected surfaces. Existing explicit choices survive migration; disabling a protected surface requires fresh app
authentication. Removing a passcode successfully resets the defaults for a future setup.

The app publishes availability, effective gates, migration and notice state atomically in
`security-gates.json`. This Class-None control-plane file contains no credential material.
Production readers read the file directly; they do not authorize from a cached defaults
projection. Missing, corrupt or unreadable state gates actions. Legacy defaults seed the file
once, only through an app writer; the file then owns subsequent choices and migration state.
Initial migration waits for protected data and a conclusive credential read. A prewarm before
first unlock leaves the projection absent and readers conservative, preserving legacy choices
for migration after unlock. Other writes cannot seed a missing projection.
Foreground credential reconciliation repairs malformed records by restoring every gate and
requesting review; confirmed credential absence clears them. Readers and ordinary settings
writes never repair the file. Unsupported versions, oversized records and I/O errors remain
untouched so an older app cannot overwrite a newer schema or mistake unreadable data for absence.

Before saving a passcode, the app must successfully publish conservative gates. A failed
publication prevents the keychain write. A failed keychain write is reconciled by an app-only
read: confirmed absence restores no-passcode operation, while an unreadable credential keeps
gates. Changing an existing credential preserves informed opt-outs. Failed deletion cannot
report successful removal. The app retries credential reads on foreground unlock.
Publication failure does not make a readable credential unavailable: gate reads stay
conservative, setting changes still require a successful write, and the app reports the
storage failure separately. If the passcode save succeeded, its result remains successful
while the app explains that shared settings need another publication attempt.

A separate pending-notice marker survives launches and is cleared only by the foreground
acknowledgement button. Shared readers do not consume it. Only the app's main actor writes
the record; atomic replacement gives readers a complete old or new state. An action already
authorized before a gate change retains that authorization. A compromised same-team process can still
rewrite shared state. These UI gates do not authenticate raw App Group files (INV-LOCK-1).

`SecurityGateProjectionTests`, compatibility-default tests, headless switch/drain tests and
`SecuritySettingsSourceTests` cover policy, the two extension entry paths and app wiring.


## Lock lifecycle and RN contract

The app's six user-selected gates remain authoritative. App Unlock protects entry to
Lava after a real background transition. Protection control and pause authenticate each
requested action. Filter editing, Activity viewing and App Settings authenticate entry
into the corresponding navigation visit. Security and credential-management screens
also require credential authentication. Setting up a passcode alone selects none of
these six choices; disabling Face ID keeps the passcode and selected protections.

The UI lock has one native session owner, `SecurityLockSession`, used by
`SecurityController`. React renders the authorized projection and preserves route,
scroll and form identities; it does not decide whether credentials succeeded.

| Event | Session behavior | Presentation behavior |
| --- | --- | --- |
| Cold launch with App Unlock on | One automatic authentication attempt | Native lock/passcode UI, then React's measured initial reveal |
| Background or protected-data loss | Revoke all current tickets; retain only the identity of the authorized visit | Cover before the OS snapshot; no private reads |
| Resume that same protected visit | One unlock restores its prior page/credential grants | Keep the route mounted; refresh scoped data beneath the cover; reveal after readiness |
| Resume Guard with only action protection enabled | No automatic authentication | The next selected action still authenticates freshly |
| Face ID inactive/active interruption | Same session and in-flight operation | Do not add a separate blank snapshot shield |
| Authentication cancellation | No grant; no new automatic attempt in that foreground session | Keep the explicit Unlock control/passcode cancellation path usable |
| Retry | A new explicit attempt in the current session | Same retained destination |
| Navigation away | End page/credential grants and discard suspended visit | Preserve App Unlock until a real background boundary |
| A completion from before background/navigation retirement | Reject the retired ticket | Cannot reveal a later session or execute stale navigation |
| Protection setting change | Publish the saved choice; revoke reader tickets; retain the already-authorized Security visit | Keep switch and scaffold identity; pending input does not dim the switch |
| Temporary biometric lockout/unavailability | Passcode fallback, including fresh authentication to disable Face ID; preserve its saved preference | One credential transaction, not a preference toggle |
| Unreadable credentials or failed gate publication | Fail closed; preserve explicit user choices | Show the lock/status rather than silently clearing protection |

A suspended visit is not cached authority. It contains only the previously granted
surface identifiers and whether the credential screen was authorized, never query data,
keys or a passcode. Successful current-session authentication may restore that exact
visit. It does not pre-authorize other areas, and protection control/pause are excluded
from restored grants. Navigation retirement and credential reset discard the intent.

Authentication tickets have a finite owner for both App Unlock and page access. App
Unlock is no longer represented by an unconditionally valid nil revision. Background
retirement invalidates the active LAContext and passcode request; late results fail the
same ticket check. Concurrent callers join the complete biometric/passcode transaction,
not just its initial Face ID stage. Scene activation claims at most one automatic unlock
per foreground session. VPN refresh, tunnel sampling and filter reconciliation run
independently and cannot delay the unlock request.

Native covers have explicit responsibilities. The snapshot shield covers real external
inactivity/background and removes every view it installed on scene activation, including
windows that moved outside the current scene enumeration. The scene security window
owns interactive lock/passcode UI above RN sheets; a passive mask cannot cover a pending
passcode request. RootView does not duplicate those controls beneath the security window.
React's existing presentation-hydration gate owns the final measured
reveal of restored content. These covers cannot grant data access.

### Acceptance and release qualification

Executable session tests cover cold state, exact-visit restoration, credential/settings
resume, repeated lifecycle notifications, cancellation/no auto-repeat, stale foreground
and page completions, leaving during unlock, action-only protection, setting changes,
and enabling App Unlock for the next background. Existing asynchronous coalescer tests
cover concurrent and overtaken requests. Native integration pins verify that the actual
controller uses these tickets, joins the whole transaction and installs/removes covers
through scene lifecycle. RN lifecycle/navigation/toggle tests continue to exercise stale
callbacks, committed hydration, same-route identity and first-tap navigation.

Before an internal RC, require all PR checks, Swift package tests, native app compilation,
and the full RN suite. Device/simulator acceptance must separately exercise real
background/resume, one successful authentication, cancellation/retry, retained sheets,
Security and Activity entry, and repeated switches; mocked credential results do not
establish physical Face ID timing. Public promotion remains held until the security
experience is accepted.
