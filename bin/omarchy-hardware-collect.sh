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
OMARCHY_INSTALL_LOG="${OMARCHY_INSTALL_LOG:-/var/log/omarchy-install.log}"
COLLECTOR_MODE="full"

case "${1:-}" in
  "") ;;
  --dynamic-only) COLLECTOR_MODE="dynamic" ;;
  --static-only) COLLECTOR_MODE="static" ;;
  *)
    echo "usage: $0 [--dynamic-only|--static-only]" >&2
    exit 2
    ;;
esac

# Every external tool call (nvidia-smi, sensors, lspci) goes through this so a
# wedged driver/tool can never hang the whole collector. /proc and /sys reads
# are plain files and don't need this, only actual subprocesses. `timeout`
# reliably reaps the process it launches; wrapping at the source here avoids
# relying on a caller (HardwareService.qml's watchdog) to clean up whatever a
# hung process leaves behind.
run_bounded() {
  if command -v timeout >/dev/null 2>&1; then
    timeout -k 1 3 "$@"
  else
    return 124
  fi
}

trim() {
  sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

json_number_or_null() {
  local value
  value=$(printf '%s' "$1" | trim)
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
  awk '
    NR == 1 {
      for (i = 2; i <= NF; i++) vals[i - 2] = $i
      user = vals[0] + 0; nice = vals[1] + 0; sys = vals[2] + 0; idle = vals[3] + 0
      iowait = vals[4] + 0; irq = vals[5] + 0; softirq = vals[6] + 0; steal = vals[7] + 0
      printf "{\"user\":%d,\"nice\":%d,\"system\":%d,\"idle\":%d,\"iowait\":%d,\"irq\":%d,\"softirq\":%d,\"steal\":%d}", \
        user, nice, sys, idle, iowait, irq, softirq, steal
      exit
    }
  ' "$PROC_STAT_PATH" 2>/dev/null
}

cpu_core_count() {
  local n
  n=$(nproc 2>/dev/null)
  [[ $n =~ ^[0-9]+$ ]] && echo "$n" || echo 0
}

# CPU temperature: discover by hwmon chip *name*, never a fixed hwmon index
# (numbering is not stable across boots or machines).
cpu_temp_c() {
  local chip name lf label input val="" f zone zone_type
  for chip in "$HWMON_ROOT"/hwmon*; do
    [ -d "$chip" ] || continue
    name=$(cat "$chip/name" 2>/dev/null) || continue

    case "$name" in
      coretemp)
        for lf in "$chip"/temp*_label; do
          [ -e "$lf" ] || continue
          label=$(cat "$lf" 2>/dev/null)
          if [ "$label" = "Package id 0" ]; then
            input="${lf%_label}_input"
            [ -r "$input" ] && val=$(cat "$input" 2>/dev/null)
            break
          fi
        done
        ;;
      k10temp | zenpower)
        for lf in "$chip"/temp*_label; do
          [ -e "$lf" ] || continue
          label=$(cat "$lf" 2>/dev/null)
          if [ "$label" = "Tctl" ] || [ "$label" = "Tdie" ]; then
            input="${lf%_label}_input"
            [ -r "$input" ] && val=$(cat "$input" 2>/dev/null)
            break
          fi
        done
        ;;
      *) ;;
    esac

    # For other chip drivers, only accept labels that identify a CPU/package
    # sensor. This adds laptop and SoC support without mistaking NVMe or board
    # temperatures for the CPU.
    if [ -z "$val" ]; then
      for lf in "$chip"/temp*_label; do
        [ -r "$lf" ] || continue
        label=$(cat "$lf" 2>/dev/null)
        if [[ ${label,,} =~ (package|tctl|tdie|cpu|soc) ]]; then
          input="${lf%_label}_input"
          [ -r "$input" ] && val=$(cat "$input" 2>/dev/null)
          [ -n "$val" ] && break
        fi
      done
    fi

    # Known CPU drivers without labels still get their first temperature.
    if [ -z "$val" ] && [[ $name =~ ^(coretemp|k10temp|zenpower|cpu_thermal|x86_pkg_temp)$ ]]; then
      for f in "$chip"/temp*_input; do
        [ -r "$f" ] || continue
        val=$(cat "$f" 2>/dev/null)
        break
      done
    fi

    [ -n "$val" ] && break
  done

  # Some systems expose CPU temperature through the thermal class but not a
  # useful hwmon label. Restrict the fallback to CPU/package/SoC zone types.
  if [ -z "$val" ]; then
    for zone in "$THERMAL_ROOT"/thermal_zone*; do
      [ -d "$zone" ] || continue
      zone_type=$(cat "$zone/type" 2>/dev/null)
      [[ ${zone_type,,} =~ (cpu|package|x86_pkg|soc) ]] || continue
      [ -r "$zone/temp" ] || continue
      val=$(cat "$zone/temp" 2>/dev/null)
      [[ $val =~ ^-?[0-9]+$ ]] && break
      val=""
    done
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
  awk '
    /^MemTotal:/     { total = $2 }
    /^MemAvailable:/ { avail = $2; haveAvail = 1 }
    /^MemFree:/      { free = $2 }
    /^Buffers:/      { buffers = $2 }
    /^Cached:/       { cached = $2 }
    END {
      if (!haveAvail) avail = free + buffers + cached
      printf "{\"totalKB\":%d,\"availableKB\":%d}", total + 0, avail + 0
    }
  ' "$MEMINFO_PATH" 2>/dev/null
}

# ---------------------------------------------------------------------------
# OS install date: read from the first line of Omarchy's own install log
# ("=== Omarchy Installation Started: YYYY-MM-DD HH:MM:SS ==="), which is
# written once at install time and never rewritten, unlike the file's mtime
# (which migrations/backups can change). Age-from-timestamp math happens in
# Model.js, same as every other derived value here.
# ---------------------------------------------------------------------------
os_json() {
  local ts epoch
  [ -r "$OMARCHY_INSTALL_LOG" ] || return 1

  ts=$(sed -n '1s/.*Installation Started: \([0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\} [0-9]\{2\}:[0-9]\{2\}:[0-9]\{2\}\).*/\1/p' \
    "$OMARCHY_INSTALL_LOG" 2>/dev/null)
  [ -n "$ts" ] || return 1

  epoch=$(date -d "$ts" +%s 2>/dev/null)
  [[ $epoch =~ ^[0-9]+$ ]] || return 1

  jq -n --argjson installedAtMs "$((epoch * 1000))" '{installedAtMs: $installedAtMs}'
}

static_main() {
  local os_obj
  os_obj=$(os_json)
  [ -n "$os_obj" ] || os_obj="null"
  jq -n --argjson os "$os_obj" '{os: $os}'
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
  echo "$sensors_json" | jq -r --arg chip "$chipname" --arg feature "fan"$fan_number --argjson rpm "$rpm" '
    to_entries[]
    | select(.key | startswith($chip + "-"))
    | .value
    | to_entries[]
    | select(.value | type == "object")
    | select(.key == $feature or ([.value[] | select(type == "number")] | any(. == $rpm)))
    | .key
  ' 2>/dev/null | head -n1
}

fans_json() {
  local sensors_json="" sensors_loaded=false
  local chip chipname f n rpm label label_file nice_label
  local items=()

  for chip in "$HWMON_ROOT"/hwmon*; do
    [ -d "$chip" ] || continue
    chipname=$(cat "$chip/name" 2>/dev/null)

    for f in "$chip"/fan*_input; do
      [ -e "$f" ] || continue
      n=$(basename "$f" | sed -n 's/^fan\([0-9][0-9]*\)_input$/\1/p')
      [ -n "$n" ] || continue
      rpm=$(cat "$f" 2>/dev/null)
      [[ $rpm =~ ^[0-9]+$ ]] || continue

      label=""
      label_file="$chip/fan${n}_label"
      if [ -r "$label_file" ] && [ -s "$label_file" ]; then
        label=$(cat "$label_file" 2>/dev/null)
      fi

      if [ -z "$label" ]; then
        if [ "$sensors_loaded" = false ]; then
          sensors_loaded=true
          if command -v sensors >/dev/null 2>&1; then
            sensors_json=$(run_bounded sensors -j 2>/dev/null)
            echo "$sensors_json" | jq -e . >/dev/null 2>&1 || sensors_json=""
          fi
        fi
        nice_label=$(sensors_nice_label "$sensors_json" "$chipname" "$n" "$rpm")
        [ -n "$nice_label" ] && label="$nice_label"
      fi

      [ -n "$label" ] || label="${chipname:-hwmon} fan ${n}"

      items+=("$(jq -cn --arg label "$label" --argjson rpm "$rpm" '{label: $label, rpm: $rpm}')")
    done
  done

  if [ "${#items[@]}" -eq 0 ]; then
    echo "[]"
    return
  fi
  printf '%s\n' "${items[@]}" | jq -s '.'
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
  name=$(run_bounded lspci -s "$addr" 2>/dev/null |
    sed -E 's/^[0-9a-fA-F:.]+ [^:]+: //' | head -n1)
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
  local items=()

  output=$(run_bounded nvidia-smi \
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
    IFS=',' read -r index pci name util temp fan memused memtotal extra <<<"$line"
    index=$(printf '%s' "$index" | trim)
    pci=$(printf '%s' "$pci" | trim)
    name=$(printf '%s' "$name" | trim)
    if ! [[ $index =~ ^[0-9]+$ ]] || [ -z "$pci" ] || [ -z "$name" ]; then
      echo "gpu: ignored malformed nvidia-smi row" >&2
      continue
    fi

    util_json=$(json_number_or_null "$util")
    temp_json=$(json_number_or_null "$temp")
    fan_json=$(json_number_or_null "$fan")
    memused_json=$(json_number_or_null "$memused")
    memtotal_json=$(json_number_or_null "$memtotal")

    [ "$util_json" != null ] || echo "gpu: NVIDIA $index utilization unavailable" >&2
    [ "$temp_json" != null ] || echo "gpu: NVIDIA $index temperature unavailable" >&2
    [ "$fan_json" != null ] || echo "gpu: NVIDIA $index fan percentage unavailable" >&2

    items+=("$(jq -cn \
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
    printf '%s\n' "${items[@]}" | jq -s '.'
  fi
}

amd_gpu_json() {
  local card="$1" util="" temp="" name hwmon hn raw card_name pci
  local memused="" memtotal="" util_json temp_json memused_json memtotal_json

  card_name=$(basename "$card")
  pci=$(basename "$(readlink -f "$card/device")" 2>/dev/null)

  if [ -r "$card/device/gpu_busy_percent" ]; then
    util=$(cat "$card/device/gpu_busy_percent" 2>/dev/null)
    [[ $util =~ ^[0-9]+$ ]] || util=""
  fi
  [ -n "$util" ] || echo "gpu: amdgpu gpu_busy_percent not available" >&2

  for hwmon in "$card"/device/hwmon/hwmon*; do
    [ -d "$hwmon" ] || continue
    hn=$(cat "$hwmon/name" 2>/dev/null)
    if [ "$hn" = "amdgpu" ] && [ -r "$hwmon/temp1_input" ]; then
      raw=$(cat "$hwmon/temp1_input" 2>/dev/null)
      [[ $raw =~ ^-?[0-9]+$ ]] && temp=$(awk -v v="$raw" 'BEGIN { printf "%.1f", v / 1000 }')
      break
    fi
  done
  [ -n "$temp" ] || echo "gpu: amdgpu hwmon temperature not available" >&2

  if [ -r "$card/device/mem_info_vram_used" ]; then
    raw=$(cat "$card/device/mem_info_vram_used" 2>/dev/null)
    [[ $raw =~ ^[0-9]+$ ]] && memused=$(awk -v v="$raw" 'BEGIN { printf "%.1f", v / 1048576 }')
  fi
  if [ -r "$card/device/mem_info_vram_total" ]; then
    raw=$(cat "$card/device/mem_info_vram_total" 2>/dev/null)
    [[ $raw =~ ^[0-9]+$ ]] && memtotal=$(awk -v v="$raw" 'BEGIN { printf "%.1f", v / 1048576 }')
  fi

  name=$(gpu_device_name "$card") || name="AMD GPU"
  util_json=$(json_number_or_null "$util")
  temp_json=$(json_number_or_null "$temp")
  memused_json=$(json_number_or_null "$memused")
  memtotal_json=$(json_number_or_null "$memtotal")

  jq -n --arg id "$card_name" --arg card "$card_name" --arg pci "$pci" --arg name "$name" \
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
    driver=$(sed -n 's/^DRIVER=//p' "$card/device/uevent" 2>/dev/null | head -n1)
  fi
  name=$(gpu_device_name "$card") || name="Intel Graphics"

  for hwmon in "$card"/device/hwmon/hwmon*; do
    [ -d "$hwmon" ] || continue
    if [ -r "$hwmon/temp1_input" ]; then
      raw=$(cat "$hwmon/temp1_input" 2>/dev/null)
      [[ $raw =~ ^-?[0-9]+$ ]] && temp=$(awk -v v="$raw" 'BEGIN { printf "%.1f", v / 1000 }')
      [ -n "$temp" ] && break
    fi
  done
  temp_json=$(json_number_or_null "$temp")

  echo "gpu: Intel utilization unavailable through standard sysfs (driver: ${driver:-unknown})" >&2
  [ "$temp_json" != null ] || echo "gpu: Intel temperature unavailable" >&2

  jq -n --arg id "$card_name" --arg card "$card_name" --arg pci "$pci" --arg name "$name" \
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
  jq -n --arg id "$card_name" --arg card "$card_name" --arg pci "$pci" --arg name "$name" \
    '{id: $id, card: $card, pciAddress: $pci, vendor: "nvidia", name: $name,
      utilPercent: null, tempC: null, memUsedMB: null,
      memTotalMB: null, fanPercent: null}'
}

gpus_json() {
  local card base vendor nvidia_json row pci suffix matched nvidia_count matched_count=0
  local discrete_items=() intel_items=() nvidia_cards=()

  while IFS= read -r card; do
    [ -d "$card" ] || continue
    base=$(basename "$card")
    [[ $base =~ ^card[0-9]+$ ]] || continue
    [ -r "$card/device/vendor" ] || continue
    vendor=$(cat "$card/device/vendor" 2>/dev/null)
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
  done < <(find "$DRM_ROOT" -maxdepth 1 -name 'card[0-9]*' 2>/dev/null | sort -V)

  if [ "${#nvidia_cards[@]}" -gt 0 ]; then
    nvidia_json=$(nvidia_gpus_json)
    nvidia_count=$(printf '%s' "$nvidia_json" | jq 'length' 2>/dev/null)
    [[ $nvidia_count =~ ^[0-9]+$ ]] || nvidia_count=0

    # Match nvidia-smi rows back to DRM cards by the bus/device/function
    # suffix. nvidia-smi commonly uses an eight-digit PCI domain while sysfs
    # uses four digits, so direct string equality is not portable.
    for card in "${nvidia_cards[@]}"; do
      base=$(basename "$card")
      pci=$(basename "$(readlink -f "$card/device")" 2>/dev/null)
      suffix=$(printf '%s' "$pci" | sed -E 's/^[0-9a-fA-F]+(:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}[.][0-9])$/\1/' | tr '[:upper:]' '[:lower:]')
      matched=$(printf '%s' "$nvidia_json" | jq -c --arg suffix "$suffix" \
        'map(select((.pciAddress | ascii_downcase | endswith($suffix)))) | first // empty' 2>/dev/null)
      if [ -n "$matched" ]; then
        row=$(printf '%s' "$matched" | jq -c --arg id "$base" --arg card "$base" \
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

  printf '%s\n' "${discrete_items[@]}" "${intel_items[@]}" | jq -s '.'
}

# ---------------------------------------------------------------------------
# Assemble
# ---------------------------------------------------------------------------
main() {
  local cpu_raw mem_obj temp_c core_count temp_json warnings_json collected_at_ms
  local gpu_obj gpus_arr gpu_warn_file line fans_arr os_obj

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
  if [ "$COLLECTOR_MODE" = "full" ]; then
    os_obj=$(os_json)
    [ -n "$os_obj" ] || os_obj="null"
  fi

  fans_arr=$(fans_json)
  [ -n "$fans_arr" ] || fans_arr="[]"

  # gpus_json runs via command substitution, i.e. in a subshell, so warnings it
  # appends to the array there would never reach this scope, so it writes
  # warnings to stderr instead and they're recovered here.
  gpu_warn_file=$(mktemp)
  gpus_arr=$(gpus_json 2>"$gpu_warn_file")
  echo "$gpus_arr" | jq -e 'type == "array"' >/dev/null 2>&1 || gpus_arr="[]"
  gpu_obj=$(printf '%s' "$gpus_arr" | jq 'if length > 0 then .[0] else null end')
  if [ -s "$gpu_warn_file" ]; then
    while IFS= read -r line; do
      [ -n "$line" ] && warnings+=("$line")
    done <"$gpu_warn_file"
  fi
  rm -f "$gpu_warn_file"

  temp_c=$(cpu_temp_c)
  if [ -n "$temp_c" ]; then
    temp_json="$temp_c"
  else
    temp_json="null"
    warnings+=("cpu: no CPU-labelled hwmon or thermal-zone temperature found")
  fi

  warnings_json="[]"
  if [ "${#warnings[@]}" -gt 0 ]; then
    warnings_json=$(printf '%s\n' "${warnings[@]}" | jq -R . | jq -s .)
  fi

  collected_at_ms=$(date +%s%3N 2>/dev/null)
  [[ $collected_at_ms =~ ^[0-9]+$ ]] || collected_at_ms=0

  jq -n \
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
    --argjson includeOs "$([ "$COLLECTOR_MODE" = "full" ] && echo true || echo false)" \
    '{
      cpu: { raw: $cpuRaw, coreCount: $coreCount, tempC: $cpuTempC },
      gpu: $gpu,
      gpus: $gpus,
      memory: $memory,
      fans: $fans,
      meta: { collectedAtMs: $collectedAtMs, warnings: $warnings }
    } | if $includeOs then . + {os: $os} else . end'
}

if [ "$COLLECTOR_MODE" = "static" ]; then
  static_main
else
  main
fi
exit 0
