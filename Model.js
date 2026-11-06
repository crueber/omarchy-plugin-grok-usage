.pragma library

// Pure helpers for the Grok usage widget. Kept out of Panel.qml so parsing,
// formatting, cache rules, and poll coordination stay testable.

function number(value) {
  var n = typeof value === "number" ? value : Number(value)
  return isFinite(n) ? n : null
}

function clamp(value, low, high) {
  return Math.min(high, Math.max(low, value))
}

function clampInt(value, low, high, fallback) {
  var n = number(value)
  if (n === null) return fallback
  return Math.round(clamp(n, low, high))
}

function text(value, max) {
  if (typeof value !== "string") return ""
  return value.slice(0, max || 200)
}

// Neutralise markup-shaped strings before they reach an Omarchy-owned text
// component whose format this plugin cannot set. Our own Text elements all use
// Text.PlainText.
function plain(value, max) {
  return text(value, max).replace(/</g, "\u2039").replace(/>/g, "\u203A")
}

function percent(value) {
  var n = number(value)
  return n === null ? 0 : clamp(n, 0, 100)
}

function parseJson(raw) {
  var source = String(raw || "").replace(/^\uFEFF+/, "").trim()
  if (source === "" || source.length > 400000) return null
  try {
    return JSON.parse(source)
  } catch (e) {
    var start = source.indexOf("{")
    var end = source.lastIndexOf("}")
    if (start < 0 || end <= start) return null
    try {
      return JSON.parse(source.slice(start, end + 1))
    } catch (e2) {
      return null
    }
  }
}

// The helper always emits one JSON object. A false `ok` is a normal empty
// state (no log yet, no billing line yet), not a crash.
function parseResult(raw) {
  var obj = parseJson(raw)
  if (!obj || typeof obj !== "object") return null
  if (obj.ok === false) {
    return { ok: false, error: text(obj.error, 300) }
  }
  if (obj.ok !== true) return null

  var weekly = obj.weekly && typeof obj.weekly === "object" ? obj.weekly : null
  if (!weekly) return null
  var resetsAt = number(weekly.resetsAt) || 0
  if (resetsAt <= 0) return null

  var onDemand = obj.onDemand && typeof obj.onDemand === "object" ? obj.onDemand : null

  return {
    ok: true,
    report: {
      source: text(obj.source, 40),
      logPath: text(obj.logPath, 400),
      snapshotAt: number(obj.snapshotAt) || 0,
      tier: plain(obj.tier, 60),
      unified: obj.unified === true,
      periodType: text(weekly.periodType, 60),
      period: periodKind(weekly.periodType),
      weekly: {
        percent: percent(weekly.usedPercent),
        periodStart: number(weekly.periodStart) || 0,
        resetsAt: resetsAt,
        expired: weekly.expired === true || Date.now() >= resetsAt
      },
      onDemand: onDemand ? {
        cap: Math.max(0, number(onDemand.cap) || 0),
        used: Math.max(0, number(onDemand.used) || 0),
        prepaid: Math.max(0, number(onDemand.prepaid) || 0)
      } : { cap: 0, used: 0, prepaid: 0 },
      local: parseLocal(obj.local)
    }
  }
}

function parseLocal(value) {
  if (!value || typeof value !== "object") return null
  return {
    sessions: Math.max(0, Math.round(number(value.sessions) || 0)),
    turns: Math.max(0, Math.round(number(value.turns) || 0)),
    tokens: Math.max(0, number(value.tokens) || 0),
    input: Math.max(0, number(value.input) || 0),
    output: Math.max(0, number(value.output) || 0),
    cached: Math.max(0, number(value.cached) || 0),
    reasoning: Math.max(0, number(value.reasoning) || 0),
    costUsd: Math.max(0, number(value.costUsd) || 0),
    since: (function() {
      var direct = number(value.since)
      if (direct !== null) return direct
      return number(Date.parse(value.since || "")) || 0
    })()
  }
}

// Grok reports its allowance period in currentPeriod.type. Weekly is the
// common SuperGrok window, but a monthly or daily plan should not be labelled
// "weekly", so derive the wording from the snapshot.
function periodKind(type) {
  var value = String(type || "").toUpperCase()
  if (value.indexOf("MONTH") >= 0) return "month"
  if (value.indexOf("DAY") >= 0 || value.indexOf("DAILY") >= 0) return "day"
  if (value.indexOf("WEEK") >= 0) return "week"
  return "other"
}

function periodName(kind) {
  if (kind === "month") return "Monthly"
  if (kind === "day") return "Daily"
  if (kind === "week") return "Weekly"
  return "Usage"
}

function periodNoun(kind) {
  if (kind === "month") return "month"
  if (kind === "day") return "day"
  if (kind === "week") return "week"
  return "period"
}

function periodLocal(kind) {
  if (kind === "month") return "this month"
  if (kind === "day") return "today"
  if (kind === "week") return "this week"
  return "this period"
}

var PERIOD_DEFS = {
  week: { label: "Week", short: "wk", detail: "Weekly limit" },
  month: { label: "Month", short: "mo", detail: "Monthly limit" },
  day: { label: "Day", short: "day", detail: "Daily limit" },
  other: { label: "Allowance", short: "use", detail: "Usage limit" }
}

function windows(report, warnPercent, criticalPercent) {
  if (!report || !report.weekly) return []
  var w = report.weekly
  var def = PERIOD_DEFS[report.period] || PERIOD_DEFS.other
  return [{
    key: "weekly",
    label: def.label,
    short: def.short,
    detail: def.detail,
    percent: w.expired ? 0 : percent(w.percent),
    resetsAt: w.resetsAt,
    expired: w.expired === true,
    state: w.expired ? "normal" : stateOf(w.percent, warnPercent, criticalPercent)
  }]
}

function filterWindows(list, visible) {
  if (!Array.isArray(list)) return []
  var out = []
  for (var i = 0; i < list.length; i++) {
    if (visible[list[i].key] !== false) out.push(list[i])
  }
  return out
}

function stateOf(value, warnPercent, criticalPercent) {
  var p = percent(value)
  if (p >= criticalPercent) return "critical"
  if (p >= warnPercent) return "warning"
  return "normal"
}

function highest(list) {
  if (!Array.isArray(list) || list.length === 0) return null
  var best = list[0]
  for (var i = 1; i < list.length; i++) {
    if (list[i].percent > best.percent) best = list[i]
  }
  return best
}

function percentText(value) {
  var p = percent(value)
  var rounded = Math.round(p * 10) / 10
  return (rounded % 1 === 0 ? String(Math.round(rounded)) : rounded.toFixed(1)) + "%"
}

function resetText(resetsAt, now) {
  var target = number(resetsAt) || 0
  if (target <= 0) return ""
  var diff = target - now
  if (diff <= 0) return "New period"
  var minutes = Math.floor(diff / 60000)
  var days = Math.floor(minutes / 1440)
  var hours = Math.floor((minutes % 1440) / 60)
  var mins = minutes % 60
  if (days >= 1) return "Resets in " + days + "d " + hours + "h"
  if (hours >= 1) return "Resets in " + hours + "h " + mins + "m"
  return "Resets in " + Math.max(1, mins) + "m"
}

function tooltip(list, now) {
  if (!Array.isArray(list) || list.length === 0) return "Grok usage"
  var lines = []
  for (var i = 0; i < list.length; i++) {
    var w = list[i]
    var line = "Grok " + w.detail.toLowerCase() + ": "
    line += w.expired ? "period ended" : percentText(w.percent)
    lines.push(line)
    var reset = resetText(w.resetsAt, now)
    if (reset !== "") lines.push("  " + reset)
  }
  return lines.join("\n")
}

function compactText(list) {
  if (!Array.isArray(list) || list.length === 0) return ""
  var parts = []
  for (var i = 0; i < list.length; i++) {
    parts.push(list[i].short + " " + (list[i].expired ? "—" : percentText(list[i].percent)))
  }
  return parts.join(" · ")
}

function updatedText(lastFetchMs, now) {
  var last = number(lastFetchMs) || 0
  if (last <= 0) return ""
  var seconds = Math.max(0, Math.floor((now - last) / 1000))
  if (seconds < 5) return "Checked just now"
  if (seconds < 60) return "Checked " + seconds + "s ago"
  var minutes = Math.floor(seconds / 60)
  if (minutes < 60) return "Checked " + minutes + "m ago"
  var hours = Math.floor(minutes / 60)
  return "Checked " + hours + "h ago"
}

// Age of the bill snapshot itself, which is separate from when this widget
// last read the file.
function snapshotText(snapshotAt, now) {
  var at = number(snapshotAt) || 0
  if (at <= 0) return "No snapshot time"
  var seconds = Math.max(0, Math.floor((now - at) / 1000))
  if (seconds < 60) return "Snapshot just now"
  var minutes = Math.floor(seconds / 60)
  if (minutes < 60) return "Snapshot " + minutes + "m old"
  var hours = Math.floor(minutes / 60)
  if (hours < 48) return "Snapshot " + hours + "h old"
  return "Snapshot " + Math.floor(hours / 24) + "d old"
}

function formatCount(value) {
  var n = number(value)
  if (n === null) return "—"
  if (n >= 1000000000) return (n / 1000000000).toFixed(1) + "B"
  if (n >= 1000000) return (n / 1000000).toFixed(1) + "M"
  if (n >= 1000) return (n / 1000).toFixed(0) + "K"
  return String(Math.round(n))
}

function formatCost(value) {
  var n = number(value)
  if (n === null || n < 0) return "—"
  if (n > 0 && n < 0.01) return "<$0.01"
  return "$" + n.toFixed(2)
}

// Token counts and cost are formatted without a currency unit for on-demand
// amounts because Grok's config exposes plain values without naming the unit.
function formatAmount(value) {
  var n = number(value)
  if (n === null) return "—"
  if (n >= 1000) return formatCount(n)
  return n.toFixed(n % 1 === 0 ? 0 : 2)
}

function shellQuote(value) {
  var s = String(value || "")
  return "'" + s.replace(/'/g, "'\\''") + "'"
}

// ------------------------------------------------------------ local cache
//
// A shell restart creates a fresh QML engine, so nothing survives in memory.
// The disk cache keeps the last successful read and the last attempt time so a
// fresh start paints immediately and waits out the rest of the interval.

var CACHE_VERSION = 1
var AUTO_MIN_MS = 60000
var FORCE_MIN_MS = 30000
var FAILURE_CAP_MS = 600000

function slimReport(report) {
  if (!report) return null
  return {
    source: text(report.source, 40),
    logPath: text(report.logPath, 400),
    snapshotAt: number(report.snapshotAt) || 0,
    tier: text(report.tier, 60),
    unified: report.unified === true,
    periodType: text(report.periodType, 60),
    weekly: report.weekly ? {
      percent: percent(report.weekly.percent),
      periodStart: number(report.weekly.periodStart) || 0,
      resetsAt: number(report.weekly.resetsAt) || 0,
      expired: report.weekly.expired === true
    } : null,
    onDemand: report.onDemand ? {
      cap: number(report.onDemand.cap) || 0,
      used: number(report.onDemand.used) || 0,
      prepaid: number(report.onDemand.prepaid) || 0
    } : null,
    local: report.local ? {
      sessions: number(report.local.sessions) || 0,
      turns: number(report.local.turns) || 0,
      tokens: number(report.local.tokens) || 0,
      input: number(report.local.input) || 0,
      output: number(report.local.output) || 0,
      cached: number(report.local.cached) || 0,
      reasoning: number(report.local.reasoning) || 0,
      costUsd: number(report.local.costUsd) || 0,
      since: number(report.local.since) || 0
    } : null
  }
}

function serializeCache(report, fetchedAt, attemptedAt, failures, error) {
  var cache = {
    version: CACHE_VERSION,
    fetchedAt: Math.max(0, Math.round(number(fetchedAt) || 0)),
    attemptedAt: Math.max(0, Math.round(number(attemptedAt) || 0)),
    failures: Math.round(clamp(number(failures) || 0, 0, 20)),
    error: text(error, 240),
    data: slimReport(report)
  }
  return JSON.stringify(cache) + "\n"
}

function parseCache(raw, nowMs) {
  var obj = parseJson(raw)
  if (!obj || obj.version !== CACHE_VERSION) return null

  var now = number(nowMs) || Date.now()
  var fetchedAt = number(obj.fetchedAt) || 0
  var attemptedAt = number(obj.attemptedAt) || 0
  if (fetchedAt > now + 300000) fetchedAt = 0
  if (attemptedAt > now + 300000) attemptedAt = 0
  if (fetchedAt < 0) fetchedAt = 0
  if (attemptedAt < 0) attemptedAt = 0

  // Re-run the same validation the live helper output uses.
  var report = null
  var data = obj.data && typeof obj.data === "object" ? obj.data : null
  if (data !== null) {
    var parsed = parseResult(JSON.stringify({
      ok: true,
      source: data.source,
      logPath: data.logPath,
      snapshotAt: data.snapshotAt,
      tier: data.tier,
      unified: data.unified,
      weekly: data.weekly ? {
        usedPercent: data.weekly.percent,
        periodType: data.periodType,
        periodStart: data.weekly.periodStart,
        resetsAt: data.weekly.resetsAt,
        expired: data.weekly.expired
      } : null,
      onDemand: data.onDemand,
      local: data.local
    }))
    if (parsed && parsed.ok) report = parsed.report
  }

  return {
    fetchedAt: fetchedAt,
    attemptedAt: attemptedAt,
    failures: Math.round(clamp(number(obj.failures) || 0, 0, 20)),
    error: text(obj.error, 240),
    report: report
  }
}

function autoDelayMs(fetchedAt, attemptedAt, failures, refreshMs, nowMs) {
  var now = number(nowMs) || Date.now()
  var interval = Math.max(AUTO_MIN_MS, number(refreshMs) || 300000)
  var last = number(fetchedAt) || 0
  var attempt = number(attemptedAt) || 0
  var fails = Math.max(0, Math.round(number(failures) || 0))
  var delay = 0

  if (last > 0) delay = Math.max(delay, last + interval - now)
  if (attempt > 0) {
    var cooldown = AUTO_MIN_MS
    if (fails > 0) cooldown = Math.min(FAILURE_CAP_MS, AUTO_MIN_MS * Math.pow(2, Math.min(fails - 1, 4)))
    delay = Math.max(delay, attempt + cooldown - now)
  }
  return Math.max(0, delay)
}

// --------------------------------------------------------- poll coordination
//
// One QML engine per monitor, one .pragma library per engine. One instance
// (the leader) owns the read loop; the others consume its published result.
// Leadership is heartbeat-based so a destroyed leader is replaced.

var pollState = {
  leader: null,
  beat: 0,
  seq: 0,
  report: null,
  fetchedAt: 0,
  attemptedAt: 0,
  failures: 0,
  error: "",
  errorText: ""
}

function pollClaim(widget, nowMs) {
  if (pollState.leader === widget) {
    pollState.beat = nowMs
    return true
  }
  if (pollState.leader === null || nowMs - pollState.beat > 20000) {
    pollState.leader = widget
    pollState.beat = nowMs
    return true
  }
  return false
}

function pollRelease(widget) {
  if (pollState.leader === widget) pollState.leader = null
}

function pollPublish(widget, result) {
  if (pollState.leader !== widget) return
  pollState.report = result.report || null
  pollState.fetchedAt = number(result.fetchedAt) || 0
  pollState.attemptedAt = number(result.attemptedAt) || 0
  pollState.failures = Math.round(number(result.failures) || 0)
  pollState.error = text(result.error, 240)
  pollState.errorText = text(result.errorText, 300)
  pollState.beat = Date.now()
  pollState.seq++
}

function pollConsume(widget) {
  if (pollState.leader === widget) return null
  return {
    seq: pollState.seq,
    report: pollState.report,
    fetchedAt: pollState.fetchedAt,
    attemptedAt: pollState.attemptedAt,
    failures: pollState.failures,
    error: pollState.error,
    errorText: pollState.errorText
  }
}

function pollLeaderInstance() {
  return pollState.leader
}

function pollSeed(fetchedAt, attemptedAt, failures) {
  var last = number(fetchedAt) || 0
  var attempt = number(attemptedAt) || 0
  var fails = Math.round(number(failures) || 0)
  if (last > pollState.fetchedAt) pollState.fetchedAt = last
  if (attempt > pollState.attemptedAt) pollState.attemptedAt = attempt
  if (fails > pollState.failures) pollState.failures = fails
}
