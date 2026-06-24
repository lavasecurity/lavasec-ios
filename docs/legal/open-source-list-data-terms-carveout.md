# Open-Source List Data Terms Carve-Out

Last reviewed: 2026-06-21
Status: Engineering decision — self-reviewed. Not a formal legal opinion; counsel review deferred (optional). The "not legal advice" caveat in [`gpl-source-url-only-compliance-decision.md`](gpl-source-url-only-compliance-decision.md) applies here too.

This file holds the ship-ready carve-out language Lava uses so that Lava's own
terms (app EULA / App Store metadata) do not restrict the rights users receive
directly under third-party open-source licenses. It supersedes the earlier
"Draft for counsel review" wording.

## Why this is low-risk to adopt without counsel

A carve-out is a *defensive* clarification: it only ever **subtracts**
restrictions, so it cannot worsen Lava's position. The risk it addresses is the
opposite one — that broadly worded Lava terms could be read to impose "further
restrictions" on GPL-licensed material, which GPL-3.0 §7/§10 forbid. Three facts
keep the residual risk small:

1. **Source-url-only.** Lava never hosts, proxies, transforms, or bundles
   third-party list bytes; the device fetches selected lists directly from
   upstream. Because Lava does not *convey* the lists, the GPL distribution
   obligations on the list data are not triggered in the first place. See
   [`gpl-source-url-only-compliance-decision.md`](gpl-source-url-only-compliance-decision.md).
2. **The app is AGPL-3.0.** The client is itself copyleft and GPLv3-compatible,
   so there is no proprietary-app-restricting-OSS-rights tension on the app code
   side.
3. **Upstream terms add nothing beyond their license.** HaGeZi and OISD impose
   no permission gate beyond GPL-3.0 (see the compliance decision's "Upstream
   terms" section).

## Carve-out language — app (Settings → About → Open-Source Notices)

> Some blocklist and threat-intelligence data offered in Lava is published by
> third-party open-source projects and licensed by them under their own terms
> (for example, GPL-3.0, MPL-2.0, MIT, or the Unlicense). When you enable such a source,
> your device fetches that list directly from the upstream project; Lava does
> not host, modify, or redistribute the list contents. Nothing in Lava's Terms
> limits, replaces, or adds restrictions to the rights you receive directly
> under those third-party licenses, and to the extent of any conflict those
> licenses govern that data. Third-party list data is provided by its respective
> authors "as is", without warranty of any kind.

## Carve-out language — App Store metadata / website (short form)

> Optional blocklist sources are published by third-party open-source projects
> under their own licenses; when enabled, your device fetches them directly from
> the upstream project. Lava does not redistribute that data and does not
> restrict your rights under those upstream licenses.

## Placement

- **App:** the Open-Source / Third-Party Notices screen already renders the
  operative **per-source attribution** for every catalog source, including the
  shipped GPL options (`ThirdPartyLegalNotice.blocklistNoticeText`: name, license,
  owner/project, plus an "attribution and source identification" statement).
  Under source-url-only Lava conveys nothing, so that attribution is the notice
  that actually matters; adding the carve-out + no-warranty *prose* to the same
  screen is a **recommended follow-up**, not a precondition for shipping
  source-url-only sources.
- **App Store metadata:** short form, only if GPL sources are surfaced in
  marketing copy. The default-enabled set (Phishing + Scam) is
  permissive/public-domain and GPL sources are off by default, so this is
  optional for launch.
- **Website / docs:** the public manual carries the same notice via
  [`third-party-notices.md`](third-party-notices.md).

## Residual items (not blockers)

- The no-warranty line for third-party list data is part of the app carve-out
  text above; it ships when that text is added to the notices screen (see
  Placement) — no separate sign-off needed.
- Patent freedom-to-operate and trademark / nominative-use review are independent
  of this carve-out and tracked in the internal IP risk register, not here.
