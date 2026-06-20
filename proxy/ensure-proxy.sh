#!/usr/bin/env bash
# Startet den WoWTranslate-Claude-Proxy, falls er nicht schon laeuft.
# Gedacht als Lutris "prelaunch_command" fuer OctoWoW. Beendet sich sofort,
# damit der Spielstart nicht blockiert.
LOG=/tmp/wtproxy.log
HERE="$(cd "$(dirname "$0")" && pwd)"

if ss -ltn 2>/dev/null | grep -q '127.0.0.1:8787'; then
  echo "[ensure-proxy] laeuft bereits." >> "$LOG"
  exit 0
fi

echo "[ensure-proxy] starte Proxy $(date)" >> "$LOG"
setsid nohup "$HERE/start-proxy.sh" >> "$LOG" 2>&1 &
exit 0
