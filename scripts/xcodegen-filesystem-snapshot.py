#!/usr/bin/env python3
"""Snapshot and restore files around in-place XcodeGen execution."""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import sys


EXCLUDED_DIRECTORY_NAMES = {
    ".build",
    ".build-xcode",
    ".git",
    ".swiftpm",
    "DerivedData",
    "build",
    "xcuserdata",
}
EXCLUDED_DIRECTORY_SUFFIXES = (".dSYM", ".trace", ".xcresult")
GENERATED_PROJECT_DIRECTORY = "LavaSec.xcodeproj"


def is_excluded(relative: Path, *, directory: bool) -> bool:
    if not relative.parts:
        return False
    if relative.parts[0] in {".git", GENERATED_PROJECT_DIRECTORY}:
        return True
    if any(part in EXCLUDED_DIRECTORY_NAMES for part in relative.parts):
        return True
    return directory and relative.name.endswith(EXCLUDED_DIRECTORY_SUFFIXES)


def inventory_paths() -> list[str]:
    paths: list[str] = []
    for current, directories, filenames in os.walk(".", topdown=True, followlinks=False):
        current_path = Path(current)
        kept_directories: list[str] = []
        for name in directories:
            relative = (current_path / name).relative_to(".")
            if is_excluded(relative, directory=True):
                continue
            if os.path.islink(relative):
                paths.append(relative.as_posix())
            else:
                kept_directories.append(name)
        directories[:] = kept_directories
        for name in filenames:
            relative = (current_path / name).relative_to(".")
            if not is_excluded(relative, directory=False):
                paths.append(relative.as_posix())
    return sorted(paths)


def snapshot() -> dict[str, dict[str, object]]:
    result: dict[str, dict[str, object]] = {}
    for relative in inventory_paths():
        if os.path.islink(relative):
            result[relative] = {"symlink": os.readlink(relative)}
        elif os.path.isfile(relative):
            with open(relative, "rb") as handle:
                result[relative] = {
                    "sha256": hashlib.sha256(handle.read()).hexdigest(),
                    "mode": stat.S_IMODE(os.stat(relative).st_mode),
                }
        else:
            raise RuntimeError(f"unsupported filesystem entry: {relative}")
    return result


def load_snapshot(snapshot_path: str) -> dict[str, dict[str, object]]:
    with open(snapshot_path, encoding="utf-8") as handle:
        value = json.load(handle)
    if not isinstance(value, dict):
        raise RuntimeError("snapshot file must contain an object")
    return value


def changed_paths(
    before: dict[str, dict[str, object]],
    after: dict[str, dict[str, object]],
) -> list[str]:
    before_paths = set(before)
    after_paths = set(after)
    return sorted(
        (before_paths ^ after_paths)
        | {path for path in before_paths & after_paths if before[path] != after[path]}
    )


def write_snapshot(snapshot_path: str, backup_root: str) -> None:
    shutil.rmtree(backup_root, ignore_errors=True)
    os.makedirs(backup_root)
    before = snapshot()
    for relative, metadata in before.items():
        destination = os.path.join(backup_root, relative)
        os.makedirs(os.path.dirname(destination), exist_ok=True)
        if "symlink" in metadata:
            os.symlink(str(metadata["symlink"]), destination)
        else:
            shutil.copy2(relative, destination, follow_symlinks=False)
    with open(snapshot_path, "w", encoding="utf-8") as handle:
        json.dump(before, handle, sort_keys=True)


def compare_snapshot(snapshot_path: str) -> None:
    before = load_snapshot(snapshot_path)
    changed = changed_paths(before, snapshot())
    if changed:
        raise RuntimeError(
            "generation changed non-project files: " + ", ".join(changed)
        )
    print("check-xcodegen-drift: generation left non-project files unchanged")


def safe_relative_path(relative: str) -> Path:
    value = Path(relative)
    if value.is_absolute() or not value.parts or ".." in value.parts:
        raise RuntimeError(f"unsafe snapshot path: {relative}")
    return value


def has_symlink_ancestor(relative: Path) -> bool:
    ancestor = Path()
    for component in relative.parts[:-1]:
        ancestor /= component
        if os.path.islink(ancestor):
            return True
    return False


def remove_path(relative: str) -> None:
    relative_path = safe_relative_path(relative)
    # If an after-state ancestor is a symlink, removing the ancestor itself is sufficient.
    # Following it to remove this child could mutate an arbitrary path outside the repo.
    if has_symlink_ancestor(relative_path):
        return
    if not os.path.lexists(relative):
        return
    if os.path.isdir(relative) and not os.path.islink(relative):
        shutil.rmtree(relative)
    else:
        os.unlink(relative)


def restore_snapshot(snapshot_path: str, backup_root: str) -> None:
    before = load_snapshot(snapshot_path)
    changed = changed_paths(before, snapshot())

    # Preflight every required backup before modifying the working tree. A corrupt or
    # incomplete backup must leave the current files untouched and surface loudly.
    for relative in changed:
        safe_relative_path(relative)
        if relative in before and not os.path.lexists(os.path.join(backup_root, relative)):
            raise RuntimeError(f"snapshot backup is missing {relative}")

    # Remove the complete after-state deepest-first while every after-state parent still
    # has its original type. Only then rebuild the before-state shallowest-first. This
    # prevents a restored directory symlink from becoming an ancestor of later removals.
    for relative in sorted(changed, key=lambda value: (-len(Path(value).parts), value)):
        remove_path(relative)

    for relative in sorted(
        (path for path in changed if path in before),
        key=lambda value: (len(Path(value).parts), value),
    ):
        source = os.path.join(backup_root, relative)
        os.makedirs(os.path.dirname(relative) or ".", exist_ok=True)
        if "symlink" in before[relative]:
            os.symlink(str(before[relative]["symlink"]), relative)
        else:
            shutil.copy2(source, relative, follow_symlinks=False)

    remaining = changed_paths(before, snapshot())
    if remaining:
        raise RuntimeError("restore verification failed for: " + ", ".join(remaining))
    if changed:
        print("check-xcodegen-drift: restored generator side effects: " + ", ".join(changed))


def main(arguments: list[str]) -> int:
    try:
        if len(arguments) == 3 and arguments[0] == "write":
            write_snapshot(arguments[1], arguments[2])
        elif len(arguments) == 2 and arguments[0] == "compare":
            compare_snapshot(arguments[1])
        elif len(arguments) == 3 and arguments[0] == "restore":
            restore_snapshot(arguments[1], arguments[2])
        else:
            print(
                "usage: xcodegen-filesystem-snapshot.py "
                "write SNAPSHOT BACKUP | compare SNAPSHOT | restore SNAPSHOT BACKUP",
                file=sys.stderr,
            )
            return 2
    except (OSError, RuntimeError, ValueError, json.JSONDecodeError) as error:
        print(f"check-xcodegen-drift: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
