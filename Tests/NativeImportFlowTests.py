#!/usr/bin/env python3
"""Compile and execute the current native import stage machine with model doubles.

The harness extracts production navigation and commit methods from
ShareableFiltersUI.swift. It checks consent, stale-target recovery, completion,
and the single-commit boundary without requiring SwiftUI or a simulator.
Run: python3 Tests/NativeImportFlowTests.py
"""
from pathlib import Path
import argparse
import os
import subprocess

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'LavaSecApp/ShareableFiltersUI.swift'


def block(source, marker):
    start = source.index(marker)
    opening = source.index('{', start)
    depth = 1
    end = opening + 1
    while depth:
        if source[end] == '{':
            depth += 1
        elif source[end] == '}':
            depth -= 1
        end += 1
    return source[start:end]


def generate():
    source = SOURCE.read_text()
    assert 'NavigationStack {\n            ZStack {' in source
    assert '@State private var stage: Stage' in source
    assert 'NavigationStack(path: $path)' not in source
    stage = block(source, '    enum Stage: Equatable')
    pending = block(source, 'private struct PendingActiveReplacement:').replace('private struct ', 'struct ', 1)
    methods = '\n'.join(block(source, marker).replace('private func ', 'func ', 1) for marker in [
        'private func finishImport()', 'private func go(to ', 'private func goBackFromMethod()',
        'private func addNew(', 'private func replace('])
    return PREFIX + pending + WRAPPER + stage + '\n' + methods + '\n}\n' + TESTS


PREFIX = r'''
import Foundation
struct ShareableFilterConfiguration: Equatable { var value: Int }
struct Filter: Equatable {
    var id: String
    var name: String
    func strippingLocalCacheState() -> Self { self }
}
enum ImportFiltersStartMode { case chooseMethod, enterCode, scanCode, review(ShareableFilterConfiguration) }
struct ImportPlan { let applied: ShareableFilterConfiguration; func droppedCount(of kind: DroppedKind) -> Int { 2 } }
enum DroppedKind { case unavailableBlocklist }
enum ShareableFilterImportResult { case success(ruleCount: Int), failure(message: String) }
enum LavaFlowDirection { case forward, backward }
enum LavaFlowTransition { static func animation(reduceMotion: Bool) -> Int { 0 } }
func withAnimation(_ animation: Int, _ action: () -> Void) { action() }
struct Library {
    var activeFilterID = "active"
    var filters = [Filter(id: "active", name: "Core"), Filter(id: "target", name: "Target")]
    func filter(id: String) -> Filter? { filters.first { $0.id == id } }
}
@MainActor final class Completion {
    var filterName: String?
    private var acknowledged = false
    var unavailableListCount = 0
    func recordCommittedFilter(named name: String, unavailableListCount: Int = 0) { if filterName == nil { self.unavailableListCount = unavailableListCount; filterName = name } }
    func acknowledge() -> Bool {
        guard filterName != nil, !acknowledged else { return false }
        acknowledged = true
        return true
    }
}
@MainActor final class Model {
    var library = Library()
    var plan = ShareableFilterConfiguration(value: 1)
    var additions = 0
    var replacements = 0
    var failAdd = false
    var failReplace = false
    func importPlan(for configuration: ShareableFilterConfiguration) -> ImportPlan { ImportPlan(applied: plan) }
    func addImportedShareableConfigurationAsNewFilter(_ configuration: ShareableFilterConfiguration) -> String? {
        additions += 1
        guard !failAdd else { return nil }
        library.filters.append(Filter(id: "new", name: "Shared filter"))
        return "new"
    }
    func replaceFilterWithImportedShareableConfiguration(id: String, _ configuration: ShareableFilterConfiguration,
                                                          confirmedActiveReplacement: Bool) async -> ShareableFilterImportResult {
        replacements += 1
        return failReplace ? .failure(message: "Write failed") : .success(ruleCount: 1)
    }
}
'''
WRAPPER = r'''
@MainActor final class Flow {
    let viewModel = Model()
    let completion = Completion()
    var startMode: ImportFiltersStartMode = .chooseMethod
    var stage = Stage.chooseMethod
    var navDirection: LavaFlowDirection = .forward
    var reduceMotion = false
    var applyError: String?
    var pendingActiveReplacement: PendingActiveReplacement?
    var onRootBack: (() -> Void)?
    var onImported: (() -> Void)?
    var dismissCount = 0
    var authorizeImport: () async -> Bool = { true }
    func dismiss() { dismissCount += 1 }
'''
TESTS = r'''
@MainActor var checks = 0
@MainActor func expect(_ value: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    precondition(value(), message)
}
@MainActor func settled(_ flow: Flow) async {
    for _ in 0..<10_000 {
        if flow.stage.transitionID != "applying" { return }
        await Task.yield()
    }
    preconditionFailure("Import task did not settle")
}
@MainActor final class Auth {
    var continuation: CheckedContinuation<Bool, Never>?
    func call() async -> Bool { await withCheckedContinuation { continuation = $0 } }
    func ready() async {
        for _ in 0..<10_000 {
            if continuation != nil { return }
            await Task.yield()
        }
        preconditionFailure("Authentication did not begin")
    }
    func reply(_ allowed: Bool) { continuation?.resume(returning: allowed); continuation = nil }
}
@main struct Runner {
    @MainActor static func main() async {
        let config = ShareableFilterConfiguration(value: 1)
        var scenarios = 0
        do {
            let flow = Flow()
            flow.go(to: .enterCode)
            expect(flow.stage == .enterCode && flow.navDirection == .forward, "Enter did not advance")
            flow.go(to: .confirm(config))
            flow.go(to: .enterCode)
            expect(flow.navDirection == .backward, "Back did not reverse the stage transition")
            flow.goBackFromMethod()
            expect(flow.stage == .chooseMethod, "Method Back did not return to chooser")
            scenarios += 1
        }
        do {
            let flow = Flow()
            flow.startMode = .enterCode
            var backs = 0
            flow.onRootBack = { backs += 1 }
            flow.goBackFromMethod()
            expect(backs == 1 && flow.dismissCount == 0, "Onboarding Back lost its owner")
            scenarios += 1
        }
        do {
            let flow = Flow(); flow.stage = .confirm(config)
            flow.addNew(config); flow.addNew(config)
            await settled(flow)
            expect(flow.viewModel.additions == 1, "Repeated Add committed twice")
            expect(flow.stage == .completed(filterName: "Shared filter"), "Add did not complete")
            expect(flow.completion.unavailableListCount == 2, "Add lost skipped-list notice")
            flow.addNew(config)
            expect(flow.viewModel.additions == 1, "A terminal callback repeated Add")
            var callbacks = 0
            flow.onImported = { callbacks += 1 }
            flow.finishImport(); flow.finishImport()
            expect(flow.dismissCount == 2 && callbacks == 1, "Completion callback was delivered twice")
            scenarios += 1
        }
        do {
            let flow = Flow(); let auth = Auth()
            flow.stage = .confirm(config)
            flow.authorizeImport = { await auth.call() }
            flow.addNew(config); await auth.ready(); auth.reply(false); await settled(flow)
            expect(flow.viewModel.additions == 0 && flow.stage == .confirm(config), "Denied Add changed the library")
            scenarios += 1
        }
        do {
            let flow = Flow(); let auth = Auth()
            flow.stage = .confirm(config)
            flow.authorizeImport = { await auth.call() }
            flow.addNew(config); await auth.ready()
            flow.viewModel.plan = ShareableFilterConfiguration(value: 0)
            auth.reply(true); await settled(flow)
            expect(flow.viewModel.additions == 0 && flow.completion.filterName == nil, "Changed catalog silently committed a different import")
            expect(flow.stage == .confirm(config) && flow.applyError != nil, "Changed preview did not return for review")
            scenarios += 1
        }
        do {
            let flow = Flow(); flow.stage = .confirm(config); flow.viewModel.failAdd = true
            flow.addNew(config); await settled(flow)
            expect(flow.stage == .confirm(config) && flow.applyError != nil, "Failed Add showed success")
            scenarios += 1
        }
        do {
            let flow = Flow(); let auth = Auth()
            let target = flow.viewModel.library.filter(id: "target")!
            flow.stage = .reviewReplacement(original: config, applied: config, target: target)
            flow.authorizeImport = { await auth.call() }
            flow.replace(config, originalConfiguration: config, into: target)
            await auth.ready()
            flow.viewModel.library.activeFilterID = target.id
            auth.reply(true); await settled(flow)
            expect(flow.viewModel.replacements == 0 && flow.stage == .chooseReplace(config), "Newly active target was replaced without consent")
            let pending = flow.pendingActiveReplacement!
            expect(pending.target == target && pending.configuration == config, "Consent lost the selected target")
            flow.authorizeImport = { true }
            flow.replace(pending.configuration, originalConfiguration: pending.originalConfiguration,
                         into: pending.target, confirmedActiveReplacement: true)
            await settled(flow)
            expect(flow.viewModel.replacements == 1 && flow.stage == .completed(filterName: target.name), "Explicit active consent did not commit")
            expect(flow.completion.unavailableListCount == 2, "Replace lost skipped-list notice")
            scenarios += 1
        }
        do {
            let flow = Flow(); let auth = Auth()
            let target = flow.viewModel.library.filter(id: "target")!
            flow.stage = .reviewReplacement(original: config, applied: config, target: target)
            flow.authorizeImport = { await auth.call() }
            flow.replace(config, originalConfiguration: config, into: target)
            await auth.ready(); flow.viewModel.library.filters[1].name = "Changed"
            auth.reply(true); await settled(flow)
            expect(flow.viewModel.replacements == 0 && flow.stage == .chooseReplace(config) && flow.applyError != nil,
                   "Stale target committed")
            scenarios += 1
        }
        do {
            let flow = Flow(); let target = flow.viewModel.library.filter(id: "target")!
            flow.stage = .reviewReplacement(original: config, applied: config, target: target)
            flow.viewModel.failReplace = true
            flow.replace(config, originalConfiguration: config, into: target); await settled(flow)
            expect(flow.stage == .chooseReplace(config) && flow.applyError == "Write failed", "Failed Replace showed success")
            scenarios += 1
        }
        print("PASS \(scenarios) production import-flow scenarios; \(checks) assertions")
    }
}
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output-dir', type=Path, default=Path('/private/tmp/lava-import-flow-tests'))
    parser.add_argument('--emit-only', action='store_true')
    args = parser.parse_args()
    args.output_dir.mkdir(parents=True, exist_ok=True)
    generated = args.output_dir / 'ImportFlowHarness.swift'
    generated.write_text(generate())
    print(f'Extracted current production methods into {generated}', flush=True)
    if not args.emit_only:
        binary = args.output_dir / 'ImportFlowHarness'
        env = os.environ.copy()
        env['CLANG_MODULE_CACHE_PATH'] = str(args.output_dir / 'clang-module-cache')
        subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-swift-version', '6', '-warnings-as-errors',
                        str(generated), '-o', str(binary)], check=True, env=env)
        subprocess.run([str(binary)], check=True, env=env)


if __name__ == '__main__':
    main()
