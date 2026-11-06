# Changelog

## 1.0.1 — 2026-11-06

- Treat a missing `creditUsagePercent` as 0% when a new weekly period starts.
  Grok omits the field until the first call of the period; the widget used to
  keep the expired snapshot and show `wk —` instead of the fresh 0%.

## 1.0.0 — 2026-11-06

- Initial widget: official Grok mark in the bar, weekly plan meter, and a popup
  with percentage, reset countdown and clock, plan tier, billing amounts, and
  local session activity.
- Reads the billing snapshot Grok writes to `~/.grok/logs/unified.jsonl`; no
  API key, network request, or auth token.
- Disk cache, 5-minute default refresh, 60-second automatic floor, 30-second
  manual floor, failure backoff, and leader election.
- Offline `demo/grok-home` fixture and capture script for the README and
  marketplace images; CI uses the fixture instead of a real Grok install.
- README: standard `omarchy plugin add` install path, CI badge, cache mode, and
  the no-network/no-token guarantees.
