<#
.SYNOPSIS
  Claude Code SessionStart hook: prints {"systemMessage": "..."} when recent working days look
  unlogged (local check only, no Jira call). Shows the same message at most once every 3 hours.
  Never fails the session: any error -> no output, exit 0.
#>
try {
    . "$PSScriptRoot\common.ps1"
    if (-not (Get-UserConfig)) { exit 0 }
    try { & "$PSScriptRoot\collect-calls.ps1" -Capture | Out-Null } catch { }
    $r = (& "$PSScriptRoot\check-missing.ps1" | ConvertFrom-Json)
    $missing = @($r.missing); $unknown = @($r.unknown)
    if ($missing.Count -eq 0 -and $unknown.Count -eq 0) { exit 0 }

    function Day($row) { ([datetime]::ParseExact($row.date, 'yyyy-MM-dd', $null)).ToString('ddd dd MMM', [Globalization.CultureInfo]::InvariantCulture) }
    $parts = @()
    if ($missing.Count) { $parts += "$($missing.Count) day(s) under the minimum: " + (($missing | ForEach-Object { Day $_ }) -join ', ') }
    if ($unknown.Count) { $parts += 'meeting time unknown: ' + (($unknown | ForEach-Object { Day $_ }) -join ', ') }
    $msg = "Jira time: " + ($parts -join '; ') + ' - run /jira-timelog missing'

    $noticeFile = Join-Path $script:UserDir 'last-notice.json'
    $last = Read-JsonFile $noticeFile
    if ($last -and $last.message -eq $msg -and ((Get-Date) - [datetime]$last.at).TotalHours -lt 3) { exit 0 }
    Write-JsonFile $noticeFile ([pscustomobject]@{ message = $msg; at = (Get-Date).ToString('s') })

    Out-Json ([pscustomobject]@{ systemMessage = $msg })
} catch { }
exit 0
