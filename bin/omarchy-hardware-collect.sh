#!/bin/bash
#
# omarchy-hardware-collect.sh: gathers CPU, GPU, memory, and fan metrics and
# prints a single JSON object to stdout. Designed to be run once per poll tick
# by HardwareService.qml.
#
# Contract: always print valid JSON and exit 0 if it was produced, no matter
# what hardware/tools are missing. A field that can't be determined is null
# (or an empty array for lists) plus an entry under meta.warnings, never a
# non-zero exit, a hang, or malformed output. No root required anywhere.

set -o pipefail

warnings=()

# Overridable for local testing/debugging against a captured sysfs snapshot
# (see README's "debugging sensor detection" section); defaults to the real
# path in normal operation.
HWMON_ROOT="${HWMON_ROOT:-/sys/class/hwmon}"
THERMAL_ROOT="${THERMAL_ROOT:-/sys/class/thermal}"
DRM_ROOT="${DRM_ROOT:-/sys/class/drm}"
PROC_STAT_PATH="${PROC_STAT_PATH:-/proc/stat}"
MEMINFO_PATH="${MEMINFO_PATH:-/proc/meminfo}"
PROC_CPUINFO_PATH="${PROC_CPUINFO_PATH:-/proc/cpuinfo}"
OMARCHY_INSTALL_LOG="${OMARCHY_INSTALL_LOG:-/var/log/omarchy-install.log}"
ROOT_FS_PATH="${ROOT_FS_PATH:-/}"
COLLECTOR_MODE="full"

# Item caps: no real machine has anywhere near this many fans or GPUs. These
# exist purely to bound loop count and JSON result size against a pathological
# or synthetic /sys tree, independent of the per-command byte caps below.
MAX_FAN_ITEMS=128
MAX_GPU_CARDS=32
MAX_NVIDIA_ITEMS=32
MAX_WARNINGS=64
MAX_STRING_BYTES=256
MAX_NUMBER_BYTES=64
MAX_DEVICE_SCAN_ITEMS=256

case "${1:-}" in
  "") ;;
  --dynamic-only) COLLECTOR_MODE="dynamic" ;;
  --static-only) COLLECTOR_MODE="static" ;;
  *)
    echo "usage: $0 [--dynamic-only|--static-only]" >&2
    exit 2
    ;;
esac

# Every captured external producer runs in a distinct process group within the
# collector's session. The separate group lets this script kill the complete
# producer tree immediately on overflow; retaining the outer session lets the
# QML watchdog sweep every in-flight group if the collector itself is killed.
# GNU timeout creates that group in normal installs. The monitor-mode fallback
# does the same for trusted local tools when timeout is unavailable.
MAX_CMD_OUTPUT_BYTES=65536
MAX_JSON_OUTPUT_BYTES=1048576

# Kill both the process group and its leader. The direct-PID signal is a
# fallback for the narrow launch race before timeout/job control establishes
# the group. Callers always wait afterward so killed children are reaped.
terminate_producer_group() {
  local producer_pid="$1"
  kill -KILL -- "-$producer_pid" 2>/dev/null || true
  kill -KILL -- "$producer_pid" 2>/dev/null || true
}

# Stream one producer into a caller-owned file, retaining only MAX+1 bytes.
# The reader and producer are waited concurrently: if the reader reaches the
# overflow byte first, the whole producer group is killed immediately; if the
# producer exits first, its group is still swept before the reader is reaped,
# preventing a forked child from keeping the pipe open or surviving unnoticed.
#
# Arguments: REQUIRE_TIMEOUT TIMEOUT_SECONDS MAX_BYTES OUTPUT_FILE COMMAND...
run_capped_to_file() {
  local require_timeout="$1" timeout_seconds="$2" max_bytes="$3" output_file="$4"
  local pipe_dir pipe_path producer_pid reader_pid completed_pid first_status input_fd
  local command_status=125 reader_status=125 size monitor_was_enabled=false
  shift 4

  pipe_dir=$(mktemp -d) || return 125
  pipe_path="$pipe_dir/output.pipe"
  if ! mkfifo -- "$pipe_path"; then
    rmdir -- "$pipe_dir" 2>/dev/null || true
    return 125
  fi

  # Bash otherwise connects an asynchronous command's stdin to /dev/null when
  # job control is disabled, which would silently discard a caller's pipe or
  # input redirection. Preserve it explicitly for the producer.
  if ! exec {input_fd}<&0; then
    rm -f -- "$pipe_path"
    rmdir -- "$pipe_dir" 2>/dev/null || true
    return 125
  fi

  if command -v timeout >/dev/null 2>&1; then
    timeout -k 1 "$timeout_seconds" "$@" <&"$input_fd" >"$pipe_path" &
    producer_pid=$!
  elif [ "$require_timeout" = true ]; then
    exec {input_fd}<&-
    rm -f -- "$pipe_path"
    rmdir -- "$pipe_dir" 2>/dev/null || true
    return 124
  else
    # Bash monitor mode gives this background job a process group without
    # moving it out of the collector's session.
    [[ $- == *m* ]] && monitor_was_enabled=true
    set -m
    "$@" <&"$input_fd" >"$pipe_path" &
    producer_pid=$!
    [ "$monitor_was_enabled" = true ] || set +m
  fi
  exec {input_fd}<&-

  head -c "$((max_bytes + 1))" <"$pipe_path" >"$output_file" &
  reader_pid=$!

  completed_pid=""
  wait -n -p completed_pid "$producer_pid" "$reader_pid"
  first_status=$?

  if [ "$completed_pid" = "$reader_pid" ]; then
    reader_status=$first_status
    size=$(wc -c <"$output_file")
    if [ "$reader_status" -ne 0 ] || [ "$size" -gt "$max_bytes" ]; then
      terminate_producer_group "$producer_pid"
    fi
    wait "$producer_pid"
    command_status=$?
    # A helper can fork, exit zero, and leave descendants behind. Sweep the
    # group after every completion, not only failures and timeouts.
    terminate_producer_group "$producer_pid"
  else
    command_status=$first_status
    terminate_producer_group "$producer_pid"
    wait "$reader_pid"
    reader_status=$?
    size=$(wc -c <"$output_file")
  fi

  rm -f -- "$pipe_path"
  rmdir -- "$pipe_dir" 2>/dev/null || true

  [ "$reader_status" -eq 0 ] || return 125
  [ "$size" -le "$max_bytes" ] || return 125
  return "$command_status"
}

# Hardware-facing helpers are skipped if timeout is unavailable. Successful
# output is copied only after the bounded producer and all of its descendants
# have been reaped.
run_bounded_capped() {
  local output_file status
  output_file=$(mktemp) || return 125
  run_capped_to_file true 3 "$MAX_CMD_OUTPUT_BYTES" "$output_file" "$@"
  status=$?
  if [ "$status" -ne 125 ]; then
    cat -- "$output_file"
  fi
  rm -f -- "$output_file"
  return "$status"
}

# jq and other trusted local producers accept already-bounded inputs, but each
# captured result is still byte- and time-capped before entering a shell
# variable. Without timeout they remain byte-capped and in a killable process
# group; the outer QML watchdog supplies the wall-clock backstop.
run_local_capped() {
  local output_file status
  output_file=$(mktemp) || return 125
  run_capped_to_file false 5 "$MAX_CMD_OUTPUT_BYTES" "$output_file" "$@"
  status=$?
  if [ "$status" -ne 125 ]; then
    cat -- "$output_file"
  fi
  rm -f -- "$output_file"
  return "$status"
}

# Read small kernel/device attributes without ever materializing an unbounded
# regular file supplied through one of the debug path overrides. Real procfs
# and sysfs attributes are already tiny, but the limit is part of the
# collector's contract and keeps synthetic or faulty inputs safe too.
read_string_file() {
  head -c "$MAX_STRING_BYTES" -- "$1" 2>/dev/null
}

read_number_file() {
  head -c "$MAX_NUMBER_BYTES" -- "$1" 2>/dev/null
}

limit_string() {
  printf '%s' "$1" | head -c "$MAX_STRING_BYTES"
}

trim() {
  sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

json_number_or_null() {
  local value
  value=$(printf '%s' "$1" | trim | head -c "$MAX_NUMBER_BYTES")
  if [[ $value =~ ^-?[0-9]+([.][0-9]+)?$ ]]; then
    printf '%s' "$value"
  else
    printf 'null'
  fi
}

# ---------------------------------------------------------------------------
# CPU: raw cumulative /proc/stat counters. Percent-from-delta is computed in
# Model.js from two samples (the QML timer already provides that window), so
# this script only ever emits the raw counters, never a percentage.
# ---------------------------------------------------------------------------
cpu_raw_json() {
  head -c 4096 -- "$PROC_STAT_PATH" 2>/dev/null | awk '
    NR == 1 {
      for (i = 2; i <= NF; i++) vals[i - 2] = $i
      user = vals[0] + 0; nice = vals[1] + 0; sys = vals[2] + 0; idle = vals[3] + 0
      iowait = vals[4] + 0; irq = vals[5] + 0; softirq = vals[6] + 0; steal = vals[7] + 0
      printf "{\"user\":%d,\"nice\":%d,\"system\":%d,\"idle\":%d,\"iowait\":%d,\"irq\":%d,\"softirq\":%d,\"steal\":%d}", \
        user, nice, sys, idle, iowait, irq, softirq, steal
      exit
    }
  ' 2>/dev/null
}

cpu_core_count() {
  local n
  n=$(run_local_capped nproc 2>/dev/null)
  [[ $n =~ ^[0-9]+$ ]] && echo "$n" || echo 0
}

# CPU model name, e.g. "AMD Ryzen 9 5900HX with Radeon Graphics". Doesn't
# change at runtime, so it's collected once via --static-only rather than on
# every poll. Empty if /proc/cpuinfo has no "model name" line.
cpu_name() {
  head -c "$MAX_CMD_OUTPUT_BYTES" -- "$PROC_CPUINFO_PATH" 2>/dev/null |
    awk -F': *' '/^model name[[:space:]]*:/ { print $2; exit }' |
    trim | head -c "$MAX_STRING_BYTES"
}

# CPU temperature: discover by hwmon chip *name*, never a fixed hwmon index
# (numbering is not stable across boots or machines).
cpu_temp_c() {
  local chip name lf label input val="" f zone zone_type
  while IFS= read -r chip; do
    [ -d "$chip" ] || continue
    name=$(read_string_file "$chip/name") || continue

    case "$name" in
      coretemp)
        while IFS= read -r lf; do
          [ -e "$lf" ] || continue
          label=$(read_string_file "$lf")
          if [ "$label" = "Package id 0" ]; then
            input="${lf%_label}_input"
            [ -r "$input" ] && val=$(read_number_file "$input")
            break
          fi
        done < <(find -L "$chip" -maxdepth 1 -type f -name 'temp*_label' 2>/dev/null |
          head -n "$MAX_DEVICE_SCAN_ITEMS" | sort -V)
        ;;
      k10temp | zenpower)
        while IFS= read -r lf; do
          [ -e "$lf" ] || continue
          label=$(read_string_file "$lf")
          if [ "$label" = "Tctl" ] || [ "$label" = "Tdie" ]; then
            input="${lf%_label}_input"
            [ -r "$input" ] && val=$(read_number_file "$input")
            break
          fi
        done < <(find -L "$chip" -maxdepth 1 -type f -name 'temp*_label' 2>/dev/null |
          head -n "$MAX_DEVICE_SCAN_ITEMS" | sort -V)
        ;;
      *) ;;
    esac

    # For other chip drivers, only accept labels that identify a CPU/package
    # sensor. This adds laptop and SoC support without mistaking NVMe or board
    # temperatures for the CPU.
    if [ -z "$val" ]; then
      while IFS= read -r lf; do
        [ -r "$lf" ] || continue
        label=$(read_string_file "$lf")
        if [[ ${label,,} =~ (package|tctl|tdie|cpu|soc) ]]; then
          input="${lf%_label}_input"
          [ -r "$input" ] && val=$(read_number_file "$input")
          [ -n "$val" ] && break
        fi
      done < <(find -L "$chip" -maxdepth 1 -type f -name 'temp*_label' 2>/dev/null |
        head -n "$MAX_DEVICE_SCAN_ITEMS" | sort -V)
    fi

    # Known CPU drivers without labels still get their first temperature.
    if [ -z "$val" ] && [[ $name =~ ^(coretemp|k10temp|zenpower|cpu_thermal|x86_pkg_temp)$ ]]; then
      while IFS= read -r f; do
        [ -r "$f" ] || continue
        val=$(read_number_file "$f")
        break
      done < <(find -L "$chip" -maxdepth 1 -type f -name 'temp*_input' 2>/dev/null |
        head -n "$MAX_DEVICE_SCAN_ITEMS" | sort -V)
    fi

    [ -n "$val" ] && break
  done < <(find -L "$HWMON_ROOT" -mindepth 1 -maxdepth 1 -type d -name 'hwmon*' 2>/dev/null |
    head -n "$MAX_DEVICE_SCAN_ITEMS" | sort -V)

  # Some systems expose CPU temperature through the thermal class but not a
  # useful hwmon label. Restrict the fallback to CPU/package/SoC zone types.
  if [ -z "$val" ]; then
    while IFS= read -r zone; do
      [ -d "$zone" ] || continue
      zone_type=$(read_string_file "$zone/type")
      [[ ${zone_type,,} =~ (cpu|package|x86_pkg|soc) ]] || continue
      [ -r "$zone/temp" ] || continue
      val=$(read_number_file "$zone/temp")
      [[ $val =~ ^-?[0-9]+$ ]] && break
      val=""
    done < <(find -L "$THERMAL_ROOT" -mindepth 1 -maxdepth 1 -type d -name 'thermal_zone*' 2>/dev/null |
      head -n "$MAX_DEVICE_SCAN_ITEMS" | sort -V)
  fi

  if [[ $val =~ ^-?[0-9]+$ ]]; then
    awk -v v="$val" 'BEGIN { printf "%.1f", v / 1000 }'
  fi
}

# ---------------------------------------------------------------------------
# Memory: raw /proc/meminfo counters (kB). GB conversion and percent math
# happen in Model.js.
# ---------------------------------------------------------------------------
mem_json() {
  head -c "$MAX_CMD_OUTPUT_BYTES" -- "$MEMINFO_PATH" 2>/dev/null | awk '
    /^MemTotal:/     { total = $2 }
    /^MemAvailable:/ { avail = $2; haveAvail = 1 }
    /^MemFree:/      { free = $2 }
    /^Buffers:/      { buffers = $2 }
    /^Cached:/       { cached = $2 }
    END {
      if (!haveAvail) avail = free + buffers + cached
      printf "{\"totalKB\":%d,\"availableKB\":%d}", total + 0, avail + 0
    }
  ' 2>/dev/null
}

# ---------------------------------------------------------------------------
# OS install date: read from the first line of Omarchy's own install log
# ("=== Omarchy Installation Started: YYYY-MM-DD HH:MM:SS ==="), which is
# written once at install time and never rewritten, unlike the file's mtime
# (which migrations/backups can change). Age-from-timestamp math happens in
# Model.js, same as every other derived value here.
#
# Falls back to the root filesystem's birth time when the log is missing or
# unreadable (e.g. rotated away, or an install method that never wrote it).
# This is the same source Omarchy's own fastfetch "OS Age" module uses, so it
# stays consistent with what a user already sees elsewhere on the system.
# ---------------------------------------------------------------------------
os_json() {
  local ts epoch birth

  if [ -r "$OMARCHY_INSTALL_LOG" ]; then
    ts=$(head -c 4096 -- "$OMARCHY_INSTALL_LOG" 2>/dev/null |
      sed -n '1s/.*Installation Started: \([0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\} [0-9]\{2\}:[0-9]\{2\}:[0-9]\{2\}\).*/\1/p')
    if [ -n "$ts" ]; then
      epoch=$(run_local_capped date -d "$ts" +%s 2>/dev/null)
      if [[ $epoch =~ ^[0-9]+$ ]]; then
        run_local_capped jq -n --argjson installedAtMs "$((epoch * 1000))" '{installedAtMs: $installedAtMs}'
        return 0
      fi
    fi
  fi

  birth=$(run_local_capped stat -c %W "$ROOT_FS_PATH" 2>/dev/null)
  [[ $birth =~ ^[0-9]+$ ]] && [ "$birth" -gt 0 ] || return 1
  run_local_capped jq -n --argjson installedAtMs "$((birth * 1000))" '{installedAtMs: $installedAtMs}'
}

static_main() {
  local os_obj cpu_name_val cpu_name_json
  os_obj=$(os_json)
  [ -n "$os_obj" ] || os_obj="null"
  cpu_name_val=$(cpu_name)
  cpu_name_json=$([ -n "$cpu_name_val" ] && run_local_capped jq -n --arg n "$cpu_name_val" '$n' || echo "null")
  emit_bounded_json static 0 jq -n \
    --argjson os "$os_obj" --argjson cpuName "$cpu_name_json" \
    '{os: $os, cpuName: $cpuName}'
}

# ---------------------------------------------------------------------------
# Fans: enumerate fan*_input across EVERY hwmon chip (never filtered to one
# driver name, since controllers vary widely: nct6775, it87, applesmc,
# thinkpad_acpi, dell_smm, asus_wmi_sensors, ...). A board with no exposed
# fan sensors (e.g. this repo's own dev machine) legitimately yields [],
# never an error.
# ---------------------------------------------------------------------------

# Optional nicety: if lm_sensors' `sensors -j` is available, borrow a nicer
# label for a fan whose sysfs fanN_label is missing, by matching the reading
# value against sensors -j's (often community-configured, human-friendly)
# key names for the same chip. Sysfs stays authoritative for the value; this
# only ever supplies a label string, and any failure here is silently
# ignored in favor of the synthesized "<chip> fan N" fallback.
sensors_nice_label() {
  local sensors_json="$1" chipname="$2" fan_number="$3" rpm="$4"
  [ -n "$sensors_json" ] && [ -n "$chipname" ] || return 1
  printf '%s\n' "$sensors_json" | run_local_capped jq -r --arg chip "$chipname" --arg feature "fan"$fan_number --argjson rpm "$rpm" '
    to_entries[]
    | select(.key | startswith($chip + "-"))
    | .value
    | to_entries[]
    | select(.value | type == "object")
    | select(.key == $feature or ([.value[] | select(type == "number")] | any(. == $rpm)))
    | .key
  ' 2>/dev/null | head -n1 | head -c "$MAX_STRING_BYTES"
}

fans_json() {
  local sensors_json="" sensors_loaded=false
  local chip chipname f n rpm label label_file nice_label scanned=0
  local items=()

  # The limit is applied by head before sorting or loop processing, so find,
  # sort, and the shell never materialize a pathological device tree. Count
  # every visited candidate, not only valid fan readings.
  while IFS= read -r f; do
    [ -e "$f" ] || continue
    scanned=$((scanned + 1))
    [ "$scanned" -le "$MAX_DEVICE_SCAN_ITEMS" ] || break
    [ "${#items[@]}" -lt "$MAX_FAN_ITEMS" ] || break

    chip=$(dirname "$f")
    chipname=$(read_string_file "$chip/name")
    n=$(basename "$f" | sed -n 's/^fan\([0-9][0-9]*\)_input$/\1/p')
    [ -n "$n" ] || continue
    rpm=$(read_number_file "$f")
    [[ $rpm =~ ^[0-9]+$ ]] || continue

    label=""
    label_file="$chip/fan${n}_label"
    if [ -r "$label_file" ] && [ -s "$label_file" ]; then
      label=$(read_string_file "$label_file")
    fi

    if [ -z "$label" ]; then
      if [ "$sensors_loaded" = false ]; then
        sensors_loaded=true
        if command -v sensors >/dev/null 2>&1; then
          sensors_json=$(run_bounded_capped sensors -j 2>/dev/null)
          printf '%s\n' "$sensors_json" | run_local_capped jq -e . >/dev/null 2>&1 || sensors_json=""
        fi
      fi
      nice_label=$(sensors_nice_label "$sensors_json" "$chipname" "$n" "$rpm")
      [ -n "$nice_label" ] && label="$nice_label"
    fi

    [ -n "$label" ] || label="${chipname:-hwmon} fan ${n}"
    label=$(limit_string "$label")

    items+=("$(run_local_capped jq -cn --arg label "$label" --argjson rpm "$rpm" '{label: $label, rpm: $rpm}')")
  done < <(find -L "$HWMON_ROOT" -mindepth 2 -maxdepth 2 -type f -name 'fan*_input' 2>/dev/null |
    head -n "$MAX_DEVICE_SCAN_ITEMS" | sort -V)

  if [ "${#items[@]}" -eq 0 ]; then
    echo "[]"
    return
  fi
  printf '%s\n' "${items[@]}" | run_local_capped jq -s '.'
}

# ---------------------------------------------------------------------------
# GPU: enumerate every /sys/class/drm/cardN device by PCI vendor. Each metric
# is independently nullable, so a missing fan or temperature never discards
# otherwise valid utilization. Discrete GPUs are ordered before Intel GPUs.
# ---------------------------------------------------------------------------

gpu_device_name() {
  # Best-effort PCI device name lookup via lspci; caller supplies a fallback.
  local card="$1" addr name
  command -v lspci >/dev/null 2>&1 || return 1
  addr=$(basename "$(readlink -f "$card/device")" 2>/dev/null)
  [ -n "$addr" ] || return 1
  name=$(run_bounded_capped lspci -s "$addr" 2>/dev/null |
    sed -E 's/^[0-9a-fA-F:.]+ [^:]+: //' | head -n1 | head -c "$MAX_STRING_BYTES")
  [ -n "$name" ] || return 1
  printf '%s' "$name"
}

nvidia_gpus_json() {
  if ! command -v nvidia-smi >/dev/null 2>&1; then
    echo "gpu: nvidia driver present but nvidia-smi not found" >&2
    echo "[]"
    return
  fi

  local output status line index pci name util temp fan memused memtotal extra
  local util_json temp_json fan_json memused_json memtotal_json
  local items=() seen_rows=0

  output=$(run_bounded_capped nvidia-smi \
    --query-gpu=index,pci.bus_id,name,utilization.gpu,temperature.gpu,fan.speed,memory.used,memory.total \
    --format=csv,noheader,nounits 2>/dev/null)
  status=$?
  if [ "$status" -ne 0 ]; then
    echo "gpu: nvidia-smi failed with exit status $status" >&2
    echo "[]"
    return
  fi

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    if [ "$seen_rows" -ge "$MAX_NVIDIA_ITEMS" ]; then
      echo "gpu: additional nvidia-smi rows omitted (limit reached)" >&2
      break
    fi
    seen_rows=$((seen_rows + 1))
    IFS=',' read -r index pci name util temp fan memused memtotal extra <<<"$line"
    index=$(printf '%s' "$index" | trim)
    pci=$(printf '%s' "$pci" | trim)
    name=$(printf '%s' "$name" | trim)
    if ! [[ $index =~ ^[0-9]+$ ]] || [ "${#index}" -gt 16 ] || [ -z "$pci" ] || [ -z "$name" ]; then
      echo "gpu: ignored malformed nvidia-smi row" >&2
      continue
    fi
    pci=$(limit_string "$pci")
    name=$(limit_string "$name")

    util_json=$(json_number_or_null "$util")
    temp_json=$(json_number_or_null "$temp")
    fan_json=$(json_number_or_null "$fan")
    memused_json=$(json_number_or_null "$memused")
    memtotal_json=$(json_number_or_null "$memtotal")

    [ "$util_json" != null ] || echo "gpu: NVIDIA $index utilization unavailable" >&2
    [ "$temp_json" != null ] || echo "gpu: NVIDIA $index temperature unavailable" >&2
    [ "$fan_json" != null ] || echo "gpu: NVIDIA $index fan percentage unavailable" >&2

    items+=("$(run_local_capped jq -cn \
      --arg id "nvidia-$index" --arg pci "$pci" --arg name "$name" \
      --argjson util "$util_json" --argjson temp "$temp_json" --argjson fan "$fan_json" \
      --argjson memUsed "$memused_json" --argjson memTotal "$memtotal_json" \
      '{id: $id, card: "", pciAddress: $pci, vendor: "nvidia", name: $name,
        utilPercent: $util, tempC: $temp, memUsedMB: $memUsed,
        memTotalMB: $memTotal, fanPercent: $fan}')")
  done <<<"$output"

  if [ "${#items[@]}" -eq 0 ]; then
    echo "gpu: nvidia-smi returned no usable GPU rows" >&2
    echo "[]"
  else
    printf '%s\n' "${items[@]}" | run_local_capped jq -s '.'
  fi
}

amd_gpu_json() {
  local card="$1" util="" temp="" name hwmon hn raw card_name pci
  local memused="" memtotal="" util_json temp_json memused_json memtotal_json

  card_name=$(basename "$card")
  pci=$(basename "$(readlink -f "$card/device")" 2>/dev/null)

  if [ -r "$card/device/gpu_busy_percent" ]; then
    util=$(read_number_file "$card/device/gpu_busy_percent")
    [[ $util =~ ^[0-9]+$ ]] || util=""
  fi
  [ -n "$util" ] || echo "gpu: amdgpu gpu_busy_percent not available" >&2

  while IFS= read -r hwmon; do
    [ -d "$hwmon" ] || continue
    hn=$(read_string_file "$hwmon/name")
    if [ "$hn" = "amdgpu" ] && [ -r "$hwmon/temp1_input" ]; then
      raw=$(read_number_file "$hwmon/temp1_input")
      [[ $raw =~ ^-?[0-9]+$ ]] && temp=$(awk -v v="$raw" 'BEGIN { printf "%.1f", v / 1000 }')
      break
    fi
  done < <(find -L "$card/device/hwmon" -mindepth 1 -maxdepth 1 -type d -name 'hwmon*' 2>/dev/null |
    head -n "$MAX_DEVICE_SCAN_ITEMS" | sort -V)
  [ -n "$temp" ] || echo "gpu: amdgpu hwmon temperature not available" >&2

  if [ -r "$card/device/mem_info_vram_used" ]; then
    raw=$(read_number_file "$card/device/mem_info_vram_used")
    [[ $raw =~ ^[0-9]+$ ]] && memused=$(awk -v v="$raw" 'BEGIN { printf "%.1f", v / 1048576 }')
  fi
  if [ -r "$card/device/mem_info_vram_total" ]; then
    raw=$(read_number_file "$card/device/mem_info_vram_total")
    [[ $raw =~ ^[0-9]+$ ]] && memtotal=$(awk -v v="$raw" 'BEGIN { printf "%.1f", v / 1048576 }')
  fi

  name=$(gpu_device_name "$card") || name="AMD GPU"
  util_json=$(json_number_or_null "$util")
  temp_json=$(json_number_or_null "$temp")
  memused_json=$(json_number_or_null "$memused")
  memtotal_json=$(json_number_or_null "$memtotal")

  run_local_capped jq -n --arg id "$card_name" --arg card "$card_name" --arg pci "$pci" --arg name "$name" \
    --argjson util "$util_json" --argjson temp "$temp_json" \
    --argjson memUsed "$memused_json" --argjson memTotal "$memtotal_json" \
    '{id: $id, card: $card, pciAddress: $pci, vendor: "amd", name: $name,
      utilPercent: $util, tempC: $temp, memUsedMB: $memUsed,
      memTotalMB: $memTotal, fanPercent: null}'
}

intel_gpu_json() {
  local card="$1" name driver="" card_name pci hwmon raw temp="" temp_json

  card_name=$(basename "$card")
  pci=$(basename "$(readlink -f "$card/device")" 2>/dev/null)

  if [ -r "$card/device/uevent" ]; then
    driver=$(head -c 4096 -- "$card/device/uevent" 2>/dev/null |
      sed -n 's/^DRIVER=//p' | head -n1 | head -c "$MAX_STRING_BYTES")
  fi
  name=$(gpu_device_name "$card") || name="Intel Graphics"

  while IFS= read -r hwmon; do
    [ -d "$hwmon" ] || continue
    if [ -r "$hwmon/temp1_input" ]; then
      raw=$(read_number_file "$hwmon/temp1_input")
      [[ $raw =~ ^-?[0-9]+$ ]] && temp=$(awk -v v="$raw" 'BEGIN { printf "%.1f", v / 1000 }')
      [ -n "$temp" ] && break
    fi
  done < <(find -L "$card/device/hwmon" -mindepth 1 -maxdepth 1 -type d -name 'hwmon*' 2>/dev/null |
    head -n "$MAX_DEVICE_SCAN_ITEMS" | sort -V)
  temp_json=$(json_number_or_null "$temp")

  echo "gpu: Intel utilization unavailable through standard sysfs (driver: ${driver:-unknown})" >&2
  [ "$temp_json" != null ] || echo "gpu: Intel temperature unavailable" >&2

  run_local_capped jq -n --arg id "$card_name" --arg card "$card_name" --arg pci "$pci" --arg name "$name" \
    --argjson temp "$temp_json" \
    '{id: $id, card: $card, pciAddress: $pci, vendor: "intel", name: $name,
      utilPercent: null, tempC: $temp, memUsedMB: null,
      memTotalMB: null, fanPercent: null}'
}

detected_nvidia_gpu_json() {
  local card="$1" card_name pci name
  card_name=$(basename "$card")
  pci=$(basename "$(readlink -f "$card/device")" 2>/dev/null)
  name=$(gpu_device_name "$card") || name="NVIDIA GPU"
  run_local_capped jq -n --arg id "$card_name" --arg card "$card_name" --arg pci "$pci" --arg name "$name" \
    '{id: $id, card: $card, pciAddress: $pci, vendor: "nvidia", name: $name,
      utilPercent: null, tempC: null, memUsedMB: null,
      memTotalMB: null, fanPercent: null}'
}

gpus_json() {
  local card base vendor nvidia_json row pci suffix matched nvidia_count matched_count=0
  local discrete_items=() intel_items=() nvidia_cards=()
  local seen_cards=0

  while IFS= read -r card; do
    [ -d "$card" ] || continue
    base=$(basename "$card")
    [[ $base =~ ^card[0-9]+$ ]] || continue
    [ -r "$card/device/vendor" ] || continue
    # Bounds enumeration against a pathological/synthetic DRM tree; no real
    # machine has anywhere near this many GPU devices.
    [ "$seen_cards" -lt "$MAX_GPU_CARDS" ] || break
    seen_cards=$((seen_cards + 1))
    vendor=$(read_number_file "$card/device/vendor")
    case "$vendor" in
      0x10de)
        nvidia_cards+=("$card")
        ;;
      0x1002)
        discrete_items+=("$(amd_gpu_json "$card")")
        ;;
      0x8086)
        intel_items+=("$(intel_gpu_json "$card")")
        ;;
    esac
  done < <(find -L "$DRM_ROOT" -mindepth 1 -maxdepth 1 -type d -name 'card[0-9]*' 2>/dev/null |
    head -n "$MAX_GPU_CARDS" | sort -V)

  if [ "${#nvidia_cards[@]}" -gt 0 ]; then
    nvidia_json=$(nvidia_gpus_json)
    nvidia_count=$(printf '%s' "$nvidia_json" | run_local_capped jq 'length' 2>/dev/null)
    [[ $nvidia_count =~ ^[0-9]+$ ]] || nvidia_count=0

    # Match nvidia-smi rows back to DRM cards by the bus/device/function
    # suffix. nvidia-smi commonly uses an eight-digit PCI domain while sysfs
    # uses four digits, so direct string equality is not portable.
    for card in "${nvidia_cards[@]}"; do
      base=$(basename "$card")
      pci=$(basename "$(readlink -f "$card/device")" 2>/dev/null)
      suffix=$(printf '%s' "$pci" | sed -E 's/^[0-9a-fA-F]+(:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}[.][0-9])$/\1/' | tr '[:upper:]' '[:lower:]')
      matched=$(printf '%s' "$nvidia_json" | run_local_capped jq -c --arg suffix "$suffix" \
        'map(select((.pciAddress | ascii_downcase | endswith($suffix)))) | first // empty' 2>/dev/null)
      if [ -n "$matched" ]; then
        row=$(printf '%s' "$matched" | run_local_capped jq -c --arg id "$base" --arg card "$base" \
          '.id = $id | .card = $card')
        discrete_items+=("$row")
        matched_count=$((matched_count + 1))
      else
        discrete_items+=("$(detected_nvidia_gpu_json "$card")")
      fi
    done

    if [ "$matched_count" -ne "$nvidia_count" ]; then
      echo "gpu: NVIDIA DRM devices and nvidia-smi rows did not fully match" >&2
    fi
  fi

  if [ "${#discrete_items[@]}" -eq 0 ] && [ "${#intel_items[@]}" -eq 0 ]; then
    echo "gpu: no supported GPU found under $DRM_ROOT" >&2
    echo "[]"
    return
  fi

  printf '%s\n' "${discrete_items[@]}" "${intel_items[@]}" | run_local_capped jq -s '.'
}

# ---------------------------------------------------------------------------
# Assemble
# ---------------------------------------------------------------------------

# Emit a known-valid minimal result without relying on jq. This path must keep
# the collector contract even when jq itself is the command that failed,
# timed out, or produced excessive output.
emit_fallback_json() {
  local kind="$1" collected_at_ms="${2:-0}" reason="$3"
  if [ "$kind" = "static" ]; then
    printf '{"os":null,"cpuName":null}\n'
  else
    printf '{"cpu":{"raw":null,"coreCount":0,"tempC":null},"gpu":null,"gpus":[],"memory":{"totalKB":0,"availableKB":0},"fans":[],"meta":{"collectedAtMs":%s,"warnings":["collector: result %s and was discarded"]}}\n' \
      "$collected_at_ms" "$reason"
  fi
}

# Run the JSON producer directly into a MAX+1-byte file. Unlike command
# substitution, this never materializes an oversized result in Bash, and the
# extra byte makes overflow detectable even when the producer exits before it
# receives SIGPIPE. Only validated object JSON is copied to stdout.
emit_bounded_json() {
  local kind="$1" collected_at_ms="$2" output_file size producer_status reason
  shift 2

  output_file=$(mktemp) || {
    emit_fallback_json "$kind" "$collected_at_ms" "could not be buffered"
    return 0
  }

  run_capped_to_file false 5 "$MAX_JSON_OUTPUT_BYTES" "$output_file" "$@"
  producer_status=$?
  size=$(wc -c <"$output_file")

  reason=""
  if [ "$size" -gt "$MAX_JSON_OUTPUT_BYTES" ]; then
    reason="exceeded the size limit"
  elif [ "$producer_status" -ne 0 ]; then
    reason="generation failed"
  elif ! run_local_capped jq -e 'type == "object"' <"$output_file" >/dev/null 2>&1; then
    reason="was invalid"
  fi

  if [ -n "$reason" ]; then
    emit_fallback_json "$kind" "$collected_at_ms" "$reason"
  else
    cat "$output_file"
  fi
  rm -f "$output_file"
}

main() {
  local cpu_raw mem_obj temp_c core_count temp_json warnings_json collected_at_ms
  local gpu_obj gpus_arr gpu_warn_file line fans_arr os_obj cpu_name_val cpu_name_json

  cpu_raw=$(cpu_raw_json)
  if [ -z "$cpu_raw" ]; then
    cpu_raw='{"user":0,"nice":0,"system":0,"idle":0,"iowait":0,"irq":0,"softirq":0,"steal":0}'
    warnings+=("cpu: failed to read /proc/stat")
  fi

  mem_obj=$(mem_json)
  if [ -z "$mem_obj" ]; then
    mem_obj='{"totalKB":0,"availableKB":0}'
    warnings+=("memory: failed to read /proc/meminfo")
  fi

  core_count=$(cpu_core_count)

  os_obj="null"
  cpu_name_json="null"
  if [ "$COLLECTOR_MODE" = "full" ]; then
    os_obj=$(os_json)
    [ -n "$os_obj" ] || os_obj="null"
    cpu_name_val=$(cpu_name)
    cpu_name_json=$([ -n "$cpu_name_val" ] && run_local_capped jq -n --arg n "$cpu_name_val" '$n' || echo "null")
  fi

  fans_arr=$(fans_json)
  [ -n "$fans_arr" ] || fans_arr="[]"

  # gpus_json runs via command substitution, i.e. in a subshell, so warnings it
  # appends to the array there would never reach this scope, so it writes
  # warnings to stderr instead and they're recovered here.
  if gpu_warn_file=$(mktemp); then
    gpus_arr=$(gpus_json 2>"$gpu_warn_file")
    printf '%s\n' "$gpus_arr" | run_local_capped jq -e 'type == "array"' >/dev/null 2>&1 || gpus_arr="[]"
    gpu_obj=$(printf '%s' "$gpus_arr" | run_local_capped jq 'if length > 0 then .[0] else null end')
    if [ -s "$gpu_warn_file" ]; then
      while IFS= read -r line; do
        [ -n "$line" ] || continue
        if [ "${#warnings[@]}" -ge "$((MAX_WARNINGS - 1))" ]; then
          warnings+=("collector: additional warnings omitted (limit reached)")
          break
        fi
        warnings+=("$(limit_string "$line")")
      done <"$gpu_warn_file"
    fi
    rm -f "$gpu_warn_file"
  else
    gpus_arr="[]"
    gpu_obj="null"
    warnings+=("gpu: could not create bounded diagnostic buffer")
  fi

  temp_c=$(cpu_temp_c)
  if [ -n "$temp_c" ]; then
    temp_json="$temp_c"
  else
    temp_json="null"
    warnings+=("cpu: no CPU-labelled hwmon or thermal-zone temperature found")
  fi

  # Cap both warning count and each line's length: some warning text embeds
  # values read from sysfs/uevent (driver names, chip names) that aren't
  # under this script's control, so string length is bounded defensively
  # even though real hardware never comes close.
  warnings_json="[]"
  if [ "${#warnings[@]}" -gt 0 ]; then
    if [ "${#warnings[@]}" -gt "$MAX_WARNINGS" ]; then
      warnings=("${warnings[@]:0:$((MAX_WARNINGS - 1))}" "collector: additional warnings omitted (limit reached)")
    fi
    warnings_json=$(printf '%s\n' "${warnings[@]}" | run_local_capped jq -R .)
    warnings_json=$(printf '%s\n' "$warnings_json" | run_local_capped jq -s \
      'map(if length > 200 then .[0:200] + "…[truncated]" else . end)')
  fi

  collected_at_ms=$(run_local_capped date +%s%3N 2>/dev/null)
  [[ $collected_at_ms =~ ^[0-9]+$ ]] || collected_at_ms=0

  emit_bounded_json dynamic "$collected_at_ms" jq -n \
    --argjson cpuRaw "$cpu_raw" \
    --argjson coreCount "$core_count" \
    --argjson cpuTempC "$temp_json" \
    --argjson gpu "$gpu_obj" \
    --argjson memory "$mem_obj" \
    --argjson fans "$fans_arr" \
    --argjson warnings "$warnings_json" \
    --argjson collectedAtMs "$collected_at_ms" \
    --argjson gpus "$gpus_arr" \
    --argjson os "$os_obj" \
    --argjson cpuName "$cpu_name_json" \
    --argjson includeOs "$([ "$COLLECTOR_MODE" = "full" ] && echo true || echo false)" \
    '{
      cpu: { raw: $cpuRaw, coreCount: $coreCount, tempC: $cpuTempC },
      gpu: $gpu,
      gpus: $gpus,
      memory: $memory,
      fans: $fans,
      meta: { collectedAtMs: $collectedAtMs, warnings: $warnings }
    } | if $includeOs then . + {os: $os, cpuName: $cpuName} else . end'
}

if [ "$COLLECTOR_MODE" = "static" ]; then
  static_main
else
  main
fi
exit 0
