<#
.SYNOPSIS
  Reads a saved Jira search result (fields: summary, assignee, comment) and keeps only the issues
  where the person wrote a comment in the date range. Used for "not assigned to me" evidence, whose
  search result is often too large to come back inline and is saved to a file by Claude Code.
.PARAMETER File
  The search result: {issues:{nodes:[...]}}, {issues:[...]} or a plain array of issues.
.PARAMETER From / To
  Local dates (team timezone), inclusive. To defaults to From.
.PARAMETER AccountId
  Defaults to config.json accountId.
.OUTPUTS
  JSON: { from, to, scanned, days: [ {date, issues: [ {key, summary, assignee, assignedToMe, comments: [ {time, text} ]} ]} ] }
#>
param(
    [Parameter(Mandatory)][string]$File,
    [Parameter(Mandatory)][string]$From,
    [string]$To,
    [string]$AccountId
)
. "$PSScriptRoot\common.ps1"

if (-not $To) { $To = $From }
$team = Get-TeamDefaults
$offset = Get-TzOffset $team
if (-not $AccountId) { $AccountId = (Get-UserConfig).accountId }
if (-not $AccountId) { throw 'No accountId: pass -AccountId or run setup.' }

$data = Read-JsonFile $File
if (-not $data) { throw "Empty or missing file: $File" }
$nodes = if ($data.issues -and $data.issues.nodes) { $data.issues.nodes } elseif ($data.issues) { $data.issues } else { $data }

# Comment bodies are ADF (object) or markdown/plain text (string).
function Get-BodyText($Body) {
    if ($null -eq $Body) { return '' }
    if ($Body -is [string]) { return $Body }
    $parts = New-Object System.Collections.Generic.List[string]
    $walk = {
        param($n)
        if ($null -eq $n) { return }
        if ($n.text) { $parts.Add([string]$n.text) }
        if ($n.attrs -and $n.attrs.text) { $parts.Add([string]$n.attrs.text) }
        foreach ($c in @($n.content)) { & $walk $c }
    }
    & $walk $Body
    return ($parts -join ' ')
}

$byDate = @{}
$scanned = 0
foreach ($n in @($nodes)) {
    $scanned++
    $f = $n.fields
    $assignee = if ($f.assignee) { $f.assignee.displayName } else { $null }
    $mine = [bool]($f.assignee -and $f.assignee.accountId -eq $AccountId)
    foreach ($c in @($f.comment.comments | Where-Object { $_ -and $_.author.accountId -eq $AccountId })) {
        $t = ConvertTo-LocalTime $c.created $offset
        $d = $t.ToString('yyyy-MM-dd')
        if ($d -lt $From -or $d -gt $To) { continue }
        $text = ((Get-BodyText $c.body) -replace '<[^>]+>', '' -replace '\s+', ' ').Trim()
        if ($text.Length -gt 160) { $text = $text.Substring(0, 160) + '...' }
        if (-not $byDate.ContainsKey($d)) { $byDate[$d] = [ordered]@{} }
        if (-not $byDate[$d].Contains($n.key)) {
            $byDate[$d][$n.key] = [pscustomobject]@{ key = $n.key; summary = $f.summary; assignee = $assignee; assignedToMe = $mine; comments = New-Object System.Collections.ArrayList }
        }
        [void]$byDate[$d][$n.key].comments.Add([pscustomobject]@{ time = $t.ToString('HH:mm'); text = $text })
    }
}

$days = foreach ($d in ($byDate.Keys | Sort-Object)) {
    [pscustomobject]@{ date = $d; issues = @($byDate[$d].Values | ForEach-Object { $_.comments = @($_.comments | Sort-Object time); $_ }) }
}
Out-Json ([pscustomobject]@{ from = $From; to = $To; scanned = $scanned; days = @($days) })
