# Lava Security iOS localization

English is the source language. The supported language list is owned by
`Config/supported-locales.json`: `en`, `ja`, `zh-Hant`, `zh-Hans`, `de`, `fr`,
`es`, `ko`, `pt-BR`, and `it`.

## Lookup ownership

- App and React Native UI: `LavaSecApp/Localizable.xcstrings`. Generate the React
  Native table with `node ReactNative/scripts/generate-localizations.mjs`.
- Permission prompts: `LavaSecApp/InfoPlist.xcstrings`.
- Intents extension metadata: `LavaSecIntents/Localizable.xcstrings`.
- Shared errors, notifications, and widgets: `Sources/LavaSecKit/Resources/*.lproj/Localizable.strings`
  through `LavaCoreStrings` and `Bundle.module`. An app catalog entry does not
  satisfy a package lookup, or vice versa.

Use `localized` / `localizedFormat` in React Native, `lavaLocalized` /
`lavaLocalizedFormat` in native app code, and `LavaCoreStrings` in package code.
Translate each component before composing a sentence, accessibility label, or
multiline summary. Runtime values need a catalog format key; interpolating an
English sentence before lookup creates an unknown key. Preserve argument types
and positions, including AppIntents `${parameter}` tokens.

Product, provider, protocol, and user-created names remain intact. Reproduced
upstream license text remains verbatim. App-authored attribution explanations
are translated. Internal debug/QA-only UI is outside release copy coverage.

The Guard page header and tab both resolve the `Guard` key. Traditional Chinese
uses `防護`; Simplified Chinese uses `防护`.

## Required checks

Run from the repository root:

```sh
node scripts/check-localization.mjs
node scripts/check-string-coverage.mjs
node --test scripts/tests/localization-formats.test.mjs scripts/tests/check-string-coverage.test.mjs
npm --prefix ReactNative run i18n:check
npm --prefix ReactNative run test:i18n
```

The catalog check validates every key in all supported languages, nonempty
translated units, scoped identical-English exceptions, and placeholder parity.
The Swift coverage check validates app, native bridge, Intents, shared, widget,
and package lookup sites against the bundle that actually resolves them. The
React Native AST check also finds source copy before it is rendered, including
accessibility props, errors, enumerable template variants, and runtime English
sentence interpolation. `npm --prefix ReactNative test` runs these checks along
with the UI and type suites; CI runs both the native and React Native gates.

## October 2026 audit

The audit traced release UI, native bridge error paths, shared errors, backup
status, legal summaries, timestamps, dynamic labels, and accessibility copy.
It added missing translations, localized composed values at their producer, and
removed the broad English exemption for `Guard`. Regression coverage verifies
both actual navigation labels in all ten languages and package copy lookup in
all nine translated languages.

The resulting catalogs contain 1,718 app keys, 4 permission keys, 5 Intents keys,
and 123 package keys: 1,850 keys with 18,500 nonempty translated units across ten
languages. The audit added 120 app keys and 43 package keys. All catalog,
placeholder, generated-table, and source coverage gates pass. The React Native
source gate scans 72 files in addition to the Swift/native coverage gate.

Validation passed: 5,485 Swift tests, 752 React Native UI tests, TypeScript
checking, repository guardrail fixtures, the Metro release bundle check, and a
full Simulator app compile with 60 UIKit regression checks. Device journeys
were not executed by this compile run.

Catalog completeness and source checks are automated coverage measurements.
They do not establish native-speaker quality or prove every device layout and
VoiceOver journey. Translation review and device checks remain necessary when
shipping changes to copy or layout. Dormant DNS preset metadata and unused
fallback presentation helpers are not rendered release UI; they retain source
keys until they acquire a display caller.


## VPN chaining follow-up

VPN setup, forced-stop recovery, active-configuration rotation warnings, and
WireGuard file/parser/key-storage failures now have copy in all ten supported
languages. Shared WireGuard errors resolve in `Bundle.module`; the legacy app
file reader resolves the same copy in the app catalog. Typed diagnostics stay
outside displayed recovery text. Server sign-in error prose also remains
diagnostic data; the displayed authentication failure uses translated copy.

The Swift source gate checks static message and notice keys as well as literal
lookup sites. Regression tests cover the actual rotation-warning model copy,
formatted file sizes, package-language lookup, and error payload privacy.
React Native tests cover regional language tags and composed connection values.

Native DNS projections distinguish localized display labels from provider and
user identities. Translate app-owned defaults before composing summaries;
preserve authored names in both visible text and accessibility labels. Do not
persist a localized display fallback as an authored name. React Native regional
locales resolve to a supported catalog, preserving explicit Chinese script tags.
The decorative onboarding mascot exposes no animation-state words to VoiceOver;
the setup controls and Ready content retain meaningful localized state.

The app catalog contains 1,745 keys and the shared package contains 139 keys.
The permission and Intents catalogs retain their four and five keys. All 1,893
keys have nonempty units in all ten supported languages.
