# AGENTS.md

Grok Usage — an Omarchy shell bar widget for a SuperGrok plan's weekly limit,
its reset clock, and local Grok session activity.

## Layout

- `manifest.json` — plugin id, bar-widget entry point, settings schema.
- `Panel.qml` — bar widget and popup; owns lifecycle, reading, and cache wiring.
- `GrokMark.qml` — the official Grok mark drawn from the app icon's path data.
- `Model.js` — pure parsing, formatting, cache, and poll-coordination helpers.
- `scripts/collect.js` — Node helper that reads the latest billing snapshot and
  local session ledgers and prints one JSON object.
- `preview.png`, `screenshots/bar.png` — README images.
- `scripts/install.sh` — deploy to the live plugin directory.
- `scripts/validate.sh` — manifest + required-file check.
- `scripts/test-model.js` — Node round-trip test for `Model.js`.

## Source and deploy

- Source of truth: this repository.
- Live copy: `~/.config/omarchy/plugins/crueber.grok-usage/`.
- Deploy with `./scripts/install.sh`; it copies the runtime files, validates the
  manifest, and rescans plugins. It does **not** enable the widget.
- Do **not** put a `.git` directory inside the live plugin folder. Quickshell
  watches that tree and a git checkout can trigger reload races.
- There is no public push target yet; keep this local for review.

## Data source (important)

Grok's TUI asks its background service for billing data when a session starts.
The shell writes the response to `~/.grok/logs/unified.jsonl` as:

```
"msg":"billing: fetched credits config"
"ctx":{"config":{"creditUsagePercent":33.0,"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY",...},
"onDemandCap":{"val":0},"onDemandUsed":{"val":0},"prepaidBalance":{"val":0},
"isUnifiedBillingUser":true,...},"subscriptionTier":"SuperGrok"}
```

That line is the source. It needs no token, no network request, and no new key.
`scripts/collect.js` scans backwards from the end of the log for the newest such
line, then sums numeric per-turn ledgers under
`~/.grok/sessions/<workspace>/<session>/usage.json` for the current period.

`grok usage` (no session id) is the documented plan path, but only on Grok's
"daemon route"; on the normal local shell route it exits 1 and says to run
`/usage` in the TUI. Do not depend on it. `grok usage <session-id>` does work
for session totals, but the widget reads the ledger directly so one helper
call covers plan and local activity.

## Invariants

1. **No secrets.** Never read, print, or copy `~/.grok/auth.json`. The widget
   reads only `logs/unified.jsonl` and numeric `usage.json` ledgers. It makes no
   network request.
2. **One read choke point.** Scheduled polls, panel opens, middle click, `r`,
   and IPC all go through `requestFetch()`. Do not spawn `collect.js` elsewhere;
   that bypasses the 60 s automatic / 30 s manual floors.
3. **Persistent cache.** `~/.cache/grok-usage/usage.json` stores the last
   success, last attempt (including failures), failure count, and error. The
   attempt time is written before a read so a restart mid-read is remembered.
   Keep the schema versioned and validate with `Model.parseCache`.
4. **One leader per engine.** `Model.js` is a `.pragma library`; `pollState` is
   shared by every monitor's widget instance. The elected leader reads and
   publishes by sequence number; followers consume. Leadership is heartbeat
   based, so a destroyed leader is replaced.
5. **Failed reads keep old data.** Do not clear `report` on a failed read. The
   popup shows the last numbers with a `read failed` note.
6. **Text safety.** Every dynamic string in a `Text` uses
   `textFormat: Text.PlainText`. Workspace names passed to Omarchy-owned
   components are sanitized by `Model.plain()`. URLs are restricted to
   `https://grok.com/`.
7. **Theme first.** Use `Style`/`Color` tokens; QML files use two-space
   indentation.
8. **Do not fabricate a new week.** When the stored period has ended, show `—`
   and "Period ended" instead of reusing the old percentage or inventing zero.

## Testing

- `./scripts/validate.sh` — manifest and file presence.
- `./scripts/test-model.js` — parse a real helper payload and round-trip the
  cache; no network.
- `node scripts/collect.js` — inspect the live JSON.
- `omarchy plugin validate ~/.config/omarchy/plugins/crueber.grok-usage`
- `omarchy-shell shell rescanPlugins` to load the plugin. Prefer rescan and
  logs over restarting the shell.
- IPC: `omarchy-shell grok-usage text`, `omarchy-shell grok-usage refresh`.
- Logs: `journalctl --user -t omarchy-shell --since "-2 min" | grep -i grok`.
- Cache checks: note `attemptedAt` in `~/.cache/grok-usage/usage.json`, restart
  the shell, and confirm it did not change.

## Notes

- Default refresh is 5 minutes. Keep the automatic floor at 60 seconds and the
  manual floor at 30 seconds.
- The log's `creditUsagePercent` is **used** percent, matching the TUI's
  `Weekly limit` bar, not remaining.
- `costUsdTicks` is 10^10 ticks per USD (`grok usage` documents this).
- Bump `manifest.json` `version` for user-visible changes.
