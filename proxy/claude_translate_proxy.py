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
import time
import threading
import urllib.request
import urllib.error
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# ----- Konfiguration -------------------------------------------------------
LISTEN_HOST = "127.0.0.1"
LISTEN_PORT = 8787
MODEL = "claude-haiku-4-5"          # schnell + guenstig, ideal fuer Chat
ANTHROPIC_URL = "https://api.anthropic.com/v1/messages"
API_KEY = os.environ.get("ANTHROPIC_API_KEY", "")

# Transiente Fehler, bei denen ein erneuter Versuch lohnt (Overload/Rate-Limit/
# kurze Serverhaenger). Backoff knapp halten, damit der DLL-Timeout nicht reisst.
RETRY_STATUS = {429, 500, 503, 529}
RETRY_BACKOFF = [1, 2]  # Sekunden vor Versuch 2 und 3 (0 Wartezeit beim 1.)

# Anthropic-Preise in USD je 1 Mio. Tokens (Input/Output). Stand 2026-06.
# Quelle: claude-api Modell-Tabelle. Bei unbekanntem Modell -> Haiku-Preis.
PRICING = {
    "claude-haiku-4-5": (1.00, 5.00),
    "claude-sonnet-4-6": (3.00, 15.00),
    "claude-opus-4-8": (5.00, 25.00),
}

STATS_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "usage-stats.json")


class UsageStats:
    """Zaehlt API-Calls/Tokens persistent mit und schaetzt die Kosten.
    Nur echte Claude-Calls landen hier — Cache-Hits kosten nichts."""

    def __init__(self, path):
        self.path = path
        self.lock = threading.Lock()
        self.data = {"calls": 0, "input_tokens": 0, "output_tokens": 0}
        try:
            with open(path, "r", encoding="utf-8") as f:
                self.data.update(json.load(f))
        except (FileNotFoundError, ValueError):
            pass

    def add(self, input_tokens, output_tokens):
        with self.lock:
            self.data["calls"] += 1
            self.data["input_tokens"] += input_tokens
            self.data["output_tokens"] += output_tokens
            tmp = self.path + ".tmp"
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump(self.data, f)
            os.replace(tmp, self.path)
            return self.cost()

    def cost(self):
        pin, pout = PRICING.get(MODEL, PRICING["claude-haiku-4-5"])
        return (self.data["input_tokens"] * pin
                + self.data["output_tokens"] * pout) / 1_000_000

    def summary(self):
        return (f"{self.data['calls']} Calls, "
                f"{self.data['input_tokens']}+{self.data['output_tokens']} Tokens, "
                f"~${self.cost():.4f}")


STATS = UsageStats(STATS_PATH)

# Cache-Datei liegt neben diesem Skript, damit sie unabhaengig vom CWD ist.
CACHE_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "translation-cache.json")


class TranslationCache:
    """Persistenter Cache ueber alle Chars/Sessions hinweg.

    Schluessel = "<from>|<to>|<text>". In-Memory-Dict fuer Tempo, JSON auf
    Platte fuers Ueberleben von Neustarts. Atomisches Schreiben (tmp + replace),
    damit ein Absturz mittendrin die Datei nicht zerschiesst.
    """

    def __init__(self, path):
        self.path = path
        self.lock = threading.Lock()
        self.data = {}
        try:
            with open(path, "r", encoding="utf-8") as f:
                self.data = json.load(f)
        except (FileNotFoundError, ValueError):
            self.data = {}

    @staticmethod
    def _key(text, src, dst):
        return f"{(src or '').lower()}|{(dst or '').lower()}|{text}"

    def get(self, text, src, dst):
        with self.lock:
            return self.data.get(self._key(text, src, dst))

    def put(self, text, src, dst, translation):
        with self.lock:
            self.data[self._key(text, src, dst)] = translation
            tmp = self.path + ".tmp"
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump(self.data, f, ensure_ascii=False)
            os.replace(tmp, self.path)

    def __len__(self):
        return len(self.data)


CACHE = TranslationCache(CACHE_PATH)

# WoW schickt Sprachcodes (zh, en, de, ru, ...). Fuer den Prompt zu Klarnamen.
LANG = {
    "zh": "Chinese", "en": "English", "de": "German", "ru": "Russian",
    "ko": "Korean", "ja": "Japanese", "fr": "French", "es": "Spanish",
    "auto": "the source language",
}


def lang_name(code):
    return LANG.get((code or "").lower(), code or "the source language")


# ----- Glossar -------------------------------------------------------------
# WoW-Begriffe, die generische Uebersetzer falsch machen (Boss-/Raid-/Slang-
# Namen). Quelle-Begriff -> kanonische Uebersetzung. Nur Eintraege, die im Text
# vorkommen, werden in den Prompt gehaengt -> kostet kaum Tokens.
# Erweiterbar ueber proxy/glossary.json (wird gemerged, ueberschreibt Defaults).
GLOSSARY = {
    # Naxxramas / Classic-Raids & Bosse (zh -> en)
    "老克": "Kel'Thuzad",
    "纳克": "Naxxramas",
    "naxx": "Naxxramas",
    "kt": "Kel'Thuzad",
    "mc": "Molten Core",
    "bwl": "Blackwing Lair",
    "拉格": "Ragnaros",
    "奥妮": "Onyxia",
    # Rollen / Slang (multi-lang -> en)
    "坦克": "tank",
    "奶": "healer",
    "法师": "mage",
    "lfg": "looking for group",
    "lfm": "looking for more",
    "ony": "Onyxia",
}

GLOSSARY_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "glossary.json")
try:
    with open(GLOSSARY_PATH, "r", encoding="utf-8") as _f:
        GLOSSARY.update(json.load(_f))
except (FileNotFoundError, ValueError):
    pass


def glossary_hint(text):
    """Liefert die im Text vorkommenden Glossar-Eintraege als Prompt-Zusatz
    (oder '' wenn keiner passt). Match case-insensitiv."""
    low = text.lower()
    hits = [f"{term} = {trans}" for term, trans in GLOSSARY.items() if term.lower() in low]
    if not hits:
        return ""
    return (
        " Use these exact translations for World of Warcraft terms when they "
        "appear: " + "; ".join(hits) + "."
    )


def translate(text, src, dst):
    """Ruft Claude auf und gibt den uebersetzten Text zurueck (raises bei Fehler)."""
    system = (
        f"You are a translation engine for World of Warcraft chat. "
        f"Translate the user's message from {lang_name(src)} to {lang_name(dst)}. "
        f"Output ONLY the translation, nothing else — no quotes, no notes, no preamble. "
        f"Keep player names, item links (text in brackets), numbers and emotes unchanged. "
        f"If the text is already in {lang_name(dst)}, return it unchanged."
        + glossary_hint(text)
    )
    body = json.dumps({
        "model": MODEL,
        "max_tokens": 1024,
        "system": system,
        "messages": [{"role": "user", "content": text}],
    }).encode("utf-8")

    data = _call_claude(body)
    # Messages-API: {"content":[{"type":"text","text":"..."}], "usage":{...}}
    parts = [b.get("text", "") for b in data.get("content", []) if b.get("type") == "text"]
    usage = data.get("usage", {})
    return "".join(parts).strip(), usage


def _call_claude(body):
    """POSTet an die Claude-API und gibt das geparste JSON zurueck.
    Wiederholt bei transienten Fehlern (Overload/Rate-Limit/Netzwerk)."""
    req = urllib.request.Request(
        ANTHROPIC_URL, data=body, method="POST",
        headers={
            "x-api-key": API_KEY,
            "anthropic-version": "2023-06-01",
            "content-type": "application/json",
        },
    )
    attempts = len(RETRY_BACKOFF) + 1
    for i in range(attempts):
        try:
            with urllib.request.urlopen(req, timeout=25) as resp:
                return json.loads(resp.read().decode("utf-8"))
        except urllib.error.HTTPError as e:
            # 4xx/5xx: nur transiente Codes wiederholen, Rest sofort weiterreichen.
            if e.code not in RETRY_STATUS or i == attempts - 1:
                raise
            print(f"[retry] claude {e.code}, Versuch {i + 1}/{attempts}")
        except urllib.error.URLError as e:
            # Netzwerkblip (DNS/Connection): wiederholen bis Versuche aus sind.
            if i == attempts - 1:
                raise
            print(f"[retry] netzwerk {e.reason}, Versuch {i + 1}/{attempts}")
        time.sleep(RETRY_BACKOFF[i])


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
            src = req.get("from", "auto")
            dst = req.get("to", "en")
            if not text:
                self._send({"error": "empty text"}, 400)
                return
            cached = CACHE.get(text, src, dst)
            if cached is not None:
                print(f"[cache] {src}->{dst}: {text[:40]!r}")
                self._send({"translation": cached, "creditsRemaining": 99999999})
                return
            out, usage = translate(text, src, dst)
            CACHE.put(text, src, dst, out)
            total = STATS.add(usage.get("input_tokens", 0), usage.get("output_tokens", 0))
            print(f"[ok] {src}->{dst}: {text[:40]!r} -> {out[:40]!r}  (~${total:.4f} gesamt)")
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
    print(f"Cache: {len(CACHE)} Eintraege geladen aus {CACHE_PATH}")
    print(f"Usage bisher: {STATS.summary()}")
    print("Strg+C zum Beenden.")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        print("\nbeendet.")


if __name__ == "__main__":
    main()
