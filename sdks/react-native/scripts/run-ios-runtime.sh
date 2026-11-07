#!/bin/sh
# Operator/main-task only. This script DOES install and launch on the specified
# already-booted simulator; building/bundling the SDK does not invoke it.
set -eu
: "${PROXYCEPT_SIMULATOR_UDID:?Choose the already-booted simulator explicitly}"
: "${PROXYCEPT_TEST_CONFIG_URL:=http://127.0.0.1:18881/sdk-test-config}"
rn_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
app="$rn_root/.build/ios/Build/Products/Debug-iphonesimulator/ProxyceptRNExample.app"
xcrun simctl install "$PROXYCEPT_SIMULATOR_UDID" "$app"
SIMCTL_CHILD_PROXYCEPT_TEST_CONFIG_URL="$PROXYCEPT_TEST_CONFIG_URL" \
  xcrun simctl launch --terminate-running-process "$PROXYCEPT_SIMULATOR_UDID" com.proxycept.reactnative.example
# Give the host's independent ingest assertion time to observe JS-driven delivery.
sleep 6
printf '%s\n' 'Launched RN runtime example; verify committed ingest and logging-status UI separately'
