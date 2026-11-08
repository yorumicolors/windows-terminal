#Requires -Version 5.1
<#
.SYNOPSIS
    Install the yorumi colour schemes into Windows Terminal, and optionally theme
    PowerShell and activate a scheme.
.DESCRIPTION
    Windows Terminal has no importable theme file, so this script does the merge
    by hand: it writes the seven scheme objects into the "schemes" array of
    settings.json, leaving every other byte of the file alone, then offers to

      * set the scheme on every profile (profiles.defaults.colorScheme), and
      * install the matching yorumi theme for PowerShell itself.

    Nothing is applied behind your back: both steps prompt, and both are skipped
    when there is nobody to answer (-NonInteractive, or piped input).
.PARAMETER Flavour
    The scheme to activate. Default: ether.
.PARAMETER SettingsPath
    settings.json to edit. Default: the first Windows Terminal settings.json found.
.PARAMETER Activate
    Set profiles.defaults.colorScheme without asking.
.PARAMETER NoActivate
    Never set profiles.defaults.colorScheme, and never ask.
.PARAMETER InstallPowerShell
    Install the yorumi theme for PowerShell without asking.
.PARAMETER NoInstallPowerShell
    Never install the PowerShell theme, and never ask.
.PARAMETER PowerShellInstaller
    Path to the PowerShell port's install.ps1. Default: beside this script if it
    is there, otherwise downloaded from GitHub.
.PARAMETER NonInteractive
    Ask nothing; do only the file work.
.EXAMPLE
    irm https://raw.githubusercontent.com/yorumicolors/windows-terminal/main/install.ps1 | iex
.EXAMPLE
    ./install.ps1 -Flavour abyss -Activate
#>
[CmdletBinding()]
param(
    [string] $Flavour = 'ether',
    [string] $SettingsPath,
    [switch] $Activate,
    [switch] $NoActivate,
    [switch] $InstallPowerShell,
    [switch] $NoInstallPowerShell,
    [string] $PowerShellInstaller,
    [switch] $NonInteractive
)

$ErrorActionPreference = 'Stop'

# Windows PowerShell 5.1 predates TLS 1.2 defaults.
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch {
    # older .NET without the enum member
}

$rawBase = 'https://raw.githubusercontent.com/yorumicolors/windows-terminal/main'
$flavours = 'ether', 'abyss', 'bifrost', 'kraken', 'kabocha', 'cosmic', 'ryujin'
if ($flavours -notcontains $Flavour) {
    throw "unknown flavour '$Flavour'. One of: $($flavours -join ', ')"
}
$schemeName = 'Yorumi ' + $Flavour.Substring(0, 1).ToUpper() + $Flavour.Substring(1)
$isYorumiScheme = [regex]'"name"\s*:\s*"Yorumi '

$interactive = -not $NonInteractive -and -not [Console]::IsInputRedirected

# ── helpers ────────────────────────────────────────────────────────────────
function Read-Text([string] $path) {
    return [IO.File]::ReadAllText($path)
}

function Write-Text([string] $path, [string] $text) {
    # no BOM: settings.json is JSONC and a BOM upsets other tools that parse it
    [IO.File]::WriteAllText($path, $text, (New-Object System.Text.UTF8Encoding($false)))
}

# index just past the "[" of "key": [   (or -1)
function Find-ArrayOpen([string] $text, [string] $key) {
    $m = [regex]::Match($text, '"' + [regex]::Escape($key) + '"\s*:\s*\[')
    if ($m.Success) { return $m.Index + $m.Length }
    return -1
}

# index of the "{" of "key": {   (or -1)
function Find-ObjectOpen([string] $text, [string] $key) {
    $m = [regex]::Match($text, '"' + [regex]::Escape($key) + '"\s*:\s*\{')
    if ($m.Success) { return $m.Index + $m.Length }
    return -1
}

# top-level { } spans inside the array that starts at $open: @{Start;End} (End exclusive)
function Get-ObjectSpans([string] $text, [int] $open) {
    $spans = @()
    $depth = 0
    $inString = $false
    $start = -1
    for ($i = $open; $i -lt $text.Length; $i++) {
        $c = $text[$i]
        if ($inString) {
            if ($c -eq '\') { $i++ }
            elseif ($c -eq '"') { $inString = $false }
            continue
        }
        if ($c -eq '"') { $inString = $true; continue }
        if ($c -eq '{') {
            if ($depth -eq 0) { $start = $i }
            $depth++
            continue
        }
        if ($c -eq '}') {
            $depth--
            if ($depth -eq 0 -and $start -ge 0) {
                $spans += @{ Start = $start; End = $i + 1 }
                $start = -1
            }
            continue
        }
        if ($c -eq ']' -and $depth -eq 0) { break }
    }
    return $spans
}

# JSONC → JSON the .NET parser accepts: drop comments and trailing commas
function ConvertTo-StrictJson([string] $text) {
    $sb = New-Object System.Text.StringBuilder
    $inString = $false
    for ($i = 0; $i -lt $text.Length; $i++) {
        $c = $text[$i]
        if ($inString) {
            [void]$sb.Append($c)
            if ($c -eq '\' -and $i + 1 -lt $text.Length) { $i++; [void]$sb.Append($text[$i]) }
            elseif ($c -eq '"') { $inString = $false }
            continue
        }
        if ($c -eq '"') { $inString = $true; [void]$sb.Append($c); continue }
        if ($c -eq '/' -and $i + 1 -lt $text.Length) {
            $next = $text[$i + 1]
            if ($next -eq '/') {
                while ($i -lt $text.Length -and $text[$i] -ne "`n") { $i++ }
                [void]$sb.Append("`n")
                continue
            }
            if ($next -eq '*') {
                $i += 2
                while ($i + 1 -lt $text.Length -and -not ($text[$i] -eq '*' -and $text[$i + 1] -eq '/')) { $i++ }
                $i++
                continue
            }
        }
        [void]$sb.Append($c)
    }
    return [regex]::Replace($sb.ToString(), ',\s*([\]\}])', '$1')
}

function Confirm-NeedsAsk([switch] $yes, [switch] $no) {
    if ($yes) { return $true }
    if ($no) { return $false }
    return $null
}

function Ask-YesNo([string] $question) {
    if (-not $interactive) { return $false }
    $answer = Read-Host "$question [y/N]"
    return ($answer -match '^(y|yes)$')
}

# ── find settings.json ─────────────────────────────────────────────────────
$isWindowsHost = ($env:OS -eq 'Windows_NT')
if (-not $isWindowsHost -and -not $SettingsPath) {
    Write-Host 'Windows Terminal runs on Windows only — run this installer there.'
    Write-Host 'The yorumi-*.json files are still in this folder to paste into settings.json.'
    return
}
if (-not $SettingsPath -and $env:LOCALAPPDATA) {
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json'),
        (Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe\LocalState\settings.json'),
        (Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminalCanary_8wekyb3d8bbwe\LocalState\settings.json'),
        (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows Terminal\settings.json'),
        (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows Terminal Preview\settings.json')
    )
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) { $SettingsPath = $candidate; break }
    }
}

if (-not $SettingsPath -or -not (Test-Path -LiteralPath $SettingsPath)) {
    Write-Host 'Windows Terminal settings.json was not found.'
    Write-Host 'Open Windows Terminal once, or pass -SettingsPath. The scheme objects are still'
    Write-Host 'in this folder if you would rather paste them yourself.'
    $SettingsPath = $null
} else {
    $SettingsPath = (Resolve-Path -LiteralPath $SettingsPath).Path
}

# ── the seven scheme objects ───────────────────────────────────────────────
$objects = @()
foreach ($f in $flavours) {
    $local = if ($PSScriptRoot) { Join-Path $PSScriptRoot "yorumi-$f.json" }
    if ($local -and (Test-Path -LiteralPath $local)) {
        $body = (Read-Text $local).Trim()
    } else {
        $body = (Invoke-WebRequest -UseBasicParsing -Uri "$rawBase/yorumi-$f.json").Content.Trim()
    }
    $objects += $body
}
Write-Host "schemes ready: $($flavours -join ', ')"

# ── merge into settings.json ───────────────────────────────────────────────
$activated = $false
if ($SettingsPath) {
    $text = Read-Text $SettingsPath
    $original = $text
    $open = Find-ArrayOpen $text 'schemes'
    $missing = @()

    if ($open -ge 0) {
        # replace a scheme we shipped before, otherwise queue it for insertion
        $spans = Get-ObjectSpans $text $open
        $rewritten = @()
        for ($i = 0; $i -lt $spans.Count; $i++) {
            $span = $spans[$i]
            $block = $text.Substring($span.Start, $span.End - $span.Start)
            if ($block -match $isYorumiScheme) { $rewritten += $i }
        }
        # descending: each splice shifts the text after it
        [array]::Reverse($rewritten)
        foreach ($i in $rewritten) {
            $span = $spans[$i]
            $block = $text.Substring($span.Start, $span.End - $span.Start)
            $m = [regex]::Match($block, '"name"\s*:\s*"(Yorumi ([A-Za-z]+))"')
            $matchFlavour = $m.Groups[2].Value.ToLower()
            $index = [array]::IndexOf($flavours, $matchFlavour)
            if ($index -ge 0) {
                $text = $text.Substring(0, $span.Start) + $objects[$index] + $text.Substring($span.End)
            }
        }
        # recompute after the replacements, then insert whatever is still absent
        $open = Find-ArrayOpen $text 'schemes'
        $spans = Get-ObjectSpans $text $open
        $present = @()
        foreach ($span in $spans) {
            $block = $text.Substring($span.Start, $span.End - $span.Start)
            $m = [regex]::Match($block, '"name"\s*:\s*"Yorumi ([A-Za-z]+)"')
            if ($m.Success) { $present += $m.Groups[1].Value.ToLower() }
        }
        foreach ($f in $flavours) {
            if ($present -notcontains $f) {
                $missing += $objects[[array]::IndexOf($flavours, $f)]
            }
        }
        if ($missing.Count -gt 0) {
            $tail = if ($spans.Count -gt 0) { "," } else { "" }
            $insert = ($missing -join ",`n") + $tail
            $text = $text.Substring(0, $open) + "`n" + $insert + $text.Substring($open)
        }
    } else {
        # no "schemes" key at all: add one as the last root member
        $close = $text.LastIndexOf('}')
        if ($close -lt 0) { throw "$SettingsPath does not look like JSON; nothing was changed." }
        $head = $text.Substring(0, $close).TrimEnd()
        if (-not ($head.EndsWith('{') -or $head.EndsWith(','))) { $head += ',' }
        $text = $head + "`n    `"schemes`": [`n" + ($objects -join ",`n") + "`n    ]`n" + $text.Substring($close)
    }

    # validate before touching the file
    try {
        $parsed = ConvertTo-StrictJson $text | ConvertFrom-Json
        $names = @($parsed.schemes | ForEach-Object { $_.name })
        foreach ($f in $flavours) {
            $want = 'Yorumi ' + $f.Substring(0, 1).ToUpper() + $f.Substring(1)
            if ($names -notcontains $want) { throw "scheme '$want' did not survive the merge" }
        }
    } catch {
        throw "the merged settings.json did not validate ($($_.Exception.Message)); $SettingsPath is unchanged."
    }

    if ($text -ne $original) {
        $backup = "$SettingsPath.yorumi-backup"
        Copy-Item -LiteralPath $SettingsPath -Destination $backup -Force
        Write-Text $SettingsPath $text
        Write-Host "schemes written to $SettingsPath (backup: $backup)"
    } else {
        Write-Host "schemes already present in $SettingsPath"
    }

    # ── activation ────────────────────────────────────────────────────────
    $wantActivate = Confirm-NeedsAsk -yes:$Activate -no:$NoActivate
    if ($null -eq $wantActivate) {
        $wantActivate = Ask-YesNo "Set '$schemeName' on every Windows Terminal profile (profiles.defaults)?"
    }
    if ($wantActivate) {
        $text = Read-Text $SettingsPath
        $profilesOpen = Find-ObjectOpen $text 'profiles'
        if ($profilesOpen -lt 0) {
            Write-Warning "this settings.json has no 'profiles' object (old array layout?); set the scheme in Settings instead."
        } else {
            $defaultsOpen = Find-ObjectOpen $text 'defaults'
            $entry = '"colorScheme": "' + $schemeName + '",'
            if ($defaultsOpen -gt $profilesOpen) {
                $existing = [regex]::Match($text.Substring($defaultsOpen), '^\s*"colorScheme"\s*:\s*"[^"]*"\s*,?')
                if ($existing.Success -and $existing.Index -eq 0) {
                    $text = $text.Substring(0, $defaultsOpen) + "`n        " + $entry + ' ' +
                        $text.Substring($defaultsOpen + $existing.Length)
                } else {
                    $text = $text.Substring(0, $defaultsOpen) + "`n        " + $entry + $text.Substring($defaultsOpen)
                }
            } else {
                $block = '"defaults": { ' + $entry.TrimEnd(',') + ' },'
                $text = $text.Substring(0, $profilesOpen) + "`n        " + $block + $text.Substring($profilesOpen)
            }
            try {
                $parsed = ConvertTo-StrictJson $text | ConvertFrom-Json
                if ($parsed.profiles.defaults.colorScheme -ne $schemeName) { throw 'colorScheme did not stick' }
            } catch {
                throw "activation did not validate ($($_.Exception.Message)); settings.json left as it was."
            }
            Write-Text $SettingsPath $text
            $activated = $true
            Write-Host "all profiles use '$schemeName'"
        }
    }
}

# ── the PowerShell prompt ──────────────────────────────────────────────────
$wantPowerShell = Confirm-NeedsAsk -yes:$InstallPowerShell -no:$NoInstallPowerShell
if ($null -eq $wantPowerShell) {
    $wantPowerShell = Ask-YesNo 'Also theme the PowerShell prompt itself (yorumi for PowerShell)?'
}
if ($wantPowerShell) {
    if (-not $PowerShellInstaller) {
        $sibling = if ($PSScriptRoot) { Join-Path (Split-Path -Path $PSScriptRoot -Parent) 'powershell\install.ps1' }
        if ($sibling -and (Test-Path -LiteralPath $sibling)) {
            $PowerShellInstaller = $sibling
        }
    }
    if ($PowerShellInstaller -and (Test-Path -LiteralPath $PowerShellInstaller)) {
        & $PowerShellInstaller -Flavour $Flavour
    } else {
        $ps = Invoke-WebRequest -UseBasicParsing -Uri 'https://raw.githubusercontent.com/yorumicolors/powershell/main/install.ps1'
        & ([scriptblock]::Create($ps.Content)) -Flavour $Flavour
    }
}

# ── what is left to do by hand ─────────────────────────────────────────────
Write-Host ''
if (-not $SettingsPath) {
    Write-Host 'Next:'
    Write-Host "  paste the scheme objects into the `"schemes`" array of settings.json, then set"
    Write-Host "  `"colorScheme`": `"$schemeName`" on a profile."
} elseif (-not $activated) {
    Write-Host 'Next:'
    Write-Host "  Windows Terminal → Settings → your profile → Appearance → Colour scheme → $schemeName"
    Write-Host '  (or re-run with -Activate to set it for every profile)'
} else {
    Write-Host "Next: reopen Windows Terminal tabs to see $schemeName."
}
