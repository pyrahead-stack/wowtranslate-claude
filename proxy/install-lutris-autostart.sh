#!/usr/bin/env bash
# Traegt den WoWTranslate-Claude-Proxy als Lutris "prelaunch_command" ein,
# damit er automatisch startet, sobald das Spiel ueber Lutris gestartet wird.
# Funktioniert fuer JEDEN Nutzer: findet die passende Lutris-Game-Konfig selbst.
#
# Aufruf:  ./install-lutris-autostart.sh
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ENSURE="$HERE/ensure-proxy.sh"
GAMES_DIR="${LUTRIS_GAMES_DIR:-$HOME/.config/lutris/games}"

[ -x "$ENSURE" ] || chmod +x "$ENSURE" 2>/dev/null || true

if [ ! -d "$GAMES_DIR" ]; then
  echo "No Lutris game configs found ($GAMES_DIR)."
  echo "Add the command manually (Lutris -> game -> gear icon -> System options ->"
  echo "  'Run a command before launch'):"
  echo "    $ENSURE"
  exit 0
fi

# Kandidaten: Configs, die nach WoW/OctoWoW aussehen
mapfile -t CANDS < <(grep -ril -E 'wow|octowow' "$GAMES_DIR"/*.yml 2>/dev/null || true)

if [ "${#CANDS[@]}" -eq 0 ]; then
  echo "No WoW game found in Lutris. Existing configs:"
  ls -1 "$GAMES_DIR"/*.yml 2>/dev/null || true
  echo
  echo "Add the command manually via the Lutris GUI:"
  echo "    $ENSURE"
  exit 0
fi

echo "Game config(s) found:"
for i in "${!CANDS[@]}"; do echo "  [$i] ${CANDS[$i]}"; done
IDX=0
if [ "${#CANDS[@]}" -gt 1 ]; then
  read -rp "Which one? (number) " IDX
fi
YML="${CANDS[$IDX]}"

cp -a "$YML" "$YML.bak.$(date +%s)"

if grep -q 'prelaunch_command:' "$YML"; then
  echo "$YML already has a prelaunch_command set — leaving it unchanged."
  echo "Check/set it manually to: $ENSURE if needed"
  exit 0
fi

if grep -qE '^system:' "$YML"; then
  # unter vorhandenem system: einfuegen
  awk -v cmd="$ENSURE" '
    /^system:/ { print; print "  prelaunch_command: " cmd; print "  prelaunch_wait: false"; next }
    { print }
  ' "$YML" > "$YML.tmp" && mv "$YML.tmp" "$YML"
else
  # neuen system-Block anhaengen
  {
    echo "system:"
    echo "  prelaunch_command: $ENSURE"
    echo "  prelaunch_wait: false"
  } >> "$YML"
fi

echo "OK — autostart added to: $YML"
echo "The proxy now starts automatically when you launch the game via Lutris."
