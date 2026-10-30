#!/usr/bin/env bash
set -euo pipefail
# Main/device owner executes this. No key is read, echoed or passed as an argument.
: "${PROXYCEPT_TEST_DEVICE:?Select the operator-owned simulator/device ID}"
: "${PROXYCEPT_TEST_CONFIG_URL:=http://127.0.0.1:18881/sdk-test-config}"
FLUTTER_BIN="${PROXYCEPT_FLUTTER_BIN:-/private/tmp/proxycept-flutter/bin/flutter}"
SDK_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$SDK_DIR/example"
export FLUTTER_SUPPRESS_ANALYTICS=true
exec "$FLUTTER_BIN" --suppress-analytics test integration_test/local_api_test.dart \
  --device-id "$PROXYCEPT_TEST_DEVICE" \
  --dart-define="PROXYCEPT_TEST_CONFIG_URL=$PROXYCEPT_TEST_CONFIG_URL"
