#!/bin/bash
# Build a drag-to-Applications DMG from an app bundle.
#
#   scripts/make-dmg.sh <path/to/Davit.app> <output.dmg>
#
# Uses create-dmg (brew) for the styled window (icon positions, /Applications
# drop link) when available; falls back to a plain hdiutil image with an
# /Applications symlink if create-dmg is missing OR fails (its Finder
# scripting can be flaky on headless CI) — the release must never fail on
# the nice-to-have.
set -euo pipefail

APP="$1"
OUT="$2"
VOLNAME="Davit"

[ -d "$APP" ] || { echo "app bundle not found: $APP" >&2; exit 1; }
rm -f "$OUT"

build_plain() {
  echo "==> hdiutil (plain layout)"
  local stage
  stage=$(mktemp -d)
  cp -R "$APP" "$stage/"
  ln -s /Applications "$stage/Applications"
  hdiutil create -volname "$VOLNAME" -srcfolder "$stage" -ov -format UDZO "$OUT"
  rm -rf "$stage"
}

if command -v create-dmg >/dev/null 2>&1; then
  echo "==> create-dmg (styled window)"
  create-dmg \
    --volname "$VOLNAME" \
    --window-pos 200 160 \
    --window-size 560 360 \
    --icon-size 112 \
    --icon "$(basename "$APP")" 140 170 \
    --app-drop-link 420 170 \
    --no-internet-enable \
    "$OUT" "$APP" || true
  if [ ! -f "$OUT" ]; then
    echo "create-dmg produced nothing — falling back"
    build_plain
  fi
else
  build_plain
fi

[ -f "$OUT" ] || { echo "DMG was not produced" >&2; exit 1; }
echo "==> Done: $OUT"
