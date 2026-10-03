# Native full-width action consolidation

The primary, tinted and secondary native action styles repeated the same label
font, wrapping, padding, minimum height, rounded shape and press animation. A
change to one did not necessarily reach its siblings; the secondary style also
kept enabled foreground text when disabled.

`LavaFullWidthActionButtonBody` in `LavaScaffold.swift` now owns this anatomy and
reads the installed SwiftUI enabled/Reduce Motion environment. Its companion
`LavaFullWidthActionState` resolves role and interaction state. Existing
`LavaStandaloneActionButtonStyle`, `LavaPanelActionButtonStyle` and
`LavaSecondaryActionButtonStyle` remain thin compatible wrappers. The panel
wrapper retains its optional corner-radius argument.

The common body uses the semantic row-title font, existing row inset tokens,
control radius and 44-point minimum action height. Wrapped labels may grow; no
line clamp, fixed height or shrink-to-fit is introduced. All disabled roles use
`secondaryText` on `disabledSurface`, consistent with RN's `LavaActionButton`.
Disabled controls do not scale or show a pressed overlay.

Enabled primary, panel and neutral fills remain deliberate role differences.
This pass preserves their existing native pressed materials and subtle scale.
The navigation-row style remains a separate row interaction. Button callbacks,
labels, accessibility semantics and caller placement are unchanged.

Existing adopters inherit the common body without leaf edits: onboarding,
backup setup/restore, feedback, filter import/review/library/domain sheets,
blocklist selection, DNS, VPN chaining, activity/date selection and QA actions.
The owner stays in `LavaScaffold.swift`, already included by the isolated native
review host as well as the full application.
