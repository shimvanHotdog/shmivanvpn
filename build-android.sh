#!/bin/sh
# Builds the shmivanvpn Android APKs.
#   ./build-android.sh            -> android/dist/*.apk
#   ./build-android.sh install    -> also installs the arm64 APK on the adb-connected phone
# Needs: JDK 21 (brew install openjdk@21) and the Android SDK (brew install --cask android-commandlinetools,
# then sdkmanager "platform-tools" "platforms;android-37.0" "build-tools;37.0.0").
set -eu
cd "$(dirname "$0")"

XRAY_VERSION="${XRAY_VERSION:-v26.10.21}"
export JAVA_HOME="${JAVA_HOME:-$(brew --prefix openjdk@21)/libexec/openjdk.jdk/Contents/Home}"
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
APP=android/app

# 1. libv2ray.aar (Xray core for Android, from 2dust/AndroidLibXrayLite), verified against GitHub's SHA-256.
AAR="$APP/libs/libv2ray.aar"
if [ ! -f "$AAR" ]; then
  echo "==> Downloading libv2ray.aar $XRAY_VERSION"
  api="https://api.github.com/repos/2dust/AndroidLibXrayLite/releases/tags/$XRAY_VERSION"
  want=$(curl -fsSL "$api" | /usr/bin/python3 -I -c 'import json,sys; print(next(a["digest"] for a in json.load(sys.stdin)["assets"] if a["name"]=="libv2ray.aar").split(":")[1])')
  curl -fsSL -o "$AAR.part" "https://github.com/2dust/AndroidLibXrayLite/releases/download/$XRAY_VERSION/libv2ray.aar"
  have=$(shasum -a 256 "$AAR.part" | awk '{print $1}')
  [ "$want" = "$have" ] || { echo "libv2ray.aar checksum mismatch" >&2; rm -f "$AAR.part"; exit 1; }
  mv "$AAR.part" "$AAR"
fi

# 2. geoip.dat / geosite.dat: reuse the macOS build's verified Xray download.
ASSETS="$APP/src/main/assets"
if [ ! -f "$ASSETS/geosite.dat" ]; then
  [ -f "vendor/xray-$XRAY_VERSION/geosite.dat" ] || ./build.sh >/dev/null
  cp "vendor/xray-$XRAY_VERSION/geoip.dat" "vendor/xray-$XRAY_VERSION/geosite.dat" "$ASSETS/"
fi

# 3. Release signing key (kept out of git). Back up android/keystore.jks: updates must be signed with the same key.
if [ ! -f android/keystore.properties ]; then
  echo "==> Creating release signing key android/keystore.jks"
  pass=$(openssl rand -hex 24)
  "$JAVA_HOME/bin/keytool" -genkeypair -keystore android/keystore.jks -alias shmivanvpn -keyalg RSA -keysize 4096 \
    -validity 10000 -storepass "$pass" -keypass "$pass" -dname "CN=shmivanvpn" >/dev/null 2>&1
  printf 'storeFile=keystore.jks\nstorePassword=%s\nkeyAlias=shmivanvpn\nkeyPassword=%s\n' "$pass" "$pass" > android/keystore.properties
  chmod 600 android/keystore.properties
fi

# 4. Build.
echo "==> Building release APKs"
(cd android && ./gradlew --quiet assembleRelease)
mkdir -p android/dist
rm -f android/dist/*.apk
VERSION=$(sed -n 's/.*versionName = "\(.*\)"/\1/p' "$APP/build.gradle.kts")
for f in "$APP"/build.nosync/outputs/apk/release/*.apk; do
  abi=$(basename "$f" .apk | sed -e 's/^app-//' -e 's/-release$//')
  cp "$f" "android/dist/shmivanvpn-$VERSION-$abi.apk"
done
ls -lh android/dist

if [ "${1:-}" = "install" ]; then
  "$ANDROID_HOME/platform-tools/adb" install -r "android/dist/shmivanvpn-$VERSION-arm64-v8a.apk"
fi
