# Hardware Panel

A hardware monitoring plugin for the [Omarchy](https://omarchy.org) Quattro shell.
Shows CPU and GPU utilization in the bar (`CPU 18%  GPU 6%`), and clicking it opens a
compact popup with CPU, GPU, memory, and fan details, built entirely from Omarchy's
own panel components, so it looks and behaves like a first-party widget.

It never assumes a specific machine. CPU temperature, every supported GPU, and fan
sensors are detected at runtime. Metrics that are not present are omitted or shown as
unavailable without hiding the hardware that was successfully detected.

## Installation

**Local development** (symlink, so edits take effect immediately):

```sh
git clone https://github.com/heyimhere/omarchy-hardware-panel.git ~/src/omarchy-hardware-panel
ln -s ~/src/omarchy-hardware-panel ~/.config/omarchy/plugins/hardware-panel
omarchy-shell shell rescanPlugins
omarchy plugin enable hardware-panel
```

**Published install:**

```sh
omarchy plugin add https://github.com/heyimhere/omarchy-hardware-panel.git --enable
```

QML source changes are picked up automatically once a file watcher notices the edit.
If a change doesn't seem to take effect, run `omarchy-restart-shell` to force a clean
reload. Changes to `bin/omarchy-hardware-collect.sh` take effect on the very next poll
tick with no restart needed, since it's a plain script the shell re-invokes each time.

## Requirements

- `bash`, `jq`, and standard coreutils (`awk`, `find`, `sort`, `mktemp`, `timeout`),
  all already present on an Omarchy install.
- No root access is ever required, for any metric.

## Supported hardware

| Metric | Source | Notes |
|---|---|---|
| CPU usage | `/proc/stat` | Always available on Linux. |
| CPU temperature | CPU-labelled hwmon sensors, known CPU drivers, then CPU/package/SoC thermal zones | Prefers `coretemp` package temperature and `k10temp`/`zenpower` `Tctl` or `Tdie`, while also supporting appropriately labelled laptop and SoC sensors. |
| Memory | `/proc/meminfo` | Always available. |
| GPU (NVIDIA) | DRM detection plus `nvidia-smi` | Utilization, temperature, VRAM, and fan percentage. Every field is parsed independently, so `N/A` fan data does not discard valid utilization. A failed command leaves the detected GPU visible with unavailable metrics. |
| GPU (AMD) | DRM sysfs, `gpu_busy_percent`, `amdgpu` hwmon, and VRAM sysfs counters | Utilization, temperature, and VRAM when each interface is available. |
| GPU (Intel) | DRM vendor/driver detection plus device hwmon | Name and temperature when exposed. Utilization remains unavailable because i915 and xe do not provide a general unprivileged sysfs utilization counter. |
| Fans | every hwmon chip's `fan*_input` | Works with any driver (`nct6775`, `it87`, `applesmc`, `thinkpad_acpi`, `dell_smm`, `asus_wmi_sensors`, and others). A board that exposes none, including the machine this plugin was developed on, correctly shows no Fans section, not an error. |

Every detected NVIDIA, AMD, and Intel GPU is shown in the panel. Discrete GPUs are
listed before Intel GPUs. The compact bar uses the first GPU that exposes utilization
so it remains useful and small.

## Optional dependency: lm_sensors

Not required. If `sensors` (lm_sensors) is installed and a fan's sysfs entry has no
`fanN_label` file, the collector tries to borrow a nicer name from `sensors -j`.
Many boards' `/etc/sensors.d/*.conf` community configs rename raw `fan1`/`fan2` into
names like "CPU Fan". Without it, fans just get a synthesized label like
`nct6798 fan 1`. Install with `sudo pacman -S lm_sensors` and run `sudo sensors-detect`
if you want this.

## Debugging sensor detection

Run the collector directly and read its JSON output. This is exactly what
`HardwareService.qml` parses every poll tick:

```sh
bash ~/.config/omarchy/plugins/hardware-panel/bin/omarchy-hardware-collect.sh | jq .
```

Each top-level key tells you what was detected:

- `cpu.tempC`: `null` means no CPU-labelled hwmon sensor or CPU thermal zone was found.
- `gpus`: an array containing every detected NVIDIA, AMD, and Intel GPU. Individual
  metrics are `null` when unavailable.
- `gpu`: the preferred first GPU, retained as a compatibility field for older tooling.
  It is `null` only when no supported GPU was detected under `/sys/class/drm`.
- `fans`: `[]` means no `fan*_input` files exist under `/sys/class/hwmon`.
- `os`: `{ "installedAtMs": ... }` parsed from the first line of
  `/var/log/omarchy-install.log`, or `null` if that log is missing or unreadable.
  Shown as a subtitle line ("Installed 118 days") under the panel's title.
- `meta.warnings`: a plain-English reason for anything above that came back
  null/empty.

Example output on the machine this plugin was developed on (NVIDIA desktop, no
exposed fan sensors):

```json
{
  "cpu": { "raw": { "...": "..." }, "coreCount": 12, "tempC": 31.0 },
  "gpu": { "vendor": "nvidia", "name": "NVIDIA GeForce GTX 1080", "utilPercent": 3, "tempC": 51 },
  "gpus": [
    {
      "vendor": "nvidia", "name": "NVIDIA GeForce GTX 1080",
      "utilPercent": 3, "tempC": 51, "memUsedMB": 1521,
      "memTotalMB": 8192, "fanPercent": 0
    }
  ],
  "memory": { "totalKB": 49231812, "availableKB": 41575560 },
  "fans": [],
  "os": { "installedAtMs": 1777778657000 },
  "meta": { "collectedAtMs": 1787982983547, "warnings": [] }
}
```

You can also point the collector at captured files for offline debugging. It supports
`HWMON_ROOT`, `THERMAL_ROOT`, `DRM_ROOT`, `PROC_STAT_PATH`, `MEMINFO_PATH`, and
`OMARCHY_INSTALL_LOG`. For example: `HWMON_ROOT=/path/to/snapshot/sys/class/hwmon bash
bin/omarchy-hardware-collect.sh`.

## Plugin architecture

```
manifest.json               declares one shared service and one bar-widget entry point
Panel.qml                   per-monitor bar row and popup; reads the shared service
HardwareService.qml         one shell-wide poller, Process, age-based watchdog, and
                             defensive snapshot state exposed to every Panel.qml
Model.js                    pure parsing/math (CPU delta %, GPU/fan normalization);
                             unit-tested standalone with `node test/model.test.js`
bin/omarchy-hardware-collect.sh   the only thing that touches /proc, /sys, and
                             external tools; prints one JSON object per run
test/collector.test.sh      captured proc/sysfs and command fixtures for GPUs, fans,
                             partial metrics, and command failures
```

`HardwareService.qml` is a manifest `"service"` kind and Omarchy creates exactly one
instance for the enabled plugin. Each monitor still gets its own lightweight bar
widget and popup, but those widgets resolve the shared instance through
`bar.shell.serviceFor("hardware-panel")`. This follows the shell's combined service
and bar-widget architecture and prevents duplicate sensor polling on multi-monitor
systems.

The service reads Omarchy's installation timestamp once at startup through the
collector's `--static-only` mode. Missing or malformed install metadata is silently
omitted because it is cosmetic. An in-process timer updates the derived day count,
while regular two-second hardware polls use `--dynamic-only` and never reread the log.

The shared service also owns the single `hardware-panel` IPC target. Commands such as
`omarchy-shell hardware-panel open`, `close`, and `toggle` route through Omarchy's
bar-widget coordinator, preserving scripting and keybindings without registering a
competing handler on every monitor.

**Reliability**: every optional external command (`nvidia-smi`, `sensors`, `lspci`) is
wrapped in a 3-second `timeout`. If `timeout` itself is missing, those optional tools
are skipped rather than run unbounded. `/proc` and `/sys` reads are plain files. A
one-shot QML watchdog starts with each collection and is stopped when that exact
process exits, so it cannot accidentally terminate a newer poll. Malformed fields do
not replace last-known-good CPU or memory state. Collector warnings are logged only
when their content changes, which keeps diagnostics useful without flooding the log.

Refresh interval defaults to 2 seconds and is user-configurable (1 to 30 seconds) via
the widget's settings (`refreshIntervalSec` in the manifest's `barWidget.schema`).

## Known limitations

- Intel integrated GPU utilization is unavailable through the standard sysfs
  interfaces. Temperature is shown when device hwmon exposes it.
- NVIDIA reports fan percentage rather than RPM. It is shown with the GPU instead of
  being mislabeled as an RPM fan sensor.
- Point-in-time values only, no historical graphing in this version.

## Validating changes

```sh
omarchy plugin validate .
node test/model.test.js
bash test/collector.test.sh
```

## License

MIT, see [LICENSE](LICENSE).
