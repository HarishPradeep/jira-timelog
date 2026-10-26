# jira-timelog

A Claude Code skill that fills your Jira time. It gathers evidence from git (commits, branch switches), pull requests (Azure DevOps / GitHub), Jira (status changes, comments) and Teams calls, skips weekends, public holidays and leave from a Confluence Leave Plan, proposes worklogs as a table and logs them **only after you approve**.

## Install

1. Clone into your Claude Code skills folder:
   ```powershell
   git clone https://github.com/HarishPradeep/jira-timelog "$HOME\.claude\skills\jira-timelog"
   ```
2. Connect the Atlassian connector in claude.ai → Settings → Connectors, then restart Claude Code.
3. Run `/jira-timelog setup`. It creates `team-defaults.json` from `team-defaults.example.json`, then your personal config in `~/.claude/jira-timelog/`.
4. Run `/jira-timelog doctor` to check that everything is ready.

Requirements: Windows with PowerShell 5.1, git, and optionally `az` / `gh` for pull request evidence.

## Use

| Command | What it does |
|---|---|
| `/jira-timelog` | Log today (up to now before 18:00, the full day after) |
| `/jira-timelog yesterday`, `2026-10-23`, `last week` | Log a day or a range |
| `/jira-timelog missing` | Catch up on every recent day under the minimum |
| `/jira-timelog fix <date>` | Change worklogs this skill wrote |
| `/jira-timelog reminder on 18:00` | Mon–Fri reminder notification |
| `/jira-timelog doctor` | Health check |

See `SKILL.md` for the full rules.
