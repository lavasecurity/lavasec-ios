# Read-surface lifecycle audit — September 12

The shared `useAppQuery` is the read boundary. `mayCacheRead` enumerates eligible read commands and their native authorization surface. A mutation or newly introduced command does not inherit Activity's cache permission by default.

| Surface | Owner | Inactivity / re-entry contract |
| --- | --- | --- |
| Activity digest, date range | `activity.query` | Keep accepted unprotected digest; refresh after return. Different date range revokes retention. |
| Top Domains | `domains.query`, history=false | Same rule; decision/range/log scope isolates results; search can retain its own decision while debounced results arrive. |
| Domain History, search, pagination | `domains.query`, history=true | Same rule; a late older page cannot replace the current page. Disabled logging clears rows immediately. |
| Network Activity | `network.query` | Keep accepted rows and native category/warning themes through app switching. Clear-log revocation fences stale replies. |
| Nerd Stats: App, DNS tiers, health | `stats.query` | Keep accepted panels. Refresh the native health mirror before combining it with a prompt lifecycle reply. Unknown and stale health have explicit meanings. |
| Blocklist catalog and selected-list budget | `catalog.query` | Same retention under the filter-edit authorization scope. Preserve current filter rows while selected IDs change; never carry them into a different filter. |
| Share code and QR | `share.query` | Same-filter retention is explicit; the screen independently conceals QR content on inactivity. New filter/code, rejection, or revoked identity cannot reuse it. |
| Guard, Filters/library/detail, preparation, Settings, Account/Backup, Plus, Customization, DNS, Privacy, Security | `AppStore` native snapshot | Already connection-owned and retained across inactivity. Mutation/invalidation and read epochs update derived reads; stale snapshot revisions cannot overwrite newer native state. Do not add a second query layer over native controller state. |
| VPN chaining and configuration | Retained native page + native controller | Shared native containment retains the page; interaction gate does not change SwiftUI enabled styling during inactivity. Credentials remain native. |
| Legal notices | Bundled immutable catalog | Synchronous memoized bundle read; no periodic fetch or network cache. |
| Sudoku | Native generated/persisted game + session snapshot | `sudoku.new` generates a new game; it is not a repeatable read and must not be query-cached. |
| Filter review, staged domain review, import/restore reviews | Native transactional tokens | Authentication and exact draft/review identity determine validity. Never cache them as generic reads or replay confirmations. |
| Backup, authentication, purchase, export and other native sheets | Native controllers | Operation-owned state and teardown, not query cache. Preserve current progress only for that operation. |

For every eligible unprotected query: keep only the already accepted display value during inactivity; clear the shared cache, suspend polling and invalidate in-flight generations. Resume without blanking existing content, then accept a fresh reply. Interrupted successes and ordinary errors are discarded. Native credential cancellation still clears protected content and stops automatic prompts. Never overlap a pending native prompt with its replacement.

Protected or unknown authorization still clears diagnostic content on inactivity/unfocus. Account, protected-action policy, log policy, unavailable protected storage, and revoked read epochs fence both stored and displayed data. The behavior is covered across Activity, Network, Nerd Stats, both domain-list modes and catalog queries; Share has additional concealment/identity/cancellation tests. Native snapshot tests cover retention and stale-version rejection separately.

This is a code/contract audit, not proof that every physical-device transition is fixed. Current-head native screen journeys and device acceptance remain release gates.
