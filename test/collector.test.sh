#!/bin/bash

set -eu

PROJECT_DIR=$(cd "$(dirname "$0")/.." && pwd)
FIXTURE_DIR=$(mktemp -d)
trap 'rm -rf "$FIXTURE_DIR"' EXIT

failures=0

assert_jq() {
  local file="$1" expression="$2" label="$3"
  if jq -e "$expression" "$file" >/dev/null; then
    printf 'ok - %s\n' "$label"
  else
    printf 'FAIL: %s\n' "$label" >&2
    failures=$((failures + 1))
  fi
}

assert_true() {
  local label="$1"
  shift
  if "$@"; then
    printf 'ok - %s\n' "$label"
  else
    printf 'FAIL: %s\n' "$label" >&2
    failures=$((failures + 1))
  fi
}

pid_file_process_is_gone() {
  local pid_file="$1" pid attempt
  [ -s "$pid_file" ] || return 1
  pid=$(head -n1 "$pid_file")
  [[ $pid =~ ^[0-9]+$ ]] || return 1
  for attempt in {1..40}; do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.05
  done
  return 1
}

mkdir -p \
  "$FIXTURE_DIR/bin" \
  "$FIXTURE_DIR/proc" \
  "$FIXTURE_DIR/hwmon/hwmon7" \
  "$FIXTURE_DIR/hwmon/hwmon9" \
  "$FIXTURE_DIR/thermal" \
  "$FIXTURE_DIR/drm/card0" \
  "$FIXTURE_DIR/drm/card1" \
  "$FIXTURE_DIR/pci/0000:01:00.0" \
  "$FIXTURE_DIR/pci/0000:00:02.0/hwmon/hwmon4"

printf 'cpu  100 0 50 850 0 0 0 0 0 0\n' >"$FIXTURE_DIR/proc/stat"
printf 'MemTotal:       33554432 kB\nMemAvailable:   20971520 kB\n' >"$FIXTURE_DIR/proc/meminfo"
printf 'processor\t: 0\nvendor_id\t: AuthenticAMD\nmodel name\t: AMD Ryzen 9 5900HX with Radeon Graphics\n' >"$FIXTURE_DIR/proc/cpuinfo"
printf '=== Omarchy Installation Started: 2024-01-01 00:00:00 ===\n' >"$FIXTURE_DIR/omarchy-install.log"

printf 'k10temp\n' >"$FIXTURE_DIR/hwmon/hwmon7/name"
printf 'Tctl\n' >"$FIXTURE_DIR/hwmon/hwmon7/temp1_label"
printf '55000\n' >"$FIXTURE_DIR/hwmon/hwmon7/temp1_input"
printf 'nct6798\n' >"$FIXTURE_DIR/hwmon/hwmon9/name"
printf 'CPU Fan\n' >"$FIXTURE_DIR/hwmon/hwmon9/fan1_label"
printf '1840\n' >"$FIXTURE_DIR/hwmon/hwmon9/fan1_input"
printf '760\n' >"$FIXTURE_DIR/hwmon/hwmon9/fan2_input"

printf '0x10de\n' >"$FIXTURE_DIR/pci/0000:01:00.0/vendor"
printf '0x8086\n' >"$FIXTURE_DIR/pci/0000:00:02.0/vendor"
printf 'DRIVER=i915\n' >"$FIXTURE_DIR/pci/0000:00:02.0/uevent"
printf 'i915\n' >"$FIXTURE_DIR/pci/0000:00:02.0/hwmon/hwmon4/name"
printf '44000\n' >"$FIXTURE_DIR/pci/0000:00:02.0/hwmon/hwmon4/temp1_input"
ln -s ../../pci/0000:01:00.0 "$FIXTURE_DIR/drm/card0/device"
ln -s ../../pci/0000:00:02.0 "$FIXTURE_DIR/drm/card1/device"

printf '%s\n' \
  '#!/bin/bash' \
  'printf "0, 00000000:01:00.0, Test NVIDIA, 37, N/A, N/A, 512, 8192\\n"' \
  >"$FIXTURE_DIR/bin/nvidia-smi"
printf '%s\n' \
  '#!/bin/bash' \
  'case "$*" in' \
  '  *00:02.0*) printf "00:02.0 VGA compatible controller: Intel Corporation Test Graphics\\n" ;;' \
  '  *) printf "01:00.0 VGA compatible controller: NVIDIA Corporation Test GPU\\n" ;;' \
  'esac' \
  >"$FIXTURE_DIR/bin/lspci"
printf '%s\n' \
  '#!/bin/bash' \
  'printf '\''{"nct6798-isa-0000":{"Chassis":{"fan2_input":760}}}\n'\''' \
  >"$FIXTURE_DIR/bin/sensors"
printf '%s\n' \
  '#!/bin/bash' \
  '[ "$#" -eq 3 ] && [ "$1" = "-c" ] && [ "$2" = "%W" ] || exit 2' \
  '[ -e "$3" ] || exit 1' \
  'printf "1700000000\n"' \
  >"$FIXTURE_DIR/bin/stat"
chmod +x "$FIXTURE_DIR/bin/nvidia-smi" "$FIXTURE_DIR/bin/lspci" "$FIXTURE_DIR/bin/sensors" "$FIXTURE_DIR/bin/stat"

run_collector() {
  PATH="${PATH_OVERRIDE:-$FIXTURE_DIR/bin:/usr/bin:/bin}" \
  HELPER_PID_FILE="${HELPER_PID_FILE:-}" \
  HWMON_ROOT="$FIXTURE_DIR/hwmon" \
  THERMAL_ROOT="$FIXTURE_DIR/thermal" \
  DRM_ROOT="$FIXTURE_DIR/drm" \
  PROC_STAT_PATH="$FIXTURE_DIR/proc/stat" \
  MEMINFO_PATH="$FIXTURE_DIR/proc/meminfo" \
  PROC_CPUINFO_PATH="$FIXTURE_DIR/proc/cpuinfo" \
  OMARCHY_INSTALL_LOG="$FIXTURE_DIR/omarchy-install.log" \
  ROOT_FS_PATH="${ROOT_FS_PATH_OVERRIDE:-$FIXTURE_DIR}" \
    "$PROJECT_DIR/bin/omarchy-hardware-collect.sh" "$@"
}

SNAPSHOT="$FIXTURE_DIR/snapshot.json"
run_collector >"$SNAPSHOT"

assert_jq "$SNAPSHOT" '.cpu.tempC == 55 and .memory.totalKB == 33554432' "CPU temperature and memory fixture"
assert_jq "$SNAPSHOT" '.fans == [{"label":"CPU Fan","rpm":1840},{"label":"Chassis","rpm":760}]' "multiple fan labels and RPM values"
assert_jq "$SNAPSHOT" '.gpus | length == 2' "multiple GPUs retained"
assert_jq "$SNAPSHOT" '.gpus[0].vendor == "nvidia" and .gpus[0].utilPercent == 37 and .gpus[0].tempC == null' "partial NVIDIA metrics retained"
assert_jq "$SNAPSHOT" '.gpus[1].vendor == "intel" and .gpus[1].tempC == 44 and .gpus[1].utilPercent == null' "Intel detection and independent temperature"
assert_jq "$SNAPSHOT" '.gpu == .gpus[0]' "legacy preferred GPU field retained"

expected_install_ms=$(( $(date -d "2024-01-01 00:00:00" +%s) * 1000 ))
assert_jq "$SNAPSHOT" ".os.installedAtMs == $expected_install_ms" "install date parsed from install log fixture"
assert_jq "$SNAPSHOT" '.cpuName == "AMD Ryzen 9 5900HX with Radeon Graphics"' "CPU name parsed from cpuinfo fixture"

rm -f "$FIXTURE_DIR/omarchy-install.log"
run_collector >"$SNAPSHOT"
assert_jq "$SNAPSHOT" '.os.installedAtMs == 1700000000000' "missing install log falls back to filesystem birth time"
assert_jq "$SNAPSHOT" '.meta.warnings | all(contains("install date") | not)' "missing install log stays silent"

ROOT_FS_PATH_OVERRIDE="$FIXTURE_DIR/no-such-path" run_collector >"$SNAPSHOT"
assert_jq "$SNAPSHOT" '.os == null' "missing install log and unreadable root fs degrades to null, not a crash"
unset ROOT_FS_PATH_OVERRIDE
printf '=== Omarchy Installation Started: 2024-01-01 00:00:00 ===\n' >"$FIXTURE_DIR/omarchy-install.log"

printf 'processor\t: 0\nvendor_id\t: AuthenticAMD\n' >"$FIXTURE_DIR/proc/cpuinfo"
run_collector >"$SNAPSHOT"
assert_jq "$SNAPSHOT" '.cpuName == null' "missing model name line degrades to null, not a crash"
assert_jq "$SNAPSHOT" '.meta.warnings | all(contains("cpu name") | not)' "missing model name stays silent"
printf 'processor\t: 0\nvendor_id\t: AuthenticAMD\nmodel name\t: AMD Ryzen 9 5900HX with Radeon Graphics\n' >"$FIXTURE_DIR/proc/cpuinfo"

run_collector --static-only >"$SNAPSHOT"
assert_jq "$SNAPSHOT" ".os.installedAtMs == $expected_install_ms and .cpuName == \"AMD Ryzen 9 5900HX with Radeon Graphics\" and (keys == [\"cpuName\", \"os\"])" "static-only mode returns install metadata and cpu name"

{
  printf 'model name\t: '
  head -c 4096 /dev/zero | tr '\0' C
  printf '\n'
} >"$FIXTURE_DIR/proc/cpuinfo"
run_collector --static-only >"$SNAPSHOT"
assert_jq "$SNAPSHOT" '.cpuName | utf8bytelength == 256' "static CPU name is producer-capped to 256 bytes"
printf 'processor\t: 0\nvendor_id\t: AuthenticAMD\nmodel name\t: AMD Ryzen 9 5900HX with Radeon Graphics\n' >"$FIXTURE_DIR/proc/cpuinfo"

run_collector --dynamic-only >"$SNAPSHOT"
assert_jq "$SNAPSHOT" 'has("os") | not' "dynamic-only mode omits install metadata"
assert_jq "$SNAPSHOT" 'has("cpuName") | not' "dynamic-only mode omits cpu name"

printf '%s\n' '#!/bin/bash' 'exit 9' >"$FIXTURE_DIR/bin/nvidia-smi"
chmod +x "$FIXTURE_DIR/bin/nvidia-smi"
run_collector >"$SNAPSHOT"
assert_jq "$SNAPSHOT" '.gpus | length == 2' "command failure does not discard detected GPUs"
assert_jq "$SNAPSHOT" '.gpus[0].vendor == "nvidia" and .gpus[0].utilPercent == null' "failed NVIDIA metrics degrade to nullable fields"
assert_jq "$SNAPSHOT" '.meta.warnings | any(contains("nvidia-smi failed"))' "command failure produces a diagnostic warning"

# A one-byte overflow is small enough for a producer to exit successfully
# before its pipe closes. The collector must detect it by size, not rely on
# SIGPIPE or the producer's exit status.
printf '%s\n' \
  '#!/bin/bash' \
  'sleep 30 </dev/null >/dev/null 2>&1 &' \
  'child=$!' \
  '[ -n "${HELPER_PID_FILE:-}" ] && printf "%s\n" "$child" >"$HELPER_PID_FILE"' \
  'head -c 65537 /dev/zero | tr '\''\0'\'' X' \
  >"$FIXTURE_DIR/bin/nvidia-smi"
chmod +x "$FIXTURE_DIR/bin/nvidia-smi"
OVERFLOW_CHILD_PID="$FIXTURE_DIR/overflow-child.pid"
HELPER_PID_FILE="$OVERFLOW_CHILD_PID" run_collector --dynamic-only >"$SNAPSHOT"
assert_jq "$SNAPSHOT" '.gpus[0].vendor == "nvidia" and .gpus[0].utilPercent == null' "one-byte command overflow is rejected"
assert_jq "$SNAPSHOT" '.meta.warnings | any(contains("nvidia-smi failed"))' "command overflow produces a diagnostic warning"
assert_true "command overflow kills and reaps the helper process group" \
  pid_file_process_is_gone "$OVERFLOW_CHILD_PID"

# A timed-out producer is subject to the same complete-group cleanup. The
# child deliberately has no output descriptor, so this also proves cleanup is
# not merely an incidental SIGPIPE from the bounded reader.
printf '%s\n' \
  '#!/bin/bash' \
  'sleep 30 </dev/null >/dev/null 2>&1 &' \
  'child=$!' \
  '[ -n "${HELPER_PID_FILE:-}" ] && printf "%s\n" "$child" >"$HELPER_PID_FILE"' \
  'wait "$child"' \
  >"$FIXTURE_DIR/bin/nvidia-smi"
chmod +x "$FIXTURE_DIR/bin/nvidia-smi"
TIMEOUT_CHILD_PID="$FIXTURE_DIR/timeout-child.pid"
HELPER_PID_FILE="$TIMEOUT_CHILD_PID" run_collector --dynamic-only >"$SNAPSHOT"
assert_jq "$SNAPSHOT" '.meta.warnings | any(contains("nvidia-smi failed"))' \
  "command timeout produces a diagnostic warning"
assert_true "command timeout kills and reaps the helper process group" \
  pid_file_process_is_gone "$TIMEOUT_CHILD_PID"

# Restore a normal NVIDIA result for the remaining fixture cases.
printf '%s\n' \
  '#!/bin/bash' \
  'printf "0, 00000000:01:00.0, Test NVIDIA, 37, N/A, N/A, 512, 8192\\n"' \
  >"$FIXTURE_DIR/bin/nvidia-smi"
chmod +x "$FIXTURE_DIR/bin/nvidia-smi"

# Strings from device attributes are capped at read time, before they become
# shell variables or jq arguments.
head -c 4096 /dev/zero | tr '\0' L >"$FIXTURE_DIR/hwmon/hwmon9/fan1_label"
run_collector --dynamic-only >"$SNAPSHOT"
assert_jq "$SNAPSHOT" '.fans[0].label | utf8bytelength == 256' "device label is producer-capped to 256 bytes"
printf 'CPU Fan\n' >"$FIXTURE_DIR/hwmon/hwmon9/fan1_label"

# Enumeration limits count candidates and sit upstream of result assembly.
mkdir -p "$FIXTURE_DIR/hwmon/hwmon10"
printf 'synthetic\n' >"$FIXTURE_DIR/hwmon/hwmon10/name"
for n in $(seq 1 140); do
  printf '%s\n' "$((1000 + n))" >"$FIXTURE_DIR/hwmon/hwmon10/fan${n}_input"
done
run_collector --dynamic-only >"$SNAPSHOT"
assert_jq "$SNAPSHOT" '.fans | length == 128' "fan result count is capped"
rm -rf "$FIXTURE_DIR/hwmon/hwmon10"

# Exercise GPU count and bounded device-name output together.
printf '%s\n' \
  '#!/bin/bash' \
  'printf "00:00.0 VGA compatible controller: Synthetic "' \
  'head -c 4096 /dev/zero | tr '\''\0'\'' G' \
  'printf "\\n"' \
  >"$FIXTURE_DIR/bin/lspci"
chmod +x "$FIXTURE_DIR/bin/lspci"
for n in $(seq 2 41); do
  hex=$(printf '%02x' "$n")
  mkdir -p "$FIXTURE_DIR/drm/card$n" "$FIXTURE_DIR/pci/0000:02:$hex.0"
  printf '0x1002\n' >"$FIXTURE_DIR/pci/0000:02:$hex.0/vendor"
  ln -s "../../pci/0000:02:$hex.0" "$FIXTURE_DIR/drm/card$n/device"
done
run_collector --dynamic-only >"$SNAPSHOT"
assert_jq "$SNAPSHOT" '.gpus | length == 32' "GPU result and enumeration count are capped"
assert_jq "$SNAPSHOT" '.gpus | all(.name | utf8bytelength <= 256)' "GPU names are capped before JSON assembly"
for n in $(seq 2 41); do
  hex=$(printf '%02x' "$n")
  rm -rf "$FIXTURE_DIR/drm/card$n" "$FIXTURE_DIR/pci/0000:02:$hex.0"
done

# Make only the final dynamic jq producer flood stdout. The bounded emitter
# must stop it at MAX+1 and return a small, valid fallback object.
printf '%s\n' \
  '#!/bin/bash' \
  'for arg in "$@"; do' \
  '  case "$arg" in' \
  '    *"meta: { collectedAtMs:"*)' \
  '      sleep 30 </dev/null >/dev/null 2>&1 &' \
  '      child=$!' \
  '      [ -n "${HELPER_PID_FILE:-}" ] && printf "%s\n" "$child" >"$HELPER_PID_FILE"' \
  '      head -c 1048577 /dev/zero | tr '\''\0'\'' X' \
  '      exit 0' \
  '      ;;' \
  '    *"{os: \$os, cpuName: \$cpuName}"*) head -c 1048577 /dev/zero | tr '\''\0'\'' X; exit 0 ;;' \
  '  esac' \
  'done' \
  'exec /usr/bin/jq "$@"' \
  >"$FIXTURE_DIR/bin/jq"
chmod +x "$FIXTURE_DIR/bin/jq"
FINAL_JSON_CHILD_PID="$FIXTURE_DIR/final-json-child.pid"
HELPER_PID_FILE="$FINAL_JSON_CHILD_PID" run_collector --dynamic-only >"$SNAPSHOT"
assert_jq "$SNAPSHOT" '.meta.warnings | any(contains("exceeded the size limit"))' "oversized final JSON becomes a valid fallback"
assert_true "fallback JSON remains small" test "$(wc -c <"$SNAPSHOT")" -lt 1024
assert_true "final JSON overflow kills and reaps the producer process group" \
  pid_file_process_is_gone "$FINAL_JSON_CHILD_PID"
run_collector --static-only >"$SNAPSHOT"
assert_jq "$SNAPSHOT" '. == {"os":null,"cpuName":null}' "oversized static JSON becomes a valid fallback"
rm -f "$FIXTURE_DIR/bin/jq"

# Intermediate JSON producers use the same bounded process-group wrapper as
# hardware helpers. A faulty jq must not fill a command substitution or leave
# a forked descendant alive before the final JSON gate is reached.
printf '%s\n' \
  '#!/bin/bash' \
  'case "$*" in' \
  '  *"CPU Fan"*)' \
  '    sleep 30 </dev/null >/dev/null 2>&1 &' \
  '    child=$!' \
  '    [ -n "${HELPER_PID_FILE:-}" ] && printf "%s\n" "$child" >"$HELPER_PID_FILE"' \
  '    head -c 65537 /dev/zero | tr '\''\0'\'' J' \
  '    exit 0' \
  '    ;;' \
  'esac' \
  'exec /usr/bin/jq "$@"' \
  >"$FIXTURE_DIR/bin/jq"
chmod +x "$FIXTURE_DIR/bin/jq"
JSON_CHILD_PID="$FIXTURE_DIR/json-child.pid"
HELPER_PID_FILE="$JSON_CHILD_PID" run_collector --dynamic-only >"$SNAPSHOT"
assert_jq "$SNAPSHOT" 'type == "object" and (.fans | type == "array")' \
  "intermediate JSON overflow still yields a valid bounded snapshot"
assert_true "intermediate JSON overflow kills and reaps the producer process group" \
  pid_file_process_is_gone "$JSON_CHILD_PID"
rm -f "$FIXTURE_DIR/bin/jq"

# `timeout` bounds the optional hardware helpers, but the collector must still
# produce a real snapshot without it: only those helpers are skipped, never the
# /proc and /sys derived CPU, temperature, and memory data. Guards against the
# bounded-JSON emitter routing its own jq through the helper-only wrapper,
# which would turn a missing `timeout` into an entirely empty panel.
NOTIMEOUT_BIN="$FIXTURE_DIR/notimeout"
mkdir -p "$NOTIMEOUT_BIN"
for tool in bash jq awk sed find sort head wc cat basename dirname readlink \
  date nproc mktemp mkfifo rmdir rm tr; do
  for dir in /usr/bin /bin; do
    if [ -x "$dir/$tool" ]; then
      ln -sf "$dir/$tool" "$NOTIMEOUT_BIN/$tool"
      break
    fi
  done
done

assert_true "fixture PATH without timeout really lacks it" \
  test -z "$(PATH="$FIXTURE_DIR/bin:$NOTIMEOUT_BIN" command -v timeout || true)"

PATH_OVERRIDE="$FIXTURE_DIR/bin:$NOTIMEOUT_BIN" run_collector --dynamic-only >"$SNAPSHOT"
assert_jq "$SNAPSHOT" '.memory.totalKB == 33554432 and .cpu.tempC == 55 and .cpu.coreCount > 0' \
  "missing timeout still yields real CPU and memory data"
assert_jq "$SNAPSHOT" '.meta.warnings | all(contains("generation failed") | not)' \
  "missing timeout does not discard the whole snapshot"

# Without GNU timeout, Bash job control supplies the local producer group.
# Keep this path covered so the byte cap cannot accidentally move a faulty
# local producer outside the outer collector session/watchdog.
printf '%s\n' \
  '#!/bin/bash' \
  'case "$*" in' \
  '  *"CPU Fan"*)' \
  '    /usr/bin/sleep 30 </dev/null >/dev/null 2>&1 &' \
  '    child=$!' \
  '    [ -n "${HELPER_PID_FILE:-}" ] && printf "%s\n" "$child" >"$HELPER_PID_FILE"' \
  '    /usr/bin/head -c 65537 /dev/zero | /usr/bin/tr '\''\0'\'' M' \
  '    exit 0' \
  '    ;;' \
  'esac' \
  'exec /usr/bin/jq "$@"' \
  >"$FIXTURE_DIR/bin/jq"
chmod +x "$FIXTURE_DIR/bin/jq"
NOTIMEOUT_CHILD_PID="$FIXTURE_DIR/notimeout-child.pid"
PATH_OVERRIDE="$FIXTURE_DIR/bin:$NOTIMEOUT_BIN" HELPER_PID_FILE="$NOTIMEOUT_CHILD_PID" \
  run_collector --dynamic-only >"$SNAPSHOT"
assert_jq "$SNAPSHOT" 'type == "object" and (.fans | type == "array")' \
  "missing-timeout local overflow still yields valid JSON"
assert_true "missing-timeout local overflow kills and reaps its process group" \
  pid_file_process_is_gone "$NOTIMEOUT_CHILD_PID"
rm -f "$FIXTURE_DIR/bin/jq"

PATH_OVERRIDE="$FIXTURE_DIR/bin:$NOTIMEOUT_BIN" run_collector --static-only >"$SNAPSHOT"
assert_jq "$SNAPSHOT" '.cpuName == "AMD Ryzen 9 5900HX with Radeon Graphics"' \
  "missing timeout still yields static metadata"

if [ "$failures" -gt 0 ]; then
  printf '\n%s collector test(s) failed\n' "$failures" >&2
  exit 1
fi

printf '\nall collector tests passed\n'
