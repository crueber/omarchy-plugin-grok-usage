#!/usr/bin/env node
'use strict'

// Read the plan snapshot Grok already fetched and printed to its unified log.
//
// Grok's TUI asks its background service for billing/credits when a session
// starts. The shell logs the response as `billing: fetched credits config`.
// That line contains the weekly usage percentage, the billing period, the
// plan tier, and on-demand/prepaid amounts. Reading it needs no token, no
// network request, and no Grok process of our own.
//
// Local session ledgers (sessions/<workspace>/<session>/usage.json) give
// per-turn tokens and Grok's own cost ticks. Only numbers are read; prompts,
// responses, and auth.json are never opened.
//
// Output is one JSON object. It always exits 0 for expected "no snapshot"
// conditions so the widget can show the reason; unexpected errors still exit
// 0 with { ok: false, error } to keep the caller's parsing simple.

const fs = require('fs')
const path = require('path')

const DAY_MS = 86400000
const MAX_LOG_SCAN = 32 * 1024 * 1024
const CHUNK = 256 * 1024

function argValue(name) {
  const i = process.argv.indexOf(name)
  if (i < 0) return ''
  return process.argv[i + 1] || ''
}

function homeDir() {
  const explicit = argValue('--home')
  if (explicit) return explicit
  const env = process.env.GROK_HOME || ''
  if (env) return env
  const home = process.env.HOME || ''
  return home ? path.join(home, '.grok') : ''
}

function text(value, max) {
  if (typeof value !== 'string') return ''
  return value.slice(0, max || 240)
}

function num(value) {
  const n = typeof value === 'number' ? value : Number(value)
  return Number.isFinite(n) ? n : null
}

function fail(message) {
  process.stdout.write(JSON.stringify({ ok: false, error: text(message, 300) }) + '\n')
  process.exit(0)
}

// Scan backwards in chunks and return the last billing snapshot line. The log
// can be large, so avoid reading it whole: billing lines are frequent, and
// 32 MB of tail is far more than enough to find the latest one.
function lastBillingMessage(logPath) {
  let fd
  try {
    fd = fs.openSync(logPath, 'r')
  } catch (e) {
    return { message: null, error: 'no Grok log at ' + logPath }
  }

  try {
    const size = fs.fstatSync(fd).size
    let end = size
    let carry = ''
    let scanned = 0

    while (end > 0 && scanned < MAX_LOG_SCAN) {
      const start = Math.max(0, end - CHUNK)
      const len = end - start
      const buf = Buffer.allocUnsafe(len)
      fs.readSync(fd, buf, 0, len, start)

      const lines = (buf.toString('utf8') + carry).split('\n')
      if (start > 0) carry = lines.shift() || ''

      for (let i = lines.length - 1; i >= 0; i--) {
        const line = lines[i]
        if (line.indexOf('billing: fetched credits config') < 0) continue
        try {
          const row = JSON.parse(line)
          if (row && row.msg === 'billing: fetched credits config') {
            return { message: row, error: '' }
          }
        } catch (e) {
          // A torn write can leave a partial line; keep looking backwards.
        }
      }

      scanned += len
      end = start
    }
  } finally {
    try { fs.closeSync(fd) } catch (e) {}
  }

  return { message: null, error: 'no billing snapshot in the Grok log yet' }
}

function parseConfig(message) {
  const ctx = message && message.ctx && typeof message.ctx === 'object' ? message.ctx : null
  const config = ctx && ctx.config && typeof ctx.config === 'object' ? ctx.config : null
  if (!config) return null

  const used = num(config.creditUsagePercent)
  const period = config.currentPeriod && typeof config.currentPeriod === 'object'
    ? config.currentPeriod : null
  if (!period) return null
  // The server omits creditUsagePercent at the start of a fresh period; the
  // TUI renders that as 0%, so treat an absent value as zero rather than
  // discarding the new snapshot.
  const usedPercent = used === null ? 0 : used

  const startMs = Date.parse(period.start || '')
  const endMs = Date.parse(period.end || '')
  if (!Number.isFinite(endMs)) return null

  const amount = function(value) {
    if (value && typeof value === 'object' && num(value.val) !== null) return num(value.val)
    return num(value)
  }

  const now = Date.now()
  return {
    tier: text(ctx.subscriptionTier, 60),
    unified: config.isUnifiedBillingUser === true,
    snapshotAt: Math.max(0, Date.parse(message.ts || '') || 0),
    weekly: {
      usedPercent: Math.max(0, Math.min(100, usedPercent)),
      periodType: text(period.type, 60),
      periodStart: Number.isFinite(startMs) ? startMs : 0,
      resetsAt: endMs,
      expired: now >= endMs
    },
    onDemand: {
      cap: Math.max(0, amount(config.onDemandCap) || 0),
      used: Math.max(0, amount(config.onDemandUsed) || 0),
      prepaid: Math.max(0, amount(config.prepaidBalance) || 0)
    }
  }
}

function walkSessionUsage(root, sinceMs) {
  const totals = {
    sessions: 0,
    turns: 0,
    tokens: 0,
    input: 0,
    output: 0,
    cached: 0,
    reasoning: 0,
    costUsd: 0,
    since: new Date(sinceMs).toISOString()
  }

  let workspaces
  try {
    workspaces = fs.readdirSync(root, { withFileTypes: true })
  } catch (e) {
    return null
  }

  const cutoff = sinceMs - DAY_MS
  for (const workspace of workspaces) {
    if (!workspace.isDirectory()) continue
    const workspaceDir = path.join(root, workspace.name)
    let sessions
    try {
      sessions = fs.readdirSync(workspaceDir, { withFileTypes: true })
    } catch (e) {
      continue
    }

    for (const session of sessions) {
      if (!session.isDirectory()) continue
      const usagePath = path.join(workspaceDir, session.name, 'usage.json')
      let stat
      try {
        stat = fs.statSync(usagePath)
      } catch (e) {
        continue
      }
      if (stat.mtimeMs < cutoff) continue

      let doc
      try {
        doc = JSON.parse(fs.readFileSync(usagePath, 'utf8'))
      } catch (e) {
        continue
      }

      const turns = Array.isArray(doc.turns) ? doc.turns : []
      let matched = false
      let countedTurn = false

      for (const turn of turns) {
        if (!turn || typeof turn !== 'object') continue
        const ended = Date.parse(turn.endedAt || '')
        if (Number.isFinite(ended) && ended < sinceMs) continue
        matched = true
        countedTurn = true
        totals.turns += Math.max(1, num(turn.turnCount) || 1)
        totals.tokens += Math.max(0, num(turn.totalTokens) || 0)
        totals.input += Math.max(0, num(turn.inputTokens) || 0)
        totals.output += Math.max(0, num(turn.outputTokens) || 0)
        totals.cached += Math.max(0, num(turn.cachedReadTokens) || 0)
        totals.reasoning += Math.max(0, num(turn.reasoningTokens) || 0)
        totals.costUsd += Math.max(0, num(turn.costUsdTicks) || 0) / 1e10
      }

      if (!countedTurn) {
        // Older ledgers have no turns array. Fall back to the session total
        // only when the session itself was updated inside the period.
        const updated = Date.parse(doc.updatedAt || '')
        if (!Number.isFinite(updated) || updated < sinceMs) continue
        const sessionUsage = doc.session && typeof doc.session === 'object' ? doc.session : null
        if (!sessionUsage) continue
        matched = true
        totals.turns += Math.max(0, num(sessionUsage.turnCount) || 0)
        totals.tokens += Math.max(0, num(sessionUsage.totalTokens) || 0)
        totals.input += Math.max(0, num(sessionUsage.inputTokens) || 0)
        totals.output += Math.max(0, num(sessionUsage.outputTokens) || 0)
        totals.cached += Math.max(0, num(sessionUsage.cachedReadTokens) || 0)
        totals.reasoning += Math.max(0, num(sessionUsage.reasoningTokens) || 0)
        totals.costUsd += Math.max(0, num(sessionUsage.costUsdTicks) || 0) / 1e10
      }

      if (matched) totals.sessions++
    }
  }

  totals.costUsd = Math.round(totals.costUsd * 10000) / 10000
  return totals
}

function main() {
  const grokHome = homeDir()
  if (!grokHome) fail('HOME is not set')

  const logPath = path.join(grokHome, 'logs', 'unified.jsonl')
  const found = lastBillingMessage(logPath)
  if (!found.message) fail(found.error)

  const config = parseConfig(found.message)
  if (!config) fail('the latest billing line has no recognizable config')

  const since = config.weekly.periodStart > 0
    ? config.weekly.periodStart
    : Date.now() - 7 * DAY_MS
  const local = walkSessionUsage(path.join(grokHome, 'sessions'), since)

  const out = {
    ok: true,
    source: 'grok-log',
    logPath: logPath,
    snapshotAt: config.snapshotAt,
    tier: config.tier,
    unified: config.unified,
    weekly: config.weekly,
    onDemand: config.onDemand,
    local: local
  }

  process.stdout.write(JSON.stringify(out) + '\n')
}

try {
  main()
} catch (e) {
  fail(e && e.message ? e.message : 'could not read the Grok log')
}
