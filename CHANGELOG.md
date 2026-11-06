# Changelog

## 1.0.0 — 2026-11-06

- Initial widget: official Grok mark in the bar, weekly plan meter, and a popup
  with percentage, reset countdown and clock, plan tier, billing amounts, and
  local session activity.
- Reads the billing snapshot Grok writes to `~/.grok/logs/unified.jsonl`; no
  API key, network request, or auth token.
- Disk cache, 5-minute default refresh, 60-second automatic floor, 30-second
  manual floor, failure backoff, and leader election.
