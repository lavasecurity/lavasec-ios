# Lava Security for iOS

[![iOS CI](https://github.com/lavasecurity/lavasec-ios/actions/workflows/ios.yml/badge.svg)](https://github.com/lavasecurity/lavasec-ios/actions/workflows/ios.yml)
[![Security](https://github.com/lavasecurity/lavasec-ios/actions/workflows/security.yml/badge.svg)](https://github.com/lavasecurity/lavasec-ios/actions/workflows/security.yml)
[![Swift 6.0](https://img.shields.io/badge/Swift-6.0-FA7343?logo=swift&logoColor=white)](https://swift.org)
![Platform: iOS 17+](https://img.shields.io/badge/platform-iOS%2017%2B-000000?logo=apple&logoColor=white)
[![License: AGPL-3.0](https://img.shields.io/badge/license-AGPL--3.0-blue)](LICENSE)

Privacy-first, on-device DNS filtering for iPhone and iPad. Lava runs a local
`NEPacketTunnelProvider` that resolves DNS over an encrypted transport
(DoH/DoT/DoQ) and filters domains against on-device blocklists — your browsing
domains are not routinely uploaded anywhere.

This is the open-source iOS client. The backend, marketing site, and operational
infrastructure live in separate (private) repositories.

> **Status:** Pre-1.0 and pre-launch. The on-device DNS-filtering core is
> functional; app surfaces, APIs, and configuration may still change before the
> first App Store release. Issues and discussion are welcome — see
> [CONTRIBUTING](CONTRIBUTING.md).

## Highlights

- **On-device filtering** — DNS resolution and blocklist matching happen inside
  the Network Extension; no per-request domain upload.
- **Encrypted DNS** — DoH / DoT / DoQ transports.
- **Memory-bounded** — blocklists are mmap'd to stay within the Network
  Extension memory budget.
- **Optional account features** — encrypted backup via Supabase: zero-knowledge
  with your recovery phrase, plus an optional Passkey for server-assisted restore
  (entirely optional; the core filter works with no account).

## Repository layout

| Path | What it is |
|------|------------|
| `LavaSecApp/` | The main SwiftUI app |
| `LavaSecTunnel/` | `NEPacketTunnelProvider` network extension (the filter engine) |
| `LavaSecWidget/` | Home-screen / Live Activity widget |
| `Shared/` | Code shared across the app and extensions (App Group, guardian, command service) |
| `Sources/`, `Tests/` | SwiftPM core library + unit tests |
| `LavaSecUITests/` | UI tests |
| `Config/` | Build configuration templates (`Lava.local.xcconfig.example`) |
| `docs/legal/` | Third-party notices and license-compliance decisions |

## Building

Requirements: Xcode 26 or newer, an iOS 18+ device or simulator.

```sh
git clone https://github.com/lavasecurity/lavasec-ios
cd lavasec-ios
cp Config/Lava.local.xcconfig.example Config/Lava.local.xcconfig   # then fill in your team / Supabase
open LavaSec.xcodeproj
```

- The **local DNS-filtering core** builds and runs with no account configuration.
- To run on a **physical device** you need your own Apple Developer team and a
  Network Extension provisioning profile (set `DEVELOPMENT_TEAM` and the profile
  names in `Config/Lava.local.xcconfig`).
- The optional **account / backup** features require your own Supabase project
  (`LAVA_SUPABASE_URL` / `LAVA_SUPABASE_ANON_KEY`).

### Schemes & tests

- **Scheme:** `LavaSec` (builds the app, Network Extension, and widget).
- **Run the core library tests:**

  ```sh
  swift test --package-path .
  ```

- **Build for the simulator (no signing required):**

  ```sh
  xcodebuild -project LavaSec.xcodeproj -scheme LavaSec \
    -configuration Debug -destination 'generic/platform=iOS Simulator' \
    CODE_SIGNING_ALLOWED=NO build
  ```

The simulator build exercises the app and the filter core. The VPN / Network
Extension itself only runs on a **physical device** — select your Apple
Developer team in `Config/Lava.xcconfig` and run the `LavaSec` scheme from Xcode.
These same checks run in CI (`.github/workflows/ios.yml`).

## License

[GNU Affero General Public License v3.0](LICENSE). See [`docs/legal/third-party-notices.md`](docs/legal/third-party-notices.md)
for third-party dependencies and blocklist data attribution.

## Security

Please report vulnerabilities privately — see [SECURITY.md](SECURITY.md). Do not
open public issues for security reports.
