#!/usr/bin/env bash
# Build the Proxycept Android demo and run it on a connected device/emulator.
#
# Env:
#   PROXY_HOST   (default 10.0.2.2)   host the app connects to (10.0.2.2 = emulator's host alias)
#   PROXY_PORT   (default 19345)      proxy port (from the profile's Connection tab)
#   CA_PEM       (optional)           path to your deployment's CA PEM; copied into res/raw/proxycept_ca.pem
#   JAVA_HOME    (required)           a JDK 17 (e.g. /opt/homebrew/opt/openjdk@17)
#   ANDROID_HOME (required)           Android SDK path (e.g. ~/Library/Android/sdk)
set -euo pipefail
cd "$(dirname "$0")"

: "${JAVA_HOME:?set JAVA_HOME to a JDK 17}"
: "${ANDROID_HOME:?set ANDROID_HOME to your Android SDK}"
ADB="$ANDROID_HOME/platform-tools/adb"
APP_ID="com.proxycept.androiddemo"

if [[ -n "${CA_PEM:-}" ]]; then
  echo "==> Bundling CA: $CA_PEM"
  cp "$CA_PEM" app/src/main/res/raw/proxycept_ca.pem
fi
echo "sdk.dir=$ANDROID_HOME" > local.properties

echo "==> Building debug APK"
./gradlew :app:assembleDebug --no-daemon -q

echo "==> Installing + launching (proxy ${PROXY_HOST:-10.0.2.2}:${PROXY_PORT:-19345})"
"$ADB" install -r app/build/outputs/apk/debug/app-debug.apk
"$ADB" shell am start -n "$APP_ID/.MainActivity"
echo "==> Done. The app fires the request on launch; check Proxycept → Sessions."
