# Wallboard settings. Copy this file to settings.exs and change what you need.
# Anything you delete falls back to the default shown here.
#
# You do not need this file: the Mac app and `bin/vitalaize setup` ask for
# the common settings and save them in settings.json beside it. What they
# save wins over this file, so set a value in one place or the other.
#
# This is one Elixir map. Text goes in "double quotes", lists in [square
# brackets], and every line inside the map ends with a comma.

%{
  # What this machine does:
  #   "both"       runs the board and saves this machine's own sessions
  #   "hub"        runs the board and saves only what other machines send
  #   "collector"  runs no board and opens no port: it only watches this
  #                machine's Claude and Codex sessions for a hub
  role: "both",

  # Only for the collector role. It finds ~/.claude, every ~/.claude-something
  # and ~/.codex by itself; list folders here only to watch others instead.
  collector: %{
    claude_dirs: nil,
    codex_dirs: nil,
    # Where it keeps its place and the events not sent yet. nil: a
    # "collector" folder beside the database's usual place (see archive).
    # Pairing with a hub leaves this machine's certificate and the hub's
    # address here too; the collector sends once they are there.
    dir: nil,
    # The most the unsent events may take on disk, in megabytes.
    outbox_mb: 64,
    # On the first start, report sessions that changed in this many days.
    backfill_days: 14
  },

  # The web address is http://<this Mac's address>:<port>/
  port: 4747,

  # Optional. With no token, anyone on the same network can open the board.
  # Set one (for example the output of: openssl rand -hex 16) and the first
  # visit from each device needs /?token=<token> at the end of the address.
  # Worth setting if you take your Mac to cafes or hotels with the board on.
  token: nil,

  # Seconds before the board flips to the other page. 0 turns rotation off.
  rotate_seconds: 30,

  # Time zone for every time on the board.
  timezone: "America/New_York",

  # Your name and logo in the header. logo is a path to an .svg or .png file.
  # With no logo, the name is shown as text.
  brand: %{
    name: "Kyroco",
    logo: nil,
    page2_title: "Production health · New Relic"
  },

  # Claude Code sessions. List every Claude config folder you use; each one
  # is checked with `claude agents --json`. With more than one, each session
  # shows which account it belongs to.
  claude: %{
    config_dirs: ["~/.claude"],
    poll_seconds: 5,
    # A working session gets a ringed, darker dot after this many minutes.
    long_running_minutes: 45
  },

  # Token use and cost, read from Claude Code's transcripts in each config
  # folder above. Costs use API list prices, set per model under prices; add
  # or change one like this (dollars per million tokens, context in tokens):
  #   prices: %{"claude-opus-5-5" => %{label: "Opus 5.5", input: 4.0, output: 20.0, cache_read: 0.20, context: 1_000_000}}
  usage: %{
    poll_seconds: 30,
    days_back: 21
  },

  # Once a day the board asks GitHub for the latest VitalAIze release and,
  # when it is newer, shows a note by Settings. false stops the check.
  updates: %{check: true},

  # Alerts. When a Claude session starts waiting on you, every channel set up
  # here gets one alert. Leave them all nil and alerts are off.
  alerts: %{
    # Messages (Mac only): this Mac sends an iMessage from the Apple ID signed
    # in to its Messages app, to this number.
    phone: nil,
    # "iMessage", or "SMS" for a plain text sent through your iPhone. SMS
    # reaches numbers that are not on iMessage, such as Google Voice, and
    # needs Text Message Forwarding on (iPhone Settings, Messages).
    via: "iMessage",
    # Slack: an incoming webhook address, https://hooks.slack.com/services/...
    slack_webhook: nil,
    # ntfy (free, any phone): a topic name, subscribed to in the ntfy app.
    # Anyone who knows the topic can read it, so make it hard to guess.
    # ntfy_server nil means https://ntfy.sh.
    ntfy_topic: nil,
    ntfy_server: nil,
    # Pushover: your user key, and the API token of an app you make at
    # pushover.net. Both are needed.
    pushover_user: nil,
    pushover_token: nil
  },

  # GitHub, read through the `gh` command, which must be signed in
  # (gh auth login).
  github: %{
    # Several repositories: list them here. The workflow files named below
    # (the gate, the deploys and the timeline rows) are the first one's. An
    # entry can be a map that names another repository's own, or changes
    # anything else in this section for it, for example
    #   repos: ["acme/api", %{repo: "acme/mobile", gate_workflow: "build.yml"}]
    # A repository that names no gate workflow gets main's state from the
    # latest runs on its main branch. The Git tab gives up to four a column
    # each; Dev and Prod follow the first. Left empty, the board follows
    # `repo` alone.
    repos: [],
    repo: "your-org/your-repo",
    branch: "main",
    poll_seconds: 30,
    deploy_poll_seconds: 120,
    # The workflow file that gates merges, and the check name on pull requests.
    gate_workflow: "ci.yml",
    gate_check: "ci",
    # Which workflow files are your dev and prod deploys.
    dev_deploy: "deploy-staging.yml",
    prod_deploy: "deploy-production.yml",
    # Deploy workflows to track even when their last run is days old.
    deploy_workflows: ["deploy-staging.yml", "deploy-production.yml"],
    # Rows of the "last 6 hours" timeline, each with its workflow files.
    # A row shows when one of its workflows ran in those hours; any other
    # workflow that ran gets a row under its own name, after these.
    lanes: [
      %{label: "CI", workflows: ["ci.yml"]},
      %{label: "Staging", workflows: ["deploy-staging.yml"]},
      %{label: "Production", workflows: ["deploy-production.yml"]}
    ]
  },

  # Whether dev is awake or asleep, read from AWS through the `aws` command.
  # Off until you name a read-only AWS profile; then the Dev tile shows
  # Awake, Asleep, Waking or Going to sleep instead of the last deploy.
  dev_power: %{
    # The AWS profile to read with, from ~/.aws/config. nil turns this off.
    aws_profile: nil,
    # nil uses the profile's own region.
    region: nil,
    # Dev's database and its ECS cluster.
    database: nil,
    cluster: nil,
    poll_seconds: 60
  },

  # Keeps every Claude session in a database on this Mac, so the Archive tab
  # can show sessions after they end or their transcripts are deleted. A
  # session is saved once it has been quiet for settle_seconds; the first
  # start saves the last backfill_days.
  archive: %{
    enabled: true,
    # nil: ~/Library/Application Support/Wallboard on a Mac,
    # ~/.local/share/vitalaize on Linux.
    path: nil,
    # This Mac's name in the database. nil uses its network name.
    machine: nil,
    backfill_days: 14,
    settle_seconds: 120,
    poll_seconds: 60,
    # GitHub runs and jobs are saved too, every 5 minutes. Each run's jobs
    # take one call, so at most this many runs get theirs per round.
    github_poll_seconds: 300,
    github_jobs_per_round: 100
  },

  # The link: collectors on other machines stream their sessions to this
  # hub, encrypted, and only machines this hub has approved may connect.
  # Off until you turn it on. It listens on its own port, not the board's,
  # and needs the archive above. Its certificates are kept in a "link"
  # folder beside the database. A new machine asks to connect and shows a
  # short code; you approve the same code in the mailbox (the envelope by
  # the board's clock). Settings lists the machines and can disconnect one.
  link: %{
    enabled: false,
    port: 4748
  },

  # Whether prod runs the same build as dev, read from AWS. Off until you name
  # a read-only AWS profile for prod; then the Prod tile says Current when
  # both run the same images and Behind when dev has a different one. The
  # reads only look at settings, so they never wake a sleeping dev.
  builds: %{
    # AWS profiles from ~/.aws/config. dev_profile nil uses dev_power's.
    prod_profile: nil,
    dev_profile: nil,
    region: "us-east-1",
    # The ECR repository both environments' images come from.
    repository: nil,
    dev: %{cluster: nil, services: []},
    prod: %{cluster: nil, services: []},
    poll_seconds: 60
  },

  # New Relic, read through its NerdGraph API. It is page 2 of the board.
  new_relic: %{
    # false removes page 2: the board stays on page 1 and never asks
    # 1Password or New Relic for anything.
    enabled: true,
    # Where the User API key (it starts with NRAK-) lives in 1Password. The
    # board runs `op read` with this once at startup and keeps the key in
    # memory only. Example: "op://Private/New Relic/credential"
    api_key_ref: nil,
    # Your New Relic account number.
    account_id: nil,
    # "us" or "eu"
    region: "us",
    poll_seconds: 60,
    # The first monitor check is the big one on page 2. The rest fill the
    # "More checks" row. Two kinds:
    #   %{name: "Heartbeat", monitor: "Name of the synthetic monitor"}
    #   %{name: "Errors today", nrql: "SELECT count(*) FROM TransactionError SINCE today", unit: ""}
    checks: [],
    # How many spaces the "More checks" row has, filled or empty.
    slots: 3
  },

  # The look. These are the Kyroco colors and fonts; change them to make the
  # board yours. Colors are CSS colors. Font files live in fonts_dir (nil
  # means the fonts that come with the board).
  theme: %{
    page: "#f1efed",
    surface: "#ffffff",
    text: "#1f1a17",
    text_body: "#6a625c",
    text_muted: "#746a61",
    border: "#e7e2dd",
    border_strong: "#d2cdc8",
    track: "#efe9e4",
    accent: "#e44456",
    alert: "#c13340",
    info: "#2e6b7c",
    info_light: "#7bb4c4",
    ok: "#16a34a",
    warn: "#f59e0b",
    warn_deep: "#b45309",
    radius: "4px",
    font_body: "system-ui, -apple-system, sans-serif",
    font_display: "'Playfair Display', Georgia, serif",
    font_css_url:
      "https://fonts.googleapis.com/css2?family=Playfair+Display:wght@400;500&display=swap",
    fonts_dir: nil,
    font_faces: []
  }
}
