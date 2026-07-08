# Contributing to Lava Security for iOS

Thanks for your interest in contributing.

## Before you start

- This project is licensed under the **AGPL-3.0**. By contributing you agree
  your contributions are licensed under the same terms.
- **Sign off your commits (DCO).** Every commit must carry a
  `Signed-off-by: Your Name <you@example.com>` line — just commit with
  `git commit -s`. This is a [Developer Certificate of
  Origin](https://developercertificate.org/) sign-off: it certifies you wrote
  the change, or otherwise have the right to submit it under the AGPL-3.0. We do
  **not** require a CLA.
- For anything beyond a small fix, open an issue first to discuss the approach.

## Development setup

1. `cp Config/Lava.local.xcconfig.example Config/Lava.local.xcconfig` and fill in your values
   (see the [README](README.md)).
2. Open `LavaSec.xcodeproj` in Xcode 26+.
3. The DNS-filtering core builds without any account configuration.

### The Xcode project is generated

`LavaSec.xcodeproj/project.pbxproj` is **generated** from `project.yml` by
[XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`) — never
edit the pbxproj by hand. To change targets, per-target file membership (including
which targets a `Shared/` file compiles into), build settings, packages, or the
shared scheme:

1. Edit `project.yml` (it documents its own conventions).
2. Run `xcodegen generate` (post-generation fixups run automatically).
3. Commit `project.yml` **and** the regenerated project together.

The generated project stays committed so checkouts build without XcodeGen and
because the test suite pins target/embed wiring as pbxproj text.
`scripts/check-xcodegen-drift.sh` verifies the committed project still matches
`project.yml`; run it if you touched either side.

### Lint & format

- **SwiftLint** runs warning-only in CI (`Repo Checks`): findings annotate the PR, never
  block it. Config: `.swiftlint.yml`; `missing_docs` applies only inside the post-split
  SPM targets (`Sources/LavaSec{Kit,DNS,FilterPipeline,AppServices}` nested configs) —
  new public API there carries `///` docs.
- **swift-format** has a committed config (`.swift-format`) for local use
  (`swift format lint -r Sources` or your editor integration); it is not wired into CI.

## Ground rules

- **Never commit secrets or signing config.** `Config/Lava.xcconfig` is a
  tracked template (build metadata like `MARKETING_VERSION` only); your real
  values belong in `Config/Lava.local.xcconfig`, which is gitignored. Keep
  Supabase keys, Apple Team IDs, and provisioning profile names out of tracked
  files.
- Run the test suite before opening a PR.
- Match the style and patterns of the surrounding code.

## Privacy is the product

Lava's core promise is that browsing domains are not routinely uploaded. Changes
that add network calls, telemetry, or data collection will get extra scrutiny and
generally need an explicit opt-in and a clear privacy rationale.
