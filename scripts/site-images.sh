#!/bin/bash
# Renders the website's raster images with Chrome: the share cards site/og.png (Chinese) and
# site/og-{en,ja,ko}.png from scripts/site-og.html?lang=…,
# and site/icon.png (512 px, from site/icon.svg). Rerun after changing either source; commit the PNGs.
set -euo pipefail
cd "$(dirname "$0")/.."
CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
[ -x "$CHROME" ] || { echo "needs Google Chrome (set CHROME=…)" >&2; exit 1; }
# Chrome often exits non-zero after writing the screenshot (display-link errors when headless); check the file instead.
shot() { rm -f "$3"; "$CHROME" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=1 "${@:4}" \
  --window-size="$2" --screenshot="$PWD/$3" "file://$PWD/$1${QUERY:-}" >/dev/null 2>&1 || true; [ -s "$3" ] || { echo "Chrome wrote no $3" >&2; exit 1; }; }
# The budget lets the web fonts load before the screenshot.
for lang in zh en ja ko; do
  out=site/og.png; [ "$lang" = zh ] || out=site/og-$lang.png
  QUERY="?lang=$lang" shot scripts/site-og.html 1200,630 "$out" --virtual-time-budget=5000
done
printf '<html><body style="margin:0"><img src="../site/icon.svg" width="512" height="512"></body></html>' > scripts/.icon.html
shot scripts/.icon.html 512,512 site/icon.png --default-background-color=00000000
rm -f scripts/.icon.html
echo "wrote site/og.png site/og-{en,ja,ko}.png site/icon.png"
