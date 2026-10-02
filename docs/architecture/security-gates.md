# App authentication gates

`SecurityProtectedSurfaceStorage` in Kit owns the shared effective gate set. The app owns
its passcode keychain, migration and user choices; extensions read the same gate without
writing preferences. A passcode seeds pause and filter-edit protection once. The version
marker preserves subsequent opt-outs; disabling a protected surface requires fresh app
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
