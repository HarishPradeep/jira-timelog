# Shared helpers for jira-timelog scripts. Windows PowerShell 5.1 compatible.
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$script:SkillDir   = Split-Path -Parent $PSScriptRoot
$script:UserDir    = Join-Path $HOME '.claude\jira-timelog'
$script:ConfigPath = Join-Path $script:UserDir 'config.json'
$script:StatePath  = Join-Path $script:UserDir 'state.json'

function Read-JsonFile([string]$Path) {
    if (-not (Test-Path $Path)) { return $null }
    $raw = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    return $raw | ConvertFrom-Json
}

function Write-JsonFile([string]$Path, $Object) {
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $json = ConvertTo-Json -InputObject $Object -Depth 12
    [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($false)))
}

function Out-Json($Object) { ConvertTo-Json -InputObject $Object -Depth 12 -Compress }

function Get-TeamDefaults { Read-JsonFile (Join-Path $script:SkillDir 'team-defaults.json') }
function Get-UserConfig   { Read-JsonFile $script:ConfigPath }

function Get-State {
    $s = Read-JsonFile $script:StatePath
    if (-not $s) { $s = [pscustomobject]@{ version = 1; worklogs = [pscustomobject]@{}; leave = [pscustomobject]@{}; lastRun = $null } }
    foreach ($p in 'worklogs', 'leave', 'days') {
        if (-not ($s.PSObject.Properties.Name -contains $p)) { $s | Add-Member -NotePropertyName $p -NotePropertyValue ([pscustomobject]@{}) }
    }
    return $s
}
function Save-State($State) { Write-JsonFile $script:StatePath $State }

# Effective setting: user config overrides team default.
function Get-Setting($Config, $Team, [string]$Name) {
    if ($Config -and ($Config.PSObject.Properties.Name -contains $Name) -and $null -ne $Config.$Name) { return $Config.$Name }
    if ($Team -and ($Team.PSObject.Properties.Name -contains $Name)) { return $Team.$Name }
    return $null
}

function Get-TzOffset($Team) {
    $tz = '+05:30'; if ($Team -and $Team.timezone) { $tz = $Team.timezone }
    $sign = if ($tz.StartsWith('-')) { -1 } else { 1 }
    $parts = $tz.TrimStart('+', '-').Split(':')
    return New-TimeSpan -Hours ($sign * [int]$parts[0]) -Minutes ($sign * [int]$parts[1])
}

function ConvertTo-LocalTime([string]$Iso, [TimeSpan]$Offset) {
    return [DateTimeOffset]::Parse($Iso, [Globalization.CultureInfo]::InvariantCulture).ToOffset($Offset)
}

function Get-IssueKeys([string]$Text) {
    if (-not $Text) { return @() }
    return @([regex]::Matches($Text, '\b[A-Z][A-Z0-9]+-\d+\b') | ForEach-Object { $_.Value } | Select-Object -Unique)
}
