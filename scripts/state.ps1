<#
.SYNOPSIS
  Reads/updates ~/.claude/jira-timelog/state.json.
.EXAMPLE
  state.ps1 get -Date 2026-10-02
  state.ps1 record -Date 2026-10-02 -Json '[{"issue":"IV-1","worklogId":"123","minutes":60,"started":"2026-10-02T09:30:00.000+0530","comment":"x"}]'
  state.ps1 remove -Date 2026-10-02 -Ids 123,124
  state.ps1 set-leave -Year 2026 -JsonFile leave.json     # { pageId, lastModified, days: { "2026-01-27": "full", ... } }
  state.ps1 summary -From 2026-09-21 -To 2026-10-05       # minutes recorded per date
#>
param(
    [Parameter(Mandatory, Position = 0)][ValidateSet('get', 'record', 'remove', 'set-leave', 'summary', 'snapshot')][string]$Action,
    [string]$Date,
    [string]$From,
    [string]$To,
    [string]$Year,
    [string]$Json,
    [string]$JsonFile,
    [string[]]$Ids
)
. "$PSScriptRoot\common.ps1"

$state = Get-State
function Get-Payload {
    if ($JsonFile) { return Read-JsonFile $JsonFile }
    if ($Json) { return $Json | ConvertFrom-Json }
    throw 'Pass -Json or -JsonFile.'
}

switch ($Action) {
    'get' {
        if ($Date) { Out-Json ([pscustomobject]@{ date = $Date; worklogs = @($state.worklogs.$Date | Where-Object { $_ }) }) }
        else { Out-Json $state }
    }
    'record' {
        if (-not $Date) { throw '-Date is required.' }
        $new = @((Get-Payload) | ForEach-Object { $_ })   # unroll: PS 5.1 ConvertFrom-Json emits an array as one object
        $existing = @($state.worklogs.$Date | Where-Object { $_ })
        $now = (Get-Date).ToString('s')
        $all = @($existing) + @($new | ForEach-Object { $_ | Add-Member -NotePropertyName recordedAt -NotePropertyValue $now -Force -PassThru })
        $state.worklogs | Add-Member -NotePropertyName $Date -NotePropertyValue $all -Force
        $state.lastRun = $now
        Save-State $state
        Out-Json ([pscustomobject]@{ date = $Date; recorded = $new.Count; total = $all.Count })
    }
    'remove' {
        if (-not $Date) { throw '-Date is required.' }
        $ids = @($Ids | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() })
        $keep = @($state.worklogs.$Date | Where-Object { $_ -and ($ids -notcontains [string]$_.worklogId) })
        if ($keep.Count -eq 0) { $state.worklogs.PSObject.Properties.Remove($Date) }
        else { $state.worklogs | Add-Member -NotePropertyName $Date -NotePropertyValue $keep -Force }
        Save-State $state
        Out-Json ([pscustomobject]@{ date = $Date; removed = $ids; remaining = $keep.Count })
    }
    'set-leave' {
        if (-not $Year) { throw '-Year is required.' }
        $p = Get-Payload
        $entry = [pscustomobject]@{ pageId = $p.pageId; lastModified = $p.lastModified; fetchedAt = (Get-Date).ToString('s'); days = $p.days }
        $state.leave | Add-Member -NotePropertyName $Year -NotePropertyValue $entry -Force
        Save-State $state
        $n = 0; if ($p.days) { $n = @($p.days.PSObject.Properties).Count }
        Out-Json ([pscustomobject]@{ year = $Year; leaveDays = $n })
    }
    'snapshot' {
        # Payload: { "YYYY-MM-DD": { "minutes": N, "partial": bool }, ... }  - what Jira showed as logged.
        $p = Get-Payload
        if (-not ($state.PSObject.Properties.Name -contains 'days')) { $state | Add-Member -NotePropertyName days -NotePropertyValue ([pscustomobject]@{}) }
        $now = (Get-Date).ToString('s'); $n = 0
        foreach ($d in $p.PSObject.Properties) {
            $v = [pscustomobject]@{ minutes = [int]$d.Value.minutes; partial = [bool]$d.Value.partial; checkedAt = $now }
            $state.days | Add-Member -NotePropertyName $d.Name -NotePropertyValue $v -Force; $n++
        }
        Save-State $state
        Out-Json ([pscustomobject]@{ snapshotDays = $n })
    }
    'summary' {
        $rows = foreach ($p in $state.worklogs.PSObject.Properties) {
            if ($From -and $p.Name -lt $From) { continue }
            if ($To -and $p.Name -gt $To) { continue }
            $m = 0; foreach ($w in @($p.Value)) { if ($w.minutes) { $m += [int]$w.minutes } }
            [pscustomobject]@{ date = $p.Name; worklogs = @($p.Value).Count; minutes = $m }
        }
        Out-Json @($rows | Sort-Object date)
    }
}
