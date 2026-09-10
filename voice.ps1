<#
.SYNOPSIS
    Everything voice, under one word.

.DESCRIPTION
    talk    Launch Claude Code in THIS terminal with voice, engines first.
    on      Start the two engine containers.
    off     Stop them. Survives a reboot.
    status  Who is running, who is healthy, is the launcher wired up.

    Voice is opt-in per terminal: `talk` merges the voicemode MCP server into
    that one session only. Terminals started with a plain `claude` have no
    voice and cannot start talking at you.

    Switching which terminal has voice costs nothing - this is a shell
    launcher, the model is never asked.

.EXAMPLE
    voice.ps1 talk
    voice.ps1 off
    voice.ps1
#>
param(
    [Parameter(Position = 0)]
    [ValidateSet('talk', 'on', 'off', 'status')]
    [string]$Action = 'status'
)
# No pass-through to claude on purpose: PowerShell binds a bare -p to its own
# -PipelineVariable before this script ever sees it. Need flags? Run
# `voice.ps1 on`, then claude yourself with the config path status prints.

$ErrorActionPreference = 'Stop'

$VoiceHome = Join-Path $HOME 'voicemode'
$VoicemodeExe = Join-Path $VoiceHome '.venv\Scripts\voicemode.exe'

$Services = @(
    [pscustomobject]@{ Name = 'voicemode-whisper'; Role = 'STT'; Health = 'http://127.0.0.1:2022/health' }
    [pscustomobject]@{ Name = 'voicemode-kokoro';  Role = 'TTS'; Health = 'http://127.0.0.1:8880/health' }
)

# Empty string when the container does not exist at all. ^name$ anchors the
# filter, which is a substring match otherwise.
function Get-ContainerState([string]$Name) {
    (@(docker ps -a --filter "name=^$Name$" --format '{{.State}}') -join '').Trim()
}

function Test-Healthy([string]$Url) {
    try { (Invoke-WebRequest $Url -TimeoutSec 3 -UseBasicParsing).StatusCode -eq 200 }
    catch { $false }
}

# Kokoro loads and warms its model before it serves, which takes ~30s on CPU.
function Wait-Healthy($Service, [int]$TimeoutSeconds = 120) {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (Test-Healthy $Service.Health) { return $true }
        Start-Sleep -Seconds 2
    }
    return $false
}

function Start-Engines {
    foreach ($service in $Services) {
        if (-not (Get-ContainerState $service.Name)) {
            Write-Error "$($service.Name) does not exist. This is the switch, not the setup - see AGENTS.md."
        }
        docker start $service.Name | Out-Null
    }
    $allReady = $true
    foreach ($service in $Services) {
        if (Wait-Healthy $service) {
            Write-Host "$($service.Name) ready" -ForegroundColor Green
        } else {
            Write-Host "$($service.Name) started but not answering - docker logs $($service.Name)" -ForegroundColor Yellow
            $allReady = $false
        }
    }
    return $allReady
}

# Generated, never committed: it holds an absolute path to this machine's venv,
# which is nobody else's path. Rewritten every call so it cannot go stale.
# WriteAllText to avoid the BOM that Set-Content -Encoding utf8 adds in PS 5.1.
function New-McpConfig {
    if (-not (Test-Path $VoicemodeExe)) {
        Write-Error "$VoicemodeExe not found. Run the setup first - see AGENTS.md."
    }
    $path = Join-Path $VoiceHome 'voicemode.mcp.json'
    $config = @{
        mcpServers = @{
            voicemode = @{
                # --tools-enabled drops the `service` tool: ~320 tokens we never
                # need, since this script manages the containers.
                command = $VoicemodeExe.Replace('\', '/')
                args    = @('--tools-enabled', 'converse')
                env     = @{ PYTHONIOENCODING = 'utf-8' }
            }
        }
    }
    [System.IO.File]::WriteAllText($path, ($config | ConvertTo-Json -Depth 6))
    return $path
}

# Loading the server is not enough. `converse` is a tool, not a mode, and Claude
# Code defers MCP tool schemas - so an unprompted session answers in text and the
# headset stays silent. That silence is what "voice mode doesn't work" actually is.
# One line, no newlines: PS 5.1 mangles multi-line strings passed to native exes.
$VoicePrompt = @(
    'This session is voice-first. The user is wearing a headset and expects to hear you, not read you.'
    'At session start, load the schema once: ToolSearch with query select:mcp__voicemode__converse.'
    'Then answer every turn by calling mcp__voicemode__converse with your reply as message.'
    'wait_for_response true when you need an answer back, false when you are only reporting progress.'
    'Speak two or three sentences; leave the detail in the terminal.'
    'If converse errors, say so in text and carry on - never just go quiet.'
) -join ' '

function Show-Status {
    foreach ($service in $Services) {
        $state = Get-ContainerState $service.Name
        if (-not $state) { $state = 'not created' }
        $health = if (Test-Healthy $service.Health) { 'healthy' } else { '-' }
        '{0,-20} {1,-5} {2,-12} {3}' -f $service.Name, $service.Role, $state, $health
    }
    $launcher = if (Test-Path $VoicemodeExe) { 'ready - run: voice.ps1 talk' }
                else { "NOT installed ($VoicemodeExe missing) - see AGENTS.md" }
    '{0,-20} {1,-5} {2}' -f 'launcher', '', $launcher
    '{0,-20} {1,-5} {2}' -f 'mcp config', '', (Join-Path $VoiceHome 'voicemode.mcp.json')

    # Voice everywhere defeats the point of the launcher, so say so.
    # $LASTEXITCODE, not $?: PS 5.1 wraps a native command's stderr in an
    # ErrorRecord, which $ErrorActionPreference='Stop' would turn terminating.
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    claude mcp get voicemode 2>&1 | Out-Null
    $registeredGlobally = ($LASTEXITCODE -eq 0)
    $ErrorActionPreference = $prev

    if ($registeredGlobally) {
        Write-Host ''
        Write-Host 'Note: voicemode is also registered globally, so every terminal has voice.' -ForegroundColor Yellow
        Write-Host 'To make it opt-in only:  claude mcp remove voicemode -s user' -ForegroundColor Yellow
    }
}

switch ($Action) {
    'talk' {
        if (-not (Start-Engines)) {
            Write-Host 'Engines are not answering; starting anyway - voice will fail until they do.' -ForegroundColor Yellow
        }
        $config = New-McpConfig
        Write-Host 'Voice is on in this terminal only. First reply takes ~8s to speak.' -ForegroundColor Green
        claude --mcp-config $config --append-system-prompt $VoicePrompt
    }

    'on' { Start-Engines | Out-Null }

    'off' {
        docker stop @($Services.Name) | Out-Null
        Write-Host 'Voice off. Stays off across reboots until: voice.ps1 on' -ForegroundColor Green
    }

    # exit 0 explicitly: the `claude mcp get` probe above leaves a non-zero
    # $LASTEXITCODE behind whenever voice is correctly NOT registered globally.
    'status' { Show-Status; exit 0 }
}
