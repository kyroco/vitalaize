# New Ideas

Ideas for VitalAIze after 0.2.0: CI, alerts anywhere, Codex needs-you, cost
per merged pull request and more.

This project moved from Linear (team VIT) to GitHub issues on October 2, 2026.
Each issue keeps its old number in a line at the end of its body, like
`Linear: VIT-61, migrated 2026-10-02`.

## The brief

Ideas for what VitalAIze could add next, gathered after the 0.2.0 release
(Linux support). Each issue says what problem it solves and roughly how big it
is.

Suggested order: CI first, since it protects the project once outside pull
requests arrive and would have caught the Linux connect-script bug found before
0.2.0. Then cost per merged pull request, the most useful new number.

Repo: https://github.com/kyroco/vitalaize

## Milestones, in order

Each one is a GitHub milestone with the same name.

### 1. Close the gaps from 0.2.0

Make what already ships safe and complete before adding new things. Tests run
on every pull request, Codex gets the same "Needs you" and hub upload that
Claude has, alerts reach Linux hubs and Android phones, and people learn when a
new version is out. Mostly improvements, all small.

### 2. What shipped work costs

Replace tokens per 1,000 lines with the numbers people ask for: cost per merged
pull request, the CI minutes each session burns, where the Claude, Codex and
GitHub limits will land, and an alert when a day goes over budget. Cost per
merged pull request comes first because later milestones build on it.

### 3. Keep agents moving

Turn the live board from something you watch into something you act on. Measure
how long agents wait on you, answer them from the iPad, warn when two agents
touch the same files, flag sessions that look stuck, and show what happened
while you were away.

### 4. Team hub and code quality

Make a shared hub useful for a team. Filter every tab by person, measure
quality (rework and code review findings) beside speed, cover the other coding
agents a team uses, and rank people by a score that rewards good work. The
Leader Board comes last: it needs the per-person view, code quality, cost per
merged pull request and response time to exist first.

### 5. Advice from your own sessions

Use the numbers from the earlier milestones to say what to change, not only
what happened. Workflow tips ranked by what they save, which skills and
commands lead to merged work cheaply, whether Korium pays off, and a daily blog
the agents write. These come last because they rest on cost per merged pull
request, response time and CI minutes.

### 6. Windows collector

Let a Windows machine report its Claude Code and Codex work to a hub, as Mac
and Linux collectors do. Collector only: hubs stay on Mac and Linux. Comes
after the streaming collector, since it is that same thin collector built for
Windows: Windows paths, running as a Windows service, an installer, and a
Windows code-signing certificate so Windows doesn't warn on install. First
check that `claude agents --json` and Codex behave the same on Windows.

### 7. Streaming collector

Replace hook scripts that resend whole transcripts with a real collector: a
thin, always-running part of the same VitalAIze codebase that watches its own
machine's Claude Code and Codex sessions and streams only filtered results to
the hub over gRPC with mutual TLS, both ways, on the local network. Pairing by
code through a new admin-only mailbox, configuration in the Mac app and a
`vitalaize setup` terminal command, and calm reconnects. Decided with Robert on
2026-09-30 (Korium thoughts 96a43ff0 and a22676d5; mockups 6 to 8 at
https://claude.ai/artifact/6QZEczqEbtYVgG45bc9TDL). Replaces #64.

### 8. LOWs and NITs

Small findings from reviews, limits we accepted, and things nobody has proven
yet. Nothing here blocks a release on its own. Robert triages: fix or toss.

### 9. Components: anyone can add a tab

Today the board's tabs are fixed in the code: Agents, Git and New Relic.
Someone who does not use New Relic gets a tab of no use, and someone who uses
another tool cannot plug it in. We cannot support every tool, and do not want
to.

A component is a folder with two files: a short description of the tab (its
name, how often to fetch, the settings and secrets it needs) and a small
program, in any language, that fetches the data and prints it in a fixed shape.
The hub finds the folder, adds the tab, asks for its settings in the app, runs
the program on a timer or keeps it running for instant updates, and draws the
result from the board's own parts. The person writing it never touches
VitalAIze's code.

A program, not code loaded into the hub: code inside the hub could reach every
key and take the board down. The hub already gets its data this way from gh,
aws and op.

Components people send in are reviewed and kept in a public library;
`vitalaize component add <name>` installs one at an exact version. A component
that never leaves a company works the same way from a local folder.

Decided with Robert on October 1, 2026. The full sketch, with a Slack channel
worked through, is in the first issue (#91).
