<#
.SYNOPSIS
  Finds git repos (up to 2 folders deep on every fixed drive, plus the user profile)
  that have commits by the given author emails in the last N days.
.OUTPUTS
  JSON: { emails: [...], repos: [ { path, commits, lastCommit } ] }  (sorted by commits desc)
#>
param(
    [string[]]$Emails,
    [int]$Days = 30,
    [string[]]$Roots
)
. "$PSScriptRoot\common.ps1"

if (-not $Emails -or $Emails.Count -eq 0) {
    $e = (git config --global user.email 2>$null)
    if ($e) { $Emails = @($e.Trim()) } else { throw 'No git email given and git config user.email is empty.' }
}
# Allow a single comma-separated argument.
$Emails = @($Emails | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })

if (-not $Roots -or $Roots.Count -eq 0) {
    $Roots = @(Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Free -ne $null } | ForEach-Object { $_.Root }) + @($HOME, (Join-Path $HOME 'source\repos'))
}
$skip = '^(Windows|Program Files.*|ProgramData|\$.*|System Volume Information|Recovery|PerfLogs|AppData|node_modules)$'

$candidates = New-Object System.Collections.Generic.List[string]
foreach ($r in $Roots) {
    if (-not (Test-Path $r)) { continue }
    if (Test-Path (Join-Path $r '.git')) { $candidates.Add((Resolve-Path $r).Path) }
    foreach ($d1 in Get-ChildItem $r -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch $skip }) {
        if (Test-Path (Join-Path $d1.FullName '.git')) { $candidates.Add($d1.FullName); continue }
        foreach ($d2 in Get-ChildItem $d1.FullName -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch $skip }) {
            if (Test-Path (Join-Path $d2.FullName '.git')) { $candidates.Add($d2.FullName) }
        }
    }
}

$repos = foreach ($path in ($candidates | Select-Object -Unique)) {
    $lines = foreach ($em in $Emails) { git -C $path log --all --author="$em" --since="$Days days ago" --format="%H|%aI" 2>$null }
    $lines = @($lines | Where-Object { $_ } | Sort-Object -Unique)
    if ($lines.Count -gt 0) {
        $last = ($lines | ForEach-Object { ($_ -split '\|')[1] } | Sort-Object -Descending | Select-Object -First 1)
        [pscustomobject]@{ path = $path; commits = $lines.Count; lastCommit = $last }
    }
}
Out-Json ([pscustomobject]@{ emails = $Emails; days = $Days; repos = @($repos | Sort-Object commits -Descending) })
