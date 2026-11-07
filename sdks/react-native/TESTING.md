# Local validation, 2026-10-30

These are local development checks for `sdks/react-native/`, not package
publication or production deployment. Device actions below are explicit
operator-run tests; build and normal unit-test tasks do not invoke them.

| Layer | Passed evidence | Boundary |
| --- | --- | --- |
| TypeScript | **19 Node tests**, zero failures; TypeScript **5.9.3 typecheck and JS/declaration build** against RN 0.82.1 / React 19.1.1 | Mock native boundary, not Hermes execution |
| Swift core/controller | **38 XCTest tests**, zero failures; complete strict concurrency build, warnings-as-errors | macOS host, not physical iOS lock/backup proof |
| Kotlin core/controller | **31 JVM JUnit tests**, zero failures, JDK 17/Kotlin 2.1.0 | JVM host, not Android device runtime |
| Exported Android RN bridge and host | **assembleDebug succeeded**, RN/Hermes 0.82.1, AGP 8.12.0, Kotlin 2.1.20, Gradle 8.13, SDK 36 | Full host runtime separately executed below |
| Exported iOS RN bridge and example host | **xcodebuild BUILD SUCCEEDED**, RN 0.82.1 / 75 CocoaPods, arm64 and x86_64 simulator slices | Worker did not install/launch a simulator |
| Runtime JS bundle | **Metro bundle succeeded**, official RN 0.82.1 Metro/Babel tooling; built app resource SHA-256 matches latest generated JS | Compiling Hermes into an app is not execution proof |
| Source pin | Upstream and adapted-source SHA-256 guard passed | Explicit review/port required after upstream changes |
| Package | `npm pack --dry-run --json` succeeded; no node_modules/Pods/build caches; `private: true` | No npm release |
| Real local API | Main task reported one committed native iOS controller event, sanitized spool, key revocation | **Core/controller only**, not RN JS runtime |
| Full JS → RN bridge → native → API, final rebuilt artifacts | **PASS after correlation/close/configuration-redirect fixes: iOS 26.2 simulator app 38 and Android API 36 device app 39**, RN 0.82.1 / React 19.1.1; one redacted committed event each; keys revoked | Both tested platforms, not all minimum OS/device combinations |

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

Two additional host-only operator-runner tests pass using fake adb and an
isolated fake APK tree; no device is touched. They verify mandatory explicit
selection, task-PID/JS-tag log scoping, nonsecret output, removal of legacy
credential variables from adb child environments, and absence of hidden reverse
commands. Run with
`python3 sdks/react-native/example/android/scripts/test-operator-runner.py`.

## Confirmed final framework runtime on both platforms

On 2026-10-30, the coordinator executed both rebuilt hosts after the correlation,
deterministic-close and configuration-redirect checks. Bundled JS invoked the
TypeScript facade, actual RN bridge, native controller/durable engine and local
API. Final independent harness logs report one committed/redacted event each:

- iOS 26.2 simulator, app 38: `/private/tmp/proxycept-cross-rn-ios-guard-final.log`.
- Android API 36 device, app 39: `/private/tmp/proxycept-cross-rn-android-guard-final.log`.

Each key was revoked; task-owned Android forwarding was removed. Builds received
no runtime key. The app fetched its short-lived configuration from the no-store
loopback server, rejecting redirects/final-URL changes before JSON parsing/use.
No credential was compiled or placed in assets/arguments. The actual test status
was `PASS rn-js-native committed=1 queued=0 hermes=true bridgeless=true`.
Android reads were restricted to this task app's PID/JS tag; unrelated app logs
were not collected. Existing simulator permission dialogs were left untouched.

PASS requires awaited flush, exact acknowledgement/drain, zero drops/bridge
failures and awaited close. This is full RN runtime proof on the two tested
platforms, separate from mocked JS, host JVM/Foundation tests and native builds.
It does not certify other RN versions, minimum-OS combinations, physical iOS
Data Protection, actual backup/restore, background execution or battery behavior.

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
introduced. The final 38-test Swift suite is green, and the final app-38 framework
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

JAVA_HOME="$(/usr/libexec/java_home -v 17)" \
GRADLE_USER_HOME=/private/tmp/proxycept-kotlin-gradle \
gradle \
  -p sdks/react-native/android/jvm --offline --no-daemon test

JAVA_HOME="$(/usr/libexec/java_home -v 17)" \
ANDROID_HOME="$HOME/Library/Android/sdk" \
GRADLE_USER_HOME=/private/tmp/proxycept-kotlin-gradle \
/path/to/gradle-8.13/bin/gradle \
  -p sdks/react-native/example/android --no-daemon :app:assembleDebug

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
Remaining upstream warnings: deprecated legacy
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

Not validated here: minimum-OS device combinations, physical iOS lock/unlock, actual backup,
background suspension, power loss/full disk, production service, or RN versions
beyond exactly 0.82.1. iOS protection/backup assertions are conditional and were not
executed by macOS tests. Both coordinated framework runtime results are recorded
above, with physical iOS protection and background behavior still unqualified.

For the Android operator run, explicitly select the device and installed adb:

```sh
PROXYCEPT_ANDROID_DEVICE=OPERATOR_SELECTED_DEVICE \
PROXYCEPT_ADB=/path/to/adb \
PROXYCEPT_TEST_CONFIG_URL=http://127.0.0.1:18881/sdk-test-config \
  python3 sdks/react-native/scripts/run-android-runtime.py
```

This installs/replaces and launches only `com.proxycept.reactnative.example`.
It requires a prebuilt APK and the coordinator's loopback config/API fixture.
The coordinator owns temporary device forwarding and must remove it and revoke
the synthetic key afterward. No build or normal unit test invokes this script.
