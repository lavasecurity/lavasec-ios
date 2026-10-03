# iOS Package Module Boundaries

This is the dependency contract for the package end state. Product names in the matrix
are shortened for readability: `Kit` means `LavaSecKit`, and the other names receive the
same `LavaSec` prefix. A consumer may link only the products listed for it.

## Consumer matrix

| Consumer | Allowed products |
|---|---|
| LavaSec app | Kit, Networking, DNS, FilterPipeline, Presentation, AppServices |
| LavaSecTunnel | Kit, Networking, DNS, FilterPipeline, ChainedUpstream |
| LavaSecWidget | Kit, Presentation |
| LavaSecIntents | Kit, FilterPipeline |
| LavaSecCore façade | all products **except ChainedUpstream**, compatibility only |

`LavaSecChainedUpstream` (the WireGuard upstream engine wrapper) is linked by exactly one
consumer, `LavaSecTunnel`, as of Phase 3's first provider-importing PR. Verified rather
than assumed: a Release build of the extension carries all seven `lava_wg_*` entry points
as defined symbols in `__TEXT`, so dead-code stripping does not remove it and the BSD-3
attribution is owed to users, not just to the repository.

It stays deliberately outside the façade — a compatibility product must not pull a crypto
archive into callers that never asked for one — and no other consumer may take it without
the same least-privilege review.

`LavaSecCore` may re-export every layer so existing callers continue to compile, but it
is a compatibility façade only. New code imports the narrowest product it needs instead
of expanding use of the façade.

## Layer dependency direction

- `LavaSecKit` imports no LavaSec layer.
- `LavaSecNetworking` depends only on `LavaSecKit`.
- `LavaSecDNS` depends only on `LavaSecKit`.
- `LavaSecFilterPipeline` depends on `LavaSecKit` and `LavaSecNetworking`.
- `LavaSecPresentation` depends only on `LavaSecKit`.
- `LavaSecAppServices` depends on `LavaSecKit` and `LavaSecFilterPipeline`.
- No layer imports `LavaSecAppServices` from below.
- `LavaSecChainedUpstream` depends on `LavaSecKit` and the `LavaSecWGCore` binary target
  (the committed WireGuard engine xcframework). **Nothing engine-ward depends on it** —
  no layer, and not the façade. `LavaSecWGCore` is the package's only binary target; the
  boundary guard whitelists it by exact shape, and its bytes are proven to equal a
  from-source rebuild by `scripts/check-wireguard-core-drift.sh`.

These rules apply to target dependencies, direct imports, and re-exported imports. Put
shared APIs in the lowest layer that owns their semantics; do not route a forbidden
dependency through `Shared/` or the compatibility façade.


## Non-production React Native review workspace

`ReactNative/ios/project.json` defines `LavaSecUIReview` (application) and
`LavaSecUIReviewUITests` (UI test bundle), classified explicitly by
`ModuleBoundarySourceTests`. The app links LavaSecAppServices for native appearance, LavaSecKit for domain
normalization, and LavaSecPresentation for the shared guardian drawing from the
existing root package. Its UI test links the review app. React Native and its pinned CocoaPods
build/codegen machinery are confined to this separate generated workspace. Production
project target/package/script policies remain unchanged. The closed manifest and
generated dependency/script provenance checks live in
`ReactNative/scripts/review-host-policy.mjs`; see `ReactNative/ios/README.md` for the
build recipe and current evidence.
