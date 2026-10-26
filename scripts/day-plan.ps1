<#
.SYNOPSIS
  Classifies each date (workday / weekend / holiday / leave / half-day / tentative) and lists
  the scheduled meetings that apply, using team defaults, the user config, the holiday file
  and the leave days cached in state.json.
.EXAMPLE
  day-plan.ps1 -From 2026-10-01 -To 2026-10-05
  day-plan.ps1 -LastWorkingDays 10          # catch-up window ending today
.OUTPUTS
  JSON: { warnings: [...], leaveCache: {...}, days: [ { date, weekday, kind, reason, loggable,
          minHours, maxHours, workStart, meetings: [ { name, start, minutes, askMinutes } ] } ] }
#>
param(
    [string]$From,
    [string]$To,
    [int]$LastWorkingDays = 0
)
. "$PSScriptRoot\common.ps1"

$team   = Get-TeamDefaults
$config = Get-UserConfig
$state  = Get-State
$warnings = New-Object System.Collections.Generic.List[string]
if (-not $config) { $warnings.Add('No user config found - run "/jira-timelog setup" first. Using team defaults.') }

$minHours  = [double](Get-Setting $null $team 'minHours')              # team rule, not overridable
$halfMin   = [double](Get-Setting $null $team 'halfDayMinHours')
$maxHours  = [double](Get-Setting $config $team 'maxHours'); if (-not $maxHours) { $maxHours = [double]$team.defaultMaxHours }
$dayStart  = [string](Get-Setting $config $team 'workdayStart')
$split     = [string](Get-Setting $config $team 'halfDaySplit')
$meetings  = @(Get-Setting $config $team 'meetings'); if (-not $meetings -or -not $meetings[0]) { $meetings = @($team.defaultMeetings) }
$refresh   = [int]$team.leavePlan.refreshDays

$today = (Get-Date).Date
$holidayCache = @{}
function Get-Holiday([datetime]$d) {
    $y = $d.Year
    if (-not $holidayCache.ContainsKey($y)) {
        $f = Read-JsonFile (Join-Path $script:SkillDir "holidays\$y.json")
        $map = @{}
        if ($f) {
            foreach ($h in $f.holidays) { $map[$h.date] = $h.name }
            if (-not $f.verified) { $warnings.Add("holidays/$y.json is not verified yet - check it against the Leave Plan holiday image.") }
        } else { $warnings.Add("No holidays/$y.json - public holidays for $y are unknown.") }
        $holidayCache[$y] = $map
    }
    return $holidayCache[$y][$d.ToString('yyyy-MM-dd')]
}

$leaveInfo = @{}
function Get-Leave([datetime]$d) {
    $y = [string]$d.Year
    if (-not $leaveInfo.ContainsKey($y)) {
        $entry = $state.leave.$y
        $info = @{ days = @{}; fetchedAt = $null; stale = $true; present = $false }
        if ($entry) {
            $info.present = $true
            $info.fetchedAt = $entry.fetchedAt
            if ($entry.fetchedAt) { $info.stale = ((Get-Date) - [datetime]$entry.fetchedAt).TotalDays -gt $refresh }
            if ($entry.days) { foreach ($p in $entry.days.PSObject.Properties) { $info.days[$p.Name] = $p.Value } }
        }
        $leaveInfo[$y] = $info
    }
    return $leaveInfo[$y].days[$d.ToString('yyyy-MM-dd')]
}

# Build the date list.
$dates = New-Object System.Collections.Generic.List[datetime]
if ($LastWorkingDays -gt 0) {
    $d = $today; $n = 0; $guard = 0
    while ($n -lt $LastWorkingDays -and $guard -lt 60) {
        if ($d.DayOfWeek -ne 'Saturday' -and $d.DayOfWeek -ne 'Sunday' -and -not (Get-Holiday $d)) { $n++ }
        $dates.Insert(0, $d); $d = $d.AddDays(-1); $guard++
    }
} else {
    if (-not $From) { $From = $today.ToString('yyyy-MM-dd') }
    if (-not $To) { $To = $From }
    $d = [datetime]::ParseExact($From, 'yyyy-MM-dd', $null)
    $end = [datetime]::ParseExact($To, 'yyyy-MM-dd', $null)
    while ($d -le $end) { $dates.Add($d); $d = $d.AddDays(1) }
}

$days = foreach ($d in $dates) {
    $wd = $d.ToString('ddd', [Globalization.CultureInfo]::InvariantCulture)
    $kind = 'workday'; $reason = $null; $min = $minHours; $start = $dayStart
    $holiday = Get-Holiday $d
    $leave = Get-Leave $d
    if ($wd -eq 'Sat' -or $wd -eq 'Sun') { $kind = 'weekend'; $reason = $wd }
    elseif ($holiday) { $kind = 'holiday'; $reason = $holiday }
    elseif ($leave -eq 'full') { $kind = 'leave'; $reason = 'Leave (Leave Plan)' }
    elseif ($leave -eq 'am') { $kind = 'half-day'; $reason = 'Half-day leave - morning off'; $min = $halfMin; $start = $split }
    elseif ($leave -eq 'pm') { $kind = 'half-day'; $reason = 'Half-day leave - afternoon off'; $min = $halfMin }
    elseif ($leave -eq 'half') { $kind = 'half-day'; $reason = 'Half-day leave (which half not stated) - ask the user'; $min = $halfMin }
    elseif ($leave -like 'tentative*') { $kind = 'tentative-leave'; $reason = "Tentative leave ($leave) - ask the user" }
    if ($d -gt $today) { $kind = 'future'; $reason = 'Date is in the future' }

    $loggable = $kind -in @('workday', 'half-day', 'tentative-leave')
    $todays = @()
    if ($loggable) {
        $todays = @(foreach ($m in $meetings) {
            if ($m.days -notcontains $wd) { continue }
            if ($leave -eq 'am' -and $m.start -lt $split) { continue }
            if ($leave -eq 'pm' -and $m.start -ge $split) { continue }
            $o = [ordered]@{ name = $m.name; start = $m.start; minutes = [int]$m.minutes }
            if ($m.askMinutes) { $o.askMinutes = @($m.askMinutes) }
            if ($m.aliases) { $o.aliases = @($m.aliases) }
            [pscustomobject]$o
        })
    }
    [pscustomobject]@{
        date = $d.ToString('yyyy-MM-dd'); weekday = $wd; kind = $kind; reason = $reason; loggable = $loggable
        minHours = $(if ($loggable) { $min } else { 0 }); maxHours = $(if ($loggable) { $maxHours } else { 0 })
        workStart = $start; meetings = $todays
    }
}

$cache = foreach ($k in $leaveInfo.Keys) { [pscustomobject]@{ year = $k; present = $leaveInfo[$k].present; fetchedAt = $leaveInfo[$k].fetchedAt; stale = $leaveInfo[$k].stale } }
foreach ($c in $cache) { if ($c.stale) { $warnings.Add("Leave cache for $($c.year) is missing or older than $refresh days - refresh it from Confluence.") } }

Out-Json ([pscustomobject]@{ warnings = @($warnings | Select-Object -Unique); leaveCache = @($cache); days = @($days) })
