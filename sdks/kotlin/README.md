# Proxycept Kotlin / Android logging SDK

MIT source SDK, Kotlin/JVM with Java 8 bytecode, usable on Android API 21+.
No Android dependency in the core; runtime dependencies are Kotlin stdlib and
Gson 2.11.0. Build uses Kotlin 2.1.0; align the consuming build's Kotlin plugins
to this version. No backend code, automatic HTTP interception, VPN, global hooks,
request body collection, or implicit header injection. The SDK implements the
frozen schema-version-1 logging contract.

## Add to an Android app

Include this folder as a Gradle project (or vendor this SDK source):

```kotlin
// settings.gradle.kts
include(":proxyceptLogging")
project(":proxyceptLogging").projectDir = file("path/to/sdks/kotlin")

// Root build.gradle.kts plugins block, when Android Kotlin is also applied:
// kotlin("jvm") version "2.1.0" apply false

// app/build.gradle.kts
// The consuming build needs mavenCentral().
dependencies { implementation(project(":proxyceptLogging")) }
```

Add `<uses-permission android:name="android.permission.INTERNET" />` to your
manifest. Create one logger per app/environment, using a dedicated private
folder. Use `noBackupFilesDir` for durable events excluded from Android backup,
or `cacheDir` when OS eviction is acceptable. Do not use external/shared
storage or ordinary `filesDir` without an explicit backup exclusion.
[Android app-specific storage](https://developer.android.com/training/data-storage/app-specific)
describes these locations.

```kotlin
import com.proxycept.logging.Configuration
import com.proxycept.logging.Level
import com.proxycept.logging.ProxyceptLogger
import com.proxycept.logging.Redactor
import java.io.File

// Usually create once in Application scope. Provision an ingest-only key at
// runtime; never use a console/session JWT. This SDK does not store the key.
val logger = ProxyceptLogger(Configuration(
    baseUrl = "https://logs.example.com", // origin, no path/query/credentials
    ingestToken = runtimeIngestKey,
    directory = File(context.noBackupFilesDir, "proxycept-logs-myapp-dev"),
    // Alternative: File(context.cacheDir, "proxycept-logs-myapp-dev")
    appVersion = BuildConfig.VERSION_NAME,
    build = BuildConfig.VERSION_CODE.toString(),
    redactor = Redactor { text -> text.replace("internal-order-123", "[REDACTED]") }
))

val queued = logger.log(
    level = Level.INFO,
    category = "checkout",
    message = "Checkout tapped",
    attributes = mapOf("screen" to "checkout", "retry" to false),
    correlationId = explicitCorrelationId // optional, supplied by the app
)
logger.flush() // async, coalesced; honors delivery backoff
val delivery = logger.stats()
// logger.disable() // stops delivery, clears the queue; reconfigure to enable
// On an I/O/lifecycle worker: logger.close() // persists pending memory; no delivery request
```

`log()` is safe to call on the UI thread: it copies scalar attributes, redacts,
serializes one bounded event, and enqueues it in bounded memory. It performs no
file/network I/O, and no worker holds the logger state lock across I/O. Keep a
custom `Redactor` fast and CPU-only, since it runs on the logging caller outside
the lock. Calls to `flush` and `disable` also only update memory/schedule work.
One serialized background worker persists immutable snapshots and performs
transport. It coalesces requests while storage/network is blocked, without an
unbounded executor backlog. Events are not sent until persistence succeeds.

Constructor/recovery and `reconfigure`'s canonical-path validation can perform
local I/O; initialize/configure on your I/O dispatcher. `close` is a blocking
lifecycle barrier that waits for outstanding worker I/O, persists the latest
pending memory snapshot, and releases the spool lock. Call it off the UI thread.
Other logging callers still return promptly while close waits. It does not
request delivery. A request already dispatched may finish, and its stale
acknowledgement cannot remove events from a new configuration generation.

Automatic delivery runs every two seconds while the process is alive. This is
not Android WorkManager: there is no delivery while the app process is
suspended/killed. `flush` returns immediately and is not a durability or delivery
barrier. A process crash before the worker persists a newly accepted event can
lose that memory-only event. Normal `close` attempts to persist pending events;
storage failures are observable in stats and may prevent durability.

`Level` is DEBUG / INFO / WARNING / ERROR. Optional adapters should map verbose
to DEBUG. Attributes accept only null, strings, booleans, and finite primitive
numbers in the inclusive range -1e308 through 1e308, matching ingest validation.
Unsupported nested/custom objects and nonfinite or out-of-range numbers reject the
event. `log` returns true when accepted into bounded memory, before durability or delivery. Invalid or
oversized events return false and increment dropped. Closed/disabled/auth-stopped
instances return false. Worker storage failures increment `storageFailures`; they cannot retroactively
change the return value of `log`. The bounded memory queue is retained and
persistence retries on the next scheduled tick, log, or flush, before delivery.

## Delivery, limits, and privacy

* POST `/api/logs/ingest`, Bearer ingest credential, uncompressed JSON. Platform
  TLS trust and hostname verification; HTTPS required except numeric loopback
  `127.0.0.1` / `::1` for tests. DNS names including localhost are not a cleartext
  exception. All redirects are refused, including same-origin ones, so redirect
  targets never receive the credential. Custom `Transport` implementations must
  preserve these requirements. See
  [HttpURLConnection redirects](https://docs.oracle.com/javase/8/docs/api/java/net/HttpURLConnection.html#setInstanceFollowRedirects-boolean-).
* Up to 50 events and 256 KiB per batch, up to 8192 serialized bytes per event.
  Category/app/build and IDs follow the contract limits. Message/category/string
  attributes are truncated; at most 16 attributes, names 64, values 512, message
  4096, correlation ID 128 characters. Oversize UTF-8 events are rejected.
* Queue defaults: 2000 events / 2 MiB of serialized spool records, whichever
  comes first. Smaller bounds are configurable. Drop oldest on overflow;
  three-day expiry, including during auth suspension while scheduling runs.
  Memory is bounded by the live queue plus one immutable queue-sized snapshot,
  one bounded batch, and JSON/object overhead; no unbounded executor backlog from calls to flush/log.
* Redaction runs **before the first disk write** and again on recovery with the
  current policy. Built-in protection masks sensitive attribute keys, bearer
  tokens, ingest-token patterns, secret assignments, and common email addresses.
  An optional additional redactor runs between two built-in passes. This is
  best effort, not perfect PII detection: never intentionally log secrets/PII.
  Only events/metadata, an installation UUID, and a lock file are stored;
  configuration and credentials are never persisted. Stats omit content/keys.
* Dedicated app-private spool uses a single-process file lock, fsync + atomic
  snapshot replacement; corrupt lines are discarded, oversized files reset.
  A snapshot replacement transiently uses up to another queue-sized temp file.
  Crash retries keep event IDs for server deduplication. Acknowledged removal
  may fail on bad storage and cause a safe deduplicated retry after restart.
  Disk failures are counted; durability/queue deletion cannot be guaranteed on
  failing storage. Spool is not separately encrypted; rely on app-private OS
  protection. No hardware keystore or device-lock storage integration.
* Only HTTP 200 with integer accepted+duplicate equal to batch size and an ISO
  received_at is treated as a committed atomic acknowledgement. Malformed or
  partial acknowledgements retain all events. Network/5xx/408 failures retry with
  exponential jitter (0.5–60 seconds); 429 honors Retry-After seconds/HTTP date.
  413 halves the attempted batch, dropping a single event if still rejected.
  Other 4xx and refused redirects drop the attempted batch and count it.
* 401/403 stop ingestion and new logging until `reconfigure(Configuration(...))`.
  Reconfigure allows only the same origin and directory. Use a separate folder
  for each app/backend/environment, including across process restarts; the SDK
  cannot tell which app a rotated token belongs to. Saved events retain original
  app/build/installation/session metadata; new runs get a new debug session UUID.
  Metadata is not authenticated identity. Credentials are held only in memory.
* `disable` immediately clears memory and prevents new dispatch. Its disk clear
  is serialized after any outstanding write, so an older snapshot cannot
  overwrite the final clear. Reconfigure snapshots and acknowledged removals
  follow the same revision ordering. Use `close` off the UI thread to wait for
  the final snapshot/clear before reopening the directory; killing the process
  before an asynchronous clear reaches disk can leave an old durable snapshot.
  `close` retains queued events and attempts to persist memory-only events.
  Neither method can retract a request already dispatched. Stats are process-local counters plus current
  queue bytes/count, retries/storage errors, flags, and next attempt time.
  Persisted sequence values stay stable on retry; each new debug session starts
  its own sequence. OS cache eviction resets installation ID and queue.

## Build and JVM tests

JDK 17, Gradle 8.11.1; no Android SDK is needed for core:

```sh
cd sdks/kotlin
gradle --no-daemon clean test jar
```

Tests use fake transport/clock and real loopback HTTP. They cover wire JSON,
pre-spool redaction, count/byte limits, durable/corrupt recovery, batching,
ack/deduplication, offline jitter/backoff, Retry-After, authentication suspension,
413, expiry/disable/close, concurrent logging, async flush, directory locks,
blocked/failing storage without caller stalls, bounded concurrent enqueue,
ordered disable/reconfigure snapshots, acknowledgement-write races, and close barriers,
URL/token rejection, and real POST/redirect credential protection. HTML report:
`build/reports/tests/test/index.html`; JAR: `build/libs/proxycept-logging-0.1.0.jar`.

## Isolated Android demo and instrumentation

`demo` is a separate Gradle project, package **com.proxycept.loggingdemo**;
it does not modify existing apps or device settings. It has no embedded token.
Requires local Android SDK platform 35/build tools and Gradle 8.11.1, JDK 17:

```sh
gradle --no-daemon -p demo assembleDebug assembleDebugAndroidTest
```

Outputs: `demo/build/outputs/apk/debug/demo-debug.apk` and
`demo/build/outputs/apk/androidTest/debug/demo-debug-androidTest.apk`.
Only the person owning the device should execute the commands below. For a
local API on port 18880, first arrange an adb reverse to the host (device owner):

```sh
adb -s DEVICE reverse tcp:18880 tcp:18880
adb -s DEVICE install -r demo/build/outputs/apk/debug/demo-debug.apk
adb -s DEVICE install -r demo/build/outputs/apk/androidTest/debug/demo-debug-androidTest.apk
adb -s DEVICE shell am instrument -w \
  -e baseUrl http://127.0.0.1:18880 -e token "$INGEST_TOKEN" \
  -e correlationId android-instrumentation-smoke \
  com.proxycept.loggingdemo.test/com.proxycept.loggingdemo.SmokeInstrumentation
```

The custom instrumentation needs no test framework dependency. It creates an
isolated no-backup spool, checks pre-write redaction, sends one explicit event,
checks redacted persistence at the transport boundary, waits up to 15 seconds
for a committed acknowledgement, reports
`proxycept_result=PASS` / result code -1, and deletes its spool. The device owner
should confirm the matching correlation ID in the local backend. Arguments can
be visible to local shell/process inspection; use a disposable development key.
To use the manual screen instead, launch the app with `am start -n
com.proxycept.loggingdemo/.MainActivity --es token "$INGEST_TOKEN" --es baseUrl
http://127.0.0.1:18880`; it sends one event and provides send/disable buttons.
The demo permits cleartext only to numeric IPv4 loopback on API 24+; the core
also enforces its URL policy on every platform. Do not reuse demo cleartext
settings in a production application.

Actual device execution is intentionally left to the coordinating device owner;
compiling APKs or passing JVM tests does not establish device/backend E2E success.
