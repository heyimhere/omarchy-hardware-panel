import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// Shared background hardware polling service. Omarchy creates this once from
// the manifest's service entry point, while every monitor's Panel.qml reads the
// same instance through bar.shell.serviceFor("hardware-panel").
Item {
  id: root

  // Injected by Omarchy's generic service loader. The singleton service owns
  // IPC so direct commands stay available without per-monitor target races.
  property var shell: null
  property int refreshIntervalSec: 2
  readonly property int pollTimeoutMs: Math.max(10000, refreshIntervalSec * 3000)

  // ---- CPU ----
  property real cpuPercent: -1 // -1 = unknown (no sample yet)
  property var cpuTempC: null // number or null
  property int cpuCoreCount: 0
  property var _prevCpuRaw: null

  // ---- GPU ----
  property bool gpuAvailable: false
  property string gpuVendor: ""
  property string gpuName: ""
  property var gpuUtilPercent: null // number or null (e.g. Intel: detected, unavailable)
  property var gpuTempC: null
  property var gpuMemUsedMB: null
  property var gpuMemTotalMB: null
  property var gpuFanPercent: null // percent, NOT rpm, nvidia-smi only
  property var gpus: []

  // ---- Fans ----
  property var fans: [] // array of {label, rpm}

  // ---- OS ----
  // Collected once when the shared service starts. The day count advances
  // locally, so regular hardware polls never reread the install log.
  property var osInstalledAtMs: null
  property double ageNowMs: Date.now()
  readonly property var osAgeDays: osInstalledAtMs !== null
    ? Model.osAgeDays(osInstalledAtMs, ageNowMs) : null

  // ---- Memory ----
  property real memUsedGB: -1
  property real memTotalGB: -1
  property real memPercent: -1

  // ---- Status ----
  property string lastError: ""
  property double lastCollectedAtMs: 0
  property var warnings: []
  property string _loggedWarningSignature: ""

  function configureRefreshInterval(value) {
    var n = parseInt(String(value), 10)
    if (!isFinite(n)) n = 2
    root.refreshIntervalSec = Math.max(1, Math.min(30, n))
  }

  function openPanel() {
    if (root.shell && typeof root.shell.summon === "function")
      root.shell.summon("hardware-panel", "")
  }

  function closePanel() {
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide("hardware-panel")
  }

  function togglePanel() {
    if (root.shell && typeof root.shell.toggle === "function")
      root.shell.toggle("hardware-panel", "")
  }

  // Resolve the collector script relative to this file's own location, since
  // a third-party plugin can't rely on $OMARCHY_PATH (that only ever points
  // at the first-party install) and must work whether this repo is
  // dev-symlinked or git-cloned by `omarchy plugin add`.
  readonly property string scriptPath: decodeURIComponent(
    String(Qt.resolvedUrl("bin/omarchy-hardware-collect.sh")).replace(/^file:\/\//, ""))

  function refresh() {
    if (collectProcess.running) return
    collectProcess.running = true
    pollWatchdog.restart()
  }

  function updateDiagnostics(nextWarnings) {
    root.warnings = nextWarnings
    var signature = nextWarnings.join("\n")
    if (signature === root._loggedWarningSignature) return
    root._loggedWarningSignature = signature
    if (nextWarnings.length > 0)
      console.warn("hardware-panel collector:", nextWarnings.join("; "))
    else
      console.info("hardware-panel collector recovered")
  }

  function applySnapshot(rawText) {
    var parsed = Model.parseSnapshot(rawText)
    if (!parsed.ok) {
      root.lastError = "Failed to parse hardware snapshot: " + parsed.error
      return
    }
    var data = parsed.data

    var cpu = data.cpu && typeof data.cpu === "object" ? data.cpu : null
    if (cpu) {
      var curRaw = Model.normalizeCpuRaw(cpu.raw)
      if (curRaw) {
        var computed = Model.computeCpuPercent(root._prevCpuRaw, curRaw)
        if (computed !== null) root.cpuPercent = computed
        root._prevCpuRaw = curRaw
      }
      if (typeof cpu.coreCount === "number" && cpu.coreCount >= 0)
        root.cpuCoreCount = cpu.coreCount
      if (Object.prototype.hasOwnProperty.call(cpu, "tempC"))
        root.cpuTempC = typeof cpu.tempC === "number" ? cpu.tempC : null
    }

    var nextGpus = null
    if (Array.isArray(data.gpus)) nextGpus = Model.normalizeGpus(data.gpus)
    else if (Object.prototype.hasOwnProperty.call(data, "gpu")) {
      var legacyGpu = Model.normalizeGpu(data.gpu)
      nextGpus = legacyGpu ? [legacyGpu] : []
    }
    if (nextGpus !== null) root.gpus = nextGpus

    // Preserve the original scalar API for compact bindings and downstream
    // users while the panel now renders every detected GPU from gpus[].
    var gpu = root.gpus.length > 0 ? root.gpus[0] : null
    root.gpuAvailable = gpu !== null
    root.gpuVendor = gpu ? gpu.vendor : ""
    root.gpuName = gpu ? gpu.name : ""
    root.gpuUtilPercent = gpu ? gpu.utilPercent : null
    root.gpuTempC = gpu ? gpu.tempC : null
    root.gpuMemUsedMB = gpu ? gpu.memUsedMB : null
    root.gpuMemTotalMB = gpu ? gpu.memTotalMB : null
    root.gpuFanPercent = gpu ? gpu.fanPercent : null

    if (Array.isArray(data.fans)) root.fans = Model.normalizeFans(data.fans)

    var mem = data.memory && typeof data.memory === "object" ? data.memory : null
    if (mem && typeof mem.totalKB === "number" && mem.totalKB > 0 &&
        typeof mem.availableKB === "number" && mem.availableKB >= 0) {
      var totalKB = mem.totalKB
      var availableKB = Math.min(mem.availableKB, totalKB)
      root.memTotalGB = Model.kbToGB(totalKB)
      root.memUsedGB = Model.kbToGB(totalKB - availableKB)
      root.memPercent = Model.memPercent(totalKB, availableKB)
    }

    var meta = data.meta || {}
    root.lastCollectedAtMs = typeof meta.collectedAtMs === "number" ? meta.collectedAtMs : Date.now()
    root.updateDiagnostics(Model.normalizeWarnings(meta.warnings))
    root.lastError = ""
  }

  Timer {
    id: refreshTimer
    interval: root.refreshIntervalSec * 1000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Timer {
    // Checking the clock is cheap and keeps the label current if the shell
    // remains running across the next age boundary.
    interval: 3600000
    repeat: true
    running: true
    onTriggered: root.ageNowMs = Date.now()
  }

  Timer {
    // A hung collector process (rare, but a sensor tool could wedge) would
    // otherwise silently stop future ticks forever, since refresh() only
    // starts a new run when the previous one isn't still running.
    id: pollWatchdog
    interval: root.pollTimeoutMs
    repeat: false
    running: false
    onTriggered: {
      if (collectProcess.running) {
        root.lastError = "Hardware collector timed out after " + Math.round(root.pollTimeoutMs / 1000) + " seconds"
        console.warn("hardware-panel:", root.lastError)
        collectProcess.running = false
      }
    }
  }

  IpcHandler {
    target: "hardware-panel"

    function open(): void { root.openPanel() }
    function close(): void { root.closePanel() }
    function show(): void { root.openPanel() }
    function hide(): void { root.closePanel() }
    function toggle(): void { root.togglePanel() }
  }

  Process {
    id: staticProcess
    running: true
    command: [root.scriptPath, "--static-only"]
    stdout: StdioCollector {
      id: staticStdout
      waitForEnd: true
    }
    stderr: StdioCollector {
      waitForEnd: true
    }
    onExited: function (exitCode) {
      if (exitCode !== 0) return
      var parsed = Model.parseSnapshot(String(staticStdout.text || ""))
      if (!parsed.ok) return
      var os = Model.normalizeOs(parsed.data.os)
      if (os) root.osInstalledAtMs = os.installedAtMs
    }
  }

  Process {
    id: collectProcess
    running: false
    command: [root.scriptPath, "--dynamic-only"]
    stdout: StdioCollector {
      id: collectStdout
      waitForEnd: true
    }
    stderr: StdioCollector {
      id: collectStderr
      waitForEnd: true
    }
    onExited: function (exitCode) {
      pollWatchdog.stop()
      if (exitCode === 0) {
        root.applySnapshot(String(collectStdout.text || ""))
      } else {
        var stderrText = String(collectStderr.text || "").trim()
        root.lastError = "Collector exited " + exitCode + (stderrText ? ": " + stderrText : "")
      }
    }
  }
}
