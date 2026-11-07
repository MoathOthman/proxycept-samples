# Proxycept Flutter mobile example

This app uses the SDK's native private/no-backup spool helper and lifecycle adapter.
It contains no ingest credential. Enter a disposable local key at runtime; it is
cleared from the text controller after setup. Nothing is sent until you press
**Log and flush**. The default endpoint is numeric loopback port 18880, not production.

Run `flutter pub get`, then build with `flutter build apk --debug` or
`flutter build ios --simulator --debug --no-codesign`. Device installation and
launch are operator-owned; compilation is not native/device E2E proof.

Android API 24+ and iOS 15+ follow Flutter 3.47's support matrix. Android needs
`adb reverse tcp:18880 tcp:18880` (device owner only) for local host access; the
SDK refuses cleartext to emulator 10.0.2.2 or DNS localhost. The checked-in debug-only networking policy permits numeric loopback for the
synthetic integration test. Release cleartext/ATS policy is unchanged; never copy
a blanket allow-cleartext setting into a production app.
