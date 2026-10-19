# Header and navigation surfaces

Owner feedback 12/13, 2026-09-13. Ordinary pages retain the native stack, native
navigation bar, tab controller, Back semantics and interactive dismissal.

## One header surface

Toolbar controls use `toolbarButton` in `review/scaffold.tsx`, which supplies
native navigation items with canonical SF Symbols, tints and grouping. UIKit
owns their size and spacing. Ordinary plain actions share the native background;
the optional `none` background hides its fill without replacing the native items.
The isolated review host's Close control retains `review.close`.

Activity places Export followed by Clear all logs in one shared native
toolbar panel at the top right. Export uses the normal navigation foreground; trash uses
the shared destructive red. Export opens the shared native action dialog with
Activity chart, Export diagnostics, Export all logs and Cancel. Activity chart
shares the selected chart and accepted date range through the fixed 4:5 card;
its install QR, three-line summary and balanced margins stay independent of data.
The two ZIP actions use the same handlers and app-settings authentication as the
two rows in Privacy & Data's export panel. Diagnostics omit domain history; all
logs include retained domain history. Neither ZIP is narrowed by Activity's range.
Clear all logs retains Privacy & Data's authentication and destructive confirmation.

Today / 7 days / Month / Custom live in the body. An accepted custom range
appears once (`activity.custom-range`); cancel preserves the accepted range and
preset. Returning to a preset removes the custom summary. Native picker behavior
and calendar arithmetic stay unchanged.

## One ordinary-page transition

`review/navigation-scaffold.ts` owns ordinary push presentation:

- `simple_push` for programmatic push/pop and matching interactive gestures;
- no synthetic transition shadow (`fullScreenGestureShadowEnabled: false`);
- `none` while Reduce Motion is enabled or its initial value is unavailable.

The installed RNScreens implementation otherwise returns UIKit's default
animator for ordinary navigation. Captured b7b3a3f6 frames show the additional
rounded page edge and grey surround during Guard → Activity and Top domains →
Activity. `RNSScreenStackAnimator.mm` provides `simple_push` with a separate
shadow flag, RTL-aware translation and completion/cancellation cleanup. The
gesture handler retains its existing finish/cancel decision.

The policy applies only to ordinary destination routes. Full-height sheets,
Passcode and Sudoku retain their existing modal owners. No view mask, border,
shadow compensation, navigation-state rewrite, or dependency patch is involved.
The Reduce Motion observer is removed on unmount; a late initial read cannot
overwrite a newer system event.

## Keyboard and foreground stability

The shared native `LavaScrollView` uses UIKit's adjusted content insets when
clamping commands from React Native. Its legal resting offset includes the
navigation bar's safe area. It also retains that offset when RN's cross-fade
keyboard-dismiss branch would otherwise reset it to zero. Both React hosts
install this owner before mounting their root; the inherited RN 0.87.1 hooks
are guarded by the complete upstream source digest during preparation.

The first field and large title must stay in place when that field is already
visible above the keyboard. Native bounds still constrain both scroll ends,
and UIKit/RN continue to reveal lower fields. Leaves must not add focus offsets
or foreground scroll resets. Ordinary read-only and unfocused pages do not
consume keyboard notifications.

Domain/URL entry uses the native URL keyboard, URL content type, and disabled
autocorrection, capitalization, spelling and smart insertion. An empty
clipboard must not produce English prose predictions or an app-created paste
prompt. The system owns its clipboard affordances and domain suffix key.

`testDomainEntryKeepsPageGeometryAcrossKeyboardAndForeground` measures the
header, input and Check button through three focus/dismiss/foreground cycles
and verifies native `.com` insertion. Before cutting an RC that changes this
scaffold, run it in light, dark and Prefer Cross-Fade Transitions modes alongside the existing domain
check/review and native navigation collapse/restore journeys. The mandatory cross-fade journey phase also runs this geometry test. Capture actual
frames; visibility alone does not qualify a stable layout. Preserve the same
draft and user scroll position through interruption and return.
