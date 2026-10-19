# Android binding surface

Implement the public `LavaUIAdapter` contract using Android-owned presentation.
The contracts and `useChoiceRequest` / `useToggleRequest` do not load iOS modules.
The tests in `tests/ui-behavior.test.tsx` demonstrate native-independent request
handling; they install no production fallback.

Preserve the existing Android canonical source and real wrappers. Integrate the
structural delta against its pinned revision, reconcile overlays, then regenerate
and check provenance. These files do not update that Android checkout.

| Binding | Existing iOS realization | Android responsibility |
| --- | --- | --- |
| Public text, surface, action and selection roles | `src/components.ios.tsx` | Supply Android renderers satisfying `LavaUIAdapter`; own platform dimensions. |
| Toggle requests | `ui/behavior/toggle.ts` + `src/toggle-row.ios.tsx` | Use shared request state; bind native events, sizing, labels and accessibility. |
| Choice requests | `ui/behavior/choice.ts` + `src/choice.ios.tsx` | Preserve stable values, acknowledgement and feedback ownership with Android controls. |
| Single choice, option stepper, page indicator | `ui/components/choice.tsx` | Supply `src/choice.android.tsx` under the extensionless import; keep purposes distinct. |
| Semantic toolbar actions | `ui/platform/toolbar.ios.ts` | Supply a sibling `toolbar.android.ts` mapping semantic actions to Android navigation items. |
| Icons | `ui/platform/ios/icons.ts` | Supply independent artwork; retain semantic differences and document unsupported roles. |
| Text/surface tokens, inputs, menus, sheets and pickers | Existing platform/scaffold owners | Use the responsibilities in the component portability guide; do not treat UIKit metrics as Android defaults. |
| App-owned artwork | `src/GuardianDrawing.tsx`, `src/OnboardingDrawing.tsx` | Reuse authored inputs and verify Android paint/motion. |

No `.android` runtime stub is provided: a placeholder must not override a working
Android implementation or imply that a native capability is supported.
