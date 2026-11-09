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
    the uninstall. Activation is a second, separately marked block, kept last in
    "profiles.defaults" and replacing any direct "colorScheme" already there
    (a name, or the light/dark object):

        // >>> yorumi colorScheme >>>
        "colorScheme": "Yorumi Ether"
        // <<< yorumi colorScheme <<<

    Both are asked for. Nothing is applied when there is nobody to answer
    (-NonInteractive, or piped input).
.PARAMETER Flavour
    Scheme to activate and to hand to the PowerShell installer. Required when
    -Activate or -InstallPowerShell will run; a plain install needs none.
.PARAMETER SettingsPath
    settings.json to edit. Default: the first Windows Terminal settings.json found.
    Naming one is also what lets the script run off Windows (WSL, CI).
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
    [string] $Flavour = '',
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
$interactive = -not $NonInteractive -and -not [Console]::IsInputRedirected
if ($Activate -and $NoActivate) { throw '-Activate and -NoActivate are mutually exclusive.' }
if ($InstallPowerShell -and $NoInstallPowerShell) { throw '-InstallPowerShell and -NoInstallPowerShell are mutually exclusive.' }
# two independent regions: the schemes, and the scheme choice
$begin = '// >>> yorumi >>>'
$end = '// <<< yorumi <<<'
$choiceBegin = '// >>> yorumi colorScheme >>>'
$choiceEnd = '// <<< yorumi colorScheme <<<'

# ── helpers ────────────────────────────────────────────────────────────────
function Read-Text([string] $path) { return [IO.File]::ReadAllText($path) }

# settings.json is UTF-8 JSONC. A BOM is kept exactly as it was - none is added,
# because other parsers choke on one - and bytes that are not UTF-8 are refused
# instead of being rewritten with replacement characters.
function Read-Settings([string] $path) {
    $bytes = [IO.File]::ReadAllBytes($path)
    $bom = [byte[]] @()
    $body = $bytes
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        $bom = [byte[]] ($bytes[0..2])
        $body = if ($bytes.Length -gt 3) { [byte[]] ($bytes[3..($bytes.Length - 1)]) } else { [byte[]] @() }
    }
    try {
        $text = (New-Object System.Text.UTF8Encoding($false, $true)).GetString($body)
    } catch {
        throw "$path is not valid UTF-8, so it was not touched. Save it as UTF-8 and run this again."
    }
    return @{ Text = $text; Bom = $bom }
}

# --- a settings.json that may be a link --------------------------------------
#
# The chain is followed to the file it names and only that file is rewritten, so
# a link survives. Resolution happens before anything is written, so a dangling
# or cyclic link stops the run with the file untouched. 5.1 has no
# ResolveLinkTarget, so the provider's target property is walked.

function Test-PathEntry([string] $path) {
    # true for a dangling link too: the entry exists, its target does not
    try {
        [void][IO.File]::GetAttributes($path)
        return $true
    } catch [System.IO.IOException] {
        return $false
    } catch [System.UnauthorizedAccessException] {
        throw "'$path' cannot be read: access denied."
    }
}

function Get-LinkTarget([string] $path) {
    $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
    $target = $null
    if ($item.PSObject.Properties['LinkTarget']) { $target = $item.LinkTarget }
    if (-not $target -and $item.PSObject.Properties['Target']) { $target = $item.Target }
    if ($target -is [array]) {
        # 5.1 hands a symbolic link's target back as a one-element string[]
        if ($target.Count -ne 1) {
            throw "'$path' is a link with $($target.Count) targets; refusing to follow it."
        }
        $target = $target[0]
    }
    if ([string]::IsNullOrWhiteSpace([string] $target)) {
        throw "'$path' is a reparse point this PowerShell cannot follow; it was left alone."
    }
    return [string] $target
}

function Resolve-TargetPath([string] $path) {
    $full = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($path)
    for ($hops = 0; $hops -lt 40; $hops++) {
        if (-not (Test-PathEntry $full)) {
            # File.Exists is true for a dangling link on some hosts, so a hop
            # that ends at a missing entry is the evidence of a broken chain
            if ($hops -gt 0) {
                throw "'$path' is a symbolic link whose target does not exist. The link was left alone; repair or remove it and run this again."
            }
            return @{ Path = $full; Exists = $false; IsDirectory = $false }
        }
        $attrs = [IO.File]::GetAttributes($full)
        if ((([int] $attrs) -band [int] ([IO.FileAttributes]::ReparsePoint)) -eq 0) {
            return @{ Path = $full; Exists = $true; IsDirectory = [IO.Directory]::Exists($full) }
        }
        $target = Get-LinkTarget $full
        $next = if ([IO.Path]::IsPathRooted($target)) { $target } else { Join-Path (Split-Path -Path $full -Parent) $target }
        $full = [IO.Path]::GetFullPath($next)
    }
    throw "'$path' has more than 40 symbolic links in its chain; refusing to follow it."
}

# Swap $temp (already holding the new bytes) in for $path: one File.Replace for
# an existing file, which renames and hands the replacement the destination's
# ACLs and creation time without the ignore-metadata option, or one File.Move
# for a new one. A failure propagates - the original is left as it was and there
# is no second, non-atomic mutation route.
function Move-FileIntoPlace([string] $temp, [string] $path, [string] $backup) {
    if (-not [IO.File]::Exists($path)) {
        [IO.File]::Move($temp, $path)
        return
    }
    # the first backup is the pristine file; later runs must not overwrite it.
    # $backup is typed [string], so "no backup" arrives as '', and even a literal
    # $null would bind as '' too - NullString::Value is what hands .NET a real null
    if ([string]::IsNullOrEmpty($backup) -or (Test-PathEntry $backup)) {
        [IO.File]::Replace($temp, $path, [System.Management.Automation.Language.NullString]::Value)
    } else {
        [IO.File]::Replace($temp, $path, $backup)
    }
}

function Write-FileAtomic([string] $path, [byte[]] $bytes, [string] $backup) {
    # fail closed before a temp exists: a protected target (macOS uchg, read-only
    # attribute, ACL deny) cannot be replaced either, and copying its flags onto a
    # temp would leave a file that cannot even be removed
    if ([IO.File]::Exists($path)) {
        $probe = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
        $probe.Dispose()
    }
    $temp = "$path.yorumi-tmp.$([IO.Path]::GetRandomFileName())"
    try {
        if ([IO.File]::Exists($path)) {
            # overwrite=false makes Copy the exclusive create, and it carries the
            # original's owner, mode and attributes onto the temp first
            [IO.File]::Copy($path, $temp, $false)
            $mode = [IO.FileMode]::Truncate
        } else {
            $mode = [IO.FileMode]::CreateNew
        }
        $stream = [IO.File]::Open($temp, $mode, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try {
            $stream.Write($bytes, 0, $bytes.Length)
        } finally {
            $stream.Dispose()
        }
        Move-FileIntoPlace $temp $path $backup
        $temp = $null
    } finally {
        if ($temp -and (Test-PathEntry $temp)) {
            Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
        }
    }
}

# index just past the "[" of "key": [  (or -1)
function Find-ArrayOpen([string] $text, [string] $key) {
    $m = [regex]::Match($text, '"' + [regex]::Escape($key) + '"\s*:\s*\[')
    if ($m.Success) { return $m.Index + $m.Length }
    return -1
}

# ── JSONC structure ────────────────────────────────────────────────────────
# A key name can also appear inside a string or a comment, so the objects the
# script edits are found by walking the braces, never by a regex over the text.

# index just past the string that opens at $i (an opening quote)
function Get-StringEnd([string] $text, [int] $i) {
    for ($j = $i + 1; $j -lt $text.Length; $j++) {
        if ($text[$j] -eq '\') { $j++; continue }
        if ($text[$j] -eq '"') { return $j + 1 }
    }
    return $text.Length
}

# index of the first character after whitespace and comments
function Skip-JsoncTrivia([string] $text, [int] $i) {
    while ($i -lt $text.Length) {
        $c = $text[$i]
        if ([char]::IsWhiteSpace($c)) { $i++; continue }
        if ($c -eq '/' -and $i + 1 -lt $text.Length) {
            if ($text[$i + 1] -eq '/') {
                while ($i -lt $text.Length -and $text[$i] -ne "`n") { $i++ }
                continue
            }
            if ($text[$i + 1] -eq '*') {
                $close = $text.IndexOf('*/', $i + 2)
                if ($close -lt 0) { return $text.Length }
                $i = $close + 2
                continue
            }
        }
        break
    }
    return $i
}

# index just past the value at $i: a string, an object, an array, or a scalar
function Get-ValueEnd([string] $text, [int] $i) {
    if ($text[$i] -eq '"') { return Get-StringEnd $text $i }
    if ($text[$i] -eq '{' -or $text[$i] -eq '[') {
        $depth = 0
        for ($j = $i; $j -lt $text.Length; $j++) {
            $d = $text[$j]
            if ($d -eq '"') { $j = (Get-StringEnd $text $j) - 1; continue }
            if ($d -eq '/' -and $j + 1 -lt $text.Length -and ($text[$j + 1] -eq '/' -or $text[$j + 1] -eq '*')) {
                $j = (Skip-JsoncTrivia $text $j) - 1
                continue
            }
            if ($d -eq '{' -or $d -eq '[') { $depth++ }
            elseif ($d -eq '}' -or $d -eq ']') {
                $depth--
                if ($depth -eq 0) { return $j + 1 }
            }
        }
        return $text.Length
    }
    $j = $i
    while ($j -lt $text.Length) {
        $d = $text[$j]
        if ($d -eq ',' -or $d -eq '}' -or $d -eq ']' -or $d -eq '/' -or [char]::IsWhiteSpace($d)) { break }
        $j++
    }
    return $j
}

# the string a JSON string literal spells; ConvertFrom-Json handles the escapes
function ConvertFrom-JsonString([string] $literal) {
    if ($literal.IndexOf('\') -lt 0) { return $literal.Substring(1, $literal.Length - 2) }
    return ConvertFrom-Json -InputObject $literal
}

# direct members of the object whose "{" is at $open, in file order:
# Start = the key's opening quote, End = just past the value
function Get-ObjectMembers([string] $text, [int] $open) {
    $members = @()
    $i = Skip-JsoncTrivia $text ($open + 1)
    while ($i -lt $text.Length -and $text[$i] -eq '"') {
        $keyEnd = Get-StringEnd $text $i
        # the key literal, quotes and all: "color\u0053cheme" is "colorScheme"
        $name = ConvertFrom-JsonString ($text.Substring($i, $keyEnd - $i))
        $colon = Skip-JsoncTrivia $text $keyEnd
        if ($colon -ge $text.Length -or $text[$colon] -ne ':') { break }
        $valueStart = Skip-JsoncTrivia $text ($colon + 1)
        if ($valueStart -ge $text.Length) { break }
        $members += @{
            Start = $i
            Name = $name
            ValueStart = $valueStart
            End = (Get-ValueEnd $text $valueStart)
        }
        $i = Skip-JsoncTrivia $text $members[$members.Count - 1].End
        if ($i -lt $text.Length -and $text[$i] -eq ',') { $i = Skip-JsoncTrivia $text ($i + 1) }
        else { break }
    }
    return $members
}

function Find-Member([string] $text, [int] $open, [string] $name) {
    foreach ($member in Get-ObjectMembers $text $open) {
        if ($member.Name -ceq $name) { return $member }
    }
    return $null
}

# the whitespace that starts the line containing $i
function Get-LineIndent([string] $text, [int] $i) {
    $start = $i
    while ($start -gt 0 -and $text[$start - 1] -ne "`n") { $start-- }
    $lead = ''
    while ($start + $lead.Length -lt $i -and ($text[$start + $lead.Length] -eq ' ' -or $text[$start + $lead.Length] -eq "`t")) {
        $lead += $text[$start + $lead.Length]
    }
    return $lead
}

# the root object and the "profiles" / "profiles.defaults" objects: the index
# of each "{", or -1. HasDefaults separates "absent" from "not an object".
function Find-ProfilesDefaults([string] $text) {
    $found = @{ Root = -1; Profiles = -1; Defaults = -1; HasDefaults = $false }
    $root = Skip-JsoncTrivia $text 0
    if ($root -ge $text.Length -or $text[$root] -ne '{') { return $found }
    $found.Root = $root
    $profiles = Find-Member $text $root 'profiles'
    if (-not $profiles -or $text[$profiles.ValueStart] -ne '{') { return $found }
    $found.Profiles = $profiles.ValueStart
    $defaults = Find-Member $text $profiles.ValueStart 'defaults'
    if ($defaults) {
        $found.HasDefaults = $true
        if ($text[$defaults.ValueStart] -eq '{') { $found.Defaults = $defaults.ValueStart }
    }
    return $found
}

# drop one member and the comma that belongs with it; a member alone on its
# line takes that line with it, and the comments around it stay.
# $prevEnd is the end of the member before it, or -1 when it is the first.
function Remove-JsoncMember([string] $text, [hashtable] $member, [int] $prevEnd) {
    $start = $member.Start
    $end = $member.End
    # the separator is the first real token after the value; a comment may sit
    # on either side of it, so the comma is removed on its own and the comment
    # bytes stay where they are
    $shift = 0
    $next = Skip-JsoncTrivia $text $end
    if ($next -lt $text.Length -and $text[$next] -eq ',') {
        $text = $text.Remove($next, 1)
    } elseif ($prevEnd -ge 0) {
        # the last member of its object: drop the separator that follows the
        # member before it — never a comma that sits inside a comment
        $sep = Skip-JsoncTrivia $text $prevEnd
        if ($sep -ge 0 -and $sep -lt $start -and $text[$sep] -eq ',') {
            $text = $text.Remove($sep, 1)
            $shift = 1
        }
    }
    $start -= $shift
    $end -= $shift
    $lineStart = $start
    while ($lineStart -gt 0 -and $text[$lineStart - 1] -ne "`n") { $lineStart-- }
    $lineEnd = $end
    while ($lineEnd -lt $text.Length -and $text[$lineEnd] -ne "`n") { $lineEnd++ }
    $ownLine = (-not $text.Substring($lineStart, $start - $lineStart).Trim()) -and
        (-not $text.Substring($end, $lineEnd - $end).Trim())
    if ($ownLine) {
        if ($lineEnd -lt $text.Length) { $lineEnd++ }
        return $text.Remove($lineStart, $lineEnd - $lineStart)
    }
    return $text.Remove($start, $end - $start)
}

# index after the line break that starts at $i, if there is one
function Get-LineBreakEnd([string] $text, [int] $i) {
    if ($i -lt $text.Length -and $text[$i] -eq "`r") { $i++ }
    if ($i -lt $text.Length -and $text[$i] -eq "`n") { $i++ }
    return $i
}

# the managed marker pairs inside [$from, $to), which must open and close in
# order and never nest
function Get-ManagedPairs([string] $text, [int] $from, [int] $to, [string] $startMarker, [string] $endMarker, [string] $path) {
    $pattern = '(?m)^[ \t]*(' + [regex]::Escape($startMarker) + '|' + [regex]::Escape($endMarker) + ')[ \t]*\r?$'
    $pairs = @()
    $openAt = -1
    foreach ($m in [regex]::Matches($text.Substring($from, $to - $from), $pattern)) {
        $lineStart = $from + $m.Index
        $lineEnd = $lineStart + $m.Length
        if ($m.Value.TrimStart().StartsWith($startMarker)) {
            if ($openAt -ge 0) {
                throw "yorumi: $path has a '$startMarker' inside another yorumi block. Nothing was changed."
            }
            $openAt = $lineStart
        } else {
            if ($openAt -lt 0) {
                throw "yorumi: $path has a '$endMarker' before its '$startMarker'. Nothing was changed."
            }
            $pairs += @{ Start = $openAt; End = (Get-LineBreakEnd $text $lineEnd) }
            $openAt = -1
        }
    }
    if ($openAt -ge 0) {
        throw "yorumi: $path has a '$startMarker' with no '$endMarker'. Nothing was changed; delete that line and run this again."
    }
    return $pairs
}

# put $member (unindented, newline-separated lines) before the closing brace of
# the object at $open, as its last member, adding the comma it needs
function Add-LastMember([string] $text, [int] $open, [string] $member) {
    $members = @(Get-ObjectMembers $text $open)
    $close = (Get-ValueEnd $text $open) - 1
    # indentation comes from the object's opening line: the closing brace may be
    # inline now and on its own line after this insert, and moving it must not
    # move the block on the next run
    $lead = Get-LineIndent $text $open
    $indent = $lead + '    '
    $lines = $member -split "`n" | ForEach-Object { if ($_.Trim()) { $indent + $_ } else { '' } }
    $lines = $lines -join "`n"
    if ($members.Count -eq 0) {
        $before = $close
        while ($before -gt $open + 1 -and [char]::IsWhiteSpace($text[$before - 1])) { $before-- }
        return $text.Substring(0, $before) + "`n" + $lines + "`n" + $lead + $text.Substring($close)
    }
    $at = $members[$members.Count - 1].End
    # the separator is the first real token after the value, whatever comments
    # sit between them
    $next = Skip-JsoncTrivia $text $at
    if ($next -lt $text.Length -and $text[$next] -eq ',') {
        $at = $next + 1
    } else {
        $text = $text.Insert($at, ',')
        $at++
    }
    # the block must end on its own terminated line: keep a line break that is
    # already there, otherwise add one
    $rest = $text.Substring($at)
    $k = 0
    while ($k -lt $rest.Length -and ($rest[$k] -eq ' ' -or $rest[$k] -eq "`t")) { $k++ }
    if ($k -lt $rest.Length -and ($rest[$k] -eq "`r" -or $rest[$k] -eq "`n")) {
        $rest = $rest.Substring($k)
    } else {
        $rest = "`n" + $rest
    }
    return $text.Substring(0, $at) + "`n" + $lines + $rest
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

# ── what runs beside the install ───────────────────────────────────────────
# The flavour chooses what is activated, not what is installed: all seven
# schemes always go into settings.json.
$wantActivate = Confirm-NeedsAsk -yes:$Activate -no:$NoActivate
if ($null -eq $wantActivate) {
    $wantActivate = Ask-YesNo 'Use a yorumi scheme as the Windows Terminal default (profiles.defaults)?'
}
$wantPowerShell = Confirm-NeedsAsk -yes:$InstallPowerShell -no:$NoInstallPowerShell
if ($null -eq $wantPowerShell) {
    $wantPowerShell = Ask-YesNo 'Also theme the PowerShell prompt itself (yorumi for PowerShell)?'
}

# only an activated terminal or a themed prompt has a flavour to name; a plain
# install writes all seven schemes and never asks for one
if (($wantActivate -or $wantPowerShell) -and -not $Flavour) {
    if (-not $interactive) {
        throw "no flavour given. pass -Flavour <name>: $($flavours -join ', ')"
    }
    for ($i = 0; $i -lt $flavours.Count; $i++) {
        Write-Host ("  {0}) {1}" -f ($i + 1), $flavours[$i])
    }
    while (-not $Flavour) {
        $answer = Read-Host "flavour (1-$($flavours.Count) or a name)"
        if (-not $answer) { continue }
        if ($answer -match '^\d+$' -and [int]$answer -ge 1 -and [int]$answer -le $flavours.Count) {
            $Flavour = $flavours[[int]$answer - 1]
        } elseif ($flavours -contains $answer) {
            $Flavour = $answer
        } else {
            Write-Warning "not a flavour: $answer"
        }
    }
}
if ($Flavour -and $flavours -notcontains $Flavour) {
    throw "unknown flavour '$Flavour'. One of: $($flavours -join ', ')"
}
if ($Flavour) { $Flavour = $Flavour.ToLower() }
# an install-only run has no flavour, so it has no scheme to name: nothing is
# invented, and the summary says where to pick one instead
$schemeName = ''
if ($Flavour) {
    $schemeName = 'Yorumi ' + $Flavour.Substring(0, 1).ToUpper() + $Flavour.Substring(1)
}
# the seven names this script owns; nothing else in "schemes" is touched
$ourNames = @($flavours | ForEach-Object { 'Yorumi ' + $_.Substring(0, 1).ToUpper() + $_.Substring(1) })

# ── find settings.json ─────────────────────────────────────────────────────
$isWindowsHost = ($env:OS -eq 'Windows_NT')
if (-not $isWindowsHost -and -not $SettingsPath) {
    Write-Host 'Windows Terminal runs on Windows only - run this installer there.'
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
    try { $settingsTarget = Resolve-TargetPath $SettingsPath } catch { throw "settings.json was not touched: $($_.Exception.Message)" }
    if (-not $settingsTarget.Exists) { throw "no settings.json at $SettingsPath" }
    if ($settingsTarget.IsDirectory) { throw "$SettingsPath is a directory, not settings.json." }
    $settingsReal = $settingsTarget.Path
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
    $settings = Read-Settings $settingsReal
    $text = $settings.Text
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

    # a file that lost its markers keeps duplicates otherwise: sweep stray
    # schemes, but only the seven this script owns — a user scheme that merely
    # starts with "Yorumi" is theirs. Ownership is the object's own direct
    # "name" member, never a nested key or a comment that mentions one.
    $spans = Get-ObjectSpans $text $schemesOpen
    if ($spans.Count -gt 1) { [array]::Reverse($spans) }
    foreach ($span in $spans) {
        $names = @(Get-ObjectMembers $text $span.Start | Where-Object { $_.Name -ceq 'name' })
        if ($names.Count -ne 1) { continue }
        $value = $text.Substring($names[0].ValueStart, $names[0].End - $names[0].ValueStart)
        if ($value.Length -lt 2 -or $value[0] -ne '"' -or $value[$value.Length - 1] -ne '"') { continue }
        $before = $text.Substring(0, $span.Start)
        $insideBlock = $before.LastIndexOf($begin) -gt $before.LastIndexOf($end)
        if ($ourNames -ccontains (ConvertFrom-JsonString $value) -and -not $insideBlock) {
            $text = $text.Substring(0, $span.Start) + $text.Substring($span.End).TrimStart("`r", "`n", ' ', ',')
        }
    }

    # our markers are checked before anything is rewritten: opening and closing
    # in order, never nested, never left unpaired
    $regions = @(Get-ManagedPairs $text 0 $text.Length $begin $end $SettingsPath)
    for ($i = $regions.Count - 1; $i -ge 1; $i--) {
        $text = $text.Remove($regions[$i].Start, $regions[$i].End - $regions[$i].Start)
    }
    $body = ($schemeBlock -split "`n" | ForEach-Object { "$indent$_" }) -join "`n"
    if ($regions.Count -gt 0) {
        $text = $text.Substring(0, $regions[0].Start) + $indent + $begin + "`n" +
            $body + "`n" + $indent + $end + "`n" + $text.Substring($regions[0].End)
    } else {
        $schemesOpen = Find-ArrayOpen $text 'schemes'
        $text = $text.Substring(0, $schemesOpen) + "`n$indent" + $begin + "`n" +
            $body + "`n$indent" + $end + "`n" +
            $text.Substring($schemesOpen)
    }

    # ── activation: one managed block inside profiles.defaults ────────────
    if ($wantActivate) {
        $found = Find-ProfilesDefaults $text
        if ($found.Root -lt 0) {
            throw "$SettingsPath does not look like JSON; nothing was changed."
        }
        if ($found.Profiles -lt 0) {
            Write-Warning "this settings.json has no 'profiles' object (old array layout?); set the scheme in Settings instead."
        } elseif ($found.HasDefaults -and $found.Defaults -lt 0) {
            Write-Warning "'profiles.defaults' is not an object; set the scheme in Settings instead."
        } else {
            # our block may have been left anywhere: take every copy out first
            $pairs = @(Get-ManagedPairs $text 0 $text.Length $choiceBegin $choiceEnd $SettingsPath)
            for ($i = $pairs.Count - 1; $i -ge 0; $i--) {
                $text = $text.Remove($pairs[$i].Start, $pairs[$i].End - $pairs[$i].Start)
            }
            # a colorScheme outside the block — a name, or the light/dark
            # object — would duplicate ours and break the file
            while ($true) {
                $found = Find-ProfilesDefaults $text
                if ($found.Defaults -lt 0) { break }
                $members = @(Get-ObjectMembers $text $found.Defaults)
                $at = -1
                for ($n = 0; $n -lt $members.Count; $n++) {
                    if ($members[$n].Name -ceq 'colorScheme') { $at = $n; break }
                }
                if ($at -lt 0) { break }
                $prevEnd = -1
                if ($at -gt 0) { $prevEnd = $members[$at - 1].End }
                $text = Remove-JsoncMember $text $members[$at] $prevEnd
            }
            $found = Find-ProfilesDefaults $text
            if ($found.Defaults -lt 0) {
                $text = Add-LastMember $text $found.Profiles '"defaults": {}'
                $found = Find-ProfilesDefaults $text
            }
            $choice = $choiceBegin + "`n" + '"colorScheme": "' + $schemeName + '"' + "`n" + $choiceEnd
            $text = Add-LastMember $text $found.Defaults $choice
            $activated = $true
        }
    }

    # keep the file's own line endings: everything inserted above used "`n"
    if ($original.Contains("`r`n")) { $text = [regex]::Replace($text, "`r?`n", "`r`n") }

    # ── validate, then write once ────────────────────────────────────────
    try {
        $parsed = ConvertTo-StrictJson $text | ConvertFrom-Json
        $names = @($parsed.schemes | ForEach-Object { $_.name })
        foreach ($f in $flavours) {
            $want = 'Yorumi ' + $f.Substring(0, 1).ToUpper() + $f.Substring(1)
            if ($names -notcontains $want) { throw "scheme '$want' did not survive the merge" }
        }
        if ($activated) {
            $found = Find-ProfilesDefaults $text
            if ($found.Defaults -lt 0) { throw 'profiles.defaults did not survive the merge' }
            $pairs = @(Get-ManagedPairs $text 0 $text.Length $choiceBegin $choiceEnd $SettingsPath)
            if ($pairs.Count -ne 1) { throw "expected one yorumi colorScheme block, found $($pairs.Count)" }
            $members = @(Get-ObjectMembers $text $found.Defaults | Where-Object { $_.Name -ceq 'colorScheme' })
            if ($members.Count -ne 1) { throw "expected one profiles.defaults.colorScheme, found $($members.Count)" }
            $value = $text.Substring($members[0].ValueStart, $members[0].End - $members[0].ValueStart)
            if ($value -ne ('"' + $schemeName + '"')) { throw 'profiles.defaults.colorScheme did not stick' }
            if ($members[0].Start -le $pairs[0].Start -or $members[0].End -ge $pairs[0].End) {
                throw 'profiles.defaults.colorScheme is not inside the yorumi block'
            }
            $defaultsClose = (Get-ValueEnd $text $found.Defaults) - 1
            if ($pairs[0].Start -le $found.Defaults -or $pairs[0].End -gt $defaultsClose) {
                throw 'the yorumi colorScheme block is outside profiles.defaults'
            }
            if ((Skip-JsoncTrivia $text $pairs[0].End) -ne $defaultsClose) {
                throw 'the yorumi colorScheme block is not last in profiles.defaults'
            }
            if ($parsed.profiles.defaults.colorScheme -ne $schemeName) {
                throw 'profiles.defaults.colorScheme did not stick'
            }
        }
    } catch {
        throw "the merged settings.json did not validate ($($_.Exception.Message)); $SettingsPath is unchanged."
    }

    if ($text -ne $original) {
        # written through the link: settings.json keeps its ACLs and stays
        # whatever it was, plain file or symlink
        $backup = "$settingsReal.yorumi-backup"
        $bytes = [byte[]] ($settings.Bom + (New-Object System.Text.UTF8Encoding($false)).GetBytes($text))
        Write-FileAtomic $settingsReal $bytes $backup
        Write-Host "settings.json updated: $SettingsPath (backup: $backup)"
    } else {
        Write-Host "settings.json already current: $SettingsPath"
    }

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
    if ($schemeName) {
        Write-Host "  `"colorScheme`": `"$schemeName`" in `"profiles.defaults`"."
    } else {
        Write-Host "  a yorumi scheme on `"profiles.defaults`" (Settings > your profile > Appearance)."
    }
} elseif (-not $activated) {
    Write-Host 'Next:'
    Write-Host '  Windows Terminal > Settings > your profile > Appearance > Colour scheme > pick a Yorumi scheme'
    Write-Host '  (or re-run with -Activate -Flavour <name> to set it in "profiles.defaults")'
} else {
    Write-Host "Next: reopen Windows Terminal tabs to see $schemeName."
}
