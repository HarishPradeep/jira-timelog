<#
.SYNOPSIS
  Collects pull-request activity per day from Azure DevOps (az CLI) and GitHub (gh CLI):
    authored - your own PRs created / completed that day (evidence for the work ticket)
    reviews  - other people's PRs where YOU commented, voted or submitted a review that day
               (these become "PR review" rows on the meetings ticket)
  Sources come from config.json "prSources" (filled by setup / -Detect).
.EXAMPLE
  collect-prs.ps1 -From 2026-09-28 -To 2026-10-02
  collect-prs.ps1 -Detect          # print the prSources detected from repo remotes + CLI logins
.OUTPUTS
  JSON: { days: [ { date, authored: [...], reviews: [ { host, repo, id, title, author, keys, url,
          actions: [ { time, type } ], comments, firstTime, lastTime } ] } ], warnings: [...] }
#>
param(
    [string]$From,
    [string]$To,
    [switch]$Detect,
    [string]$After          # HH:mm - on the -From day, ignore PR activity before this time (already logged)
)
. "$PSScriptRoot\common.ps1"

$team = Get-TeamDefaults
$config = Get-UserConfig
$offset = Get-TzOffset $team
$warnings = New-Object System.Collections.Generic.List[string]

function Invoke-Cli([string]$Exe, [string[]]$CliArgs) {
    # Native stderr must not become a terminating error under EAP=Stop (PS 5.1).
    $ErrorActionPreference = 'Continue'
    $out = & $Exe @CliArgs 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $out) { return $null }
    try { return (($out | Out-String) | ConvertFrom-Json) } catch { return $null }
}
function Local([string]$iso) { if (-not $iso) { return $null }; ConvertTo-LocalTime $iso $offset }

if ($Detect) {
    $sources = @()
    $repos = @($config.repos)
    $remotes = foreach ($r in $repos) { $ErrorActionPreference = 'Continue'; git -C $r remote get-url origin 2>$null }
    $ado = $remotes | Where-Object { $_ -match '^https://(?:[^@/]+@)?([^./]+)\.visualstudio\.com/([^/]+)/_git/' -or $_ -match '^https://(?:[^@/]+@)?dev\.azure\.com/([^/]+)/([^/]+)/_git/' } |
        ForEach-Object {
            if ($_ -match '\.visualstudio\.com') { $null = $_ -match '^https://(?:[^@/]+@)?([^./]+)\.visualstudio\.com/([^/]+)/_git/'; "https://$($matches[1]).visualstudio.com|$([uri]::UnescapeDataString($matches[2]))" }
            else { $null = $_ -match 'dev\.azure\.com/([^/]+)/([^/]+)/_git/'; "https://dev.azure.com/$($matches[1])|$([uri]::UnescapeDataString($matches[2]))" }
        } | Select-Object -Unique
    if ($ado) {
        $acct = Invoke-Cli 'az' @('account', 'show', '-o', 'json')
        foreach ($a in $ado) { $p = $a.Split('|'); $sources += [pscustomobject]@{ type = 'ado'; org = $p[0]; project = $p[1]; user = $acct.user.name } }
        if (-not $acct) { $warnings.Add('Azure DevOps repos found but az is not logged in (run: az login).') }
    }
    $gh = $remotes | Where-Object { $_ -match 'github\.com[/:]([^/]+)/' } | ForEach-Object { $null = $_ -match 'github\.com[/:]([^/]+)/'; $matches[1] } | Select-Object -Unique
    if ($gh) {
        $u = Invoke-Cli 'gh' @('api', 'user')
        foreach ($o in $gh) { $sources += [pscustomobject]@{ type = 'github'; owner = $o; login = $u.login } }
        if (-not $u) { $warnings.Add('GitHub repos found but gh is not logged in (run: gh auth login).') }
    }
    Out-Json ([pscustomobject]@{ prSources = @($sources); warnings = @($warnings) })
    return
}

if (-not $From) { throw '-From is required (or use -Detect).' }
if (-not $To) { $To = $From }
$fromD = [datetime]::ParseExact($From, 'yyyy-MM-dd', $null)
$toD = [datetime]::ParseExact($To, 'yyyy-MM-dd', $null)
function InRange($t) { $t -and $t.Date -ge $fromD -and $t.Date -le $toD }

$authored = New-Object System.Collections.Generic.List[object]
$reviews = New-Object System.Collections.Generic.List[object]

foreach ($src in @($config.prSources)) {
    if (-not $src) { continue }

    if ($src.type -eq 'ado') {
        $base = @('--organization', $src.org, '--project', $src.project, '--status', 'all', '--top', '100', '-o', 'json')
        $mine = Invoke-Cli 'az' (@('repos', 'pr', 'list', '--creator', $src.user) + $base)
        $asRev = Invoke-Cli 'az' (@('repos', 'pr', 'list', '--reviewer', $src.user) + $base)
        if ($null -eq $mine -and $null -eq $asRev) { $warnings.Add("Azure DevOps: no data from $($src.org) (az login? network?)"); continue }
        foreach ($pr in @($mine)) {
            if (-not $pr) { continue }
            $url = "$($src.org)/$([uri]::EscapeDataString($src.project))/_git/$($pr.repository.name)/pullrequest/$($pr.pullRequestId)"
            $keys = @(Get-IssueKeys "$($pr.title) $($pr.sourceRefName)")
            $c = Local $pr.creationDate; $x = Local $pr.closedDate
            if (InRange $c) { $authored.Add([pscustomobject]@{ date = $c.ToString('yyyy-MM-dd'); host = 'ado'; repo = $pr.repository.name; id = $pr.pullRequestId; title = $pr.title; keys = $keys; event = 'created'; time = $c.ToString('HH:mm'); url = $url }) }
            if ((InRange $x) -and $pr.status -eq 'completed') { $authored.Add([pscustomobject]@{ date = $x.ToString('yyyy-MM-dd'); host = 'ado'; repo = $pr.repository.name; id = $pr.pullRequestId; title = $pr.title; keys = $keys; event = 'completed'; time = $x.ToString('HH:mm'); url = $url }) }
        }
        foreach ($pr in @($asRev)) {
            if (-not $pr) { continue }
            if ($pr.createdBy.uniqueName -eq $src.user) { continue }
            $c = Local $pr.creationDate; $x = Local $pr.closedDate
            if ($c.Date -gt $toD -or ($x -and $x.Date -lt $fromD)) { continue }   # not open during the range
            $threads = Invoke-Cli 'az' @('devops', 'invoke', '--organization', $src.org, '--area', 'git', '--resource', 'pullRequestThreads',
                '--route-parameters', "project=$($src.project)", "repositoryId=$($pr.repository.id)", "pullRequestId=$($pr.pullRequestId)",
                '--api-version', '7.1', '-o', 'json')
            $acts = @(foreach ($th in @($threads.value)) {
                $isVote = ($th.properties.CodeReviewThreadType.'$value' -eq 'VoteUpdate')
                foreach ($cm in @($th.comments)) {
                    if (-not $cm -or $cm.author.uniqueName -ne $src.user -or $cm.isDeleted) { continue }
                    $t = Local $cm.publishedDate
                    if (InRange $t) { [pscustomobject]@{ date = $t.ToString('yyyy-MM-dd'); time = $t.ToString('HH:mm'); type = $(if ($isVote) { 'vote' } elseif ($cm.commentType -eq 'system') { 'system' } else { 'comment' }) } }
                }
            })
            foreach ($g in ($acts | Group-Object date)) {
                $a = @($g.Group | Sort-Object time)
                $reviews.Add([pscustomobject]@{
                    date = $g.Name; host = 'ado'; repo = $pr.repository.name; id = $pr.pullRequestId; title = $pr.title; author = $pr.createdBy.displayName
                    keys = @(Get-IssueKeys "$($pr.title) $($pr.sourceRefName)"); url = "$($src.org)/$([uri]::EscapeDataString($src.project))/_git/$($pr.repository.name)/pullrequest/$($pr.pullRequestId)"
                    actions = @($a | Select-Object time, type); comments = @($a | Where-Object { $_.type -eq 'comment' }).Count
                    firstTime = $a[0].time; lastTime = $a[-1].time
                })
            }
        }
    }

    if ($src.type -eq 'github') {
        $q = "org:$($src.owner) is:pr involves:$($src.login) updated:>=$From"
        $found = Invoke-Cli 'gh' @('api', '-X', 'GET', 'search/issues', '-f', "q=$q", '-f', 'per_page=50')
        if ($null -eq $found) { $warnings.Add("GitHub: no data for $($src.owner) (gh auth login?)"); continue }
        foreach ($it in @($found.items)) {
            if (-not $it) { continue }
            $repo = ($it.repository_url -split '/')[-1]
            $n = $it.number
            $pr = Invoke-Cli 'gh' @('api', "repos/$($src.owner)/$repo/pulls/$n")
            if (-not $pr) { continue }
            $keys = @(Get-IssueKeys "$($pr.title) $($pr.head.ref)")
            if ($pr.user.login -eq $src.login) {
                $c = Local $pr.created_at; $m = Local $pr.merged_at
                if (InRange $c) { $authored.Add([pscustomobject]@{ date = $c.ToString('yyyy-MM-dd'); host = 'github'; repo = $repo; id = $n; title = $pr.title; keys = $keys; event = 'created'; time = $c.ToString('HH:mm'); url = $pr.html_url }) }
                if (InRange $m) { $authored.Add([pscustomobject]@{ date = $m.ToString('yyyy-MM-dd'); host = 'github'; repo = $repo; id = $n; title = $pr.title; keys = $keys; event = 'merged'; time = $m.ToString('HH:mm'); url = $pr.html_url }) }
                continue
            }
            $acts = @()
            foreach ($rv in @(Invoke-Cli 'gh' @('api', "repos/$($src.owner)/$repo/pulls/$n/reviews", '-f', 'per_page=100', '-X', 'GET'))) {
                if ($rv -and $rv.user.login -eq $src.login) { $t = Local $rv.submitted_at; if (InRange $t) { $acts += [pscustomobject]@{ date = $t.ToString('yyyy-MM-dd'); time = $t.ToString('HH:mm'); type = ('review-' + $rv.state.ToLowerInvariant()) } } }
            }
            foreach ($path in "pulls/$n/comments", "issues/$n/comments") {
                foreach ($cm in @(Invoke-Cli 'gh' @('api', "repos/$($src.owner)/$repo/$path", '-f', 'per_page=100', '-X', 'GET'))) {
                    if ($cm -and $cm.user.login -eq $src.login) { $t = Local $cm.created_at; if (InRange $t) { $acts += [pscustomobject]@{ date = $t.ToString('yyyy-MM-dd'); time = $t.ToString('HH:mm'); type = 'comment' } } }
                }
            }
            foreach ($g in ($acts | Group-Object date)) {
                $a = @($g.Group | Sort-Object time)
                $reviews.Add([pscustomobject]@{
                    date = $g.Name; host = 'github'; repo = $repo; id = $n; title = $pr.title; author = $pr.user.login; keys = $keys; url = $pr.html_url
                    actions = @($a | Select-Object time, type); comments = @($a | Where-Object { $_.type -eq 'comment' }).Count
                    firstTime = $a[0].time; lastTime = $a[-1].time
                })
            }
        }
    }
}

$days = for ($d = $fromD; $d -le $toD; $d = $d.AddDays(1)) {
    $ds = $d.ToString('yyyy-MM-dd')
    $cut = if ($After -and $ds -eq $From) { $After } else { '00:00' }
    $dayReviews = foreach ($rv in @($reviews | Where-Object { $_.date -eq $ds })) {
        $a = @($rv.actions | Where-Object { $_.time -ge $cut })
        if (-not $a.Count) { continue }
        $rv.actions = $a; $rv.firstTime = $a[0].time; $rv.lastTime = $a[-1].time
        $rv.comments = @($a | Where-Object { $_.type -eq 'comment' }).Count
        $rv
    }
    [pscustomobject]@{
        date = $ds
        after = $(if ($cut -ne '00:00') { $cut } else { $null })
        authored = @($authored | Where-Object { $_.date -eq $ds -and $_.time -ge $cut } | Sort-Object time | Select-Object host, repo, id, title, keys, event, time, url)
        reviews = @($dayReviews | Sort-Object firstTime | Select-Object host, repo, id, title, author, keys, url, actions, comments, firstTime, lastTime)
    }
}
if (-not $config.prSources) { $warnings.Add('No prSources in config - run collect-prs.ps1 -Detect and save the result into config.json.') }
Out-Json ([pscustomobject]@{ from = $From; to = $To; days = @($days); warnings = @($warnings) })
