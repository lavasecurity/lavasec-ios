# Working in this repo

DNS-filtering iOS app. The app (`LavaSecApp/`), packet tunnel (`LavaSecTunnel/`),
widget, and App Intents extension consume a layered Swift package. Package code is split
across `LavaSecKit`, `LavaSecNetworking`, `LavaSecDNS`, `LavaSecFilterPipeline`,
`LavaSecPresentation`, and `LavaSecAppServices`. `LavaSecCore` is the compatibility
façade that re-exports all six layers. Production process targets link only their approved
narrow products, so the tunnel does not link Presentation, AppServices, or the façade.
Executable package tests live in `Tests/LavaSecCoreTests/`. `Shared/` files are
compiled into multiple targets by pbxproj membership. The pbxproj is GENERATED: edit
`project.yml` and run `xcodegen generate`, never the pbxproj itself
(`scripts/check-xcodegen-drift.sh` catches drift; see CONTRIBUTING.md). Read `README.md`
for build/test basics and `CONTRIBUTING.md` for ground rules; plans live in the
`lavasec-infra` repo under `plans/`.

## Comment conventions

This codebase deliberately carries dense rationale comments. Keep the culture, follow the
rules:

- A comment states what the code cannot: the security boundary, the memory budget, the
  queue/isolation contract, or the field evidence that forced the design.
- Cite durable anchors: invariant IDs from `docs/invariants.md` (e.g. `INV-DNS-1`),
  PR numbers, plan files. Never bare review-round shorthand ("P2 r5") — rounds are
  unresolvable later.
- If your diff falsifies a comment anywhere (including "this never happens" claims),
  update that comment in the same diff. Registry-listed invariants also update
  `docs/invariants.md`.
- Safety-critical invariant comments are paired with their enforcement: either a test/
  source pin asserts the invariant (add a `// pinned: <TestName>` breadcrumb next to the
  comment so the pair is discoverable), or the comment is ordinary explanation. Add the
  pairing when you touch such a comment; no bulk retrofit.
- New `public` API in post-split SPM targets carries `///` doc comments; existing
  pre-split API is retrofitted opportunistically, not in bulk.
- No `TODO`/`FIXME` in code — deferred work gets a Linear ticket or a plan entry.

## Test conventions

- `<Type>Tests.swift` = executable unit tests against `LavaSecCore`. `<Feature>SourceTests.swift`
  = text pins on out-of-target source via `readSource`/`sourceBlock`
  (`Tests/LavaSecCoreTests/SourceIntrospectionSupport.swift` is the file registry).
- Pins are for cross-process wiring the compiler can't see (pbxproj membership, workflow
  files, provider/app wiring). NEW logic goes where it can get executable tests —
  a `LavaSecCore` type — with the provider/app keeping thin orchestration.
- Moving or renaming pinned code is fine but budget for it: update the `SourceFile`
  registry path and the affected pins in the same PR (`SourceFileRegistryTests` reports
  stale registry paths as one failure). Prefer anchoring `sourceBlock` on `// MARK:`
  headers or function signatures, not on arbitrary code text.
- Policy logic (pure value types in `Sources/LavaSecCore/*Policy*.swift`) always gets
  real behavioral tests, never pins.

## Concurrency & safety rails

- Swift 6 strict concurrency; app models are `@MainActor`.
- Tunnel DNS state is `dnsStateQueue`-confined with a specific-key re-entrancy pattern —
  see `INV-QUEUE-1` before touching provider state or extracting helpers.
- Filtering never fails open (`INV-DNS-1`); the NE process lives under a ~50 MB jetsam
  ceiling (`INV-MEM-1`) — don't add resident copies or parallel compiles in the tunnel.

## Verification expectations

- `swift test --package-path . -Xswiftc -warnings-as-errors` runs the core suite (CI runs
  it on macOS; the full app
  compile runs in a separate CI lane — a green `swift test` alone does not prove the app
  target builds).
- PR descriptions list the exact commands run, RED/GREEN for new tests where applicable,
  and honestly state anything not run locally.
- Commit only what you verified; report failures as failures.
