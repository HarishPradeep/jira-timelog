<#
.SYNOPSIS
  Local health check for the jira-timelog skill. Checks everything that does not need the Atlassian
  MCP tools (those are checked by the skill itself, see SKILL.md "doctor").
.OUTPUTS
  JSON: { summary: { ok, warn, fail }, checks: [ { area, check, status: ok|warn|fail, detail, fix } ] }
#>
param([switch]$Quick)   # -Quick skips the network calls to Azure DevOps / GitHub
$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$checks = New-Object System.Collections.ArrayList
function Add-Check($area, $check, $status, $detail, $fix) {
    [void]$checks.Add([pscustomobject]@{ area = $area; check = $check; status = $status; detail = $detail; fix = $fix })
}
function Try-Json($text) { try { return (($text | Out-String) | ConvertFrom-Json) } catch { return $null } }
function Run([string]$Exe, [string[]]$CliArgs) { $o = & $Exe @CliArgs 2>$null; return [pscustomobject]@{ code = $LASTEXITCODE; out = $o } }

$skillDir = Split-Path -Parent $PSScriptRoot
$userDir = Join-Path $HOME '.claude\jira-timelog'

# ---------- System ----------
$psv = $PSVersionTable.PSVersion
Add-Check 'System' 'PowerShell 5.1+' $(if ($psv.Major -ge 5) { 'ok' } else { 'fail' }) "PowerShell $psv" 'Install Windows PowerShell 5.1 or PowerShell 7.'
# The skill starts every script with -ExecutionPolicy Bypass, which works unless a company Group Policy
# (MachinePolicy / UserPolicy scope) forces Restricted or AllSigned - that cannot be bypassed.
$gpo = @('MachinePolicy', 'UserPolicy' | ForEach-Object { [string](Get-ExecutionPolicy -Scope $_) } | Where-Object { $_ -and $_ -ne 'Undefined' }) | Select-Object -First 1
$blocked = $gpo -in 'Restricted', 'AllSigned'
Add-Check 'System' 'Scripts allowed to run' $(if ($blocked) { 'fail' } else { 'ok' }) $(if ($gpo) { "Group Policy forces: $gpo" } else { 'No Group Policy restriction (scripts run with -ExecutionPolicy Bypass)' }) 'Ask IT to allow RemoteSigned for your user; the skill cannot run its scripts otherwise.'
$tz = [TimeZoneInfo]::Local
$team = $null; try { $team = Get-Content -Raw (Join-Path $skillDir 'team-defaults.json') | ConvertFrom-Json } catch { }
$teamTz = if ($team.timezone) { $team.timezone } else { '+05:30' }
$sign = if ($tz.BaseUtcOffset.Ticks -lt 0) { '-' } else { '+' }
$localTz = '{0}{1:00}:{2:00}' -f $sign, [math]::Abs($tz.BaseUtcOffset.Hours), [math]::Abs($tz.BaseUtcOffset.Minutes)
Add-Check 'System' 'Time zone matches team' $(if ($localTz -eq $teamTz) { 'ok' } else { 'warn' }) "PC: $localTz ($($tz.Id)), team: $teamTz" 'Times are converted to the team zone; check the start times in the draft table carefully.'

# ---------- Skill files ----------
$need = 'SKILL.md', 'team-defaults.json', 'scripts\common.ps1', 'scripts\day-plan.ps1', 'scripts\collect-git.ps1', 'scripts\collect-prs.ps1', 'scripts\collect-calls.ps1', 'scripts\schedule.ps1', 'scripts\state.ps1', 'scripts\check-missing.ps1', 'scripts\own-activity.ps1','scripts\reminder.ps1', 'scripts\install-reminder.ps1', 'scripts\protocol-handler.ps1', 'scripts\startup-check.ps1'
$missing = @($need | Where-Object { -not (Test-Path (Join-Path $skillDir $_)) })
Add-Check 'Skill' 'Skill files present' $(if ($missing.Count) { 'fail' } else { 'ok' }) $(if ($missing.Count) { 'Missing: ' + ($missing -join ', ') } else { "$($need.Count) files in $skillDir" }) 'Reinstall / update the iverdi plugin (or copy the skill folder again).'
Add-Check 'Skill' 'Team defaults readable' $(if ($team) { 'ok' } else { 'fail' }) $(if ($team) { "Jira site $($team.jira.site), min $($team.minHours)h" } else { 'team-defaults.json missing or invalid JSON' }) 'Copy team-defaults.example.json to team-defaults.json and fill in your Jira site, cloudId and Leave Plan space.'
$year = (Get-Date).Year
$hol = $null; try { $hol = Get-Content -Raw (Join-Path $skillDir "holidays\$year.json") | ConvertFrom-Json } catch { }
if (-not $hol) { Add-Check 'Skill' "Holiday list $year" 'fail' "holidays\$year.json missing - public holidays would be treated as workdays" "Add holidays\$year.json (copy the previous year's format)." }
elseif (-not $hol.verified) { Add-Check 'Skill' "Holiday list $year" 'warn' "$(@($hol.holidays).Count) holidays, not verified against the Leave Plan image yet" 'Compare with the Leave Plan page and set "verified": true.' }
else { Add-Check 'Skill' "Holiday list $year" 'ok' "$(@($hol.holidays).Count) holidays, verified" $null }

# ---------- Git ----------
$git = Get-Command git -ErrorAction SilentlyContinue
Add-Check 'Git' 'git installed' $(if ($git) { 'ok' } else { 'fail' }) $(if ($git) { (git --version) } else { 'git not found on PATH' }) 'Install Git for Windows.'
$gEmail = if ($git) { (git config --global user.email) } else { $null }
Add-Check 'Git' 'git user.email set' $(if ($gEmail) { 'ok' } else { 'fail' }) $(if ($gEmail) { $gEmail } else { 'not set' }) 'Run: git config --global user.email "<your work email>"'

# ---------- Config ----------
$cfgPath = Join-Path $userDir 'config.json'
$cfg = $null; if (Test-Path $cfgPath) { try { $cfg = Get-Content -Raw $cfgPath | ConvertFrom-Json } catch { } }
if (-not $cfg) {
    Add-Check 'Config' 'Personal config' 'fail' "Missing or invalid: $cfgPath" 'Run: /jira-timelog setup'
} else {
    $miss = @('accountId', 'gitEmails', 'repos', 'meetingsTicket', 'maxHours' | Where-Object { -not $cfg.$_ })
    Add-Check 'Config' 'Personal config' $(if ($miss.Count) { 'fail' } else { 'ok' }) $(if ($miss.Count) { 'Missing fields: ' + ($miss -join ', ') } else { "$($cfg.displayName) - meetings ticket $($cfg.meetingsTicket), max $($cfg.maxHours)h" }) 'Run: /jira-timelog setup'
    $minH = if ($team.minHours) { [double]$team.minHours } else { 8 }
    if ($cfg.maxHours) { Add-Check 'Config' 'Max hours >= minimum' $(if ([double]$cfg.maxHours -ge $minH) { 'ok' } else { 'fail' }) "max $($cfg.maxHours)h, min $($minH)h" 'Set maxHours to at least the team minimum in config.json.' }
    if ($gEmail -and $cfg.gitEmails -and (@($cfg.gitEmails) -notcontains $gEmail)) { Add-Check 'Config' 'git email in config' 'warn' "git uses $gEmail but config has $(@($cfg.gitEmails) -join ', ')" 'Add the email to gitEmails in config.json, or run setup again.' }

    # Repos
    $since = '30 days ago'; $total = 0; $bad = @(); $idle = @()
    foreach ($r in @($cfg.repos)) {
        if (-not (Test-Path (Join-Path $r '.git'))) { $bad += $r; continue }
        $n = 0; foreach ($e in @($cfg.gitEmails)) { $n += @(git -C $r log --all --author="$e" --since="$since" --format=%h 2>$null).Count }
        if ($n -eq 0) { $idle += (Split-Path -Leaf $r) }; $total += $n
    }
    Add-Check 'Git' 'Configured repos exist' $(if ($bad.Count) { 'fail' } else { 'ok' }) $(if ($bad.Count) { 'Not found / not git: ' + ($bad -join ', ') } else { "$(@($cfg.repos).Count) repos" }) 'Fix the paths in config.json or run setup again.'
    Add-Check 'Git' 'Your commits found (30 days)' $(if ($total -gt 0) { 'ok' } else { 'warn' }) $(if ($total -gt 0) { "$total commits" + $(if ($idle.Count) { "; no recent commits in: $($idle -join ', ')" } else { '' }) } else { 'No commits by your emails - evidence will be thin' }) 'Check gitEmails / repos in config.json (setup can re-detect them).'

    # PR sources
    if (-not $cfg.prSources) { Add-Check 'Pull requests' 'PR sources configured' 'warn' 'No prSources - PR reviews will not be detected' 'Run setup again, or: collect-prs.ps1 -Detect and copy the result into config.json.' }
    foreach ($s in @($cfg.prSources)) {
        if ($s.type -eq 'ado') {
            $az = Get-Command az -ErrorAction SilentlyContinue
            if (-not $az) { Add-Check 'Pull requests' 'Azure CLI (az)' 'fail' 'az not installed' 'Install: winget install Microsoft.AzureCLI'; continue }
            $ext = Run 'az' @('extension', 'list', '--query', "[?name=='azure-devops'].version", '-o', 'tsv')
            Add-Check 'Pull requests' 'az devops extension' $(if ($ext.out) { 'ok' } else { 'fail' }) $(if ($ext.out) { "azure-devops $($ext.out)" } else { 'missing' }) 'Run: az extension add --name azure-devops'
            $acct = Try-Json (Run 'az' @('account', 'show', '-o', 'json')).out
            Add-Check 'Pull requests' 'az logged in' $(if ($acct) { 'ok' } else { 'fail' }) $(if ($acct) { $acct.user.name } else { 'not logged in' }) 'Run: az login'
            if ($acct -and $acct.user.name -ne $s.user) { Add-Check 'Pull requests' 'az account matches config' 'warn' "az: $($acct.user.name), config: $($s.user)" 'Log in with the account in config, or update prSources.user.' }
            if ($acct -and -not $Quick) {
                $t = Run 'az' @('repos', 'pr', 'list', '--organization', $s.org, '--project', $s.project, '--top', '1', '-o', 'json')
                Add-Check 'Pull requests' "Azure DevOps access ($($s.project))" $(if ($t.code -eq 0) { 'ok' } else { 'fail' }) $(if ($t.code -eq 0) { $s.org } else { "Cannot list PRs in $($s.org)" }) 'Check you have access to the project; then: az login'
            }
        }
        if ($s.type -eq 'github') {
            $gh = Get-Command gh -ErrorAction SilentlyContinue
            if (-not $gh) { Add-Check 'Pull requests' 'GitHub CLI (gh)' 'fail' 'gh not installed' 'Install: winget install GitHub.cli'; continue }
            $u = Try-Json (Run 'gh' @('api', 'user')).out
            Add-Check 'Pull requests' 'gh logged in' $(if ($u) { 'ok' } else { 'fail' }) $(if ($u) { $u.login } else { 'not logged in' }) 'Run: gh auth login'
            if ($u -and $u.login -ne $s.login) { Add-Check 'Pull requests' 'gh account matches config' 'warn' "gh: $($u.login), config: $($s.login)" 'Switch account (gh auth switch) or update prSources.login.' }
            if ($u -and -not $Quick) {
                $t = Run 'gh' @('api', '-X', 'GET', 'search/issues', '-f', "q=org:$($s.owner) is:pr involves:$($u.login)", '-f', 'per_page=1')
                Add-Check 'Pull requests' "GitHub access ($($s.owner))" $(if ($t.code -eq 0) { 'ok' } else { 'fail' }) $(if ($t.code -eq 0) { "org $($s.owner)" } else { "Cannot search PRs in $($s.owner)" }) 'Run: gh auth refresh -s read:org  (and check SSO authorization for the org)'
            }
        }
    }
}

# ---------- State / leave ----------
$state = $null; $sp = Join-Path $userDir 'state.json'
if (Test-Path $sp) { try { $state = Get-Content -Raw $sp | ConvertFrom-Json } catch { Add-Check 'State' 'state.json readable' 'fail' 'state.json is not valid JSON' "Rename $sp and run /jira-timelog status to rebuild it." } }
$lv = if ($state) { $state.leave."$year" } else { $null }
if (-not $lv) { Add-Check 'Leave' "Leave Plan $year cached" 'warn' 'Not cached yet' 'Run: /jira-timelog leave refresh' }
else {
    $age = ((Get-Date) - [datetime]$lv.fetchedAt).TotalDays
    $refresh = if ($team.leavePlan.refreshDays) { $team.leavePlan.refreshDays } else { 7 }
    Add-Check 'Leave' "Leave Plan $year cached" $(if ($age -le $refresh) { 'ok' } else { 'warn' }) ("{0} leave day(s), fetched {1:N0} day(s) ago" -f @($lv.days.PSObject.Properties).Count, $age) 'Run: /jira-timelog leave refresh'
}

# ---------- Reminder ----------
$task = Get-ScheduledTask -TaskName 'JiraTimelogReminder' -ErrorAction SilentlyContinue
if ($task) {
    $info = Get-ScheduledTaskInfo -TaskName 'JiraTimelogReminder'
    $last = if ($info.LastRunTime -and $info.LastRunTime.Year -gt 2000) { " | last run $($info.LastRunTime.ToString('yyyy-MM-dd HH:mm')) result 0x{0:X}" -f $info.LastTaskResult } else { '' }
    Add-Check 'Reminder' '6 PM reminder task' $(if ($task.State -ne 'Disabled') { 'ok' } else { 'warn' }) ("$($task.State), next run $($info.NextRunTime.ToString('ddd yyyy-MM-dd HH:mm'))" + $last) 'Run: /jira-timelog reminder on'
} else { Add-Check 'Reminder' '6 PM reminder task' 'warn' 'Not installed (optional)' 'Run: /jira-timelog reminder on' }
$proto = Test-Path 'HKCU:\Software\Classes\jiratimelog\shell\open\command'
Add-Check 'Reminder' 'Notification buttons (jiratimelog: link)' $(if ($proto) { 'ok' } elseif ($task) { 'fail' } else { 'warn' }) $(if ($proto) { 'registered' } else { 'not registered' }) 'Run: /jira-timelog reminder on'
$claude = Get-Command claude -ErrorAction SilentlyContinue
Add-Check 'Reminder' "'Log now' can start Claude" $(if ($claude) { 'ok' } else { 'warn' }) $(if ($claude) { $claude.Source } else { 'claude not on PATH' }) 'Add the Claude Code install folder to PATH.'
$hook = $false
try { $st = Get-Content -Raw (Join-Path $HOME '.claude\settings.json') | ConvertFrom-Json; $hook = [bool](($st.hooks.SessionStart | ForEach-Object { $_.hooks } | Where-Object { "$($_.command) $($_.args -join ' ')" -like '*startup-check.ps1*' })) } catch { }
Add-Check 'Reminder' 'Claude Code start-up check (hook)' $(if ($hook) { 'ok' } else { 'warn' }) $(if ($hook) { 'SessionStart hook present' } else { 'Not configured (optional)' }) 'Run: /jira-timelog reminder on  (it adds the hook)'

# ---------- Meeting lengths (Teams calls) ----------
$teamsLogs = Join-Path $env:LOCALAPPDATA 'Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\Logs'
$hasTeams = Test-Path $teamsLogs
Add-Check 'Meetings' 'Teams call log' $(if ($hasTeams) { 'ok' } else { 'warn' }) $(if ($hasTeams) { 'New Teams logs found: meeting lengths are measured' } else { 'New Teams not found: meetings use the schedule only' }) 'Install / sign in to the new Microsoft Teams app; calls on a phone or in a browser are not measured.'
if ($hasTeams) {
    $calls = $null; try { $calls = Get-Content -Raw (Join-Path $userDir 'calls.json') | ConvertFrom-Json } catch { }
    $lastEvent = if ($calls) { @($calls.events.PSObject.Properties | ForEach-Object { $_.Name }) | Sort-Object | Select-Object -Last 1 } else { $null }
    Add-Check 'Meetings' 'Calls saved' $(if ($lastEvent) { 'ok' } else { 'warn' }) $(if ($lastEvent) { "$(@($calls.events.PSObject.Properties).Count) call events, last $lastEvent" } else { 'No call saved yet' }) 'Run collect-calls.ps1 -Capture after a Teams call, or turn the reminder on.'
    $ct = Get-ScheduledTask -TaskName 'JiraTimelogCallCapture' -ErrorAction SilentlyContinue
    if ($ct) {
        $ci = Get-ScheduledTaskInfo -TaskName 'JiraTimelogCallCapture'
        Add-Check 'Meetings' 'Call capture task (every 2h)' $(if ($ct.State -ne 'Disabled') { 'ok' } else { 'warn' }) "$($ct.State), next run $($ci.NextRunTime.ToString('ddd yyyy-MM-dd HH:mm'))" 'Run: /jira-timelog reminder on'
    } else { Add-Check 'Meetings' 'Call capture task (every 2h)' 'warn' 'Not installed: Teams keeps about a day of logs, so calls are lost unless a run happens daily' 'Run: /jira-timelog reminder on' }
}

$sum = [pscustomobject]@{
    ok = @($checks | Where-Object status -eq 'ok').Count
    warn = @($checks | Where-Object status -eq 'warn').Count
    fail = @($checks | Where-Object status -eq 'fail').Count
}
ConvertTo-Json -InputObject ([pscustomobject]@{ summary = $sum; checks = @($checks) }) -Depth 6 -Compress
