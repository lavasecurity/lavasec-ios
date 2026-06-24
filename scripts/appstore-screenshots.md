# App Store screenshots

`capture-appstore-screenshots.sh` produces App Store Connect screenshots at the
required device sizes, reusing the same launch-argument capture path as the
website-asset capture (so the Guard hero renders identically to the marketing site).

## Usage

```bash
# Default: iPhone 16 Pro Max (6.9"), 6 of the app's 10 locales, "protected" Guard hero.
scripts/capture-appstore-screenshots.sh

# Override device set / locales / states. Device names are newline-separated
# (one per line) because they contain spaces; locales/states stay space-separated.
LAVA_APPSTORE_DEVICES=$'iPhone 16 Pro Max\niPhone 16 Plus' \
LAVA_APPSTORE_LOCALES="en de" \
scripts/capture-appstore-screenshots.sh
```

The default captures `en ja zh-Hant zh-Hans de fr`; pass `LAVA_APPSTORE_LOCALES`
to add the remaining shipped locales (`es ko pt-BR it`).

Output lands in `fastlane/screenshots/<asc-locale>/<index>_<device>_<screen>.png`,
where `<asc-locale>` is the App Store Connect language code (e.g. `en-US`, `de-DE`).
This is a `fastlane deliver`-compatible tree — no `Fastfile`/metadata is committed yet.

## Device sizes

App Store Connect now accepts a single **6.9"** iPhone set (iPhone 16 Pro Max,
1320×2868) and upscales it to the 6.7"/6.5" listings. Add a 6.5" device as an extra
line in `LAVA_APPSTORE_DEVICES` only if you want a dedicated set.

**iPad:** the LavaSec target is universal (`TARGETED_DEVICE_FAMILY = 1,2`), so the App
Store listing also requires a 13" iPad set. The script captures whatever simulators you
list, so add an iPad to `LAVA_APPSTORE_DEVICES` to shoot it in the same run, e.g.
`LAVA_APPSTORE_DEVICES=$'iPhone 16 Pro Max\niPad Pro 13-inch (M4)'`. The default is the
required iPhone set only — the iPad set is a separate, slower pass kept out of the
default on purpose.

## Multi-screen sets (follow-up)

The reliable, ready-now shot is the **`protected` Guard hero** — it uses the
curated `-lavaWebsiteCaptureState` capture screen, so it's populated and chrome-free.

A full listing wants 3–5 shots (Guard, Filters, Activity, Plus). Setting
`LAVA_APPSTORE_DEEPLINKS=1` will *additionally* launch the real app and deep-link
to `settings/upgrade`/`guard`/`filters`/`activity`, but those real screens render with
**empty/default data** in a fresh simulator (no sample blocklists or activity
history), so they are not yet listing-quality. The `settings/upgrade` route is also
auth-gated, so on a simulator without an enrolled passcode/biometric it may not open.
A deep link that fails to route silently captures the previous screen, so **always
review deep-linked shots visually** before using them.

To make them listing-quality, add a small **screenshot/demo seed mode** to the app
(a launch arg that pre-populates representative Filters/Activity data, mirroring how
`-lava-website-asset-capture` curates the Guard screen), then promote the deep-link
screens out of the experimental block. That app-side change is tracked as a
follow-up in the lavasec-infra release-prep plan, not done here.

## Notes

- Requires a Mac with Xcode + iOS simulators. The script's argument parsing has been
  unit-checked, but a full capture run (build + simulator) has not — run it on a build
  machine to produce assets.
- Capture mode is compiled only into **Debug** builds, so the script requires
  `LAVA_APPSTORE_CONFIGURATION=Debug` (the default) and aborts on any other config.
- The status bar is pinned to the canonical 9:41 / full-signal / 100% for clean shots.
