# Lava Security for iOS

[![iOS CI](https://github.com/lavasecurity/lavasec-ios/actions/workflows/ios.yml/badge.svg)](https://github.com/lavasecurity/lavasec-ios/actions/workflows/ios.yml)
[![Security](https://github.com/lavasecurity/lavasec-ios/actions/workflows/security.yml/badge.svg)](https://github.com/lavasecurity/lavasec-ios/actions/workflows/security.yml)
[![Swift 6.0](https://img.shields.io/badge/Swift-6.0-FA7343?logo=swift&logoColor=white)](https://swift.org)
![Platform: iOS 18+](https://img.shields.io/badge/platform-iOS%2018%2B-000000?logo=apple&logoColor=white)
[![License: AGPL-3.0](https://img.shields.io/badge/license-AGPL--3.0-blue)](LICENSE)

[<img src="docs/media/app-store-badge.svg" alt="Download on the App Store" height="40">](https://apps.apple.com/app/lava-security/id6778022110)

**The internet is lava — so I made a blocklist app even my dad can use.**

Lava blocks known-bad domains on your iPhone — no account, and nothing routed
through us. Core protection is free, it's live on the App Store, and the client
is fully open source.

This repo is that client for [Lava Security](https://lavasecurity.app); the
backend, marketing site, and operational infrastructure live in separate
(private) repositories.

> **Status:** Live and actively developed — surfaces, APIs, and configuration can
> still change between releases. Issues and discussion are welcome; see
> [CONTRIBUTING](CONTRIBUTING.md).

## How it works

Lava runs a local `NEPacketTunnelProvider` that resolves DNS over an encrypted
transport (DoH/DoT/DoQ) and filters domains against on-device blocklists. Your
browsing domains are not routinely uploaded anywhere.

## Highlights

- **On-device filtering** — DNS resolution and blocklist matching happen inside
  the Network Extension; no per-request domain upload.
- **Encrypted DNS** — DoH / DoT / DoQ, with the resolver you choose.
- **Memory-bounded** — blocklists are mmap'd to stay within the Network
  Extension memory budget.
- **Optional account** — encrypted, zero-knowledge backup via Supabase with your
  recovery phrase, plus an optional Passkey for server-assisted restore. The core
  filter works with no account.

## Repository layout

| Path | What it is |
|------|------------|
| `ReactNative/` | React Native screens, navigation, and the generated iOS workspace — the supported app entry point |
| `LavaSecApp/` | Native app host, services, and native views used by RN |
| `LavaSecTunnel/` | `NEPacketTunnelProvider` network extension (the filter engine) |
| `LavaSecWidget/`, `LavaSecIntents/` | Widget / Live Activity and App Intents extensions |
| `Shared/` | Code shared across the app and extensions (App Group, guardian, command service) |
| `Sources/`, `Tests/` | Layered SwiftPM core library (`LavaSecKit` through `LavaSecCore`) + unit tests |
| `LavaSecUITests/` | UI tests |
| `Catalog/`, `Config/` | Blocklist catalog inputs and build configuration templates |
| `docs/` | Architecture, invariants, testing, and license notes |

See [RN app ownership and native retention](docs/architecture/rn-only-app.md) for
the React Native / native split.

## Building

Install Xcode 26+, Node matching `ReactNative/package.json` engines
(`^22.13 || ^24.3 || >=26`, with npm), Ruby 3.3.12 with Bundler 4.0.16, and
Python 3 on your `PATH`. The first preparation installs the locked npm and
CocoaPods dependencies, downloads the pinned XcodeGen, runs the RN checks, and
generates the workspace — so it needs network access. The DNS-filtering core
builds with no account configuration; a **physical device** needs a Developer
team and a Network Extension provisioning profile.

```sh
git clone https://github.com/lavasecurity/lavasec-ios
cd lavasec-ios
cp Config/Lava.local.xcconfig.example Config/Lava.local.xcconfig   # then fill in your team / Supabase
bash ReactNative/scripts/prepare-full-app.sh /tmp/lava-rn-build /tmp/lava-rn-evidence
open ReactNative/native-app/LavaSecRN.xcworkspace
```

- Set `DEVELOPMENT_TEAM` and the profile names in
  `Config/Lava.local.xcconfig` to run on a device.
- The optional **account / backup** features need your own Supabase project
  (`LAVA_SUPABASE_URL` / `LAVA_SUPABASE_ANON_KEY`).

### Schemes & tests

- **Scheme:** `LavaSec` (builds the app, Network Extension, and widget).
- **Core library tests:**

  ```sh
  swift test --package-path . -Xswiftc -warnings-as-errors
  ```

- **Simulator build (no signing required):**

  ```sh
  xcodebuild -workspace ReactNative/native-app/LavaSecRN.xcworkspace -scheme LavaSec \
    -configuration Debug -destination 'generic/platform=iOS Simulator' \
    CODE_SIGNING_ALLOWED=NO build
  ```

The simulator build exercises the app and the filter core; the VPN / Network
Extension itself only runs on a physical device. CI runs these same checks
(`.github/workflows/ios.yml`).

## License

[GNU Affero General Public License v3.0](LICENSE). See
[`docs/legal/third-party-notices.md`](docs/legal/third-party-notices.md) for
third-party dependencies and blocklist data attribution.

## Security

Please report vulnerabilities privately — see [SECURITY.md](SECURITY.md). Do not
open public issues for security reports.
