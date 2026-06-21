#!/usr/bin/env bash
# Startet den WoWTranslate-Claude-Proxy. Liest den API-Key aus einer
# geschuetzten Datei (Standard: ~/.config/wowtranslate/anthropic.key),
# damit er nie im Repo, in der Shell-History oder in ps-Ausgaben landet.
set -euo pipefail

KEY_FILE="${ANTHROPIC_KEY_FILE:-$HOME/.config/wowtranslate/anthropic.key}"

if [ ! -s "$KEY_FILE" ]; then
  echo "ERROR: key file missing or empty: $KEY_FILE" >&2
  echo "Create it (without leaking to shell history):" >&2
  echo "  read -rsp 'Paste your key, then Enter: ' K && (umask 077; printf '%s' \"\$K\" > \"$KEY_FILE\") && unset K" >&2
  exit 1
fi

export ANTHROPIC_API_KEY="$(tr -d '[:space:]' < "$KEY_FILE")"
echo "Key loaded from $KEY_FILE ($(wc -c < "$KEY_FILE") bytes)."

# Optionales Monatslimit (USD): WT_BUDGET oder Datei ~/.config/wowtranslate/budget.
# Gesetzt -> Uebersetzung stoppt beim Limit, Config-Fenster zeigt "Budget -> $x left".
# Ohne Limit = unbegrenzt (eigener Key).
BUDGET_FILE="$HOME/.config/wowtranslate/budget"
if [ -z "${WT_BUDGET:-}" ] && [ ! -s "$BUDGET_FILE" ]; then
  echo "Note: no monthly limit set (unlimited). Optional:  echo 5 > $BUDGET_FILE"
fi
exec python3 -u "$(dirname "$0")/claude_translate_proxy.py"
