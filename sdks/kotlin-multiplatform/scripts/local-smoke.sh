#!/bin/sh
set -eu
# Never enable shell tracing here: the credential exists only in inherited environment.
: "${PROXYCEPT_TEST_BASE_URL:?Missing local test base URL}"
: "${PROXYCEPT_TEST_INGEST_KEY:?Missing local test ingest key}"
: "${PROXYCEPT_TEST_DEBUG_SESSION:?Missing random test session}"
: "${PROXYCEPT_TEST_SPOOL_DIR:?Missing private test spool directory}"
task_root=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
if [ ! -f "$task_root/build/smoke-classpath.txt" ]; then
    echo 'Run Gradle prepareLocalSmoke first.' >&2
    exit 1
fi
if [ -n "${JAVA_HOME:-}" ]; then task_java="$JAVA_HOME/bin/java"; else task_java=java; fi
exec "$task_java" -cp "$(cat "$task_root/build/smoke-classpath.txt")" com.proxycept.logging.kmp.LocalSmokeKt
