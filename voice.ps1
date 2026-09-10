<#
.SYNOPSIS
    Turn the local VoiceMode engines on or off.

.DESCRIPTION
    Starts and stops the two Docker containers that VoiceMode talks to.
    "off" survives a reboot: both containers run with --restart unless-stopped,
    which Docker reads as "restart it unless a human stopped it on purpose".

    This does not touch the MCP server registration, so flipping the switch
    never costs you a Claude Code restart. With the engines off, asking Claude
    for voice fails with a connection error rather than falling back to a cloud
    service.

.EXAMPLE
    .\voice.ps1 on
    .\voice.ps1 off
    .\voice.ps1            # same as: .\voice.ps1 status
#>
param(
    [Parameter(Position = 0)]
    [ValidateSet('on', 'off', 'status')]
    [string]$Action = 'status'
)

$ErrorActionPreference = 'Stop'

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

function Test-McpRegistered {
    try {
        claude mcp get voicemode *>$null
        return $?
    } catch { return $false }   # claude not on PATH
}

function Show-Status {
    foreach ($service in $Services) {
        $state = Get-ContainerState $service.Name
        if (-not $state) { $state = 'not created' }
        $health = if (Test-Healthy $service.Health) { 'healthy' } else { '-' }
        '{0,-20} {1,-5} {2,-12} {3}' -f $service.Name, $service.Role, $state, $health
    }
    $mcp = if (Test-McpRegistered) { 'registered (run: claude mcp get voicemode)' }
           else { 'NOT registered - run: claude mcp add voicemode --scope user -e PYTHONIOENCODING=utf-8 -- $HOME\voicemode\.venv\Scripts\voicemode.exe' }
    '{0,-20} {1,-5} {2}' -f 'mcp server', '', $mcp
}

switch ($Action) {
    'on' {
        foreach ($service in $Services) {
            if (-not (Get-ContainerState $service.Name)) {
                Write-Error "$($service.Name) does not exist. This is the switch, not the setup - see AGENTS.md."
            }
            docker start $service.Name | Out-Null
        }
        foreach ($service in $Services) {
            if (Wait-Healthy $service) {
                Write-Host "$($service.Name) ready" -ForegroundColor Green
            } else {
                Write-Host "$($service.Name) started but not answering - docker logs $($service.Name)" -ForegroundColor Yellow
            }
        }
        if (-not (Test-McpRegistered)) {
            Write-Host 'Engines are up but the MCP server is not registered - Claude cannot see them yet.' -ForegroundColor Yellow
            Write-Host 'See step 5 in README.md.' -ForegroundColor Yellow
        }
    }

    'off' {
        docker stop @($Services.Name) | Out-Null
        Write-Host 'Voice off. Stays off across reboots until: .\voice.ps1 on' -ForegroundColor Green
    }

    'status' { Show-Status }
}
