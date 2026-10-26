<#
.SYNOPSIS
  Assigns start times: meetings keep their own slot, already-logged blocks are kept free, and work rows
  fill the remaining gaps from workStart (a work row is split around meetings when it does not fit).
  With "until" (partial day), nothing is placed after that time; what does not fit is returned as unplaced.
.EXAMPLE
  schedule.ps1 -Date 2026-10-05 -Json '{"workStart":"09:00","until":"13:05",
     "logged":[{"start":"09:00","minutes":60}],
     "meetings":[{"issue":"IV-15353","name":"Internal meeting","start":"09:30","minutes":30}],
     "work":[{"issue":"IV-18148","minutes":120}]}'
.OUTPUTS
  JSON: { rows: [ { issue, name, minutes, timeSpent, started, start, end, part } ], unplaced: [ { issue, name, minutes } ],
          coveredUntil }
#>
param(
    [Parameter(Mandatory)][string]$Date,
    [string]$Json,
    [string]$JsonFile
)
. "$PSScriptRoot\common.ps1"

$team = Get-TeamDefaults
$offset = Get-TzOffset $team
$plan = if ($JsonFile) { Read-JsonFile $JsonFile } else { $Json | ConvertFrom-Json }
$day = [datetime]::ParseExact($Date, 'yyyy-MM-dd', $null)
function At([string]$hhmm) { $p = $hhmm.Split(':'); return $day.AddHours([int]$p[0]).AddMinutes([int]$p[1]) }
function Fmt([datetime]$t) {
    $sign = if ($offset.Ticks -lt 0) { '-' } else { '+' }
    return $t.ToString('yyyy-MM-ddTHH:mm:ss.fff') + $sign + ('{0:00}{1:00}' -f [math]::Abs($offset.Hours), [math]::Abs($offset.Minutes))
}
function Span([int]$m) { $h = [math]::Floor($m / 60); $r = $m % 60; if ($h -and $r) { "${h}h ${r}m" } elseif ($h) { "${h}h" } else { "${r}m" } }

$rows = New-Object System.Collections.ArrayList
$busy = New-Object System.Collections.ArrayList
$unplaced = New-Object System.Collections.ArrayList
$until = if ($plan.until) { At ([string]$plan.until) } else { $null }

# Already-logged blocks: kept free, not output.
foreach ($l in @($plan.logged)) {
    if (-not $l -or -not $l.minutes -or -not $l.start) { continue }
    $s = At $l.start
    [void]$busy.Add([pscustomobject]@{ s = $s; e = $s.AddMinutes([int]$l.minutes) })
}
foreach ($m in @($plan.meetings)) {
    if (-not $m -or -not $m.minutes -or -not $m.start) { continue }
    $s = At $m.start
    [void]$busy.Add([pscustomobject]@{ s = $s; e = $s.AddMinutes([int]$m.minutes) })
    [void]$rows.Add([pscustomobject]@{ issue = $m.issue; name = $m.name; minutes = [int]$m.minutes; s = $s; part = $null })
}
# Meetings without a start time (e.g. ad-hoc PR reviews) are treated like work.
$queue = @(@($plan.meetings | Where-Object { $_ -and $_.minutes -and -not $_.start }) + @($plan.work | Where-Object { $_ -and $_.minutes }))

$cursor = At ([string]$plan.workStart)
$sorted = @($busy | Sort-Object s)
foreach ($w in $queue) {
    $left = [int]$w.minutes; $part = 0
    while ($left -gt 0) {
        do {
            $moved = $false
            foreach ($b in $sorted) { if ($cursor -ge $b.s -and $cursor -lt $b.e) { $cursor = $b.e; $moved = $true } }
        } while ($moved)
        if ($until -and $cursor -ge $until) { break }
        $next = $sorted | Where-Object { $_.s -gt $cursor } | Select-Object -First 1
        $gap = if ($next) { [int]($next.s - $cursor).TotalMinutes } else { [int]::MaxValue }
        if ($until) { $gap = [math]::Min($gap, [int]($until - $cursor).TotalMinutes) }
        if ($gap -lt 15) {
            if ($next -and (-not $until -or $next.s -lt $until)) { $cursor = $next.e; continue }
            break
        }
        $take = [math]::Min($left, $gap)
        $part++
        [void]$rows.Add([pscustomobject]@{ issue = $w.issue; name = $w.name; minutes = $take; s = $cursor; part = $part })
        $cursor = $cursor.AddMinutes($take); $left -= $take
    }
    if ($left -gt 0) { [void]$unplaced.Add([pscustomobject]@{ issue = $w.issue; name = $w.name; minutes = $left }) }
}

$out = foreach ($r in ($rows | Sort-Object s)) {
    [pscustomobject]@{ issue = $r.issue; name = $r.name; minutes = $r.minutes; timeSpent = (Span $r.minutes)
        started = (Fmt $r.s); start = $r.s.ToString('HH:mm'); end = $r.s.AddMinutes($r.minutes).ToString('HH:mm'); part = $r.part }
}
$ends = @(@($out | ForEach-Object { $_.end }) + @($busy | ForEach-Object { $_.e.ToString('HH:mm') })) | Sort-Object
Out-Json ([pscustomobject]@{ rows = @($out); unplaced = @($unplaced); coveredUntil = ($ends | Select-Object -Last 1) })
