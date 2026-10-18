#!/usr/bin/env bash
# Build the pinned WireGuard source with the active Xcode/SDKs. Build preparation
# runs this before SwiftPM/Xcode consumes the local binary target. Historical
# artifact bytes and compiler versions are never inputs to this build.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/../ThirdParty/wireguard-core" && pwd -P)"
out="${here}/build"
explicit_output=false
if [ "$#" -ne 0 ]; then
  if [ "$#" -ne 2 ] || [ "$1" != --output ] || [[ "$2" != /* ]] || [ -e "$2" ] || [ -L "$2" ]; then
    echo "usage: $0 [--output /absolute/nonexistent/directory]" >&2
    exit 2
  fi
  out="$2"
  explicit_output=true
fi

cargo_home="${CARGO_HOME:-$HOME/.cargo}"
export PATH="$cargo_home/bin:$PATH"
# Notices checks in later CI steps need the same Rust installation.
if [ -n "${GITHUB_PATH:-}" ]; then
  printf '%s\n' "$cargo_home/bin" >> "$GITHUB_PATH"
fi
for tool in xcodebuild xcrun python3 plutil; do
  command -v "$tool" >/dev/null 2>&1 || { echo "error: $tool not found" >&2; exit 1; }
done
if [ "$explicit_output" = true ]; then
  # Resolve missing/../existing and existing parent aliases before the build.
  # Remember the physical destination so a later parent symlink cannot redirect it.
  out="$(python3 - "$out" <<'PYEOF'
from pathlib import Path
import sys
output = Path(sys.argv[1]).resolve()
if output.exists() or output.is_symlink():
    sys.exit(f"error: explicit output already exists: {output}")
print(output)
PYEOF
)"
fi
if ! command -v rustup >/dev/null 2>&1; then
  curl --proto '=https' --tlsv1.2 --fail --silent --show-error \
    https://sh.rustup.rs | sh -s -- -y --default-toolchain none --no-modify-path
fi
# The crate override, not a host's default Rust, selects the compiler and targets.
cd "$here"
rustup toolchain install --profile minimal
# Homebrew can expose rustup without Cargo/rustc shims on PATH. Resolve the
# selected compiler's binaries through rustup rather than guessing install paths.
cargo_path="$(rustup which cargo)"
cargo_bin="${cargo_path%/*}"
export PATH="$cargo_bin:$PATH"
if [ -n "${GITHUB_PATH:-}" ]; then
  printf '%s\n' "$cargo_bin" >> "$GITHUB_PATH"
fi

# Device, simulator and executable macOS package tests.
targets=(aarch64-apple-ios aarch64-apple-ios-sim aarch64-apple-darwin)
for t in "${targets[@]}"; do
  if ! rustup target list --installed | grep -qx "$t"; then
    rustup target add "$t"
  fi
done

scratch="$(mktemp -d "${TMPDIR:-/tmp}/lavasec-wireguard.XXXXXX")"
scratch="$(cd "$scratch" && pwd -P)"
trap 'rm -rf "$scratch"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
# A clean target directory also prevents Cargo build.rs outputs from retaining
# C objects produced by a previous Xcode selected at the same filesystem path.
export CARGO_TARGET_DIR="$scratch/target"
staged="$scratch/build"
xcframework="$staged/LavaSecWGCore.xcframework"
mkdir -p "$staged"
sysroot="$(rustc --print sysroot)"
# Cargo splits ordinary RUSTFLAGS at whitespace even when a path is quoted.
# Append our mappings through its argument-preserving encoded form, retaining
# the caller's flags and Cargo's precedence for an existing encoded value.
CARGO_ENCODED_RUSTFLAGS="$(python3 - "$here" "$cargo_home" "$sysroot" "$scratch" <<'PYEOF'
import os, re, sys
encoded = os.environ.get("CARGO_ENCODED_RUSTFLAGS")
flags = encoded.split("\x1f") if encoded else []
if encoded is None:
    flags = re.findall(r"[^ \t\r\n\v\f]+", os.environ.get("RUSTFLAGS", ""))
for source, destination in zip(sys.argv[1:], ("/lavasec-wireguard-core", "/cargo", "/rustc", "/wireguard-build")):
    flags.append(f"--remap-path-prefix={source}={destination}")
print("\x1f".join(flags))
PYEOF
)"
export CARGO_ENCODED_RUSTFLAGS
# ring uses the pinned cc crate, whose shell-escaped mode preserves spaces and
# quotes in C path mappings. Preserve the caller's existing parsing semantics.
CFLAGS="$(python3 - "$cargo_home" "$here" "$scratch" <<'PYEOF'
import os, re, shlex, sys
value = os.environ.get("CFLAGS", "")
shell_escaped = os.environ.get("CC_SHELL_ESCAPED_FLAGS", "") not in ("", "0", "no", "false")
flags = shlex.split(value) if shell_escaped else re.findall(r"[^ \t\r\n\v\f]+", value)
for source, destination in zip(sys.argv[1:], ("/cargo", "/lavasec-wireguard-core", "/wireguard-build")):
    flags.append(f"-ffile-prefix-map={source}={destination}")
print(shlex.join(flags))
PYEOF
)"
export CFLAGS CC_SHELL_ESCAPED_FLAGS=1
export SOURCE_DATE_EPOCH=0

for t in "${targets[@]}"; do
  cargo build --locked --release --target "$t"
done
lib_basename=liblavasec_wireguard_core.a
xcodebuild -create-xcframework \
  -library "$CARGO_TARGET_DIR/aarch64-apple-ios/release/$lib_basename" -headers "$here/include" \
  -library "$CARGO_TARGET_DIR/aarch64-apple-ios-sim/release/$lib_basename" -headers "$here/include" \
  -library "$CARGO_TARGET_DIR/aarch64-apple-darwin/release/$lib_basename" -headers "$here/include" \
  -output "$xcframework"

# xcodebuild can emit AvailableLibraries in different orders on repeated builds.
plist="$xcframework/Info.plist"
plutil -convert json -o "$staged/Info.plist.json" "$plist"
python3 - "$staged/Info.plist.json" <<'PYEOF'
import json, sys
p = sys.argv[1]
with open(p) as f:
    data = json.load(f)
data["AvailableLibraries"] = sorted(data["AvailableLibraries"], key=lambda d: d["LibraryIdentifier"])
with open(p, "w") as f:
    json.dump(data, f, sort_keys=True)
PYEOF
plutil -convert xml1 -o "$plist" "$staged/Info.plist.json"
rm "$staged/Info.plist.json"

# Detected versions are provenance, not host requirements or historical pins.
{
  echo "rustc: $(rustc --version)"
  xcodebuild -version
  xcrun clang --version | sed -n '1p'
  for sdk in iphoneos iphonesimulator macosx; do
    sdk_version="$(xcrun --sdk "$sdk" --show-sdk-version)"
    echo "$sdk-sdk: $sdk_version"
  done
} > "$staged/BUILD-TOOLCHAIN.txt"

# Only the generated slices, headers and metadata may reach a consumer. Check
# entry types too: manifests of regular files alone would silently omit symlinks.
python3 - "$staged" <<'PYEOF'
from pathlib import Path
import sys
root = Path(sys.argv[1])
expected = {"BUILD-TOOLCHAIN.txt", "LavaSecWGCore.xcframework/Info.plist"}
for slice in ("ios-arm64", "ios-arm64-simulator", "macos-arm64"):
    for file in ("Headers/lavasec_wireguard_core.h", "liblavasec_wireguard_core.a"):
        expected.add(f"LavaSecWGCore.xcframework/{slice}/{file}")
entries = list(root.rglob("*"))
if any(p.is_symlink() or not (p.is_file() or p.is_dir()) for p in entries):
    sys.exit("error: non-regular entry in generated WireGuard artifact")
actual = {str(p.relative_to(root)) for p in entries if p.is_file()}
if actual != expected:
    sys.exit(f"error: unexpected WireGuard artifact contents: {sorted(actual ^ expected)}")
PYEOF
for lib in "$xcframework"/*/"$lib_basename"; do
  strings -a "$lib" > "$scratch/strings.txt"
  if grep -F -e "$HOME" -e "$cargo_home" -e "$here" -e "$scratch" "$scratch/strings.txt" >/dev/null; then
    echo "error: absolute build path embedded in $lib" >&2
    exit 1
  fi
done

# Publish only a complete successful build. A failed build cannot fall back to
# the checked-in snapshot: callers stop on this script's nonzero exit status.
if [ "$explicit_output" = true ]; then
  python3 - "$staged" "$out" <<'PYEOF'
from pathlib import Path
from tempfile import TemporaryDirectory
import os, shutil, sys
source, output = map(Path, sys.argv[1:])
output.parent.mkdir(parents=True, exist_ok=True)
if output.resolve() != output:
    sys.exit(f"error: explicit output parent changed during the build: {output}")
# Stage beside the destination so publication is a same-filesystem rename even
# when TMPDIR is on another volume. mkdir claims the final name atomically: an
# existing directory, file or symlink is never removed or used as a container.
with TemporaryDirectory(prefix=".lavasec-wireguard-publish-", dir=output.parent) as temporary:
    artifact = Path(temporary) / "build"
    shutil.copytree(source, artifact)
    try:
        output.mkdir()
    except FileExistsError:
        sys.exit(f"error: explicit output appeared during the build: {output}")
    try:
        os.replace(artifact, output)
    except BaseException:
        # Only our empty reservation may be removed; never recursively delete a
        # caller-supplied output, even if publication fails.
        output.rmdir()
        raise
PYEOF
else
  mkdir -p "$(dirname "$out")"
  rm -rf "$out"
  mv "$staged" "$out"
fi
echo "WireGuard source build ready: $out"
cat "$out/BUILD-TOOLCHAIN.txt"
