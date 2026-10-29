# ProxyceptLogging for Swift/iOS

Small, dependency-free Swift Package for explicit application logs. iOS 15+,
macOS 12+, Swift 5.9+. Public SDK source, examples and tests in this directory
are independently authored and MIT licensed; no private application code or
history is included. No automatic instrumentation, swizzling, VPN, header
injection, or implicit collection of request/response bodies.

After the root package facade PR is merged, add the public repository Git URL
in Xcode or SwiftPM and link the `ProxyceptLogging` product. The root `Package.swift`
exposes the sources and tests in `sdks/swift`; use a revision containing that facade.
Adding `sdks/swift` as a local Swift Package remains supported.
No third-party logging adapter is required or included.

## Integrate

```swift
import Foundation
import ProxyceptLogging

let support = try FileManager.default.url(for: .applicationSupportDirectory,
    in: .userDomainMask, appropriateFor: nil, create: true)
let configuration = LoggingConfiguration(
    baseURL: URL(string: "https://logs.example.com")!,
    ingestToken: runtimeIngestToken, // short-lived ingest-only key from your host
    appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
    build: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown",
    spoolDirectory: support.appendingPathComponent("ProxyceptLogs", isDirectory: true)
)
let logger = try ProxyceptLogger(configuration: configuration)

logger.log(level: .info, category: "checkout", message: "Checkout tapped",
    attributes: ["screen": .string("checkout"), "attempt": .number(1), "guest": .bool(true)],
    correlationId: "explicit-request-id")
await logger.flush()
let stats = await logger.deliveryStats()
print(stats.accepted, stats.duplicate, stats.queued, stats.failures)
```

Retain one client per spool directory. Initialization validates configuration,
loads/protects the spool and performs disk I/O synchronously; initialize off the
main thread if startup latency matters. Subsequent log processing, spool writes
and network operations run off the caller's thread. `log` returns promptly after
bounded admission, with at most 32 pending log calls. Its Bool reports admission,
not durable storage or delivery. Invalid input or a full admission buffer returns
false; later disabled/oversized rejections appear in delivery stats.

Use `.debug`, `.info`, `.warning`, or `.error`. Attributes are only `.string`,
`.number` (finite Double with absolute value at most `1e308`), `.bool`, or `.null`.
Attribute names must contain 1–64 Unicode scalars. Invalid attributes reject the
entire event locally (returning false and incrementing `invalid`) before spool or
batch admission, so valid neighboring events remain deliverable. On spool reload,
individually invalid legacy events are discarded and counted without discarding
valid neighbors. Nested values are not accepted.
All event/identifier limits are validated using Unicode scalar counts (and
serialized UTF-8 byte counts); inputs exceeding character limits are rejected.
An event exceeding 8,192 serialized bytes after redaction is dropped as invalid.
Redaction replacements are limited again to the wire field lengths.

An omitted `installationId` is a random UUID retained by the spool across launches;
an omitted `debugSessionId` is a fresh UUID for this client. Both may be supplied
explicitly, up to 128 characters. They are metadata, never trusted identity.
Events keep their original app/build/installation/session metadata across restart;
different metadata is delivered in separate batches. Event UUIDs and increasing
nonnegative sequences survive replay. A corrupt/deleted spool resets its sequence
and generated installation identifier. Explicitly deleting or purging a queue may
lose events; server acknowledgement is the delivery boundary.

## Lifecycle and delivery

The default lifecycle state is foreground. Wire lifecycle changes from SwiftUI:

```swift
.onChange(of: scenePhase) { phase in
    logger.setForegroundActive(phase == .active)
}
```

For UIKit, call that method from your scene delegate's `sceneDidBecomeActive` and
`sceneWillResignActive`. Automatic foreground delivery runs every two seconds.
Explicit `await logger.flush()` attempts to drain batches, respecting backoff;
it returns after a failure/auth stop or the queue drains, not a delivery promise.
The host app owns any iOS background execution time. No background task, daemon,
network reachability polling, or automatic UIKit lifecycle observation is installed.

Before a normal shutdown, use `await logger.flush(); await logger.close()`.
`close()` stops admissions/timer, waits for an existing request, and retains the
remaining durable queue. It does not initiate delivery itself. A custom transport
must honor timeouts or `flush`/`close` can wait indefinitely. The default transport
has 15-second request and 30-second resource timeouts.

`await logger.disable()` stops delivery and purges the queue; use
`disable(purge: false)` to retain it. A request already transmitted cannot be
recalled; disable ignores its later completion. Closed/disabled clients cannot
be re-enabled: release the old client and create a new one. The spool file lock
is held until the client is deallocated, including while existing async work
retains it. `reconfigure(ingestToken:)` rotates the in-memory token and resumes an
authentication stop, but does not enable a closed/disabled client.

- Atomic JSON spool, at most 2 MiB **including metadata** and 2,000 queued events,
  whichever limit is reached first; both limits can be reduced. Overflow evicts
  oldest events, with `droppedOldest` counting them. The byte bound can evict a
  small group of oldest events at once. Admission overflow is separately counted
  in `admissionDropped`. Counters are per-client and not persisted.
- The queue expires events at three days during startup, flush, stats queries,
  enqueue and the live timer (including inactive mode). A terminated/suspended
  process cannot delete files until the OS runs it again.
- Each POST is schema version 1 to `/api/logs/ingest`, no compression, at most
  50 events and 256 KiB. Only a valid 200 response with `accepted + duplicate`
  equal to the submitted count and an ISO `received_at` removes an acknowledged
  batch. Lost responses replay identical event IDs for server deduplication.
- 401/403 stop delivery until credential reconfiguration. 413 halves the batch;
  a single rejected event is discarded. 429 honors numeric or HTTP-date
  `Retry-After`. Network errors, 408, 5xx and malformed acknowledgements use
  exponential backoff (2s initial base, capped at 300s base, 0.5–1.5 jitter).
  Other statuses, including refused redirects, discard that batch as rejected.
- The default transport uses ephemeral Foundation URLSession, standard TLS trust,
  no cookie/cache/credential persistence, a 64 KiB response cap and cancellation
  handling. All redirects are refused, including same origin. Base URLs must be
  HTTPS origins without credentials/query/fragment/path; HTTP is allowed only
  for literal `127.0.0.1`, `::1` or `localhost` loopback tests.

## Storage and redaction

The dedicated spool directory has POSIX mode 0700, files mode 0600. On iOS, files
use `completeUntilFirstUserAuthentication` protection; the directory and queue
are excluded from backup. A nonblocking exclusive file lock prevents competing
clients from overwriting the same spool. A directory symlink is refused. Corrupt,
oversized or structurally invalid spools are discarded safely and counted.
Snapshot replacement is atomic, not an fsync-based power-loss guarantee. Disk
failures increment `storageFailures`; data stays in bounded memory for subsequent
writes, with no claim of durability until storage succeeds. Do not place the
spool in a shared/public directory or let another process modify it.

Before any event is spooled, the SDK redacts sensitive attribute keys, bearer
values, ingest-token patterns, common key=value secrets and email addresses in
messages, keys, string attributes, correlation IDs, categories and metadata.
Loaded events are scrubbed again. The configured ingest credential is never
written by the SDK; credential configuration is held in memory. Credentials are
not placed in URLs, the queue, or delivery stats. The host is responsible for
provisioning and rotating ingest-only credentials (for example via Keychain);
never use a console/session credential or ship a permanent production key.

This is **best-effort redaction, not perfect PII/secret detection**. Do not log
secrets intentionally. Add domain-specific sensitive keys and regex patterns:

```swift
var configuration = configuration
configuration.redaction.sensitiveKeys.insert("customer_identifier")
configuration.redaction.additionalPatterns.append(#"ORDER-PRIVATE-[0-9]+"#)
```

Invalid custom regex patterns are ignored. Redaction can collapse attribute names,
in which case the later sorted key wins. Server-side independent redaction remains
necessary. Installation/session identifiers and the sanitized contents are still
application data; choose access/retention policies accordingly.

## Tests and demo

From this directory:

```sh
swift test
```

The tests use injected transports, a deterministic clock and jitter, plus an
independent loopback Python HTTP peer for the real URLSession on macOS. Those
three tests need `/usr/bin/python3` and permission to bind localhost ephemeral
ports. iOS tests use the injected transports; macOS subprocess tests are excluded.
No real backend or third-party dependency is needed. Transport injection is public
via `LogTransport`; injected transports must bound buffers, honor timeout and
redirect requirements, and protect credentials themselves.

For a restricted build environment, writable build/cache locations can be supplied:

```sh
CLANG_MODULE_CACHE_PATH=/private/tmp/proxycept-swift-module-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/proxycept-swift-module-cache \
swift test --disable-sandbox --scratch-path /private/tmp/proxycept-swift-build
```

The standalone SwiftUI smoke app is in `Examples/LoopbackDemo`. Its checked-in
Xcode project references this package locally. Optional regeneration uses XcodeGen
with `project.yml`; consumers need no XcodeGen dependency. Build without launching
or modifying any simulator:

```sh
xcodebuild -project Examples/LoopbackDemo/LoopbackDemo.xcodeproj \
  -scheme LoopbackDemo -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /private/tmp/proxycept-swift-ios-build \
  CODE_SIGNING_ALLOWED=NO build
```

Use `build-for-testing` in place of `build` to compile the included iOS XCTest
bundle without running a simulator. The shared scheme includes `LoopbackDemoTests`.
See [TESTING.md](TESTING.md) for the executed checks and exact test names.

For a locally operated simulator run, first start
`python3 Examples/loopback_server.py` on the host; it listens only on
`127.0.0.1:18880`. The app automatically emits one sanitized event and provides a
button to emit another. Its fallback key is a public dummy fixture, and the sample
server does not authenticate. Use only test data. An optional
`PROXYCEPT_INGEST_TOKEN` runtime environment value replaces the fixture key.
Simulator installation/launch is left to the operator. No device-global ATS,
proxy, CA, VPN or privacy settings need to be changed.

macOS tests cannot verify iOS device-lock file protection. iOS-specific backup
and protection assertions are conditional on an iOS test run. A simulator build
proves compilation only; real locked-device behavior, background suspension,
physical-device networking and a production ingest service require integration
validation by the app owner. No third-party adapter is included.
