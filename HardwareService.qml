import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// Shared background hardware polling service. Omarchy creates this once from
// the manifest's service entry point, while every monitor's Panel.qml reads the
// same instance through bar.shell.serviceFor("io.github.heyimhere.hardware-panel").
Item {
  id: root

  // Injected by Omarchy's generic service loader. The singleton service owns
  // IPC so direct commands stay available without per-monitor target races.
  property var shell: null
  property int refreshIntervalSec: 2
  readonly property int pollTimeoutMs: Math.max(10000, refreshIntervalSec * 3000)
  readonly property int staticTimeoutMs: 10000

  // Producer-side byte caps in the collector script keep real snapshots well
  // under this, so it's only ever hit by a runaway/malfunctioning collector;
  // treated the same as a timeout (see killProcessGroup below). QProcess's
  // own read buffer is checked after each incoming chunk, keeping any overrun
  // to the size of one QProcess read.
  readonly property int maxCollectedBytes: 1048576
  readonly property int maxCollectedStderrBytes: 262144

  // ---- CPU ----
  property real cpuPercent: -1 // -1 = unknown (no sample yet)
  property var cpuTempC: null // number or null
  property int cpuCoreCount: 0
  // Collected once when the shared service starts, alongside osInstalledAtMs,
  // since the CPU model never changes at runtime.
  property var cpuName: null
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
      root.shell.summon("io.github.heyimhere.hardware-panel", "")
  }

  function closePanel() {
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide("io.github.heyimhere.hardware-panel")
  }

  function togglePanel() {
    if (root.shell && typeof root.shell.toggle === "function")
      root.shell.toggle("io.github.heyimhere.hardware-panel", "")
  }

  // Resolve the collector script relative to this file's own location, since
  // a third-party plugin can't rely on $OMARCHY_PATH (that only ever points
  // at the first-party install) and must work whether this repo is
  // dev-symlinked or git-cloned by `omarchy plugin add`.
  readonly property string scriptPath: decodeURIComponent(
    String(Qt.resolvedUrl("bin/omarchy-hardware-collect.sh")).replace(/^file:\/\//, ""))

  // Set by the watchdog-timeout and stdout-overflow handlers below so
  // onExited (which fires asynchronously afterward once the killed process
  // is actually reaped) doesn't clobber their specific message with its own
  // generic "Collector exited <code>" one.
  property bool _dynamicKillReported: false
  property bool _staticKillReported: false

  function refresh() {
    if (collectProcess.running) return
    root._dynamicKillReported = false
    collectProcess.running = true
    pollWatchdog.restart()
  }

  // Both collector Processes below run under `setsid`, giving each its own
  // session and initial process group distinct from Quickshell's. GNU timeout
  // may create a subordinate process group for a helper, so kill both the
  // initial negative PGID and every process in the dedicated session. This
  // covers the shell, timeout, the hardware helper, and its descendants.
  function killProcessGroup(proc) {
    var pid = Number(proc.processId)
    if (proc.running && isFinite(pid) && pid > 1) {
      Quickshell.execDetached(["kill", "-KILL", "--", "-" + Math.floor(pid)])
      Quickshell.execDetached(["pkill", "-KILL", "-s", String(Math.floor(pid))])
    }
    proc.running = false
  }

  function collectedByteLength(collector) {
    var bytes = collector.data
    if (bytes && typeof bytes.byteLength === "number") return bytes.byteLength
    // Compatibility fallback for a Quickshell build that exposes QByteArray
    // differently. Four bytes per UTF-16 code unit is deliberately
    // conservative, so a fallback can terminate early but never undercount.
    return String(collector.text || "").length * 4
  }

  function updateDiagnostics(nextWarnings) {
    root.warnings = nextWarnings
    var signature = nextWarnings.join("\n")
    if (signature === root._loggedWarningSignature) return
    root._loggedWarningSignature = signature
    if (nextWarnings.length > 0)
      console.warn("io.github.heyimhere.hardware-panel collector:", nextWarnings.join("; "))
    else
      console.info("io.github.heyimhere.hardware-panel collector recovered")
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
    // Static metadata is collected only once, but it invokes helpers too and
    // must not be allowed to leave a stuck process tree behind at startup.
    id: staticWatchdog
    interval: root.staticTimeoutMs
    repeat: false
    running: false
    onTriggered: {
      if (staticProcess.running) {
        root._staticKillReported = true
        root.lastError = "Static hardware collector timed out after " + Math.round(root.staticTimeoutMs / 1000) + " seconds"
        console.warn("io.github.heyimhere.hardware-panel:", root.lastError)
        root.killProcessGroup(staticProcess)
      }
    }
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
        root._dynamicKillReported = true
        root.lastError = "Hardware collector timed out after " + Math.round(root.pollTimeoutMs / 1000) + " seconds"
        console.warn("io.github.heyimhere.hardware-panel:", root.lastError)
        root.killProcessGroup(collectProcess)
      }
    }
  }

  IpcHandler {
    target: "io.github.heyimhere.hardware-panel"

    function open(): void { root.openPanel() }
    function close(): void { root.closePanel() }
    function show(): void { root.openPanel() }
    function hide(): void { root.closePanel() }
    function toggle(): void { root.togglePanel() }
  }

  // `setsid` puts each collection in its own session/process group; --wait
  // preserves the script's exit status. With QProcess's normal fork/exec
  // launch, the tracked pid is both the new session and process-group id.
  // See killProcessGroup() above for complete descendant cleanup.
  Process {
    id: staticProcess
    running: true
    command: ["setsid", "--wait", root.scriptPath, "--static-only"]
    onStarted: {
      root._staticKillReported = false
      staticWatchdog.restart()
    }
    stdout: StdioCollector {
      id: staticStdout
      waitForEnd: false
      onDataChanged: {
        if (staticProcess.running && root.collectedByteLength(staticStdout) > root.maxCollectedBytes) {
          root._staticKillReported = true
          root.lastError = "Static hardware collector output exceeded " + root.maxCollectedBytes + " bytes"
          console.warn("io.github.heyimhere.hardware-panel: static collector output exceeded", root.maxCollectedBytes, "bytes, terminating")
          root.killProcessGroup(staticProcess)
        }
      }
    }
    stderr: StdioCollector {
      id: staticStderr
      waitForEnd: false
      onDataChanged: {
        if (staticProcess.running && root.collectedByteLength(staticStderr) > root.maxCollectedStderrBytes) {
          root._staticKillReported = true
          root.lastError = "Static hardware collector stderr exceeded " + root.maxCollectedStderrBytes + " bytes"
          console.warn("io.github.heyimhere.hardware-panel:", root.lastError)
          root.killProcessGroup(staticProcess)
        }
      }
    }
    // Best-effort teardown cleanup: Quickshell's Process destructor SIGKILLs
    // only its immediate child, and `setsid` deliberately places the collector
    // outside Quickshell's session, so a reload mid-collection would otherwise
    // orphan what the script spawned. This runs on engine-driven destruction
    // (config reload); an abrupt process death cannot run QML handlers at all,
    // which is safe here because every helper is already `timeout`-bounded.
    Component.onDestruction: root.killProcessGroup(staticProcess)
    onExited: function (exitCode) {
      staticWatchdog.stop()
      if (exitCode !== 0 || root._staticKillReported) return
      var parsed = Model.parseSnapshot(String(staticStdout.text || ""))
      if (!parsed.ok) return
      var os = Model.normalizeOs(parsed.data.os)
      if (os) root.osInstalledAtMs = os.installedAtMs
      root.cpuName = Model.normalizeCpuName(parsed.data.cpuName)
    }
  }

  Process {
    id: collectProcess
    running: false
    command: ["setsid", "--wait", root.scriptPath, "--dynamic-only"]
    stdout: StdioCollector {
      id: collectStdout
      // false so overflow can be observed and acted on mid-stream; the
      // collector script already caps its output well under maxCollectedBytes,
      // so this only ever fires against a runaway/malfunctioning collector.
      waitForEnd: false
      onDataChanged: {
        if (collectProcess.running && root.collectedByteLength(collectStdout) > root.maxCollectedBytes) {
          root._dynamicKillReported = true
          root.lastError = "Hardware collector output exceeded " + root.maxCollectedBytes + " bytes"
          console.warn("io.github.heyimhere.hardware-panel:", root.lastError)
          root.killProcessGroup(collectProcess)
        }
      }
    }
    stderr: StdioCollector {
      id: collectStderr
      waitForEnd: false
      onDataChanged: {
        if (collectProcess.running && root.collectedByteLength(collectStderr) > root.maxCollectedStderrBytes) {
          root._dynamicKillReported = true
          root.lastError = "Hardware collector stderr exceeded " + root.maxCollectedStderrBytes + " bytes"
          console.warn("io.github.heyimhere.hardware-panel:", root.lastError)
          root.killProcessGroup(collectProcess)
        }
      }
    }
    // See staticProcess above: best-effort reload cleanup, since the destructor
    // alone leaves descendants of an in-flight poll outside Quickshell's session.
    Component.onDestruction: root.killProcessGroup(collectProcess)
    onExited: function (exitCode) {
      pollWatchdog.stop()
      if (exitCode === 0) {
        root.applySnapshot(String(collectStdout.text || ""))
      } else if (!root._dynamicKillReported) {
        var stderrText = String(collectStderr.text || "").trim()
        root.lastError = "Collector exited " + exitCode + (stderrText ? ": " + stderrText : "")
      }
    }
  }
}
