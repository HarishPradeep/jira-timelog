---
name: jira-timelog
description: Fill the user's Jira time for a day, a range, or every missed day. Gathers evidence from git (commits, changed files, branch switches), Jira (status changes, comments) and the team's meeting schedule, skips weekends, public holidays and leave from the Confluence Leave Plan, proposes worklogs (min 8h; max set per person; meetings on the person's meetings ticket) and logs them ONLY after the user approves. Use when the user runs /jira-timelog or asks to log, fill, catch up on or fix their Jira time.
argument-hint: "[today | yesterday | last friday | YYYY-MM-DD | this week | <from>..<to> | missing [N] | fix <date> | setup | leave refresh | status | reminder on [HH:MM] | reminder off | reminder test | doctor]"
---

# Jira time logging

**Golden rule: never call `addWorklogToJiraIssue` before the user explicitly approves the latest table** ("approve", "yes", "go", "ok log it"). This applies in every mode, including catch-up.

Other rules:
- Never invent work. Rows without evidence are marked ❓ and the user must accept them.
- Day minimum: **8h** (team rule; half-day leave: **4h**). Day maximum: the person's `maxHours`. Both include time already logged.
- Leave days, public holidays and weekends are **skipped**: nothing is logged.
- Meetings and PR reviews go to the person's **meetings ticket**, one worklog per meeting.

## Files

| Path | What |
|---|---|
| `team-defaults.json` (skill dir, git-ignored; copy from `team-defaults.example.json`) | Shared: Jira cloudId/site, timezone, min hours, default meeting schedule, Leave Plan location |
| `holidays/<year>.json` (skill dir) | Shared public holiday list. `verified:false` means it has not been checked against the Leave Plan image yet |
| `~/.claude/jira-timelog/config.json` | Per person: accountId, gitEmails, repos, meetingsTicket, maxHours, optional `meetings` override |
| `~/.claude/jira-timelog/state.json` | Per person: worklogs this skill created (IDs), cached leave days |
| `~/.claude/jira-timelog/calls.json` | Per person: Teams call start/end events saved from the Teams log, which logged hours it covers, and measured length per meeting (`history`, used for usual lengths). Kept 120 days |

Scripts live in `~/.claude/skills/jira-timelog/scripts/` and print JSON. Run them with the PowerShell tool, always through a child PowerShell so a restrictive execution policy can't block them:
`powershell -NoProfile -ExecutionPolicy Bypass -File "$HOME\.claude\skills\jira-timelog\scripts\<name>.ps1" <args>`
**JSON input always goes through a file**: write it with the Write tool to the scratchpad and pass `-JsonFile <path>`. Never pass `-Json '…'` through `powershell -File`: Windows strips the double quotes and the script gets invalid JSON.

| Script | Purpose |
|---|---|
| `detect-repos.ps1 [-Emails a,b] [-Days 30]` | Repos (2 folders deep on all drives) with the person's commits |
| `day-plan.ps1 -From d [-To d]` or `-LastWorkingDays N` | Per day: `kind` (workday / weekend / holiday / leave / half-day / tentative-leave / future), `loggable`, `minHours`, `maxHours`, `workStart`, scheduled `meetings`; plus `warnings` |
| `collect-git.ps1 -From d [-To d]` | Per day: commits (keys, files, +/- lines, merge flag), `branchSwitches` from the reflog, `branchAtStartOfDay`, first/last activity; `uncommitted` work when the range includes today |
| `schedule.ps1 -Date d -JsonFile f` (f = `{workStart, until?, logged:[{start,minutes}], meetings:[{issue,name,start,minutes}], work:[{issue,minutes}]}`) | Start times → `{rows, unplaced, coveredUntil}`: meetings keep their slot, already-logged blocks stay free, work fills the gaps (split around meetings); with `until` nothing is placed after that time and the rest is `unplaced` |
| `collect-prs.ps1 -From d [-To d]` / `-Detect` | Per day: `authored` (your PRs created / completed / merged) and `reviews` (others' PRs you commented on, voted on or reviewed, with times). Azure DevOps via `az`, GitHub via `gh`. Slow (~1 min for 2 weeks): one call per range |
| `collect-calls.ps1 -From d [-To d]` / `-Capture` | Measured meetings from the new Teams log. Per day: `calls` (start, end, minutes, `open` = no end seen), `meetings` (each scheduled meeting with its matched `call`, `measuredMinutes` rounded to 5, `logCovered` = Teams was logging at its start, `usualMinutes` = median of the last 10 measurements), `unscheduled` (calls matching no meeting), `covered` spans. Each call also has `with` (names from the Teams call history cache, or null), `direction`, `callType` (TwoParty = 1:1) and `source` (`log`, or `history` when only the cache saw it). `-Capture` only saves events (Teams keeps about a day of logs) |
| `own-activity.ps1 -File f -From d [-To d]` | Filters a saved Jira search result (fields: summary, assignee, comment) down to the issues you commented on in the range → per day `{key, summary, assignee, assignedToMe, comments:[{time,text}]}` |
| `state.ps1 get\|record\|remove\|set-leave\|summary\|snapshot` | Read/update state.json (`snapshot` stores what Jira showed as logged per day, used by the reminder) |
| `check-missing.ps1 [-IncludeToday]` | Local-only list of recent working days under their minimum (no Jira call) |
| `install-reminder.ps1 [-Time HH:mm] [-Uninstall]` | Mon–Fri scheduled task "JiraTimelogReminder" + `jiratimelog:` link handler (HKCU, no admin) |
| `reminder.ps1 [-Test]` | The notification itself: **Log now** opens Claude Code with `/jira-timelog` (or `missing`), **Snooze 30 min** |
| `doctor.ps1 [-Quick]` | Local health check (system, skill files, git, config, repos, az/gh, leave cache, reminder) → `{summary, checks:[{area, check, status, detail, fix}]}` |
| `startup-check.ps1` | SessionStart hook: `{"systemMessage": …}` when days are missing (throttled to once per 3h) |

Use the Atlassian Rovo MCP tools (`mcp__claude_ai_Atlassian_Rovo__*`), loading them with ToolSearch if they are deferred. Python is not installed, so parse large tool results with PowerShell `ConvertFrom-Json`. In Windows PowerShell 5.1 wrap a piped array in parentheses: `(... | ConvertFrom-Json) | ForEach-Object`.

## 0. Start of every run
1. Read `config.json`. If it is missing, or the argument is `setup`, run **Setup** first.
2. Parse the argument into a mode and dates (timezone from team defaults, +05:30):
   - empty / `today` · `yesterday` · `last <weekday>` · `YYYY-MM-DD`, `YYYY.MM.DD`, `YYYY/MM/DD` → a single day
   - `this week` (Mon→today) · `last week` (Mon→Fri) · `<from>..<to>` → a range
   - `missing [N]` → catch-up over the last N working days (default `catchUpDays`)
   - `fix <date>` · `setup` · `leave refresh` · `status` · `reminder …` · `doctor` → see their sections
   (`doctor` works without config.json; run it before Setup's check.)
3. Run `day-plan.ps1` for the dates. Act on its `warnings`:
   - leave cache stale or missing → run **Leave refresh** (quietly), then re-run day-plan
   - holiday file unverified/missing → mention it once in the final message (don't block)

## Setup (first run, or `setup`)
0. If `team-defaults.json` is missing in the skill dir: copy `team-defaults.example.json` to it, get the site and cloudId from `getAccessibleAtlassianResources`, ask for the Leave Plan space key, and fill them in.
1. `atlassianUserInfo` → accountId, display name.
2. Git emails: `git config --global user.email`. Ask whether there are others (e.g. a personal email used on some repos).
3. `detect-repos.ps1 -Emails <emails>` → show the list and ask the user to confirm, remove or add paths.
4. Meetings ticket: JQL `worklogAuthor = currentUser() AND worklogDate >= -30d AND (summary ~ "meeting" OR summary ~ "PR review")` (fields: summary). One hit → confirm it. Several → ask which. None → ask for the key.
5. Ask for **max hours per day** (default 12; must be ≥ 8). Show the team meeting schedule from `team-defaults.json` and ask whether theirs is different. If it is, store a full `meetings` array in config, using the same shape as `defaultMeetings`.
6. PR sources: after repos are confirmed, run `collect-prs.ps1 -Detect` (it reads the repos' remotes and the `az` / `gh` logins). Show the result. If it warns that `az` or `gh` isn't logged in, tell the user the command (`! az login`, `! gh auth login`) and continue without that source.
7. Write `config.json` with the Write tool (version 1, accountId, displayName, gitEmails, repos, meetingsTicket, maxHours, workdayStart "09:00", meetings or null, prSources).
8. Run **Leave refresh**. Show a short summary of the saved settings.
9. Offer the reminder ("Remind you Mon–Fri at 18:00?"). If yes, run `reminder on` and add the SessionStart hook (see **Reminder**).
10. Finish with **doctor** so the person sees everything is green.

## `doctor`: "is everything ready?"
Read-only; never writes to Jira. Two parts, then one report.
1. **Local**: `doctor.ps1` (add `-Quick` to skip the Azure DevOps / GitHub network calls).
2. **Online** (needs the Atlassian tools, so the skill does it), each one an ok / warn / fail line:
   - Atlassian tools available (ToolSearch finds `mcp__claude_ai_Atlassian_Rovo__searchJiraIssuesUsingJql`). Missing → fail: "Connect the Atlassian connector in claude.ai → Settings → Connectors, then restart Claude Code".
   - `atlassianUserInfo` works, and its accountId equals `config.accountId` (mismatch → fail: signed in as someone else).
   - Jira search: `worklogAuthor = currentUser() AND worklogDate >= -14d` (fields: summary, maxResults 1) runs without error.
   - Meetings ticket: `getJiraIssue <meetingsTicket>` (fields: summary, status) is readable → show its summary.
   - Leave Plan: CQL for `Leave Plan <year>` finds the page; in its HTML a row mentions `data-user-id="<accountId>"`. Page missing → warn. Not on the page → warn: "you're not on the Leave Plan, so leave days won't be skipped automatically; ask the page owner to add you".
   - Writing worklogs can't be tested without writing. Say it's verified the first time the user approves a table, and that `addWorklogToJiraIssue` asks for permission (the permission rule in settings).
3. Report as one table grouped by area: `✅ / ⚠️ / ❌ | Check | Detail`, then a **"To fix"** list with only the ❌ and ⚠️ fixes, as commands the user can run (prefix shell commands with `!`). End with the verdict:
   - no ❌ → "Ready to use ✅" (mention any ⚠️ as optional)
   - any ❌ → "Not ready: fix the ❌ items, then run `/jira-timelog doctor` again".

## Leave refresh
1. CQL `space = <spaceKey> AND type = page AND title = "Leave Plan <year>"` (from `leavePlan` in team defaults). Not found → warn and continue without leave.
2. `getConfluencePage` with `contentFormat: "html"`. Find the table row whose first cell has `data-type="mention"` with `data-user-id="<accountId>"`. Map each month column header (`January <year>` …) to its cell text; a cell may contain several `<p>` paragraphs.
3. Interpret each cell into date → value:
   - `16`, `21st`, `05th` → that day `full`; `27-30` / `15-19` → each day in the range `full`
   - "half" with morning / first half → `am` (morning off); evening / afternoon / second half → `pm`; no half stated → `half`
   - "(tentative)" → `tentative` (or `tentative-am` / `tentative-pm`), applied to the number(s) it is attached to
   - "21st28th" style run-ons are two days. If anything is truly ambiguous, ask the user rather than guess.
4. Save it to a scratch JSON `{ pageId, lastModified, days: { "YYYY-MM-DD": value } }` and run `state.ps1 set-leave -Year <year> -JsonFile <file>`.

## 1. Already logged (per date)
`worklogs.total` can be larger than the worklogs embedded in a search result (max 20, oldest first; the meetings ticket has hundreds), so:
1. JQL `worklogAuthor = currentUser() AND worklogDate >= "<from>" AND worklogDate <= "<to>" AND key != <meetingsTicket>` (fields: summary, worklog). For each issue whose `worklog.total` ≤ the number returned, sum the worklogs where `author.accountId` = me and the local date of `started` is in range, per date. If an issue is truncated, treat it like the meetings ticket below.
2. Meetings ticket (and any truncated issue), per date: JQL `worklogAuthor = currentUser() AND worklogDate = "<d>" AND key = <key>` (fields: summary). Do **not** request the `worklog` field for it (the payload is huge).
   - Not returned → nothing logged there that day.
   - Returned → use the matching entries from `state.ps1 get -Date <d>` for the amount. If state has none, the time was logged outside this skill and the amount is unknown: tell the user and ask how much it was before proposing.
3. **Tempo guard**: one JQL for the range, `worklogAuthor = "<tempoAppAccountId>" AND worklogDate >= "<from>" AND worklogDate <= "<to>"` (fields: summary). Worklogs written through Tempo are authored by the Tempo app, not the person, so they are invisible to the checks above. Usually this returns nothing (the team stopped using Tempo in 2025). If it returns issues, tell the user that Tempo worklogs exist in this range that may be theirs, and ask how much of their time on those days was logged via Tempo before proposing.
4. Logged ≥ the day's minimum → report it and skip the day unless the user asks to add more (still ≤ max).
5. Save what you found so the reminder stays accurate: `state.ps1 snapshot -JsonFile <f>` with `{"<d>":{"minutes":N,"partial":<true if meetings-ticket time exists but its amount is unknown>}, …}`. Do this in every mode that runs this step (`status`, `missing`, single days) and again after writing (section 5), and once the user tells you an unknown amount.
6. Keep the **list of already-logged worklogs** per date, not just the total: issue, start (local HH:mm), minutes, comment. Sources: the embedded Jira worklogs from item 1 (comment text from the ADF) plus `state.ps1 get -Date <d>` for the meetings ticket. `coveredUntil` = the latest end time among them (null if nothing is logged).

## 1b. Partial day and continuing a day
Decide the **day mode** per date:
- **Partial**: the date is today and the current time is before `reminderTime` (default 18:00), unless the user said "full day" / "log the whole day" (e.g. leaving early). Only time **up to now** is logged.
- **Continue**: something is already logged that day (`coveredUntil` not null) and the day is under its minimum. Only time **after `coveredUntil`** is proposed.
- Both can apply: a second run at 15:00 is partial and continue.
- Otherwise **full**: normal behaviour.

What changes:
- **Evidence window**: in continue mode pass `-After <coveredUntil>` to `collect-git.ps1` and `collect-prs.ps1` for that date (run them per date then, not as one range call). Use only Jira status changes and comments with a time ≥ `coveredUntil` (changelog `created`, comment `created`). In partial mode ignore anything after now (there is none, but uncommitted work counts as "now").
- **Meetings already logged**: drop a scheduled meeting when a worklog on the meetings ticket that day has a comment containing its `name` or one of its `aliases` (case-insensitive). Drop a PR review when a meetings-ticket comment that day contains `#<id>`. In partial mode also drop meetings whose `start` is after now (they come in the evening run).
- **Target**:
  - partial → the working time from `max(workStart, coveredUntil)` to **now**, rounded down to 15m, including the meetings in that window. No ❓ filling beyond now.
  - continue (not partial) → `minHours` − already logged (more only with clear evidence, never above `maxHours` − logged).
- **Start times**: call `schedule.ps1` with `"workStart"` = `coveredUntil` (or the day's `workStart`), `"logged"` = the already-logged blocks (so nothing overlaps them), and in partial mode `"until"` = now (HH:mm). If `unplaced` is not empty, either shrink those rows or tell the user they don't fit before now.
- **Header** of the table: `📅 Mon 2026-10-05 · partial (until 13:05) · already logged 0h · new 4h · so far 4h — run again this evening` or `· continuing after 13:00 · already logged 4h · new 4h · day total 8h ✔`. List the already-logged rows above the new ones, greyed as "(logged)", so the user sees the whole day.

## 2. Evidence (per date)
**Jira** (skip the meetings ticket here):
- Status changes: `status CHANGED BY currentUser() DURING ("<d>", "<d+1>")` (fields: summary, status).
- Candidates: `assignee = currentUser() AND updated >= "<d>" AND updated < "<d+1>"` (fields: summary, status, comment). Keep the user's own comments created that day (`author.accountId` = me).
- **Not assigned to me** (people often work on tickets assigned to someone else, or unassigned): one JQL for the whole range, `(watcher = currentUser() OR status CHANGED BY currentUser() DURING ("<from>", "<to+1>") OR assignee CHANGED BY currentUser() DURING ("<from>", "<to+1>")) AND updated >= "<from>" AND (assignee != currentUser() OR assignee is EMPTY) AND key != <meetingsTicket>` (fields: summary, assignee, comment; maxResults 100). Commenting makes you a watcher, so this catches comments too. The result is usually too big to come back inline; Claude Code saves it to a file, then run `own-activity.ps1 -File <that file> -From <from> -To <to>`. If it does come back inline, apply the same filter yourself. Being a watcher alone is **not** evidence. Keep only issues with your own comment that day (from the script) or your own status/assignee change that day (from the status query above / changelog). Show these rows with the current assignee in the Title column, e.g. `Checkpoint twice in PDF (assignee: Sven)`.
- Git commit / branch keys and PR keys count **whatever the assignee is**. For a key that none of the Jira queries returned, call `getJiraIssue` (fields: summary, assignee, status) to get its title, and check that it exists before proposing it.
- For up to ~6 issues that matter, call `getJiraIssue` with `expand: "changelog"` and `fields: ["summary"]` to get exact transition times. Ignore histories authored by others (sprint rollovers, other people's edits).
- `updatedBy()` is not supported on this Jira; don't use it.

**Git**: `collect-git.ps1 -From <from> -To <to>` (one call for the whole range).
- Branch session = a switch *to* a branch with key K until the next switch away in the same repo (or that day's last activity). These sessions are the best time evidence.
- Commits: map by keys in the subject or refs. Use changed files and +/- lines to judge size and to write the comment. Merge commits ("Merge pull request #N") are light evidence, e.g. "Merged PR #N".
- A commit with no key → propose the most likely ticket (by branch session or repo) and mark it ⚠.
- `uncommitted` (today only): work in progress on that branch's ticket.

**Pull requests**: `collect-prs.ps1 -From <from> -To <to>` (one call for the whole range; skip it if config has no `prSources`).
- `authored` → evidence for the ticket in the PR's keys: `created` = ✅ (the work was being finished that day, so mention "opened PR #N" in the comment); `completed` / `merged` = ⚠ light evidence ("merged PR #N").
- `reviews` → **PR review rows on the meetings ticket**, one per PR per day, comment `PR review – #<id> <KEY> (<author>)`. Suggested time from `prReviewMinutes`: only votes/approvals → 15m; 1–2 comments → 30m; ≥ `manyCommentsThreshold` comments or first→last span over an hour → 45m. Merge PRs by the same author for the same key on the same day (API + UI pair) into one row, e.g. `PR review – #20334/#20335 IV-19148`. Start time = the review's `firstTime` (pass it as `start` to schedule.ps1) unless that overlaps a meeting.
- These rows are evidence-based (📝 in the Ev column), and the user can still change their minutes.

**Meetings (Teams calls)**: `collect-calls.ps1 -From <from> -To <to>` (one call for the range, in parallel with git and PRs). It reads the new Teams log, which records when a call starts and ends but not which meeting it was, so calls are matched to the schedule by start time (±15 min). Who a call was with comes from Teams' local call history cache (1:1 and direct calls; meeting joins usually have no names). Calls on a phone or in a browser are not in either.

**Evidence marks**: ✅ branch session, commit, own comment or PR created · 📝 PR review (from PR comments/votes) · 📞 meeting measured from a Teams call · 📅 meeting from the schedule only · ⚠ status change or merge only · ❓ no evidence (gap filler).

## 3. Build the proposal (per date)
1. **Meetings** from day-plan `meetings`, each on the meetings ticket. Length and start come from `collect-calls`, in this order:
   - `measuredMinutes` set → use it and the call's real `start`; mark 📞. Don't ask `askMinutes`; the measurement answers it.
   - `call.open` (start seen, no end) → show the start, ask the length.
   - no call and `logCovered` true → Teams was logging and saw no call: ask "Did <meeting> happen today? (no Teams call found)". Default **not** to log it; include it if the user says it happened (phone/browser).
   - no call and `logCovered` false (Teams closed, or logs lost) → the old behaviour: scheduled `start`, `usualMinutes` if `usualSamples` ≥ 3, else the default `minutes`; if it has `askMinutes`, ask which. Mark 📅.
   - `unscheduled` calls → one question each. With `with` set: "Call with Jane Doe 12:18–12:35 (17m, incoming): what was it about?" and the comment becomes `Call with <names> – <user's answer>` (the names alone if the user just says "ok"). Without `with`: "Unscheduled call 11:10–11:40 (30m): what was it?" and the comment is `Call – <user's answer>`. Default to the meetings ticket; the user may name another ticket or say "skip". Calls under 5 minutes are listed but proposed as skipped.
   Half-day `half` or tentative leave → ask first. Add the **PR review rows** from step 2 here too (they count as meetings-ticket time).
2. **Target** = max(`minHours`, evidence span) − already logged, capped at `maxHours` − already logged. Go above the minimum only when the first→last activity clearly shows a longer day. In partial or continue mode use the target from section 1b instead, and leave out meetings and PR reviews that are already logged.
3. **Work** = target − meetings, split across evidenced tickets in proportion to evidence (session length first, then commit size, then transitions/comments). Every ticket with ✅ evidence gets ≥ 30m. Round to 15m; the total must be exact.
4. Not enough evidence to fill the target → put the remainder on the most likely ticket(s), marked ❓, and say so. Never present guessed work as fact.
5. **Comments**: 1–2 plain lines from what actually happened (changed files, commit subjects, transitions, own comments). Wording must match the evidence strength: ⚠/❓ rows get modest wording ("Follow-up on …", "Moved to QA after verification"), not invented detail.
6. Start times: `schedule.ps1 -Date <d> -JsonFile <f>` with `{"workStart":"<workStart or coveredUntil>","until":"<now, partial only>","logged":[…already-logged blocks],"meetings":[…with issue + start],"work":[…]}` and use its `rows`. A work row may be split into parts around meetings; show the parts as separate rows.

## 4. One message: meeting questions + table + approval
```
📅 Fri 2026-10-02 · workday · already logged 0h · new 8h · day total 8h (min 8h, max 12h ✔)
Meetings: Internal meeting 09:31–09:52 20m 📞 · Oslo scrum 14:30 — no Teams call found, did it happen? · Call with Jane Doe 12:18–12:35 (17m) — what was it about? · Unscheduled call 11:10–11:40 (30m) — what was it? · any other meetings (phone/browser)?
PR reviews found: #20334/#20335 IV-19148 (Pasindu, 8 comments) 45m · #1483 IV-19131 (Yasir, 1 comment) 30m — adjust?

| # | Start–End   | Issue    | Title                    | Time   | Ev | Worklog comment |
|---|-------------|----------|--------------------------|--------|----|-----------------|
| 1 | 09:00–09:30 | IV-18148 | Rich text editor paste   | 30m    | ✅ | … |
| 2 | 09:30–10:00 | IV-15353 | Internal meeting         | 30m    | 📅 | Internal meeting |
…
Skipped: Sat 10-03, Sun 10-04 (weekend)
```
The table assumes the defaults. End with **Approve / Edit / Cancel**. An answer to the meeting questions is an edit: apply it, re-validate min/max, show the table again and ask again. Only approval of the latest table counts.

## 5. Write (after approval only)
1. **Duplicate guard**: re-run the step 1 check for each date about to be written. If more time is logged now than when the table was shown, stop and show the difference. Also check each new row against the already-logged list: same issue with an overlapping time, or a meeting / PR review already present (name, alias or `#id` in a comment) → drop that row and tell the user.
2. For each row, in time order: `addWorklogToJiraIssue` (cloudId, issueIdOrKey, `timeSpent` e.g. "1h 30m", `started` from schedule.ps1, `commentBody`, `contentFormat: "markdown"`).
3. After each success, record it: `state.ps1 record -Date <d> -JsonFile <f>` with `[{"issue":"…","worklogId":"<id from response>","minutes":N,"started":"…","comment":"…"}]`.
4. On the first failure: stop, report what succeeded and what failed, and do not retry silently.
5. Report: per date, each issue + time with `<jira.site>/browse/<key>`, the day total, and any warnings (e.g. holiday list unverified).

## Catch-up: `missing [N]`
1. `day-plan.ps1 -LastWorkingDays N` → loggable days (skipped days are listed with their reason).
2. Step 1 for the whole range → days below their minimum. None → say so and stop.
3. Evidence: one `collect-git.ps1` call and one `collect-prs.ps1` call for the range (run them in parallel); Jira status/candidate queries per day.
4. Ask the meeting questions **once** for the batch, only for what `collect-calls` could not measure (no call, open call, unscheduled call, days with no Teams log), grouped by day. Then show one table per day, oldest first.
5. Accept: `approve all`, `approve <dates>`, or edits per date. Write the approved days only, oldest first, using section 5.

## `fix <date>`
Jira can't delete worklogs through these tools. `state.ps1 get -Date <d>` lists what this skill wrote, with links `<jira.site>/browse/<key>?focusedWorklogId=<id>`.
- Change time, comment or start → `addWorklogToJiraIssue` with `worklogId` (after approval), then `state.ps1 record` the new values and `state.ps1 remove` the old ID.
- Remove → the user deletes it in Jira via the link, then run `state.ps1 remove -Date <d> -Ids <id>`.

## `status`
Show the config summary, leave cache date, holiday file status, reminder status (`Get-ScheduledTask JiraTimelogReminder` → state and next run), and a `missing` check without writing to Jira.

## Reminder: `reminder on [HH:MM]` · `reminder off` · `reminder test`
- `on`: if a time is given, save it as `reminderTime` in config.json. Then run `install-reminder.ps1` (it reads the time from config). Report the task state and next run. Setup offers this as its last step.
- `off`: `install-reminder.ps1 -Uninstall`.
- `test`: `reminder.ps1 -Test` shows the notification now.
- `on` also installs **JiraTimelogCallCapture**: Mon–Fri every 2 hours from 08:00, it silently runs `collect-calls.ps1 -Capture`, because Teams keeps only about a day of logs. The reminder and the start-up hook capture too. `off` removes both tasks.
- How it behaves: Mon–Fri at the reminder time (or when the PC wakes, if it was off), only when today or recent days look under the minimum according to the local snapshot. **Log now** opens a terminal running `claude '/jira-timelog'`, or `'/jira-timelog missing'` when earlier days are involved. Nothing is logged without approval in that session.
- Claude Code start-up: the SessionStart hook in `~/.claude/settings.json` runs `startup-check.ps1`. Setup should add it for new users (merge into the existing `hooks`; use `"command": "powershell.exe"` with `args` `["-NoProfile","-ExecutionPolicy","Bypass","-File","<home>\\.claude\\skills\\jira-timelog\\scripts\\startup-check.ps1"]`).
