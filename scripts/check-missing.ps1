<#
.SYNOPSIS
  Local-only check (no Jira call) of which recent working days still look under their minimum,
  using the Jira snapshots and worklogs recorded in state.json. Used by the 6 PM reminder and the
  Claude Code SessionStart hook; /jira-timelog itself always re-checks Jira.
.PARAMETER IncludeToday
  Count today even before the reminder time.
.OUTPUTS
  JSON: { today, includeToday, missing: [ {date, weekday, status, loggedMinutes, minMinutes} ], unknown: [...], ok: N }
  status: short (below minimum) | unchecked (no snapshot, nothing recorded) | unknown (meetings-ticket amount not known)
#>
param([switch]$IncludeToday)
. "$PSScriptRoot\common.ps1"

$team = Get-TeamDefaults
$config = Get-UserConfig
$state = Get-State
$reminder = [string](Get-Setting $config $team 'reminderTime'); if (-not $reminder) { $reminder = '18:00' }
$n = [int](Get-Setting $config $team 'catchUpDays'); if (-not $n) { $n = 10 }

$now = Get-Date
$today = $now.ToString('yyyy-MM-dd')
$rp = $reminder.Split(':')
$includeToday = $IncludeToday -or ($now -ge $now.Date.AddHours([int]$rp[0]).AddMinutes([int]$rp[1]))

# Only judge days from the first Jira snapshot on, so a fresh install does not nag about old days.
$snapDates = @($state.days.PSObject.Properties.Name | Sort-Object)
$trackFrom = if ($snapDates.Count) { $snapDates[0] } else { $today }

$plan = (& "$PSScriptRoot\day-plan.ps1" -LastWorkingDays $n | ConvertFrom-Json)
$missing = @()
$unknown = @()
$ok = 0
foreach ($d in $plan.days) {
    if (-not $d.loggable) { continue }
    if ($d.date -lt $trackFrom) { continue }
    if ($d.date -eq $today -and -not $includeToday) { continue }
    $min = [int]([double]$d.minHours * 60)
    $snap = $state.days.($d.date)
    $known = 0
    if ($snap) { $known = [int]$snap.minutes }
    foreach ($w in @($state.worklogs.($d.date) | Where-Object { $_ })) {
        # Worklogs recorded after the snapshot are not in it yet.
        if (-not $snap -or ($w.recordedAt -and $w.recordedAt -gt $snap.checkedAt)) { $known += [int]$w.minutes }
    }
    $row = [pscustomobject]@{ date = $d.date; weekday = $d.weekday; loggedMinutes = $known; minMinutes = $min; status = $null }
    if ($known -ge $min) { $ok++ }
    elseif ($snap -and $snap.partial) { $row.status = 'unknown'; $unknown += $row }
    elseif (-not $snap -and $known -eq 0) { $row.status = 'unchecked'; $missing += $row }
    else { $row.status = 'short'; $missing += $row }
}
Out-Json ([pscustomobject]@{ today = $today; includeToday = [bool]$includeToday; trackFrom = $trackFrom; missing = @($missing); unknown = @($unknown); ok = $ok })
