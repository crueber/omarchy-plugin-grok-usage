# Changelog

## Unreleased

- Add an offline `demo/grok-home` fixture, a capture script for the README and
  marketplace images, and use the fixture in `scripts/test-model.js` so CI no
  longer needs a real Grok install.
- README: add the standard `omarchy plugin add` install path and the CI badge;
  note the cache directory mode and the no-network/no-token guarantees.
- Replace `preview.png` and `screenshots/bar.png` with anonymised captures of
  the real widget running on the fixture.

## 1.0.0 — 2026-11-06

- Initial widget: official Grok mark in the bar, weekly plan meter, and a popup
  with percentage, reset countdown and clock, plan tier, billing amounts, and
  local session activity.
- Reads the billing snapshot Grok writes to `~/.grok/logs/unified.jsonl`; no
  API key, network request, or auth token.
- Disk cache, 5-minute default refresh, 60-second automatic floor, 30-second
  manual floor, failure backoff, and leader election.
