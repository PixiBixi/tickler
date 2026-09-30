# Tickler V2 design: live status of linked MRs, tickets and PRs

Date: 2026-10-01. Status: scope agreed in conversation (V2 = live MR/ticket/PR status plus an Approve button behind a confirmation, sources `glab`, `jira`, `gh`); the owner asked to build it without a review round.

## Goal

A reminder about a merge request or a ticket should say whether the action is still needed before anyone opens a browser: is the pipeline green, is it approved, is the ticket still in progress. When the owner may approve a GitLab MR, the app offers it, with a confirmation, since an approval goes out in their name and cannot be taken back cleanly.

## Scope

- GitLab merge requests (any host `glab` is logged into): title, state, draft, pipeline status and link, approvals required and given, whether the owner already approved or may approve, detailed merge status, conflicts, unresolved blocking threads.
- Jira issues: summary, status and status category, assignee.
- GitHub pull requests: title, state, draft, review decision, checks summary (passed, failed, pending).
- Approve a GitLab MR from the detail pane, only when GitLab says the owner can approve and has not yet, and only after a confirmation dialog naming the MR and the project.
- `tickler status <id> [--json]`: the same live data for Claude at check time.

Out of scope: approving from a notification (too easy to hit by mistake), merging, GitHub reviews, caching in the database, Slack (V3).

## Architecture

All in `Sources/TicklerCore/Live/`:

| Unit | Responsibility |
|---|---|
| `LiveTarget` | Recognizes a link: `.gitlabMR(host, project, iid)`, `.jira(key)`, `.githubPR(owner, repo, number)`. Validates every part with a strict pattern, so nothing unexpected reaches a command line |
| `LiveStatus` and its three structs | The data shown, `Codable` for the CLI JSON |
| `LiveStatusParser` | Pure decoding of the three CLIs' JSON, unit-tested with fixtures |
| `CommandRunning` / `LoginShellRunner` | Runs a tool through the user's login shell (`$SHELL -lic 'exec "$0" "$@"' tool args...`): the app, started from Finder, has neither the shell PATH nor tokens like `JIRA_API_TOKEN`. Arguments are passed as positional parameters, never interpolated |
| `LiveStatusFetcher` | Maps a target to CLI calls and parses the result; `approve(_:)` for GitLab |

Calls:

- GitLab: `glab api --hostname <host> projects/<url-encoded path>/merge_requests/<iid>` and `.../approvals`; approve with `glab api --hostname <host> -X POST .../approve`.
- Jira: `jira issue view <KEY> --raw`.
- GitHub: `gh pr view <url> --json number,title,state,isDraft,reviewDecision,statusCheckRollup,url`.

Errors are per link and never block the rest: tool missing, not logged in or any non-zero exit shows as a short message on that link's card.

## App

- The detail pane gets a "Live status" section above the links: one card per recognized link, with a refresh button and the age of the data. Status loads when a reminder is selected, refreshes if older than 2 minutes, and on demand.
- MR card: pipeline chip (colored by state, opens the pipeline), approvals `given / required`, threads, merge status, conflicts; buttons Approve… (only when allowed), Open in GitLab, Pipeline.
- Ticket card: status chip by category (to do, in progress, done), assignee, summary.
- PR card: checks summary, review decision, state.
- Approve… opens a confirmation dialog: "Approve !221 in <project>?" with "The approval is sent in your name and notifies the author." After success the card refreshes.
- In memory only (`LiveStatusStore`, keyed by URL). Nothing new in SQLite.

## Testing

Unit: target recognition (hosts, nested GitLab groups, invalid parts rejected), parsers on fixtures (states, missing pipeline, checks mix, missing assignee), fetcher arguments with a fake runner (including the approve call), error mapping. Fixtures use neutral example data. Not unit-tested: the SwiftUI cards and the real CLIs.
