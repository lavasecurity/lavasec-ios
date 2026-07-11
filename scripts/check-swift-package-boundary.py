#!/usr/bin/env python3
"""Fail closed when SwiftPM can compile code outside the reviewed package graph."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import subprocess
import sys
import tempfile


class BoundaryError(Exception):
    """The semantic Swift package dump differs from the approved policy."""


LAYER_TARGETS = [
    "LavaSecKit",
    "LavaSecNetworking",
    "LavaSecDNS",
    "LavaSecFilterPipeline",
    "LavaSecPresentation",
    "LavaSecAppServices",
]

REQUIRED_PACKAGE_KEYS = {
    "cLanguageStandard",
    "cxxLanguageStandard",
    "dependencies",
    "name",
    "packageKind",
    "pkgConfig",
    "platforms",
    "products",
    "providers",
    "swiftLanguageVersions",
    "targets",
    "toolsVersion",
    "traits",
}

# Xcode 26.5's SwiftPM added this dump key while Xcode 26.3 omits it. Accept
# both known schema shapes, but require the manifest's exact resource-
# localization policy whenever the newer toolchain makes the field visible.
OPTIONAL_PACKAGE_FIELDS = {"defaultLocalization": "en"}

EXPECTED_PLATFORMS = [
    {"options": [], "platformName": "ios", "version": "18.0"},
    {"options": [], "platformName": "macos", "version": "15.0"},
]


def by_name(name: str) -> dict[str, list[str | None]]:
    return {"byName": [name, None]}


def target(
    name: str,
    target_type: str,
    dependencies: list[str],
    *,
    resources: list[dict[str, object]] | None = None,
    settings: list[dict[str, object]] | None = None,
) -> dict[str, object]:
    return {
        "dependencies": [by_name(dependency) for dependency in dependencies],
        "exclude": [],
        "name": name,
        "packageAccess": True,
        "resources": resources or [],
        "settings": settings or [],
        "type": target_type,
    }


EXPECTED_TARGETS = [
    target(
        "LavaSecKit",
        "regular",
        [],
        resources=[{"path": "Resources", "rule": {"process": {}}}],
        settings=[{
            "kind": {"linkedLibrary": {"_0": "sqlite3"}},
            "tool": "linker",
        }],
    ),
    target("LavaSecNetworking", "regular", ["LavaSecKit"]),
    target("LavaSecDNS", "regular", ["LavaSecKit"]),
    target(
        "LavaSecFilterPipeline",
        "regular",
        ["LavaSecKit", "LavaSecNetworking"],
    ),
    target("LavaSecPresentation", "regular", ["LavaSecKit"]),
    target(
        "LavaSecAppServices",
        "regular",
        ["LavaSecKit", "LavaSecFilterPipeline"],
    ),
    target("LavaSecCore", "regular", LAYER_TARGETS),
    target("LavaSecCoreTests", "test", ["LavaSecCore", *LAYER_TARGETS]),
    target("LavaSecCoreFacadeCompileTests", "test", ["LavaSecCore"]),
]


def library_product(name: str, targets: list[str]) -> dict[str, object]:
    return {
        "name": name,
        "settings": [],
        "targets": targets,
        "type": {"library": ["automatic"]},
    }


EXPECTED_PRODUCTS = [
    library_product("LavaSecCore", ["LavaSecCore", *LAYER_TARGETS]),
    *[library_product(name, [name]) for name in LAYER_TARGETS],
]


def validate_package(package: object) -> None:
    if not isinstance(package, dict):
        raise BoundaryError("package dump must be a JSON object")
    actual_package_keys = set(package)
    approved_package_keys = REQUIRED_PACKAGE_KEYS | set(OPTIONAL_PACKAGE_FIELDS)
    unexpected = sorted(actual_package_keys - approved_package_keys)
    missing = sorted(REQUIRED_PACKAGE_KEYS - actual_package_keys)
    if unexpected or missing:
        raise BoundaryError(
            "package top-level fields differ from policy "
            + f"(unexpected={unexpected}, missing={missing})"
        )
    for field, expected in OPTIONAL_PACKAGE_FIELDS.items():
        if field in package and package[field] != expected:
            raise BoundaryError("package default localization differs from policy")
    if package["name"] != "LavaSec":
        raise BoundaryError("package name differs from policy")
    if package["platforms"] != EXPECTED_PLATFORMS:
        raise BoundaryError("package platforms differ from policy")
    if any(
        package[field] is not None
        for field in (
            "swiftLanguageVersions",
            "cLanguageStandard",
            "cxxLanguageStandard",
        )
    ):
        raise BoundaryError("package language differs from policy")
    if package["toolsVersion"] != {"_version": "6.0.0"}:
        raise BoundaryError("package tools version differs from policy")
    if package["pkgConfig"] is not None:
        raise BoundaryError("package pkg-config differs from policy")
    if package["providers"] is not None:
        raise BoundaryError("package providers differ from policy")
    package_kind = package["packageKind"]
    if (
        not isinstance(package_kind, dict)
        or set(package_kind) != {"root"}
        or not isinstance(package_kind["root"], list)
        or len(package_kind["root"]) != 1
        or not isinstance(package_kind["root"][0], str)
        or not Path(package_kind["root"][0]).is_absolute()
    ):
        raise BoundaryError("package kind differs from policy")
    if package.get("dependencies") != []:
        raise BoundaryError("package dependencies differ from policy")
    if package.get("traits") != []:
        raise BoundaryError("package traits differ from policy")
    if package.get("products") != EXPECTED_PRODUCTS:
        raise BoundaryError("package products differ from policy")

    actual_targets = package.get("targets")
    if not isinstance(actual_targets, list):
        raise BoundaryError("package targets must be a JSON array")
    actual_names = [
        entry.get("name") if isinstance(entry, dict) else None
        for entry in actual_targets
    ]
    expected_names = [entry["name"] for entry in EXPECTED_TARGETS]
    if sorted(actual_names, key=lambda value: str(value)) != sorted(expected_names):
        raise BoundaryError(
            "package target set differs from policy: "
            + f"actual={actual_names}, expected={expected_names}"
        )
    if len(set(actual_names)) != len(actual_names):
        raise BoundaryError("package target names contain duplicates")

    targets_by_name = {entry["name"]: entry for entry in actual_targets}
    for expected in EXPECTED_TARGETS:
        name = expected["name"]
        actual = targets_by_name[name]
        if actual != expected:
            unexpected = sorted(set(actual) - set(expected))
            missing = sorted(set(expected) - set(actual))
            detail = f"unexpected fields={unexpected}, missing fields={missing}"
            raise BoundaryError(f"package target {name} differs from policy ({detail})")


def validate_package_description(description: object) -> None:
    if not isinstance(description, dict):
        raise BoundaryError("package description must be a JSON object")
    if description.get("default_localization") != "en":
        raise BoundaryError("package default localization differs from policy")


def load_package_dump(input_path: str | None) -> object:
    if input_path is not None:
        return json.loads(Path(input_path).read_text(encoding="utf-8"))
    repository = Path(__file__).resolve().parent.parent
    with tempfile.TemporaryDirectory(prefix="lavasec-package-dump-") as scratch:
        result = subprocess.run(
            [
                "swift",
                "package",
                "dump-package",
                "--package-path",
                str(repository),
                "--scratch-path",
                scratch,
            ],
            check=False,
            capture_output=True,
            text=True,
        )
    if result.returncode != 0:
        detail = result.stderr.strip() or f"exit status {result.returncode}"
        raise BoundaryError(f"swift package dump-package failed: {detail}")
    return json.loads(result.stdout)


def load_package_description(input_path: str | None) -> object:
    if input_path is not None:
        return json.loads(Path(input_path).read_text(encoding="utf-8"))
    repository = Path(__file__).resolve().parent.parent
    with tempfile.TemporaryDirectory(prefix="lavasec-package-description-") as scratch:
        result = subprocess.run(
            [
                "swift",
                "package",
                "--package-path",
                str(repository),
                "--scratch-path",
                scratch,
                "describe",
                "--type",
                "json",
            ],
            check=False,
            capture_output=True,
            text=True,
        )
    if result.returncode != 0:
        detail = result.stderr.strip() or f"exit status {result.returncode}"
        raise BoundaryError(f"swift package describe failed: {detail}")
    return json.loads(result.stdout)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", help="validate an existing dump-package JSON fixture")
    parser.add_argument(
        "--description-input",
        help="validate an existing package describe JSON fixture",
    )
    arguments = parser.parse_args()
    try:
        if arguments.input is not None or arguments.description_input is None:
            validate_package(load_package_dump(arguments.input))
        if arguments.description_input is not None or arguments.input is None:
            validate_package_description(
                load_package_description(arguments.description_input)
            )
    except (BoundaryError, json.JSONDecodeError, OSError) as error:
        print(f"check-swift-package-boundary: {error}", file=sys.stderr)
        return 1
    print("check-swift-package-boundary: package graph matches the approved boundary")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
