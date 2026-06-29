import AppIntents
import ExtensionFoundation

// MARK: - App Intents Extension principal (LAV-100 Phase 4)
//
// `SetFocusFilterIntent` runs its `perform()` in the APP process only while the app is running (WWDC22
// §10121). To switch the active filter hands-free when Lava is CLOSED, the intent must live in an App
// Intents extension that the system spins up in the background. This extension hosts `LavaFocusFilterIntent`
// (in FocusFilterIntent.swift); its `perform()` drives the shared LavaSecCore headless switch engine via
// `FocusSwitchEnvironment.performSwitch`, then signals the always-on tunnel to reload (P4d).
//
// ExtensionKit packaging (NOT the older NSExtension): `@main AppIntentsExtension` + Info.plist
// `EXAppExtensionAttributes` → `EXExtensionPointIdentifier = com.apple.appintents-extension`.
@main
struct LavaSecIntentsExtension: AppIntentsExtension {}
