# iOS reference audit — 2026-09-08

The existing native app is the design specification. Screen parity includes the
same composition, copy, states, controls, toolbar actions, sheets, navigation,
spacing, typography and interactions. Native tabs or switches alone do not meet
that bar. Do not invent simpler replacement interfaces for unported features.

The operator's Activity screenshot exposed an invented Today/7 days switch and
fixture controls inside a product page. Seven days is retention copy. This cut
corrects Activity and removes the global preview footer. Fixture data is disclosed
and chosen at the native review welcome screen. The build remains isolated from
the production tunnel, logs and commands.

## Activity correction

Reference: `LavaSecApp/DiagnosticsView.swift`, `DiagnosticsDateControls.swift`,
`LavaDesignSystem/LavaComponents.swift`, `LavaScaffold.swift`, `LavaTokens.swift`
and English values in `Localizable.xcstrings` ("Domain logs", "Top domains").

- Calendar/Today belongs in the native navigation toolbar; back uses the compact
  native chevron. The original SwiftUI calendar, endpoint selection, reset,
  draft/confirm behavior and range-label formatting are compiled into this host.
- The digest uses the green panel, native metric floors and label weight, a
  14-point branch bar with a 3-point split and visible blocked sliver, 22-point
  stat-icon columns, secondary labels and semibold tabular values.
- SF Symbols use the reference's typographic sizes (15pt semibold stat glyphs,
  12pt bold calendar) rather than shrinking a padded UIImage to that same square.
  The Today item's margins and filled Settings gear follow the rendered reference.
- The two domain-log navigation rows and retention/privacy footer match the
  reference composition. The Privacy & Data link navigates to its review route.
- Empty and example selection is on the native welcome screen. The one-day
  example matches the supplied aggregate counts; it does not access browsing data.
- Tests exercise no invented range/fixture switches, link navigation, canceled
  and confirmed dates, zero/single/tiny traffic shares, native sheet reopening,
  Today reset, and screenshots of the example in dark mode and empty in light.

## Scaffold migration round

The second round replaces the simplified pages with shared semantic counterparts of
`LavaInfoPanel`, `LavaCondensedList`, `lavaRow`, and `LavaSheetScaffold`. The signed-out
Free fixture uses Balanced, empty logs, zero Guard progress and the reference plan
prices. It is disclosed before entering React. The production SwiftUI target and
its services remain unchanged.

- Account: both native provider rows, account copy and disabled encrypted backup actions.
- Customization: grouped notifications, native slider/segmented controls and conditional sections.
- DNS: device/fallback switches, curated providers and four transport choices.
- Privacy/Security: native log/export/delete sections, authentication methods and six gated actions.
- Filters: saved view → edit → domain/exception sheet → review; grouped library/share chooser;
  catalog selection and native serializer-backed QR/code preview.
- Feedback: Topic → Details → Review, draft preservation and discard confirmation.
- Legal: actual native notice registry. Stats/Network: native sections and empty fixture states.
- Shell: native sheet presentations and toolbar items; review exit moved outside product chrome.

Device validation and the new comparison PDF determine the remaining visual gaps;
JS tests alone do not establish parity. In particular, this round does not complete
signed-in backup/authentication, active/error tunnel states, real purchases, populated
native logs, camera import, native filter preparation/apply, Dynamic Type overrides,
localization, animations or the full accessibility/device matrix. Unavailable commands
still stop at the review boundary. Do not call the full 2F parity gate complete.

## DNS follow-up and device review

The DNS filtering-limits section was removed from both the production SwiftUI
DNS provider page and the React Native review page at the operator's request.
This is a copy/layout change; resolver behavior is unchanged. Nerd stats now
reserves equal columns for tier labels and values. Both SwiftUI and React Native
align every DNS value block to the same leading edge, including short On/Off and
Device DNS blocks. Rows use system separators and tabular digits,
and include the selected DoH hostname. Device DNS places the selected alternative
under T2, including its configured value when fallback is disabled.
Each diagnostic row is one accessibility element, announcing its label before its
value as the native reference does.

The next review should be on a physical iPhone: light/dark mode, safe areas and
sheet detents, back/tab gestures, keyboard/IME editing, background/relaunch,
system text sizes and VoiceOver. This is a UI review, not a VPN acceptance pass.
The exported CI app remains a simulator artifact; an iPhone build needs separate
development signing for the isolated review bundle identifier.

Known remaining UI/interaction gaps include sheet/header offsets, the Share
Copy icon and image-sharing payload, full-license and diagnostic-disclosure
destinations, and conditional signed-in/paid/tunnel/log states. DNS non-DoH
metadata and transport availability still need the native preset adapter;
session fixtures are not resolver configuration authority. Text-size overrides,
localization and the full device/accessibility matrix remain open. Auth/backup,
purchases, tunnel commands, filter apply/import, passcode confirmation and feedback
submission still require native service adapters before functional device testing.

## Sudoku omission follow-up

The earlier comparison omitted the hidden Sudoku game entirely. The review now
opens it with five mascot taps within the native 1.2-second idle window. A
1.2-second hold still opens the Lava Guard picker, and the protection-status
element exposes both native accessibility actions.

The React screen follows `SudokuEasterEggView.swift`: a full-screen paper board,
locked givens, cell tracking, a scrub-to-preview keypad, contextual eraser, notes,
assistance counts and correctness glyphs, and reset/new-puzzle confirmations.
It retains the native minimum board size, safe-area handling, completion colors,
and solved-board lock. The comparison includes light/dark boards, notes,
assistance, and both confirmation dialogs.

The first puzzle is the native seed-648 test fixture. New review rounds permute
that proven unique puzzle; the production generator is not replaced. Progress
resumes within the React review session and is cleared when Lava Guard progress
is disabled or cleared. Durable storage, production progress integration and
haptic parity remain service/device work, consistent with this isolated host's
review boundary. Closing the review runtime discards its game state.
