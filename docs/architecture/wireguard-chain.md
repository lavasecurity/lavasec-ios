# Ordered WireGuard configurations

VPN chaining stores zero, one, or two named profiles. A single profile behaves as
before. With two profiles, order selects an immutable destination-routing policy:

| Row 1 | Row 2 | Destination policy | Transport |
| --- | --- | --- | --- |
| Split | Full | Row 1 for matching destinations; row 2 for all others | Independent tunnels |
| Full | Split | Row 2 for its destinations; row 1 for all others | Row 2's connection travels inside row 1 |
| Full | Full | All captured destinations use row 2 | Successive encrypted hops |
| Split | Split | First matching row wins; unmatched traffic follows existing split behavior | Independent tunnels |

This is destination fallback, never failover after a transport error. Failure
cannot redirect a selected flow to another profile or open a direct socket for a
nested profile. The existing bounded outage/surrender lifecycle remains in charge.
A full profile anywhere makes the stack capture IPv4 default traffic and claim
IPv6 for the existing fail-closed drop; IPv6 forwarding remains unsupported.
The profiles retain their authored AllowedIPs. Split-only capture uses their union.

The virtual interface uses the last profile's client address. Each runner maps
that address to its own assigned address before encryption and maps replies back,
including TCP/UDP pseudoheader checksums and ICMP error quotations (RFC 1624).
Translation has no flow table. Malformed/unowned packets and unsupported
address-authenticated protocols are refused when translation is needed.
Incoming source ownership is checked before forwarding/liveness accounting.

General T0 DNS uses the full profile's DNS entries (row 2 when both are full),
or the first profile if both are split. Resolver addresses must pass the existing usability and route
coverage gates. This does not add domain/suffix-specific private DNS selection.
Client DNS still enters Lava's filter before any tunnel sends it. An enabled full profile
in either row forbids physical T1/T2 DNS fallback. All-split profiles retain
explicit fallback consent. DNS settings hide ineffective lower controls.

A full first row requires a numeric IPv4 second endpoint and sufficient MTU for
nested encapsulation. A split first row does not need to reach the second endpoint:
both tunnels bind independently to the physical interface. Hostname bootstrap
remains unsupported; the existing literal-endpoint readiness gate applies.

## Storage and editor

The existing configuration envelope remains the single atomic commit point. It
contains the exit plus one optional entry and their names, but no private or
pre-shared keys. Both profiles' secrets occupy one generation-scoped Keychain item in a versioned
binary layout built on the existing private-key/optional-PSK codec. No base64
String copies are created in the tunnel process.
New envelopes with disabled rows use schema 4; other two-profile envelopes use schema 3, so older builds refuse them rather than
applying obsolete strict-nesting semantics. Schema 3 remains readable. Legacy schema 2 is refused for explicit replacement, since silently applying destination routing would change its strict nested transport semantics. Enabled single profiles still use schema 1 and decode old records
without a name. Per-row save/remove uses the existing writer lock and checks the
editor's expected generation before changing anything.

The native editor receives only row index, name, existence, and a native staging callback.
The page follows the DNS editor's draft/Save/Cancel lifecycle and stable toolbar.
Navigation and the shared app-lock overlay own authorization and foreground privacy;
Control Center/background events never replace the page with an empty screen.
Switches persist independently and never enter edit mode; newly entered config material remains in
`ChainedUpstreamEditDraft` in native memory. Sheet Save, removal, order swaps, and recovery reset
only stage changes. Page Save checks the stored generation, commits all rows in one
generation, preserves the current switch choices, and requests a single reconnect
when needed. An unchanged Save only exits editing. Cancel/unmount releases profile
drafts without undoing independently saved switches. Switching chaining OFF restores
DNS settings regardless of the setup disclosure or saved profiles.
Both DNS and VPN lists share the panel action footer: Add below two rows, Swap
order at two rows, only during editing. VPN swaps move whole draft rows, preserving
original key indices and new replacement material. Draft rows strip saved chain
nesting before composition validation; refused swaps leave the draft untouched.
Swap never requests a VPN restart; only page Save may reconnect for edits. Swapping twice
restores the saved order without a write. Row taps open the sheet only in edit
mode. Outside editing, each numbered row carries the shared native switch. A row toggle
commits its participation immediately through the existing guarded reconnect; all rows
OFF returns to DNS-only without deleting keys. A stopped Guard stays stopped. Runtime
metadata and credentials select the same active row under a matching generation.
Composition checks retain endpoint and nested MTU safety constraints.
Deleting the final profile still persists OFF before deleting keys. If profiles
commit but the separate settings write fails, the draft rebases to the committed
generation for an explicit retry; the error is surfaced rather than reporting success.
The sheet confirms discard on Close or swipe when its name/content has changed. It
never rehydrates saved secret content. Rename preserves stored credentials inside
the store operation. Import and paste create a temporary replacement draft; import
starts concealed, Show configuration reveals only that draft, backgrounding
conceals it again, and successful sheet staging clears it. Empty editors open directly to the input scaffold; saved content is never rehydrated. The cover overlays the same editor geometry and substitutes empty text beneath it. The concealment scaffold draws
static blurred shapes rather than real configuration text. A missing single-profile
key can be replaced directly. Unreadable or missing chain secrets retain an explicit,
confirmed delete-all recovery action; no row is silently dropped to repair a chain.

## Transport and failure

`ChainedStackSessionSource` builds two existing bounded session runners and
exposes one session to the outage driver. For nested stacks, a connected relay
uses the first runner's engine/socket for the second engine's datagrams; it never
opens a physical socket to the second peer. Nested UDP replies are intercepted
before utun delivery and general-forwarding evidence. Both engines share one
serial engine queue and the existing admission/send bounds.

Transport rebinding preserves both engines; independent stacks rebind both
sockets, nested stacks rebind only the outer socket. Credential generations must
match at construction. Authentication and demanded-data evidence track both
branches so a working branch cannot certify a branch still awaiting a response.
A child ending shuts down the whole stack and reports one event. No new secret
cache or unbounded packet/flow table is introduced.

The shared MTU is the minimum of the profiles for independent stacks. Nested
stacks reserve 60 bytes plus padding for IPv4/UDP/WireGuard overhead and obey the
engine ceiling. An explicitly too-small full first profile is refused.

Executable tests cover both mixed orders and Full → Full using real Noise
handshakes, provider-assigned source addresses, reply translation, DNS filtering,
rebinding, and absence of direct-to-second sockets for nested stacks. Pure tests
cover overlap priority, full capture, general DNS selection, MTU, TCP/UDP and ICMP
checksums, fragments, and malformed input. Real-provider interoperability,
physical-device roam/rekey/outage behavior, and peak extension memory remain
qualification requirements.

Simulator UI verification (2026-09-28, iOS 27 QA build) covered prerequisite-off
visibility, the empty edit panel and Add action, the named native sheet, two
numbered saved rows with no third Add action, the disabled fallback explanation,
and the DNS page with all lower controls hidden. A synthetic pasted draft was
concealed after backgrounding and revealed only through Show configuration;
reopening a saved row originally offered a replacement cover; the follow-up now opens the empty replacement editor directly without loading or revealing secrets.
The UIKit-hosted editor observes application foreground notifications because its
SwiftUI scene phase can remain inactive. File-picker import and physical-provider
traffic were not exercised in this walkthrough.

The page retains the newest sheet-published draft through the native commit acknowledgement.
Clearing the native draft cannot briefly restore the older one-row page snapshot. The
regression test reproduces that publication order before verifying the stable two-row panel.
Draft swaps, additions and removals never write credentials or request runtime reloads.
