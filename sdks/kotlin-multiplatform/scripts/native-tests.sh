#!/bin/sh
set -eu
# Own a separate device set. Never use 'booted', an existing device, or any physical device.
task_root=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
task_binary="$task_root/build/bin/iosSimulatorArm64/debugTest/test.kexe"
[ -f "$task_binary" ] || { echo 'Build linkDebugTestIosSimulatorArm64 first.' >&2; exit 1; }
task_set="$task_root/build/isolated-simulators"
mkdir -p "$task_set"
task_udid=$(xcrun simctl --set "$task_set" create ProxyceptKmpUnit com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro com.apple.CoreSimulator.SimRuntime.iOS-26-2)
task_server=
cleanup() {
    if [ -n "$task_server" ]; then kill "$task_server" 2>/dev/null || true; wait "$task_server" 2>/dev/null || true; fi
    xcrun simctl --set "$task_set" shutdown "$task_udid" >/dev/null 2>&1 || true
    xcrun simctl --set "$task_set" delete "$task_udid" >/dev/null 2>&1 || true
}
trap cleanup EXIT HUP INT TERM
xcrun simctl --set "$task_set" boot "$task_udid"
xcrun simctl --set "$task_set" bootstatus "$task_udid" -b
task_port_file="$task_root/build/native-loopback-port"
rm -f "$task_port_file"
python3 "$task_root/scripts/native-loopback.py" --port-file "$task_port_file" &
task_server=$!
task_attempt=0
while [ ! -f "$task_port_file" ]; do
    task_attempt=$((task_attempt + 1))
    [ "$task_attempt" -lt 100 ] || { echo 'Loopback fixture failed to start' >&2; exit 1; }
    sleep 0.1
done
SIMCTL_CHILD_PROXYCEPT_NATIVE_LOOPBACK_BASE="http://127.0.0.1:$(cat "$task_port_file")" \
    xcrun simctl --set "$task_set" spawn "$task_udid" "$task_binary" --ktest_logger=SIMPLE
