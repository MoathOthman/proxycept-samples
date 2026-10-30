# Proxycept React Native logging — source preview

A TypeScript API over real native Swift/iOS and Kotlin/Android delivery engines.
Explicit application events only: no console interception, swizzling, header
injection, fetch patching, VPN, or implicit HTTP body collection. MIT licensed.
`private: true` prevents npm publication; no npm release is authorized or available.

The integration target is **React Native 0.82.1 / React 19.1.1**, iOS 15.1+, Android
API 24+, JDK 17. Peer dependencies are deliberately exact. The exported modules
use RN's legacy-module **interop layer within the New Architecture**; this package
has no custom C++/JSI implementation. RN 0.82 cannot run the old architecture.
Do not infer compatibility with other RN versions or Expo Go. Expo development
builds require native linking and a rebuilt binary. See [TESTING.md](TESTING.md)
for the actual typecheck, core, bridge-build and runtime evidence and gaps.

**Verified final framework runtime:** after the correlation/close fixes and strict
configuration-redirect guard, React Native 0.82.1 / React 19.1.1 delivered a
redacted, committed local-API event through bundled JS → native bridge → durable
core on both an iOS 26.2 simulator (app 38) and an Android API 36 device (app 39).
Both keys were revoked. Runtime evidence reports
`committed=1 queued=0 hermes=true bridgeless=true`.
Final checks pass: **19 JS tests, 38 Swift tests, 31 JVM tests**, strict concurrency,
TypeScript and both native bridge builds. This does not certify minimum OS
versions, physical iOS Data Protection or OS background/battery behavior.

## Install locally

This is a nested package in a public monorepo, not a published npm package. From a
checkout, build the JS/declarations before adding its local folder to an app:

```sh
cd sdks/react-native
npm ci --ignore-scripts
npm run build
# In your RN app:
npm install /absolute/path/to/proxycept-samples/sdks/react-native
# Run your app's normal CocoaPods install and rebuild iOS/Android.
```

The podspec and `react-native.config.js` support native autolinking. Android uses
the RN app's Gradle dependency management for `react-android`; its only additional
runtime dependency is Gson 2.11.0 from Maven Central. The iOS pod depends on
`React-Core` and uses Foundation URLSession. No AsyncStorage, shared-preferences
spool or JS fetch fallback exists. `npm pack` is permitted locally after a build;
`npm publish` remains disabled. A bare Git URL cannot select this nested npm package.

The native source engines are bundled **inside this package**, so an installed
package never reaches out to sibling SDK folders. Their provenance, upstream
hashes, intentional wrapper adaptations and bundled hashes are pinned in
`native-source-provenance.json`. They are public MIT source, not private backend
code. Run `npm run check:native-source` from the monorepo after any upstream SDK
change; it fails if a fix has not been explicitly reviewed/ported. Do not silently
refresh hashes as a substitute for porting a fix and running both native suites.
The shared fixture is a development-only relative dependency and is not packed.

## API

```ts
import {createLogger} from '@proxycept/react-native-logging';

const logger = await createLogger({
  baseUrl: 'https://logs.example.com',
  ingestToken: runtimeShortLivedIngestKey,
  appVersion: '1.0', build: '12',
  spoolName: 'qa',                    // private child directory name, not a path
  debugSessionId: randomSessionId,     // optional; random UUID if omitted
  // installationId: optionalMetadataId,
});

const admitted = logger.log('info', 'checkout', 'Checkout tapped',
  {screen: 'checkout', attempt: 1, guest: true, optional: null}, explicitCorrelationId);
await logger.flush();
const stats = await logger.deliveryStats();
await logger.reconfigure(replacementIngestKey); // same origin, new in-memory token
await logger.disable(); // stop admission/delivery and purge; already-sent requests cannot be recalled
await logger.close();   // persist/finish native work and release ownership; no new delivery attempt
```

Use one client per native module/React runtime. A second configure is rejected
while a client is open. Retain the client and call `close` on teardown. Native iOS close releases spool
ownership before returning, even when the closed client remains retained, and
prevents that old client from writing over a subsequent owner. After
close, create a new client; do not reuse the retired one. `disable` is terminal at
the TypeScript API; create a fresh client after closing to re-enable delivery.
Use `await logger.flush(); await logger.close()` for a final attempt. `flush`
respects backoff/auth stops and is not a delivery guarantee. A valid committed
acknowledgement is the delivery boundary, not a successful call to `log`.

`log` is synchronous bounded **admission**, not disk/network I/O or a persistence
promise. JS snapshots caller values and allows at most 32 pending bridge admissions
and 256 KiB of staged JSON. Each native bridge independently bounds dispatch and
input sizes. A false result means rejected JS admission. Asynchronous native
rejections and bridge errors are visible in `bridgeRejected`/`bridgeFailures`;
no unhandled log promise or raw native error is sent back to the application.

Levels are `debug`, `info`, `warning`, `error`. Attributes are at most 16 scalar
values (string, finite number with magnitude <= `1e308`, boolean or null), with
nonempty names <=64 Unicode scalars and string values <=512. Nested maps/arrays,
nonfinite/out-of-range numbers, getters and unsupported objects are rejected.
Message/category/correlation limits are 4096/80/128 Unicode scalars; app/build
limits are 80. Native code validates again and enforces the final 8192-byte event
limit. Invalid events never poison a batch of valid neighbors. There is no
implicit correlation header; `correlationId` is null or an explicit nonempty
string of 1–128 Unicode scalars. Empty strings are rejected before admission,
including at native wire boundaries. Recovery discards invalid-correlation events
individually while preserving valid neighbors and replay IDs.

Common delivery stats are `queued`, `accepted`, `duplicate`, `dropped`, `expired`,
`failures`, `storageFailures`, `authenticationStopped`, and `disabled`. JS counters
are `admissionDropped`, `invalid`, `bridgeRejected`, `bridgeFailures`. They are
per-client, in memory; platforms group some native drop/error reasons differently.
`accepted`/`duplicate` count acknowledged events, not log API invocations.

## Delivery and protection

The native durable queue is bounded by **2 MiB or 2000 events**, whichever is
reached first; configuration can reduce both. `maxQueueBytes` has a portable
minimum of 8192; `maxQueueEvents` minimum is one. Overflow evicts oldest records
and increments native drop counters. Bounded bridge staging and an in-flight
batch are additional transient allocations; the 2 MiB bound is the durable event
queue, not total process RSS. Foreground flush is every two seconds, with at most
50 events/256 KiB per uncompressed POST. Event UUIDs are stable across retries and
restart; original session/app metadata stays attached to queued records.

`createLogger` attaches AppState changes, treating unknown startup state as
inactive. Native iOS UIApplication notifications and Android host lifecycle
listeners also gate automatic delivery. The engines, not JS timers, own flushing.
Explicit flush remains available in the background if the host provides execution
time. No background-service entitlement or wake guarantee is installed.
Three-day expiration runs when the native engine executes; a suspended/terminated
app cannot delete files until the OS lets it run again.

- Only HTTPS origins are accepted, except literal numeric `127.0.0.1` and `::1`
  HTTP loopback. Hostname HTTP, URL credentials, non-origin paths, queries and
  fragments are refused independently by native code. No global ATS/Android
  cleartext relaxation is installed. For a local test, use narrowly scoped
  app-specific network exceptions if the OS requires them; never relax production
  TLS policy globally.
- Native URLSession/HttpURLConnection refuse **all redirects**, including same
  origin. There is no reliance on RN fetch's `redirect: 'error'` behavior.
  Authorization stays on the ingest request. Platform TLS trust is unchanged.
- Only HTTP 200 with nonnegative integral accepted/duplicate counts whose sum
  matches the whole submitted batch, and a valid ISO `received_at`, acknowledges
  delivery. Lost/malformed responses retain records for replay/deduplication.
- 401/403 stop native delivery until token reconfiguration. 429 honors numeric or
  HTTP-date Retry-After. Network/408/5xx/malformed acknowledgements back off with
  native jitter. 413 reduces batches or drops a single oversized event. Other
  permanent client errors, including refused redirects, discard that batch.
- iOS spools live under private Application Support, use owner-only modes and
  `completeUntilFirstUserAuthentication` protection, and are excluded from backup.
  Android uses `Context.noBackupFilesDir` with owner-only files/directories and the
  platform app sandbox. This is OS protection, **not app-level encryption**.
  There is no cross-platform claim of equal protection while the device is locked.
- Disk writes use atomic snapshots. Failure retains bounded memory and increments
  `storageFailures`; no claim of persistence is made after a failed write. An
  exclusive owner lock prevents concurrent clients writing one spool. Malformed
  snapshots are handled safely; readable legacy events with invalid scalar bounds
  are rejected without poisoning valid neighbor records. Unparseable snapshots
  can lose events. Uninstall/clear-data also removes the installation identifier.

Redaction runs natively **before any event is spooled** and again on recovery.
It covers the configured ingest key, ingest-token patterns, bearer credentials,
common secret assignments and email patterns in keys/values/messages/metadata.
Sensitive attribute values such as password are replaced. No credential is put
in the spool or stats. JS holds event arguments only in bounded transient memory;
provision the ingest-only credential at runtime via the host, never from a bundled
permanent key. Server-independent redaction is still required. This is best-effort
scrubbing, not perfect PII/secret detection; never intentionally log sensitive data.

## Example and local smoke

`example/android` is a complete RN New Architecture/Hermes local runtime host,
not just a bridge compile harness. Its pinned build uses Gradle 8.13, AGP 8.12.0,
Kotlin 2.1.20, JDK 17, SDK 36 and NDK 28.2.13676358. It bundles the same
credential-free JS entry as iOS; no Metro server is needed at runtime. Build
`:app:assembleDebug` without credentials, then explicitly run
`scripts/run-android-runtime.py` with `PROXYCEPT_ANDROID_DEVICE` and
`PROXYCEPT_ADB` set. Builds never install/launch a device. The operator owns
temporary forwarding for 18880/18881 and test-key revocation; see TESTING.md.

`example/App.tsx` demonstrates admission/flush/stats and lifecycle-safe cleanup.
Obtain its `configuration` prop from a runtime credential provider. The
`example/ios` host uses RN 0.82's factory/bootstrap API. Its checked-in project
spec can be generated with XcodeGen. `npm run bundle:example` bundles
`example/runtime-entry.js` without a key. The runtime entry fetches
`http://127.0.0.1:18881/sdk-test-config` (no-store, operator-provided) and invokes
the actual TypeScript facade and native bridge. The factory passes only
`PROXYCEPT_TEST_CONFIG_URL`, never a compiled key. The example requires the local
ingest origin `http://127.0.0.1:18880`. A native build alone does not prove JS module
discovery or Hermes execution; the on-screen `logging-status` reports PASS only
after the JS-created client observes exactly one committed acknowledgement and a
drained queue, and includes runtime Hermes/bridgeless flags.
`example/android` is explicitly a native-bridge **compile harness**, not an app.
No simulator/device boot, install or launch is part of the commands below.

First run `npm run prepare:smoke` without runtime credentials. This preparation
script strips all test configuration from the build environment. `smoke:core`
subsequently executes the prebuilt `.build/swift/debug/ProxyceptRNSmoke` directly;
no compiler or package manager inherits the runtime key.

For the local API smoke, pre-set these environment variables in the operator's
process (never print the key or put it in argv, a source file or the JS bundle):
`PROXYCEPT_TEST_BASE_URL=http://127.0.0.1:18880`, `PROXYCEPT_TEST_INGEST_KEY`,
`PROXYCEPT_TEST_DEBUG_SESSION` (random ID), `PROXYCEPT_TEST_SPOOL_DIR` (dedicated
private absolute directory). Then run:

```sh
cd /private/tmp/proxycept-logging-sdks/sdks/react-native
npm run smoke:core
```

The runner uses the real bundled Foundation engine and RN native controller,
emits category `rn-integration`, message `Cross-platform SDK smoke`, attributes
`password='must-be-redacted'`, waits for a valid committed acknowledgement and
empty queue without drops, closes, then prints a nonsecret PASS. It refuses
non-numeric/local origins. It does **not** execute Hermes, the RN bridge or TS
runtime, and should not be described as an end-to-end RN app test.

For a coordinated runtime test, the **main task/operator** can run the already
built app on an explicitly selected booted simulator. This command installs and
launches that app, and is never called by the SDK's build/test scripts:

```sh
# Pre-set PROXYCEPT_SIMULATOR_UDID and start the ephemeral no-store config server.
sh scripts/run-ios-runtime.sh
```

Use the independent local API assertion plus `logging-status` to establish
JS → RN interop bridge → native controller → durable core → ingest evidence.
The runner only reports launch; it does not invent a runtime PASS. No key is in
its command line. Simulator ownership, screenshots, cleanup and ephemeral key
revocation belong to the coordinating main task.

## Development checks and official references

```sh
npm test
npm run typecheck
npm run build
npm run check:native-source
CLANG_MODULE_CACHE_PATH=/private/tmp/proxycept-rn-module-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/proxycept-rn-module-cache \
swift test --disable-sandbox --package-path ios --scratch-path .build/swift
# JVM suite: use JDK 17 and Gradle 8.11.1 with android/jvm as the project directory.
```

[TESTING.md](TESTING.md) records exact commands, results and limitations.
Implementation/integration references verified against primary sources:
[RN 0.82 and its interop layer](https://reactnative.dev/blog/2025/10/08/react-native-0.82),
[iOS native modules](https://reactnative.dev/docs/legacy/native-modules-ios),
[Android native modules](https://reactnative.dev/docs/legacy/native-modules-android),
[AppState](https://reactnative.dev/docs/appstate),
[factory-based iOS integration](https://reactnative.dev/docs/integration-with-existing-apps),
[Android private files](https://developer.android.com/training/data-storage/app-specific),
[CocoaPods source selection](https://guides.cocoapods.org/syntax/podspec.html#source_files),
[TypeScript 5.9](https://www.typescriptlang.org/docs/handbook/release-notes/typescript-5-9.html).
