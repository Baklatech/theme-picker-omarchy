#!/bin/bash
# Removes everything install.sh put in place. Themes installed through the
# window stay: remove them there first, or with omarchy theme remove.
set -euo pipefail

plugin_id=gnome627.theme-picker
menu=$HOME/.config/omarchy/extensions/omarchy-menu.jsonc

((EUID != 0)) || { echo "Error: run it without sudo" >&2; exit 1; }

if command -v omarchy-shell >/dev/null; then
  omarchy plugin disable "$plugin_id" || true
fi
rm -rf "$HOME/.config/omarchy/plugins/$plugin_id"
rm -f "$HOME/.local/bin/theme-picker"
rm -rf "${XDG_CACHE_HOME:-$HOME/.cache}/theme-picker"
[[ ! -e $menu ]] || sed -i '/"install.style.theme-catalog": /d; /^\/\/ [<>]\{3\} theme-picker [<>]\{3\}$/d' "$menu"

echo "Removed."
