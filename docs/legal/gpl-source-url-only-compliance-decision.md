# GPL Blocklist Launch Decision

Last reviewed: 2026-06-21
Review type: Engineering self-review (not a formal legal opinion)
Engineering owner: Lava Security
Launch status: HaGeZi and OISD (GPL-3.0) shipped as opt-in, off-by-default, source-url-only catalog options. AdGuard (GPL-3.0) and 1Hosts (MPL-2.0) carry the identical source-url-only posture and are eligible on the same terms; whether a given copyleft source is in the catalog is a product/catalog decision — annotated per-source by the canonical manifest's `counsel_status` review field (bookkeeping, not a runtime gate) — not a licensing bar.

This document records Lava Security's engineering decision. It is not legal
advice. The decision was self-reviewed against the upstream licenses and project
terms rather than by retained counsel; a one-off counsel check remains optional
before any GPL source becomes default-enabled or Lava-hosted.

## Distribution Mode

Lava does not publish GPL blocklist bytes. HaGeZi and OISD are source-url-only
options that the app fetches directly from upstream only when the user selects
them. The app's fresh-install default is a permissive/public-domain source (Block List
Basic, Unlicense), and it supports paid user-provided
Pi-hole-compatible HTTPS URLs fetched directly by the user's device.

Because Lava never conveys the list bytes, the GPL-3.0 distribution obligations
attach to the upstream projects' own distribution, not to Lava. The app being
AGPL-3.0 (GPLv3-compatible) removes any separate app-license conflict if a list
were ever bundled in future.

## Required Engineering Controls

| Control | Required state |
| --- | --- |
| R2 blocklist objects | Not written for third-party blocklist content |
| Worker blocklist routes | No public `/v1/blocklists/.../domains.txt` artifact route |
| Active curated GPL catalog entries | HaGeZi, OISD, and AdGuard source-url-only metadata |
| App defaults | Block List Basic (the source flagged `defaultEnabled: true`); Unlicense |
| Custom URLs | User-provided, paid, fetched on-device, not sent to Lava servers |
| On-device cache | Raw downloaded lists and compiled snapshots stay local to the device |
| IPA content | Third-party list content is not bundled in production app artifacts |
| Off-by-default | Copyleft sources ship `defaultEnabled: false`; the fresh-install set is `DefaultCatalog.recommendedDefaultSourceIDs` — currently Block List Basic (the source flagged `defaultEnabled: true`). This per-source flag is the actual control that keeps GPL/MPL sources off by default. |
| Cache safeguard | `inactiveGPLLaunchSourceIDs` is a narrow cache-migration safeguard (forces a low-risk refresh and purges any cached bytes for the listed IDs). It is **not** a default-enable gate and does not filter a remote catalog — do not rely on it as a launch control. |

## Source Decisions

| Source family | License | State | Notes |
| --- | --- | --- | --- |
| HaGeZi DNS Blocklists | GPL-3.0 | Shipped: source-url-only, off by default | Show attribution/license/source URL; do not bundle, proxy, transform, or default-enable. |
| OISD | GPL-3.0 | Shipped: source-url-only, off by default | Show attribution/license/source URL; do not bundle, proxy, transform, or default-enable. |
| AdGuard DNS Filter | GPL-3.0 | Shipped: source-url-only, off by default | Same copyright posture as HaGeZi/OISD under source-url-only. Non-copyright note: "AdGuard" is a commercial trademark — use the name nominatively to identify the source only, with no implied endorsement. |
| 1Hosts (Lite) | MPL-2.0 | Shipped: source-url-only, off by default | MPL-2.0 is weak / file-level copyleft and combinable with other code; under source-url-only no share-alike obligation is triggered — lower-friction than the GPL sources. |

## Upstream terms (checked 2026-06-21)

- **HaGeZi** (`github.com/hagezi/dns-blocklists`): GPL-3.0. The README disclaimer
  states redistribution and adaptation are permitted within the applicable
  open-source license terms, with no additional permission gate and an as-is /
  no-warranty disclaimer. (HaGeZi's separate free public *resolvers* are
  described as non-commercial; that applies to their hosted DNS servers, not the
  blocklists, and Lava does not use them.)
- **OISD** (`github.com/sjhgvr/oisd`): GPL-3.0, with no additional terms in the
  repo or on oisd.nl beyond a voluntary donation request.
- **AdGuard DNS Filter** (`github.com/AdguardTeam/AdGuardSDNSFilter`): GPL-3.0 —
  same terms as HaGeZi/OISD. Under source-url-only no redistribution obligation
  attaches regardless of whether it ships.
- **1Hosts** (`github.com/badmojr/1Hosts`): MPL-2.0 (weak / file-level copyleft).
  Source-url-only does not trigger the share-alike obligation.

Net: for the bytes Lava references, GPL-3.0 governs and no active upstream
imposes a permission requirement beyond it. Lava's source-url-only posture means
it is not redistributing in any case.

## Self-review findings (resolved)

- Listing GPL source metadata and fetching upstream URLs on-device, without
  proxying bytes, means Lava does not convey GPL list copies — the trigger for
  GPL distribution duties is not met.
- App Store path: Lava distributes only its own AGPL-3.0 app code (sole
  copyright holder) plus permissively licensed (Apache-2.0) dependencies; it
  ships no third-party GPL code and no GPL list data through Apple, so the
  "GPL on the App Store" conflict does not arise.
- Carve-out wording is finalized in
  [`open-source-list-data-terms-carveout.md`](open-source-list-data-terms-carveout.md).
- No active upstream requires explicit permission for source-url-only reference
  (see "Upstream terms").

## Residual / deferred (optional counsel)

- Default-enabling or Lava-hosting any GPL source would change the analysis and
  should get a counsel check first.
- Patent freedom-to-operate and trademark items are tracked in the internal IP
  risk register.

## Launch Decision

Ship with Block List Basic as the fresh-install default; copyleft sources (GPL-3.0,
MPL-2.0) as opt-in, off-by-default, source-url-only choices. Off-by-default is
enforced by each source's `defaultEnabled: false` (the fresh-install set is
`DefaultCatalog.recommendedDefaultSourceIDs`); `inactiveGPLLaunchSourceIDs` is a
cache-migration safeguard, not a default-enable gate, and `counsel_status` in the
canonical catalog manifest is a review-tracking annotation, not a runtime control.
Default-enabling any copyleft source would require a deliberate code change to its
`defaultEnabled` flag and a counsel check first; Lava-hosting one would likewise
require counsel review.
