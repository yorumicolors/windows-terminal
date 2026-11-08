#Requires -Version 5.1
<#
.SYNOPSIS
    Install the yorumi colour schemes into Windows Terminal, and optionally theme
    PowerShell and activate a scheme.
.DESCRIPTION
    Windows Terminal has no importable theme file, so this script owns a marked
    block in settings.json:

        "schemes": [
            // >>> yorumi >>>
            { "name": "Yorumi Ether", … }
            // <<< yorumi <<<
        ]

    The block is rewritten whole, never spliced line by line, and deleting it is
    the uninstall. Activation is a second block inside "profiles.defaults":

        // >>> yorumi >>>
        "colorScheme": "Yorumi Ether",
        // <<< yorumi <<<

    Both are asked for. Nothing is applied when there is nobody to answer
    (-NonInteractive, or piped input).
.PARAMETER Flavour
    Scheme to activate and to hand to the PowerShell installer. Default: ether.
.PARAMETER SettingsPath
    settings.json to edit. Default: the first Windows Terminal settings.json found.
.PARAMETER Activate
    Write the profiles.defaults block without asking.
.PARAMETER NoActivate
    Never write it, and never ask.
.PARAMETER InstallPowerShell
    Install the yorumi theme for PowerShell without asking.
.PARAMETER NoInstallPowerShell
    Never install it, and never ask.
.PARAMETER PowerShellInstaller
    Path to the PowerShell port's install.ps1. Default: beside this repo, else downloaded.
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

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
} catch {
    # older .NET without the enum member
}

$rawBase = 'https://raw.githubusercontent.com/yorumicolors/windows-terminal/main'
$flavours = 'ether', 'abyss', 'bifrost', 'kraken', 'kabocha', 'cosmic', 'ryujin'
if ($flavours -notcontains $Flavour) {
    throw "unknown flavour '$Flavour'. One of: $($flavours -join ', ')"
}
$schemeName = 'Yorumi ' + $Flavour.Substring(0, 1).ToUpper() + $Flavour.Substring(1)

$interactive = -not $NonInteractive -and -not [Console]::IsInputRedirected
# two independent regions: the schemes, and the scheme choice
$begin = '// >>> yorumi >>>'
$end = '// <<< yorumi <<<'
$choiceBegin = '// >>> yorumi colorScheme >>>'
$choiceEnd = '// <<< yorumi colorScheme <<<'

# ── helpers ────────────────────────────────────────────────────────────────
function Read-Text([string] $path) { return [IO.File]::ReadAllText($path) }

function Write-Text([string] $path, [string] $text) {
    # no BOM: settings.json is JSONC, and a BOM upsets other parsers
    [IO.File]::WriteAllText($path, $text, (New-Object System.Text.UTF8Encoding($false)))
}

# index just past the "[" of "key": [  (or -1)
function Find-ArrayOpen([string] $text, [string] $key) {
    $m = [regex]::Match($text, '"' + [regex]::Escape($key) + '"\s*:\s*\[')
    if ($m.Success) { return $m.Index + $m.Length }
    return -1
}

# index just past the "{" of "key": {  (or -1)
function Find-ObjectOpen([string] $text, [string] $key) {
    $m = [regex]::Match($text, '"' + [regex]::Escape($key) + '"\s*:\s*\{')
    if ($m.Success) { return $m.Index + $m.Length }
    return -1
}

# top-level { } spans inside the array that starts at $open
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

# character span of the first region between the given marker lines
function Find-BlockRegion([string] $text, [string] $startMarker, [string] $endMarker) {
    $m = [regex]::Match($text, '(?m)^[ \t]*' + [regex]::Escape($startMarker) + '[^\r\n]*$')
    if (-not $m.Success) { return $null }
    $rest = $text.Substring($m.Index + $m.Length)
    $e = [regex]::Match($rest, '(?m)^[ \t]*' + [regex]::Escape($endMarker) + '[^\r\n]*$')
    if (-not $e.Success) { return @{ Start = $m.Index; End = -1 } }
    return @{ Start = $m.Index; End = $m.Index + $m.Length + $e.Index + $e.Length }
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
if ($SettingsPath) {
    if (-not (Test-Path -LiteralPath $SettingsPath)) { throw "no settings.json at $SettingsPath" }
    $SettingsPath = (Resolve-Path -LiteralPath $SettingsPath).Path
}

# ── the scheme objects ─────────────────────────────────────────────────────
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

$schemeBlock = ($objects -join ",`n") + ','
$activated = $false

if ($SettingsPath) {
    $text = Read-Text $SettingsPath
    $original = $text
    $indent = '            '

    # ── schemes ──────────────────────────────────────────────────────────
    $schemesOpen = Find-ArrayOpen $text 'schemes'
    if ($schemesOpen -lt 0) {
        # no "schemes" key at all: create one as the last root member
        $close = $text.LastIndexOf('}')
        if ($close -lt 0) { throw "$SettingsPath does not look like JSON; nothing was changed." }
        $head = $text.Substring(0, $close).TrimEnd()
        if (-not ($head.EndsWith('{') -or $head.EndsWith(','))) { $head += ',' }
        $body = ($schemeBlock -split "`n" | ForEach-Object { "    $_" }) -join "`n"
        $text = $head + "`n    `"schemes`": [`n" + $body + "`n    ]`n" + $text.Substring($close)
        $schemesOpen = Find-ArrayOpen $text 'schemes'
    }

    # a file that lost its markers keeps duplicates otherwise: sweep stray schemes
    $spans = Get-ObjectSpans $text $schemesOpen
    if ($spans.Count -gt 1) { [array]::Reverse($spans) }
    foreach ($span in $spans) {
        $block = $text.Substring($span.Start, $span.End - $span.Start)
        $before = $text.Substring(0, $span.Start)
        $insideBlock = $before.LastIndexOf($begin) -gt $before.LastIndexOf($end)
        if ($block -match '"name"\s*:\s*"Yorumi ' -and -not $insideBlock) {
            $text = $text.Substring(0, $span.Start) + $text.Substring($span.End).TrimStart("`r", "`n", ' ', ',')
        }
    }

    $region = Find-BlockRegion $text $begin $end
    if ($region -and $region.End -lt 0) {
        throw "yorumi: $SettingsPath has a '$begin' with no '$end'. Nothing was changed; delete that line and run this again."
    }
    if ($region) {
        $text = $text.Substring(0, $region.Start) + $indent + $begin + "`n" +
            (($schemeBlock -split "`n" | ForEach-Object { "$indent$_" }) -join "`n") + "`n$indent" + $end +
            $text.Substring($region.End)
    } else {
        $schemesOpen = Find-ArrayOpen $text 'schemes'
        $text = $text.Substring(0, $schemesOpen) + "`n$indent" + $begin + "`n" +
            (($schemeBlock -split "`n" | ForEach-Object { "$indent$_" }) -join "`n") + "`n$indent" + $end + "`n" +
            $text.Substring($schemesOpen)
    }

    # ── activation: a block inside profiles.defaults ──────────────────────
    $wantActivate = Confirm-NeedsAsk -yes:$Activate -no:$NoActivate
    if ($null -eq $wantActivate) {
        $wantActivate = Ask-YesNo "Set '$schemeName' on every Windows Terminal profile (profiles.defaults)?"
    }
    if ($wantActivate) {
        $profilesOpen = Find-ObjectOpen $text 'profiles'
        if ($profilesOpen -lt 0) {
            Write-Warning "this settings.json has no 'profiles' object (old array layout?); set the scheme in Settings instead."
        } else {
            $defaultsOpen = Find-ObjectOpen $text 'defaults'
            if ($defaultsOpen -lt 0) {
                $text = $text.Substring(0, $profilesOpen) + "`n        `"defaults`": {`n        }" + $text.Substring($profilesOpen)
                $defaultsOpen = Find-ObjectOpen $text 'defaults'
            }
            # drop a stray key outside the block, so the file cannot end up with two
            $head = $text.Substring(0, $defaultsOpen)
            $tail = $text.Substring($defaultsOpen)
            $tail = [regex]::Replace($tail, '^\s*"colorScheme"\s*:\s*"[^"]*"\s*,?', '', 1)
            $text = $head + $tail

            $keyLine = '"colorScheme": "' + $schemeName + '",'
            $choice = Find-BlockRegion $text $choiceBegin $choiceEnd
            if ($choice -and $choice.End -lt 0) {
                throw "yorumi: $SettingsPath has a '$choiceBegin' with no '$choiceEnd'. Nothing was changed."
            }
            if ($choice) {
                $text = $text.Substring(0, $choice.Start) + "        " + $choiceBegin + "`n        " + $keyLine +
                    "`n        " + $choiceEnd + $text.Substring($choice.End)
            } else {
                $defaultsOpen = Find-ObjectOpen $text 'defaults'
                $text = $text.Substring(0, $defaultsOpen) + "`n        " + $choiceBegin + "`n        " + $keyLine +
                    "`n        " + $choiceEnd + "`n" + $text.Substring($defaultsOpen)
            }
        }
    }

    # ── validate, then write once ────────────────────────────────────────
    try {
        $parsed = ConvertTo-StrictJson $text | ConvertFrom-Json
        $names = @($parsed.schemes | ForEach-Object { $_.name })
        foreach ($f in $flavours) {
            $want = 'Yorumi ' + $f.Substring(0, 1).ToUpper() + $f.Substring(1)
            if ($names -notcontains $want) { throw "scheme '$want' did not survive the merge" }
        }
        if ($wantActivate -and $parsed.profiles.defaults.colorScheme -ne $schemeName) {
            throw 'profiles.defaults.colorScheme did not stick'
        }
    } catch {
        throw "the merged settings.json did not validate ($($_.Exception.Message)); $SettingsPath is unchanged."
    }

    if ($text -ne $original) {
        $backup = "$SettingsPath.yorumi-backup"
        if (-not (Test-Path -LiteralPath $backup)) { Copy-Item -LiteralPath $SettingsPath -Destination $backup }
        Write-Text $SettingsPath $text
        Write-Host "settings.json updated: $SettingsPath (backup: $backup)"
    } else {
        Write-Host "settings.json already current: $SettingsPath"
    }
    $activated = [bool]$wantActivate

    if ($activated) {
        Write-Host "profiles.defaults now uses '$schemeName'"
        $listOpen = Find-ArrayOpen $text 'list'
        if ($listOpen -ge 0) {
            $pinned = @()
            foreach ($span in (Get-ObjectSpans $text $listOpen)) {
                $block = $text.Substring($span.Start, $span.End - $span.Start)
                if ($block -match '"colorScheme"\s*:') {
                    $nm = [regex]::Match($block, '"name"\s*:\s*"([^"]+)"')
                    $pinned += $(if ($nm.Success) { $nm.Groups[1].Value } else { '(unnamed profile)' })
                }
            }
            if ($pinned.Count -gt 0) {
                Write-Host "note: these profiles keep their own scheme: $($pinned -join ', ')"
            }
        }
    }
}

# ── the PowerShell prompt ──────────────────────────────────────────────────
$wantPowerShell = Confirm-NeedsAsk -yes:$InstallPowerShell -no:$NoInstallPowerShell
if ($null -eq $wantPowerShell) {
    $wantPowerShell = Ask-YesNo 'Also theme the PowerShell prompt itself (yorumi for PowerShell)?'
}
if ($wantPowerShell) {
    if (-not $PowerShellInstaller -and $PSScriptRoot) {
        $sibling = Join-Path (Split-Path -Path $PSScriptRoot -Parent) 'powershell\install.ps1'
        if (Test-Path -LiteralPath $sibling) { $PowerShellInstaller = $sibling }
    }
    if ($PowerShellInstaller -and (Test-Path -LiteralPath $PowerShellInstaller)) {
        & $PowerShellInstaller -Flavour $Flavour
    } else {
        $ps = Invoke-WebRequest -UseBasicParsing -Uri 'https://raw.githubusercontent.com/yorumicolors/powershell/main/install.ps1'
        & ([scriptblock]::Create($ps.Content)) -Flavour $Flavour
    }
}

Write-Host ''
if (-not $SettingsPath) {
    Write-Host 'Next:'
    Write-Host "  paste the scheme objects from this folder into the `"schemes`" array, then set"
    Write-Host "  `"colorScheme`": `"$schemeName`" on a profile."
} elseif (-not $activated) {
    Write-Host 'Next:'
    Write-Host "  Windows Terminal → Settings → your profile → Appearance → Colour scheme → $schemeName"
    Write-Host '  (or re-run with -Activate to set it for every profile)'
} else {
    Write-Host "Next: reopen Windows Terminal tabs to see $schemeName."
}
