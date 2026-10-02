# Header and navigation surfaces

Owner feedback 12/13, 2026-09-13. Ordinary pages retain the native stack, native
navigation bar, tab controller, Back semantics and interactive dismissal.

## One header surface

All custom toolbar controls use `toolbarButton` in `review/scaffold.tsx`. It
supplies `hidesSharedBackground: true` and the canonical `LavaIconButton`, so the
app's circle is the only painted control. This includes Activity's calendar and
the isolated review host's Close control, with `review.close` preserved.

The former Activity `headerRight` took a different native-stack path. In the
installed `@react-navigation/native-stack` 7.18.10 `useHeaderConfigProps.tsx`,
custom header items forward `hidesSharedBackground`; the legacy `headerRight`
wrapper does not. RNScreens 4.27 forwards this flag to the `UIBarButtonItem`.
That explains the extra white glass surrounding the former painted date pill.

Today / Week / Month remain quick presets. The calendar is always named
“Change activity dates” through the existing localized key. An accepted custom
range appears once in the body (`activity.custom-range`), with no selected
preset. Cancel preserves the accepted range and preset. Returning to a preset
removes the custom summary. Native picker behavior and calendar arithmetic stay
unchanged.

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
