#!/usr/bin/env bash
# Capture anonymised documentation screenshots for this plugin.
#
# The widget's `grokHome` setting is pointed at a temp copy of demo/grok-home,
# an offline Grok home with invented billing and session data. The capture
# script backs up the widget's settings entry, its usage cache, and the enabled
# state of any widgets it hides, restores them on every exit path, and refuses
# to publish a preview that still contains real account data.
#
# Usage:
#   demo/capture-preview.sh [options]
#
#   --out DIR          write preview.png/screenshots/ here (default: repo root)
#   --hide ID          hide a bar widget during the capture (repeatable);
#                      use it to keep a neighbouring widget out of the shot
#   --accent HEX       popup border colour (default: the active theme accent)
#   --bar-height N     bar height in px (default: detect from the capture)
#   --bar-width N      fallback bar crop width when no active button is visible
#   --keep-raw         keep shots/ and backups for inspection
#   --allow-restart    permit one `omarchy restart shell` if the fixture does
#                      not load after a plugin rescan (avoid while other work
#                      is using the shell)
#   --no-restore       leave the fixture settings in place (debugging only)
#   -h, --help
#
# Requirements: omarchy, omarchy-shell, jq, grim, ImageMagick (magick),
# tesseract. Runs on the live session; the panel is opened and closed once.
set -euo pipefail
umask 077

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
plugin=crueber.grok-usage
demo_home="$repo_dir/demo/grok-home"
config_home=${XDG_CONFIG_HOME:-$HOME/.config}
cache_home=${XDG_CACHE_HOME:-$HOME/.cache}
shell_json="$config_home/omarchy/shell.json"
cache_file="$cache_home/grok-usage/usage.json"
work=""
work_auto=0
shots=""
backup=""

out=$repo_dir
accent_arg=""
bar_height_arg=0
bar_width=180
keep_raw=0
allow_restart=0
skip_restore=0
restored=0
backed_up=0
hidden_ids=()
hides=()

canvas_max_w=1600
canvas_min_w=900
canvas_min_h=1000
panel_margin=200
accent=""
panel_x=0
panel_y=0
panel_w=0
panel_h=0
margin_top=96
margin_bottom=96
crop_inset=3

die() { printf 'capture-preview: %s\n' "$*" >&2; exit 1; }
note() { printf '==> %s\n' "$*"; }

usage() {
  sed -n '2,27p' "$0" | sed 's/^# \{0,1\}//'
}

# All backups live in a private directory, never a predictable /tmp path. The
# optional override is accepted only when it is a real directory owned by the
# current user and inaccessible to group/other.
prepare_workdir() {
  local requested="${GROK_USAGE_CAPTURE_DIR:-}" mode
  if [[ -n $requested ]]; then
    if [[ ! -e $requested ]]; then
      mkdir -m 700 -- "$requested" || die "cannot create $requested"
    fi
    work=$requested
  else
    work=$(mktemp -d -- "${TMPDIR:-/tmp}/grok-usage-capture.XXXXXX") \
      || die "cannot create a private capture directory"
    work_auto=1
  fi

  [[ -d $work && ! -L $work ]] || die "capture directory is not a real directory: $work"
  [[ -O $work ]] || die "capture directory is not owned by you: $work"
  mode=$(stat -c '%a' "$work") || die "cannot stat $work"
  (( (8#$mode & 8#077) == 0 )) || die "capture directory must not be group/world accessible: $work ($mode)"

  shots="$work/shots"
  backup="$work/backup"
  [[ -e $shots ]] || mkdir -m 700 -- "$shots" || die "cannot create $shots"
  [[ -e $backup ]] || mkdir -m 700 -- "$backup" || die "cannot create $backup"
  local dir
  for dir in "$shots" "$backup"; do
    [[ -d $dir && ! -L $dir ]] || die "unsafe capture directory: $dir"
    [[ -O $dir ]] || die "capture directory is not owned by you: $dir"
    mode=$(stat -c '%a' "$dir") || die "cannot stat $dir"
    (( (8#$mode & 8#077) == 0 )) || die "capture directory must not be group/world accessible: $dir ($mode)"
  done
}

while (( $# > 0 )); do
  case "$1" in
    --out) out=${2:?--out needs a directory}; shift 2 ;;
    --hide) hides+=("${2:?--hide needs a plugin id}"); shift 2 ;;
    --accent) accent_arg=${2:?--accent needs a hex colour}; shift 2 ;;
    --bar-height) bar_height_arg=${2:?--bar-height needs a number}; shift 2 ;;
    --bar-width) bar_width=${2:?--bar-width needs a number}; shift 2 ;;
    --keep-raw) keep_raw=1; shift ;;
    --allow-restart) allow_restart=1; shift ;;
    --no-restore) skip_restore=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
done

for c in jq grim magick tesseract omarchy omarchy-shell; do
  command -v "$c" >/dev/null || die "$c is required"
done
[ -d "$demo_home" ] || die "$demo_home is missing"
[ -f "$shell_json" ] || die "$shell_json not found"

state_entry() {
  jq -c --arg id "$plugin" \
    'first(.bar.layout[][]? | select(type == "object" and .id == $id)) // empty' \
    "$shell_json"
}

backup_state() {
  local entry
  entry=$(state_entry)
  [ -n "$entry" ] || die "$plugin is not on the bar; enable it before capturing"
  printf '%s\n' "$entry" >"$backup/entry.json"
  if [ -f "$cache_file" ]; then
    install -m 0600 "$cache_file" "$backup/usage.json"
  else
    rm -f "$backup/usage.json"
  fi
  backed_up=1
}

restore_state() {
  (( restored )) && return 0
  restored=1
  # Nothing was touched yet, so there is nothing to put back.
  (( backed_up )) || return 0
  note "restoring widget settings and cache"
  omarchy-shell shell hide "$plugin" >/dev/null 2>&1 || true

  if [ -f "$backup/entry.json" ]; then
    local entry old_home old_bot old_stats
    entry=$(cat "$backup/entry.json")
    old_home=$(jq -r '.grokHome // ""' <<<"$entry")
    old_bot=$(jq -r '.botHome // ""' <<<"$entry")
    old_stats=$(jq -r 'if .showLocalStats == null then true else .showLocalStats end' <<<"$entry")
    omarchy bar set "$plugin" grokHome "$old_home" >/dev/null 2>&1 || true
    omarchy bar set "$plugin" botHome "$old_bot" >/dev/null 2>&1 || true
    omarchy bar set "$plugin" showLocalStats "$old_stats" --json >/dev/null 2>&1 || true
  fi

  if [ -f "$backup/usage.json" ]; then
    install -D -m 0600 "$backup/usage.json" "$cache_file"
  else
    rm -f "$cache_file"
  fi

  local id
  for id in ${hidden_ids[@]+"${hidden_ids[@]}"}; do
    note "re-enabling $id"
    omarchy-shell shell setPluginEnabled "$id" true >/dev/null 2>&1 || true
  done

  omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
}

finish() {
  local rc=$?
  trap - EXIT INT TERM
  [[ -n $work ]] || exit "$rc"
  if (( ! skip_restore )); then
    restore_state || note "restore failed; check $backup"
  fi
  if (( keep_raw )); then
    note "kept raw capture state at $work"
  elif (( work_auto )); then
    if (( rc == 0 && ! skip_restore )); then
      rm -rf -- "$work"
    else
      # Keep the private backups for diagnosis; drop the large raw shots.
      rm -f -- "$shots"/*.png 2>/dev/null || true
      note "capture state kept at $work"
    fi
  else
    note "left capture state at $work"
  fi
  exit "$rc"
}
trap finish EXIT INT TERM

# Copy the committed fixture and move its billing period around "now" so the
# countdown, the reset clock, and the local-activity window are always live.
stage_fixture() {
  local now start end stamp tmp file
  rm -rf "$work/grok-home"
  cp -R "$demo_home" "$work/grok-home"

  now=$(date +%s)
  start=$(date -u -d "@$(( now - 4 * 86400 ))" +%Y-%m-%dT%H:%M:%S.000Z)
  end=$(date -u -d "@$(( now + 3 * 86400 + 3 * 3600 ))" +%Y-%m-%dT%H:%M:%S.000Z)
  stamp=$(date -u -d "@$now" +%Y-%m-%dT%H:%M:%S.000Z)

  tmp="$work/unified.jsonl"
  : >"$tmp"
  while IFS= read -r line; do
    if [[ $line == *"billing: fetched credits config"* ]]; then
      jq -c --arg ts "$stamp" --arg s "$start" --arg e "$end" \
        '.ts = $ts | .ctx.config.currentPeriod.start = $s | .ctx.config.currentPeriod.end = $e' \
        <<<"$line" >>"$tmp"
    else
      printf '%s\n' "$line" >>"$tmp"
    fi
  done <"$work/grok-home/logs/unified.jsonl"
  mv "$tmp" "$work/grok-home/logs/unified.jsonl"

  while IFS= read -r file; do
    jq --arg at "$stamp" '.updatedAt = $at | (.turns[] | .endedAt) = $at' "$file" >"$file.tmp"
    mv "$file.tmp" "$file"
  done < <(find "$work/grok-home/sessions" -name usage.json -type f)
}

hide_plugins() {
  local id enabled
  for id in ${hides[@]+"${hides[@]}"}; do
    enabled=$(omarchy-shell shell listPlugins 2>/dev/null \
      | jq -r --arg id "$id" '.[] | select(.id == $id) | .enabled' | sed -n '1p')
    if [ "$enabled" = "true" ]; then
      note "hiding $id for the capture"
      omarchy-shell shell setPluginEnabled "$id" false >/dev/null
      hidden_ids+=("$id")
    else
      note "$id is already disabled"
    fi
  done
  sleep 0.5
}

apply_fixture() {
  note "pointing $plugin at the offline fixture"
  omarchy bar set "$plugin" grokHome "$work/grok-home"
  omarchy bar set "$plugin" botHome "$repo_dir/demo/grok-bot-home"
  omarchy bar set "$plugin" showLocalStats true --json
  rm -f "$cache_file"
  omarchy-shell shell rescanPlugins >/dev/null
}

wait_for_fixture() {
  for _ in $(seq 1 40); do
    if [ -f "$cache_file" ] \
      && jq -e '.data.tier == "SuperGrok" and .data.weekly.percent == 41' "$cache_file" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.25
  done
  return 1
}

panel_open() {
  omarchy-shell shell summon "$plugin" '{}' >/dev/null 2>&1 \
    || omarchy-shell shell toggle "$plugin" >/dev/null 2>&1 \
    || die "could not open the popup"
}

panel_close() {
  omarchy-shell shell hide "$plugin" >/dev/null 2>&1 || true
}

detect_bar_height() {
  local w h row
  if (( bar_height_arg > 0 )); then
    printf '%s\n' "$bar_height_arg"
    return
  fi
  read -r w _ < <(magick identify -format '%w %h\n' "$shots/closed.png")
  # The bar's bottom border is drawn in the theme accent. Averaging the accent
  # mask per row finds that line exactly and ignores the shadow below it.
  if [ -n "$accent" ]; then
    row=$(magick "$shots/closed.png" -crop "${w}x80+0+0" +repage -fuzz 1% \
      -fill white -opaque "$accent" -fill black +opaque white \
      -scale 1x80! -depth 8 txt:- \
      | awk -F'[(),]' '/^[0-9]+,/ { y = $2 + 0; v = $3 + 0; if (y > 4 && v > 60 && v > max) { max = v; best = y } }
          END { if (best) print best }')
    if [[ $row =~ ^[0-9]+$ ]] && (( row >= 12 && row <= 120 )); then
      printf '%s\n' "$row"
      return
    fi
  fi
  # Average each row across the width and take the first strong vertical
  # colour step: that is the bar's bottom edge. Icon rows barely move the
  # average; the bar-to-wallpaper step is large. --bar-height overrides it.
  read -r w h < <(magick identify -format '%w %h\n' "$shots/closed.png")
  h=$(magick "$shots/closed.png" -crop "${w}x160+0+0" +repage -scale 1x160! -depth 8 txt:- \
    | awk -F'[(),]' '
        /^[0-9]+,/ {
          y = $2 + 0; r = $3 + 0; g = $4 + 0; b = $5 + 0
          if (y > 2 && y < 60) {
            d = (r > pr ? r - pr : pr - r) + (g > pg ? g - pg : pg - g) + (b > pb ? b - pb : pb - b)
            if (d > 60) last = y
          }
          pr = r; pg = g; pb = b
        }
        END { if (last) print last }')
  if [[ $h =~ ^[0-9]+$ ]] && (( h >= 12 && h <= 120 )); then
    printf '%s\n' "$h"
  else
    printf '34\n'
  fi
}

# Emits "WxH+X+Y" for the region that differs between two images. The caller
# crops the region first, so the offset is relative to that crop.
diff_bbox() {
  magick "$1" "$2" -compose difference -composite -colorspace Gray \
    -threshold 3% -trim -format '%wx%h%O' info:
}

theme_accent() {
  local name file
  name=$(omarchy theme current 2>/dev/null | tr '[:upper:]' '[:lower:]')
  [ -n "$name" ] || return 0
  for file in "$HOME/.config/omarchy/themes/$name/colors.toml" \
    "/usr/share/omarchy/themes/$name/colors.toml"; do
    if [ -f "$file" ]; then
      awk -F'"' '/^[[:space:]]*accent[[:space:]]*=/ { print $2; exit }' "$file"
      return
    fi
  done
}

# Bbox of the popup border. Its horizontal and vertical accent lines are much
# longer than anything in the wallpaper, so requiring a run longer than an
# eighth of the screen ignores wallpaper accents that a plain colour mask would
# include.
accent_border_bbox() {
  local screen_w=$1 screen_h=$2 bar_h=$3 accent=$4
  local r g b
  [[ $accent =~ ^#[0-9A-Fa-f]{6}$ ]] || return 0
  r=$((16#${accent:1:2}))
  g=$((16#${accent:3:2}))
  b=$((16#${accent:5:2}))
  magick "$shots/open.png" -crop "${screen_w}x$(( screen_h - bar_h - 2 ))+0+$(( bar_h + 2 ))" +repage -depth 8 txt:- \
    | awk -F'[:,() ]+' -v W="$screen_w" -v H="$(( screen_h - bar_h - 2 ))" \
        -v ar="$r" -v ag="$g" -v ab="$b" '
      /^[0-9]+,/ {
        if ($3 == ar && $4 == ag && $5 == ab) { row[$2]++; col[$1]++ }
      }
      END {
        nr = 0
        for (y = 0; y < H; y++) {
          if (row[y] <= W / 8) continue
          if (nr && y <= ends[nr] + 2) ends[nr] = y
          else { nr++; starts[nr] = y; ends[nr] = y }
        }
        nc = 0
        for (x = 0; x < W; x++) {
          if (col[x] <= H / 8) continue
          if (nc && x <= cends[nc] + 2) cends[nc] = x
          else { nc++; cstarts[nc] = x; cends[nc] = x }
        }
        if (nr >= 2 && nc >= 2) {
          printf "%dx%d+%d+%d\n", cends[nc] - cstarts[1] + 1,
            ends[nr] - starts[1] + 1, cstarts[1], starts[1]
        }
      }' 2>/dev/null || true
}

# Locate the popup by its accent border. Independent of the wallpaper or of
# anything animating behind it; falls back to a frame diff if the theme accent
# is unknown.
detect_panel() {
  local screen_w=$1 screen_h=$2 bar_h=$3
  local accent geo low_h

  accent=${accent_arg:-$(theme_accent)}
  if [ -n "$accent" ]; then
    geo=$(accent_border_bbox "$screen_w" "$screen_h" "$bar_h" "$accent")
    if [[ $geo =~ ^([0-9]+)x([0-9]+)\+([0-9]+)\+([0-9]+)$ ]] \
      && (( BASH_REMATCH[1] > 200 && BASH_REMATCH[2] > 200 )) \
      && (( BASH_REMATCH[1] < screen_w * 8 / 10 && BASH_REMATCH[2] < screen_h * 9 / 10 )); then
      panel_w=${BASH_REMATCH[1]}
      panel_h=${BASH_REMATCH[2]}
      panel_x=${BASH_REMATCH[3]}
      panel_y=$(( bar_h + 2 + BASH_REMATCH[4] ))
      note "popup located by theme accent $accent"
      return
    fi
  fi

  # Fallback: diff the area below the bar so the bar button cannot widen it.
  low_h=$(( screen_h - bar_h ))
  magick "$shots/open.png" -crop "${screen_w}x${low_h}+0+${bar_h}" +repage "$work/open_low.png"
  magick "$shots/closed.png" -crop "${screen_w}x${low_h}+0+${bar_h}" +repage "$work/closed_low.png"
  geo=$(diff_bbox "$work/open_low.png" "$work/closed_low.png")
  [[ $geo =~ ^([0-9]+)x([0-9]+)\+([0-9]+)\+([0-9]+)$ ]] \
    || die "could not locate the popup (got '$geo'); pass --accent HEX"
  (( BASH_REMATCH[1] > 200 && BASH_REMATCH[2] > 200 )) \
    || die "popup detection looks wrong: ${BASH_REMATCH[1]}x${BASH_REMATCH[2]}"
  # Stay inside the border so no wallpaper/shadow corner leaks into the crop.
  panel_x=$(( BASH_REMATCH[3] + crop_inset ))
  panel_y=$(( bar_h + BASH_REMATCH[4] + crop_inset ))
  panel_w=$(( BASH_REMATCH[1] - 2 * crop_inset ))
  panel_h=$(( BASH_REMATCH[2] - 2 * crop_inset ))
  note "popup located by frame diff"
}

compose() {
  local screen_w screen_h bar_h geo bx bw
  read -r screen_w screen_h < <(magick identify -format '%w %h\n' "$shots/open.png")
  accent=${accent_arg:-$(theme_accent)}
  bar_h=$(detect_bar_height)
  detect_panel "$screen_w" "$screen_h" "$bar_h"

  # Widget extent: the bar background is uniform, so the widget is the run of
  # non-background columns around the popup centre. Merge gaps <= 14px so the
  # mark and its meters count as one widget, then pad it.
  local center=$(( panel_x + panel_w / 2 ))
  local span band_h
  band_h=$(( bar_h - 16 ))
  (( band_h < 10 )) && band_h=10
  span=$(magick "$shots/closed.png" -crop "${screen_w}x${band_h}+0+8" +repage -depth 8 txt:- \
    | awk -F'[(),]' -v cx="$center" -v w="$screen_w" '
        /^[0-9]+,/ {
          x = $1 + 0; r = $3 + 0; g = $4 + 0; b = $5 + 0
          if ((r + g + b) > 60) on[x] = 1
        }
        END {
          n = 0
          for (x = 0; x < w; x++) {
            if (!on[x]) continue
            s = x
            while (x < w && on[x]) x++
            e = x - 1
            if (n > 0 && s - ends[n] <= 24) ends[n] = e
            else { n++; starts[n] = s; ends[n] = e }
          }
          best = 0; bestd = 1e9
          for (i = 1; i <= n; i++) {
            if (cx >= starts[i] - 4 && cx <= ends[i] + 4) { print starts[i], ends[i]; exit }
            d = (cx < starts[i] ? starts[i] - cx : cx - ends[i])
            if (d < bestd) { bestd = d; best = i }
          }
          if (best) print starts[best], ends[best]
        }')
  if [ -n "$span" ]; then
    read -r ws we <<<"$span"
    bx=$(( ws > 16 ? ws - 16 : 0 ))
    bw=$(( we - bx + 17 ))
  else
    bx=$(( center - bar_width / 2 ))
    (( bx < 0 )) && bx=0
    bw=$bar_width
  fi
  (( bx + bw > screen_w )) && bw=$(( screen_w - bx ))

  # Bar background: the dominant colour of the crop itself, so extending the
  # strip and the canvas never picks up an icon or a bright wallpaper patch.
  local bg canvas_bg
  bg=$(magick "$shots/closed.png" -crop "${bw}x${bar_h}+${bx}+0" +repage \
    -format %c histogram:info:- | sort -rn | sed -n '1s/.*\(#[0-9A-Fa-f]\{6\}\).*/\1/p')
  if [ -z "$bg" ]; then
    bg=$(magick "$shots/closed.png" -depth 8 -format "%[pixel:p{2,$(( bar_h / 2 ))}]" info:)
  fi
  # Lift the canvas slightly off the bar colour so the bar reads as a strip
  # instead of blending into the background.
  canvas_bg=$(magick "xc:$bg" -fill white -colorize 12% -depth 8 -format '%[pixel:p{0,0}]' info:)

  local canvas_w=$(( panel_w + 2 * panel_margin ))
  (( canvas_w < canvas_min_w )) && canvas_w=$canvas_min_w
  (( canvas_w > canvas_max_w )) && canvas_w=$canvas_max_w
  (( canvas_w % 2 )) && canvas_w=$(( canvas_w + 1 ))

  note "bar ${bar_h}px, widget ${bw}x${bar_h}+${bx}, popup ${panel_w}x${panel_h}+${panel_x}+${panel_y}"

  magick "$shots/closed.png" -crop "${bw}x${bar_h}+${bx}+0" +repage \
    -background "$bg" -gravity center -extent "${canvas_w}x${bar_h}" \
    -strip "$work/bar-strip.png"
  magick "$shots/open.png" -crop "${panel_w}x${panel_h}+${panel_x}+${panel_y}" +repage \
    -strip "$work/panel.png"

  local canvas_h=$(( bar_h + margin_top + panel_h + margin_bottom ))
  (( canvas_h < canvas_min_h )) && canvas_h=$canvas_min_h
  local pan_x=$(( (canvas_w - panel_w) / 2 ))
  local pan_y=$(( bar_h + margin_top ))

  magick -size "${canvas_w}x${canvas_h}" "xc:$canvas_bg" \
    "$work/bar-strip.png" -geometry +0+0 -composite \
    "$work/panel.png" -geometry "+${pan_x}+${pan_y}" -composite \
    -strip "$work/preview.png"

  # README shot: a slice of bar starting just left of the widget, so it stays
  # inside the bar island and never shows the wallpaper or a neighbouring
  # island. Includes the bar's bottom border, which the preview strip omits.
  local barimg_w=480
  local barimg_x=$(( bx > 24 ? bx - 24 : 0 ))
  (( barimg_x + barimg_w > screen_w )) && barimg_w=$(( screen_w - barimg_x ))
  magick "$shots/closed.png" -crop "${barimg_w}x$(( bar_h + 2 ))+${barimg_x}+0" +repage \
    -bordercolor "$bg" -border 20 -strip "$work/bar.png"

  note "composed ${canvas_w}x${canvas_h} preview in $work"
}

qa() {
  note "checking the preview for real account data"
  local ocr bad=0 pattern
  ocr=$(tesseract "$work/preview.png" stdout --psm 6 2>/dev/null || true)

  for pattern in \
    'crueber' \
    '[[:alnum:]._%+-]+@[[:alnum:].-]+\.[[:alpha:]]{2,}' \
    '33%' '6\.18' '29\.2M' '258K' '28\.4M' '08:22' '\bws_[[:alnum:]]'; do
    if grep -qiE "$pattern" <<<"$ocr"; then
      printf 'FAIL: preview still contains /%s/\n' "$pattern" >&2
      bad=1
    fi
  done
  for pattern in 'grok' 'weekly' '41%' 'supergrok' 'grok bot' '42\.7%'; do
    if ! grep -qiE "$pattern" <<<"$ocr"; then
      printf 'FAIL: expected /%s/ is missing from the preview\n' "$pattern" >&2
      bad=1
    fi
  done

  if jq -e '.data.tier == "SuperGrok" and .data.weekly.percent == 41' "$cache_file" >/dev/null 2>&1; then
    note "fixture data confirmed in the cache"
  else
    printf 'FAIL: the cache does not hold the demo report\n' >&2
    bad=1
  fi

  if magick identify -format '%[EXIF:*]' "$work/preview.png" 2>/dev/null | grep -q .; then
    printf 'FAIL: preview still carries EXIF metadata\n' >&2
    bad=1
  fi

  (( bad == 0 )) || die "screenshot QA failed; nothing was published"
}

publish() {
  mkdir -p "$out/screenshots"
  install -m 0644 "$work/preview.png" "$out/preview.png"
  install -m 0644 "$work/bar.png" "$out/screenshots/bar.png"
  note "wrote $out/preview.png and $out/screenshots/bar.png"
}

main() {
  prepare_workdir
  backup_state
  hide_plugins
  stage_fixture
  apply_fixture

  # Opening the panel triggers the fetch; wait until the fixture has landed so
  # both captures show populated meters.
  panel_open
  if ! wait_for_fixture; then
    if (( allow_restart )); then
      note "fixture not loaded after rescan; restarting the shell once"
      omarchy restart shell
      sleep 4
      panel_open
      wait_for_fixture || die "the widget never requested data from the fixture"
    else
      die "the widget did not request data from the fixture; retry with --allow-restart"
    fi
  fi
  sleep 1.5

  # Closed capture first: no popup, no button highlight, data already on the bar.
  panel_close
  sleep 0.8
  grim "$shots/closed.png"

  panel_open
  sleep 1.2
  grim "$shots/open.png"

  compose
  qa
  publish
  note "done"
}

main
