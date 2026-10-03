#!/usr/bin/env python3
"""Execute the actual active-import method across controlled publication boundaries.

The persistence double models the production config/library write before the artifact
await, including its generation CAS. This covers import orchestration, not actual
filesystem atomicity, artifact compilation, tunnel adoption or SwiftUI rendering.
Use --baseline-ref REF for a reproducible RED run against an explicit old source.
"""
from pathlib import Path
import argparse
import os
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = 'LavaSecApp/AppViewModel/AppViewModel+ShareableFilters.swift'
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--baseline-ref')
parser.add_argument('--output-dir')
args = parser.parse_args()
source = (subprocess.check_output(['git', 'show', f'{args.baseline_ref}:{SOURCE}'], cwd=ROOT, text=True)
          if args.baseline_ref else (ROOT / SOURCE).read_text())
start = source.index('    func applyImportedShareableConfiguration(')
cursor = source.index('{', start) + 1
depth = 1
while depth:
    if source[cursor] == '{':
        depth += 1
    elif source[cursor] == '}':
        depth -= 1
    cursor += 1
method = source[start:cursor]

# Keep the double's suspension point tied to actual production ordering.
persistence = (ROOT / 'LavaSecApp/AppViewModel/AppViewModel+Persistence.swift').read_text()
assert persistence.index('SharedFilterStatePersistence.writeConfigurationAndLibrary(') < persistence.index('publishOutcome = try await persistPreparedSnapshotArtifacts(')

prefix = r'''
import Foundation
enum Failure: Error { case prepare, artifact, rollback }
enum SharedFilterStatePersistence {
    struct StaleBaseGenerationError: Error {}
}
enum Outcome { case published, abortedSuperseded, abortedContended, abortedCancelled }
enum ShareableFilterImportResult {
    case success(ruleCount: Int), failure(message: String)
    var count: Int? { if case .success(let count) = self { return count }; return nil }
    var message: String? { if case .failure(let message) = self { return message }; return nil }
}
struct Filter: Equatable { var id: String; var value: Int; func strippingLocalCacheState() -> Self { self } }
struct ShareableFilterConfiguration: Equatable {
    var value: Int
    var isEmpty: Bool { value == 0 }
    init(value: Int) { self.value = value }
    init(filter: Filter) { value = filter.value }
}
struct Configuration: Equatable {
    var value = 1
    var configurationGeneration = 0
    func applyingImportedShareableConfiguration(_ applied: ShareableFilterConfiguration) -> Self {
        var next = self; next.value = applied.value; return next
    }
}
struct Library {
    var activeFilterID = "A"
    var filters = ["A": Filter(id: "A", value: 1), "B": Filter(id: "B", value: 99)]
    var activeFilter: Filter { filters[activeFilterID]! }
}
struct Summary { var blockedDomainRuleCount: Int }
struct PreparedFilterSnapshot { var summary: Summary }
struct CustomResult { var sourceHashes: [String: String] = [:] }
struct Prepared { var snapshot: PreparedFilterSnapshot; var customResult = CustomResult(); var catalogResult: Int }
struct Plan { var applied: ShareableFilterConfiguration }
enum Activity { case changeFilters }
extension String { func lavaLocalizedFormat(_ args: CVarArg...) -> String { String(format: self, arguments: args) } }
@MainActor final class Gate {
    private var continuation: CheckedContinuation<Void, Never>?
    var waiting: Bool { continuation != nil }
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}
@MainActor final class ReplacementGate {
    var token = 0
    func begin() -> Int { token += 1; return token }
    func isCurrent(_ value: Int) -> Bool { token == value }
}
@MainActor final class Backup {
    var schedules = 0
    func scheduleAutomaticBackupAfterConfigurationChange() { schedules += 1 }
}
@MainActor final class Subject {
    var configuration = Configuration()
    var library = Library()
    var diskConfiguration = Configuration()
    var diskLibrary = Library()
    var diskPointer = "A"
    var activeFilterDraft: Int? = 5
    var protectedRuleCount = 1
    var catalogStatusMessage = "Original status"
    var catalogStatusIsError = false
    let configurationReplacementGate = ReplacementGate()
    let backup = Backup()
    var prepareGate: Gate?
    var artifactGate: Gate?
    var notifyGate: Gate?
    var restoreGate: Gate?
    var failPreparation = false
    var failArtifact = false
    var failRollback = false
    var outcome = Outcome.published
    var prepareCalls = 0
    var persistCalls = 0
    var writtenPairs = 0
    var catalogApplies = 0
    var activities = 0
    var notifications = 0
    var restores = 0
    func importPlan(for value: ShareableFilterConfiguration) -> Plan { Plan(applied: value) }
    func preparedSnapshotForCurrentConfiguration() -> PreparedFilterSnapshot {
        PreparedFilterSnapshot(summary: Summary(blockedDomainRuleCount: configuration.value))
    }
    func makeProtectionRestoreRequest() -> Int { 1 }
    func prepareFilterSnapshot(for next: Configuration) async throws -> Prepared {
        prepareCalls += 1
        await prepareGate?.wait()
        if failPreparation { throw Failure.prepare }
        return Prepared(snapshot: PreparedFilterSnapshot(summary: Summary(blockedDomainRuleCount: next.value)), catalogResult: next.value)
    }
    func updateCustomBlocklistHashes(_ hashes: [String: String]) {}
    func persistSharedState(preparedSnapshot: PreparedFilterSnapshot, schedulesAutomaticBackup: Bool,
                            expectedConfigurationGeneration: Int) async throws -> Outcome {
        persistCalls += 1
        // The production funnel synchronizes its active library entry before calling
        // the writer. A refused write must unwind this in-memory mutation too.
        library.filters[library.activeFilterID]!.value = configuration.value
        guard diskConfiguration.configurationGeneration == expectedConfigurationGeneration else {
            throw SharedFilterStatePersistence.StaleBaseGenerationError()
        }
        if persistCalls > 1 && failRollback { throw Failure.rollback }
        configuration.configurationGeneration += 1
        diskConfiguration = configuration
        diskLibrary = library
        writtenPairs += 1
        if persistCalls == 1 {
            await artifactGate?.wait()
            if failArtifact { throw Failure.artifact }
            if outcome == .published { diskPointer = diskLibrary.activeFilterID }
            return outcome
        }
        diskPointer = diskLibrary.activeFilterID
        return .published
    }
    // A later switch keeps every saved filter, including the imported contents of A.
    func switchToB(adoptIntoApp: Bool) {
        diskLibrary.activeFilterID = "B"
        diskConfiguration.value = diskLibrary.activeFilter.value
        diskConfiguration.configurationGeneration += 1
        diskPointer = "B"
        if adoptIntoApp {
            _ = configurationReplacementGate.begin()
            configuration = diskConfiguration
            library = diskLibrary
            protectedRuleCount = 99
            catalogStatusMessage = "B status"
            catalogStatusIsError = true
        }
    }
    func applyCatalogSyncResult(_ value: Int) { catalogApplies += 1; protectedRuleCount = value }
    func appendAppNetworkActivity(_ activity: Activity) { activities += 1 }
    func notifyTunnelSnapshotUpdated() async { notifications += 1; await notifyGate?.wait() }
    func restoreProtectionIfNeeded(_ value: Int) async { restores += 1; await restoreGate?.wait() }
    static func filterPreparationFailureMessage(for error: Error) -> String { "Preparation or publication failed" }
'''

tests = r'''
}
@MainActor var checks = 0
@MainActor var failures = 0
@MainActor func expect(_ condition: @autoclosure () -> Bool, _ description: String) {
    checks += 1
    if !condition() { failures += 1; print("FAIL: \(description)") }
}
@MainActor func wait(_ gate: Gate) async {
    for _ in 0..<10_000 { if gate.waiting { return }; await Task.yield() }
    fatalError("Controlled production await was not reached")
}
@main struct Main {
    @MainActor static func main() async {
        let imported = ShareableFilterConfiguration(value: 7)
        // 1. Ordinary publication still runs its successful tail exactly once.
        do {
            let s = Subject(); let result = await s.applyImportedShareableConfiguration(imported)
            expect(result.count == 7, "normal publication returns imported count")
            expect(s.writtenPairs == 1 && s.diskLibrary.filters["A"]!.value == 7, "normal publication saves once")
            expect(s.catalogApplies == 1 && s.backup.schedules == 1 && s.notifications == 1 && s.restores == 1, "normal successful tail remains intact")
        }
        // 2. Focus writes B only after loading the already-imported saved library.
        do {
            let s = Subject(); let gate = Gate(); s.artifactGate = gate; s.outcome = .abortedSuperseded
            let task = Task { await s.applyImportedShareableConfiguration(imported) }
            await wait(gate)
            expect(s.diskLibrary.filters["A"]!.value == 7, "import pair is durable before artifact await")
            s.switchToB(adoptIntoApp: false); gate.release(); let result = await task.value
            expect(result.count == 7, "superseded flip reports committed import success")
            expect(s.diskLibrary.filters["A"]!.value == 7 && s.diskLibrary.activeFilterID == "B" && s.diskPointer == "B", "superseded flip preserves imported inactive A and newer B")
            expect(s.persistCalls == 1 && s.catalogApplies == 0 && s.backup.schedules == 0 && s.notifications == 0 && s.restores == 0, "superseded flip never retries or runs stale active tail")
        }
        // 3. In-process adoption after the write also cannot turn success into retry.
        do {
            let s = Subject(); let gate = Gate(); s.artifactGate = gate
            let task = Task { await s.applyImportedShareableConfiguration(imported) }
            await wait(gate); s.switchToB(adoptIntoApp: true); gate.release(); let result = await task.value
            expect(result.count == 7, "post-write gate loss returns captured import count, not B count")
            expect(s.configuration.value == 99 && s.catalogStatusMessage == "B status" && s.catalogStatusIsError, "post-write gate loss preserves newer app state")
            expect(s.catalogApplies == 0 && s.backup.schedules == 0 && s.notifications == 0 && s.restores == 0 && s.persistCalls == 1, "post-write gate loss skips all stale tail effects")
        }
        // 4. A replacement before the write still rejects the obsolete import.
        do {
            let s = Subject(); let gate = Gate(); s.prepareGate = gate
            let task = Task { await s.applyImportedShareableConfiguration(imported) }
            await wait(gate); s.switchToB(adoptIntoApp: true); gate.release(); let result = await task.value
            expect(result.message != nil && s.persistCalls == 0, "pre-write supersession stays a failure without persistence")
            expect(s.diskLibrary.filters["A"]!.value == 1 && s.diskPointer == "B", "pre-write supersession preserves original A and newer B")
        }
        // 5. External CAS rejection never becomes a successful import or clobbers B.
        do {
            let s = Subject(); s.switchToB(adoptIntoApp: false)
            let result = await s.applyImportedShareableConfiguration(imported)
            expect(result.message != nil && s.writtenPairs == 0, "pre-write generation rejection remains failure")
            expect(s.diskLibrary.filters["A"]!.value == 1 && s.diskLibrary.activeFilterID == "B" && s.diskPointer == "B", "CAS rejection and fenced rollback cannot overwrite B")
            expect(s.configuration.value == 1 && s.library.filters["A"]!.value == 1 && s.library.activeFilterID == "A", "CAS rejection restores the pre-import foreground configuration and library")
            expect(s.activeFilterDraft == 5, "CAS rejection restores the pre-import active draft")
            expect(s.persistCalls == 1, "CAS rejection does not attempt an unauthorized rollback write")
        }
        // 6. A genuine artifact error still restores the reviewed old content.
        do {
            let s = Subject(); s.failArtifact = true
            let result = await s.applyImportedShareableConfiguration(imported)
            expect(result.message != nil && s.persistCalls == 2 && s.writtenPairs == 2, "artifact error still performs one rollback")
            expect(s.diskLibrary.filters["A"]!.value == 1 && s.activeFilterDraft == 5, "successful rollback restores old content and draft")
            expect(s.catalogApplies == 0 && s.backup.schedules == 0 && s.notifications == 0 && s.restores == 0, "failed publication does not run success tail")
        }
        // 7. Failed rollback remains explicit; it never claims restoration or success.
        do {
            let s = Subject(); s.failArtifact = true; s.failRollback = true
            let result = await s.applyImportedShareableConfiguration(imported)
            expect(result.message == "The import could not be saved or restored. Review the current filter before trying again.", "rollback failure retains actionable truthful error")
            expect(s.writtenPairs == 1 && s.diskLibrary.filters["A"]!.value == 7, "rollback failure preserves actual stored state")
        }
        // 8. An external winner during a throwing artifact attempt defeats rollback CAS.
        do {
            let s = Subject(); let gate = Gate(); s.artifactGate = gate; s.failArtifact = true
            let task = Task { await s.applyImportedShareableConfiguration(imported) }
            await wait(gate); s.switchToB(adoptIntoApp: false); gate.release(); let result = await task.value
            expect(result.message != nil && s.writtenPairs == 1, "newer generation fences failed-publication rollback")
            expect(s.diskLibrary.filters["A"]!.value == 7 && s.diskPointer == "B" && s.diskLibrary.activeFilterID == "B", "throw and rollback never overwrite newer B")
        }
        // 9. A newer owner during notification must not run old restore/status effects.
        do {
            let s = Subject(); let gate = Gate(); s.notifyGate = gate
            let task = Task { await s.applyImportedShareableConfiguration(imported) }
            await wait(gate); s.switchToB(adoptIntoApp: true); gate.release(); let result = await task.value
            expect(result.count == 7 && s.restores == 0, "notification suspension preserves committed result and skips old restore")
            expect(s.catalogStatusMessage == "B status" && s.catalogStatusIsError, "notification suspension preserves newer status")
        }
        // 10. Restore has its own suspension; no later import status may overwrite B.
        do {
            let s = Subject(); let gate = Gate(); s.restoreGate = gate
            let task = Task { await s.applyImportedShareableConfiguration(imported) }
            await wait(gate); s.switchToB(adoptIntoApp: true); gate.release(); let result = await task.value
            expect(result.count == 7 && s.restores == 1, "restore suspension keeps the captured committed count")
            expect(s.catalogStatusMessage == "B status" && s.catalogStatusIsError, "restore suspension preserves newer status")
        }
        // 11. Preparation errors still have no persistence side effects.
        do {
            let s = Subject(); s.failPreparation = true
            let result = await s.applyImportedShareableConfiguration(imported)
            expect(result.message != nil && s.writtenPairs == 0 && s.persistCalls == 0, "preparation failure remains non-mutating")
        }
        print("\(failures == 0 ? "PASS" : "FAIL"): 11 production import-publication scenarios, \(checks) assertions, \(failures) failures")
        if failures != 0 { exit(1) }
    }
}
'''

output = Path(args.output_dir) if args.output_dir else Path(tempfile.mkdtemp(prefix='lava-import-publication-', dir='/private/tmp'))
output.mkdir(parents=True, exist_ok=True)
swift = output / 'ImportPublication.swift'
swift.write_text(prefix + method + tests)
cache = output / 'cache'
cache.mkdir(exist_ok=True)
environment = dict(os.environ, CLANG_MODULE_CACHE_PATH=str(cache), SWIFT_MODULECACHE_PATH=str(cache))
binary = output / 'ImportPublicationTests'
subprocess.run(['swiftc', '-parse-as-library', '-swift-version', '6', '-warnings-as-errors',
                '-module-cache-path', str(cache), str(swift), '-o', str(binary)], check=True, env=environment)
print(f'Production source: {args.baseline_ref or "working tree"}; harness: {swift}', flush=True)
raise SystemExit(subprocess.run([str(binary)]).returncode)
