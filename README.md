# Lava Security for iOS

Privacy-first, on-device DNS filtering for iPhone and iPad. Lava runs a local
`NEPacketTunnelProvider` that resolves DNS over an encrypted transport
(DoH/DoT/DoQ) and filters domains against on-device blocklists — your browsing
domains are not routinely uploaded anywhere.

This is the open-source iOS client. The backend, marketing site, and operational
infrastructure live in separate (private) repositories.

> **Status:** Open-source release in progress. This README is a starting point —
> sections marked _TODO_ will be filled out before the first tagged release.

## Highlights

- **On-device filtering** — DNS resolution and blocklist matching happen inside
  the Network Extension; no per-request domain upload.
- **Encrypted DNS** — DoH / DoT / DoQ transports.
- **Memory-bounded** — blocklists are mmap'd to stay within the Network
  Extension memory budget.
- **Optional account features** — encrypted, zero-knowledge backup via Supabase
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
| `Config/` | Build configuration template (`Lava.xcconfig.example`) |
| `docs/legal/` | Third-party notices and license-compliance decisions |

## Building

Requirements: Xcode 26 or newer, an iOS 18+ device or simulator.

```sh
git clone https://github.com/lavasecurity/lavasec-ios
cd lavasec-ios
cp Config/Lava.xcconfig.example Config/Lava.xcconfig   # then fill in your team / Supabase
open LavaSec.xcodeproj
```

- The **local DNS-filtering core** builds and runs with no account configuration.
- To run on a **physical device** you need your own Apple Developer team and a
  Network Extension provisioning profile (set `DEVELOPMENT_TEAM` and the profile
  names in `Config/Lava.xcconfig`).
- The optional **account / backup** features require your own Supabase project
  (`LAVA_SUPABASE_URL` / `LAVA_SUPABASE_ANON_KEY`).

_TODO: scheme names, simulator vs device notes, running the test suite._

## License

[GNU Affero General Public License v3.0](LICENSE). See [`docs/legal/third-party-notices.md`](docs/legal/third-party-notices.md)
for third-party dependencies and blocklist data attribution.

## Security

Please report vulnerabilities privately — see [SECURITY.md](SECURITY.md). Do not
open public issues for security reports.
