#!/bin/sh
# Builds shmivanvpn.app with only the Xcode Command Line Tools (no Xcode needed).
#   ./build.sh            -> build/shmivanvpn.app
#   ./build.sh install    -> also copies it to /Applications
set -eu
cd "$(dirname "$0")"

XRAY_VERSION="${XRAY_VERSION:-v26.10.21}"
case "$(uname -m)" in
  arm64) XRAY_ZIP=Xray-macos-arm64-v8a.zip ;;
  x86_64) XRAY_ZIP=Xray-macos-64.zip ;;
  *) echo "unsupported arch" >&2; exit 1 ;;
esac
VENDOR="vendor/xray-$XRAY_VERSION"

# 1. Fetch Xray-core from the official GitHub release and verify its SHA-256.
if [ ! -x "$VENDOR/xray" ]; then
  echo "==> Downloading Xray-core $XRAY_VERSION"
  rm -rf "$VENDOR"; mkdir -p "$VENDOR"
  base="https://github.com/XTLS/Xray-core/releases/download/$XRAY_VERSION"
  curl -fsSL -o "$VENDOR/xray.zip" "$base/$XRAY_ZIP"
  curl -fsSL -o "$VENDOR/xray.zip.dgst" "$base/$XRAY_ZIP.dgst"
  want=$(grep -i '^SHA2-256' "$VENDOR/xray.zip.dgst" | awk '{print $2}')
  have=$(shasum -a 256 "$VENDOR/xray.zip" | awk '{print $1}')
  [ "$want" = "$have" ] || { echo "checksum mismatch: $have != $want" >&2; exit 1; }
  unzip -q -o "$VENDOR/xray.zip" xray geoip.dat geosite.dat -d "$VENDOR"
  rm "$VENDOR/xray.zip" "$VENDOR/xray.zip.dgst"
  chmod +x "$VENDOR/xray"
fi

# 2. Compile.
echo "==> Compiling"
swift build -c release
BIN="$(swift build -c release --show-bin-path)/VPNBar"

# 3. Assemble the bundle.
echo "==> Assembling build/shmivanvpn.app"
APP=build/shmivanvpn.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/shmivanvpn"
cp Support/Info.plist "$APP/Contents/Info.plist"
cp "$VENDOR/xray" "$VENDOR/geoip.dat" "$VENDOR/geosite.dat" "$APP/Contents/Resources/"
cp Support/icon/AppIcon.icns Support/icon/menubar-face.png "$APP/Contents/Resources/"
cp Support/vpnbar-tun.sh Support/install-helper.sh Support/uninstall-helper.sh "$APP/Contents/Resources/"
# Seed the first launch with the links in .env (imported once, then stored in ~/Library/Application Support/shmivanvpn).
[ -f .env ] && cp .env "$APP/Contents/Resources/default.env"

# 4. Self-test: generated configs must pass `xray -test`.
echo "==> Self-test"
for mode in proxy tun; do
  if [ -f .env ]; then
    "$APP/Contents/MacOS/shmivanvpn" --print-config .env $mode > build/selftest-$mode.json
    XRAY_LOCATION_ASSET="$APP/Contents/Resources" "$APP/Contents/Resources/xray" run -test -c build/selftest-$mode.json >/dev/null \
      && echo "   $mode config OK" || { echo "   $mode config FAILED"; exit 1; }
  fi
done
rm -f build/selftest-*.json

# 5. Ad-hoc sign so macOS runs it locally.
xattr -cr "$APP"
codesign --force --sign - "$APP/Contents/Resources/xray"
codesign --force --sign - "$APP"

if [ "${1:-}" = "install" ]; then
  pkill -x shmivanvpn 2>/dev/null || true
  pkill -x VPNBar 2>/dev/null || true  # pre-rename build
  rm -rf /Applications/shmivanvpn.app /Applications/VPNBar.app
  cp -R "$APP" /Applications/
  echo "==> Installed to /Applications/shmivanvpn.app"
fi
echo "==> Done: $APP"
