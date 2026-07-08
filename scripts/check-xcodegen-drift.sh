#!/usr/bin/env bash
# Fails when the committed LavaSec.xcodeproj drifts from project.yml (the XcodeGen
# source of truth) — i.e. someone hand-edited the generated pbxproj, edited the spec
# without regenerating, or a different XcodeGen version changed the build-affecting
# output. Phase C1 of lavasec-infra plans/2026-07-07-ios-modularization-scaffolding-plan.md.
#
# Mechanics: regenerate in place (XcodeGen resolves file references relative to the
# project location, so generating into a temp dir would skew every path), stash the
# generated artifacts in a temp dir, restore the committed project, then compare the
# two pbxprojs SEMANTICALLY: per-target build-phase memberships resolved to repo
# paths, file types, product types, dependencies, package product dependencies,
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

tmp=$(mktemp -d)
cp -R LavaSec.xcodeproj "$tmp/committed.xcodeproj"
# Whatever happens below, the committed project is restored and the temp dir removed.
restore() {
    rm -rf LavaSec.xcodeproj
    cp -R "$tmp/committed.xcodeproj" LavaSec.xcodeproj
    rm -rf "$tmp"
}
trap restore EXIT

xcodegen generate
cp LavaSec.xcodeproj/project.pbxproj "$tmp/generated.pbxproj"
cp LavaSec.xcodeproj/xcshareddata/xcschemes/LavaSec.xcscheme "$tmp/generated.xcscheme"

plutil -convert json -o "$tmp/committed.json" "$tmp/committed.xcodeproj/project.pbxproj"
plutil -convert json -o "$tmp/generated.json" "$tmp/generated.pbxproj"

status=0
python3 - "$tmp/committed.json" "$tmp/generated.json" <<'PYEOF' || status=1
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


def normalize(path):
    with open(path) as f:
        root = json.load(f)
    objects = root["objects"]
    parent = build_parent_map(objects)
    project = objects[root["rootObject"]]

    def config_list(list_id):
        lst = objects[list_id]
        out = {}
        for cid in lst["buildConfigurations"]:
            cfg = objects[cid]
            base = cfg.get("baseConfigurationReference")
            out[cfg["name"]] = {
                "baseConfiguration": resolve_path(objects, parent, base) if base else None,
                "buildSettings": cfg.get("buildSettings", {}),
            }
        return {"configs": out, "defaultConfigurationName": lst.get("defaultConfigurationName")}

    def file_type(ref_id):
        ref = objects[ref_id]
        return ref.get("lastKnownFileType") or ref.get("explicitFileType")

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
        t = {
            "productType": target.get("productType"),
            "configurations": config_list(target["buildConfigurationList"]),
            "dependencies": sorted(
                objects[objects[d]["target"]]["name"]
                for d in target.get("dependencies", [])
                if "target" in objects[d]
            ),
            "packageProducts": sorted(
                objects[p]["productName"] for p in target.get("packageProductDependencies", [])
            ),
            "phases": {},
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
                attrs = bf.get("settings", {}).get("ATTRIBUTES")
                if attrs:
                    entry["attributes"] = sorted(attrs)
                entries.append(entry)
            if not entries:
                # An absent phase and an empty phase are the same build; skip both.
                continue
            entries.sort(key=json.dumps)
            if isa == "PBXCopyFilesBuildPhase":
                # Key copy phases by destination, not display name (Xcode renamed
                # "Embed App Extensions" to "Embed Foundation Extensions" over time).
                key = f"CopyFiles:{phase.get('dstSubfolderSpec')}:{phase.get('dstPath')}"
            else:
                key = isa.replace("PBX", "").replace("BuildPhase", "")
            t["phases"][key] = entries
        result["targets"][target["name"]] = t
    return result


committed = normalize(sys.argv[1])
generated = normalize(sys.argv[2])
if committed == generated:
    print("check-xcodegen-drift: committed pbxproj matches project.yml output")
    sys.exit(0)

print("check-xcodegen-drift: DRIFT between committed pbxproj and `xcodegen generate` output:")
import difflib

a = json.dumps(committed, indent=1, sort_keys=True).splitlines()
b = json.dumps(generated, indent=1, sort_keys=True).splitlines()
for line in difflib.unified_diff(a, b, "committed", "generated", lineterm="", n=2):
    print(line)
print("fix: edit project.yml (never the pbxproj), run `xcodegen generate`, commit both.")
sys.exit(1)
PYEOF

if ! diff -q "$tmp/committed.xcodeproj/xcshareddata/xcschemes/LavaSec.xcscheme" "$tmp/generated.xcscheme" >/dev/null; then
    echo "check-xcodegen-drift: DRIFT in shared scheme LavaSec.xcscheme:" >&2
    diff "$tmp/committed.xcodeproj/xcshareddata/xcschemes/LavaSec.xcscheme" "$tmp/generated.xcscheme" >&2 || true
    status=1
fi

exit "$status"
