// Plain-node test for Model.js. Run with: node test/model.test.js
"use strict"

const Model = require("../Model.js")

let failures = 0

function assertEqual(actual, expected, label) {
  const ok = JSON.stringify(actual) === JSON.stringify(expected)
  if (!ok) {
    failures++
    console.error(`FAIL: ${label}\n  expected: ${JSON.stringify(expected)}\n  actual:   ${JSON.stringify(actual)}`)
  } else {
    console.log(`ok - ${label}`)
  }
}

function assertClose(actual, expected, label, epsilon) {
  epsilon = epsilon || 0.01
  const ok = typeof actual === "number" && Math.abs(actual - expected) < epsilon
  if (!ok) {
    failures++
    console.error(`FAIL: ${label}\n  expected ~${expected}\n  actual:   ${actual}`)
  } else {
    console.log(`ok - ${label}`)
  }
}

// ---- parseSnapshot ----
assertEqual(Model.parseSnapshot('{"cpu":{}}').ok, true, "parseSnapshot: valid JSON object")
assertEqual(Model.parseSnapshot("not json").ok, false, "parseSnapshot: malformed JSON")
assertEqual(Model.parseSnapshot("[]").ok, false, "parseSnapshot: JSON array is rejected (not an object)")
assertEqual(Model.parseSnapshot("").ok, false, "parseSnapshot: empty string")
assertEqual(Model.parseSnapshot(null).ok, false, "parseSnapshot: null input")

// ---- computeCpuPercent ----
assertEqual(Model.computeCpuPercent(null, { user: 1, idle: 1 }), null, "computeCpuPercent: no previous sample")

const prev = { user: 100, nice: 0, system: 50, idle: 850, iowait: 0, irq: 0, softirq: 0, steal: 0 }
const curIdle = { user: 110, nice: 0, system: 55, idle: 935, iowait: 0, irq: 0, softirq: 0, steal: 0 }
// total delta = (110+55+935) - (100+50+850) = 1100-1000 = 100; idle delta = 85 -> busy 15%
assertClose(Model.computeCpuPercent(prev, curIdle), 15, "computeCpuPercent: 15% busy")

assertEqual(Model.computeCpuPercent(prev, prev), null, "computeCpuPercent: identical samples (no advance) is null")

const curBusy = { user: 300, nice: 0, system: 200, idle: 900, iowait: 0, irq: 0, softirq: 0, steal: 0 }
// total delta = 1400-1000=400; idle delta=50 -> busy 87.5%
assertClose(Model.computeCpuPercent(prev, curBusy), 87.5, "computeCpuPercent: 87.5% busy")

const prevWait = { user: 100, nice: 0, system: 50, idle: 800, iowait: 50, irq: 0, softirq: 0, steal: 0 }
const curWait = { user: 110, nice: 0, system: 55, idle: 870, iowait: 65, irq: 0, softirq: 0, steal: 0 }
// Total delta 100, idle+iowait delta 85, so storage wait is not counted busy.
assertClose(Model.computeCpuPercent(prevWait, curWait), 15, "computeCpuPercent: iowait counts as idle")

assertEqual(Model.normalizeCpuRaw(prev), prev, "normalizeCpuRaw: valid counters preserved")
assertEqual(Model.normalizeCpuRaw({ user: 1 }), null, "normalizeCpuRaw: incomplete counters rejected")
assertEqual(Model.normalizeCpuRaw({ ...prev, idle: -1 }), null, "normalizeCpuRaw: negative counter rejected")

// ---- normalizeGpu ----
assertEqual(Model.normalizeGpu(null), null, "normalizeGpu: null input is null")
assertEqual(Model.normalizeGpu([1, 2]), null, "normalizeGpu: array input is null")
assertEqual(Model.normalizeGpu({}), null, "normalizeGpu: missing vendor is null")

const nvidiaGpu = Model.normalizeGpu({
  vendor: "nvidia", name: "NVIDIA GeForce GTX 1080",
  utilPercent: 6, tempC: 49, memUsedMB: 1354, memTotalMB: 8192, fanPercent: 0
})
assertEqual(nvidiaGpu && nvidiaGpu.vendor, "nvidia", "normalizeGpu: valid nvidia object keeps vendor")
assertEqual(nvidiaGpu && nvidiaGpu.utilPercent, 6, "normalizeGpu: valid nvidia object keeps utilPercent")

const intelGpu = Model.normalizeGpu({ vendor: "intel", name: "Intel Graphics", utilPercent: null, tempC: null })
assertEqual(intelGpu && intelGpu.utilPercent, null, "normalizeGpu: intel degraded util stays null, not dropped")
assertEqual(intelGpu && intelGpu.vendor, "intel", "normalizeGpu: intel vendor preserved")

const malformedGpu = Model.normalizeGpu({ vendor: "nvidia", utilPercent: "not a number" })
assertEqual(malformedGpu && malformedGpu.utilPercent, null, "normalizeGpu: non-numeric field coerced to null, not crash")
assertEqual(malformedGpu && malformedGpu.name, "nvidia", "normalizeGpu: missing name falls back to vendor")
assertEqual(Model.normalizeGpu({ vendor: "nvidia", utilPercent: 101 }).utilPercent, null, "normalizeGpu: invalid percentage becomes null")
assertEqual(Model.normalizeGpu({ vendor: "nvidia", memTotalMB: -1 }).memTotalMB, null, "normalizeGpu: negative memory becomes null")

assertEqual(
  Model.normalizeGpus([nvidiaGpu, null, intelGpu]).map(gpu => gpu.vendor),
  ["nvidia", "intel"],
  "normalizeGpus: malformed entries dropped without losing valid GPUs"
)
assertEqual(Model.normalizeGpus(null), [], "normalizeGpus: non-array becomes empty")

// ---- normalizeFans ----
assertEqual(Model.normalizeFans(null), [], "normalizeFans: null input is []")
assertEqual(Model.normalizeFans("nope"), [], "normalizeFans: non-array input is []")
assertEqual(Model.normalizeFans([]), [], "normalizeFans: empty array stays []")
assertEqual(
  Model.normalizeFans([{ label: "CPU Fan", rpm: 1840 }, { label: "GPU Fan", rpm: 1120 }]),
  [{ label: "CPU Fan", rpm: 1840 }, { label: "GPU Fan", rpm: 1120 }],
  "normalizeFans: multiple valid fans preserved in order"
)
assertEqual(
  Model.normalizeFans([{ rpm: 900 }]),
  [{ label: "Fan 1", rpm: 900 }],
  "normalizeFans: missing label synthesized"
)
assertEqual(
  Model.normalizeFans([{ label: "Bad" }, { label: "Good", rpm: 500 }, "garbage", null]),
  [{ label: "Good", rpm: 500 }],
  "normalizeFans: malformed entries dropped, valid ones kept"
)
assertEqual(Model.normalizeFans([{ label: "Impossible", rpm: -1 }]), [], "normalizeFans: negative RPM dropped")

// ---- warnings ----
assertEqual(Model.normalizeWarnings(["one", "", null, "two"]), ["one", "two"], "normalizeWarnings: invalid entries dropped")
assertEqual(Model.normalizeWarnings("warning"), [], "normalizeWarnings: non-array becomes empty")

// ---- normalizeOs / osAgeDays ----
assertEqual(Model.normalizeOs(null), null, "normalizeOs: null input is null")
assertEqual(Model.normalizeOs({}), null, "normalizeOs: missing installedAtMs is null")
assertEqual(Model.normalizeOs({ installedAtMs: 0 }), null, "normalizeOs: zero timestamp is null")
assertEqual(Model.normalizeOs({ installedAtMs: -5 }), null, "normalizeOs: negative timestamp is null")
assertEqual(Model.normalizeOs({ installedAtMs: 1000 }), { installedAtMs: 1000 }, "normalizeOs: valid timestamp preserved")

// ---- normalizeCpuName ----
assertEqual(Model.normalizeCpuName(null), null, "normalizeCpuName: null input is null")
assertEqual(Model.normalizeCpuName(undefined), null, "normalizeCpuName: undefined input is null")
assertEqual(Model.normalizeCpuName(""), null, "normalizeCpuName: empty string is null")
assertEqual(Model.normalizeCpuName(42), null, "normalizeCpuName: non-string coerced to null")
assertEqual(Model.normalizeCpuName("AMD Ryzen 9 5900HX"), "AMD Ryzen 9 5900HX", "normalizeCpuName: valid string preserved")

const dayMs = 86400000
assertEqual(Model.osAgeDays(1000, 1000), 0, "osAgeDays: installed just now is 0 days")
assertEqual(Model.osAgeDays(0, dayMs * 5), 5, "osAgeDays: exactly 5 days later")
assertEqual(Model.osAgeDays(0, dayMs * 5 + 1000), 5, "osAgeDays: rounds down, not up")
assertEqual(Model.osAgeDays(dayMs * 5, 1000), 0, "osAgeDays: install timestamp in the future clamps to 0")
assertEqual(Model.osAgeDays(null, 1000), null, "osAgeDays: non-number installedAtMs is null")
assertEqual(typeof Model.osAgeDays(0), "number", "osAgeDays: nowMs defaults to Date.now() when omitted")

// ---- kbToGB / memPercent ----
assertClose(Model.kbToGB(1048576), 1, "kbToGB: 1048576 KB is 1 GB")
assertEqual(Model.kbToGB(null), null, "kbToGB: non-number is null")
assertEqual(Model.kbToGB(Infinity), null, "kbToGB: infinite value is null")

assertClose(Model.memPercent(1000, 500), 50, "memPercent: half used")
assertEqual(Model.memPercent(0, 500), null, "memPercent: zero total is null")
assertClose(Model.memPercent(1000, 1200), 0, "memPercent: available > total clamps to 0% used")

// ---- formatPercent / formatTemp ----
assertEqual(Model.formatPercent(18.4), "18%", "formatPercent: rounds down")
assertEqual(Model.formatPercent(NaN), "N/A", "formatPercent: NaN is N/A")
assertEqual(Model.formatTemp(54.6), "55°C", "formatTemp: rounds")
assertEqual(Model.formatTemp(null), "N/A", "formatTemp: null is N/A")

if (failures > 0) {
  console.error(`\n${failures} test(s) failed`)
  process.exit(1)
}
console.log("\nall tests passed")
