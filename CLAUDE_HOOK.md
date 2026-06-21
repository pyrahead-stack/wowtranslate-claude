# WoWTranslate → Claude (Fork)

Ersetzt das kostenpflichtige Cloud-Backend durch einen lokalen Proxy, der die
**Claude Messages API** aufruft. Die DLL merkt davon nichts — gleiche Schnittstelle.

## Was geändert wurde
`dll/src/translator_core.cpp` (3 Zeilen):
- `serverHost` → `127.0.0.1`, `serverPort` → `8787`
- HTTP-Flag `WINHTTP_FLAG_SECURE` → `0` (Plain-HTTP statt HTTPS, spart TLS-Cert)

## Voraussetzungen
- **SuperWoW** muss geladen sein (liefert die `UnitXP`-Funktion, über die die DLL
  mit dem Addon redet). Test im Spiel: `/run print(UnitXP and "ok" or "fehlt")`.
- DLL-Loader, der `dlls.txt` liest (hast du bereits — vanillafixes etc.).

## 1. DLL bauen (GitHub Actions, kein lokaler Compiler nötig)
1. Diesen Fork in dein GitHub pushen.
2. Tab **Actions** → Workflow „Build & Package WoWTranslate" → `Run workflow`
   (oder läuft automatisch beim Push auf `main`).
   Baut mit MSVC als **Win32 (32-bit)** — passt zu WoW 1.12.
3. Artefakt `WoWTranslate-vNN` herunterladen → enthält `WoWTranslate.dll`
   + den `Interface`-Ordner.

## 2. Installieren
1. `WoWTranslate.dll` neben `WoW.exe` legen.
2. `WoWTranslate.dll` in `dlls.txt` eintragen (eine Zeile).
3. `Interface/AddOns/WoWTranslate/` ins WoW-`Interface/AddOns/` kopieren.

## 3. Proxy starten (auf dem Linux-Host)
```bash
export ANTHROPIC_API_KEY=sk-ant-...
python3 proxy/claude_translate_proxy.py
```
Läuft auf `127.0.0.1:8787`. Wine/Proton teilt sich den Loopback mit dem Host,
die DLL erreicht den Proxy also direkt.

## 4. Im Spiel
- `/wt key egal` — irgendein Dummy-Key (der Proxy ignoriert ihn, aber das Addon
  will einen gesetzt haben).
- `/wt show` — Sprachen/Channels einstellen.
- Standard-Richtung: eingehend `zh→en`, ausgehend `en→zh`. Über die Config
  (`WoWTranslateDB.incomingToLang` etc.) auf z. B. `de` änderbar.

## Autostart (Proxy startet automatisch mit dem Spiel)
Damit man den Proxy nicht jedes Mal von Hand starten muss — funktioniert fuer
jeden Nutzer, kein Hardcoding von Pfaden:

**Automatisch (Lutris):**
```bash
proxy/install-lutris-autostart.sh
```
Findet die WoW/OctoWoW-Konfig in `~/.config/lutris/games/` und traegt
`proxy/ensure-proxy.sh` als `prelaunch_command` ein (mit Backup, idempotent).

**Manuell / universell (jede Distro, jeder Launcher):**
In Lutris: Spiel → Zahnrad → **Systemoptionen** → „Skript vor dem Start
ausfuehren" → Pfad zu `proxy/ensure-proxy.sh`.

`ensure-proxy.sh` startet den Proxy nur, wenn er nicht schon laeuft, und beendet
sich sofort (blockiert den Spielstart nicht).

## Stellschrauben
- **Modell:** im Proxy `MODEL` (Default `claude-haiku-4-5`). Für bessere Qualität
  `claude-sonnet-4-6`.
- **Port:** muss in DLL (`serverPort`) und Proxy (`LISTEN_PORT`) identisch sein.

## Cache, Glossar, Retry (Proxy-Features)
- **Persistenter Cache:** `proxy/translation-cache.json` (neben dem Skript, per
  `.gitignore` ausgeschlossen). Bereits übersetzte Zeilen sind danach über alle
  Chars/Neustarts hinweg sofort & kostenlos. Datei einfach löschen zum Leeren.
- **WoW-Glossar:** eingebaute Begriffsliste (Boss-/Raid-/Slang-Namen) sorgt für
  korrekte Übersetzungen (`老克 → Kel'Thuzad` statt „Old gram"). Nur Begriffe,
  die im Text vorkommen, landen im Prompt → kaum Token-Kosten. Erweiterbar über
  `proxy/glossary.json` (`{"begriff": "übersetzung"}`, wird über die Defaults
  gemerged).
- **Retry:** bei Overload/Rate-Limit/Netzwerkblip (429/500/503/529) wiederholt der
  Proxy automatisch (2×, Backoff 1s→2s). Echte Fehler (z. B. 400/401) werden
  sofort weitergereicht.

## Bekannte Stolpersteine
- **`UnitXP` fehlt** → SuperWoW nicht geladen. Ohne das geht gar nichts.
- **Encoding:** Turtle-WoW & Co. nutzen UTF-8 (passt). Sollte der Server eine
  Westeuropa-Codepage (Latin1) fahren, kann es bei Sonderzeichen Mojibake geben.
- **Keine Übersetzung, Proxy zeigt nichts:** prüfen ob DLL überhaupt lädt
  (`/run print(UnitXP("WoWTranslate","ping"))` → soll `pong` sein).
