<#
.SYNOPSIS
  Collects git evidence per day for the configured repos and author emails:
  commits (with changed files / line counts / ticket keys), branch switches from the reflog,
  and uncommitted work (only when the range includes today).
.EXAMPLE
  collect-git.ps1 -From 2026-10-01 -To 2026-10-05
  collect-git.ps1 -From 2026-10-05 -After 13:00   # continue mode: only evidence from 13:00 on that day
.OUTPUTS
  JSON: { days: [ { date, commits: [...], branchSwitches: [...], keys: [...], firstActivity, lastActivity } ],
          uncommitted: [ { repo, branch, keys, changedFiles, files } ], warnings: [...] }
#>
param(
    [Parameter(Mandatory)][string]$From,
    [string]$To,
    [string[]]$Repos,
    [string[]]$Emails,
    [string]$After          # HH:mm - on the -From day, ignore evidence before this time (already logged)
)
. "$PSScriptRoot\common.ps1"

$team = Get-TeamDefaults
$config = Get-UserConfig
$offset = Get-TzOffset $team
$warnings = New-Object System.Collections.Generic.List[string]
if (-not $To) { $To = $From }
if (-not $Repos)  { $Repos  = @($config.repos) }
if (-not $Emails) { $Emails = @($config.gitEmails) }
if (-not $Repos -or -not $Repos[0])  { throw 'No repos - pass -Repos or run setup.' }
if (-not $Emails -or -not $Emails[0]) { throw 'No git emails - pass -Emails or run setup.' }

$fromD = [datetime]::ParseExact($From, 'yyyy-MM-dd', $null)
$toD   = [datetime]::ParseExact($To, 'yyyy-MM-dd', $null)
# Widen the git query by a day each side; bucket by local (team) time afterwards.
$since = $fromD.AddDays(-1).ToString('yyyy-MM-dd')
$until = $toD.AddDays(2).ToString('yyyy-MM-dd')

$commits = New-Object System.Collections.Generic.List[object]
$switches = New-Object System.Collections.Generic.List[object]
$seen = @{}

foreach ($repo in $Repos) {
    if (-not (Test-Path (Join-Path $repo '.git'))) { $warnings.Add("Not a git repo (skipped): $repo"); continue }
    $name = Split-Path -Leaf $repo

    foreach ($em in $Emails) {
        $raw = git -C $repo log --all --author="$em" --since="$since" --until="$until" --date=iso-strict --numstat `
            --format="@@C|%H|%h|%ad|%P|%D|%s" 2>$null
        $cur = $null
        foreach ($line in $raw) {
            if ($line -like '@@C|*') {
                $p = $line.Substring(4) -split '\|', 6
                if ($seen.ContainsKey($p[0])) { $cur = $null; continue }
                $seen[$p[0]] = $true
                $t = ConvertTo-LocalTime $p[2] $offset
                $refs = $p[4]
                $cur = [pscustomobject]@{
                    repo = $name; hash = $p[1]; time = $t.ToString('yyyy-MM-ddTHH:mm:sszzz'); date = $t.ToString('yyyy-MM-dd')
                    isMerge = (($p[3] -split ' ').Count -gt 1); refs = $refs; subject = $p[5]
                    keys = @(Get-IssueKeys ("$refs $($p[5])")); added = 0; deleted = 0; files = New-Object System.Collections.Generic.List[string]
                }
                $commits.Add($cur)
            } elseif ($cur -and $line -match '^(\d+|-)\t(\d+|-)\t(.+)$') {
                if ($matches[1] -ne '-') { $cur.added += [int]$matches[1] }
                if ($matches[2] -ne '-') { $cur.deleted += [int]$matches[2] }
                $cur.files.Add($matches[3])
            }
        }
    }

    # Reflog: branch switches with timestamps (HEAD@{<date>}).
    $rl = git -C $repo log -g --date=iso-strict --format="%gd|%gs" -n 3000 2>$null
    foreach ($line in $rl) {
        if ($line -match '^HEAD@\{(.+?)\}\|checkout: moving from (.+) to (.+)$') {
            $t = ConvertTo-LocalTime $matches[1] $offset
            if ($t.Date -lt $fromD.AddDays(-1) -or $t.Date -gt $toD) { continue }
            $switches.Add([pscustomobject]@{
                repo = $name; time = $t.ToString('yyyy-MM-ddTHH:mm:sszzz'); date = $t.ToString('yyyy-MM-dd')
                from = $matches[2]; to = $matches[3]; keys = @(Get-IssueKeys $matches[3])
            })
        }
    }
}

$days = for ($d = $fromD; $d -le $toD; $d = $d.AddDays(1)) {
    $ds = $d.ToString('yyyy-MM-dd')
    $cut = if ($After -and $ds -eq $From) { "${ds}T$After" } else { $ds }   # evidence before $cut is excluded
    $dc = @($commits | Where-Object { $_.date -eq $ds -and $_.time -ge $cut } | Sort-Object time)
    $dsw = @($switches | Where-Object { $_.date -eq $ds -and $_.time -ge $cut } | Sort-Object time)
    # Branch active at the start of the window = target of the last switch before it.
    $carry = @($switches | Where-Object { $_.time -lt $cut } | Group-Object repo | ForEach-Object {
        $last = $_.Group | Sort-Object time | Select-Object -Last 1
        [pscustomobject]@{ repo = $_.Name; branch = $last.to; keys = $last.keys }
    })
    $times = @($dc.time) + @($dsw.time) | Where-Object { $_ } | Sort-Object
    $out = foreach ($c in $dc) {
        $f = @($c.files)
        [pscustomobject]@{
            repo = $c.repo; hash = $c.hash; time = $c.time; isMerge = $c.isMerge; subject = $c.subject; refs = $c.refs
            keys = @($c.keys); added = $c.added; deleted = $c.deleted; fileCount = $f.Count; files = @($f | Select-Object -First 12)
        }
    }
    [pscustomobject]@{
        date = $ds
        commits = @($out)
        branchSwitches = @($dsw)
        branchAtStartOfDay = $carry
        after = $(if ($cut -ne $ds) { $After } else { $null })
        keys = @((@($dc | ForEach-Object { $_.keys }) + @($dsw | ForEach-Object { $_.keys })) | Where-Object { $_ } | Select-Object -Unique)
        firstActivity = ($times | Select-Object -First 1)
        lastActivity = ($times | Select-Object -Last 1)
    }
}

$uncommitted = @()
if ($toD -ge (Get-Date).Date) {
    $uncommitted = @(foreach ($repo in $Repos) {
        if (-not (Test-Path (Join-Path $repo '.git'))) { continue }
        $st = @(git -C $repo status --porcelain 2>$null | Where-Object { $_ })
        if ($st.Count -eq 0) { continue }
        $br = (git -C $repo rev-parse --abbrev-ref HEAD 2>$null)
        [pscustomobject]@{ repo = (Split-Path -Leaf $repo); branch = $br; keys = @(Get-IssueKeys $br); changedFiles = $st.Count; files = @($st | Select-Object -First 10 | ForEach-Object { $_.Substring(3) }) }
    })
}

Out-Json ([pscustomobject]@{ from = $From; to = $To; days = @($days); uncommitted = $uncommitted; warnings = @($warnings) })
