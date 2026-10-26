<#
.SYNOPSIS
  Handles jiratimelog: links from the reminder notification.
    jiratimelog:log      open Claude Code with /jira-timelog (today)
    jiratimelog:missing  open Claude Code with /jira-timelog missing
    jiratimelog:snooze   show the reminder again in 30 minutes
#>
param([string]$Uri)
. "$PSScriptRoot\common.ps1"

$action = ($Uri -replace '^jiratimelog:(//)?', '').Trim('/').ToLowerInvariant()
switch ($action) {
    'snooze' {
        $time = (Get-Date).AddMinutes(30)
        $act = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSScriptRoot\reminder.ps1`""
        $trg = New-ScheduledTaskTrigger -Once -At $time
        Register-ScheduledTask -TaskName 'JiraTimelogSnooze' -Action $act -Trigger $trg -Force | Out-Null
    }
    default {
        $cmd = if ($action -eq 'missing') { '/jira-timelog missing' } else { '/jira-timelog' }
        $inner = "claude '$cmd'"
        $wt = Get-Command wt.exe -ErrorAction SilentlyContinue
        if ($wt) { Start-Process $wt.Source -ArgumentList @('-d', "`"$HOME`"", 'powershell.exe', '-NoExit', '-Command', $inner) }
        else { Start-Process powershell.exe -WorkingDirectory $HOME -ArgumentList @('-NoExit', '-Command', $inner) }
    }
}
