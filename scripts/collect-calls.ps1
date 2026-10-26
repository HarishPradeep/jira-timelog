<#
.SYNOPSIS
  Measured meeting times from the new Teams client's local log (no calendar access needed).
  Teams keeps only about a day of logs, so every run first saves the call events it finds into
  ~/.claude/jira-timelog/calls.json; -Capture does only that (used by the scheduled task and hooks).
.DESCRIPTION
  Teams writes "OnIsInCallChanged Call became active" when a call starts and "LogCallEndedTelemetry
  Call ended" when it ends. Its timestamps carry a "+05:30" label but are UTC; the real offset is
  worked out per file from the local time in the file name, so a fixed label never shifts calls.
  Calls on a phone or in a browser are not in this log.
  Who a call was with comes from the Teams call history cached in its IndexedDB (LevelDB) folder:
  each record has start/connect/end (UTC), direction, 1:1 or group, and the participants' names.
  Records are saved into calls.json `peers` and attached to a logged call whose start is within 3 min;
  an accepted call found only in the history (log lost) is added as a call with source "history".
.EXAMPLE
  collect-calls.ps1 -Capture
  collect-calls.ps1 -From 2026-10-13
  collect-calls.ps1 -From 2026-10-12 -To 2026-10-16
  JSON: { teamsFound, days: [ { date, covered: [ { from, to } ], calls: [ { start, end, minutes, open } ],
          meetings: [ { name, start, scheduledMinutes, logCovered, call, measuredMinutes, usualMinutes, usualSamples } ],
          unscheduled: [ { start, end, minutes, open } ] } ], warnings }
  Each call also has: with (names, or null), direction (Incoming/Outgoing), callType (TwoParty/...), source (log/history).
#>
param([string]$From, [string]$To, [switch]$Capture)
. "$PSScriptRoot\common.ps1"

$logDir = Join-Path $env:LOCALAPPDATA 'Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\Logs'
$historyDir = Join-Path $env:LOCALAPPDATA 'Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\EBWebView\WV2Profile_tfw\IndexedDB\https_teams.microsoft.com_0.indexeddb.leveldb'
$callsPath = Join-Path $script:UserDir 'calls.json'
$team = Get-TeamDefaults
$config = Get-UserConfig
$tz = Get-TzOffset $team
$matchWindowMinutes = 15
$rejoinGapMinutes = 5
$peerMatchMinutes = 3
$historyFileDays = 7
$keepDays = 120

function Get-Store {
    $s = Read-JsonFile $callsPath
    if (-not $s) { $s = [pscustomobject]@{ version = 1; events = [pscustomobject]@{}; coverage = [pscustomobject]@{}; history = [pscustomobject]@{}; peers = [pscustomobject]@{} } }
    foreach ($p in 'events', 'coverage', 'history', 'peers') {
        if (-not ($s.PSObject.Properties.Name -contains $p)) { $s | Add-Member -NotePropertyName $p -NotePropertyValue ([pscustomobject]@{}) }
    }
    return $s
}
function Set-Prop($Object, [string]$Name, $Value) {
    if ($Object.PSObject.Properties.Name -contains $Name) { $Object.$Name = $Value } else { $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value }
}

# Log stamp "2026-10-13T04:01:37.704902+05:30 ..." -> the 19-char wall time; the label is ignored.
function Get-Stamp([string]$Line) {
    if ($Line.Length -lt 19) { return $null }
    $d = [datetime]::MinValue
    if ([datetime]::TryParseExact($Line.Substring(0, 19), 'yyyy-MM-ddTHH:mm:ss', [Globalization.CultureInfo]::InvariantCulture, 'None', [ref]$d)) { return $d }
    return $null
}

# Saves the call events and the covered time span per day from every Teams log still on disk.
function Save-TeamsEvents($Store) {
    if (-not (Test-Path $logDir)) { return $false }
    $files = @(Get-ChildItem $logDir -File -Filter 'MSTeams_2*.log' | Where-Object Length -gt 0)
    foreach ($f in $files) {
        if ($f.Name -notmatch '^MSTeams_(\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2})') { continue }
        $opened = [datetime]::ParseExact($Matches[1], 'yyyy-MM-dd_HH-mm-ss', $null)
        $first = Get-Stamp ([string](Get-Content $f.FullName -TotalCount 1))
        if (-not $first) { continue }
        # Skew between the file name (local) and the stamps, rounded to 15 min, then into the team zone.
        $skewMin = [math]::Round(($opened - $first).TotalMinutes / 15) * 15
        $pcToTeam = ($tz - [TimeZoneInfo]::Local.GetUtcOffset($opened)).TotalMinutes
        $shift = [TimeSpan]::FromMinutes($skewMin + $pcToTeam)
        $last = Get-Stamp ([string](Get-Content $f.FullName -Tail 1))
        if ($last) {
            $a = $first + $shift; $b = $last + $shift
            for ($d = $a.Date; $d -le $b.Date; $d = $d.AddDays(1)) {
                $key = $d.ToString('yyyy-MM-dd')
                $lo = if ($a -gt $d) { $a } else { $d }
                $hi = if ($b -lt $d.AddDays(1)) { $b } else { $d.AddDays(1).AddSeconds(-1) }
                Set-Prop $Store.coverage "$key|$($f.Name)" ([pscustomobject]@{ from = $lo.ToString('HH:mm'); to = $hi.ToString('HH:mm') })
            }
        }
        foreach ($hit in (Select-String -Path $f.FullName -Pattern 'OnIsInCallChanged|LogCallEndedTelemetry')) {
            $t = Get-Stamp $hit.Line
            if (-not $t) { continue }
            $kind = if ($hit.Line -match 'became active') { 'start' } elseif ($hit.Line -match 'LogCallEndedTelemetry|became inactive') { 'end' } else { $null }
            if ($kind) { Set-Prop $Store.events (($t + $shift).ToString('yyyy-MM-ddTHH:mm:ss')) $kind }
        }
    }
    # Drop old data.
    $cut = (Get-Date).AddDays(-$keepDays).ToString('yyyy-MM-dd')
    foreach ($bag in $Store.events, $Store.coverage, $Store.history, $Store.peers) {
        foreach ($n in @($bag.PSObject.Properties | ForEach-Object { $_.Name })) { if ($n.Substring(0, 10) -lt $cut) { $bag.PSObject.Properties.Remove($n) } }
    }
    return $true
}

# Reads a V8-serialised string value at $Pos of a Latin-1 decoded buffer (tag '"' one-byte, 'c' two-byte).
function Read-V8String([string]$T, [int]$Pos) {
    while ($Pos -lt $T.Length -and $T[$Pos] -eq [char]0) { $Pos++ }
    if ($Pos -ge $T.Length) { return $null }
    $tag = $T[$Pos]; $Pos++
    if ($tag -ne '"' -and $tag -ne 'c') { return $null }
    $len = 0; $shift = 0
    do {
        if ($Pos -ge $T.Length) { return $null }
        $b = [int]$T[$Pos]; $Pos++
        $len = $len -bor (($b -band 0x7f) -shl $shift); $shift += 7
    } while (($b -band 0x80) -and $shift -lt 35)
    if ($len -le 0 -or $Pos + $len -gt $T.Length -or $len -gt 400) { return $null }
    $s = $T.Substring($Pos, $len)
    if ($tag -eq 'c') { $s = [Text.Encoding]::Unicode.GetString([Text.Encoding]::GetEncoding(28591).GetBytes($s)) }
    return $s
}
function Get-V8Field([string]$Seg, [string]$Key) {
    $i = $Seg.IndexOf($Key)
    if ($i -lt 0) { return $null }
    return Read-V8String $Seg ($i + $Key.Length)
}

# Saves who each call was with, from the Teams call history in its local IndexedDB cache.
# Teams keeps the files open, so they are read with shared access; compressed blocks are simply skipped.
function Save-CallHistory($Store) {
    if (-not (Test-Path $historyDir)) { return $false }
    $latin1 = [Text.Encoding]::GetEncoding(28591)
    $me = if ($config -and $config.displayName) { [string]$config.displayName } else { '' }
    $since = (Get-Date).AddDays(-$historyFileDays)
    $files = @(Get-ChildItem $historyDir -File | Where-Object { ($_.Extension -in '.ldb', '.log') -and $_.LastWriteTime -ge $since })
    foreach ($f in $files) {
        try {
            $fs = [IO.File]::Open($f.FullName, 'Open', 'Read', 'ReadWrite,Delete')
            try { $ms = New-Object IO.MemoryStream; $fs.CopyTo($ms) } finally { $fs.Close() }
        } catch { continue }
        $t = $latin1.GetString($ms.ToArray())
        $anchors = @([regex]::Matches($t, 'callHistoryBucket') | ForEach-Object { $_.Index })
        for ($k = 0; $k -lt $anchors.Count; $k++) {
            $a = $anchors[$k]
            $b = if ($k + 1 -lt $anchors.Count) { $anchors[$k + 1] } else { [math]::Min($t.Length, $a + 6000) }
            $seg = $t.Substring($a, [math]::Min($b - $a, 6000))
            $callId = Get-V8Field $seg 'callId'
            $start = Get-V8Field $seg 'startTime'
            if (-not $callId -or $callId -notmatch '^[0-9a-f-]{36}$' -or -not $start) { continue }
            $state = Get-V8Field $seg 'callState'
            $end = Get-V8Field $seg 'endTime'
            $connect = Get-V8Field $seg 'connectTime'
            try {
                $s = (ConvertTo-LocalTime $start $tz).DateTime
                $c = if ($connect) { (ConvertTo-LocalTime $connect $tz).DateTime } else { $null }
                $e = if ($end) { (ConvertTo-LocalTime $end $tz).DateTime } else { $null }
            } catch { continue }
            $names = New-Object System.Collections.ArrayList
            foreach ($m in [regex]::Matches($seg, 'displayName')) {
                $n = Read-V8String $seg ($m.Index + 11)
                # Some copies are JSON text ("displayName":"…"), which reads as junk here; keep only name-like values.
                if ($n -and $n -match "^\p{L}[\p{L}\p{M} .'()-]{1,79}$" -and $n -ne $me -and -not $names.Contains($n)) { [void]$names.Add($n) }
            }
            $key = "$($s.ToString('yyyy-MM-ddTHH:mm:ss'))|$callId"
            $old = $Store.peers.PSObject.Properties[$key]
            # A later copy of the same record may carry the end time or more names; keep the fuller one.
            if ($old -and $old.Value.end -and -not $e) { continue }
            Set-Prop $Store.peers $key ([pscustomobject]@{
                connect = $(if ($c) { $c.ToString('yyyy-MM-ddTHH:mm:ss') } else { $null })
                end = $(if ($e) { $e.ToString('yyyy-MM-ddTHH:mm:ss') } else { $null })
                direction = (Get-V8Field $seg 'callDirection'); callType = (Get-V8Field $seg 'callType'); state = $state
                with = @($names)
            })
        }
    }
    return $true
}

# History records for a date as { s (start or connect), e, with, direction, callType }.
function Get-Peers($Store, [string]$Date) {
    @($Store.peers.PSObject.Properties | Where-Object { $_.Name.StartsWith($Date) } | ForEach-Object {
        $v = $_.Value
        $at = if ($v.connect) { $v.connect } else { $_.Name.Substring(0, 19) }
        [pscustomobject]@{
            s = [datetime]::ParseExact($at, 'yyyy-MM-ddTHH:mm:ss', $null)
            e = $(if ($v.end) { [datetime]::ParseExact($v.end, 'yyyy-MM-ddTHH:mm:ss', $null) } else { $null })
            with = @($v.with); direction = $v.direction; callType = $v.callType; state = $v.state
        }
    })
}

# Pairs start/end events into calls; joins a rejoin within a few minutes into one call.
function Get-Calls($Store, [string]$Date) {
    $evs = @($Store.events.PSObject.Properties | Where-Object { $_.Name.StartsWith($Date) } | Sort-Object Name |
        ForEach-Object { [pscustomobject]@{ at = [datetime]::ParseExact($_.Name, 'yyyy-MM-ddTHH:mm:ss', $null); kind = $_.Value } })
    $calls = New-Object System.Collections.ArrayList
    $open = $null
    foreach ($e in $evs) {
        if ($e.kind -eq 'start') {
            if ($open) { [void]$calls.Add([pscustomobject]@{ s = $open; e = $e.at; open = $true }) }
            $open = $e.at
        } elseif ($open) {
            [void]$calls.Add([pscustomobject]@{ s = $open; e = $e.at; open = $false }); $open = $null
        }
    }
    if ($open) { [void]$calls.Add([pscustomobject]@{ s = $open; e = $null; open = $true }) }
    $joined = New-Object System.Collections.ArrayList
    foreach ($c in $calls) {
        $prev = if ($joined.Count) { $joined[$joined.Count - 1] } else { $null }
        if ($prev -and $prev.e -and -not $prev.open -and ($c.s - $prev.e).TotalMinutes -le $rejoinGapMinutes) { $prev.e = $c.e; $prev.open = $c.open }
        else { [void]$joined.Add($c) }
    }
    # Attach who the call was with; an accepted history call with no log call (log lost) becomes a call itself.
    $peers = New-Object System.Collections.ArrayList
    foreach ($p in @(Get-Peers $Store $Date)) { [void]$peers.Add($p) }
    foreach ($c in $joined) {
        $c | Add-Member -NotePropertyName source -NotePropertyValue 'log'
        $hit = $peers | Where-Object { [math]::Abs(($_.s - $c.s).TotalMinutes) -le $peerMatchMinutes } |
            Sort-Object { [math]::Abs(($_.s - $c.s).TotalMinutes) } | Select-Object -First 1
        $c | Add-Member -NotePropertyName peer -NotePropertyValue $hit
        if ($hit) { [void]$peers.Remove($hit) }
    }
    foreach ($p in $peers) {
        if ($p.state -ne 'Accepted' -or -not $p.e) { continue }
        [void]$joined.Add([pscustomobject]@{ s = $p.s; e = $p.e; open = $false; source = 'history'; peer = $p })
    }
    return @($joined | Sort-Object s | ForEach-Object {
        [pscustomobject]@{
            start = $_.s.ToString('HH:mm'); end = $(if ($_.e) { $_.e.ToString('HH:mm') } else { $null }); open = $_.open
            minutes = $(if ($_.e) { [int][math]::Max(1, [math]::Round(($_.e - $_.s).TotalMinutes)) } else { $null })
            with = $(if ($_.peer -and @($_.peer.with).Count) { @($_.peer.with) } else { $null })
            direction = $(if ($_.peer) { $_.peer.direction } else { $null })
            callType = $(if ($_.peer) { $_.peer.callType } else { $null })
            source = $_.source
            _s = $_.s
        }
    })
}

function Round5([int]$m) { [int][math]::Max(5, [math]::Round($m / 5) * 5) }
function Median($xs) { $a = @($xs | Sort-Object); if (-not $a.Count) { return $null }; $i = [int][math]::Floor(($a.Count - 1) / 2); if ($a.Count % 2) { $a[$i] } else { Round5 (($a[$i] + $a[$i + 1]) / 2) } }

$store = Get-Store
$teamsFound = Save-TeamsEvents $store
$historyFound = Save-CallHistory $store
Write-JsonFile $callsPath $store
if ($Capture) { Out-Json ([pscustomobject]@{ captured = $teamsFound; events = @($store.events.PSObject.Properties).Count; peers = @($store.peers.PSObject.Properties).Count }); return }

if (-not $From) { $From = (Get-Date).ToString('yyyy-MM-dd') }
if (-not $To) { $To = $From }
$plan = (& "$PSScriptRoot\day-plan.ps1" -From $From -To $To | ConvertFrom-Json)
$warnings = New-Object System.Collections.ArrayList
if (-not $teamsFound) { [void]$warnings.Add('New Teams log folder not found: meeting lengths cannot be measured on this PC.') }
if (-not $historyFound) { [void]$warnings.Add('Teams call history cache not found: calls will not show who they were with.') }

$days = foreach ($p in @($plan.days)) {
    $date = $p.date
    $calls = @(Get-Calls $store $date)
    $cov = @($store.coverage.PSObject.Properties | Where-Object { $_.Name.StartsWith("$date|") } | ForEach-Object { $_.Value })
    $free = New-Object System.Collections.ArrayList; foreach ($c in $calls) { [void]$free.Add($c) }
    $meetings = foreach ($m in @($p.meetings)) {
        $ms = [datetime]::ParseExact("$date $($m.start)", 'yyyy-MM-dd HH:mm', $null)
        $best = $free | Where-Object { [math]::Abs(($_._s - $ms).TotalMinutes) -le $matchWindowMinutes } |
            Sort-Object { [math]::Abs(($_._s - $ms).TotalMinutes) } | Select-Object -First 1
        $measured = $null
        if ($best) {
            [void]$free.Remove($best)
            if ($best.minutes -and -not $best.open) {
                $measured = Round5 $best.minutes
                Set-Prop $store.history "$date|$($m.name)" $measured
            }
        }
        $samples = @($store.history.PSObject.Properties | Where-Object { $_.Name.EndsWith("|$($m.name)") -and $_.Name.Substring(0, 10) -lt $date } |
            Sort-Object Name -Descending | Select-Object -First 10 | ForEach-Object { [int]$_.Value })
        [pscustomobject]@{
            name = $m.name; start = $m.start; scheduledMinutes = $m.minutes
            logCovered = [bool]($cov | Where-Object { $_.from -le $m.start -and $_.to -ge $m.start })
            call = $(if ($best) { [pscustomobject]@{ start = $best.start; end = $best.end; minutes = $best.minutes; open = $best.open; with = $best.with } } else { $null })
            measuredMinutes = $measured
            usualMinutes = (Median $samples); usualSamples = $samples.Count
        }
    }
    [pscustomobject]@{
        date = $date
        covered = @($cov | Sort-Object from | Select-Object from, to)
        calls = @($calls | Select-Object start, end, minutes, open, with, direction, callType, source)
        meetings = @($meetings)
        unscheduled = @($free | Select-Object start, end, minutes, open, with, direction, callType, source)
    }
}
Write-JsonFile $callsPath $store
Out-Json ([pscustomobject]@{ teamsFound = $teamsFound; days = @($days); warnings = @($warnings) })
