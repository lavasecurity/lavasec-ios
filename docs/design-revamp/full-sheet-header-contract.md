# Full-size sheet header contract

The content safe-area origin is the reference edge, not the physical screen or status bar. `LavaFullSheetMetrics` defines an 18-point top and horizontal inset and 12-point bottom gap. The React Native token generator exports those exact values as `fullSheet`.

`LavaFullSheetHeader` and the React Native `Sheet` header render this chrome. The first/last circular action stays 18 points from the applicable side and 18 points below the content safe-area edge. Controls use the existing 44-point circular scaffold. Actions align at the top while the centered title wraps and grows. No leaf may offset an individual glyph or recreate header geometry. Shared accessibility containers are `full-sheet.header` and `full-sheet.title`.

The native `lavaFullSheetHeader` modifier hides only the host stage's navigation bar and inserts the header into the top safe area. Existing NavigationStacks, stage transitions, dismissal gestures, action callbacks, loading guards and privacy masks remain owned by their current flows. Ordinary pushed descendants explicitly retain their native navigation bar. Existing pinned search/category headers remain part of `LavaSheetScaffold` content; they do not become another navigation header.

## Native adopters

| Host | Shared header and retained action ownership |
| --- | --- |
| Onboarding | Direct header; history Back and final Additional setup action |
| Additional setup | Shared header; existing Skip completion |
| Backup setup and restore | `LavaTaskSheet`; existing step Back, Close and disabled state |
| Import method, code, scan, review and replacement stages | Shared import adapter; original stage Back, optional Skip and Close |
| Share my filter | Shared trailing action group; Share card before Close, existing QR availability guard |
| Lava Guard picker | Shared Close; Upgrade and Privacy pushed pages keep native bars |
| Choose Blocklists / Choose Blocklist | Shared Cancel and conditional Bring your own list action; pushed editor keeps native bar |
| Feedback presented as a sheet | Settings and rage shake use the native Feedback sheet with its shared Cancel header and dirty-draft confirmation; terminal success retains Done |
| Native Plus upgrade sheet | Shared Close; actual purchase/restore destination unchanged |
| RN bridge licenses, custom blocklist, Phone QA | Shared Close through the bridge's flow owner |
| RN bridge DNS | Shared Close through the existing draft-discard confirmation, then explicit bridge callback; swipe dismissal blocked only for an unsaved modal draft |
| Phone QA rage-shake sheet | Shared Close stays outside the privacy mask |

The five live RN form sheets and two isolated review form sheets use the matching RN header; details and tests are in `ReactNative/review/scaffold.tsx` and `ReactNative/tests/full-sheet-header.test.tsx`.

The direct Feedback and Phone QA leaf masks cover form/footer content while leaving only their dismissal header outside. The RN `LavaAppNativeFlowView` has a stronger, pre-existing whole-host mask above the entire NavigationStack: it continues to mask headers as well, with its Unlock action available. Import stages are still unmounted entirely during privacy withholding. Moving the header does not bypass that host boundary.

## Separate presentation families

Fixed-height account, rename/create/delete and domain prompts remain compact native sheets. VPN configuration, automation instructions and the native filter review use mixed medium/large detents and remain the expandable compact-sheet family. Date-range compact sheets, system document/photo/share/store sheets, ordinary root/pushed pages and fullscreen authentication/preparation remain their respective existing owners. The native passcode setup is normally fullscreen; the legacy RN native-flow entry remains a separate authentication surface, not a general content sheet. These are explicit presentation distinctions, not per-screen glyph exceptions: all custom single-glyph controls still use the same circular button scaffold.

## Permission illustration envelope

`LavaSetupPermissionIllustration` measures both local-protection and notification variants in the same ZStack at the same available width and text settings. Only the requested variant is visible; both are decorative and hidden from VoiceOver. The shared card grows to the taller intrinsic variant, including translated/larger text. No fixed text/card height or clipping is introduced. Geometry anchors are `setup.permission-illustration.localProtection` and `.notifications` on the outer card container. The original onboarding Lava scene and animation are unchanged.
