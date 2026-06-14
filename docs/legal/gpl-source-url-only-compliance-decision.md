# GPL Blocklist Launch Decision

Last reviewed: 2026-05-26
Legal reviewer: Not reviewed
Engineering owner: Lava Security
Launch status: HaGeZi and OISD visible as opt-in source-url-only catalog options; AdGuard inactive pending counsel or upstream permission

This document records Lava Security's v1 engineering decision. It is not legal advice. Production terms and app-store submissions should still be reviewed by qualified open-source licensing counsel.

## Distribution Mode

For v1, Lava does not publish GPL blocklist bytes. HaGeZi and OISD are visible source-url-only options that the app fetches directly from upstream only when selected. The app defaults to a permissive/public-domain source and supports paid user-provided Pi-hole-compatible HTTPS URLs fetched directly by the user's device.

## Required Engineering Controls

| Control | Required state |
| --- | --- |
| R2 blocklist objects | Not written for third-party blocklist content |
| Worker blocklist routes | No public `/v1/blocklists/.../domains.txt` artifact route |
| Active curated GPL catalog entries | HaGeZi and OISD source-url-only metadata only |
| App defaults | Block List Basic only |
| Custom URLs | User-provided, paid, fetched on-device, not sent to Lava servers |
| On-device cache | Raw downloaded lists and compiled snapshots stay local to the device |
| IPA content | Third-party list content is not bundled in production app artifacts |

## Source Decisions

| Source family | License recorded by Lava | v1 state | Notes |
| --- | --- | --- | --- |
| HaGeZi DNS Blocklists | GPL-3.0 | Active source-url-only option; off by default | Show attribution/license/source URL; do not bundle, proxy, transform, or default-enable. |
| OISD | GPL-3.0 | Active source-url-only option; off by default | Show attribution/license/source URL; do not bundle, proxy, transform, or default-enable. |
| AdGuard DNS Filter | GPL-3.0 | Inactive; license review | Do not default-enable or show as ordinary curated source. |

## Counsel Questions

- Does listing GPL source metadata without proxying bytes avoid Lava conveying GPL list copies?
- Does Apple's App Store distribution path create any additional issue for a proprietary app that points users to GPL-licensed remote data sources?
- What EULA carve-out language should Lava use so Lava terms do not restrict upstream open-source rights?
- Do any upstream projects require explicit permission for inclusion in a curated source catalog even when Lava does not proxy or serve their list bytes?

## Launch Decision

Launch decision: ship v1 with Block List Basic as the only default, keep HaGeZi and OISD as opt-in source-url-only catalog choices, keep AdGuard inactive, and require counsel review before any GPL source becomes default-enabled or Lava-hosted.
