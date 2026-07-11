#!/usr/bin/env bash
# Fails when the committed LavaSec.xcodeproj drifts from project.yml (the XcodeGen
# source of truth) — i.e. someone hand-edited the generated pbxproj, edited the spec
# without regenerating, or a different XcodeGen version changed the build-affecting
# output. Phase C1 of lavasec-infra plans/2026-07-07-ios-modularization-scaffolding-plan.md.
#
# Mechanics: regenerate in place (XcodeGen resolves file references relative to the
# project location, so generating into a temp dir would skew every path), first with the
# pinned post-generation hook removed. Generation and the explicit hook must leave all
# non-project files byte-stable. The raw project must match the approved target, source,
# package, dependency, and scheme boundary; raw/fixed PBX object graphs must then be
# identical after masking only knownRegions and .icon file types. Finally, restore the
# committed project and compare committed/fixed pbxprojs SEMANTICALLY: memberships
# resolved to repo paths, file types, product types, dependencies, package products,
# embed/copy phases (destination + attributes), every build setting at project and
# target level, base xcconfig wiring, knownRegions. UUIDs, group layout, and comments
# are ignored — they carry no build meaning. The shared scheme is compared
# byte-for-byte (it is generated too).
set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v xcodegen >/dev/null 2>&1; then
    echo "check-xcodegen-drift: xcodegen not installed (brew install xcodegen)" >&2
    exit 2
fi

snapshot_nonproject_files() {
    python3 scripts/xcodegen-filesystem-snapshot.py "$@"
}

tmp=""
cleanup_tmp() {
    if [ -n "$tmp" ]; then
        rm -rf "$tmp"
    fi
}
trap cleanup_tmp EXIT
tmp=$(mktemp -d)
cp -R LavaSec.xcodeproj "$tmp/committed.xcodeproj"
cp project.yml "$tmp/committed-project.yml"
node scripts/check-xcodegen-sources.mjs --emit-boundary-json > "$tmp/expected-boundary.json"
# From the first in-place mutation onward, restore the committed project as well.
active_nonproject_snapshot=""
active_nonproject_backup=""
restore() {
    original_status=$?
    trap - EXIT
    restore_failed=0
    if [ -n "$active_nonproject_snapshot" ]; then
        if ! snapshot_nonproject_files restore \
            "$active_nonproject_snapshot" \
            "$active_nonproject_backup"; then
            restore_failed=1
        fi
    fi
    if ! cp "$tmp/committed-project.yml" project.yml; then
        restore_failed=1
    fi
    if ! rm -rf LavaSec.xcodeproj; then
        restore_failed=1
    elif ! cp -R "$tmp/committed.xcodeproj" LavaSec.xcodeproj; then
        restore_failed=1
    fi
    if [ "$restore_failed" -ne 0 ]; then
        echo "check-xcodegen-drift: FATAL: working-tree restore failed; backup retained at $tmp" >&2
        exit 1
    fi
    rm -rf "$tmp"
    exit "$original_status"
}
trap restore EXIT

# Generate once without the post-generation hook, then run the one approved fixup explicitly.
# Comparing those two semantic graphs prevents the hook from mutating target identity, sources,
# dependencies, packages, phases, or build settings while still allowing its two documented edits.
python3 - <<'PYEOF'
from pathlib import Path

path = Path("project.yml")
text = path.read_text(encoding="utf-8")
command = "  postGenCommand: python3 scripts/xcodegen-fixups.py\n"
if text.count(command) != 1:
    raise SystemExit("check-xcodegen-drift: expected one exact pinned postGenCommand")
path.write_text(text.replace(command, ""), encoding="utf-8")
PYEOF
active_nonproject_snapshot="$tmp/pre-xcodegen-files.json"
active_nonproject_backup="$tmp/pre-xcodegen-backup"
snapshot_nonproject_files write "$active_nonproject_snapshot" "$active_nonproject_backup"
xcodegen generate
snapshot_nonproject_files compare "$active_nonproject_snapshot"
active_nonproject_snapshot=""
active_nonproject_backup=""
cp LavaSec.xcodeproj/project.pbxproj "$tmp/raw.pbxproj"
cp -R LavaSec.xcodeproj "$tmp/raw.xcodeproj"
cp -R LavaSec.xcodeproj/xcshareddata/xcschemes "$tmp/raw-schemes"
cp "$tmp/committed-project.yml" project.yml
active_nonproject_snapshot="$tmp/pre-postgen-files.json"
active_nonproject_backup="$tmp/pre-postgen-backup"
snapshot_nonproject_files write "$active_nonproject_snapshot" "$active_nonproject_backup"
python3 scripts/xcodegen-fixups.py
snapshot_nonproject_files compare "$active_nonproject_snapshot"
active_nonproject_snapshot=""
active_nonproject_backup=""
cp LavaSec.xcodeproj/project.pbxproj "$tmp/generated.pbxproj"
cp -R LavaSec.xcodeproj "$tmp/generated.xcodeproj"
cp -R LavaSec.xcodeproj/xcshareddata/xcschemes "$tmp/generated-schemes"

plutil -convert json -o "$tmp/committed.json" "$tmp/committed.xcodeproj/project.pbxproj"
plutil -convert json -o "$tmp/raw.json" "$tmp/raw.pbxproj"
plutil -convert json -o "$tmp/generated.json" "$tmp/generated.pbxproj"

status=0
if ! node scripts/check-xcodegen-generated-boundary.mjs \
    "$tmp/expected-boundary.json" \
    "$tmp/raw.json" \
    "$tmp/raw.xcodeproj"; then
    status=1
fi
if ! node scripts/check-xcodegen-generated-boundary.mjs \
    "$tmp/expected-boundary.json" \
    "$tmp/generated.json" \
    "$tmp/generated.xcodeproj"; then
    status=1
fi
if ! node scripts/check-xcodegen-generated-boundary.mjs \
    "$tmp/expected-boundary.json" \
    "$tmp/committed.json" \
    "$tmp/committed.xcodeproj"; then
    status=1
fi
python3 - "$tmp/committed.json" "$tmp/generated.json" "$tmp/raw.json" <<'PYEOF' || status=1
import copy
import difflib
import json
import sys


def build_parent_map(objects):
    parent = {}
    for oid, obj in objects.items():
        if obj.get("isa") in ("PBXGroup", "PBXVariantGroup"):
            for child in obj.get("children", []):
                parent[child] = oid
    return parent


def resolve_path(objects, parent, oid):
    parts = []
    cur = oid
    while cur is not None:
        obj = objects[cur]
        if obj.get("sourceTree") == "BUILT_PRODUCTS_DIR":
            return "BUILT_PRODUCTS_DIR/" + obj.get("path", obj.get("name", "?"))
        p = obj.get("path")
        if p:
            parts.append(p)
        cur = parent.get(cur)
    return "/".join(reversed(parts))


def load_project(path):
    with open(path) as f:
        return json.load(f)


def normalize(path):
    root = load_project(path)
    objects = root["objects"]
    parent = build_parent_map(objects)
    project = objects[root["rootObject"]]

    def config_list(list_id):
        lst = objects[list_id]
        out = []
        for cid in lst["buildConfigurations"]:
            cfg = objects[cid]
            base = cfg.get("baseConfigurationReference")
            out.append(
                {
                    "name": cfg["name"],
                    "baseConfiguration": resolve_path(objects, parent, base) if base else None,
                    "buildSettings": cfg.get("buildSettings", {}),
                }
            )
        out.sort(key=json.dumps)
        return {
            "configs": out,
            "defaultConfigurationIsVisible": lst.get("defaultConfigurationIsVisible"),
            "defaultConfigurationName": lst.get("defaultConfigurationName"),
        }

    def file_type(ref_id):
        ref = objects[ref_id]
        return ref.get("lastKnownFileType") or ref.get("explicitFileType")

    def target_dependency(dependency_id):
        dependency = copy.deepcopy(objects[dependency_id])
        target_id = dependency.get("target")
        dependency["target"] = objects.get(target_id, {}).get("name", target_id)
        proxy_id = dependency.get("targetProxy")
        if proxy_id:
            proxy = copy.deepcopy(objects.get(proxy_id, {"missing": proxy_id}))
            if proxy.get("containerPortal") == root["rootObject"]:
                proxy["containerPortal"] = "<project>"
            remote_id = proxy.get("remoteGlobalIDString")
            if remote_id in objects and objects[remote_id].get("name"):
                proxy["remoteGlobalIDString"] = objects[remote_id]["name"]
            dependency["targetProxy"] = proxy
        return dependency

    result = {
        "developmentRegion": project.get("developmentRegion"),
        "knownRegions": sorted(project.get("knownRegions", [])),
        "projectConfigurations": config_list(project["buildConfigurationList"]),
        "packageReferences": [],
        "targets": {},
    }
    for pid in project.get("packageReferences", []):
        pkg = objects[pid]
        if pkg["isa"] == "XCLocalSwiftPackageReference":
            result["packageReferences"].append({"local": pkg.get("relativePath")})
        else:
            result["packageReferences"].append(
                {"url": pkg.get("repositoryURL"), "requirement": pkg.get("requirement")}
            )
    result["packageReferences"].sort(key=json.dumps)

    for tid in project["targets"]:
        target = objects[tid]
        approved_target_fields = {
            "buildConfigurationList",
            "buildPhases",
            "buildRules",
            "dependencies",
            "isa",
            "name",
            "packageProductDependencies",
            "productName",
            "productReference",
            "productType",
        }
        t = {
            "productType": target.get("productType"),
            "configurations": config_list(target["buildConfigurationList"]),
            "dependencies": sorted(
                (target_dependency(d) for d in target.get("dependencies", [])),
                key=json.dumps,
            ),
            "packageProducts": sorted(
                objects[p]["productName"] for p in target.get("packageProductDependencies", [])
            ),
            "unexpectedTargetFields": {
                key: copy.deepcopy(value)
                for key, value in target.items()
                if key not in approved_target_fields
            },
            "phases": [],
        }
        for phid in target.get("buildPhases", []):
            phase = objects[phid]
            isa = phase["isa"]
            entries = []
            for bfid in phase.get("files", []):
                bf = objects[bfid]
                entry = {}
                if "fileRef" in bf:
                    entry["path"] = resolve_path(objects, parent, bf["fileRef"])
                    entry["fileType"] = file_type(bf["fileRef"])
                elif "productRef" in bf:
                    entry["package"] = objects[bf["productRef"]]["productName"]
                build_file_metadata = {
                    key: copy.deepcopy(value)
                    for key, value in bf.items()
                    if key not in ("isa", "fileRef", "productRef")
                }
                attrs = build_file_metadata.get("settings", {}).get("ATTRIBUTES")
                if attrs:
                    build_file_metadata["settings"]["ATTRIBUTES"] = sorted(attrs)
                if build_file_metadata:
                    entry["buildFile"] = build_file_metadata
                entries.append(entry)
            entries.sort(key=json.dumps)
            phase_metadata = {
                key: copy.deepcopy(value)
                for key, value in phase.items()
                if key not in ("isa", "files")
            }
            t["phases"].append(
                {
                    "isa": isa,
                    "metadata": phase_metadata,
                    "files": entries,
                }
            )
        t["phases"].sort(key=json.dumps)
        result["targets"][target["name"]] = t
    return result


def mask_approved_postgen_changes(root):
    # Raw and fixed files come from the same XcodeGen run, so UUID-preserving structural
    # equality is both possible and stricter than the lossy cross-generation normalizer.
    masked = copy.deepcopy(root)
    objects = masked["objects"]
    project = objects[masked["rootObject"]]
    project["knownRegions"] = []
    for obj in objects.values():
        if obj.get("isa") != "PBXFileReference":
            continue
        leaf = obj.get("path") or obj.get("name") or ""
        if leaf.endswith(".icon") and "lastKnownFileType" in obj:
            obj["lastKnownFileType"] = "<approved-icon-composer-type>"
    return masked


def print_diff(before, after, before_name, after_name):
    a = json.dumps(before, indent=1, sort_keys=True).splitlines()
    b = json.dumps(after, indent=1, sort_keys=True).splitlines()
    for line in difflib.unified_diff(a, b, before_name, after_name, lineterm="", n=2):
        print(line)


committed = normalize(sys.argv[1])
generated = normalize(sys.argv[2])
generated_structure = load_project(sys.argv[2])
raw_structure = load_project(sys.argv[3])
ok = True

masked_raw = mask_approved_postgen_changes(raw_structure)
masked_generated = mask_approved_postgen_changes(generated_structure)
if masked_raw != masked_generated:
    print("check-xcodegen-drift: postGenCommand changed unapproved project semantics:")
    print_diff(
        masked_raw,
        masked_generated,
        "raw-xcodegen",
        "postgen",
    )
    ok = False
else:
    print("check-xcodegen-drift: postGenCommand changed only approved project properties")

if committed == generated:
    print("check-xcodegen-drift: committed pbxproj matches project.yml output")
else:
    print("check-xcodegen-drift: DRIFT between committed pbxproj and `xcodegen generate` output:")
    print_diff(committed, generated, "committed", "generated")
    print("fix: edit project.yml (never the pbxproj), run `xcodegen generate`, commit both.")
    ok = False

sys.exit(0 if ok else 1)
PYEOF

if ! diff -qr "$tmp/raw-schemes" "$tmp/generated-schemes" >/dev/null; then
    echo "check-xcodegen-drift: postGenCommand changed the shared schemes:" >&2
    diff -r "$tmp/raw-schemes" "$tmp/generated-schemes" >&2 || true
    status=1
fi

if ! diff -qr "$tmp/committed.xcodeproj/xcshareddata/xcschemes" "$tmp/generated-schemes" >/dev/null; then
    echo "check-xcodegen-drift: DRIFT in shared schemes:" >&2
    diff -r "$tmp/committed.xcodeproj/xcshareddata/xcschemes" "$tmp/generated-schemes" >&2 || true
    status=1
fi

exit "$status"
