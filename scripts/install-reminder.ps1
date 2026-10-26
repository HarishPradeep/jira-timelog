<#
.SYNOPSIS
  Installs (or removes) the daily reminder for the current Windows user, no admin needed:
    - scheduled task "JiraTimelogReminder": Mon-Fri at the reminder time (runs late if the PC was off)
    - jiratimelog: link handler in HKCU, used by the notification buttons
.EXAMPLE
  install-reminder.ps1                 # uses reminderTime from config / team defaults (18:00)
  install-reminder.ps1 -Time 17:30
  install-reminder.ps1 -Uninstall
#>
param([string]$Time, [switch]$Uninstall)
. "$PSScriptRoot\common.ps1"

$taskName = 'JiraTimelogReminder'
$captureTaskName = 'JiraTimelogCallCapture'
$protoKey = 'HKCU:\Software\Classes\jiratimelog'

if ($Uninstall) {
    foreach ($t in $taskName, 'JiraTimelogSnooze', $captureTaskName) { Unregister-ScheduledTask -TaskName $t -Confirm:$false -ErrorAction SilentlyContinue }
    if (Test-Path $protoKey) { Remove-Item $protoKey -Recurse -Force }
    Out-Json ([pscustomobject]@{ removed = $true })
    return
}

$team = Get-TeamDefaults; $config = Get-UserConfig
if (-not $Time) { $Time = [string](Get-Setting $config $team 'reminderTime') }
if (-not $Time) { $Time = '18:00' }
$at = [datetime]::ParseExact($Time, 'HH:mm', $null)

# Link handler for the notification buttons.
$handler = Join-Path $PSScriptRoot 'protocol-handler.ps1'
New-Item -Path "$protoKey\shell\open\command" -Force | Out-Null
Set-ItemProperty -Path $protoKey -Name '(default)' -Value 'URL:Jira timelog reminder'
Set-ItemProperty -Path $protoKey -Name 'URL Protocol' -Value ''
Set-ItemProperty -Path "$protoKey\shell\open\command" -Name '(default)' -Value "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$handler`" `"%1`""

$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$(Join-Path $PSScriptRoot 'reminder.ps1')`""
$trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Monday, Tuesday, Wednesday, Thursday, Friday -At $at
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal `
    -Description 'Reminds you to log Jira time (jira-timelog skill for Claude Code).' -Force | Out-Null

# Teams keeps about a day of logs: save the call events every 2 hours on workdays (silent, no notification).
$captureAction = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$(Join-Path $PSScriptRoot 'collect-calls.ps1')`" -Capture"
$captureTrigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Monday, Tuesday, Wednesday, Thursday, Friday -At ([datetime]::ParseExact('08:00', 'HH:mm', $null))
$captureTrigger.Repetition = (New-ScheduledTaskTrigger -Once -At ([datetime]::ParseExact('08:00', 'HH:mm', $null)) -RepetitionInterval (New-TimeSpan -Hours 2) -RepetitionDuration (New-TimeSpan -Hours 16)).Repetition
Register-ScheduledTask -TaskName $captureTaskName -Action $captureAction -Trigger $captureTrigger -Settings $settings -Principal $principal `
    -Description 'Saves Teams call times for meeting lengths (jira-timelog skill for Claude Code).' -Force | Out-Null

$task = Get-ScheduledTask -TaskName $taskName
$info = Get-ScheduledTaskInfo -TaskName $taskName
$captureInfo = Get-ScheduledTaskInfo -TaskName $captureTaskName
Out-Json ([pscustomobject]@{ task = $taskName; state = [string]$task.State; time = $Time; days = 'Mon-Fri'; nextRun = $(if ($info.NextRunTime) { $info.NextRunTime.ToString('s') }); protocol = 'jiratimelog:'
    callCapture = [pscustomobject]@{ task = $captureTaskName; every = '2h, 08:00-24:00 Mon-Fri'; nextRun = $(if ($captureInfo.NextRunTime) { $captureInfo.NextRunTime.ToString('s') }) } })
