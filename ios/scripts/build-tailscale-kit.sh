#!/bin/sh
# Build TailscaleKit.xcframework from upstream libtailscale (M8 T3).
#
# Chain: clone libtailscale (pinned commit) -> go c-archive for iOS device +
# simulator (upstream's own Makefile targets and clangwrap scripts, so any
# drift in upstream's build shape fails here, not on the phone) -> xcodebuild
# TailscaleKit.framework per platform -> xcodebuild -create-xcframework.
#
# Versions are pinned because the Go/tailscale-core pairing has broken before
# (pub.dev ecosystem precedent; docs/dev/plans/M8-cross-network.md §八). To
# upgrade: bump GO_VERSION / LIBTAILSCALE_REF, delete the clone, rerun.
#
# Usage: ios/scripts/build-tailscale-kit.sh   (outputs to ios/Frameworks/)
set -eu

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT_DIR="$REPO_ROOT/ios/Frameworks"

GO_VERSION=1.25.5
GO_ROOT="$HOME/sdks/go/$GO_VERSION"
LIBTAILSCALE_REF=59d4bb82744915815178e0f0776d60026a397ee7
LIBTAILSCALE_SRC="$HOME/sdks/src/libtailscale"

# --- toolchain: the pinned Go, fetched on first run -------------------------
if [ ! -x "$GO_ROOT/bin/go" ]; then
  echo "==> Go $GO_VERSION not found, installing to $GO_ROOT"
  mkdir -p "$HOME/sdks/go"
  TAR="$HOME/sdks/go/go$GO_VERSION.darwin-arm64.tar.gz"
  curl -sL -o "$TAR" "https://go.dev/dl/go$GO_VERSION.darwin-arm64.tar.gz"
  EXTRACT="$HOME/sdks/go/.extract.$$"
  mkdir -p "$EXTRACT"
  tar -xzf "$TAR" -C "$EXTRACT"
  mv "$EXTRACT/go" "$GO_ROOT"
  rm -rf "$EXTRACT" "$TAR"
fi
export PATH="$GO_ROOT/bin:$PATH"
export GOPATH="$REPO_ROOT/ios/.build/gopath"  # inside the workspace: sandbox-writable and repo-local
export GOTOOLCHAIN=local                   # never let go.mod auto-download a different toolchain
export GOPROXY="${GOPROXY:-https://goproxy.cn,direct}"  # CN mirror; proxy.golang.org is unreachable from CN networks
echo "==> go $(go version)"

# --- source: pinned libtailscale (tarball, not git — a commit snapshot is
# reproducible byte-for-byte and immune to git transport quirks) -------------
if [ ! -f "$LIBTAILSCALE_SRC/.pinned-ref" ] || [ "$(cat "$LIBTAILSCALE_SRC/.pinned-ref")" != "$LIBTAILSCALE_REF" ]; then
  echo "==> fetching libtailscale @ $LIBTAILSCALE_REF"
  rm -rf "$LIBTAILSCALE_SRC"
  mkdir -p "$LIBTAILSCALE_SRC"
  TAR="$LIBTAILSCALE_SRC.tar.gz"
  curl -sL -o "$TAR" "https://github.com/tailscale/libtailscale/archive/$LIBTAILSCALE_REF.tar.gz"
  EXTRACT="$LIBTAILSCALE_SRC/.unpack.$$"
  mkdir -p "$EXTRACT"
  tar -xzf "$TAR" -C "$EXTRACT"
  mv "$EXTRACT"/libtailscale-*/* "$LIBTAILSCALE_SRC/"
  rm -rf "$EXTRACT" "$TAR"
  echo "$LIBTAILSCALE_REF" > "$LIBTAILSCALE_SRC/.pinned-ref"
fi
cd "$LIBTAILSCALE_SRC"

# --- static libs for device + simulator (upstream Makefile) ------------------
echo "==> go c-archive: iOS device (arm64)"
make c-archive-ios
echo "==> go c-archive: iOS simulator (arm64 + x86_64)"
make c-archive-ios-sim

# --- TailscaleKit.framework per platform, then the xcframework ---------------
echo "==> xcodebuild: TailscaleKit frameworks"
cd swift
make ios-fat

echo "==> collecting xcframework into $OUT_DIR"
mkdir -p "$OUT_DIR"
rm -rf "$OUT_DIR/TailscaleKit.xcframework"
cp -R "$LIBTAILSCALE_SRC/swift/build/Build/Products/Release-iphonefat/TailscaleKit.xcframework" "$OUT_DIR/"

echo "==> done: $OUT_DIR/TailscaleKit.xcframework"
