# Flutter logging validation

Date: 2026-10-30. Official Flutter 3.47.9 / Dart 3.13.7, source-only SDK.
No production request, publish, merge, or deployment is part of these checks.

## Host tests

Final host result: **66 passed** (52 core/isolate/transport/storage tests plus
14 native-policy decision tests). Static analysis reports no issues.

Run from `sdks/flutter`:

```sh
FLUTTER_SUPPRESS_ANALYTICS=true /private/tmp/proxycept-flutter/bin/flutter --suppress-analytics analyze --no-pub
FLUTTER_SUPPRESS_ANALYTICS=true /private/tmp/proxycept-flutter/bin/flutter --suppress-analytics test --no-pub
```

Coverage includes all ten shared `../conformance/attribute-vectors.json` cases;
mixed valid/invalid admission and legacy recovery; malformed UTF-16 in fields,
metadata, attribute keys and values; UTC timestamps; serialized count/byte bounds;
expiry/overflow; pre-write redaction; stable retry IDs; strict committed ACK counts;
backoff/Retry-After/auth/413; storage failure; disable/storage/network races; real
loopback HTTP redirects, response cap, compressed-response refusal and timeout;
real POSIX ownership/modes; and the public client's dedicated isolate.

The shutdown regression fills eight ordinary RPC slots without awaiting them,
then closes and immediately reopens the spool with the queued event retained.
The privacy regression reserves purge under the same saturation and verifies an
empty reopened queue. Retaining disable can be upgraded to a coalesced purge.
Final-write failure is reported after closing transport/storage rather than
silently killing an isolate before cleanup.

Fourteen policy tests keep physical iOS strict and permit only the explicit
simulator/unreported exception. All backup/directory/file-private requirements
still apply; known None/wrong/mixed protection classes cannot use the exception.

## Build evidence

- Android debug example APK compiled successfully with the native Kotlin
  no-backup/private-spool bridge; artifact stays under ignored `example/build`.
- iOS simulator example and runtime-test target compiled successfully with the
  Swift private-spool bridge, CocoaPods, and code signing disabled.
- Known future-toolchain migration warnings: iOS plugin SwiftPM support and
  Android plugin Built-in Kotlin adoption are not implemented. Current builds pass.
- Example Xcode project/workspace/shared scheme source metadata has narrowly
  scoped ignore exceptions; user state, Pods, DerivedData and binaries remain ignored.
  Builds use Flutter-generated Gradle wrappers; do not overwrite custom source
  and debug-only network policy with a blanket `flutter create` regeneration.

## Independently operated local integration

Main's harness reported:

- Dart CLI core/isolate -> local API: one redacted committed event, spool credential
  scrub verified, synthetic key revoked.
- Actual iOS Simulator native test: private spool, backup flag and POSIX modes
  verified, one redacted committed event, synthetic key revoked. The simulator
  does not report file/directory Data Protection classes; the test explicitly
  reports **UNVERIFIED** for that metadata. It does not certify hardware encryption,
  physical iOS lock behavior or actual backup/restore behavior.
- Actual Android device native test: private/no-backup spool -> SDK -> local API,
  one redacted committed event, synthetic key revoked; temporary adb reverse
  mappings for 18880/18881 were removed by main.

Both native integration targets were rebuilt and rerun against the final SDK
source **after the saturated-close fix**, and both **passed**: iOS Simulator
(disposable app 35) and physical Android (disposable app 36) each delivered one
committed, redacted local API event. Both synthetic keys were revoked; main removed
the Android task's temporary adb port mappings. The Android post-fix runtime log is
`/private/tmp/proxycept-cross-flutter-android-postfix.log`. The iOS Simulator Data
Protection metadata remains explicitly **UNVERIFIED**, as described above.

The post-fix precompiled Dart core rerun also **passed**: one committed/redacted
local API event (disposable app 33), spool scrub verified by the harness, key revoked.
This host core run is separate from the two post-fix native runtime passes.

Main compiled the kernel before provisioning the runtime key:

```sh
/private/tmp/proxycept-flutter/bin/dart --suppress-analytics compile kernel tool/local_smoke.dart -o build/local_smoke.dill
# Under the local harness, credentials arrive only in the runtime environment:
/private/tmp/proxycept-flutter/bin/cache/dart-sdk/bin/dart build/local_smoke.dill
```

The bare-VM kernel invocation does **not** accept `--suppress-analytics`; runtime
inherits the harness suppression environment. No credential is in compiler
arguments or the ignored kernel artifact. Local operator evidence paths:
`/private/tmp/proxycept-cross-flutter-smoke-compile.log` and
`/private/tmp/proxycept-cross-flutter-core-final.log`. These local logs are not
package source or public CI evidence.

Only the nonsecret configuration URL is passed to the native builder. The test
fetches synthetic `{base_url,ingest_key,debug_session_id}` from the ephemeral
loopback configuration server at runtime. Credentials are never compiled,
written to test assets, supplied in argv/defines, or printed by these runners.
Main owns endpoint startup, test-key revocation and device installation/routing.
See README for exact commands and remaining platform/storage limitations.
