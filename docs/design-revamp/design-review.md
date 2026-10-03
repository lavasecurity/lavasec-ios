# Interface engineering review

Read this with the [implementation contracts](README.md) before changing a screen. Current source and executable tests determine shipped behavior.

## Shared ownership

- Describe the user's task, then use the smallest composition that supports it. Keep copy concise and understandable without network expertise.
- Equivalent functions share atomic implementation, including when nested inside larger panels. Shared tokens alone do not establish reuse.
- Screen modules arrange shared primitives. Foundation tokens, native palette/type owners and RN scaffolds own paint, typography, control geometry, disabled states and motion.
- Native navigation owns headers, Back, Close, tabs and system tool chrome. Each route has one header and one ordinary page scroll. Compare intermediate transitions and cancellation as well as settled screens.
- Settings introductions, rows, helper copy, selectors and disclosure accessories use their existing shared families. Keep controls and explanations distinct, and preserve explicit opt-in and confirmation semantics.
- Primary, panel and secondary actions share their label, wrapping, minimum target and interaction owners. Role colors remain semantic differences.
- Repeated benefits, summary tiles and chart legends share their corresponding outer treatment and text roles. Display real proportions and preserve empty/unavailable meanings.
- Filter identity and unchanged rows stay stable across reading, editing and pending operations. A confirmation follows the actual operation's success.
- Security policy selects privacy covers. All-off pages retain their ordinary presentation through read refresh; loading is not a security choice. See the [lifecycle contract](../testing/background-privacy-settings.md).

Use these concrete owners when changing a shared atom:

| Atom | Canonical owner |
| --- | --- |
| RN row body and accessory | `Row`, `RowContent`, `RowAccessory` in [primitives.tsx](../../ReactNative/review/primitives.tsx) |
| RN list-row composition | `ListRow` in [scaffold.tsx](../../ReactNative/review/scaffold.tsx) |
| Row title and supporting text | `LavaRowLabel` in [row-content.tsx](../../ReactNative/src/row-content.tsx) |
| Selection state and control | RN `Choice` in [primitives.tsx](../../ReactNative/review/primitives.tsx); native `LavaSelectableRow` in [LavaSelectableRow.swift](../../LavaSecApp/LavaDesignSystem/LavaSelectableRow.swift) |
| Typography roles | RN `Copy` in [primitives.tsx](../../ReactNative/review/primitives.tsx); native `LavaTypography` in [LavaTokens.swift](../../LavaSecApp/LavaDesignSystem/LavaTokens.swift) |
| RN primary, panel and secondary actions | `LavaActionButton` in [components.ios.tsx](../../ReactNative/src/components.ios.tsx) |
| Settings disclosure | `SettingsDisclosure` in [settings-scaffold.tsx](../../ReactNative/review/settings-scaffold.tsx) |
| Benefit scenes | `BenefitScene` in [plus-scaffold.tsx](../../ReactNative/review/plus-scaffold.tsx) |

## Review a complete journey

Compare the changed atom with its closest siblings and audit every adopter. Check light/dark appearance, Dynamic Type, portrait/landscape, keyboard and iPad layouts. Verify navigation, dismissal, cancellation, pending/error feedback, persistence and accessibility using the full app as well as isolated components.

Source checks establish wiring and policy, not rendered fit or device behavior. Record fresh build/render evidence separately from implementation claims. Dated planning, release trials and review receipts belong in infra, outside the public source tree.
