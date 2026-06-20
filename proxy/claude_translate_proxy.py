#!/usr/bin/env python3
"""
Claude-Proxy fuer WoWTranslate (geforkte DLL).

Die geforkte DLL POSTet an  http://127.0.0.1:8787/api/translate
  Body:    {"apiKey":"...","text":"...","from":"<lang>","to":"<lang>"}
  Erwartet:{"translation":"...","creditsRemaining":<zahl>}
           bzw. {"error":"..."} im Fehlerfall.

Dieser Proxy ignoriert apiKey/credits (privater Server, keine Abrechnung),
ruft die Claude Messages API auf und gibt die Uebersetzung zurueck.

Start:
  export ANTHROPIC_API_KEY=sk-ant-...
  python3 claude_translate_proxy.py
"""

import os
import json
import urllib.request
import urllib.error
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# ----- Konfiguration -------------------------------------------------------
LISTEN_HOST = "127.0.0.1"
LISTEN_PORT = 8787
MODEL = "claude-haiku-4-5"          # schnell + guenstig, ideal fuer Chat
ANTHROPIC_URL = "https://api.anthropic.com/v1/messages"
API_KEY = os.environ.get("ANTHROPIC_API_KEY", "")

# WoW schickt Sprachcodes (zh, en, de, ru, ...). Fuer den Prompt zu Klarnamen.
LANG = {
    "zh": "Chinese", "en": "English", "de": "German", "ru": "Russian",
    "ko": "Korean", "ja": "Japanese", "fr": "French", "es": "Spanish",
    "auto": "the source language",
}


def lang_name(code):
    return LANG.get((code or "").lower(), code or "the source language")


def translate(text, src, dst):
    """Ruft Claude auf und gibt den uebersetzten Text zurueck (raises bei Fehler)."""
    system = (
        f"You are a translation engine for World of Warcraft chat. "
        f"Translate the user's message from {lang_name(src)} to {lang_name(dst)}. "
        f"Output ONLY the translation, nothing else — no quotes, no notes, no preamble. "
        f"Keep player names, item links (text in brackets), numbers and emotes unchanged. "
        f"If the text is already in {lang_name(dst)}, return it unchanged."
    )
    body = json.dumps({
        "model": MODEL,
        "max_tokens": 1024,
        "system": system,
        "messages": [{"role": "user", "content": text}],
    }).encode("utf-8")

    req = urllib.request.Request(
        ANTHROPIC_URL, data=body, method="POST",
        headers={
            "x-api-key": API_KEY,
            "anthropic-version": "2023-06-01",
            "content-type": "application/json",
        },
    )
    with urllib.request.urlopen(req, timeout=25) as resp:
        data = json.loads(resp.read().decode("utf-8"))
    # Messages-API: {"content":[{"type":"text","text":"..."}], ...}
    parts = [b.get("text", "") for b in data.get("content", []) if b.get("type") == "text"]
    return "".join(parts).strip()


class Handler(BaseHTTPRequestHandler):
    def _send(self, obj, code=200):
        payload = json.dumps(obj).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_POST(self):
        if self.path != "/api/translate":
            self._send({"error": "not found"}, 404)
            return
        try:
            length = int(self.headers.get("Content-Length", 0))
            req = json.loads(self.rfile.read(length).decode("utf-8"))
            text = req.get("text", "")
            if not text:
                self._send({"error": "empty text"}, 400)
                return
            out = translate(text, req.get("from", "auto"), req.get("to", "en"))
            print(f"[ok] {req.get('from')}->{req.get('to')}: {text[:40]!r} -> {out[:40]!r}")
            # creditsRemaining gross genug, damit das Addon nie "out of credits" meldet
            self._send({"translation": out, "creditsRemaining": 99999999})
        except urllib.error.HTTPError as e:
            detail = e.read().decode("utf-8", "replace")
            print(f"[claude-http-error] {e.code}: {detail[:200]}")
            self._send({"error": f"claude {e.code}"}, 200)
        except Exception as e:
            print(f"[error] {e}")
            self._send({"error": str(e)}, 200)

    def log_message(self, *a):
        pass  # eigene Logs oben, Default-Spam aus


def main():
    if not API_KEY:
        raise SystemExit("ANTHROPIC_API_KEY ist nicht gesetzt (export ANTHROPIC_API_KEY=sk-ant-...)")
    srv = ThreadingHTTPServer((LISTEN_HOST, LISTEN_PORT), Handler)
    print(f"WoWTranslate Claude-Proxy laeuft auf http://{LISTEN_HOST}:{LISTEN_PORT}  (Modell: {MODEL})")
    print("Strg+C zum Beenden.")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        print("\nbeendet.")


if __name__ == "__main__":
    main()
