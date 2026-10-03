#!/usr/bin/env python3
"""Execute the unmodified production display-order methods with small model doubles.

This validates ordering and pending-row retention; it does not emulate UIKit layout.
The full-app row-frame journey independently checks the rendered geometry.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--output', type=Path)
parser.add_argument('--ref', help='Read production methods from this git revision for RED evidence')
args = parser.parse_args()
path = 'LavaSecApp/AppViewModel/AppViewModel+FilterEditingDrafts.swift'
source = subprocess.check_output(['git', 'show', f'{args.ref}:{path}'], cwd=root, text=True) if args.ref else (root / path).read_text()

def method(name):
    start = source.index('    func ' + name)
    opening = source.index('{', start)
    depth, cursor = 1, opening + 1
    while depth:
        if source[cursor] == '{': depth += 1
        elif source[cursor] == '}': depth -= 1
        cursor += 1
    return source[start:cursor]

methods = '\n'.join(method(name) for name in [
    'stagedBlocklistIDsForDisplay()', 'stagedBlockedDomainsForDisplay()', 'stagedAllowedDomainsForDisplay()',
])
fixture = r'''
import Foundation
struct FilterState {
    var enabledBlocklistIDs: Set<String> = []
    var blockedDomains: Set<String> = []
    var allowedDomains: Set<String> = []
}
final class AppViewModel {
    var filterDetailBaseline = FilterState()
    var filterEditDraft: FilterState?
    var names: [String: String] = [:]
    func blocklistName(for id: String) -> String { names[id] ?? id }
    // PRODUCTION_METHODS
}
let model = AppViewModel()
var failures: [String] = []
var checks = 0
func check(_ actual: [String], _ expected: [String], _ name: String) {
    checks += 1
    if actual != expected { failures.append("\(name): \(actual) != \(expected)") }
}
model.filterDetailBaseline = FilterState(
    enabledBlocklistIDs: ["a-id", "z-id"],
    blockedDomains: ["site49.example", "site5.example", "site7.example"],
    allowedDomains: ["site10.example", "site2.example"])
model.names = ["a-id": "Zeta", "z-id": "Alpha"]
let viewedBlocked = model.stagedBlockedDomainsForDisplay()
let viewedAllowed = model.stagedAllowedDomainsForDisplay()
let viewedLists = model.stagedBlocklistIDsForDisplay()
check(viewedBlocked, ["site5.example", "site7.example", "site49.example"], "viewed blocked natural order")
check(viewedAllowed, ["site2.example", "site10.example"], "viewed allowed natural order")
check(viewedLists, ["z-id", "a-id"], "viewed lists use display names")
model.filterEditDraft = model.filterDetailBaseline
check(model.stagedBlockedDomainsForDisplay(), viewedBlocked, "Edit preserves blocked positions")
check(model.stagedAllowedDomainsForDisplay(), viewedAllowed, "Edit preserves allowed positions")
check(model.stagedBlocklistIDsForDisplay(), viewedLists, "Edit preserves list positions")
model.filterEditDraft?.blockedDomains.remove("site5.example")
model.filterEditDraft?.allowedDomains.remove("site2.example")
model.filterEditDraft?.enabledBlocklistIDs.remove("z-id")
check(model.stagedBlockedDomainsForDisplay(), viewedBlocked, "pending blocked removal stays in place")
check(model.stagedAllowedDomainsForDisplay(), viewedAllowed, "pending allowed removal stays in place")
check(model.stagedBlocklistIDsForDisplay(), viewedLists, "pending list removal stays in place")
model.filterEditDraft?.blockedDomains.insert("site6.example")
model.filterEditDraft?.allowedDomains.insert("site3.example")
model.filterEditDraft?.enabledBlocklistIDs.insert("middle")
model.names["middle"] = "Beta"
check(model.stagedBlockedDomainsForDisplay(), ["site5.example", "site6.example", "site7.example", "site49.example"], "new blocked row joins the same order")
check(model.stagedAllowedDomainsForDisplay(), ["site2.example", "site3.example", "site10.example"], "new allowed row joins the same order")
check(model.stagedBlocklistIDsForDisplay(), ["z-id", "middle", "a-id"], "new list joins display-name order")
model.filterEditDraft = nil
check(model.stagedBlockedDomainsForDisplay(), viewedBlocked, "cancel restores saved blocked rows")
check(model.stagedAllowedDomainsForDisplay(), viewedAllowed, "cancel restores saved allowed rows")
check(model.stagedBlocklistIDsForDisplay(), viewedLists, "cancel restores saved lists")
model.names = ["a-id": "Same", "z-id": "Same"]
check(model.stagedBlocklistIDsForDisplay(), ["a-id", "z-id"], "view ties use source ID")
model.filterEditDraft = model.filterDetailBaseline
check(model.stagedBlocklistIDsForDisplay(), ["a-id", "z-id"], "edit ties use source ID")
if failures.isEmpty { print("PASS \(checks) actual production display-order checks") }
else { failures.forEach { print("FAIL \($0)") }; exit(1) }
'''.replace('    // PRODUCTION_METHODS', methods)

with tempfile.TemporaryDirectory(prefix='lava-filter-order-') as temporary:
    output = args.output or Path(temporary)
    output.mkdir(parents=True, exist_ok=True)
    swift = output / 'DisplayOrder.swift'
    swift.write_text(fixture)
    (output / 'provenance.json').write_text(json.dumps({
        'source': path, 'ref': args.ref, 'methodsSHA256': hashlib.sha256(methods.encode()).hexdigest(),
        'boundary': 'Unmodified production methods; storage and display-name lookup are fixture doubles; no UI claim',
    }, indent=2) + '\n')
    executable = output / 'display-order'
    cache = Path('/private/tmp/lava-filter-display-order-clang')
    subprocess.run(['xcrun', 'swiftc', '-warnings-as-errors', '-module-cache-path', str(cache), str(swift), '-o', str(executable)], check=True)
    subprocess.run([str(executable)], check=True, env={**os.environ, 'LANG': 'en_US.UTF-8'})
