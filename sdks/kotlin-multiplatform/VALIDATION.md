# Validation — 2026-10-30

Owned scope: `sdks/kotlin-multiplatform/**` only. No edits to existing Kotlin,
Swift, Flutter, React Native, root docs or backend source. No commit/publish.

Build toolchain: Kotlin 2.3.21, Gradle 8.13, Homebrew JDK 17, AGP 8.13.2,
Android SDK 35, Xcode 26.3 / iOS SDK and simulator runtime 26.2.
Minimum runtime: Android **26**, iOS **14**, JVM Java 8. Android host does not
need java.time desugaring at this minimum. Both generated frameworks' plist
minimum is 14.0. Existing JVM SDK minimum/API/toolchain is unchanged.

## Executed checks

* JVM: **27 tests, 0 failures/errors/skips**. Includes 10 shared admission vectors
  in mixed valid-neighbor batches and legacy-spool recovery, real loopback POST
  and all five HTTP redirect status classes, pre-write 0600 modes, concurrent
  blocked storage, expiry/auth/429/413/atomic acknowledgements/retry IDs.
* Four deadline/cancellation regressions all passed: trickled responses hit the
  whole-call deadline and retry the same ID; disable+close clears the durable
  queue without waiting for a slow server; blocked request writes are actually
  stalled and then interrupted both by cancellation and by the total deadline.
  Default logger privacy close completes within the test's 1.5-second bound.
* Native iOS: **20 tests passed, no optional HTTP tests skipped**. Executed the
  Gradle-produced `iosSimulatorArm64` native test binary using the owned isolated
  simulator script, not just framework linking. Includes common/shared vectors,
  Apple file modes/recovery/exclusive ownership, actual NSURLSession POST and
  cross-origin redirect refusal, and slow-response cancellation with persisted
  privacy clearing. Uses a local stub server and dummy key, not production.
* Identifier contract regressions passed on JVM and native: empty correlation IDs
  and IDs erased by custom redaction normalize to null on admission and legacy
  recovery. Installation/session identifiers must remain 1–128 after scrub/clip;
  invalid new metadata rejects, corrupted legacy records drop individually, and
  valid neighboring event IDs survive. A real JVM private-spool regression also
  verifies normalized rewrite and upload of retained neighbors.
* Android debug AAR compiled successfully for API 26+. Lint: **0 errors**;
  eight dependency/tool-version update warnings. No physical Android test run.
* arm64 device and arm64 simulator static iOS frameworks linked successfully.
  Swift factory/JSON-bridge example typechecked against the final simulator
  framework. This is not a real app/physical iOS backend delivery claim.
* The coordinator reran the real local backend KMP/JVM smoke **after** the final
  transport deadline revision: one committed, sanitized event, no key in spool,
  and the disposable ingestion key revoked afterward. It executes the prebuilt
  JVM runner with an environment-only credential, not a Gradle build carrying
  that credential. This remains JVM delivery evidence, not Android device or
  full native iOS host-app delivery evidence.

The coordinator's app27 real-API smoke above predates the final identifier-only
normalization change. The identifier revision was checked with the JVM/native
regressions and platform rebuilds here; no new real-API key was used by this worker.

## Reproduce

From this module, with JAVA_HOME/JDK17, ANDROID_HOME and the isolated cache
variables described in README:

```sh
/path/to/gradle-8.13/bin/gradle --no-daemon jvmTest assembleDebug lintDebug \
  linkDebugFrameworkIosSimulatorArm64 linkDebugFrameworkIosArm64 \
  linkDebugTestIosSimulatorArm64 prepareLocalSmoke
sh scripts/native-tests.sh
```

Native script creates/deletes only its own simulator in
`build/isolated-simulators`; after execution no owned test device remains.
Shared/booted/user simulators and physical devices were not modified.

For the coordinator's real local API harness, export PROXYCEPT_TEST_BASE_URL,
PROXYCEPT_TEST_INGEST_KEY, PROXYCEPT_TEST_DEBUG_SESSION and
PROXYCEPT_TEST_SPOOL_DIR in memory, then:

```sh
JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home \
  sh scripts/local-smoke.sh
```

No secret is printed, accepted on command line, or written to a token file.
Native frameworks, AARs, generated fixture sources, reports, classpath, toolchains
and caches stay in ignored build/cache folders. Temporary top-level build logs
were removed for handoff; only source/tests/examples/scripts/docs are untracked
handoff files.
