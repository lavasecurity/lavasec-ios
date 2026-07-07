// LavaSecCore is a pure façade (Phase B4 endpoint): it re-exports the split targets so
// every existing `import LavaSecCore` — app, tunnel, widget, intents, tests — keeps
// seeing the full pre-split API surface. New code imports the specific layer it needs:
// LavaSecKit / LavaSecDNS / LavaSecFilterPipeline / LavaSecAppServices.
@_exported import LavaSecKit
@_exported import LavaSecDNS
@_exported import LavaSecFilterPipeline
@_exported import LavaSecAppServices
