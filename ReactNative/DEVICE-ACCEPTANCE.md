# RN full app device acceptance

Use the delivered RN QA build number and source SHA recorded in the release receipt. The simulator fixture app is not this candidate. Record device, iOS version, appearance, text size, language, and result for each journey; include the first failing step rather than only a screenshot. The native behavioral audit is in [FULL-APP-CONTRACT-AUDIT.md](FULL-APP-CONTRACT-AUDIT.md).

## Account and backup

Use a test account for the two permanent deletion checks. The existing QA configuration needs its own Google OAuth client before Google sign-in can be accepted; Apple and Google provider availability must be recorded separately.

1. Signed out: backup setup/restore/manual/delete controls are disabled and Automatic Backup reads off. Sign in; provider progress ends with the real native account state. Tap both sign-in providers rapidly and cancel the provider sheet: only one provider flow opens, its pending state ends after cancellation, and retry works without a stale second sheet. Open the connected account row and cancel sign-out/account deletion; neither action should run.
2. Set up encrypted backup with the native recovery/passkey flow. Cancel before completion once, then complete it; run Back Up Now and check the settled status. Restore through the native review flow and verify filters/settings after relaunch.
3. Turn **Automatic Backup** off: only scheduled uploading stops. The configured backup and server copy remain. Turn it back on.
4. Cancel **Delete online backup copy**: no change. Confirm it: the server copy is deleted, while the device remains configured for backup and can upload a new copy.
5. With a fresh copy uploaded, attempt **Turn off & delete backup** while offline: deletion fails visibly and backup remains configured. Reconnect and explicitly confirm: the server copy is deleted, local unlock/envelope material is removed, and automatic backup is off. Set up again only if wanted.

## Protection and platform behavior

6. Accept the VPN permission; start, stop, and resume Lava. Status must follow the actual tunnel. Long-press the pill for native pause durations. Reselect Guard repeatedly: no movement or additional navigation. Verify allowed/blocked DNS behavior, fallback recovery, and app relaunch.
7. Exercise widget, Shortcuts, Focus switching, Live Activity pause/resume, lock/unlock, background/foreground and reboot. Confirm changes reach the same RN state and that protected actions still authenticate.

## Filters and drafts

8. Open active and inactive filters. In Library, authenticate Edit, rename, create/duplicate within quota, stage multiple deletes, Undo, cancel the confirmation, and discard on exit. The active/frozen filters must retain their native restrictions.
9. Edit an inactive filter and Save: it persists without a weakening review or preparation screen. For the active filter, strengthening changes prepare directly; removing a block or adding an exception opens Review. Cancel, then try again. While editing a changed draft, background and return, then Discard: it must leave editing without another authentication prompt and keep the saved filter unchanged. Check preparation failure/retry/keep-current/back-to-edit if a network failure can be reproduced.
10. Add/remove/Undo domains and blocklists; invalid and duplicate input stays in the editor with the native reason. Free limits offer Upgrade; Plus at its limit requires removing entries. Toggle blocklist checkboxes while scrolled down: rows and scroll position must stay in place while totals update. Cancel custom-list entry and the blocklist picker without applying unconfirmed checkbox changes. Relaunch to verify only accepted saves persist.

## Settings, diagnostics and secondary flows

11. In Custom DNS, edit then cancel a primary-provider/back discard prompt; the draft remains. Clear changes only the draft until Save. Test validation, primary and encrypted fallback settings, supported transports, and persistence. Rapidly change Device DNS mode then tap a provider or transport: controls wait for the first change and do not apply to the wrong primary/fallback target. Exercise native VPN chaining if used.
12. Create a passcode, test biometrics and each protected surface, cancel authentication, then retry after backgrounding. Cancellation must not change toggles or open a stale screen. Reselect Settings from a long page: return to the root at its compact-title top.
13. Activity dates, Top Domains, Domain History, Network and Nerd Stats must reflect native data. With Domain logs off, Domain History offers Turn On Local History; use it, then verify Privacy shows logging on after relaunch. Top Domains retains its separate off-state guidance. Long-press domains for Copy/Block/Allow and cancel a staged Review. Load additional log pages. Cancel each clear action before explicitly trying a desired clear; exports include domains only after that export's opt-in and report Files failures.
14. Change appearance, text size, notifications, Guard look and icon preference; relaunch. Verify unlock gating, native haptics, large text, localized VoiceOver labels/actions (including Sudoku cells and notes) and Reduce Motion. Open Sudoku with five mascot taps; exercise values/notes/drag/assist/clear/new puzzle and its progress-log persistence preference.
15. Test share code/QR (including VoiceOver announcements explaining empty or oversized filters), camera import, legal/notices, and native feedback attachments. Submit feedback only when deliberately testing delivery. Exercise purchase/restore/manage in the appropriate StoreKit test environment and verify cancelled purchases do not grant Plus.

## Review outcome

Record Passed / Failed / Not exercised for every journey. External-account, VPN, StoreKit and reboot outcomes remain unverified until exercised on a device. Device acceptance does not authorize a release or begin Android UI mapping.
The retired SwiftUI app exists only at historical tag `native-ui-reference-2026-09-08`;
current builds use the RN workspace. Historical releases also require their
historical runner workflow revision.
