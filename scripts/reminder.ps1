<#
.SYNOPSIS
  Shows a Windows notification when recent working days look under their minimum (local check,
  see check-missing.ps1). Buttons: "Log now" opens Claude Code with /jira-timelog, "Snooze 30 min".
  Run by the "JiraTimelogReminder" scheduled task (install-reminder.ps1).
.PARAMETER Test
  Always show the notification (with sample text if nothing is missing).
#>
param([switch]$Test)
. "$PSScriptRoot\common.ps1"
try { & "$PSScriptRoot\collect-calls.ps1" -Capture | Out-Null } catch { }

$r =(& "$PSScriptRoot\check-missing.ps1" -IncludeToday | ConvertFrom-Json)
$missing = @($r.missing); $unknown = @($r.unknown)
if (-not $Test -and $missing.Count -eq 0 -and $unknown.Count -eq 0) { exit 0 }

function Day($row) { ([datetime]::ParseExact($row.date, 'yyyy-MM-dd', $null)).ToString('ddd dd MMM', [Globalization.CultureInfo]::InvariantCulture) }
$lines = @()
$todayRow = $missing | Where-Object { $_.date -eq $r.today }
$earlier = @($missing | Where-Object { $_.date -ne $r.today })
if ($todayRow) { $lines += ('Today: {0}h of {1}h logged.' -f [math]::Round($todayRow.loggedMinutes / 60, 2), ($todayRow.minMinutes / 60)) }
if ($earlier.Count) { $lines += ('Not logged: ' + (($earlier | ForEach-Object { Day $_ }) -join ', ')) }
if ($unknown.Count) { $lines += ('Check meeting time: ' + (($unknown | ForEach-Object { Day $_ }) -join ', ')) }
if (-not $lines) { $lines = @('Test notification - nothing is missing.') }
$mode = if ($earlier.Count -or $unknown.Count) { 'missing' } else { 'log' }

$esc = { param($s) [Security.SecurityElement]::Escape($s) }
$xml = @"
<toast activationType="protocol" launch="jiratimelog:$mode" scenario="reminder">
  <visual><binding template="ToastGeneric">
    <text>Jira time not logged yet</text>
    <text>$(& $esc ($lines -join "`n"))</text>
  </binding></visual>
  <actions>
    <action content="Log now" activationType="protocol" arguments="jiratimelog:$mode"/>
    <action content="Snooze 30 min" activationType="protocol" arguments="jiratimelog:snooze"/>
    <action content="Dismiss" activationType="system" arguments="dismiss"/>
  </actions>
</toast>
"@

try {
    [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
    [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime] | Out-Null
    $doc = New-Object Windows.Data.Xml.Dom.XmlDocument
    $doc.LoadXml($xml)
    $appId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
    [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Show([Windows.UI.Notifications.ToastNotification]::new($doc))
} catch {
    # Fallback: simple Yes/No popup (auto-closes after 10 minutes).
    $ans = (New-Object -ComObject WScript.Shell).Popup(($lines -join "`n") + "`n`nOpen Claude Code to log it now?", 600, 'Jira time not logged yet', 4 + 48)
    if ($ans -eq 6) { & "$PSScriptRoot\protocol-handler.ps1" "jiratimelog:$mode" }
}
