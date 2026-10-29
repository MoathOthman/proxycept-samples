# Validation record

Validated on 2026-10-29 with Apple Swift 6.2.4, arm64 macOS and the Xcode iOS Simulator 26.2 SDK.

- **32 XCTest tests passed, 0 failures**, including 3 real URLSession tests against
  an independent ephemeral localhost HTTP server (macOS system Python).
- **Strict concurrency build passed** with `-strict-concurrency=complete` and
  `-warnings-as-errors` for the SDK sources.
- **Prior implementation validation: generic iOS Simulator build-for-testing passed** for the SDK, the SwiftUI
  executable demo and iOS XCTest bundle. Both arm64 and x86_64 simulator slices
  compiled. Xcode printed only the benign AppIntents metadata extraction warning
  for targets that do not depend on AppIntents. This iOS build was not rerun for
  the attribute-validation follow-up; the additional regressions ran on macOS.
- No simulator boot/install/launch, device settings changes, production backend
  calls, commit, push or deployment were performed.

Commands, run from the public clone root (environment cache overrides are needed
only in the restricted development environment):

```sh
CLANG_MODULE_CACHE_PATH=/private/tmp/proxycept-swift-module-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/proxycept-swift-module-cache \
swift test --disable-sandbox --package-path sdks/swift \
  --scratch-path /private/tmp/proxycept-swift-build

CLANG_MODULE_CACHE_PATH=/private/tmp/proxycept-swift-module-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/proxycept-swift-module-cache \
swift build --disable-sandbox --package-path sdks/swift \
  --scratch-path /private/tmp/proxycept-swift-strict-build \
  -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors

CLANG_MODULE_CACHE_PATH=/private/tmp/proxycept-swift-module-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/proxycept-swift-module-cache \
xcodebuild -project sdks/swift/Examples/LoopbackDemo/LoopbackDemo.xcodeproj \
  -scheme LoopbackDemo -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /private/tmp/proxycept-swift-ios-build \
  -clonedSourcePackagesDirPath /private/tmp/proxycept-swift-ios-packages \
  CODE_SIGNING_ALLOWED=NO build-for-testing
```

The sandbox initially denied ephemeral localhost binds; the full suite above
passed with local networking enabled. macOS `/tmp` does not give a useful
`isExcludedFromBackup` readback here; backup/protection assertions are conditional
on iOS. They **compiled but were not executed on iOS**. A successful simulator
build is not a runtime delivery or device-lock protection test. Physical-device
lock/unlock, suspension, full disk, power loss, real TLS/backend acceptance and
production ingestion quotas have not been tested. Redaction remains best effort.
The storage-failure test simulates an unwritable snapshot path, not physical disk
exhaustion. No SwiftyBeaver dependency or adapter is included.

The demo executable is produced at:
`/private/tmp/proxycept-swift-ios-build/Build/Products/Debug-iphonesimulator/LoopbackDemo.app`
with bundle ID `com.proxycept.logging.loopback-demo`. The operator/main task owns
any simulator run; start `Examples/loopback_server.py` on host loopback port 18880
first if exercising the demo. The fixture key is public test data.

## Attribute-validation follow-up

Empty attribute names and finite numeric magnitudes above `1e308` now reject the
individual log event before spool admission. Both signs of the inclusive numeric
boundary remain supported. An independent fake ingest validator rejects an entire
batch with 422 if either rule is violated, so the mixed-event regression verifies
actual batch safety rather than only testing a helper. Legacy spool validation
filters invalid events individually, preserves valid neighbors and their sequence
numbers, and increments `invalid` instead of dropping the whole spool.

The nested README now documents the root remote Git URL package facade after its
PR is merged, while retaining local nested-package installation instructions.
Root package files are owned by the main task and were not edited here.

Repository-root facade validation also passed: **32 tests, 0 failures**. Command:

```sh
CLANG_MODULE_CACHE_PATH=/private/tmp/proxycept-swift-module-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/proxycept-swift-module-cache \
swift test --disable-sandbox --scratch-path /private/tmp/proxycept-swift-root-build
```

## Exact test inventory

### ConcurrencyTests.swift (4)

- `testConcurrentFlushesShareSingleRequest`
- `testDisableIgnoresInFlightAcknowledgement`
- `testCredentialRotationIgnoresStaleAuthenticationFailure`
- `testStorageFailureRetainsMemoryAndRecovers`

### LoggerTests.swift (25)

- `testFrozenWireAndOffMainTransport`
- `testRedactsBeforeSpoolIncludingKeysMetadataAndCorrelation`
- `testRestartRetainsEventIDsSequenceAndInstallation`
- `testCountAndByteBoundsDropOldest`
- `testFiftyEventBatchLimitAndNullCorrelation`
- `testExpiredEventsRemovedFromDiskWithoutSending`
- `testAuthenticationStopsUntilCredentialReconfiguration`
- `testBackoffForNetworkServerAndInvalidAcknowledgement`
- `testRetryAfterSecondsAndHTTPDate`
- `test413ShrinksBatchThenDropsSingleOversize`
- `testPermanentFailureDropsBatch`
- `testDisablePurgesAndClosePreserves`
- `testInvalidAndUTF8OversizeEventsRejected`
- `testInvalidAttributesNeverPoisonMixedBatch`
- `testInvalidLegacyAttributesDoNotDiscardValidSpoolNeighbors`
- `testCorruptAndOversizeSpoolRecovery`
- `testExclusiveSpoolOwnership`
- `testEndpointAndTokenValidation`
- `testForegroundTimerFlushesAtTwoSeconds`
- `testBackgroundPausesAutomaticDelivery`
- `testDuplicateAcknowledgementCommitsQueue`
- `testDecodedBatchByteLimit`
- `testRestartSeparatesOriginalSessionMetadata`
- `testUnicodeScalarLimitsAndSymlinkDirectoryRefusal`
- `testRedirectDelegateRejectsCrossOriginAndSameOrigin`

### URLSessionTests.swift (3)

- `testRealURLSessionWireAgainstLoopbackServer`
- `testRealSessionDoesNotFollowRedirect`
- `testRealSessionBoundsResponseMemory`

