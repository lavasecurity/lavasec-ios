# Contributing to Lava Security for iOS

Thanks for your interest in contributing.

## Before you start

- This project is licensed under the **AGPL-3.0**. By contributing you agree
  your contributions are licensed under the same terms. _(TODO: decide whether a
  CLA / DCO sign-off is required.)_
- For anything beyond a small fix, open an issue first to discuss the approach.

## Development setup

1. `cp Config/Lava.xcconfig.example Config/Lava.xcconfig` and fill in your values
   (see the [README](README.md)).
2. Open `LavaSec.xcodeproj` in Xcode 26+.
3. The DNS-filtering core builds without any account configuration.

## Ground rules

- **Never commit secrets or signing config.** `Config/Lava.xcconfig` is
  gitignored; keep real Supabase keys, Apple Team IDs, and provisioning profile
  names out of tracked files.
- Run the test suite before opening a PR.
- Match the style and patterns of the surrounding code.

## Privacy is the product

Lava's core promise is that browsing domains are not routinely uploaded. Changes
that add network calls, telemetry, or data collection will get extra scrutiny and
generally need an explicit opt-in and a clear privacy rationale.
