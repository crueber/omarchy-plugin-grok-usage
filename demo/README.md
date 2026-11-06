# Demo fixture and screenshot capture

The preview image is a capture of the real widget filled with **invented**
data. `demo/grok-home` is a miniature Grok home that the widget reads exactly
as it reads `~/.grok`: one billing snapshot line and two numeric session
ledgers. No real account, workspace, prompt, token total, or path is involved.

- `grok-home/logs/unified.jsonl` — three log lines, one of them a
  `billing: fetched credits config` snapshot: weekly 41 %, tier `SuperGrok`.
- `grok-home/sessions/demo-workspace/demo-session-{a,b}/usage.json` — four
  invented turns with token and cost numbers only.
- `grok-bot-home/usage.blob` — the Grok Bot desktop app's cached `bot.usage`
  shape with an invented 42.7 % weekly reading and its own reset.

`capture-preview.sh` copies the fixture to a temp directory and moves the
billing period and turn timestamps around "now" so the countdown, reset clock,
and local-activity window are always live. It then points the widget's
`grokHome` setting at that copy, captures the bar and popup, composes a clean
`preview.png` plus `screenshots/bar.png`, runs the anonymisation check, and
restores everything on every exit path.

## Why a fixture instead of redaction

The widget already accepts a Grok home through `grokHome`, and its helper takes
`--home`. Pointing it at an invented home exercises the real `collect.js`,
`Model.js`, and QML, so the screenshot shows the shipping code without any
demo branch in the runtime and without touching `~/.grok`.

## Run it

```bash
demo/capture-preview.sh --help

# Normal capture. The sibling OpenCode widget sits next to this one, so hide it
# for the shot:
demo/capture-preview.sh --hide crueber.opencode-usage

# If the widget does not pick up the fixture after a rescan, allow one restart:
demo/capture-preview.sh --hide crueber.opencode-usage --allow-restart
```

Needs `grim`, ImageMagick (`magick`), `tesseract`, `jq`, and the Omarchy CLI.
The script opens and closes the popup once and takes a few seconds.

On a 1× monitor the popup renders small; raise the scale for one capture and
put it back afterwards:

```bash
omarchy hyprland monitor scaling 2
demo/capture-preview.sh --hide crueber.opencode-usage --allow-restart
omarchy hyprland monitor scaling 1
```

## What it changes, and what it puts back

| Touched | Backup | Restore |
| --- | --- | --- |
| `~/.config/omarchy/shell.json` widget entry | `backup/entry.json` in a private `mktemp -d` work dir | the changed keys (`grokHome`, `botHome`, `showLocalStats`) via `omarchy bar set` |
| `~/.cache/grok-usage/usage.json` | `backup/usage.json` | byte-for-byte copy back, or removed if there was none |
| Widgets passed with `--hide` | recorded in `hidden_ids` | re-enabled with `omarchy-shell shell setPluginEnabled <id> true`, keeping their bar slot |

The work directory is created with `mktemp -d` (mode `0700`, unpredictable
name) and backups inside it are mode `0600`; no full `shell.json` copy is
written. The optional `GROK_USAGE_CAPTURE_DIR` override is accepted only when
it is a real directory owned by the current user and inaccessible to
group/other.

A `trap` runs the restore on success, failure, Ctrl-C, and `SIGTERM`. A
successful run removes its temporary directory; a failed one keeps the private
backups for diagnosis and drops the raw shots. `--keep-raw` keeps everything in
both cases.

## Quality gate

`capture-preview.sh` runs OCR on the result and **fails** if it finds
`crueber`, any e-mail address, the previous real numbers (`33%`, `$6.18`,
`29.2M`, `258K`, `28.4M`), an old reset clock, or an account id prefix. It also
requires the demo tier, the `Weekly limit` label, and `41%` to be readable,
checks that the preview carries no EXIF data, and confirms the cache held the
fixture report.

`scripts/test-model.js` uses the same fixture (with fresh dates) in CI, so the
test suite never needs a real Grok install.
