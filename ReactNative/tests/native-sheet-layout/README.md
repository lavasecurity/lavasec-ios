# Retired historical sheet-layout harness

This extraction fixture targets the removed `LavaFullSheetHeader`. Its former
78 checks do not qualify current native navigation or sheet behavior. The runner
now fails immediately with an explicit retirement message. Preserve the fixture
and old evidence as history; use the full-app shared-editor and Round 8 closeout
journeys for actual current presentation, scrolling and dismissal qualification.

## Historical fixture contract

# Native sheet layout verification

This small simulator app measures the real shared SwiftUI header, circular controls and permission cards inside an offset `UIHostingController`. UIKit background probes record the rendered frames. SwiftUI accessibility containers expose the union of accessible children, which cannot measure blank padding or decorative card bounds accurately.

The fixture checks three proposed widths (320, 393 and 768 points), standard text and Dynamic Type accessibility3. Its long header title exercises wrapping. Each of the six cases checks the actual 18-point top and leading insets, 44-point controls, trailing alignment and equal permission-card dimensions: 78 checks in total.

`extract-native-sheet-layout.py` copies these declarations verbatim from production source and records their source paths, line ranges and SHA256 hashes:

- `LavaFullSheetHeader`, `LavaToolbarIconButton`, `NativeToolbarIconButton`, `LavaActionRole`, `LavaCircularIconLabel`, `LavaToolbarIconSymbol`, `LavaSetupPermissionIllustration`, `lavaRowTitleText()` and `lavaSupportingText()` from `LavaScaffold.swift`.
- `LavaPlainCard` from `LavaComponents.swift`.
- `LavaGuardianShieldShape` and `LavaGuardianPathMapper` from `Shared/SoftShieldGuardian.swift`.
- Whole unchanged files: `LavaTokens.swift`, `LavaStrings.swift` and `LavaIconSize.swift`.

The generated source has no layout stubs or replacement formulas. The original localization helper uses English fallback strings in the resource-free test bundle. The extractor rejects missing/duplicate declarations and unsupported raw or multiline strings. Generated Swift must compile with Swift 6 and warnings treated as errors.

From `ReactNative`, provide an already booted task-private simulator:

```sh
bash scripts/test-native-sheet-layout.sh "$LAVA_TEST_SIMULATOR" .artifacts/sheet-layout/actual
```

The script installs a separate test app, exports `native-sheet-layout-results.json` and `source/source-manifest.json`, and uninstalls only its own test bundle. It preserves the Lava app and its data.

Two negative controls alter only generated test copies. Both commands must fail, with complete 78-check reports identifying the intended geometry regression:

```sh
bash scripts/test-native-sheet-layout.sh "$LAVA_TEST_SIMULATOR" .artifacts/sheet-layout/top-negative header-top
bash scripts/test-native-sheet-layout.sh "$LAVA_TEST_SIMULATOR" .artifacts/sheet-layout/cards-negative independent-illustrations
```

`header-top` restores the old 8-point top inset; `independent-illustrations` lets only the selected illustration determine its card height. The source manifest explicitly records the mutation and generated-source hash. A missing report or unrelated launch/compiler error is not evidence that a negative control worked.

This verifies component layout at the proposed widths. The full app journeys and screenshots remain responsible for UIKit sheet presentation, safe-area placement, navigation, privacy, persistence and actual user interaction. React Native header frames continue to be measured in their full app journeys.
