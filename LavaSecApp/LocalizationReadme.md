# Lava Security iOS Localization

English is the source locale. Priority locales are:

1. 日本語: `ja`
2. 繁體中文: `zh-Hant`
3. 简体中文: `zh-Hans`
4. Deutsch: `de`
5. Français: `fr`

Use `Localizable.xcstrings` for app UI strings and `InfoPlist.xcstrings` for Info.plist strings. Keep `Lava Security` as the display name in every locale for the first localized release.

Release UI strings use `Localizable.xcstrings` entries for both direct SwiftUI labels and string values passed through shared components. `LavaStrings.localized(...)` and the `String.lavaLocalized` helpers are for dynamic strings that would otherwise render as verbatim English.

The localization check enforces a baseline release-app key set across `en`, `ja`, `zh-Hant`, `zh-Hans`, `de`, and `fr`. Internal QA/debug strings can remain English unless they become visible in release builds.

Review guidance lives in:

- `docs/i18n/localization-file-schema.md`
- `docs/i18n/lava-security-glossary.md`
- `docs/i18n/translation-review-checklist.md`

Run the localization check from the repo root:

```bash
node apps/ios/scripts/check-localization.mjs
```
