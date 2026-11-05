#!/bin/sh
# Installs Cicada for this user, no sudo: the app in ~/.local/lib/cicada, `cicada` in
# ~/.local/bin, the menu entry and icon in ~/.local/share. Run it again to update; --remove undoes it; --check only checks the libraries
# (records and the Ling key stay in ~/.local/share/cicada and ~/.config/cicada).
set -e
src="$(cd "$(dirname "$0")" && pwd)"
lib="$HOME/.local/lib/cicada"; bin="$HOME/.local/bin"; share="$HOME/.local/share"
if [ "$1" = "--remove" ]; then
  rm -rf "$lib" "$bin/cicada" "$share/applications/com.wquguru.cicada.desktop" "$share/icons/hicolor/scalable/apps/cicada.svg" \
         "${XDG_CONFIG_HOME:-$HOME/.config}/autostart/com.wquguru.cicada.desktop"
  # The 开始 / 结束听 keyboard shortcut, if it was added in 设置 (it would run a removed program).
  python3 - <<'PY' 2>/dev/null || true
from gi.repository import Gio
schema = "org.gnome.settings-daemon.plugins.media-keys"
if Gio.SettingsSchemaSource.get_default().lookup(schema, True):
    keys = Gio.Settings.new(schema)
    ours = {"/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/%s/" % n for n in ("cicada", "cicada-speak")}
    keys.set_strv("custom-keybindings", [p for p in keys.get_strv("custom-keybindings") if p not in ours])
    Gio.Settings.sync()
PY
  echo "Cicada removed."; exit 0
fi
missing=""
python3 -c 'import gi; gi.require_version("Gtk", "3.0"); from gi.repository import Gtk' 2>/dev/null || missing="$missing python3-gi gir1.2-gtk-3.0"
python3 -c 'import ctypes.util, sys; sys.exit(0 if ctypes.util.find_library("pulse-simple") else 1)' || missing="$missing libpulse0"
if [ -n "$missing" ]; then echo "Cicada needs:$missing  (sudo apt install$missing)"; exit 1; fi
# --check: only the checks above (an update runs the new version's before anything is replaced).
[ "$1" = "--check" ] && exit 0
rm -rf "$lib" && mkdir -p "$lib" "$bin" "$share/applications" "$share/icons/hicolor/scalable/apps"
cp -R "$src/cicada" "$src/lproj" "$src/bin" "$lib/"
[ -f "$src/sample.wav" ] && cp "$src/sample.wav" "$lib/"
# 说话人识别: the voiceprint weights and libcicada-voice-<arch>.so (speakers.py looks for them here).
for d in models lib; do [ -d "$src/$d" ] && cp -R "$src/$d" "$lib/"; done
cp "$src/cicada.svg" "$lib/"  # the tray and window icon, by path
cp "$src/VERSION" "$lib/"     # read by cicada/__init__.py
ln -sf "$lib/bin/cicada" "$bin/cicada"
sed "s|@BIN@|$lib/bin/cicada|" "$src/com.wquguru.cicada.desktop" > "$share/applications/com.wquguru.cicada.desktop"
cp "$src/cicada.svg" "$share/icons/hicolor/scalable/apps/cicada.svg"
gtk-update-icon-cache -q "$share/icons/hicolor" 2>/dev/null || true
echo "Cicada installed: open it from the app grid (知了 / Cicada)."
