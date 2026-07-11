# iOS Feature Slice Checklist

Complete a feature slice in this order. Keep each box in the change description so the
reviewer can distinguish compiler-checked behavior from wiring that still needs a source
pin.

1. [ ] **Place pure behavior in the narrowest package target.** Put models, policies, and
   service logic in the lowest layer allowed by the
   [module-boundary contract](module-boundaries.md).
2. [ ] **Prove behavior with executable RED/GREEN tests.** Add an executable unit test,
   run it and confirm the expected failure, implement the minimum behavior, then run it
   green. Do not use a source pin for logic that can execute in a package test.
3. [ ] **Keep the controller app-only and inject platform/service ports.** Put UI and
   lifecycle orchestration in `LavaSecApp/`; express each platform or service dependency
   as a narrow injected protocol rather than reaching through global state.
4. [ ] **Add a narrow `*HubBridging` contract only for shared hub state.** Do this only
   when the feature must read or mutate state owned by the shared app hub; expose only
   the operations the slice needs.
5. [ ] **Assemble the environment.** Bind concrete platform services, controller, and any
   hub bridge at the app composition root. Each extension owns its separate assembly.
6. [ ] **Declare explicit `project.yml` membership.** List every app, shared, or extension
   source under the targets that compile it, regenerate the Xcode project, and check
   generated-project drift. Classify every new native target in the exact production
   consumer or non-production exemption matrix in `ModuleBoundarySourceTests`. Keep the
   manifest directly auditable: XcodeGen includes, target templates, YAML merges, and
   merge modifiers are intentionally rejected, as are generator-time file writes, legacy or
   aggregate targets, build scripts/plugins/rules, and executable scheme actions.
   `LavaSecPackage` remains the sole local package at the repository root; its reserved
   products cannot be linked through aliases. The drift check independently verifies the raw
   generated target/source/package/dependency/copy-phase graph, package requirements, and
   shared-scheme build/test identities. In-place generation snapshots existing working-tree
   files (including ignored local config) for verified restoration, and post-generation
   fixups may change only the documented localization regions and Icon Composer file types.
7. [ ] **Register `SourceFile` only for unavoidable pins.** Add a registry entry and a
   focused `*SourceTests.swift` assertion only when cross-process or generated-project
   wiring cannot be checked by the compiler.
8. [ ] **Localize user-visible text.** Add keys and translations to the catalog owned by
   the process or package that emits the text, then run the localization check.
9. [ ] **Compile the app.** Build the affected app/extension graph; a green package test
   alone does not prove Xcode target membership or platform API usage.
10. [ ] **Remove superseded source pins.** Delete source assertions and `SourceFile`
    registry entries once executable coverage or compiler-checked wiring replaces them.
