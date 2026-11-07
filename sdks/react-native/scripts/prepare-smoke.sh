#!/bin/sh
set -eu
# Strip all runtime test configuration before any build tool starts.
unset PROXYCEPT_TEST_INGEST_KEY PROXYCEPT_TEST_DEBUG_SESSION PROXYCEPT_TEST_SPOOL_DIR PROXYCEPT_TEST_BASE_URL PROXYCEPT_TEST_CONFIG_URL
rn_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/private/tmp/proxycept-rn-module-cache}"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
exec swift build --disable-sandbox --package-path "$rn_root/ios" \
  --scratch-path "$rn_root/.build/swift" --product ProxyceptRNSmoke
