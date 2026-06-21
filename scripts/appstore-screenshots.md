# App Store screenshots

`capture-appstore-screenshots.sh` produces App Store Connect screenshots at the
required device sizes, reusing the same launch-argument capture path as the
website-asset capture (so the Guard hero renders identically to the marketing site).

## Usage

```bash
# Default: iPhone 16 Pro Max (6.9"), the 6 shipped locales, "protected" Guard hero.
scripts/capture-appstore-screenshots.sh

# Override device set / locales / states:
LAVA_APPSTORE_DEVICES="iPhone 16 Pro Max" \
LAVA_APPSTORE_LOCALES="en de" \
scripts/capture-appstore-screenshots.sh
```

Output lands in `fastlane/screenshots/<locale>/<index>_<device>_<screen>.png`,
ready for `fastlane deliver` once metadata is wired up (see the infra release-prep plan).

## Device sizes

App Store Connect now accepts a single **6.9"** iPhone set (iPhone 16 Pro Max,
1320×2868) and upscales it to the 6.7"/6.5" listings. Add a 6.5" device to
`LAVA_APPSTORE_DEVICES` only if you want a dedicated set. iPad sizes are required
only if the app is published as universal.

## Multi-screen sets (follow-up)

The reliable, ready-now shot is the **`protected` Guard hero** — it uses the
curated `-lavaWebsiteCaptureState` capture screen, so it's populated and chrome-free.

A full listing wants 3–5 shots (Guard, Filters, Activity, Plus). Setting
`LAVA_APPSTORE_DEEPLINKS=1` will *additionally* launch the real app and deep-link
to `upgrade`/`guard`/`filters`/`activity`, but those real screens render with
**empty/default data** in a fresh simulator (no sample blocklists or activity
history), so they are not yet listing-quality.

To make them listing-quality, add a small **screenshot/demo seed mode** to the app
(a launch arg that pre-populates representative Filters/Activity data, mirroring how
`-lava-website-asset-capture` curates the Guard screen), then promote the deep-link
screens out of the experimental block. That app-side change is tracked as a
follow-up in the release-prep plan, not done here.

## Notes

- Requires a Mac with Xcode + iOS simulators; this script has only been
  syntax-checked in CI-less environments — run it on a build machine to produce assets.
- The status bar is pinned to the canonical 9:41 / full-signal / 100% for clean shots.
