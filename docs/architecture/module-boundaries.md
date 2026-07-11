# iOS Package Module Boundaries

This is the dependency contract for the package end state. Product names in the matrix
are shortened for readability: `Kit` means `LavaSecKit`, and the other names receive the
same `LavaSec` prefix. A consumer may link only the products listed for it.

## Consumer matrix

| Consumer | Allowed products |
|---|---|
| LavaSec app | Kit, Networking, DNS, FilterPipeline, Presentation, AppServices |
| LavaSecTunnel | Kit, Networking, DNS, FilterPipeline |
| LavaSecWidget | Kit, Presentation |
| LavaSecIntents | Kit, FilterPipeline |
| LavaSecCore façade | all products, compatibility only |

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

These rules apply to target dependencies, direct imports, and re-exported imports. Put
shared APIs in the lowest layer that owns their semantics; do not route a forbidden
dependency through `Shared/` or the compatibility façade.
