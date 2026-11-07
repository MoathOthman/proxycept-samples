# Application logging SDK source release

This change prepares React Native, Flutter and Kotlin Multiplatform alongside the
existing Swift and Kotlin SDKs. All use the same schema-version-1 ingestion API
and dedicated application ingestion keys. No credentials are included.

## Availability and installation

This is a **source preview**, not an npm, pub.dev or Maven Central publication.
Use a reviewed Git revision and local source dependencies. Do not run a package
registry install command for a package that is not published. The React Native
package retains `private: true`; Flutter retains `publish_to: none`.

- [Swift](sdks/swift/README.md): root Swift Package Manager product or local package.
- [Kotlin/Android](sdks/kotlin/README.md): local Gradle module.
- [React Native](sdks/react-native/README.md): build JS/declarations, then install
  the local package, install pods and rebuild the native app. RN 0.82.1/React 19.1.1;
  iOS 15.1+, Android API 24+. Expo Go is unsupported.
- [Flutter](sdks/flutter/README.md): local path plugin. Flutter 3.47.9/Dart 3.13.7;
  iOS 15+, Android API 24+. Mobile only, not Flutter web.
- [Kotlin Multiplatform](sdks/kotlin-multiplatform/README.md): local Gradle module
  or exported Apple framework. Kotlin 2.3.21/Gradle 8.13/JDK 17;
  Android API 26+, iOS 14+.

Hosted App Logs is available on paid plans. Source SDK availability does not enable
collection on a self-hosted server; its operator must enable that feature. See the
[App Logs quickstart](https://proxycept.com/guides/app-logs-quickstart) after its
separate website PR is deployed. Until then, follow the complete README in your SDK.

## Release boundaries

Logging is explicit. No client captures another app's console, configures a VPN,
installs a proxy certificate, captures network bodies or injects headers automatically.
Swift/Kotlin's opt-in request-tagging helpers are also ported into React Native's
bundled native cores; the JS API still accepts an explicitly supplied correlation ID
and does not promise a JS request-tagging helper. Framework hosts own HTTP tagging.

Keys are supplied at runtime and are not written into SDK spool files. Redaction,
private bounded queues, retries, acknowledgement validation and three-day expiry
are covered by SDK tests, but are not a guarantee of personal-data removal,
uninterrupted OS background execution, or compatibility with every framework/OS.
A successful log call means admission, not a confirmed server commit.

The historical October 30 runtime evidence in SDK validation documents is dated.
The November release verification is recorded separately below; compiling a target
is not presented as an executed device test. No registry, store or production
publication is performed by this PR.

## Verification — 7 November 2026

Run on macOS with Xcode 26.3 / iOS Simulator 26.2, JDK 17, Gradle 8.13,
Android SDK API 35 and the toolchain versions above. These results qualify this
source revision; minimum supported OS declarations are not a tested device matrix.

- Swift root package: **39 tests passed**.
- Kotlin standalone SDK: **34 JVM tests passed**, JAR built.
- React Native: **19 JS tests passed**, TypeScript check/build, native provenance
  check and `npm pack --dry-run` passed. Bundled Swift: **45 tests passed**, also
  built with strict concurrency and warnings as errors. Bundled JVM: **38 tests
  passed**. The Android debug host APK and CocoaPods iOS simulator host app built.
- Flutter: **66 tests passed**, analyzer clean; Android debug APK and iOS simulator
  app built. Integration tests ran the native storage channel and confirmed a
  redacted event committed to the current local API on both an API-35 ARM64 emulator and iOS Simulator 26.2.
- KMP: **27 JVM tests passed**; Android AAR/lint and both arm64 Apple frameworks
  built. **20 Apple-native simulator tests passed**, including actual Apple
  transport and cross-origin redirect refusal. The JVM runner committed an event
  to the current local API.
- React Native's full JavaScript-to-native bridge committed a redacted event to
  the local API on both iOS Simulator 26.2 and the API-35 ARM64 emulator. The Swift
  core and Flutter/Dart host runners separately passed the same API smoke check.
- Shared admission fixture matches the private ingestion schema's test vectors.
  Local runtime keys were synthetic, provisioned at runtime and revoked afterward;
  they were not compiled into mobile artifacts. No production traffic was sent.

The portable PR workflow reruns host tests and builds; it does not claim to run
this entire mobile runtime matrix. No physical-device, minimum-OS, store-signing
or package-registry release qualification is implied. iOS Simulator cannot fully
certify hardware Data Protection; Flutter's storage test reports that distinction.
Flutter's current example uses CocoaPods and emits an upcoming SwiftPM migration
notice; its Android host also emits a future Kotlin Gradle plugin support notice.
These do not prevent the tested source-preview builds.
