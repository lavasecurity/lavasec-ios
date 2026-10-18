#!/usr/bin/env python3
"""Verify immutable preview source and the exact source-built engine it consumes."""
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
ARTIFACT = "ThirdParty/wireguard-core/build"
ENGINE_FILES = {f"{ARTIFACT}/BUILD-TOOLCHAIN.txt", f"{ARTIFACT}/LavaSecWGCore.xcframework/Info.plist"}
for platform in ("ios-arm64", "ios-arm64-simulator", "macos-arm64"):
    for name in ("Headers/lavasec_wireguard_core.h", "liblavasec_wireguard_core.a"):
        ENGINE_FILES.add(f"{ARTIFACT}/LavaSecWGCore.xcframework/{platform}/{name}")


def engine_manifest():
    artifact = ROOT / ARTIFACT
    for parent in (ROOT / "ThirdParty", ROOT / "ThirdParty/wireguard-core", artifact):
        if parent.is_symlink() or not parent.is_dir():
            raise ValueError("The source-built engine must use regular directories.")
    files = {}
    for path in artifact.rglob("*"):
        info = path.lstat()
        if stat.S_ISDIR(info.st_mode):
            continue
        if not stat.S_ISREG(info.st_mode):
            raise ValueError("The source-built engine contains a symlink or non-regular entry.")
        relative = path.relative_to(ROOT).as_posix()
        files[relative] = {"sha256": hashlib.sha256(path.read_bytes()).hexdigest(), "mode": stat.S_IMODE(info.st_mode)}
    if set(files) != ENGINE_FILES:
        raise ValueError("The source-built engine does not have the exact expected file membership.")
    return {"version": 1, "files": files}


def git(*args):
    return subprocess.check_output(["git", *args], cwd=ROOT).strip()


def verify_source(revision, prepared):
    if git("rev-parse", "HEAD").decode() != revision:
        raise ValueError("The preview checkout no longer has the captured source revision.")
    # Preparation never stages files. Reject index changes even in the generated
    # engine tree; the commit remains the authority for all tracked source.
    subprocess.run(["git", "diff", "--quiet", "--no-ext-diff", "--no-textconv", "--cached", "HEAD", "--"], cwd=ROOT, check=True)
    paths = ["."] + ([f":(exclude){ARTIFACT}"] if prepared else [])
    subprocess.run(["git", "diff", "--quiet", "--no-ext-diff", "--no-textconv", "HEAD", "--", *paths], cwd=ROOT, check=True)
    if git("ls-files", "--others", "--exclude-standard", "-z"):
        raise ValueError("The preview checkout contains untracked source files.")


def main():
    command, *args = sys.argv[1:]
    if command == "capture-engine" and len(args) == 1:
        manifest = engine_manifest()
        destination = Path(args[0])
        destination.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.NamedTemporaryFile(mode="w", dir=destination.parent, delete=False) as output:
            temporary = Path(output.name)
            json.dump(manifest, output, sort_keys=True, indent=2)
            output.write("\n")
        try:
            os.replace(temporary, destination)
        finally:
            temporary.unlink(missing_ok=True)
    elif command == "verify-clean" and len(args) == 1:
        verify_source(args[0], prepared=False)
    elif command == "verify-prepared" and len(args) == 2:
        verify_source(args[0], prepared=True)
        expected = json.loads(Path(args[1]).read_text())
        if expected != engine_manifest():
            raise ValueError("The source-built engine changed after successful preparation.")
    else:
        raise ValueError("Usage: verify-preview-source.py capture-engine MANIFEST | verify-clean REVISION | verify-prepared REVISION MANIFEST")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        sys.exit(f"Preview source verification failed: {error}")
