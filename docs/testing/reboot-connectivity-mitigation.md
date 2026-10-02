# Reboot connectivity mitigation qualification

The October 1, 2026 device capture of `main-e6bfeffc` recorded one provider start
after the approximately 11:30 JST reboot. Initial shared-state preparation took
5.790 seconds. The first network-settings apply took 563 milliseconds, then a
second apply added the physically observed DNS-patch NAT64 destination and took
18.499 seconds. DNS work expiry and waiter overload continued after startup
readiness. An earlier cold start took 12.801 seconds for the second apply; a warm
restart took 244 milliseconds. These observations motivate consolidating the
initial settings apply; they do not establish an OS callback-delay cause or the
exact time browsing recovered.

The initial reported Connect On Demand switch-off has no conclusive cause in the
capture. New-profile creation and explicit OFF are recorded later, but do not
explain the earlier switch-off. Qualification must therefore check the saved
profile itself, rather than assuming that a connected tunnel has armed restart.
Keep raw device logs local; the PR needs only timings and event categories.

## Automated regression boundaries

- Initial DNS-patch discovery must explicitly succeed before the first settings
  snapshot is admitted. Actual observed endpoints, including a network-specific
  translation, must enter both the route plan and packet classifier together.
- Failed discovery, its existing five-second deadline, stale lifecycles, and
  cancellation must never approve unknown capture routes. A route change while
  an apply is pending still requires a serialized follow-up before readiness.
  A network/configuration refresh during startup must use the same drain and
  cannot overlap the initial settings post or bypass discovery settlement.
- On-demand arming must verify saved preferences and stop retrying when the
  connected epoch, explicit protection intent, or direct-Restart ownership changes.
  A failed read/save/readback must not publish a confirmed restart guarantee.
- An inactive app must still capture ownership before admitting an arm. A later
  foreground repair must require a successful saved-profile read, preserve explicit
  OFF, and retire stale asynchronous work.
  A fresh epoch must supersede an older pending arm; its late completion cannot
  confirm the replacement. A same-epoch retry must not duplicate an in-flight arm.
  Foreground saved-profile reads and cache/status publication must share the arm's
  mutation fence. A pending save/readback must finish before that read starts, so
  a correctly loaded disabled snapshot cannot erase the successful confirmation.
  OFF/background while waiting or reading must prevent publication.

## Physical-device acceptance

Use the supported RN QA build with the DNS patch and the same saved VPN profile.
Follow the broader first-unlock protocol in the infra repository at
`docs/engineering/reboot-first-unlock-qa-protocol.md`. Do not delete the profile or
change the resolver between cold and warm comparisons unless testing replacement.

1. Turn Guard on, wait for the saved-profile on-demand readback to succeed, and
   inspect Connect On Demand in iOS Settings. Background Lava immediately after
   enabling and repeat after a warm reconnect. The saved switch must remain on.
2. Reboot while locked, then unlock on the same Wi-Fi without opening Lava.
   Verify filtering and VPN forwarding recover automatically. Record kernel boot,
   first recorded provider entry, discovery completion, initial settings begin/end,
   startup readiness, and user-observed browsing recovery separately.
3. Verify the first settings apply already includes the discovered DNS-patch
   translation. An unchanged physical path must not require a second startup apply.
   Repeat on IPv4 and a NAT64 path; do not assume the well-known NAT64 prefix.
4. Repeat a warm reconnect and compare settings callback durations. Count DNS
   expiry/overload events and verify sustained client delivery, rather than treating
   an upstream-answer sample or `startTunnel-ready` as browsing success.
5. Turn Guard off during a pending arm/repair, then return to Lava. It must remain
   off and on-demand must remain disabled. Repeat a newer explicit Restart during
   an older pending operation; the old operation must not re-arm the old epoch.
6. With on-demand deliberately disabled while protection intent remains on, return
   to Lava and verify bounded repair against the saved profile. Failed readback must
   remain observable and must not create a continuous save/retry loop.
7. On a known split-tunnel chaining profile, repeat Lava Restart and a cold reboot
   with DNS fallback explicitly on, then explicitly off. Compare the saved
   `chainedTierTwoFallbackEnabled` configuration value before and after each run,
   and record the settings switch and runtime fallback status separately. Both
   choices must survive. Test full-tunnel suppression separately: its disabled
   fallback presentation must not be mistaken for a changed saved preference.

Unit tests and simulator/device-target compilation validate policy and wiring.
They do not prove a reboot latency improvement on physical iOS. The interval
before the first recorded provider entry and the unexplained bootstrap preparation
cost remain separate measurements; this mitigation does not impose an OS launch
deadline or change resolver queue/lifetime limits.
