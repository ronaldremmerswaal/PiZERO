#!/usr/bin/env bash
#
# Fetch the Spotify Connect receiver that runs on the Pi Zero / Zero 2 W.
#
# Upstream is go-librespot, a pure-Go librespot implementation. The release
# assets are used directly, so no cross toolchain and no sudo are needed; the
# download is pinned and checksum-verified.
#
#   armhf  go-librespot_linux_armv6_rpi.tar.gz
#          The dedicated ARMv6 build: the generic "armv6" asset is in fact
#          compiled for ARMv7 (Thumb-2 + NEON, Tag_CPU_arch v7) and dies with
#          "Illegal instruction" on a Zero W's ARM1176JZF-S. This asset also
#          runs on a Zero 2 W (ARMv7/ARMv8 in 32-bit mode).
#   arm64  go-librespot_linux_arm64.tar.gz for a 64-bit OS on a Zero 2 W.
#
# Usage: scripts/build-spotify-connect.sh [--force] [ARCH]
#   --force   refetch the pinned release even if the output already exists
#   ARCH      armhf (default) or arm64, matching `dpkg --print-architecture`
#
# The result is written to build/spotify-connect-<ARCH> (repo relative) and its
# path is printed on stdout.

set -euo pipefail

GO_LIBRESPOT_VERSION="v0.10.5"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$REPO_ROOT/build"

FORCE=0
ARCH=""
for arg in "$@"; do
    case "$arg" in
        -f|--force) FORCE=1 ;;
        -h|--help)
            sed -n '2,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        armhf|arm64) ARCH="$arg" ;;
        *) echo "error: unknown argument: $arg" >&2; exit 2 ;;
    esac
done
ARCH="${ARCH:-armhf}"

case "$ARCH" in
    armhf)
        ASSET="go-librespot_linux_armv6_rpi.tar.gz"
        SHA256="a1f36d2de2973742274eb122c730e0082490ac1e297271a48371e29f290c2e5d"
        ELF_CHECK="armv6"
        ;;
    arm64)
        ASSET="go-librespot_linux_arm64.tar.gz"
        SHA256="35274c1d3576090096d3459ecf76ee9c025258d19dc76f0bf724f95c525467e1"
        ELF_CHECK="aarch64"
        ;;
esac

OUTPUT="$BUILD_DIR/spotify-connect-$ARCH"

if [[ -x "$OUTPUT" && "$FORCE" -eq 0 ]]; then
    echo "spotify-connect $GO_LIBRESPOT_VERSION ($ARCH) already present, not rebuilding (use --force)" >&2
    echo "$OUTPUT"
    exit 0
fi

URL="https://github.com/devgianlu/go-librespot/releases/download/${GO_LIBRESPOT_VERSION}/${ASSET}"

echo "Fetching go-librespot ${GO_LIBRESPOT_VERSION} (${ASSET})..." >&2
mkdir -p "$BUILD_DIR"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

curl -fsSL --retry 3 --retry-connrefused -o "$WORK_DIR/$ASSET" "$URL"

echo "Verifying checksum..." >&2
echo "$SHA256  $WORK_DIR/$ASSET" | sha256sum -c --quiet -

tar -xzf "$WORK_DIR/$ASSET" -C "$WORK_DIR"
[[ -f "$WORK_DIR/go-librespot" ]] || { echo "error: archive does not contain go-librespot" >&2; exit 1; }

# Refuse to install a binary for the wrong architecture.
if command -v readelf >/dev/null 2>&1; then
    if [[ "$ELF_CHECK" == armv6 ]]; then
        cpu_arch="$(readelf -A "$WORK_DIR/go-librespot" | sed -n 's/^ *Tag_CPU_arch: *//p' | head -n1)"
        case "$cpu_arch" in
            v6*) ;;
            *) echo "error: binary is not ARMv6 (Tag_CPU_arch: ${cpu_arch:-unknown}); check the pinned asset" >&2; exit 1 ;;
        esac
        echo "ELF architecture: ARM ${cpu_arch}" >&2
    else
        machine="$(readelf -h "$WORK_DIR/go-librespot" | sed -n 's/^ *Machine: *//p' | head -n1)"
        [[ "$machine" == *AArch64* ]] || {
            echo "error: binary is not AArch64 (Machine: ${machine:-unknown})" >&2
            exit 1
        }
        echo "ELF architecture: ${machine}" >&2
    fi
else
    echo "warning: readelf not found, skipping architecture check" >&2
fi

install -m 0755 "$WORK_DIR/go-librespot" "$OUTPUT"

echo "Built $(stat -c '%s bytes' "$OUTPUT") from go-librespot $GO_LIBRESPOT_VERSION" >&2
echo "$OUTPUT"
