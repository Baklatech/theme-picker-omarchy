#!/bin/bash
# Theme catalog for Omarchy: a window with every community theme as a tile.
# Run as a regular user; nothing here needs sudo. Safe to re-run.
set -euo pipefail

repo=$(dirname "$(readlink -f "$0")")
plugin_id=gnome627.theme-picker
plugin_dir=$HOME/.config/omarchy/plugins/$plugin_id
menu=$HOME/.config/omarchy/extensions/omarchy-menu.jsonc

step() { echo -e "\n==> $*"; }
die() {
  echo "Error: $*" >&2
  exit 1
}

((EUID != 0)) || die "run it without sudo, as your own user"
command -v omarchy-shell >/dev/null || die "the Omarchy shell is required (Omarchy 4 or newer)"
[[ -x /usr/bin/python3 ]] || die "python3 is required: sudo pacman -S python"
/usr/bin/python3 -c 'import tomllib' 2>/dev/null || die "python 3.11 or newer is required"
command -v git >/dev/null || die "git is required: sudo pacman -S git"
# Only the fallback palette needs it: themes without colors.toml or
# alacritty.toml get their swatches from the preview image.
command -v magick >/dev/null ||
  echo "Warning: imagemagick is missing, so a few themes will have no color swatches."

step "theme-picker script"
install -Dm755 "$repo/bin/theme-picker" "$HOME/.local/bin/theme-picker"

step "Catalog window: Omarchy shell plugin"
install -Dm644 "$repo/plugin/manifest.json" "$plugin_dir/manifest.json"
install -Dm644 "$repo/plugin/ThemePicker.qml" "$plugin_dir/ThemePicker.qml"
omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
omarchy plugin enable "$plugin_id"

step "Omarchy menu entry: Install > Style > Theme Catalog"
if [[ -e $menu ]] && ! grep -q '"install.style.theme-catalog"' "$menu"; then
  # The menu entry is described in Russian for ru locales, in English otherwise.
  case ${LC_ALL:-${LC_MESSAGES:-${LANG:-}}} in
    ru*) description="Каталог тем сообщества: превью, палитра, установка и удаление" ;;
    *) description="Community theme catalog: preview, palette, install and remove" ;;
  esac
  # The row goes right before the closing brace of the file.
  row='  "install.style.theme-catalog": {"icon":"󰸌","label":"Theme Catalog","aliases":["theme-catalog","catalog"],"description":"'$description'","action":"$HOME/.local/bin/theme-picker menu"},'
  last=$(grep -n '^}' "$menu" | tail -n1 | cut -d: -f1)
  sed -i "${last}i\\$row" "$menu"
else
  echo "The menu entry is already there"
fi

step "Done. Open it from the Omarchy menu or run: theme-picker menu"
echo "After an update of an already installed copy, restart the shell: omarchy restart shell"
