#!/usr/bin/env bash
set -euo pipefail

# Deploy the runtime files to the live Omarchy plugin directory.
# This intentionally does not add the widget to the bar; enable it explicitly.

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
plugin_id="crueber.grok-usage"
dest="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins/$plugin_id"

command -v omarchy >/dev/null 2>&1 || {
  echo "omarchy is not on PATH; this script is for an Omarchy install" >&2
  exit 1
}

install -d "$dest" "$dest/scripts"
for file in manifest.json Panel.qml GrokMark.qml Model.js README.md LICENSE preview.png; do
  test -f "$repo_dir/$file" || continue
  install -m 0644 "$repo_dir/$file" "$dest/$file"
done
install -m 0755 "$repo_dir/scripts/collect.js" "$dest/scripts/collect.js"

omarchy plugin validate "$dest"
omarchy-shell -q shell rescanPlugins || true

echo "Installed $plugin_id to $dest"
echo "Enable it with: omarchy plugin enable $plugin_id --section right"
