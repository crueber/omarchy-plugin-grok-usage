#!/usr/bin/env node
'use strict'

// Round-trip Model.js against a real collect.js payload. No network, no QML.

const assert = require('assert')
const { execFileSync } = require('child_process')
const fs = require('fs')
const path = require('path')
const vm = require('vm')

const repo = path.resolve(__dirname, '..')
const source = fs.readFileSync(path.join(repo, 'Model.js'), 'utf8')
  .replace(/^\.pragma library\s*$/m, '')
const context = { console, Date, JSON, Math, String, Number, Array, Object, isFinite }
vm.createContext(context)
vm.runInContext(source, context)

const raw = execFileSync(process.execPath, [path.join(repo, 'scripts', 'collect.js')], {
  encoding: 'utf8'
})

const parsed = context.parseResult(raw)
assert.ok(parsed, 'parseResult should accept the helper output')
assert.ok(parsed.ok, 'helper should report ok on this machine (run Grok once first)')
assert.ok(parsed.report.weekly, 'weekly window present')
assert.ok(parsed.report.weekly.resetsAt > 0, 'reset timestamp present')
assert.ok(parsed.report.weekly.percent >= 0 && parsed.report.weekly.percent <= 100, 'percent bounded')
assert.ok(parsed.report.tier.length > 0, 'tier present')

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
const now = Date.now()
assert.ok(context.autoDelayMs(now, now, 0, 300000, now) > 290000)
assert.ok(context.autoDelayMs(0, now, 0, 300000, now) > 55000)
assert.ok(context.autoDelayMs(0, now, 3, 300000, now) > 200000)

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
expired.weekly.resetsAt = now - 1000
expired.weekly.expired = true
const expiredParsed = context.parseResult(JSON.stringify(expired))
const expiredWindows = context.windows(expiredParsed.report, 70, 90)
assert.equal(expiredWindows[0].expired, true)
assert.equal(expiredWindows[0].percent, 0)
assert.equal(context.compactText(expiredWindows), 'wk —')

console.log('ok — weekly ' + text + ', ' + parsed.report.tier
  + ', local ' + (parsed.report.local ? parsed.report.local.tokens : 0) + ' tokens')
