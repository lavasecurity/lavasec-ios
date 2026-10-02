# App Store screenshots

The legacy SwiftUI screenshot scripts and launch-argument capture root are retired.
They rendered pages that are no longer the app UI.

Use the current RN tools for development captures:

- `ReactNative/scripts/build-review-host.sh` builds the isolated fixture gallery.
- `ReactNative/scripts/build-full-app.sh --journeys` exercises the complete RN app
  against its native controllers and saves journey evidence.

Neither command exports a complete App Store screenshot set. Store-ready locale
and device capture automation must be added against the RN navigator before the
next screenshot refresh. See [app ownership](../docs/architecture/rn-only-app.md).
