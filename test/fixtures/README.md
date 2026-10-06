# Test fixtures

Real output captured on 2026-09-28, trimmed to the fields the board reads.
The shape, timings, counts and outcomes are as the tools printed them. Names
that pointed at private work are made up: the repository is `acme/shop`,
issue ids are `SHOP-nnnn` (same digits), pull request titles, branch names,
workflow files, AWS names and account ids (`123456789012`), paths, and Claude
session and request ids are all replaced, the same way in every file.

| File | Where it came from |
|---|---|
| claude/agents_busy.json | `claude agents --json` (second account): three busy background sessions |
| claude/agents_all.json | `claude agents --json --all`: adds done and stopped sessions |
| claude/agents_empty.json | `claude agents --json` for an account with no sessions |
| claude/job_state_planner.json | `jobs/4a662dec/state.json`, a working background job |
| claude/job_state_other.json | `jobs/97a04926/state.json`, a stopped background job |
| claude/session_file_planner.json | `sessions/32714.json` |
| claude/timeline_blocked_record.json | the newest real "blocked" record from a job's timeline.jsonl |
| claude/transcript_trimmed.jsonl | 65 real lines from this build's own session transcript: model replies (usage, model, effort, request id, stop reason, time) and file edits (patch shape). All conversation and file text is removed; patch lines keep only their +/-/space mark |
| github/runs_24h.json | `gh api repos/acme/shop/actions/runs?per_page=100&created=>=<24h ago>` |
| github/deploy_*.json | `gh api repos/acme/shop/actions/workflows/<file>/runs?per_page=10` |
| github/jobs_completed.json | `gh api repos/acme/shop/actions/runs/36487639186/jobs` |
| github/graphql.json | `gh api graphql` for the merge queue and open pull requests |
| github/pulls_closed.json | `gh api "repos/acme/shop/pulls?state=closed&sort=updated&direction=desc&per_page=6"`, captured 2026-10-05, trimmed to the fields the board reads; titles, branches and the author are made up |
| aws/db_stopped.json | `aws rds describe-db-instances --db-instance-identifier shop-dev-db --profile dev-readonly`, with dev asleep, trimmed to the name and status |
| aws/list_services.json | `aws ecs list-services --cluster shop-dev --profile dev-readonly` |
| aws/services_asleep.json | `aws ecs describe-services` for those services, with dev asleep, trimmed to name, status and task counts |

No Claude session was waiting on anyone while these were captured, so the
tests for the "needs you" case take the real busy output and set the one
field Claude Code 2.1.284 sets for a waiting session (`state: "blocked"`, or
`status: "waiting"` with `waitingFor`). New Relic has no real fixture: this
session was not allowed to read the key, so its parsing test uses the reply
shape from New Relic's NerdGraph documentation and says so.

`claude/agents_stopped_job.json` is not a capture. It is written by hand in
the shape `claude agents --json` printed on Claude Code 2.1.285, with made-up
sessions: a background job that ended or was stopped but is still listed as
`state: "working"` with no `pid` and no `status`, beside a busy and an idle
background session and a session in a terminal, which all have a `pid`.

`github/workflows.json` is not a capture either. It is written by hand in the
shape `gh api repos/<owner>/<name>/actions/workflows` answers in, per GitHub's
REST documentation, with made-up workflows: two files and one of GitHub's own
(Dependabot), whose path is not a file.

`github/jobs_runners.json` and `github/runners.json` are not captures. They
are written by hand, with made-up runners, in the shape GitHub answered on
2026-10-05 for `gh api repos/<owner>/<name>/actions/runs/<id>/jobs` and
`gh api repos/<owner>/<name>/actions/runners`. The job GitHub ran keeps the
runner name and group a real job of this repository showed that day
("GitHub Actions 1000041223", group "GitHub Actions"). The other jobs ran, or
wait to run, on self-hosted runners in the group "Default"; no real
self-hosted job was at hand to copy, so that group name is GitHub's default
for a new runner, not a capture.

The `collector/` files are not captures. They are written by hand in the
shape Claude Code 2.1.284 and codex-cli 0.155.1 write their session files,
with made-up content, for the tests of what a collector may send to the hub
(`Wallboard.Collector.Filter`). Every word starting with `PLANTED` marks text
that must never leave the collector's machine: a prompt past its clip point,
the model's replies, tool inputs and outputs, file names and contents, and
pasted data.

| File | What it stands for |
|---|---|
| collector/claude_session.jsonl | a Claude session's main transcript |
| collector/claude_subagent.jsonl | one of its helper agents' transcripts |
| collector/codex_rollout.jsonl | a Codex session's rollout file |
