# Component contracts and platform bindings

The UI foundation separates semantic contracts and control behavior from platform
rendering. Existing entry points remain compatibility exports. A source move or
name change must preserve the current iOS appearance, native identity, state and
event ordering. The governing scope is [infra plan 330](https://github.com/lavasecurity/lavasec-infra/pull/330).

## Ownership

The [migration manifest](component-migration.json) lists retained entry points
and extracted owners. The [Android binding surface](../src/ui/platform/android/README.md)
identifies the platform siblings and existing integration responsibilities.

| Module | Responsibility |
| --- | --- |
| `src/ui/contracts/` | Values, actions, roles, callbacks and accessibility meaning. No generated iOS token data or native bridge imports. |
| `src/ui/behavior/` | Existing controlled selection/toggle request handling. The feature/native owner remains authoritative for durable state. |
| `src/ui/platform/ios/` | SF Symbol mappings and iOS presentation bindings. Exact glyph variants and current metrics remain platform-owned. |
| `src/ui/components/` | Purpose-specific entry points delegating to the selected platform implementation. |
| `src/components.ios.tsx`, `choice.ios.tsx`, `toggle-row.ios.tsx` | Existing iOS rendering, measurement and native event adapters. |
| `src/GuardianDrawing.tsx`, `OnboardingDrawing.tsx` | Existing shared RN/SVG artwork; geometry and timelines remain unchanged. |
| `review/` | Existing shared page/scaffold compositions and platform flow integration. This refactor does not relocate whole screens. |
| `specs/` | Existing native wire contracts and registration names. These are transport details, not the public UI API. |

Import public contracts from `src/ui/contracts`, or the retained `src/contracts`
facade. Import platform components through extensionless paths so Metro selects
the correct implementation. Reusing a file labelled `.ios` does not establish
Android support.

## Control behavior

Choices carry stable option values, independent of label or display order. A
request can remain displayed while its owner's promise settles; settlement
reconciles to the authoritative value. Reselection is opt-in. Disabled, missing
and unchanged options retain the existing acknowledgement behavior. Page
indicators retain native feedback ownership.

Toggles claim a gesture before calling their owner, preventing synchronous
reentry. Pending input is blocked without inventing a saved value. Optimistic
display is explicit; rejection returns to the owner's current value. The native
adapter owns intrinsic measurement, accessibility, labels and event transport.

The extracted hooks retain their existing lifecycle behavior. Native visit,
privacy, authentication, input-buffer and confidential-field owners remain where
they are. A fulfilled promise is not permission to persist or admit a screen.

## Android binding checklist

| Family | Android implementation responsibility |
| --- | --- |
| Text, surfaces, rows, actions | Map semantic roles to Android metrics, colors and controls; preserve required states and accessibility. |
| Icons and toolbar actions | Supply independently licensed artwork for every semantic action. Preserve import/share, allow/block and back/previous distinctions. |
| Selection, stepping, pagination | Bind each purpose to its Android control; consume shared request behavior where applicable. |
| Toggles | Bind native events, dimensions and accessibility to the shared request behavior. |
| Ordinary/emoji inputs | Preserve composition, buffer ownership, explicit reset, focus, replacement and measured size. |
| Menus, navigation, sheets and pickers | Preserve action/result and lifecycle contracts using Android presentation. |
| Guardian contact and feedback | Preserve contact/cancellation meanings and map feedback to available hardware. |
| Shared artwork | Reuse the existing authored paths, palettes and frame equations; verify Android rendering. |

This package does not install Android production stubs or claim that an adapter
exists. Android's existing canonical-source tree and real overlays remain the
integration owners. Apply the structural rename/export delta to its pinned
source; do not bulk-import unrelated iOS features. Regenerate and verify its
canonical provenance after reconciling overlays, and keep the imported revision
in its README consistent with the manifest.

## Equivalence review

Existing component tests cover controlled/pending/rejected state, reentry,
intrinsic sizing and stable native controls. Platform-contract tests exercise
shared behavior through a test-only adapter and protect exact iOS icon variants.
Neither establishes rendered equivalence on a device.

For each integrated structural slice, compare matched baseline/candidate captures
and journeys in the same environment. Preserve copy, geometry, fonts, materials,
symbols, native controls, navigation, motion, accessibility and input behavior.
Keep runtime evidence in infra or the PR receipt. A visual difference is a
regression for this work; updating expectations does not authorize it.
