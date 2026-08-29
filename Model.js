// Pure parsing/formatting/math helpers for the hardware panel. No Quickshell
// imports here so this file can be unit tested with plain `node` (see
// test/model.test.js) as well as imported from QML.

function parseSnapshot(rawText) {
  try {
    var data = JSON.parse(String(rawText || ""))
    if (!data || typeof data !== "object" || Array.isArray(data))
      return { ok: false, data: null, error: "snapshot is not an object" }
    return { ok: true, data: data, error: null }
  } catch (e) {
    return { ok: false, data: null, error: String(e) }
  }
}

// Computes CPU utilization percent (0-100) from two raw /proc/stat samples.
// Returns null if there is no previous sample yet, or if the counters did
// not advance (e.g. two samples collected in the same tick).
function computeCpuPercent(prevRaw, curRaw) {
  if (!prevRaw || !curRaw) return null

  function total(raw) {
    return (raw.user || 0) + (raw.nice || 0) + (raw.system || 0) + (raw.idle || 0) +
           (raw.iowait || 0) + (raw.irq || 0) + (raw.softirq || 0) + (raw.steal || 0)
  }

  var prevTotal = total(prevRaw)
  var curTotal = total(curRaw)
  var totalDelta = curTotal - prevTotal
  if (totalDelta <= 0) return null

  // Linux tools conventionally treat iowait as idle time. It remains part of
  // total time, but should not make a machine waiting on storage look busy.
  var idleDelta = ((curRaw.idle || 0) + (curRaw.iowait || 0)) -
                  ((prevRaw.idle || 0) + (prevRaw.iowait || 0))
  var percent = (1 - idleDelta / totalDelta) * 100
  if (percent < 0) percent = 0
  if (percent > 100) percent = 100
  return percent
}

function normalizeCpuRaw(raw) {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return null
  var fields = ["user", "nice", "system", "idle", "iowait", "irq", "softirq", "steal"]
  var result = {}
  for (var i = 0; i < fields.length; i++) {
    var value = raw[fields[i]]
    if (typeof value !== "number" || !isFinite(value) || value < 0) return null
    result[fields[i]] = value
  }
  return result
}

// Normalizes a raw gpu object from the collector into a shape safe to bind
// to QML properties, or null if the input isn't a usable object (missing,
// malformed, or the collector found no supported GPU). Fields the collector
// intentionally leaves null (e.g. Intel utilization/temp) stay null here too.
// That is a "detected but degraded" state, distinct from "no GPU".
function normalizeGpu(raw) {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return null
  if (typeof raw.vendor !== "string" || raw.vendor === "") return null

  function numOrNull(v) {
    return typeof v === "number" && isFinite(v) ? v : null
  }

  function nonNegativeOrNull(v) {
    var n = numOrNull(v)
    return n !== null && n >= 0 ? n : null
  }

  function percentOrNull(v) {
    var n = numOrNull(v)
    return n !== null && n >= 0 && n <= 100 ? n : null
  }

  return {
    id: typeof raw.id === "string" ? raw.id : "",
    card: typeof raw.card === "string" ? raw.card : "",
    pciAddress: typeof raw.pciAddress === "string" ? raw.pciAddress : "",
    vendor: raw.vendor,
    name: typeof raw.name === "string" && raw.name !== "" ? raw.name : raw.vendor,
    utilPercent: percentOrNull(raw.utilPercent),
    tempC: numOrNull(raw.tempC),
    memUsedMB: nonNegativeOrNull(raw.memUsedMB),
    memTotalMB: nonNegativeOrNull(raw.memTotalMB),
    fanPercent: percentOrNull(raw.fanPercent)
  }
}

function normalizeGpus(raw) {
  if (!Array.isArray(raw)) return []
  var result = []
  for (var i = 0; i < raw.length; i++) {
    var gpu = normalizeGpu(raw[i])
    if (gpu) result.push(gpu)
  }
  return result
}

// Normalizes a raw fans array from the collector into a list of
// {label, rpm} objects safe to bind in QML, dropping any malformed entries
// rather than failing the whole list. Missing/non-array input becomes [].
function normalizeFans(raw) {
  if (!Array.isArray(raw)) return []
  var result = []
  for (var i = 0; i < raw.length; i++) {
    var entry = raw[i]
    if (!entry || typeof entry !== "object") continue
    if (typeof entry.rpm !== "number" || !isFinite(entry.rpm) || entry.rpm < 0) continue
    var label = typeof entry.label === "string" && entry.label !== "" ? entry.label : "Fan " + (result.length + 1)
    result.push({ label: label, rpm: entry.rpm })
  }
  return result
}

function normalizeWarnings(raw) {
  if (!Array.isArray(raw)) return []
  var result = []
  for (var i = 0; i < raw.length; i++) {
    if (typeof raw[i] === "string" && raw[i] !== "") result.push(raw[i])
  }
  return result
}

// Normalizes a raw os object from the collector (an install timestamp), or
// null if missing/malformed.
function normalizeOs(raw) {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return null
  if (typeof raw.installedAtMs !== "number" || !isFinite(raw.installedAtMs) || raw.installedAtMs <= 0)
    return null
  return { installedAtMs: raw.installedAtMs }
}

// Whole days since installedAtMs. nowMs defaults to Date.now() when omitted
// (the QML call site), but can be passed explicitly for deterministic tests.
function osAgeDays(installedAtMs, nowMs) {
  if (typeof installedAtMs !== "number" || !isFinite(installedAtMs)) return null
  var now = typeof nowMs === "number" ? nowMs : Date.now()
  var deltaMs = now - installedAtMs
  if (deltaMs < 0) deltaMs = 0
  return Math.floor(deltaMs / 86400000)
}

function kbToGB(kb) {
  if (typeof kb !== "number" || !isFinite(kb) || kb < 0) return null
  return kb / 1024 / 1024
}

function memPercent(totalKB, availableKB) {
  if (typeof totalKB !== "number" || !isFinite(totalKB) || totalKB <= 0) return null
  if (typeof availableKB !== "number" || !isFinite(availableKB)) return null
  var usedKB = totalKB - availableKB
  if (usedKB < 0) usedKB = 0
  return Math.min(100, (usedKB / totalKB) * 100)
}

function formatPercent(n) {
  if (typeof n !== "number" || isNaN(n)) return "N/A"
  return Math.round(n) + "%"
}

function formatTemp(c) {
  if (typeof c !== "number" || isNaN(c)) return "N/A"
  return Math.round(c) + "°C"
}

if (typeof module !== "undefined") {
  module.exports = {
    parseSnapshot: parseSnapshot,
    computeCpuPercent: computeCpuPercent,
    normalizeCpuRaw: normalizeCpuRaw,
    normalizeGpu: normalizeGpu,
    normalizeGpus: normalizeGpus,
    normalizeFans: normalizeFans,
    normalizeWarnings: normalizeWarnings,
    normalizeOs: normalizeOs,
    osAgeDays: osAgeDays,
    kbToGB: kbToGB,
    memPercent: memPercent,
    formatPercent: formatPercent,
    formatTemp: formatTemp
  }
}
