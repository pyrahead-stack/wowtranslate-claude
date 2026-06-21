# WoWTranslate → Claude

Real-time chat translation for World of Warcraft 1.12. Chat is translated through the
Claude API via a small local proxy, so you use your own API key instead of a paid service.

A fork of [sanjaygbhat/wow-translate](https://github.com/sanjaygbhat/wow-translate): the
original sends chat to a commercial cloud backend; this version talks to a local proxy
and your own Anthropic key.

## What it does

- Translates **incoming** chat into your language — **any** source language is
  auto-detected (Chinese, Russian, French, German, …). A small `[DE]`/`[CN]` tag shows
  what the original was (toggle with `/wt tag off`).
- **Multilingual?** Tick the languages you already read under **"Don't translate"** —
  those are shown as-is; everything else is translated.
- **Outgoing** translation (your messages → another language) is optional and off by
  default. A reply to a whisper automatically goes out in the language that person used.
- **Pay-per-use** against your own API key — no subscription. Set an optional monthly
  **budget** (`~/.config/wowtranslate/budget`); once reached it stops calling the API and
  serves translations from its offline cache.
- Only new text is sent out; repeats, your own languages, and non-text (links/numbers)
  are handled locally at no cost.

## Requirements

- A **WoW 1.12** client with a DLL loader that reads `dlls.txt` (e.g. vanillafixes).
- **SuperWoW** loaded — it provides the `UnitXP` function the addon needs.
  Check in-game: `/run print(UnitXP and "ok" or "missing")`.
- **Python 3** to run the proxy (the same machine as the game is fine).
- An **Anthropic API key** (next section).

## Get an API key

1. Go to **[platform.claude.com](https://platform.claude.com/)** (the old
   `console.anthropic.com` redirects here) and sign up.
2. When asked **"How will you use the Claude API?"**, choose **Individual**.
3. Buy usage credits → **$5**. Adding credit needs a billing address and a credit card.
   - **Do NOT enable auto-reload** — leave it off, so your card can't be charged again and
     the $5 is a hard ceiling. It lasts a very long time.
4. Open **API keys → Create key**, name it (e.g. `wowtranslate`), and **copy the
   `sk-ant-...` value** — it is shown only once.

This key goes into the proxy (see [Run](#run)). Cost is tiny — a chat line is a few dozen
tokens and the proxy avoids needless calls, so $5 lasts a very long time. Since credit is
prepaid with auto-reload off, you can never spend more than you loaded.

### Sharing with a friend

Keys bill to **your** account, so you can hand a friend a key and they just run the proxy
with it. The dependable cost cap is your prepaid balance (auto-reload off) — total spend
across all keys can never exceed it. For a separate, revocable key per person (and
per-person cost tracking), create a **Workspace** (Console → Settings → Workspaces) and
create the key there. Revoke any key anytime under **API keys**.

> Note: the Console has no reliable per-key "$X then stop" cap — its workspace spend
> limits are email alerts/throttles, not hard stops. The prepaid balance is the real limit.

## Install

1. Download the latest **[release ZIP](https://github.com/pyrahead-stack/wowtranslate-claude/releases/latest)**
   (or build it yourself — see the end of this file).
2. Copy the contents into your WoW folder:

```
YourWoWFolder/
├── WoW.exe
├── WoWTranslate.dll                 ← from the ZIP
├── dlls.txt                         ← add a line: WoWTranslate.dll
└── Interface/AddOns/WoWTranslate/   ← from the ZIP
```

If `dlls.txt` doesn't exist, create it with `WoWTranslate.dll` on the first line.

## Run

**1. Start the proxy** with your key. Quickest:

```bash
export ANTHROPIC_API_KEY=sk-ant-...
python3 proxy/claude_translate_proxy.py
```

Or store the key once so it stays out of your shell history:

```bash
mkdir -p ~/.config/wowtranslate
read -rs K && (umask 077; printf '%s' "$K" > ~/.config/wowtranslate/anthropic.key) && unset K
proxy/start-proxy.sh
```

The proxy must be running while you play. To launch it together with the game, see
[Auto-start](#auto-start-optional).

**2. In-game**, type `/wt key x` once (the addon requires a key field; this fork ignores
its value — the real key is on the proxy), then `/wt show` to pick languages and channels.

A minimap button appears: **left-click** opens settings, **right-click** quickly switches
the outgoing reply language. Default is incoming Chinese → English; outgoing translation
stays off until you turn it on.

## Commands

| Command | Description |
|---------|-------------|
| `/wt show` | Open the settings panel |
| `/wt on` / `/wt off` | Enable/disable translation |
| `/wt key <key>` | Set the stored key field (any value works with this fork) |
| `/wt status` | Show status |
| `/wt test 你好` | Test a translation |
| `/wt outgoing on` / `off` | Toggle translating your own outgoing messages |
| `/wt clearcache` | Clear the in-game translation cache |

## Auto-start (optional)

The proxy has to be running while you play. Either start it by hand each time, or have
your game launcher start it first via its "run before launch" hook — point that hook at
`proxy/ensure-proxy.sh` (it only starts the proxy if it isn't already running, so it's
safe to run every time).

If you use **Lutris**, a helper sets this up for you:

```bash
proxy/install-lutris-autostart.sh
```

## Settings (optional)

In `proxy/claude_translate_proxy.py`:

- **`LISTEN_PORT`** — proxy port (default `8787`; must match the DLL).
- **`TRANSLATE_WHEN_UNSURE`** — `False` (default) passes text through when the language is
  unclear; `True` sends it to be translated anyway.

## Troubleshooting

| Problem | Solution |
|---------|----------|
| `UnitXP` missing | SuperWoW isn't loaded — nothing works without it. Check `/run print(UnitXP and "ok" or "missing")` |
| DLL not loading | Ensure `WoWTranslate.dll` is next to `WoW.exe` and listed in `dlls.txt`. Test: `/run print(UnitXP("WoWTranslate","ping"))` should print `pong` |
| No translations, nothing in the proxy window | Confirm the DLL loaded (above) and that the proxy is running |
| Your own messages go out garbled/empty | Outgoing translation is on and producing a script your client can't display (e.g. Chinese). Turn it off with `/wt outgoing off`, or pick a Latin-script reply language |
| Garbled incoming characters | Most servers use UTF-8 and are fine. A server on a Western (Latin1) codepage can mangle special characters |

## Build from source

<details>
<summary>For contributors</summary>

Release ZIPs are produced by GitHub Actions on each version tag. To build the DLL locally
on Windows:

**Requirements:** Windows, Visual Studio 2022, CMake 3.20+

```bash
cd dll && mkdir build && cd build
cmake .. -G "Visual Studio 17 2022" -A Win32
cmake --build . --config Release
```

Output: `dll/build/bin/Release/WoWTranslate.dll`.

The only DLL change vs. upstream is three lines in `dll/src/translator_core.cpp`:
`serverHost → 127.0.0.1`, `serverPort → 8787`, and `WINHTTP_FLAG_SECURE → 0` (plain HTTP
for the local hop, so no TLS cert is needed).

</details>

## License

MIT License. Forked from [sanjaygbhat/wow-translate](https://github.com/sanjaygbhat/wow-translate).
