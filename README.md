# VoiceMode on native Windows

[VoiceMode](https://github.com/mbailey/voicemode) gives Claude Code a voice — you talk,
it talks back. Its README lists "Windows (native or WSL)" as supported, but the official
installer refuses to run there:

```python
# installer/voicemode_install/system.py
raise RuntimeError("Unsupported operating system")   # anything but darwin/linux
```

The **runtime** package is fine on Windows, though. Only the installer is not. This repo
is the hand-wired setup that works: a venv, two Docker containers, and one alias file.

No WSL. That is deliberate — VoiceMode's own docs still mark the WSLg PulseAudio mic
bridge "coming soon", while `sounddevice` on native Windows reaches the mic through
WASAPI directly.

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

Both URLs are VoiceMode's built-in defaults, so once the containers listen on those
ports there is nothing to configure. Everything runs locally — no OpenAI key, no audio
leaving the machine.

Verified against: VoiceMode 8.12.0, Python 3.13.14, Windows 11, Docker Desktop.

---

## Prerequisites

- **Python 3.13** (3.11+ works; 3.13 needs `audioop-lts`, see below)
- **Docker Desktop** with the WSL2 backend, set to start at login
- ~4 GB disk for the two images plus the Whisper model
- A working mic. `Settings → Privacy → Microphone → let desktop apps access` must be on.

No admin rights needed anywhere in this guide.

---

## 1. The venv

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

That is voice-mode's full dependency list minus `simpleaudio`.

`audioop-lts` matters on 3.13: the stdlib `audioop` module was removed in that release
([PEP 594](https://peps.python.org/pep-0594/)), and `pydub` imports it. `audioop-lts` is
the drop-in replacement. On 3.12 or older you can leave it out.

Check it imports:

```powershell
.\.venv\Scripts\voicemode.exe --version
```

## 2. ffmpeg

`pydub` shells out to ffmpeg for MP3. Grab a static build, unzip it, and put the folder
on your **user** PATH (no admin, no installer):

```powershell
# after unzipping the release so that ffmpeg.exe sits in $HOME\voicemode\ffmpeg
[Environment]::SetEnvironmentVariable(
  "Path",
  [Environment]::GetEnvironmentVariable("Path", "User") + ";$HOME\voicemode\ffmpeg",
  "User")
```

Open a new shell, then `ffmpeg -version` should answer.

## 3. Speech-to-text — speaches

[speaches](https://github.com/speaches-ai/speaches) serves faster-whisper behind an
OpenAI-compatible `/v1/audio/transcriptions`.

**Download the model on the host first.** The container runs with `HF_HUB_OFFLINE=1`, so
it never reaches Hugging Face itself — see [Why the model is downloaded on the host](#why-the-model-is-downloaded-on-the-host)
below.

```powershell
mkdir $HOME\voicemode\hf-cache
$env:HF_HUB_CACHE = "$HOME\voicemode\hf-cache"
.\.venv\Scripts\hf.exe download Systran/faster-whisper-small
```

**Fix the model alias.** VoiceMode asks for the model literally named `whisper-1`
(`STT_MODEL = os.getenv("VOICEMODE_STT_MODEL", "whisper-1")` in `voice_mode/config.py`),
which is OpenAI's name and means nothing to speaches. speaches resolves it through
`model_aliases.json` in its working directory — but the file it ships points `whisper-1`
at `faster-whisper-large-v3`, which you did not download. Mount the copy from this repo
over it:

```json
{
    "tts-1": "speaches-ai/Kokoro-82M-v1.0-ONNX",
    "tts-1-hd": "speaches-ai/Kokoro-82M-v1.0-ONNX",
    "whisper-1": "Systran/faster-whisper-small"
}
```

Skip this and every transcription fails with a model-not-found — the most confusing
failure in the whole setup, because the mic works, the request goes out, and nothing
comes back.

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

## 4. Text-to-speech — Kokoro

```powershell
docker run -d --name voicemode-kokoro `
  --restart unless-stopped `
  -p 8880:8880 `
  ghcr.io/remsky/kokoro-fastapi-cpu:latest
```

Nothing to mount: [kokoro-fastapi](https://github.com/remsky/kokoro-FastAPI) bakes the
model into the image.

`--restart unless-stopped` on both is the autostart story — Docker Desktop starts at
login, Docker restarts the containers. No systemd, no launchd, no scheduled task.

Check both:

```powershell
curl.exe http://127.0.0.1:2022/v1/models
curl.exe http://127.0.0.1:8880/v1/audio/voices
```

## 5. Wire it into Claude Code

```powershell
claude mcp add --scope user voicemode -- $HOME\voicemode\.venv\Scripts\voicemode.exe
```

`voicemode.exe` with no arguments starts the MCP server on stdio; the subcommands are for
service management.

Optional — skip the approval prompt on every turn, in `~/.claude/settings.json`:

```json
{
  "permissions": {
    "allow": ["mcp__voicemode__converse", "mcp__voicemode__service"]
  }
}
```

Then just ask Claude to talk to you.

**Do not run `/voicemode:install` or the plugin's own installer.** They hit the
`RuntimeError` above and will not repair anything.

## 6. Config

`~/.voicemode/voicemode.env` — a big commented template, everything already defaulted
correctly for this layout. Worth setting:

```ini
VOICEMODE_VOICES=af_sky
VOICEMODE_WHISPER_LANGUAGE=en
```

Pinning the language skips Whisper's language-detection pass, which is both faster and
stops it guessing wrong on short utterances.

The base URLs need no entry — `voice_mode/config.py` already defaults to
`http://127.0.0.1:2022/v1` and `http://127.0.0.1:8880/v1`, each with the OpenAI API as a
fallback if the local service is down.

---

## Troubleshooting

### Why the model is downloaded on the host

If HTTPS on your machine is intercepted by security software (Norton, Zscaler, a
corporate proxy — anything re-signing traffic with its own CA), containers and Python
both fail with:

```
CERTIFICATE_VERIFY_FAILED: unable to get local issuer certificate
```

Windows trusts the interception CA; Python does not, because it uses `certifi`'s bundle
rather than the OS store. A working `curl` proves nothing here — Git Bash's curl has its
own bundle behaviour and often succeeds where Python fails.

Downloading on the host and bind-mounting the cache with `HF_HUB_OFFLINE=1` sidesteps it
for the container. If the host download also fails:

```powershell
pip install truststore
python -c "import truststore; truststore.inject_into_ssl(); from huggingface_hub import snapshot_download; snapshot_download('Systran/faster-whisper-small')"
```

[`truststore`](https://truststore.readthedocs.io/) makes Python use the Windows
certificate store, which *does* trust the interception CA. That keeps verification on —
prefer it over `--trusted-host` or disabling TLS checks. Turning off the AV's "encrypted
connections scanning" removes the whole class of problem if you are allowed to.

### Transcription returns nothing / model not found

The alias file (step 3). `docker exec voicemode-whisper cat model_aliases.json` should
show `faster-whisper-small`, not `large-v3`.

### `ModuleNotFoundError: audioop`

Python 3.13 without `audioop-lts`. `pip install audioop-lts`.

### Wheel build fails for simpleaudio

You dropped the `--no-deps`. Step 1.

### No microphone

`python -c "import sounddevice; print(sounddevice.query_devices())"` in the venv. Empty
or missing input device means the Windows mic privacy setting, not VoiceMode.

### First response is slow

The Whisper model loads lazily on the first request. Subsequent ones are quick.

---

## Layout

```
C:\Users\<you>\voicemode\
├── .venv\                 # voice-mode + deps, no simpleaudio
├── ffmpeg\                # static build, on the user PATH
├── hf-cache\              # HF hub cache, bind-mounted into speaches
└── model_aliases.json     # whisper-1 → faster-whisper-small

C:\Users\<you>\.voicemode\
├── voicemode.env          # config
├── audio\                 # recordings
├── transcriptions\
└── logs\
```

## Credits

- [mbailey/voicemode](https://github.com/mbailey/voicemode) — MIT
- [speaches-ai/speaches](https://github.com/speaches-ai/speaches) — MIT
- [remsky/kokoro-FastAPI](https://github.com/remsky/kokoro-FastAPI) — Apache 2.0

Not affiliated with any of them. This is one working configuration, written down.
