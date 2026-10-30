#!/usr/bin/env python3
"""Explicit operator-only install/launch. Never called by SDK build/test tasks.

Requires an operator-selected device, a prebuilt example APK and runtime local
configuration. The coordinator owns temporary adb reverse mappings and key
issuance/revocation. No credential is passed in arguments, compiled or printed.
"""

import os
from pathlib import Path
import re
import shutil
import subprocess
import time


def main():
    device = os.environ.get("PROXYCEPT_ANDROID_DEVICE")
    if not device or not re.fullmatch(r"[A-Za-z0-9_.:-]+", device):
        raise SystemExit("Select the operator-owned device with PROXYCEPT_ANDROID_DEVICE")
    adb = os.environ.get("PROXYCEPT_ADB") or shutil.which("adb")
    if not adb:
        sdk = os.environ.get("ANDROID_HOME") or os.environ.get("ANDROID_SDK_ROOT")
        adb = str(Path(sdk) / "platform-tools" / "adb") if sdk else None
    if not adb or not Path(adb).is_file():
        raise SystemExit("Set PROXYCEPT_ADB to the installed adb executable")
    url = os.environ.get("PROXYCEPT_TEST_CONFIG_URL", "http://127.0.0.1:18881/sdk-test-config")
    if url != "http://127.0.0.1:18881/sdk-test-config":
        raise SystemExit("Only the disposable loopback configuration endpoint is allowed")
    root = Path(__file__).resolve().parents[1]
    apk = root / "example/android/app/build/outputs/apk/debug/app-debug.apk"
    if not apk.is_file():
        raise SystemExit("Build the Android runtime example APK first, without credentials")
    package = "com.proxycept.reactnative.example"
    # Native config mode needs only a fixture URL. Never propagate legacy core
    # runner credentials into adb or other child command environments.
    child_env = {key: value for key, value in os.environ.items() if key not in {
        "PROXYCEPT_TEST_INGEST_KEY", "PROXYCEPT_TEST_DEBUG_SESSION", "PROXYCEPT_TEST_SPOOL_DIR",
    }}

    def command(*args):
        return subprocess.run([adb, "-s", device, *args], capture_output=True,
                              text=True, check=True, timeout=60, env=child_env).stdout

    command("install", "-r", "-t", str(apk))
    command("shell", "am", "force-stop", package)
    command("shell", "am", "start", "-n", package + "/.MainActivity",
            "--es", "PROXYCEPT_TEST_CONFIG_URL", url)
    deadline = time.monotonic() + 45
    while time.monotonic() < deadline:
        result = subprocess.run([adb, "-s", device, "shell", "pidof", package],
                                capture_output=True, text=True, timeout=10, env=child_env)
        for pid in result.stdout.strip().split():
            if not pid.isdigit():
                raise SystemExit("Unexpected test app process identifier")
            # Only this test application's process and JS tag; never broad device logs.
            output = command("logcat", "-d", "--pid", pid, "-s", "ReactNativeJS:I")
            match = re.search(r"PASS rn-js-native committed=1 queued=0 hermes=(true|false) bridgeless=(true|false)", output)
            if match:
                if match.groups() != ("true", "true"):
                    raise SystemExit("Expected Hermes and bridgeless runtime")
                print(match.group(0), flush=True)
                return
            if "FAIL rn-js-native smoke" in output:
                raise SystemExit("RN Android runtime test reported failure")
        time.sleep(.25)
    raise SystemExit("RN Android test app did not report completion within 45 seconds")


if __name__ == "__main__":
    main()
