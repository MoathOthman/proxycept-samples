# Proxycept Logging KMP

Independent MIT source SDK: common Kotlin queue/admission/delivery code, JVM and
Android actuals, and native iOS actuals. Package: `com.proxycept.logging.kmp`.
The existing `sdks/kotlin` and `sdks/swift` SDKs are independent and unchanged.
No private backend source is included. Nothing is published automatically.

## Toolchain and supported targets

Pinned build: **Kotlin 2.3.21, Gradle 8.13, AGP 8.13.2, JDK 17**.
Runtime targets: JVM Java 8+, **Android API 26+**, iOS 14+ arm64 device and
arm64 simulator. Intel simulator is not currently a target. Android consumers
need a compatible Kotlin compiler/AGP; do not include this module in a build
that pins an older Kotlin plugin without aligning the host toolchain.

This standalone module deliberately uses a newer compiler than the old JVM
SDK: installed Xcode is 26.3 with iOS SDK 26.2. The official
[KMP compatibility table](https://kotlinlang.org/docs/multiplatform/multiplatform-compatibility-guide.html)
and [stable releases](https://kotlinlang.org/docs/releases.html) were checked;
Kotlin 2.1.0 lists Xcode 16, while 2.3.21 supports the Xcode 26 toolchain family.
Both arm64 iOS frameworks were built with the installed toolchain. No global
Java, Xcode selection, Android settings, or existing SDK versions are changed.

Common dependencies: coroutines 1.10.1, serialization JSON 1.8.0, datetime 0.6.2,
Okio 3.9.1. JVM/Android additionally use OkHttp 4.12.0. iOS uses Foundation
`NSURLSession` directly. JSON uses tree APIs, without serialization codegen.
Android minimum 26 accommodates datetime's `java.time` usage without asking
consumers to configure core library desugaring. Tests' `java.nio.file` imports
are JVM-only; Android runtime code uses `java.io`/Okio.

## Common API

Initialize once on an I/O/lifecycle worker: constructor performs bounded private
file recovery, establishes directory ownership, and sanitizes recovered events.
All runtime disk writes and transport run on the SDK's serialized worker.
`log`, `flush`, `disable`, and `close` do not perform disk/network I/O on callers.
No worker holds the state lock over disk writes, transport, or application redactors.

```kotlin
import com.proxycept.logging.kmp.*

val logger = ProxyceptLogger(Configuration(
    baseUrl = "https://logs.example.com", // origin only
    ingestKey = provisionedIngestOnlyKey,
    spoolDirectory = appPrivateNoBackupPath, // dedicated absolute directory
    appVersion = "1.0",
    build = "12"
))

// Safe on UI thread: bounded in-memory copy, validation/redaction, admission.
val admitted = logger.log(Level.INFO, "checkout", "Checkout tapped",
    mapOf("screen" to "checkout", "attempt" to 1), correlationId = explicitId)
logger.flush() // async/coalesced; respects backoff
val stats = logger.stats()
logger.disable() // immediate memory/dispatch disable; ordered disk clear on worker
// logger.reconfigure(newConfiguration) // same directory/origin; resumes auth stop/disable
logger.close() // immediate admission/dispatch stop; cancels active request, persists final state
// From a coroutine: logger.awaitClosed() // waits for final persistence attempt and lease release
```

`true` from `log` means admitted into bounded memory, not committed to disk or
server. Process death before worker persistence can lose new memory-only events.
Storage failures are counted; retained memory is retried on subsequent tick,
log, or flush before upload. `close` attempts to persist all pending events;
check `storageFailures` after `awaitClosed`. It does not request final delivery.
Use `flush` and inspect delivery stats if a committed upload matters first.

Only finite primitive numeric values in inclusive **[-1e308, 1e308]**, booleans,
strings, and null are allowed. Empty attribute names, nested/custom objects and
out-of-range/nonfinite numbers reject the event without poisoning valid batch
neighbors. At most 16 attributes; keys 64, string values 512, category 80,
message 4096, correlation ID 128 characters. Strings are clipped without
splitting a trailing UTF-16 surrogate. Events over 8192 UTF-8 bytes reject.
Empty correlation IDs normalize to JSON null, including IDs erased by an
additional redactor or clipping and legacy spool recovery. Installation/session
metadata identifiers must remain nonempty (1–128) after redaction/clipping;
invalid new events reject and invalid legacy records drop individually, keeping
valid neighboring records and their stable event IDs.
Use a fast CPU-only `Redactor` for extra policy; its callback runs on `log`'s
caller outside the state lock. Do not put I/O in that callback.

See `examples/common/Example.kt` for a small factory/admission example.

## Android integration

Use Gradle 8.13/JDK 17, Kotlin 2.3.21 and AGP 8.13.2 in a compatible host build.
Include the source module in settings and consume its Android variant:

```kotlin
// settings.gradle.kts; repositories need google() and mavenCentral()
include(":loggingKmp")
project(":loggingKmp").projectDir = file("path/to/sdks/kotlin-multiplatform")
// Root plugins block may declare these versions with apply false so versions
// are known when Android/KMP plugins share the host classpath:
// kotlin("multiplatform") version "2.3.21" apply false
// id("com.android.library") version "8.13.2" apply false

// app/build.gradle.kts
android { defaultConfig { minSdk = 26 } }
dependencies { implementation(project(":loggingKmp")) }
```

Initialize off UI with `File(context.noBackupFilesDir, "proxycept-kmp-myapp-dev").absolutePath`.
The library manifest supplies INTERNET. `noBackupFilesDir` is recommended;
`cacheDir` is an alternative when OS eviction is acceptable. Never use public,
external/shared storage. Ordinary `filesDir` needs explicit host backup exclusions.
Directory is owner-only and each payload file is made 0600 **before writing**.
No key is placed in preferences, Android keystore, files, build config, or APK.
Provision a disposable ingest-only credential at runtime for development.

Call `log` from UI callbacks; keep one logger in application scope rather than
an Activity. `close` is nonblocking; await `awaitClosed` in your lifecycle coroutine
before reopening the same spool. No WorkManager/service or permission dialogs
are installed. See `examples/android/Example.kt` and
[Android private storage](https://developer.android.com/training/data-storage/app-specific).

## iOS / Swift integration

On macOS build both frameworks (commands below). Link the correct static
`ProxyceptLoggingKmp.framework`; use **Do Not Embed** for a static framework.
For a distributable local bundle, combine the device and simulator frameworks
using `xcodebuild -create-xcframework` into the module's ignored `build` folder.
The containing Xcode project owns signing, deployment configuration, and app lifecycle.

`examples/ios/BridgeCompile.swift` is typechecked against the generated simulator
framework. Use the default-argument-free Swift factory and scalar JSON bridge:

```swift
import Foundation
import ProxyceptLoggingKmp

// Initialize on your background lifecycle queue, using an Application Support
// child directory unique to this app/backend/environment.
let client = LoggingSdk.shared.create(baseUrl: origin, ingestKey: runtimeKey,
    spoolDirectory: supportURL.appendingPathComponent("proxycept-kmp-dev").path,
    appVersion: "1.0", build: "12")
_ = client.logJson(level: Level.info, category: "checkout", message: "Checkout tapped",
    attributesJson: #"{"screen":"checkout"}"#, correlationId: explicitCorrelationId)
client.flush()
// At lifecycle shutdown:
client.close() // nonblocking, including cancellation of in-flight transport
client.awaitClosed { error in /* directory released; inspect delivery stats */ }
```

Native spool uses owner-only directory/files, backup exclusion on the directory,
and `NSFileProtectionCompleteUntilFirstUserAuthentication` before payload writes.
No promise of hardware-backed encryption or delivery while the device is locked.
Use a separate directory per app/environment. iOS network/ATS settings remain the
host app's responsibility; local HTTP tests may require an appropriate narrowly
scoped local-development ATS policy. Do not disable ATS globally for production.

## Delivery, privacy, lifecycle

* Frozen schema version 1, POST `/api/logs/ingest`, explicit Bearer ingest key;
  JSON without request compression. No swizzling, request capture, global headers,
  VPN, automatic body collection, or authenticated console session reuse.
* HTTPS required except exact numeric loopback 127.0.0.1 / ::1. No userinfo,
  query, fragment, or base path. All redirects are refused, including same-origin
  and TLS downgrade redirects. OkHttp disables HTTP/SSL redirects, cookies,
  authenticators and disk cache; platform TLS trust/hostname validation remains.
  iOS uses an ephemeral session with cookies/cache/credential storage disabled
  and a delegate refusing every redirected request before dispatch.
* **10-second whole-call deadline** covers connect, writes, headers and full bounded
  acknowledgement consumption, independent of per-read progress. JVM async OkHttp
  cancellation actively closes the call socket; coroutine cancellation is wired
  to `Call.cancel()`, not merely a timeout around a blocking read. Apple cancellation
  cancels the captured NSURLSession task/session. Disable, close and reconfigure
  cancel the captured coroutine request, never a later generation's request.
  Cancelling transport hooks executes off the caller/state lock.
* Batches at most 50 events / 256 KiB. Only HTTP 200 with integer nonnegative
  accepted+duplicate equal to attempted count and parseable ISO received_at removes
  the atomic batch. Event IDs remain stable across retries/recovery. Invalid acks
  retain all events. Request already committed before cancellation can replay
  safely through server deduplication; cancellation cannot undo a server commit.
* 401/403 stop until reconfigure; 429 honors numeric/HTTP-date Retry-After;
  network/5xx/408 back off exponentially with jitter (0.5–60s). 413 halves batches
  then drops a rejected single event. Other 4xx/refused redirects drop attempted
  events. Timeout/cancel due lifecycle cannot apply stale acknowledgements to a
  changed generation. Timeouts during normal operation leave events retryable.
* Queue maximum 2 MiB of serialized records / 2000 events, whichever first; optional
  smaller bounds. Drop oldest with explicit counter; expire after 3 days, including
  periodic housekeeping during auth suspension. Scheduler cadence is 2s while the
  process lives. There is no OS background delivery guarantee.
* Redaction precedes every first payload write, recovery rewrite, and upload.
  Built-in masks sensitive keys, bearer/ingest tokens, secret assignments and
  whitespace-delimited tokens containing @ (conservative best effort). Additional
  redactor runs between built-in passes. It cannot guarantee PII detection;
  never intentionally log secrets. Key/configuration never enters spool records.
* Snapshot I/O is serialized with revision/generation checks outside the short
  state lock. Coalesced wake channel has capacity one even during blocked I/O.
  Memory is bounded by the live queue, one immutable snapshot, a batch, and
  JSON/object overhead. Temp replacement can transiently use one extra queue-sized
  disk file. Files are fsynced before atomic rename; no claim against every
  power-loss/filesystem failure. Corrupt entries are discarded independently;
  oversized files reset. Advisory lease prevents concurrent owners.
* Disable clears memory immediately and queues an ordered empty snapshot; a stale
  snapshot cannot overwrite that final clear. Await close before reopening to
  wait for that clear. Process kill/storage failure before an asynchronous clear
  reaches disk can leave older durable data. Stats count storage failures and
  pending persistence; counters other than recovered drops are process-local.
* Installation UUID is stored privately; debug session UUID is new per config by
  default. App/build/session/installation metadata is untrusted display metadata.
  Recovered records keep original metadata. Same origin/directory is required
  for reconfigure; caller must ensure a rotated key belongs to the same app.

## Build and tests

Run from this folder with Gradle **8.13**, JDK 17, Android SDK 35, and Xcode 26.x.
To keep caches in this module (no global installation):

```sh
export JAVA_HOME="$(/usr/libexec/java_home -v 17)"
export ANDROID_HOME="$HOME/Library/Android/sdk"
export GRADLE_USER_HOME="$PWD/.gradle-user-home"
export KONAN_DATA_DIR="$PWD/.konan"
# Use installed Gradle 8.13, not system Gradle 9.5.1:
GRADLE=gradle  # Gradle 8.13 (no wrapper is checked in)
"$GRADLE" --no-daemon jvmTest assembleDebug lintDebug \
  linkDebugFrameworkIosSimulatorArm64 linkDebugFrameworkIosArm64 \
  linkDebugTestIosSimulatorArm64 prepareLocalSmoke
sh scripts/native-tests.sh
```

Native test script uses only its own simulator device set under `build`, starts
an isolated local stub HTTP server, injects its nonsecret loopback URL with
SIMCTL_CHILD, executes the compiled native test binary, then deletes only its
own test device. It does not use any shared booted simulator or physical device.
The optional native HTTP tests print SKIPPED if run without that fixture; the
script supplies it and verifies actual NSURLSession POST, redirect refusal,
slow-response cancellation and ordered privacy clearing. `iosSimulatorArm64Test`
is also available through Gradle for ordinary common/native tests on a selected
simulator, but the script provides isolated ownership and the HTTP fixture.

JVM tests include real loopback delivery/redirect checks, slow trickle total
call deadlines, blocked request write cancellation and deadline tests, retry IDs,
nonblocking blocked storage, private modes, recovery and mixed valid neighbors.
Common tests consume `../conformance/attribute-vectors.json` via a development-only
generated test source (all 10 cases, fresh/mixed and legacy recovery). That
fixture and its loader are not packaged in SDK artifacts.

Outputs (ignored, never source-controlled): Android AAR under `build/outputs/aar`,
JVM JAR under `build/libs`, static iOS frameworks under `build/bin`, test reports
under `build/reports`. Build/toolchain logs and caches are ignored; handoff
removes temporary top-level build logs.

## Explicit local backend smoke

Prepare the JVM classpath once with `prepareLocalSmoke`. Main/coordinator exports
these environment variables in memory: PROXYCEPT_TEST_BASE_URL (numeric loopback,
for example http://127.0.0.1:18880), PROXYCEPT_TEST_INGEST_KEY, a random
PROXYCEPT_TEST_DEBUG_SESSION, and an app-private PROXYCEPT_TEST_SPOOL_DIR.
No credential command-line arguments or token files are accepted/generated.
Then run:

```sh
JAVA_HOME="$(/usr/libexec/java_home -v 17)" \
  sh scripts/local-smoke.sh
```

Runner emits category `kmp-integration`, message `Cross-platform SDK smoke`,
attributes password=`must-be-redacted` (redacted before disk), waits for a valid
committed ack and empty queue, and prints only a nonsecret PASS. This exercises
common core + JVM transport against the actual local backend. It is **not**
physical Android delivery or Swift bridge/backend E2E. Native local stub tests
separately exercise the actual Apple transport; Swift example typechecking is
compile proof. Coordinator owns any real mobile app/backend cross-integration.
