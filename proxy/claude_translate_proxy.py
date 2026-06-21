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
import re
import time
import threading
import urllib.request
import urllib.error
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# ----- Konfiguration -------------------------------------------------------
LISTEN_HOST = "127.0.0.1"
LISTEN_PORT = 8787
MODEL = "claude-haiku-4-5"          # schnell + guenstig, ideal fuer Chat
# Bei unsicherer Spracherkennung: True = trotzdem an Claude schicken,
# False = Text 1:1 durchreichen (spart Calls, Standard).
TRANSLATE_WHEN_UNSURE = False
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


def _load_budget():
    """Optionales Selbstlimit in USD pro Monat. Quelle (Vorrang):
    Env WT_BUDGET, sonst Datei ~/.config/wowtranslate/budget. None = unbegrenzt."""
    v = os.environ.get("WT_BUDGET")
    if not v:
        try:
            with open(os.path.expanduser("~/.config/wowtranslate/budget"),
                      "r", encoding="utf-8") as f:
                v = f.read().strip()
        except (FileNotFoundError, OSError):
            return None
    try:
        v = float(v)
    except (TypeError, ValueError):
        return None
    return v if v > 0 else None


BUDGET = _load_budget()  # USD/Monat oder None (unbegrenzt)


class UsageStats:
    """Zaehlt API-Calls/Tokens persistent mit und schaetzt die Kosten — pro Monat.
    Nur echte Claude-Calls landen hier — Cache-Hits/Skips kosten nichts.
    Beim Monatswechsel werden die Zaehler beim naechsten add() zurueckgesetzt."""

    def __init__(self, path):
        self.path = path
        self.lock = threading.Lock()
        self.data = {"month": "", "calls": 0, "input_tokens": 0, "output_tokens": 0}
        try:
            with open(path, "r", encoding="utf-8") as f:
                self.data.update(json.load(f))
        except (FileNotFoundError, ValueError):
            pass

    @staticmethod
    def _month():
        return time.strftime("%Y-%m")

    def _cost(self, intok, outtok):
        pin, pout = PRICING.get(MODEL, PRICING["claude-haiku-4-5"])
        return (intok * pin + outtok * pout) / 1_000_000

    def add(self, input_tokens, output_tokens):
        with self.lock:
            if self.data.get("month") != self._month():
                self.data["month"] = self._month()
                self.data["calls"] = 0
                self.data["input_tokens"] = 0
                self.data["output_tokens"] = 0
            self.data["calls"] += 1
            self.data["input_tokens"] += input_tokens
            self.data["output_tokens"] += output_tokens
            tmp = self.path + ".tmp"
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump(self.data, f)
            os.replace(tmp, self.path)
            return self._cost(self.data["input_tokens"], self.data["output_tokens"])

    def snapshot(self):
        """Aktuelle Monatszahlen (calls/in/out/cost). Stale Monat -> Nullen."""
        with self.lock:
            if self.data.get("month") != self._month():
                return {"calls": 0, "in": 0, "out": 0, "cost": 0.0}
            i, o = self.data["input_tokens"], self.data["output_tokens"]
            return {"calls": self.data["calls"], "in": i, "out": o,
                    "cost": self._cost(i, o)}

    def cost(self):
        s = self.snapshot()
        return s["cost"]

    def summary(self):
        s = self.snapshot()
        return (f"{s['calls']} Calls, {s['in']}+{s['out']} Tokens, ~${s['cost']:.4f}"
                + (f" (Budget ${BUDGET:.2f}/Monat)" if BUDGET else ""))


STATS = UsageStats(STATS_PATH)


def credits_remaining():
    """creditsRemaining-Feld fuers Addon: bei gesetztem Budget die echten
    Restcent, sonst eine Dummy-Grosszahl (Addon meldet dann nie 'out of credits')."""
    if BUDGET is None:
        return 99999999
    return max(0, int(round((BUDGET - STATS.cost()) * 100)))

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
    # --- Raids & Dungeons: chinesischer Name -> kanonischer englischer Name
    #     (aus pfQuest/pfQuest-turtle zhCN-Locale, inkl. Turtle-Custom-Content) ---
    "熔火之心": "Molten Core",
    "黑翼之巢": "Blackwing Lair",
    "纳克萨玛斯": "Naxxramas",
    "纳克": "Naxxramas",
    "黑石深渊": "Blackrock Depths",
    "黑石塔": "Blackrock Spire",
    "斯坦索姆": "Stratholme",
    "通灵学院": "Scholomance",
    "厄运之槌": "Dire Maul",
    "血色修道院": "Scarlet Monastery",
    "死亡矿井": "The Deadmines",
    "影牙城堡": "Shadowfang Keep",
    "哀嚎洞穴": "Wailing Caverns",
    "奥达曼": "Uldaman",
    "玛拉顿": "Maraudon",
    "诺莫瑞根": "Gnomeregan",
    "剃刀沼泽": "Razorfen Kraul",
    "剃刀高地": "Razorfen Downs",
    # Turtle-WoW Custom-Raids/Dungeons
    "翡翠圣殿": "Emerald Sanctum",
    "仇恨熔炉采石场": "Hateforge Quarry",
    "卡拉赞墓穴": "Karazhan Crypt",
    "卡拉赞": "Karazhan",
    "吉尔尼斯城": "Gilneas City",
    "暴风城地牢": "Stormwind Vault",
    "龙喉居所": "Dragonmaw Retreat",
    "黑色沼泽": "The Black Morass",

    # --- Bosse: chinesischer Name -> englischer Name ---
    "拉格纳罗斯": "Ragnaros",
    "拉格": "Ragnaros",
    "奥妮克希亚": "Onyxia",
    "奥妮": "Onyxia",
    "奈法利安": "Nefarian",
    "维克多·奈法里奥斯领主": "Lord Victor Nefarius",
    "沙尔图拉": "Battleguard Sartura",
    "哈霍兰公主": "Princess Huhuran",
    "无疤者奥斯里安": "Ossirian the Unscarred",
    "黑女巫法琳娜": "Grand Widow Faerlina",
    "迈克斯纳": "Maexxna",
    "洛欧塞布": "Loatheb",
    "教官拉苏维奥斯": "Instructor Razuvious",
    "收割者戈提克": "Gothik the Harvester",
    "萨菲隆": "Sapphiron",
    "帕奇维克": "Patchwerk",
    "塔迪乌斯": "Thaddius",
    "老克": "Kel'Thuzad",
    "哈卡": "Hakkar",
    "血领主曼多基尔": "Bloodlord Mandokir",
    "高阶女祭司耶克里克": "High Priestess Jeklik",
    "迦顿男爵": "Baron Geddon",
    "加尔": "Garr",
    "焚化者古雷曼格": "Golemagg the Incinerator",
    "管理者埃克索图斯": "Majordomo Executus",
    "鲁西弗隆": "Lucifron",
    "勒什雷尔": "Broodlord Lashlayer",
    "堕落的瓦拉斯塔兹": "Vaelastrasz the Corrupt",
    "克洛玛古斯": "Chromaggus",
    "埃博诺克": "Ebonroc",
    "费尔默": "Firemaw",
    "弗莱格尔": "Flamegor",
    "艾德温·范克里夫": "Edwin VanCleef",
    "大法师阿鲁高": "Archmage Arugal",
    "赫洛德": "Herod",
    "秘法师杜安": "Arcanist Doan",
    "通灵院长·加丁": "Darkmaster Gandling",
    "瑞文戴尔男爵": "Baron Rivendare",
    "莱斯·霜语": "Ras Frostwhisper",
    "达格兰·索瑞森大帝": "Emperor Dagran Thaurissan",
    "重拳先生": "Mr. Smite",
    # Turtle-WoW Custom-Bosse
    "埃伦纽斯": "Erennius",
    "索尔纽斯": "Solnius",
    "阿拉鲁斯": "Alarus",
    "艾丝卓仕·格瑞姆弗雷姆": "Aszosh Grimflame",

    # --- Rollen / Slang (multi-lang -> en) ---
    "坦克": "tank",
    "奶": "healer",
    "奶妈": "healer",
    "法师": "mage",
    "猎人": "hunter",
    "盗贼": "rogue",
    "术士": "warlock",
    "牧师": "priest",
    "战士": "warrior",
    "德鲁伊": "druid",
    "萨满": "shaman",
    "圣骑士": "paladin",
    "组队": "looking for group",
    "求组": "looking for group",
    "公会": "guild",

    # --- Englische Abkuerzungen -> Vollname (Wortgrenzen-Match, s. unten).
    #     Bewusst nur eindeutige; mehrdeutige wie "dm"/"es" ausgelassen. ---
    "mc": "Molten Core",
    "bwl": "Blackwing Lair",
    "naxx": "Naxxramas",
    "zg": "Zul'Gurub",
    "aq40": "Temple of Ahn'Qiraj",
    "aq20": "Ruins of Ahn'Qiraj",
    "ubrs": "Upper Blackrock Spire",
    "lbrs": "Lower Blackrock Spire",
    "brd": "Blackrock Depths",
    "strat": "Stratholme",
    "scholo": "Scholomance",
    "kara": "Karazhan",
    "kt": "Kel'Thuzad",
    "ony": "Onyxia",
    "lfg": "looking for group",
    "lfm": "looking for more",
}

GLOSSARY_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "glossary.json")
try:
    with open(GLOSSARY_PATH, "r", encoding="utf-8") as _f:
        GLOSSARY.update(json.load(_f))
except (FileNotFoundError, ValueError):
    pass


def glossary_hint(text):
    """Liefert die im Text vorkommenden Glossar-Eintraege als Prompt-Zusatz
    (oder '' wenn keiner passt).

    ASCII-Begriffe (Abkuerzungen wie 'mc', 'kt') werden an Wortgrenzen geprueft,
    damit 'es' nicht in 'goes' o.ae. matcht. CJK-Begriffe haben keine Wort-
    grenzen -> einfacher Substring-Treffer."""
    low = text.lower()
    hits = []
    for term, trans in GLOSSARY.items():
        if term.isascii():
            if re.search(r"\b" + re.escape(term.lower()) + r"\b", low):
                hits.append(f"{term} = {trans}")
        elif term in text:
            hits.append(f"{term} = {trans}")
    if not hits:
        return ""
    return (
        " Use these exact translations for World of Warcraft terms when they "
        "appear: " + "; ".join(hits) + "."
    )


# ----- Spracherkennung (lokal, gratis) -------------------------------------
# Schrift-basiert (sehr sicher) fuer CJK/Kyrillisch/Hangul, Stopwoerter fuer
# lateinische Sprachen. Liefert einen Sprachcode oder None ("unsicher").
# Funktionswoerter, die in fast jedem Satz vorkommen — bewusst diskriminierend
# gewaehlt (Woerter, die mehrere Sprachen teilen, helfen wenig).
STOPWORDS = {
    # English deliberately broad: this is usually the read/target language, so the
    # more English we recognise, the more English chat we SKIP (no call, no tag).
    "en": {"the", "and", "you", "for", "are", "with", "that", "this", "what",
           "have", "not", "your", "can", "need", "anyone", "please", "where",
           "is", "it", "a", "an", "to", "of", "in", "on", "at", "or", "if",
           "im", "i", "me", "my", "we", "us", "he", "she", "they", "them",
           "do", "does", "did", "be", "was", "were", "been", "am", "has", "had",
           "will", "would", "should", "could", "but", "so", "no", "yes", "ok",
           "just", "like", "know", "see", "now", "then", "here", "there", "how",
           "when", "why", "who", "all", "any", "some", "get", "got", "want",
           "thanks", "guys", "still", "about", "really", "much", "from", "out",
           "going", "doing", "been", "into", "than", "them", "their", "there's"},
    "de": {"der", "die", "das", "und", "ist", "nicht", "ich", "wir", "ihr",
           "mit", "auf", "ein", "eine", "sind", "wo", "auch", "noch", "brauche",
           "du", "den", "dem", "noch", "mal", "schon", "hast", "kein", "war",
           "wie", "was", "wer", "warum", "hallo", "danke", "bitte", "jemand"},
    "fr": {"les", "des", "une", "est", "pas", "vous", "nous", "qui", "que",
           "avec", "pour", "oui", "bonjour", "merci", "quelqu'un", "où",
           "je", "tu", "il", "elle", "ils", "ça", "ce", "un", "et", "mais",
           "salut", "bien", "fait", "veux", "donjon", "comment", "non"},
    "es": {"los", "las", "una", "está", "qué", "por", "para", "pero", "hola",
           "gracias", "dónde", "soy", "eres", "alguien", "necesito", "sí",
           "el", "la", "un", "yo", "tú", "que", "con", "amigo", "quieres",
           "como", "muy", "bien", "no", "grupo"},
    "pt": {"não", "você", "está", "obrigado", "uma", "isso", "onde", "nós",
           "alguém", "preciso", "com", "para", "sim", "olá", "que", "por",
           "eu", "um", "uma", "bom", "como", "ajudar", "missão", "grupo"},
}


def detect_script(text):
    """Eindeutige Schrift-Erkennung (hohe Sicherheit). None = kein CJK/Cyr/Hangul."""
    for ch in text:
        o = ord(ch)
        if 0x4E00 <= o <= 0x9FFF:      # CJK Unified Ideographs
            return "zh"
        if 0x3040 <= o <= 0x30FF:      # Hiragana/Katakana
            return "ja"
        if 0xAC00 <= o <= 0xD7AF:      # Hangul
            return "ko"
        if 0x0400 <= o <= 0x04FF:      # Kyrillisch
            return "ru"
    return None


_WORD_RE = re.compile(r"[a-zà-ÿñ']+")


def detect_latin(text):
    """Stopwort-Erkennung fuer lateinische Sprachen. None bei zu kurzem Text
    oder ohne klaren Sieger (Gleichstand)."""
    words = _WORD_RE.findall(text.lower())
    if len(words) < 3:                 # zu wenig Signal
        return None
    scores = {lang: sum(1 for w in words if w in sw) for lang, sw in STOPWORDS.items()}
    ranked = sorted(scores.items(), key=lambda kv: kv[1], reverse=True)
    if ranked[0][1] == 0:              # kein einziges Funktionswort getroffen
        return None
    if ranked[0][1] == ranked[1][1]:   # Gleichstand -> unsicher
        return None
    return ranked[0][0]


def detect_lang(text):
    """Sprachcode oder None ('unsicher'). Schrift schlaegt Stopwoerter."""
    return detect_script(text) or detect_latin(text)


def parse_dst(dst_raw):
    """Zerlegt das to-Feld. Format: 'en' ODER 'en;keep=en,de,fr'.
    Liefert (target, keep_set). target ist immer in keep (en->en nie uebersetzen).
    'keep' = Sprachen, die der Nutzer versteht -> nicht uebersetzen."""
    parts = (dst_raw or "en").split(";")
    target = (parts[0].strip().lower() or "en")
    keep = {target}
    for p in parts[1:]:
        p = p.strip()
        if p.startswith("keep="):
            for c in p[5:].split(","):
                c = c.strip().lower()
                if c:
                    keep.add(c)
    return target, keep


def translate(text, src, dst):
    """Ruft Claude auf und gibt den uebersetzten Text zurueck (raises bei Fehler)."""
    system = (
        f"You are a translation engine for World of Warcraft chat. "
        f"Translate the user's message from {lang_name(src)} to {lang_name(dst)}. "
        f"Begin your output with the DETECTED SOURCE language as a 2-letter lowercase "
        f"ISO 639-1 code in double square brackets (e.g. [[fr]], [[de]], [[zh]], [[ru]], "
        f"[[no]], [[nl]]), then IMMEDIATELY the translation. Example: [[fr]]Hello there. "
        f"After that marker output ONLY the translation — no quotes, no notes, no preamble. "
        f"NEVER ask questions, explain, apologize, or add any commentary. "
        f"You are NOT a chat partner; you only transform text. "
        f"Keep player names, item links (text in brackets), numbers, URLs and emotes unchanged. "
        f"If the text is already in {lang_name(dst)}, return it unchanged (still prefix the marker)."
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
            dst, keep = parse_dst(req.get("to", "en"))  # keep = understood langs
            if not text:
                self._send({"error": "empty text"}, 400)
                return
            # Stats-Sentinel: kein Claude-Call, kostet nichts. Liefert die echten
            # Monatszahlen im translation-Feld (pipe-frei, das Addon parst sie).
            if text == "__WT_STATS__":
                s = STATS.snapshot()
                budget = BUDGET if BUDGET is not None else -1.0
                left = max(0.0, BUDGET - s["cost"]) if BUDGET is not None else -1.0
                payload = ("WTSTATS;spentusd=%.6f;calls=%d;intok=%d;outtok=%d;"
                           "budgetusd=%.6f;leftusd=%.6f"
                           % (s["cost"], s["calls"], s["in"], s["out"], budget, left))
                self._send({"translation": payload,
                            "creditsRemaining": credits_remaining()})
                return
            # Nichts Uebersetzbares? Platzhalter-URLs (http://ph.wt/N) raus, dann pruefen
            # ob ueberhaupt ein Buchstabe da ist. Nur Links/Zahlen/Symbole -> Original
            # zurueck, KEIN Claude-Call (sonst antwortet das Modell konversationell).
            stripped = re.sub(r'https?://\S+', '', text)
            if not re.search(r'[^\W\d_]', stripped):
                print(f"[skip:nichts] {text[:40]!r}")
                self._send({"translation": text, "creditsRemaining": credits_remaining()})
                return
            cached = CACHE.get(text, src, dst)
            if cached is not None:
                print(f"[cache] {src}->{dst}: {text[:40]!r}")
                self._send({"translation": cached, "creditsRemaining": credits_remaining()})
                return
            # Vorfilter: schon Zielsprache -> immer durch; unsicher -> durch,
            # sofern nicht TRANSLATE_WHEN_UNSURE. Beides spart den API-Call.
            detected = detect_lang(text)
            # Bei from=auto auch unsichere/kurze Fremdtexte uebersetzen (z.B. "Bonjour",
            # "Hola") — sonst blieben sie liegen. Sprachen, die der Nutzer versteht
            # (keep, inkl. Zielsprache), werden uebersprungen.
            twu = TRANSLATE_WHEN_UNSURE or (src == "auto")
            if (detected is not None and detected in keep) or (detected is None and not twu):
                why = ("verstanden:" + detected) if detected else "unsicher"
                print(f"[skip:{why}] ->{dst}: {text[:40]!r}")
                self._send({"translation": text, "creditsRemaining": credits_remaining()})
                return
            # Harte Budget-Grenze: ist das Monatslimit erreicht, KEIN neuer Call mehr
            # (Cache-Hits oben werden weiter bedient = Offline-Modus). Original zurueck.
            if BUDGET is not None and STATS.cost() >= BUDGET:
                print(f"[budget] Limit erreicht, kein Call: {text[:40]!r}")
                self._send({"translation": text, "creditsRemaining": 0})
                return
            out, usage = translate(text, src, dst)
            CACHE.put(text, src, dst, out)
            total = STATS.add(usage.get("input_tokens", 0), usage.get("output_tokens", 0))
            print(f"[ok] {src}->{dst}: {text[:40]!r} -> {out[:40]!r}  (~${total:.4f} Monat)")
            self._send({"translation": out, "creditsRemaining": credits_remaining()})
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
