import Foundation

/// Protection-class policy for the shared App Group files (INV-PERSIST-2).
///
/// iOS stamps app-group files Class C (`NSFileProtectionCompleteUntilFirstUserAuthentication`)
/// by default, so a Connect-On-Demand tunnel start between reboot and first unlock cannot read
/// them: the boot tunnel then serves fail-closed (INV-DNS-1) until the user first unlocks —
/// a block-all outage for exactly the user who wants filtering up with the device (the
/// 2026-07-14 incident's phase-2 fix; lavasec-infra
/// `plans/2026-07-14-reboot-first-unlock-data-reset-incident-plan.md`).
///
/// The deliberate trade (INV-PERSIST-2, registry entry in `docs/invariants.md`): the
/// CONTROL-PLANE files — the config/library pair, tunnel health, and the compiled filter
/// artifacts — hold filter selections and custom rules, never browsing history, so they carry
/// `NSFileProtectionNone` and stay readable pre-unlock. The PRIVACY stores // mobsf-ignore: ios_file_no_special
/// (`dns-events.sqlite`, `diagnostics.json`, `network-activity-log.json`,
/// `incident-ledger.json`, `vpn-debug-log.jsonl`, the `catalog-cache` downloads) deliberately
/// stay at the iOS default Class C — they record user activity and nothing at boot needs
/// them. Every control-plane writer funnels its options/attributes through this ONE type so
/// the class assignment cannot drift per call site.
/// - pinned: ControlPlaneProtectionSourceTests.testSharedPairWriterStampsControlPlaneWritingOptions
///
/// `Data.WritingOptions.noFileProtection` and `FileAttributeKey.protectionKey` are // mobsf-ignore: ios_file_no_special
/// iOS-family-only API — NOT available on macOS, where CI compiles and runs `swift test` —
/// so every member is `#if os(iOS)`-guarded (`canImport(Darwin)` would be wrong: it is true
/// on macOS) and degrades to the plain atomic/no-attribute behavior off-iOS.
/// - pinned: SharedStateFileProtectionTests.testNonIOSPlatformsKeepPlainAtomicWritesAndReportProtectionApplied
public enum SharedStateFileProtection {
    /// Writing options for atomic control-plane file writes: `[.atomic, .noFileProtection]` // mobsf-ignore: ios_file_no_special
    /// on iOS so the replacement file lands Class-None (readable by a pre-unlock boot
    /// tunnel), `[.atomic]` elsewhere. `.atomic` is load-bearing for every caller (torn-write
    /// safety across three processes); only the protection class varies by platform.
    public static var atomicControlPlaneWritingOptions: Data.WritingOptions {
        #if os(iOS)
        return [.atomic, .noFileProtection] // mobsf-ignore: ios_file_no_special
        #else
        return [.atomic]
        #endif
    }

    /// File-creation attributes stamping a new control-plane file Class-None at birth
    /// (`FileManager.createFile(atPath:contents:attributes:)`), so a later same-volume
    /// rename/promotion inherits the readable class instead of the directory default.
    /// `nil` off-iOS — the protection attribute key does not exist there.
    public static var controlPlaneCreationAttributes: [FileAttributeKey: Any]? {
        #if os(iOS)
        return [.protectionKey: FileProtectionType.none]
        #else
        return nil
        #endif
    }

    /// Best-effort re-stamp of an EXISTING file to `NSFileProtectionNone`, VERIFIED. // mobsf-ignore: ios_file_no_special
    ///
    /// Used after promotions that can preserve the destination's old class
    /// (`FileManager.replaceItemAt` keeps destination metadata) and by the one-shot
    /// migration over files written before INV-PERSIST-2. Re-reads the applied class after the
    /// `setAttributes` and returns `false` unless it is confirmed Class-None — so a
    /// `setAttributes` that returns without throwing yet does NOT actually downgrade the class
    /// cannot report success and let the migration latch a still-locked control-plane file
    /// (silently reopening the incident window). Returning `false` (on a throw, a wrong class,
    /// or an unreadable attribute) lets the migration retry on the next app foreground instead
    /// of latching a partial result; always `true` off-iOS, where there is no protection class
    /// to change.
    /// - pinned: ControlPlaneProtectionSourceTests.testApplyControlPlaneProtectionVerifiesTheAppliedClass
    ///
    /// - Parameters:
    ///   - url: The existing file (or directory) to re-stamp.
    ///   - fileManager: Injectable for tests; defaults to `.default`.
    /// - Returns: Whether the file is now VERIFIED Class-None (or off-iOS, vacuously true).
    @discardableResult
    public static func applyControlPlaneProtection(
        at url: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        #if os(iOS)
        do {
            try fileManager.setAttributes(
                [.protectionKey: FileProtectionType.none],
                ofItemAtPath: url.path
            )
        } catch {
            return false
        }
        // VERIFY the class actually landed before a caller can latch this success: a
        // setAttributes that returns WITHOUT throwing but leaves the file Class C would
        // otherwise let the one-shot migration latch a still-locked control-plane file,
        // silently reopening the reboot-before-first-unlock window this whole change closes
        // (INV-PERSIST-2; lavasec-infra
        // `plans/2026-07-14-reboot-first-unlock-data-reset-incident-plan.md`). Re-read the
        // applied class and require Class-None (`FileProtectionType.none`): any other class —
        // or an unreadable attribute — is a failed apply the migration must RETRY (return
        // false), never latch.
        guard
            let applied = (try? fileManager.attributesOfItem(atPath: url.path))?[.protectionKey] as? FileProtectionType,
            applied == FileProtectionType.none
        else {
            return false
        }
        return true
        #else
        return true
        #endif
    }
}
