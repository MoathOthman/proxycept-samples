# Proxycept logging for Flutter / Dart

MIT source SDK for **Flutter iOS and Android**, using the same schema-version-1 API
as the Swift and Kotlin SDKs. A Dart core owns its queue, redaction, storage, and
HTTP transport in a dedicated isolate; a small Flutter plugin supplies protected
mobile spool directories and a host-driven lifecycle adapter. **No web support.**
There is no interception, print capture, VPN, automatic request-header injection,
implicit request/response-body collection, or crash handler.

The tested toolchain is Flutter 3.47.9 / Dart 3.13.7, Android API 24+ / JDK 17,
and iOS 15+ / CocoaPods. These minimums follow the installed Flutter toolchain,
not the separate Kotlin SDK's API 21 target. See Flutter's
[supported-platform matrix](https://docs.flutter.dev/reference/supported-platforms).
Desktop Dart execution is used for core tests and the CLI smoke; this plugin
implements only iOS/Android. Sources are not a pub.dev release (`publish_to: none`).

## Add and initialize

Check out the public repository and depend on the nested directory:

```yaml
# Application pubspec.yaml
dependencies:
  proxycept_logging:
    path: path/to/proxycept-samples/sdks/flutter
```

Use `createMobileLogger` for native private/no-backup setup. Supply a short-lived
**ingest-only** key at runtime from your host's provisioning/secure-storage flow.
Never put a console JWT or personal API token into the logger. Never put a key in
`--dart-define`, source, assets, the URL, or a shared spool folder.

```dart
import 'package:proxycept_logging/proxycept_logging_flutter.dart';

final logger = await createMobileLogger(
  namespace: 'myapp-development', // separate per app/backend/environment
  configuration: LoggingConfiguration(
    baseUrl: Uri.parse('https://logs.example.com'), // origin only
    ingestToken: runtimeIngestKey,
    appVersion: '1.0', build: '12',
  ),
);
final lifecycle = ProxyceptLifecycleAdapter(logger);

final admitted = logger.log(
  level: LogLevel.info,
  category: 'checkout',
  message: 'Checkout tapped',
  attributes: {'screen': 'checkout', 'attempt': 1, 'guest': true},
  correlationId: explicitRequestId, // optional, supplied by application code
);
await logger.flush();
final stats = await logger.stats();
// Inspect accepted / duplicate / queued / droppedOldest / invalid /
// admissionDropped / storageFailures / failures / authStopped; not log content.

// At an owned, normal shutdown when OS execution time is available:
lifecycle.dispose();
await logger.close();
```

Retain one logger per spool directory. Initialization is asynchronous: native
filesystem work runs on platform I/O queues; queue/file/network work runs in a
worker isolate. `log` performs only bounded scalar validation, copying and
redaction on the caller, with **no file or network I/O**. It accepts at most 32
unacknowledged admissions; overflow returns false and increments
`admissionDropped`. Invalid scalar/Unicode inputs return false. A true return is
**admission only**: worker validation, disk failures, process death, or later
expiry/overflow can still prevent persistence/delivery. Events over 8,192 bytes
are rejected by the worker and reflected in `invalid`.

`flush()` is coalesced, respects retry delays, and attempts up to ten batches per
call; another foreground tick can continue. It is not an unconditional delivery
or durability barrier. `close()` stops admissions, persists the latest queue,
closes the transport, and releases ownership; it does not initiate upload.
Await flush before close if you want a delivery attempt. If the final snapshot
cannot persist, close reports an error after still releasing storage/transport.
There are at most 8 ordinary pending controls, 2 coalesced privacy slots (retain
and purge), and 1 coalesced close slot. A saturated ordinary queue cannot reject
shutdown or privacy purge. A later purge can upgrade a retaining disable. Once
closing starts, new ordinary controls/admissions fail; close awaits the worker's
persistence/resource-cleanup acknowledgement before disposing its isolate.

## Wire, bounds, and retries

POST `/api/logs/ingest`, Bearer `plog_ingest_...`, uncompressed JSON. HTTPS origins
must have no user info, path other than `/`, query, or fragment. Cleartext is
allowed only to numeric `127.0.0.1` / `::1` for local testing, **not** DNS localhost
or Android emulator `10.0.2.2`. Normal TLS/hostname verification is used. The
`dart:io` transport explicitly sets `followRedirects=false`, refuses all redirects,
uses no persisted cookies/credentials/cache or system proxy, requests identity
encoding, refuses compressed replies, caps the response at 64 KiB, and closes
requests after a 30-second deadline. See Dart's
[redirect control](https://api.dart.dev/dart-io/HttpClientRequest/followRedirects.html)
and [response decompression defaults](https://api.dart.dev/dart-io/HttpClient/autoUncompress.html).

- Levels: debug/info/warning/error. Category/app version/build ≤80 Unicode scalars;
  IDs ≤128; message ≤4,096. Unpaired UTF-16 surrogates reject the event/configuration;
  valid supplementary-plane emoji count as one scalar. NUL is sanitized.
- At most 16 scalar attributes: nonempty names ≤64 scalars, string values ≤512,
  null/bool/finite numbers within inclusive ±1e308. Nested lists/maps, custom
  objects, empty names, and invalid/nonfinite numbers reject the entire event.
  A rejected event never poisons its valid batch neighbors.
- At most 50 events / 256 KiB per upload; at most 8,192 UTF-8 JSON bytes per event.
  IDs and nonnegative sequence numbers survive replay. Original app/build/
  installation/session metadata survives restart; mixed metadata uses separate batches.
- Only HTTP 200 with nonnegative integer `accepted` + `duplicate` equal to the
  submitted count and a timezone-bearing ISO `received_at` acknowledges a batch.
  Lost/malformed acknowledgements retain every event for deduplicated retry.
- 401/403 stop delivery until `await logger.reconfigure(ingestToken: newKey)`.
  Reconfiguration rotates the in-memory token, preserves queued IDs, and resumes
  an auth stop/disabled logger; it cannot reopen a closed logger. Use a new client
  and namespace to change application/backend/environment identity.
- Network/5xx/408 or invalid acknowledgement failures use exponential backoff,
  2-second initial base, 300-second capped base, 0.5–1.5 jitter. 429 also honors
  Retry-After seconds (bounded to a day) or HTTP date when later than backoff.
  413 halves batches and discards a singly rejected event. Other statuses,
  including redirects, discard that attempted batch and count it as rejected.

## Offline storage and lifecycle

The queue holds at most **2 MiB including serialized metadata / 2,000 events**,
whichever limit is reached first; configuration may lower both. Overflow evicts
oldest events and counts them. Disk writes are coalesced and serialized. Memory
includes one bounded live queue/encoding, one immutable in-flight snapshot,
one bounded batch/response, admission messages, and object overhead; the 2 MiB
limit is a serialized spool bound, not total RSS.

The queue expires events at three days on load, enqueue, stats, ticks and flush,
including inactive/auth-stopped mode. Suspended or killed processes cannot delete
until the OS runs them again. Generated installation ID persists in the spool;
new clients normally use a new debug-session UUID. These are untrusted metadata,
not stable user identity. Clock changes, corruption, directory deletion, or OS
storage removal can reset identifiers/sequence and lose events.

Redaction runs before file writes and again during recovery: sensitive attribute
keys, bearer/ingest-token patterns, common secret assignments and email patterns
are masked in text, categories, string attributes, IDs and metadata. The configured
credential is never written. Add up to 32 domain-specific `sensitiveKeys` in the
configuration. This is **best effort, not perfect PII detection**; never deliberately
log credentials or personal data. Stats and worker errors exclude contents/keys.

The Flutter helper enforces the native locations before opening the worker:

- Android uses a dedicated `Context.noBackupFilesDir` child, POSIX 0700 directory
  and 0600 queue files; storage is app-private and excluded from normal Android
  backup. No custom encryption or hardware-keystore integration is claimed.
- iOS uses Application Support, excludes the directory from backup, and requests
  `completeUntilFirstUserAuthentication` protection on the directory/existing
  files. New files inherit directory protection; queued files also use mode 0600.
  Locked-device behavior must be checked on a physical device. Apple's backup
  exclusion is an OS hint, not a guarantee that data can never appear in a backup:
  see [Apple's backup guidance](https://developer.apple.com/documentation/foundation/optimizing-your-app-s-data-for-icloud-backup).
- The Dart core's `PrivateSpool.hostProvided(path, protectionConfirmed: true)` is
  for a host that already ensures private/no-backup/platform-protected storage,
  including the host CLI smoke. The boolean is an explicit host assertion, not
  proof; prefer the Flutter native helper in mobile apps. No shared/public folders.

File ownership uses POSIX `flock` across clients/isolates/processes. Default Dart
advisory locks alone are process-scoped and do not exclude other isolates;
[Dart documents that limitation](https://api.dart.dev/dart-io/RandomAccessFile/lock.html).
Queue/lock symlinks and nonfiles are refused. Snapshot replacement uses a same-
directory temp file, file flush and rename; a temporary second queue-sized file
can exist. Parent-directory fsync/power-loss durability is not promised. Oversized
or corrupt spools reset safely; individually invalid legacy records are removed
while valid neighbors survive. Storage failures keep bounded memory for retry;
no event is uploaded before its current queue snapshot has persisted.

`await logger.disable()` immediately stops admission/delivery and then persists
an empty queue. The returned bool says whether purge persistence succeeded;
`disable(purge: false)` retains the queue. It waits behind an older storage write,
so an older snapshot cannot restore purged data. Generation checks prevent stale
network acknowledgements after disable/reconfiguration from removing newer data.
An already transmitted request cannot be retracted. Close/disable cannot promise
physical deletion on failing storage, backups, or a terminated process.

Automatic foreground ticks run every two seconds. Wire the lifecycle adapter or
call `setForegroundActive`; it uses Flutter's
[lifecycle notifications](https://api.flutter.dev/flutter/widgets/AppLifecycleState.html).
No background task, WorkManager job, daemon, device-global settings, or automatic
lifecycle guarantee is installed. iOS/Android may suspend/kill the process without
sending every notification. The app owner controls execution time and consent.

## Tests, native builds, and local smoke

From `sdks/flutter`, using the official installed SDK (analytics suppressed per
command; no global shell-profile change):

```sh
FLUTTER_SUPPRESS_ANALYTICS=true /private/tmp/proxycept-flutter/bin/flutter --suppress-analytics pub get
FLUTTER_SUPPRESS_ANALYTICS=true /private/tmp/proxycept-flutter/bin/flutter --suppress-analytics analyze --no-pub
FLUTTER_SUPPRESS_ANALYTICS=true /private/tmp/proxycept-flutter/bin/flutter --suppress-analytics test --no-pub
```

Tests read `../conformance/attribute-vectors.json` as a development-only shared
fixture: all ten scalar cases, mixed admission neighbors and legacy-spool recovery.
They also cover Unicode/surrogates, pre-spool scrubbing, serialized bounds, expiry,
IDs, malformed acknowledgements, retry/auth/413, storage failure, disable/storage/
network races, and real loopback redirects/response caps/private file ownership.
The public client is tested through its actual worker isolate and real loopback IO.
Fixtures/transports are not production inputs or extra library runtime dependencies.

The checked-in `example` uses runtime key entry and native private storage. From
`example`: `flutter build apk --debug` or
`flutter build ios --simulator --debug --no-codesign`. No installation or launch
is implied. iOS currently uses CocoaPods; SwiftPM plugin adoption is not implemented.
The Android plugin currently uses KGP; Flutter reports future built-in-Kotlin
migration warnings. These are known forward-compatibility gaps, not runtime proof.

Source-only Xcode project/workspace and shared scheme metadata are explicitly
unignored under this SDK; user state, Pods, DerivedData and build products stay
ignored. Flutter's Android build command regenerates its ignored Gradle wrapper
scripts/JAR from the installed Flutter tooling when needed. A clean checkout uses
`flutter pub get` then the Flutter build commands; do not regenerate the whole
example with `flutter create`, which can overwrite its custom debug policy/test.

### Core CLI integration (main supplies environment; never credentials in argv)

```sh
/private/tmp/proxycept-flutter/bin/dart --suppress-analytics run tool/local_smoke.dart
```

Required environment: `PROXYCEPT_TEST_BASE_URL=http://127.0.0.1:18880`,
`PROXYCEPT_TEST_INGEST_KEY`, a random `PROXYCEPT_TEST_DEBUG_SESSION`, and a private
`PROXYCEPT_TEST_SPOOL_DIR`. The runner refuses non-loopback targets, emits category
`flutter-integration`, message `Cross-platform SDK smoke`, password attribute
`must-be-redacted`, waits for a valid committed acknowledgement and empty queue,
then prints a nonsecret PASS. Main's harness owns key issuance/revocation and
independent server/spool verification. This proves core/isolate delivery, not the
Flutter/native storage bridge or device file-protection behavior.

### Native integration (main/device owner only)

Main's ephemeral server at `http://127.0.0.1:18881/sdk-test-config` supplies in-memory
`{base_url,ingest_key,debug_session_id}` and revokes the synthetic key in cleanup.
The runner needs only the nonsecret `PROXYCEPT_TEST_CONFIG_URL`; no credential is
compiled, placed in assets, passed through `--dart-define`, or printed. Only the
configuration URL may be supplied as a define. Android needs device-owner adb
reverse mappings for **18880 and 18881**, with owner cleanup. The example's
loopback cleartext exception is debug-only; release policy is unchanged.

```sh
PROXYCEPT_TEST_DEVICE=OPERATOR_SELECTED_DEVICE \
  PROXYCEPT_TEST_CONFIG_URL=http://127.0.0.1:18881/sdk-test-config \
  ./tool/run_mobile_smoke.sh
```

`example/integration_test/local_api_test.dart` fetches bounded runtime config,
checks native private/no-backup/file-policy flags without repairing them, inspects
the redacted private queue before delivery, then requires a committed ACK/drain.
Main's harness verifies the matching server event independently. The test never
prints a key, session ID, private path, or log content. Only an explicitly identified
iOS Simulator with both protection classes unreported may continue after verifying
backup exclusion and 0700/0600 modes; it prints **UNVERIFIED** Data Protection metadata.
Known None/wrong/mixed classes never get that exception. Physical iOS devices must
report the expected directory/file protection class. Compiling this target is not
running it; simulator execution never proves physical iOS lock-state protection.
Do not install/launch or alter adb routing on somebody else's device implicitly.
