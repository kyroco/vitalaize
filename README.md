# Kyroco VitalAIze

VitalAIze is a wall screen for teams that build software with AI coding
agents. Put it on an iPad (or any browser) and at a glance you see every
Claude Code and Codex session at work, which one is waiting on you, what your
GitHub builds are doing, and how the work trends over days and weeks.

It runs on your own Mac or Linux machine. Your session data is never sent
anywhere except between your own machines, if you connect more than one.

![The Agents tab: Claude and Codex sessions under the status line](docs/images/live.jpg)

## What it shows

Across the top, always in view: a status line for all your repositories, then
tabs. The board turns from tab to tab on its own; tap a tab to pick one, and
tap Pin to stay on it.

- **Status line.** Main, the merge queue, what is running, failures in the
  last day, and your dev and prod deploys. With several repositories it adds
  them up: Main says "5 of 6 green" and names the red one.
- **Agents tab.** One card per Claude Code or Codex session, marked with that
  tool's icon and the repository it works in. Each card says whether the
  session is working (green), idle, or needs you (orange), plus how full its
  context is, its model and effort, lines added and removed, its helper
  agents, and its cost (Claude) or tokens and plan use (Codex).
- **Needs you.** When a Claude session stops to ask you something, a banner
  runs across the screen and its card moves to the top. Your Mac can also
  text you.
- **Git tab.** A column per repository, up to four across: its main, what is
  running, recent runs and a timeline of the last 6 hours. With more than four,
  the busiest get the columns (anything running or failed first, then the most
  recent run), and the rest sit below as one line each until they run or go
  red. Tap a repository for every workflow's recent runs, its merge queue and
  its failures.
- **Archive.** Every session is saved in a small SQLite database on the
  machine that runs the board, so you can look back at any one: what it cost,
  what tools it used, what it changed.
- **Trends.** A chart per measure, one bar per day: spend, tokens, cache hits,
  failed tool calls, lines added, GitHub run times and more. If you use both
  Claude and Codex, a row compares them, starting with how many tokens each
  spends per 1,000 lines of code. Hover over or tap any bar for its value.
- **Korium** (optional). If your agents use [Korium](https://korium.ai), how
  often their memory searches find something, how many saves work, and how
  often code searches hit. See [About Korium](#about-korium).
- **New Relic tab** (optional). Production health checks from New Relic.
- **Light and dark.** Switch with the button next to Settings.

![The Git tab: four busy repositories in columns, two quiet ones below](docs/images/git.jpg)

![The Trends view: Claude and Codex compared, then each tool's own charts](docs/images/trends.jpg)

![The Agents tab in dark mode](docs/images/dark.jpg)

## Install on a Mac

1. Download `VitalAIze-<version>.pkg` from the
   [latest release](https://github.com/kyroco/vitalaize/releases/latest)
   and open it. It is signed and notarized by Apple.
2. The installer says what it will do, then puts VitalAIze in your
   Applications folder and opens it.
3. VitalAIze asks what this Mac does:
   - **Hub and collector**, for your main Mac: it runs the board and saves
     this Mac's sessions.
   - **Hub only**: it runs the board and keeps what other Macs send it.
   - **Collector only**, for your other Macs: it sends this Mac's Claude and
     Codex sessions to a hub. It finds hubs on your network by itself; you
     paste the hub's key from the hub's Settings page (Connect another Mac).
     Codex runs a new hook only once you trust it, so afterwards type
     `/hooks` in Codex and trust the two `wallboard-upload.sh` hooks.
4. It fills in what it can find (your Claude and Codex folders, every GitHub
   repository your sessions work in and their workflows, your AWS profiles) and
   asks you to check it. Click **Install**. The board starts now and again
   every time you log in.
5. On your iPad, open the address VitalAIze shows in Safari, tap Share, then
   **Add to Home Screen**. Opened from the Home Screen, the board fills the
   screen. Turn the iPad sideways, and set Auto-Lock to Never in the iPad's
   Display & Brightness settings so the screen stays on.

Open VitalAIze again any time to see the board, restart it, change the setup
or remove it.

## Install on Linux

1. Download `vitalaize-<version>-linux-x86_64.tar.gz` (Intel and AMD) or
   `vitalaize-<version>-linux-arm64.tar.gz` (ARM) from the
   [latest release](https://github.com/kyroco/vitalaize/releases/latest).
   It carries everything it runs on; you do not need Elixir or Erlang. It
   runs on Ubuntu 22.04 or newer, Debian 12 or newer, and other Linux systems
   of the same age or newer, and needs OpenSSL 3 (`libssl3`), which they
   already have.
2. Unpack it and make your settings file:

   ```
   tar -xzf vitalaize-*-linux-*.tar.gz
   cd vitalaize
   cp settings.example.exs settings.exs     # then edit it
   ```

3. Try it: `WALLBOARD_SETTINGS=$PWD/settings.exs bin/wallboard start`. It
   prints the address to open.
4. To keep it running, and start it whenever you log in:
   `./systemd.sh on` (`./systemd.sh off` turns it off). To keep it running
   after you log out too, run `loginctl enable-linger $USER` once.

What differs from a Mac: there is no setup app, so you edit `settings.exs`;
text alerts by Messages need a Mac, so use Slack, ntfy or Pushover
instead (see Alerts below); and the database lives in
`~/.local/share/vitalaize`. To have other machines find the hub on the
network by themselves, install `avahi-utils` on the hub; without it,
collectors type the hub's address. A Linux machine can be a collector too:
run the command from the hub's Settings page (Connect another Mac) there. It
needs `python3` and `curl`. Like the app, the command hooks up Codex too when
the machine has it, and says to trust the new hooks with `/hooks` in Codex.

## What you need

- A Mac with Apple silicon (M1 or newer), or a Linux machine (see above).
  You do not need Elixir or Erlang to use the installer or the Linux
  download; they carry everything they run on.
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) (the `claude`
  command), signed in.
- The [GitHub CLI](https://cli.github.com) (`gh`), signed in with
  `gh auth login`.
- Optional: [Codex](https://github.com/openai/codex), for Codex sessions.
- Optional: the AWS CLI (`aws`) with read-only profiles, to show whether dev
  is awake and whether prod runs the same build as dev.
- Optional: New Relic and the 1Password CLI (`op`), for the production page.
- Optional, for alerts: the Messages app signed in (Mac only), a Slack
  incoming webhook, the ntfy app, or a Pushover account.

## Build from source

You need Elixir 1.18 or newer and Erlang/OTP, plus a C compiler (Xcode's
command line tools on a Mac) for the SQLite driver.

```
git clone https://github.com/kyroco/vitalaize.git
cd vitalaize
mix deps.get
cp settings.example.exs settings.exs     # then edit it
MIX_ENV=prod mix release
_build/prod/rel/wallboard/bin/wallboard start
```

It prints the address to open, like `Board is up: http://192.168.1.20:4747/`.
To keep it running (it starts when you log in and again if it ever stops),
run `scripts/login-item.sh on` on a Mac or `scripts/systemd.sh on` on Linux;
`off` turns either one off.

Everything specific to you lives in `settings.exs`. The example file explains
each setting. At the least, set `github.repo` and the workflow file names, and
`claude.config_dirs` if your Claude folder is not `~/.claude`. Anything you
leave out uses the default shown in the example file.

To follow several repositories, list them in `github.repos`. The rest of the
`github` section applies to each; an entry can be a map that changes any of it
for one repository, such as its gate workflow or timeline rows. A file with
only `github.repo` keeps working as it always has.

```elixir
github: %{
  gate_workflow: "ci.yml",
  repos: [
    "acme/api",
    %{repo: "acme/mobile", gate_workflow: "build.yml"}
  ]
}
```

To build the Mac app and its installer yourself: `macos/build.sh`. With an
Apple Developer ID it signs them, and with `--notary-profile NAME` it also
notarizes them (see the top of the script).

Run the tests with `mix test`. Before you push, run the same three checks
GitHub runs on Linux and macOS for every pull request, which fail on bad code
style or any compiler warning:

```
mix format --check-formatted
MIX_ENV=test mix compile --warnings-as-errors --force
mix test --warnings-as-errors
```

`mix format` fixes the style for you.

To make a release:

1. Set the version in `mix.exs`, merge it, and push a tag for it from main,
   like `git tag v0.3.0 && git push origin v0.3.0`.
2. GitHub builds both Linux downloads on Ubuntu 22.04 (Intel and ARM), checks
   that each one starts, and puts them on a draft release for that tag.
3. Build the Mac installer on a Mac with `macos/build.sh` (it needs the
   Developer ID), add it with `gh release upload v0.3.0 VitalAIze-0.3.0.pkg`,
   then write the notes and publish the draft.

Push the tag before making the release, so there is only the one draft. A
published release only gets Linux downloads it does not have yet; to replace
one, delete it from the release first.

## Settings you may want

- **Keep it private.** Anyone on the same network can open the board. It is
  read-only and shows no keys, but it does show pull request titles and what
  your sessions ask you. Set `token` in `settings.exs` (or a board password on
  the Settings page); the first visit from each device then needs
  `/?token=<your token>` at the end of the address.
- **Alerts.** Once each time a session starts waiting on you, the board sends
  an alert on every channel you set up, in `alerts` or on the Settings page:
  - Messages (Mac only): set `phone` to your number. The Mac sends an iMessage
    from the Apple ID signed in there. The first time, macOS asks whether the
    board may control Messages. If the number is not on iMessage, set `via`
    to `"SMS"` (needs Text Message Forwarding on your iPhone).
  - Slack: make an incoming webhook for a channel and set `slack_webhook` to
    its address.
  - ntfy (free, iPhone or Android): pick a topic name that is hard to guess,
    subscribe to it in the ntfy app, and set `ntfy_topic`. Set `ntfy_server`
    if you run your own.
  - Pushover: set `pushover_user` to your user key, and `pushover_token` to
    the API token of an app you make at pushover.net.

  Alerts cover the Claude sessions on the machine that runs the board and on
  every machine that sends it sessions, and the board machine's Codex
  sessions once the Codex hook below is set up. A connected machine tells
  the hub the moment one of its Claude sessions starts waiting (a
  permission prompt, a question, or a form from an MCP server), and the
  session shows as needing you on the hub's board, marked with that
  machine's name, until it moves on. To notice a prompt approved, denied
  or closed with Esc, that machine checks `claude agents` every few seconds
  while a session waits, so `claude` and `perl` need to be on its PATH;
  without them the card clears at the session's next step instead. If the
  hub cannot be reached, the session carries on as usual. A machine
  connected by version 0.2.0 or earlier needs connecting once more
  (Connect another Mac on the hub's Settings page) to add these hooks.
  Codex sessions on other machines do not alert yet.
- **Codex.** On by default, reading `~/.codex/sessions`. Codex runs on a plan
  rather than per-token prices, so its cards show tokens and plan use. Set
  `codex: %{enabled: false}` to leave it out.
- **Codex needing you.** Codex writes nothing to its session file while it
  waits on you, so VitalAIze needs a small Codex hook to know. The board
  keeps it at `~/.codex/vitalaize/hook.sh`. Add these entries to
  `~/.codex/hooks.json`, next to any hooks you already have there:

  ```json
  {
    "hooks": {
      "PermissionRequest": [{"hooks": [{"type": "command", "command": "sh ~/.codex/vitalaize/hook.sh", "timeout": 5}]}],
      "PostToolUse": [{"hooks": [{"type": "command", "command": "sh ~/.codex/vitalaize/hook.sh", "timeout": 5}]}],
      "UserPromptSubmit": [{"hooks": [{"type": "command", "command": "sh ~/.codex/vitalaize/hook.sh", "timeout": 5}]}],
      "Stop": [{"hooks": [{"type": "command", "command": "sh ~/.codex/vitalaize/hook.sh", "timeout": 5}]}],
      "SubagentStop": [{"hooks": [{"type": "command", "command": "sh ~/.codex/vitalaize/hook.sh", "timeout": 5}]}],
      "Interrupt": [{"hooks": [{"type": "command", "command": "sh ~/.codex/vitalaize/hook.sh", "timeout": 5}]}],
      "SessionEnd": [{"hooks": [{"type": "command", "command": "sh ~/.codex/vitalaize/hook.sh", "timeout": 5}]}]
    }
  }
  ```

  Then open Codex, type `/hooks` and trust them: Codex skips a new or
  changed hook until you do. A Codex card then shows **Needs you** (and
  sends an alert, if alerts are on) when Codex asks to run something, or when
  a turn ends on a question, meaning the last paragraph of its reply ends in
  a question mark. It clears when Codex moves on or you reply. The card names
  only the program Codex wants to run, never the whole command, since that
  can hold a password. Codex tells nothing when a command you approved
  starts, so the card keeps saying Needs you until that command finishes.
  And if Codex runs other commands at the same time as the one waiting on
  you, the first of those to finish clears the card although Codex still
  waits.
  A card waiting on your approval stays up to 12 hours, even past the idle
  time. The hook keeps only the latest thing Codex sent it for each session
  and each helper agent, in `~/.codex/vitalaize`, and the board removes those
  after a week.

  This is new and has not yet been seen working with a real Codex, so it may
  mark a card wrongly or send a wrong alert. To help check it, turn on
  recording with `touch ~/.codex/vitalaize/capture-on`. Every call Codex
  makes to the hook is then added to `~/.codex/vitalaize/payloads.jsonl`.
  Use Codex as usual (a run where it asks for your approval is the most
  useful), then `rm ~/.codex/vitalaize/capture-on` and send that file to the
  VitalAIze team. It holds what you typed and what Codex ran, so read it
  first and leave out anything private.
- **New Relic tab.** Set `new_relic: %{enabled: false}` if you do not use
  New Relic. Otherwise set `api_key_ref` to where your New Relic User API key
  lives in 1Password (`"op://Vault/Item/field"`), `account_id`, and the
  `checks` to show. The key is read once at start and kept in memory only.
- **Dev awake or asleep.** If your dev environment sleeps at night, set
  `dev_power.aws_profile`, `database` and `cluster`, and the Dev tile shows
  Awake, Asleep, Waking or Going to sleep.
- **Prod builds.** Set `builds.prod_profile` and the ECR repository and ECS
  services, and the Prod tile says whether prod runs the same build as dev.
- **Costs.** Claude costs use the API list prices in `usage.prices`. On a
  Claude plan your bill is different; read the dollars as a measure of work.
- **Your look.** The `theme` section holds every color and font, and `brand`
  holds the name and logo in the header.

## About Korium

[Korium](https://korium.ai) is another Kyroco project: shared company memory
for people and AI agents. It keeps your team's decisions, with the reasons and
sources behind them, so an agent can look up what the team already learned
before it starts. It also gives agents code search tied to specific commits,
reusable skills and workflows, and a Mac command line tool that indexes code
locally. It works with Claude, OpenAI, Gemini and other assistants.

VitalAIze does not need Korium. When your sessions use it, the Trends tab
shows a Korium section: memory searches that found something, saves that
worked, and code searches that hit. Set `korium: %{enabled: false}` to hide
it. Learn more at [korium.ai](https://korium.ai).

## How it keeps up

Each source has its own timer: sessions every few seconds, GitHub every 30
seconds (about 600 calls an hour per repository, so six stay inside GitHub's
limit of 5,000), New Relic every minute. Only what changed
is sent to the screen. If one source fails, its panel keeps its last good
data, says how old it is and why, and the rest of the board carries on. Trends
say "Loading…" beside a section while its history is still coming in.

## If something is off

- **The iPad cannot reach the board.** Check that both are on the same Wi-Fi,
  and that the firewall allows incoming connections on the board's port
  (4747 unless you changed it): on a Mac in System Settings, Network,
  Firewall; on Linux with ufw, `sudo ufw allow 4747/tcp`.
- **"Add ?token= ..." on the page.** You set a `token`, and the address is
  missing it or has a different one.
- **A panel shows "stale" in red.** It says why. Usually `gh` or `claude` is
  signed out, or the Mac lost its connection.
- **No alerts.** The board's log says which channel failed and why. For
  Messages, check `alerts.phone`, that Messages is signed in, and that macOS
  allowed the board to control Messages (System Settings, Privacy & Security,
  Automation). For Slack, ntfy or Pushover, check the address, topic or keys,
  and that the board's machine can reach the internet.

## License

Apache License 2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).

Claude is a trademark of Anthropic, and Codex of OpenAI. VitalAIze is not
made by or affiliated with either; it shows their icons only to mark which
tool ran a session.
