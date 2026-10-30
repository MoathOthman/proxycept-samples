"""Host-only runner validation with a fake adb executable; no Android device calls."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

RUNNER = Path(__file__).resolve().parents[3] / "scripts/run-android-runtime.py"


class OperatorRunnerTest(unittest.TestCase):
    def test_mandatory_selection_fails_before_adb(self):
        env = os.environ.copy()
        env.pop("PROXYCEPT_ADB", None)
        env.pop("PROXYCEPT_ANDROID_DEVICE", None)
        result = subprocess.run([sys.executable, str(RUNNER)], capture_output=True, text=True, env=env)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertIn("Select the operator-owned device", result.stderr)

    def test_scoped_calls_and_nonsecret_only_output(self):
        with tempfile.TemporaryDirectory() as folder:
            # A clean source checkout need not contain an assembled APK. This
            # test exercises command scoping with an isolated fake host tree.
            root = Path(folder) / "sdk"
            runner = root / "scripts/run-android-runtime.py"
            runner.parent.mkdir(parents=True)
            runner.write_text(RUNNER.read_text())
            apk = root / "example/android/app/build/outputs/apk/debug/app-debug.apk"
            apk.parent.mkdir(parents=True)
            apk.write_bytes(b"operator-test-fixture")
            executable = Path(folder) / "fake-adb"
            trace = Path(folder) / "trace.jsonl"
            executable.write_text("#!" + sys.executable + "\n" + '''
import json, os, sys
args = sys.argv[1:]
with open(os.environ['FAKE_ADB_TRACE'], 'a') as f:
    f.write(json.dumps({'args': args, 'keyPresent': 'PROXYCEPT_TEST_INGEST_KEY' in os.environ}) + '\\n')
if 'pidof' in args: print('12345')
elif 'logcat' in args: print('PASS rn-js-native committed=1 queued=0 hermes=true bridgeless=true')
elif any(x.startswith("date '") for x in args): print('10-30 12:00:00.000')
''')
            executable.chmod(0o700)
            env = dict(os.environ, PROXYCEPT_ADB=str(executable), PROXYCEPT_ANDROID_DEVICE="explicit-test-device",
                       PROXYCEPT_TEST_CONFIG_URL="http://127.0.0.1:18881/sdk-test-config",
                       PROXYCEPT_TEST_INGEST_KEY="fixture-never-in-adb-env", FAKE_ADB_TRACE=str(trace))
            result = subprocess.run([sys.executable, str(runner)], capture_output=True, text=True, env=env)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, 'PASS rn-js-native committed=1 queued=0 hermes=true bridgeless=true\n')
            calls = [json.loads(line) for line in trace.read_text().splitlines()]
            self.assertTrue(all(row['args'][:2] == ['-s', 'explicit-test-device'] for row in calls))
            self.assertTrue(all(not row['keyPresent'] for row in calls))
            self.assertFalse(any('reverse' in row['args'] for row in calls))
            logs = [row['args'] for row in calls if 'logcat' in row['args']]
            self.assertTrue(logs)
            self.assertTrue(all('--pid' in args and '12345' in args and 'ReactNativeJS:I' in args for args in logs))


if __name__ == '__main__':
    unittest.main()
