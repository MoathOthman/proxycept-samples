# Local validation, 2026-10-30

Source changes are confined to `sdks/react-native/`. No commit, push, publication,
merge, production request or device-global setting change was made by this worker.

| Layer | Passed evidence | Boundary |
| --- | --- | --- |
| TypeScript | **19 Node tests**, zero failures; TypeScript **5.9.3 typecheck and JS/declaration build** against RN 0.82.1 / React 19.1.1 | Mock native boundary, not Hermes execution |
| Swift core/controller | **38 XCTest tests**, zero failures; complete strict concurrency build, warnings-as-errors | macOS host, not physical iOS lock/backup proof |
| Kotlin core/controller | **31 JVM JUnit tests**, zero failures, JDK 17/Kotlin 2.1.0 | JVM host, not Android device runtime |
| Exported Android RN bridge | **compileDebugKotlin succeeded**, real `react-android:0.82.1`, AGP 8.7.3, SDK 36 | Compile only |
| Exported iOS RN bridge and example host | **xcodebuild BUILD SUCCEEDED**, RN 0.82.1 / 75 CocoaPods, arm64 and x86_64 simulator slices | Worker did not install/launch a simulator |
| Runtime JS bundle | **Metro bundle succeeded**, official RN 0.82.1 Metro/Babel tooling; built app resource SHA-256 matches latest generated JS | Compiling Hermes into an app is not execution proof |
| Source pin | Upstream and adapted-source SHA-256 guard passed | Explicit review/port required after upstream changes |
| Package | `npm pack --dry-run --json` succeeded; no node_modules/Pods/build caches; `private: true` | No npm release |
| Real local API | Main task reported one committed native iOS controller event, sanitized spool, key revocation | **Core/controller only**, not RN JS runtime |
| Full JS → RN bridge → native → API, final rebuilt artifact | **PASS after correlation/close fixes: RN 0.82.1 / React 19.1.1, iOS 26.2 simulator**; one committed event, redaction verified, app 34; ephemeral key revoked | Coordinating main-task run; no Android runtime claim |

The JS, Swift-controller and Kotlin-controller suites read the shared
`../conformance/attribute-vectors.json` via development-only relative paths. All
10 vectors are exercised. Mixed valid neighbors remain deliverable around rejected
attributes; inherited native recovery regressions preserve valid legacy-spool
neighbors. Native peers independently reject poisoned atomic batches with 422.
Tests also cover replay IDs, acknowledgement counts/date, auth stops, retry/backoff,
413/429, expiry/overflow, corruption, storage failures, ownership, disable and close.
Swift tests include three real URLSession loopback HTTP tests; JVM tests include
HttpURLConnection loopback delivery and redirect-leak refusal. JS tests include
bounded blocked-bridge admission, caller snapshots and concurrent purge/close barriers.

## Confirmed final full-framework iOS runtime

On 2026-10-30, after the correlation and deterministic-close fixes, the coordinating
main task reran the rebuilt example on the already-booted iOS 26.2 simulator
`1AA9651C-989C-4623-8242-5C138C0A67A6`. The final build succeeded at 22:23:39.
Bundled JavaScript invoked the TypeScript facade, RN native-module interop bridge,
native controller/durable engine and local API. This is framework runtime evidence,
separate from the earlier Foundation-only proof.

Final independent harness evidence,
`/private/tmp/proxycept-cross-rn-runtime-final.log`:

```text
react-native: PASS; 1 committed event(s), redaction verified, app_id=34
```

The coordinator confirmed revocation of the ephemeral key. The native child
received only a nonsecret config URL; key/session JSON was fetched into memory
from the no-store loopback config server. Builds were prepared without the runtime
key in compiler environments. The final artifact includes the correlation and
close changes; this is not the earlier app-26 binary.

Earlier visual evidence remains separately identified: the reviewed screenshot
`/private/tmp/proxycept-react-native-runtime.png` from the app-26 run shows:

```text
PASS rn-js-native committed=1 queued=0 hermes=true bridgeless=true
```

The screenshot is not presented as a new app-34 capture. Its unrelated simulator
permission overlay was left untouched; no screenshot/dialog content is copied
into this public source package. The status is set after awaited native flush,
stats verification and close, not merely after launch. Native flush waits for
acknowledgement/drain or failure/backoff/auth stop, and queued/dropped/error checks
prevent a false PASS. Runtime proof is **iOS only**, not Android, other RN versions,
or physical-device protection/background behavior.

## Empty-correlation blocker follow-up

RN admission, both adapted native cores, native JSON boundaries and persisted
record recovery now require correlation to be null or a nonempty string of at
most 128 Unicode scalars. Invalid records are dropped individually, preserving
valid neighboring event IDs. Android does not coerce numeric/boolean correlation
values into strings. Validation also applies after native redaction. Original
Swift/Kotlin SDK files remain unchanged; adapted hashes and rationale were updated.
Focused tests assert that peers rejecting empty correlations with atomic 422 still
acknowledge valid neighbors, both on fresh admission and legacy-spool recovery.

The copied Swift core also now makes close a deterministic ownership-release
barrier. A dedicated regression retains the old client while reopening the spool,
then exercises old-client stats/disable/repeated close to verify no stale writes
or double-closing of a descriptor reused by the new owner. Separate in-flight
close waiters prevent disable from completing close prematurely. This legitimately
resolved two restart-test spoolInUse failures; no sleeps or weaker assertions were
introduced. The final 38-test Swift suite is green, and the final app-34 framework
rerun above covers the rebuilt native changes. Original SDKs remain unchanged.

## Reproduce

From the clone root, without runtime credentials in the build environment:

```sh
npm test --prefix sdks/react-native
npm run typecheck --prefix sdks/react-native
npm run build --prefix sdks/react-native
npm run check:native-source --prefix sdks/react-native
npm run bundle:example --prefix sdks/react-native
npm run prepare:smoke --prefix sdks/react-native

CLANG_MODULE_CACHE_PATH=/private/tmp/proxycept-rn-module-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/proxycept-rn-module-cache \
swift test --disable-sandbox --package-path sdks/react-native/ios \
  --scratch-path sdks/react-native/.build/swift

CLANG_MODULE_CACHE_PATH=/private/tmp/proxycept-rn-module-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/proxycept-rn-module-cache \
swift build --disable-sandbox --package-path sdks/react-native/ios \
  --scratch-path sdks/react-native/.build/swift-strict \
  -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors

JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home \
GRADLE_USER_HOME=/private/tmp/proxycept-kotlin-gradle \
/Users/moathaliwat/.gradle/wrapper/dists/gradle-8.11.1-bin/bpt9gzteqjrbo1mjrsomdt32c/gradle-8.11.1/bin/gradle \
  -p sdks/react-native/android/jvm --offline --no-daemon test

JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home \
ANDROID_HOME=/Users/moathaliwat/Library/Android/sdk \
GRADLE_USER_HOME=/private/tmp/proxycept-kotlin-gradle \
/Users/moathaliwat/.gradle/wrapper/dists/gradle-8.11.1-bin/bpt9gzteqjrbo1mjrsomdt32c/gradle-8.11.1/bin/gradle \
  -p sdks/react-native/example/android --offline --no-daemon :proxycept-logging:compileDebugKotlin

xcodegen generate --spec sdks/react-native/example/ios/project.yml
PATH=/opt/homebrew/opt/ruby/bin:$PATH \
GEM_HOME=/private/tmp/proxycept-cocoapods GEM_PATH=/private/tmp/proxycept-cocoapods \
/private/tmp/proxycept-cocoapods/bin/pod install --project-directory=sdks/react-native/example/ios

CLANG_MODULE_CACHE_PATH=/private/tmp/proxycept-rn-module-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/proxycept-rn-module-cache \
xcodebuild -workspace sdks/react-native/example/ios/ProxyceptRNExample.xcworkspace \
  -scheme ProxyceptRNExample -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath sdks/react-native/.build/ios CODE_SIGNING_ALLOWED=NO build
```

Local networking was allowed for the loopback tests. Initial unset JAVA_HOME was
fixed using the existing JDK 17. RN/DOM TS declaration conflicts were fixed with
ES2020-only libraries and actual React types, not skipLibCheck. Metro's `bundleOut`
option fixed an initial unwanted `.js` suffix before the app was finalized.
Remaining upstream warnings: AGP 8.7.3's SDK-35 support ceiling, deprecated legacy
ReactPackage factory, RN's CocoaPods deprecation notice, Hermes build-phase outputs,
and skipped AppIntents metadata for a target without AppIntents. None is presented
as runtime certification.

## Ready operator handoff

App: `.build/ios/Build/Products/Debug-iphonesimulator/ProxyceptRNExample.app`.
Bundle ID: `com.proxycept.reactnative.example`.

With main's ephemeral no-store config server at
`http://127.0.0.1:18881/sdk-test-config`, pre-set `PROXYCEPT_SIMULATOR_UDID`, then run
`sh sdks/react-native/scripts/run-ios-runtime.sh` from the clone root. This script
**does install/launch** on the specified already-booted simulator; SDK build/test
scripts never invoke it. Main owns device actions, screenshots, key revocation and
cleanup. The child gets only `PROXYCEPT_TEST_CONFIG_URL`; JSON
`{base_url, ingest_key, debug_session_id}` is fetched into memory after launch.
The test entry requires numeric loopback config/ingest endpoints.

Independently inspect the API's committed row and on-screen `logging-status`. The
JS entry emits a nonsecret PASS only after exactly one acknowledgement, zero
queued events/drops/bridge errors; it reports actual `HermesInternal` and
`RN$Bridgeless` flags. The launch script reports launch, not invented runtime PASS.

For core-only tests, `prepare:smoke` unsets runtime variables before compiling;
`smoke:core` executes the prebuilt native binary directly with the four documented
environment variables. No compiler/package manager inherits the runtime key.
This Foundation/controller path is never described as RN runtime proof.

Not validated here: Android RN runtime, physical-device lock/unlock, actual backup,
background suspension, power loss/full disk, production service, or RN versions
beyond exactly 0.82.1. iOS protection/backup assertions are conditional and were not
executed by macOS tests. The coordinated iOS runtime evidence is recorded above; Android runtime remains unvalidated.
