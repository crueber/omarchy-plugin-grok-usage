#!/usr/bin/env node
'use strict'

// Round-trip Model.js against the offline demo fixture. No network, no QML, and
// no real ~/.grok: `demo/grok-home` is copied to a temp dir whose billing
// period is moved around "now" so the fixture never expires in CI.

const assert = require('assert')
const { execFileSync } = require('child_process')
const fs = require('fs')
const os = require('os')
const path = require('path')
const vm = require('vm')

const repo = path.resolve(__dirname, '..')
const DAY_MS = 86400000
const fixture = path.join(repo, 'demo', 'grok-home')
const home = fs.mkdtempSync(path.join(os.tmpdir(), 'grok-home-'))

const iso = function(ms) { return new Date(ms).toISOString() }
const now = Date.now()
const periodStart = iso(now - 4 * DAY_MS)
const periodEnd = iso(now + 3 * DAY_MS + 2 * 3600000)
const turnAt = iso(now - DAY_MS)

function stageFixture() {
  fs.cpSync(fixture, home, { recursive: true })

  const logPath = path.join(home, 'logs', 'unified.jsonl')
  const lines = fs.readFileSync(logPath, 'utf8').trim().split('\n').map(function(line) {
    const row = JSON.parse(line)
    if (row.msg === 'billing: fetched credits config') {
      row.ts = iso(now)
      row.ctx.config.currentPeriod.start = periodStart
      row.ctx.config.currentPeriod.end = periodEnd
    }
    return JSON.stringify(row)
  })
  fs.writeFileSync(logPath, lines.join('\n') + '\n')

  const sessions = path.join(home, 'sessions', 'demo-workspace')
  for (const name of fs.readdirSync(sessions)) {
    const usagePath = path.join(sessions, name, 'usage.json')
    if (!fs.existsSync(usagePath)) continue
    const doc = JSON.parse(fs.readFileSync(usagePath, 'utf8'))
    doc.updatedAt = iso(now - DAY_MS)
    for (const turn of doc.turns || []) turn.endedAt = turnAt
    fs.writeFileSync(usagePath, JSON.stringify(doc, null, 2) + '\n')
  }
}

function cleanup() {
  fs.rmSync(home, { recursive: true, force: true })
}

let raw
try {
  stageFixture()
  raw = execFileSync(process.execPath, [
    path.join(repo, 'scripts', 'collect.js'),
    '--home', home
  ], { encoding: 'utf8' })
} finally {
  cleanup()
}

const source = fs.readFileSync(path.join(repo, 'Model.js'), 'utf8')
  .replace(/^\.pragma library\s*$/m, '')
const context = { console, Date, JSON, Math, String, Number, Array, Object, isFinite }
vm.createContext(context)
vm.runInContext(source, context)

const parsed = context.parseResult(raw)
assert.ok(parsed, 'parseResult should accept the helper output')
assert.ok(parsed.ok, 'helper should report ok for the offline fixture')
assert.ok(parsed.report.weekly, 'weekly window present')
assert.ok(parsed.report.weekly.resetsAt > 0, 'reset timestamp present')
assert.ok(parsed.report.weekly.percent >= 0 && parsed.report.weekly.percent <= 100, 'percent bounded')
assert.equal(parsed.report.weekly.percent, 41, 'fixture percentage')
assert.equal(parsed.report.tier, 'SuperGrok', 'fixture tier')
assert.ok(parsed.report.logPath.indexOf(home) === 0, 'read only the fixture home')
assert.equal(parsed.report.local.sessions, 2, 'fixture sessions')
assert.equal(parsed.report.local.turns, 4, 'fixture turns')
assert.ok(Math.abs(parsed.report.local.costUsd - 2.52) < 0.0001, 'fixture cost')

// A fresh period can omit creditUsagePercent entirely. The TUI shows that as
// 0%, and the widget must keep the new snapshot instead of showing "—".
const zeroHome = fs.mkdtempSync(path.join(os.tmpdir(), 'grok-home-zero-'))
try {
  fs.cpSync(fixture, zeroHome, { recursive: true })
  const zeroLog = path.join(zeroHome, 'logs', 'unified.jsonl')
  const zeroLines = fs.readFileSync(zeroLog, 'utf8').trim().split('\n').map(function(line) {
    const row = JSON.parse(line)
    if (row.msg === 'billing: fetched credits config') {
      row.ts = iso(now)
      row.ctx.config.currentPeriod.start = periodStart
      row.ctx.config.currentPeriod.end = periodEnd
      delete row.ctx.config.creditUsagePercent
    }
    return JSON.stringify(row)
  })
  fs.writeFileSync(zeroLog, zeroLines.join('\n') + '\n')
  const zeroRaw = execFileSync(process.execPath, [
    path.join(repo, 'scripts', 'collect.js'),
    '--home', zeroHome
  ], { encoding: 'utf8' })
  const zero = context.parseResult(zeroRaw)
  assert.ok(zero && zero.ok, 'zero-usage snapshot should parse')
  assert.equal(zero.report.weekly.percent, 0, 'missing creditUsagePercent means 0%')
} finally {
  fs.rmSync(zeroHome, { recursive: true, force: true })
}

const windows = context.windows(parsed.report, 70, 90)
assert.equal(windows.length, 1)
assert.equal(windows[0].key, 'weekly')
assert.ok(windows[0].detail === 'Weekly limit')

const text = context.percentText(parsed.report.weekly.percent)
assert.ok(/^\d+(\.\d)?%$/.test(text), 'percent formatting: ' + text)
assert.ok(context.resetText(parsed.report.weekly.resetsAt, Date.now()).length > 0)
assert.ok(context.tooltip(windows, Date.now()).indexOf('weekly limit') >= 0)
assert.ok(context.compactText(windows).indexOf('wk ') === 0)

const cacheRaw = context.serializeCache(
  parsed.report,
  Date.now(),
  Date.now(),
  0,
  ''
)
const cache = context.parseCache(cacheRaw, Date.now())
assert.ok(cache, 'cache parses')
assert.ok(cache.report, 'cache keeps the report')
assert.equal(cache.report.weekly.percent, parsed.report.weekly.percent)
assert.equal(cache.report.tier, parsed.report.tier)
assert.equal(cache.report.local.since, parsed.report.local.since)
assert.equal(cache.report.local.tokens, parsed.report.local.tokens)

// Cooldown floors: a fresh success waits the 5-minute interval, a fresh manual
// attempt waits 30 seconds, and failures grow towards the 10-minute cap.
const nowMs = Date.now()
assert.ok(context.autoDelayMs(nowMs, nowMs, 0, 300000, nowMs) > 290000)
assert.ok(context.autoDelayMs(0, nowMs, 0, 300000, nowMs) > 55000)
assert.ok(context.autoDelayMs(0, nowMs, 3, 300000, nowMs) > 200000)

// The label follows the snapshot's period type rather than assuming weekly.
const monthly = JSON.parse(raw)
monthly.weekly.periodType = 'USAGE_PERIOD_TYPE_MONTHLY'
const monthlyParsed = context.parseResult(JSON.stringify(monthly))
assert.equal(monthlyParsed.report.period, 'month')
assert.equal(context.windows(monthlyParsed.report, 70, 90)[0].detail, 'Monthly limit')
assert.equal(context.periodName(monthlyParsed.report.period), 'Monthly')
assert.equal(context.periodLocal(monthlyParsed.report.period), 'this month')

// A stale cache from an expired period must not reuse the old percentage.
const expired = JSON.parse(raw)
expired.weekly.resetsAt = nowMs - 1000
expired.weekly.expired = true
const expiredParsed = context.parseResult(JSON.stringify(expired))
const expiredWindows = context.windows(expiredParsed.report, 70, 90)
assert.equal(expiredWindows[0].expired, true)
assert.equal(expiredWindows[0].percent, 0)
assert.equal(context.compactText(expiredWindows), 'wk —')

console.log('ok — weekly ' + text + ', ' + parsed.report.tier
  + ', local ' + parsed.report.local.tokens + ' tokens')
