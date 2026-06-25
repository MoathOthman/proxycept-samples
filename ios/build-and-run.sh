#!/usr/bin/env bash
# Build the Proxycept iOS demo, trust the CA in the booted Simulator, install + launch it.
#
# Env:
#   PROXY_HOST   (default 127.0.0.1)   proxy host the app connects to
#   PROXY_PORT   (default 19345)       proxy port (from the profile's Connection tab)
#   CA_PEM       (required)            path to the Proxycept CA cert (PEM)
#   SIM_UDID     (default: booted)     target simulator UDID
set -euo pipefail
cd "$(dirname "$0")"

PROXY_HOST="${PROXY_HOST:-127.0.0.1}"
PROXY_PORT="${PROXY_PORT:-19345}"
BUNDLE_ID="com.proxycept.iosdemo"

# Resolve the target simulator (booted one by default).
if [[ -n "${SIM_UDID:-}" ]]; then UDID="$SIM_UDID"; else
  UDID=$(xcrun simctl list devices booted -j | python3 -c "import sys,json;d=json.load(sys.stdin);print([x['udid'] for r in d['devices'].values() for x in r if x['state']=='Booted'][0])")
fi
echo "==> Simulator: $UDID"

echo "==> Generating Xcode project (xcodegen)"
xcodegen generate >/dev/null

echo "==> Building for the Simulator"
xcrun xcodebuild -project ProxyceptDemo.xcodeproj -scheme ProxyceptDemo \
  -sdk iphonesimulator -configuration Debug -destination "id=$UDID" \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO build >/dev/null
APP="build/Build/Products/Debug-iphonesimulator/ProxyceptDemo.app"

if [[ -n "${CA_PEM:-}" ]]; then
  echo "==> Trusting the Proxycept CA in the Simulator"
  xcrun simctl keychain "$UDID" add-root-cert "$CA_PEM"
else
  echo "!! CA_PEM not set — HTTPS will fail validation until the CA is trusted." >&2
fi

echo "==> Installing + launching (proxy ${PROXY_HOST}:${PROXY_PORT})"
xcrun simctl install "$UDID" "$APP"
xcrun simctl launch "$UDID" "$BUNDLE_ID"
echo "==> Done. The app fires the request on launch; check Proxycept → Sessions."
