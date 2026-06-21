# WoWTranslate → Claude

Real-time chat translation for World of Warcraft 1.12, talking to the Claude API
through a small local proxy instead of a paid cloud service.

## What this is

A fork of [sanjaygbhat/wow-translate](https://github.com/sanjaygbhat/wow-translate).
The original sends chat to a commercial cloud backend. This fork points the in-game
DLL at a local proxy (`127.0.0.1:8787`) that calls the
[Claude Messages API](https://platform.claude.com/docs/en/api/messages) with your own
Anthropic API key. The DLL behaves the same; only the endpoint changed.

What that means in practice:

- You run the proxy yourself and use your own Anthropic key.
- Billing is pay-per-use directly to Anthropic — there is no separate subscription for
  this addon. See [Getting an API key](#getting-an-api-key-step-by-step) and
  [Cost](#cost) for the actual setup and prices.
- Incoming chat (e.g. Chinese → English) is translated for you to read. Outgoing
  translation (your text → another language) is optional and off by default.

## Requirements

- A **WoW 1.12** client with a DLL loader that reads `dlls.txt` (vanillafixes, etc.).
- **SuperWoW** loaded — it provides the `UnitXP` function the DLL uses to talk to the
  addon. Verify in-game: `/run print(UnitXP and "ok" or "missing")`.
- **Python 3** on the machine that runs the proxy. On Linux/Wine the proxy runs on the
  host and the WoW client reaches it over loopback automatically.
- An **Anthropic account and API key** (next section).

## Getting an API key (step by step)

The proxy needs one Anthropic API key. Beginner-friendly walkthrough:

1. Go to **[platform.claude.com](https://platform.claude.com/)** (the old
   `console.anthropic.com` redirects here) and sign up — *Continue with Google* or email.
2. When asked **"How will you use the Claude API?"**, choose **Individual**.
3. **Buy usage credits:** pick **$5** ("Trying it out"). Adding credit requires a billing
   address and a **credit card**.
   - **Important: do NOT enable auto-reload** — leave it off. With auto-reload off, your
     card can never be charged again, so the $5 is a hard ceiling. It lasts a very long
     time for chat.
4. In the left sidebar open **API keys → Create key**, name it (e.g. `wowtranslate`), and
   **copy the `sk-ant-...` value** — it is shown only once.

That key is what the proxy uses. The in-game `/wt key` field is a separate dummy this fork
ignores.

### Cost

Pay-per-use, no subscription. The default model `claude-haiku-4-5` is **$1 per million
input tokens** / **$5 per million output tokens**. A chat line is only a few dozen tokens,
and the proxy avoids needless calls (local cache, glossary, and a language pre-filter that
passes through text already in your language), so real-world use is very cheap. Because
the balance is prepaid and auto-reload is off, you can never spend more than you loaded.

### Using the key with the proxy

Either export it for one session:

```bash
export ANTHROPIC_API_KEY=sk-ant-...
python3 proxy/claude_translate_proxy.py
```

Or store it once so `proxy/start-proxy.sh` picks it up (kept out of shell history and
`ps` output):

```bash
mkdir -p ~/.config/wowtranslate
read -rs K && (umask 077; printf '%s' "$K" > ~/.config/wowtranslate/anthropic.key) && unset K
proxy/start-proxy.sh
```

### Sharing a key with a friend

All keys you create bill to **your** account, so you can hand a friend a key and their
proxy will use it. What actually bounds the cost:

- **Your prepaid balance is the only hard cap.** With auto-reload off, total spend across
  every key can never exceed what you loaded (e.g. $5). This is the real safety net.
- For a **separate, independently revocable key per person** (and per-person cost
  tracking), create a **Workspace**: Console → **Settings → Workspaces → Create**, switch
  to it with the top-left selector, then make the key on the **API keys** page. (The
  Dashboard always shows the org-wide overview, which is why it looks like it "snaps back"
  to Default — that's normal; the API keys / Cost / Logs pages do respect the selected
  workspace.)
- A workspace's **Limits** tab offers a **spend notification** (email alert at, say, $2)
  and **rate limits** — but note these are **alerts/throttles, not a guaranteed hard
  stop**. There is currently no reliable "$2 then cut off" per-key cap in the Console; the
  dependable limit is the prepaid balance above.
- You can **revoke** any key anytime: API keys → `⋯` → delete.

References: [Rate & spend limits](https://platform.claude.com/docs/en/api/rate-limits),
[Workspaces](https://platform.claude.com/docs/en/manage-claude/workspaces).

## Quick start

### 1. Get the DLL + addon (built via GitHub Actions — no local compiler needed)

1. Fork/push this repo to your own GitHub account.
2. **Actions** tab → workflow **"Build & Package WoWTranslate"** → it builds on push to
   `main` (or run it manually), compiling with MSVC as Win32 / 32-bit to match WoW 1.12.
3. Download the artifact **`WoWTranslate-v<run-number>`** — it contains `WoWTranslate.dll`
   plus the `Interface/` folder.

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

If `dlls.txt` doesn't exist, create it and put `WoWTranslate.dll` on the first line.

### 3. Start the proxy (on the host)

Quick way:

```bash
export ANTHROPIC_API_KEY=sk-ant-...
python3 proxy/claude_translate_proxy.py
```

Or use `proxy/start-proxy.sh`, which reads the key from
`~/.config/wowtranslate/anthropic.key` (so it never lands in your shell history or the
repo) and keeps it out of `ps` output. The proxy listens on `127.0.0.1:8787`. To launch
it automatically with the game, see [Auto-start the proxy](#auto-start-the-proxy).

### 4. Configure in-game

```
/wt key whatever     the addon requires a key field; this fork ignores its value
/wt show             pick languages and channels
```

The real key is the `ANTHROPIC_API_KEY` on the proxy — the in-game `/wt key` is just a
dummy the addon insists on. A minimap button (scroll icon) appears: left-click opens
settings, right-click is a quick switch for the outgoing reply language. Default
direction is incoming `zh → en`; outgoing translation is off until you enable it.

## Commands

| Command | Description |
|---------|-------------|
| `/wt show` | Open the configuration panel |
| `/wt on` / `/wt off` | Enable/disable translation |
| `/wt key <key>` | Set the stored key field (dummy value is fine with this fork) |
| `/wt status` | Show status |
| `/wt test 你好` | Test a translation |
| `/wt outgoing on` / `off` | Toggle translating your own outgoing messages |
| `/wt clearcache` | Clear the in-game translation cache |

## How it works

```
WoW client (DLL)  --HTTP-->  local proxy (127.0.0.1:8787)  --HTTPS-->  Claude Messages API
       ^                                                                     |
       +------------------- translated text <---------------------------------+
```

1. The DLL sends each eligible chat line to the local proxy.
2. The proxy resolves it locally where possible (cache hit, or a language pre-filter that
   passes text already in the target language straight through) and otherwise calls Claude.
3. Only an actual Claude call uses credits. A glossary maps WoW terms (raids, bosses,
   class names, including Turtle-WoW content) to their canonical names.

## Auto-start the proxy

So you don't have to launch it by hand. Works for any user, no hardcoded paths.

**Automatic (Lutris):**

```bash
proxy/install-lutris-autostart.sh
```

Finds your WoW/OctoWoW config in `~/.config/lutris/games/` and registers
`proxy/ensure-proxy.sh` as the `prelaunch_command` (with backup, idempotent).

**Manual / universal (any distro, any launcher):**
In Lutris: game → gear icon → **System options** → "Run a script before launch" → point
it at `proxy/ensure-proxy.sh`. It starts the proxy only if it isn't already running and
exits immediately, so it never blocks the game launch.

## Configuration

In `proxy/claude_translate_proxy.py`:

- **`MODEL`** — default `claude-haiku-4-5` (fast and cheap). Use `claude-sonnet-4-6` for
  higher-quality translations at higher cost.
- **`LISTEN_PORT`** — must match the port the DLL uses (`serverPort`, default `8787`).
- **`TRANSLATE_WHEN_UNSURE`** — when language detection is unsure, `False` (default)
  passes the text through untouched; `True` sends it to Claude anyway.

The fork's change vs. upstream is three lines in `dll/src/translator_core.cpp`:
`serverHost → 127.0.0.1`, `serverPort → 8787`, and `WINHTTP_FLAG_SECURE → 0` (plain HTTP
for the loopback hop, so no TLS cert is needed).

## Troubleshooting

| Problem | Solution |
|---------|----------|
| `UnitXP` missing | SuperWoW isn't loaded — nothing works without it. Check `/run print(UnitXP and "ok" or "missing")` |
| DLL not loading | Ensure `WoWTranslate.dll` is next to `WoW.exe` and listed in `dlls.txt`. Test: `/run print(UnitXP("WoWTranslate","ping"))` should print `pong` |
| No translations, proxy shows nothing | Confirm the DLL loaded (above) and that the proxy is running on the same port |
| Your own messages go out garbled/empty | Outgoing translation is on and producing a script your client can't render (e.g. Chinese). Turn it off with `/wt outgoing off`, or pick a Latin-script reply language |
| Garbled incoming characters (mojibake) | Most servers (Turtle WoW etc.) use UTF-8 and are fine. A Latin1/Western codepage server can mangle special characters |
| Launcher issues | Run `WoW.exe` directly instead of through a launcher |

## Building from source (locally)

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

## License

MIT License. Forked from [sanjaygbhat/wow-translate](https://github.com/sanjaygbhat/wow-translate).
