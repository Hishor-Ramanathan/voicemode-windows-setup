# Setup instructions for a coding agent

You are installing VoiceMode on a **native Windows** machine using this repo.
`README.md` explains *why* each step is shaped the way it is — read it if a step
surprises you. This file is the order of operations and the gate that proves each
step worked.

**Do not run a gate's next step until its gate passes.** Every gate below has failed
on a real machine; they are not ceremony.

## Rules

1. **Never run `/voicemode:install`, `voicemode install`, or the plugin installer.**
   They raise `RuntimeError: Unsupported operating system` on Windows and repair
   nothing. If the user asks you to, tell them why it cannot work and point at this file.
2. **Never `pip install voice-mode` without `--no-deps`.** It pulls `simpleaudio`, which
   has no wheels past cp38 and will try to invoke a C compiler.
3. Do not install WSL for this. The whole point is that it is not needed.
4. Use PowerShell. Paths below assume `$HOME` = `C:\Users\<user>`.

## Step 0 — Preconditions

```powershell
py -3.13 --version          # or 3.11+
docker version              # daemon must be reachable, not just the client
git --version
claude --version
```

**Gate:** all four answer. If Docker is not running, start Docker Desktop and wait —
do not proceed with a dead daemon, the container steps will fail confusingly.

## Step 1 — venv

```powershell
mkdir $HOME\voicemode -Force
cd $HOME\voicemode
py -3.13 -m venv .venv
.\.venv\Scripts\python.exe -m pip install --no-deps voice-mode
.\.venv\Scripts\python.exe -m pip install aiohttp audioop-lts click fastmcp httpx `
    keyring numpy openai psutil pydub pyyaml scipy sounddevice uv webrtcvad-wheels
```

**Gate:**

```powershell
.\.venv\Scripts\voicemode.exe --version
.\.venv\Scripts\python.exe -c "import sounddevice, pydub; print('ok')"
```

Both must succeed. `ModuleNotFoundError: audioop` means `audioop-lts` did not install —
it is mandatory on Python 3.13, optional below it.

## Step 2 — ffmpeg

Download a static Windows build, unzip so that `ffmpeg.exe` sits in
`$HOME\voicemode\ffmpeg\`, and append that folder to the **User** PATH (not Machine —
you do not have admin and do not need it):

```powershell
[Environment]::SetEnvironmentVariable("Path",
  [Environment]::GetEnvironmentVariable("Path","User") + ";$HOME\voicemode\ffmpeg", "User")
```

**Gate:** `ffmpeg -version` in a **new** shell. The current shell will not see the change.

## Step 3 — Whisper model, on the host

The container runs offline on purpose. Fetch the model to a host cache first:

```powershell
mkdir $HOME\voicemode\hf-cache -Force
$env:HF_HUB_CACHE = "$HOME\voicemode\hf-cache"
.\.venv\Scripts\hf.exe download Systran/faster-whisper-small
```

**Gate:** `ls $HOME\voicemode\hf-cache` shows `models--Systran--faster-whisper-small`.

If this fails with `CERTIFICATE_VERIFY_FAILED`, the machine has TLS interception
(antivirus or a corporate proxy). Do **not** disable certificate verification. Use
`truststore` — see the Troubleshooting section of `README.md`.

## Step 4 — The alias file

```powershell
copy .\model_aliases.json $HOME\voicemode\model_aliases.json   # from this repo
```

This is the step that gets skipped and costs an hour. VoiceMode requests the model
named `whisper-1`; the image's own alias file points that at `faster-whisper-large-v3`,
which is not what step 3 downloaded.

**Gate:** the file exists and its `whisper-1` value is `Systran/faster-whisper-small`.

## Step 5 — Containers

```powershell
docker run -d --name voicemode-whisper --restart unless-stopped `
  -p 2022:8000 -e HF_HUB_OFFLINE=1 `
  -v $HOME\voicemode\hf-cache:/home/ubuntu/.cache/huggingface/hub `
  -v $HOME\voicemode\model_aliases.json:/home/ubuntu/speaches/model_aliases.json:ro `
  ghcr.io/speaches-ai/speaches:latest-cpu

docker run -d --name voicemode-kokoro --restart unless-stopped `
  -p 8880:8880 `
  ghcr.io/remsky/kokoro-fastapi-cpu:latest
```

**Gate:**

```powershell
docker exec voicemode-whisper cat model_aliases.json     # must say faster-whisper-small
curl.exe -s http://127.0.0.1:2022/v1/models              # must list faster-whisper-small
curl.exe -s -o $null -w "%{http_code}" http://127.0.0.1:8880/health   # 200
```

Kokoro needs ~30s to warm its model on CPU before `/health` answers. A connection
failure in the first half-minute is normal; check `docker logs voicemode-kokoro` for
`Application startup complete` before treating it as broken.

## Step 6 — Register with Claude Code

```powershell
claude mcp add voicemode --scope user -e PYTHONIOENCODING=utf-8 -- `
  $HOME\voicemode\.venv\Scripts\voicemode.exe
```

`PYTHONIOENCODING=utf-8` is not optional on Windows: VoiceMode prints emoji, the default
console encoding is cp1252, and the result is `UnicodeEncodeError: 'charmap' codec can't
encode character '\u274c'`.

**Gate:** `claude mcp get voicemode` reports `Status: ✔ Connected`. Then tell the user to
**restart Claude Code once** — a newly registered server is not live in an already-running
session.

## Step 7 — Config

Optional, in `$HOME\.voicemode\voicemode.env` (created on first run):

```ini
VOICEMODE_VOICES=af_sky
VOICEMODE_WHISPER_LANGUAGE=en
```

Leave the base URLs alone; VoiceMode already defaults to ports 2022 and 8880.

## Done when

```powershell
.\voice.ps1 status
```

prints `running` + `healthy` for both containers and `registered` for the MCP server.

## What you did NOT set up

- `voicemode service start|stop|status` — VoiceMode's own service manager drives
  launchd/systemd installs, not these containers. On this setup it reports every service
  "not available" and is the wrong tool. `voice.ps1` is the switch. Do not wire the two
  together.
- Any autostart task. `--restart unless-stopped` plus Docker Desktop starting at login
  covers it.
