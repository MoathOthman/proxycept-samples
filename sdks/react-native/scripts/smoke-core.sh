#!/bin/sh
set -eu
# No compiler/package manager may inherit the runtime ingest key.
: "${PROXYCEPT_TEST_BASE_URL:?Set loopback test origin}"
: "${PROXYCEPT_TEST_INGEST_KEY:?Set test ingest key}"
: "${PROXYCEPT_TEST_DEBUG_SESSION:?Set random debug session}"
: "${PROXYCEPT_TEST_SPOOL_DIR:?Set dedicated private spool root}"
rn_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
binary="$rn_root/.build/swift/debug/ProxyceptRNSmoke"
if [ ! -x "$binary" ]; then
  printf '%s\n' 'Prepare the native smoke binary first with npm run prepare:smoke (without runtime credentials)' >&2
  exit 1
fi
exec "$binary"
