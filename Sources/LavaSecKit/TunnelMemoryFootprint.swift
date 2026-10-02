import Foundation

// QA-ONLY, like every other instrumentation surface here: the emission in
// `EnergyCounters` is `#if DEBUG || LAVA_QA_TOOLS` and so is this. Ungated, the type
// still shipped as inert public API in the App Store binary — nothing ran and nothing was
// user-facing, but "instrumentation stays strictly in QA" means the CODE too, not just its
// call sites (founder, PR #578).
#if DEBUG || LAVA_QA_TOOLS

/// A reading of the tunnel process's physical memory footprint — the figure jetsam judges.
///
/// ## Why this exists
///
/// A jetsam kill terminates the process, so nothing can be written at the moment it happens: any
/// evidence has to already be in the log. Chimmy's 8,662-line field log from 2026-08-24 recorded
/// two starts refusing to chain with `device-startup-crash-loop` and NOT ONE byte of memory data —
/// no key in the whole file matched footprint, rss, or memory — so the exclusion was visible and
/// its cause was not. This is the sample that makes the next one diagnosable.
///
/// ``peakBytes`` is the important half. The kill lands BETWEEN periodic samples by definition, so
/// an instantaneous reading taken every 60 s will almost always miss the spike that caused it. The
/// kernel tracks the high-water mark itself (`ledger_phys_footprint_peak`), which is why this is
/// read from the ledger rather than sampled in a loop — a loop would be both less accurate and a
/// cost paid on the DNS-serving path, which `INV-MEM-1` exists to keep clear.
public struct TunnelMemoryFootprint: Equatable, Sendable {
    /// Physical footprint right now, in bytes — `phys_footprint`, the ledger jetsam reads.
    public let bytes: UInt64
    /// The high-water mark the kernel has recorded for this process, when it is available.
    ///
    /// `nil` on a kernel whose `task_vm_info` predates the peak field. Distinguished from zero
    /// deliberately: absent and never-grew are different facts, and a reader diagnosing a kill
    /// needs to know which it is looking at.
    public let peakBytes: UInt64?

    public init(bytes: UInt64, peakBytes: UInt64? = nil) {
        self.bytes = bytes
        self.peakBytes = peakBytes
    }

    /// The ceiling `INV-MEM-1` bounds the network-extension process at, in bytes.
    ///
    /// ~50 MB is the figure the invariant and the chained-upstream types are written against
    /// (`ChainedUpstreamChannelParameters`, `ChainedDroppedFragmentTable`, `ChainedAllowedIPs`).
    /// It is a REFERENCE POINT for reporting, not an enforcement threshold — nothing here refuses
    /// anything, and the real limit iOS applies is neither published nor constant.
    public static let referenceCeilingBytes: UInt64 = 50 * 1024 * 1024

    /// Footprint in whole megabytes, which is the resolution a log line wants.
    public var megabytes: Int { Int(bytes / (1024 * 1024)) }

    /// Peak footprint in whole megabytes, or `nil` when the kernel did not report a peak.
    public var peakMegabytes: Int? { peakBytes.map { Int($0 / (1024 * 1024)) } }

    /// Peak (falling back to current) as a percentage of ``referenceCeilingBytes``.
    ///
    /// Reported from the PEAK because that is the number that gets a process killed; the current
    /// reading at flush time can sit comfortably low moments after a spike that nearly ended it.
    /// Uncapped on purpose — a value over 100 is exactly the observation worth having, and
    /// clamping it would erase the evidence this type was added to capture.
    public var percentOfReferenceCeiling: Int {
        let measured = peakBytes ?? bytes
        return Int((measured * 100) / Self.referenceCeilingBytes)
    }
}

#endif
