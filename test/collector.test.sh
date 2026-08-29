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
chmod +x "$FIXTURE_DIR/bin/nvidia-smi" "$FIXTURE_DIR/bin/lspci" "$FIXTURE_DIR/bin/sensors"

run_collector() {
  PATH="$FIXTURE_DIR/bin:/usr/bin:/bin" \
  HWMON_ROOT="$FIXTURE_DIR/hwmon" \
  THERMAL_ROOT="$FIXTURE_DIR/thermal" \
  DRM_ROOT="$FIXTURE_DIR/drm" \
  PROC_STAT_PATH="$FIXTURE_DIR/proc/stat" \
  MEMINFO_PATH="$FIXTURE_DIR/proc/meminfo" \
  OMARCHY_INSTALL_LOG="$FIXTURE_DIR/omarchy-install.log" \
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

rm -f "$FIXTURE_DIR/omarchy-install.log"
run_collector >"$SNAPSHOT"
assert_jq "$SNAPSHOT" '.os == null' "missing install log degrades to null, not a crash"
assert_jq "$SNAPSHOT" '.meta.warnings | all(contains("install date") | not)' "missing install log stays silent"
printf '=== Omarchy Installation Started: 2024-01-01 00:00:00 ===\n' >"$FIXTURE_DIR/omarchy-install.log"

run_collector --static-only >"$SNAPSHOT"
assert_jq "$SNAPSHOT" ".os.installedAtMs == $expected_install_ms and (keys == [\"os\"])" "static-only mode returns only install metadata"

run_collector --dynamic-only >"$SNAPSHOT"
assert_jq "$SNAPSHOT" 'has("os") | not' "dynamic-only mode omits install metadata"

printf '%s\n' '#!/bin/bash' 'exit 9' >"$FIXTURE_DIR/bin/nvidia-smi"
chmod +x "$FIXTURE_DIR/bin/nvidia-smi"
run_collector >"$SNAPSHOT"
assert_jq "$SNAPSHOT" '.gpus | length == 2' "command failure does not discard detected GPUs"
assert_jq "$SNAPSHOT" '.gpus[0].vendor == "nvidia" and .gpus[0].utilPercent == null' "failed NVIDIA metrics degrade to nullable fields"
assert_jq "$SNAPSHOT" '.meta.warnings | any(contains("nvidia-smi failed"))' "command failure produces a diagnostic warning"

if [ "$failures" -gt 0 ]; then
  printf '\n%s collector test(s) failed\n' "$failures" >&2
  exit 1
fi

printf '\nall collector tests passed\n'
