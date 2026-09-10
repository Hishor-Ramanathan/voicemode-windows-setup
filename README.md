# VoiceMode on native Windows

[VoiceMode](https://github.com/mbailey/voicemode) gives Claude Code a voice — you talk, it
talks back. Its README lists "Windows (native or WSL)" as supported, but the official
installer refuses to run there:

```python
# installer/voicemode_install/system.py
raise RuntimeError("Unsupported operating system")   # anything but darwin/linux
```

The **runtime** is fine on Windows; only the installer is not. This repo is the hand-wired
setup that works: a venv, two Docker containers, and one alias file.

No WSL, deliberately — VoiceMode's own docs still mark the WSLg PulseAudio mic bridge
"coming soon", while `sounddevice` on native Windows reaches the mic through WASAPI
directly.

---

## Start talking

Once it is set up, [`voice.ps1`](voice.ps1) is the entire interface:

```powershell
voice.ps1 talk     # THIS terminal gets voice. Starts the engines if they are down.
voice.ps1 off      # engines down, ~1.5 GB back. Stays off across reboots.
voice.ps1 on       # engines back up
voice.ps1          # status
```

`talk` opens a Claude session that **speaks every reply**. There is no skill to enable and
no phrase to say first. The first reply takes **~8 seconds** before you hear anything —
Kokoro is slow to its first chunk on CPU, slower when cold.

To move voice to another window, run `talk` there. A terminal started with a plain
`claude` has no voicemode tools at all and cannot start talking at you. There is no
mid-session switch: a session's MCP servers are fixed at launch.

**To mute yourself, use the headset's own mute button** — boom arm up, or the button on
the earcup. Hardware mute cuts the mic below the OS, so nothing running on the machine can
override it, and it covers every app rather than just this one.

Not set up yet? Point a coding agent at [`AGENTS.md`](AGENTS.md) — the same steps below as
an executable checklist with a verification gate on each. To do it by hand, read on.

---

## What you end up with

```
Claude Code
    │  stdio (MCP)
    ▼
voicemode.exe  ── venv at C:\Users\<you>\voicemode\.venv
    │                └── sounddevice → WASAPI → your mic & speakers
    │
    ├── STT  http://127.0.0.1:2022/v1 ──► Docker: speaches (faster-whisper-small)
    └── TTS  http://127.0.0.1:8880/v1 ──► Docker: kokoro-fastapi (Kokoro-82M)
```

Both URLs are VoiceMode's built-in defaults, so once the containers listen on those ports
there is nothing to configure. Everything runs locally — no OpenAI key, no audio leaving
the machine.

Verified against: VoiceMode 8.12.0, Python 3.13.14, Windows 11, Docker Desktop.

---

## Setup

**Prerequisites:** Python 3.13 (3.11+ works), Docker Desktop with the WSL2 backend set to
start at login, ~4 GB disk, and a working mic with
`Settings → Privacy → Microphone → let desktop apps access` on. No admin rights needed
anywhere below.

### 1. The venv

`pip install voice-mode` fails on Windows because of one dependency: **`simpleaudio`**,
which has no wheels past cp38 and needs a C compiler. It is only a *fallback* playback
path inside a `try/except` in `voice_mode/core.py` — `sounddevice` handles playback and
`simpleaudio` is never reached. So install with `--no-deps` and list the rest by hand.

```powershell
mkdir $HOME\voicemode
cd $HOME\voicemode
py -3.13 -m venv .venv
.\.venv\Scripts\Activate.ps1

pip install --no-deps voice-mode
pip install aiohttp audioop-lts click fastmcp httpx keyring numpy openai `
            psutil pydub pyyaml scipy sounddevice uv webrtcvad-wheels
```

That is voice-mode's full dependency list minus `simpleaudio`. `audioop-lts` matters on
3.13: the stdlib `audioop` module was removed in that release
([PEP 594](https://peps.python.org/pep-0594/)) and `pydub` imports it. On 3.12 or older
you can leave it out.

Check: `.\.venv\Scripts\voicemode.exe --version`.

### 2. ffmpeg

`pydub` shells out to ffmpeg for MP3. Grab a static build, unzip so `ffmpeg.exe` sits in
`$HOME\voicemode\ffmpeg\`, and put that folder on your **user** PATH:

```powershell
[Environment]::SetEnvironmentVariable(
  "Path",
  [Environment]::GetEnvironmentVariable("Path", "User") + ";$HOME\voicemode\ffmpeg",
  "User")
```

Check: `ffmpeg -version` in a **new** shell.

### 3. Speech-to-text — speaches

[speaches](https://github.com/speaches-ai/speaches) serves faster-whisper behind an
OpenAI-compatible `/v1/audio/transcriptions`.

**Download the model on the host first.** The container runs with `HF_HUB_OFFLINE=1`, so
it never reaches Hugging Face itself — see
[Why the model is downloaded on the host](#why-the-model-is-downloaded-on-the-host).

```powershell
mkdir $HOME\voicemode\hf-cache
$env:HF_HUB_CACHE = "$HOME\voicemode\hf-cache"
.\.venv\Scripts\hf.exe download Systran/faster-whisper-small
```

**Then fix the model alias — this is the step that costs an hour when skipped.** VoiceMode
asks for a model literally named `whisper-1` (OpenAI's name, meaningless to speaches).
speaches resolves it through `model_aliases.json` in its working directory, and the file
it ships points `whisper-1` at `faster-whisper-large-v3` — which you did not download.
Copy this repo's [`model_aliases.json`](model_aliases.json) to `$HOME\voicemode\` and
mount it over the image's copy:

```powershell
docker run -d --name voicemode-whisper `
  --restart unless-stopped `
  -p 2022:8000 `
  -e HF_HUB_OFFLINE=1 `
  -v $HOME\voicemode\hf-cache:/home/ubuntu/.cache/huggingface/hub `
  -v $HOME\voicemode\model_aliases.json:/home/ubuntu/speaches/model_aliases.json:ro `
  ghcr.io/speaches-ai/speaches:latest-cpu
```

Port 2022 on the host, 8000 in the container — 2022 is what VoiceMode expects.

### 4. Text-to-speech — Kokoro

```powershell
docker run -d --name voicemode-kokoro `
  --restart unless-stopped `
  -p 8880:8880 `
  ghcr.io/remsky/kokoro-fastapi-cpu:latest
```

Nothing to mount: [kokoro-fastapi](https://github.com/remsky/kokoro-FastAPI) bakes the
model into the image. `--restart unless-stopped` on both containers is the whole autostart
story — Docker Desktop starts at login and restarts them. No systemd, no scheduled task.

Check both:

```powershell
curl.exe http://127.0.0.1:2022/v1/models
curl.exe http://127.0.0.1:8880/v1/audio/voices
```

Kokoro needs ~30s to warm its model before `/health` answers. A connection failure in the
first half-minute is normal.

### 5. Wire it into Claude Code

Put this repo's folder on your user PATH, and that is the wiring done:

```powershell
[Environment]::SetEnvironmentVariable("Path",
  [Environment]::GetEnvironmentVariable("Path","User") + ";C:\path\to\this\repo", "User")
```

`voice.ps1 talk` builds the MCP config and launches Claude with it. Optionally skip the
approval prompt on every spoken turn, in `~/.claude/settings.json`:

```json
{ "permissions": { "allow": ["mcp__voicemode__converse"] } }
```

**Do not run `/voicemode:install` or the plugin's own installer.** They hit the
`RuntimeError` above and repair nothing.

### 6. Config (optional)

`~/.voicemode/voicemode.env` is a big commented template, already defaulted correctly for
this layout. Worth setting:

```ini
VOICEMODE_VOICES=af_sky
VOICEMODE_WHISPER_LANGUAGE=en
```

Pinning the language skips Whisper's detection pass — faster, and it stops guessing wrong
on short utterances. The base URLs need no entry.

---

## Why it is per-terminal

`--mcp-config` *merges* a server into one session rather than replacing your config, so a
voice terminal keeps Supabase, Gmail and everything else. The config file is generated
into `$HOME\voicemode\` on each run rather than committed — it holds an absolute path to
your venv, which is nobody else's path.

For this to stay opt-in, voicemode must **not** be registered globally. `voice.ps1 status`
warns you if it finds one; `claude mcp remove voicemode -s user` clears it.

If you do run two voice terminals, VoiceMode's single-speaker lock (**the conch**, state in
`~/.voicemode/conch`) queues them: one holds the floor on a 10s renewing lease, others wait
up to 25s. `voicemode conch status | bump | release` inspects and clears it.

Note that `voicemode service start|stop|status` is **not** the switch here — it drives
launchd/systemd installs of whisper.cpp and kokoro, has no idea these containers exist, and
reports everything "not available" no matter what is running.

## Is it listening all the time?

No, and it is checkable rather than a promise:

- `sd.rec` and `sd.InputStream` appear in **exactly one file** in the package,
  `voice_mode/tools/converse.py`. The mic opens when a turn starts listening and closes
  when it ends — no wake-word listener, no background stream.
  `grep -rn "sd\.rec(\|InputStream" voice_mode/` is the whole audit.
- `~/.voicemode/audio/` and `~/.voicemode/transcriptions/` stay empty unless you turn
  saving on.
- Speech goes to your own containers on 127.0.0.1, and with no `OPENAI_API_KEY` set there
  is no cloud fallback to leak into.

The mic is genuinely open for the few seconds after Claude speaks, while it waits for your
reply. That window is what the headset's hardware mute covers.

## What voice costs in tokens

Measured against this setup, not estimated:

| | tokens | when |
|---|---|---|
| `converse` + `pause_conversation` schemas | ~4,300 | **once**, first use, that session only |
| server instructions injected into the system prompt | 0 | never — VoiceMode sends none |
| registered but unused | ~10 | per request, just the tool names |
| switching terminals | 0 | never |

Claude Code **defers MCP tool schemas** — they are listed by name and only loaded when a
`ToolSearch` pulls them in, so the ~4.3k sits outside your context until you actually
speak. `voice.ps1` also passes `--tools-enabled converse`, dropping the `service` tool for
another ~320. The recurring cost is the obvious one: every spoken exchange puts its
transcript in context, exactly like typing it.

---

## Troubleshooting

### It speaks, but never hears you

Check the headset first — a muted or quiet mic is the likeliest cause and the easiest to
miss, because nothing errors. The signature, in `~/.voicemode/logs/conversations/`:

```
"type": "stt", "text": "[no speech detected]"
"type": "stt", "text": "through"          # one word from 38 seconds of audio
```

Boom arm down, mute off, then `mmsys.cpl` → Recording → your headset → Properties →
Levels → push the mic to 100. VoiceMode gates recordings through webrtcvad at aggressiveness
3, its strictest setting, so a quiet speaker is trimmed to silence before whisper sees the
audio. If the level is right and it still clips you, relax the gate in `voicemode.env`:
`VOICEMODE_VAD_AGGRESSIVENESS=2`.

### Claude opened but never says anything

`converse` is a **tool, not a mode**, and Claude Code defers MCP tool schemas — so a
session that was told none of this just answers in text: every container healthy, every
check green, not one word spoken. `voice.ps1 talk` handles it with
`--append-system-prompt`. If you started `claude` by hand, you have to ask: "talk to me out
loud."

To tell "never asked" from "actually broken", check whether anything reached the engines:

```powershell
docker logs --since 20m voicemode-kokoro  | Select-String "speech"
docker logs --since 20m voicemode-whisper | Select-String "transcriptions"
```

No lines means the tool was never called, so look at the session, not the stack. To test
the stack alone: `voicemode converse --skip-stt "testing the speak path"`.

### `voice.ps1 : The term 'voice.ps1' is not recognized`

A stale shell. PATH changes only reach **new processes**, and the trap is that a new
Windows Terminal *tab* inherits from the Terminal process, which is still the old one — a
new tab is not a new environment. Close Windows Terminal completely and reopen, or refresh
in place:

```powershell
$env:Path = [Environment]::GetEnvironmentVariable("Path","Machine") + ";" +
            [Environment]::GetEnvironmentVariable("Path","User")
```

### Why the model is downloaded on the host

If HTTPS on your machine is intercepted by security software (Norton, Zscaler, a corporate
proxy — anything re-signing traffic with its own CA), containers and Python both fail with
`CERTIFICATE_VERIFY_FAILED`. Windows trusts the interception CA; Python does not, because
it uses `certifi`'s bundle rather than the OS store. A working `curl` proves nothing —
Git Bash's curl has its own bundle behaviour and often succeeds where Python fails.

Downloading on the host and bind-mounting the cache with `HF_HUB_OFFLINE=1` sidesteps it
for the container. If the host download also fails:

```powershell
pip install truststore
python -c "import truststore; truststore.inject_into_ssl(); from huggingface_hub import snapshot_download; snapshot_download('Systran/faster-whisper-small')"
```

[`truststore`](https://truststore.readthedocs.io/) makes Python use the Windows certificate
store, which *does* trust the interception CA. That keeps verification on — prefer it over
`--trusted-host` or disabling TLS checks.

### Everything else

| Symptom | Cause |
|---|---|
| Transcription returns nothing / model not found | The alias file, step 3. `docker exec voicemode-whisper cat model_aliases.json` should show `faster-whisper-small`. |
| `UnicodeEncodeError: 'charmap' codec` | Windows gave Python a cp1252 stream and VoiceMode printed an emoji. Set `PYTHONIOENCODING=utf-8` in your shell before any `voicemode` subcommand. |
| `ModuleNotFoundError: audioop` | Python 3.13 without `audioop-lts`. `pip install audioop-lts`. |
| Wheel build fails for `simpleaudio` | You dropped the `--no-deps`. Step 1. |
| No microphone | `python -c "import sounddevice; print(sounddevice.query_devices())"` in the venv. Empty means the Windows mic privacy setting, not VoiceMode. |
| `voicemode service status` says "not available" | Expected. Wrong tool for this setup — use `voice.ps1 status`. |
| First response is slow | The Whisper model loads lazily on first request. |

---

## Layout

```
this repo
├── README.md              # why, and the manual walkthrough
├── AGENTS.md              # the same steps as an agent checklist, with gates
├── voice.ps1              # talk / on / off / status  (put this folder on PATH)
└── model_aliases.json     # copy to $HOME\voicemode\, mounted into speaches

C:\Users\<you>\voicemode\  # .venv, ffmpeg, hf-cache, model_aliases.json
                           # + voicemode.mcp.json, generated by talk, not committed
C:\Users\<you>\.voicemode\ # voicemode.env, conch, audio\, transcriptions\, logs\
```

## Credits

- [mbailey/voicemode](https://github.com/mbailey/voicemode) — MIT
- [speaches-ai/speaches](https://github.com/speaches-ai/speaches) — MIT
- [remsky/kokoro-FastAPI](https://github.com/remsky/kokoro-FastAPI) — Apache 2.0

Not affiliated with any of them. This is one working configuration, written down.
