# WoWTranslate → Claude

<p align="center">
  <strong>Real-time chat translation for World of Warcraft 1.12</strong><br>
  Break the language barrier on multilingual WoW 1.12 servers — powered by your own Claude API key
</p>

<p align="center">
  <img src="https://img.shields.io/badge/WoW-1.12-blue" alt="WoW 1.12">
  <img src="https://img.shields.io/badge/backend-Claude-orange" alt="Claude backend">
  <img src="https://img.shields.io/badge/license-MIT-green" alt="MIT License">
</p>

---

> **This is a fork.** It replaces the original paid cloud backend with a small **local proxy** that calls the
> [Claude Messages API](https://docs.anthropic.com/en/api/messages). The in-game DLL is unchanged in behaviour —
> it just talks to `127.0.0.1` instead of a remote server. There is **no subscription and no per-key billing**:
> you bring your own `ANTHROPIC_API_KEY` and pay Anthropic's normal API rates (a few cents a month for chat).
>
> Original project: [sanjaygbhat/wow-translate](https://github.com/sanjaygbhat/wow-translate).
> German implementation notes: [`CLAUDE_HOOK.md`](CLAUDE_HOOK.md).

---

## ✨ Features

| Feature | Description |
|---------|-------------|
| 🌍 **Multi-Language** | Chinese, Japanese, Korean, Russian, German, … → English (and reverse) |
| 🤖 **Your Claude key** | Runs against the Claude Messages API with your own key — no third-party service in the middle |
| 💸 **Pay-per-use** | Only Anthropic's API cost; with `claude-haiku-4-5` that's typically cents per month |
| ⚡ **Instant Cache** | Previously seen translations are instant and free (no API call) |
| 💬 **Outgoing Translation** | Type in English, send in Chinese (or other languages) |
| 🔗 **Hyperlink Safe** | Player names, items, and quests stay clickable |
| 🗺️ **Minimap Button** | One-click access to settings, draggable around the minimap |
| 📺 **Channel Filtering** | Choose exactly which channels get translated |
| 💤 **AFK Auto-Pause** | Pauses translation while you're AFK to save API calls |

---

## 📋 Requirements

- **WoW 1.12** client with a DLL loader that reads `dlls.txt` (vanillafixes, etc.).
- **SuperWoW** loaded — it provides the `UnitXP` function the DLL uses to talk to the addon.
  Verify in-game: `/run print(UnitXP and "ok" or "missing")`.
- **An Anthropic API key** (`ANTHROPIC_API_KEY`) for the local proxy.
- **Python 3** on the host that runs the proxy. On Linux/Wine the proxy runs on the host and
  the WoW client reaches it over loopback automatically.

---

## 🚀 Quick Start

### 1. Get the DLL + Addon (built via GitHub Actions — no local compiler needed)

1. Fork/push this repo to your own GitHub account.
2. **Actions** tab → workflow **“Build & Package WoWTranslate”** → builds automatically on push to `main`
   (or run it manually). It compiles with MSVC as **Win32 / 32-bit**, matching WoW 1.12.
3. Download the artifact **`WoWTranslate-v<run-number>`** — it contains `WoWTranslate.dll` plus the
   `Interface/` folder.

### 2. Install into WoW

```
YourWoWFolder/
├── WoW.exe
├── WoWTranslate.dll        ← from the artifact
├── dlls.txt                ← add the line "WoWTranslate.dll"
└── Interface/
    └── AddOns/
        └── WoWTranslate/   ← from the artifact
```

> If `dlls.txt` doesn't exist, create it and put `WoWTranslate.dll` on the first line.

### 3. Start the proxy (on the host)

```bash
export ANTHROPIC_API_KEY=sk-ant-...
python3 proxy/claude_translate_proxy.py
```

Listens on `127.0.0.1:8787`. Want it to start automatically with the game? See
[Auto-start the proxy](#-auto-start-the-proxy) below.

### 4. Configure in-game

```
/wt key whatever     ← any dummy value; the proxy ignores the key, but the addon
                       wants one set
/wt show             ← pick languages / channels
```

**Done!** A minimap button (scroll icon) appears — click it for settings. Chat now shows up translated.
Default direction is incoming `zh→en`, outgoing `en→zh`; change it via the config
(`WoWTranslateDB.incomingToLang` etc.) to e.g. `de`.

---

## 📖 Commands

| Command | Description |
|---------|-------------|
| `/wt show` | Open configuration panel |
| `/wt on` / `/wt off` | Enable/disable translation |
| `/wt key <key>` | Set the API key the addon stores (dummy is fine with this fork) |
| `/wt status` | Show status |
| `/wt test 你好` | Test translation |
| `/wt outgoing on` | Enable outgoing translation |
| `/wt clearcache` | Clear translation cache |

---

## 🔧 How It Works

```
WoW client (DLL)  ──HTTP──►  local proxy (127.0.0.1:8787)  ──HTTPS──►  Claude Messages API
       ▲                                                                      │
       └──────────────────── translated text ◄───────────────────────────────┘
```

1. **Glossary / Cache** — WoW terms and previously seen messages resolve instantly and for free.
2. **Proxy** — new text is POSTed to the local proxy, which ignores the dummy key, builds a prompt and
   calls Claude.
3. **Claude** — returns the translation; only this step uses your Anthropic credits.

---

## 🔌 Auto-start the proxy

So you don't have to launch the proxy by hand each time. Works for any user, no hardcoded paths.

**Automatic (Lutris):**

```bash
proxy/install-lutris-autostart.sh
```

Finds your WoW/OctoWoW config in `~/.config/lutris/games/` and registers `proxy/ensure-proxy.sh`
as the `prelaunch_command` (with backup, idempotent).

**Manual / universal (any distro, any launcher):**
In Lutris: game → gear icon → **System options** → “Run a script before launch” → point it at
`proxy/ensure-proxy.sh`.

`ensure-proxy.sh` only starts the proxy if it isn't already running and exits immediately, so it
never blocks the game launch.

---

## 🎛️ Configuration

In `proxy/claude_translate_proxy.py`:

- **`MODEL`** — default `claude-haiku-4-5` (fast + cheap, ideal for chat). Use `claude-sonnet-4-6`
  for higher-quality translations.
- **`LISTEN_PORT`** — must match the port the DLL uses (`serverPort`, default `8787`).

What the fork changed vs. upstream — `dll/src/translator_core.cpp` (3 lines):
`serverHost → 127.0.0.1`, `serverPort → 8787`, and `WINHTTP_FLAG_SECURE → 0` (plain HTTP instead of
HTTPS, so no TLS cert is needed for the loopback hop).

---

## ❓ Troubleshooting

| Problem | Solution |
|---------|----------|
| `UnitXP` missing | SuperWoW isn't loaded — nothing works without it. Check `/run print(UnitXP and "ok" or "missing")` |
| DLL not loading | Ensure `WoWTranslate.dll` is next to `WoW.exe` and listed in `dlls.txt`. Test: `/run print(UnitXP("WoWTranslate","ping"))` should print `pong` |
| No translations, proxy shows nothing | Confirm the DLL loaded (see above) and that the proxy is running on the same port |
| Garbled characters (mojibake) | Most servers (Turtle WoW etc.) use UTF-8 and are fine. A Latin1/Western codepage server can mangle special characters |
| Launcher issues | Run `WoW.exe` directly instead of through a launcher |

---

## 🛠️ Building from Source (locally)

<details>
<summary>For contributors</summary>

CI (GitHub Actions) is the recommended path. To build locally on Windows:

**Requirements:** Windows, Visual Studio 2022, CMake 3.20+

```bash
cd dll && mkdir build && cd build
cmake .. -G "Visual Studio 17 2022" -A Win32
cmake --build . --config Release
```

Output: `dll/build/bin/Release/WoWTranslate.dll`

</details>

---

## 📄 License

MIT License. Forked from [sanjaygbhat/wow-translate](https://github.com/sanjaygbhat/wow-translate).

---

<p align="center">
  <sub>Made for the WoW 1.12 community</sub>
</p>
