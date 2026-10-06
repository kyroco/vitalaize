# Kyroco VitalAIze

VitalAIze is a wall screen for teams that build software with AI coding
agents. Put it on an iPad (or any browser) and at a glance you see every
Claude Code and Codex session at work, on the machine that runs it and on
your other machines, which one is waiting on you, what your GitHub builds are
doing across all your repositories, and how the work trends over days and
weeks. When a session needs you, it can tell you by Messages, Slack, ntfy or
Pushover. It runs on your own Mac or Linux machine, and needs Claude Code
and the GitHub CLI (`gh`), both signed in; Codex is optional.

![The Agents tab: Claude and Codex sessions under the status line](docs/images/live.jpg)

The [wiki](https://github.com/kyroco/vitalaize/wiki) covers everything else:
what each part of the board shows, settings and alerts, connecting other
machines, known limits, building from source and how it works.

## What's new in 0.3.0

- **Several repositories**, added up in the status line. The Git tab gives
  the four busiest a column each and lists the rest below.
- **Alerts anywhere**: Slack, ntfy (iPhone or Android) and Pushover, besides
  Messages on a Mac.
- **Your other machines, live**: a small collector on each one watches its
  own Claude and Codex sessions and streams them to the hub over an encrypted
  connection. Their sessions get cards on the board as they work, show Needs
  you, and send your alerts. It sends numbers and a few short lines (a
  session's title, its folder and branch, and the start of your prompts),
  never the agent's replies, the commands it ran or your files; the
  [wiki](https://github.com/kyroco/vitalaize/wiki/How-it-works) lists what
  crosses the network. A collector built after 0.3.0 also sends the name
  and state of any GitHub runner on its machine, and nothing more about it
  (see "Your own CI machines" below).
- **Connect a machine by code**: the new machine shows a six-digit code, and
  you approve the same code in the mailbox on the hub's board. There is no
  key to copy. At most you type the hub's address.
- **Settings in the app**, or with `vitalaize setup` in a terminal. Most
  changes are in use within seconds, with no restart.
- **Codex**: Codex sessions can show Needs you (new, and not yet tried with
  a real Codex).
- **A note when a new version is out**, which you can turn off in Settings.

If you run 0.2.0 on Linux, upgrade. Every copy of that download had the same
built-in secret for remote control, so if you started the board by hand
(not with `systemd.sh`), anyone on your network who also had the download
could run commands on your machine. 0.3.0 turns remote control off.

A machine connected by 0.2.0 or earlier sent its sessions with upload hooks.
0.3.0 replaces those with the collector, and the hub no longer takes uploads:
it refuses them, so such a machine's sessions stop arriving until it is moved
across. On each of those machines, install 0.3.0 and set it up as a collector (the
app on a Mac, `bin/vitalaize setup` on Linux). Setup takes VitalAIze's old
hooks out of that machine's Claude and Codex settings, leaves every other
hook as it was, and keeps a copy of each file it changes beside it
(`settings.json.before-collector`). Sessions the hub saved before stay in
the archive and trends.

## Install on a Mac

1. Download `VitalAIze-<version>.pkg` from the
   [latest release](https://github.com/kyroco/vitalaize/releases/latest)
   and open it. It is signed and notarized by Apple. If an Installer
   window from an earlier install is still open on its last page, close it
   first: otherwise the new package only brings that window forward and
   installs nothing.
2. The installer says what it will do, then puts VitalAIze in your
   Applications folder and opens it.
3. VitalAIze asks what this Mac does:
   - **Hub and collector**, for your main Mac: it runs the board and saves
     this Mac's sessions.
   - **Hub only**: it runs the board and keeps what other Macs send it.
   - **Collector only**, for your other Macs: a small collector watches
     this Mac's Claude and Codex sessions and streams them to a hub as they
     happen. It finds hubs on your network by itself. No key is typed or
     pasted: this Mac shows a short code, and you approve the same code in
     the mailbox on the hub's board (the envelope by the clock). The hub
     must take collectors: turn on **Take collectors**, under Collectors on other machines, in the
     hub's settings first.
4. On a hub, it fills in what it can find (your Claude and Codex folders,
   the GitHub repositories your sessions work in, up to six, busiest first,
   the busiest one's workflows, your AWS profiles) and asks you to check it.
   Add or remove repositories there. Click **Install and start the board**.
   The board starts now and again every time you log in. On a collector,
   click **Start the collector and pair** instead; steps 5 and 6 are for
   the hub.
5. On your iPad, open the address VitalAIze shows in Safari, tap Share, then
   **Add to Home Screen**. Opened from the Home Screen, the board fills the
   screen. Turn the iPad sideways, and set Auto-Lock to Never in the iPad's
   Display & Brightness settings so the screen stays on.
6. Choose how alerts reach you. Setup asks only for a phone number, for
   Messages. For Slack, ntfy or Pushover, open VitalAIze, click
   **Settings** and fill in the Alerts section. You can change the
   repositories there too.

Open VitalAIze again any time to see the board, restart it, change its
settings or remove it. **Settings** in the app shows every setting and saves
it there, with no browser. Most changes take effect within a few seconds; a
few (the ports, the board password, what this Mac does) restart the board,
and only then. The board's own Settings page shows the settings and can no
longer change them.

## Install on Linux

1. Download `vitalaize-<version>-linux-x86_64.tar.gz` (Intel and AMD) or
   `vitalaize-<version>-linux-arm64.tar.gz` (ARM) from the
   [latest release](https://github.com/kyroco/vitalaize/releases/latest).
   It carries everything it runs on; you do not need Elixir or Erlang. It
   runs on Ubuntu 22.04 or newer, Debian 12 or newer, and other Linux systems
   of the same age or newer, and needs OpenSSL 3 (`libssl3`), which they
   already have.
2. Unpack it and set it up:

   ```
   tar -xzf vitalaize-*-linux-*.tar.gz
   cd vitalaize
   bin/vitalaize setup
   ```

   `vitalaize setup` asks what this machine does (the board, a collector,
   or both) and the settings that go with it. Enter keeps a value. It saves
   your answers in `settings.json` in that folder, pairs a collector with
   its hub by code, and offers to keep VitalAIze running as a systemd
   service.
3. If you did not take the service: `bin/wallboard start` runs it, and
   prints the address to open.
4. To keep it running later, and start it whenever you log in:
   `./systemd.sh on` (`./systemd.sh off` turns it off). To keep it running
   after you log out too, run `loginctl enable-linger $USER` once.

Run `bin/vitalaize setup` again any time to change a setting. It restarts
VitalAIze only when a change needs it. The same command works on a Mac, in a
terminal, and it and the Mac app save to the same file, so either can change
what the other saved.

What differs from a Mac: there is no setup app, so `vitalaize setup` is how
you change settings. The board's Settings page shows them and cannot change
them. If you would sooner write a file, copy `settings.example.exs` to
`settings.exs` and edit it: it still works, and what `vitalaize setup` saves
goes on top of it. List your repositories under GitHub.
Text alerts by Messages need a Mac, so use Slack, ntfy or Pushover instead.
The database lives in `~/.local/share/vitalaize`. Many Linux machines have
no keychain, so a New Relic API key typed in `vitalaize setup` is kept in
`keys/new_relic` beside the database (`~/.local/share/vitalaize/keys/new_relic`
unless you moved the database), a file only your user can read, and never in
`settings.json`. On a Mac it is kept in your login keychain.
Either way, `vitalaize setup` shows it only as "set", and the board takes
up a new key with no restart. To have other machines
find the hub on the network by themselves, install `avahi-utils` on the hub;
without it, collectors type the hub's address.

A Linux machine can be a collector too: unpack the download on it, run
`bin/vitalaize setup` and answer `collector`. It finds the hub on your
network or takes its address, and shows a short code; approve the same code
in the mailbox on the hub's board. No key is copied.

To take VitalAIze off a Linux machine, run `bin/vitalaize remove`. It stops
VitalAIze, takes it out of what starts at login, deletes the machine's
certificate for its hub and takes out any upload hooks an earlier version
added. On a Mac, **Remove VitalAIze** in the app does the same.

A collector streams to its hub over an encrypted connection, and only a
machine you approved in the mailbox can send. See the known limits in the
[wiki](https://github.com/kyroco/vitalaize/wiki).

To try a hub and a collector on two machines step by step, with what you
should see at each step, follow the [test guide](docs/test-guide.md).

## Your own CI machines

If some of your GitHub Actions jobs run on your own machines (self-hosted
runners), the Git tab says so: a run your machines worked on reads "on" and
the runner's name. A job counts as yours when it carries the `self-hosted`
label (in any letter case, as GitHub reads it) or its runner is in GitHub's
list of the repository's runners; any other job outside GitHub's own runner
group, such as one on GitHub's paid larger runners, is counted apart as not
known.

GitHub always bills its larger runners, on public repositories too. CI
minutes count its macOS larger runners (`macos-15-large`,
`macos-latest-xlarge`) as paid everywhere. A Linux or Windows larger
runner sits in a runner group its owner named, as does a machine of your
own without the `self-hosted` label, and nothing in the job tells the two
apart: on a private repository such a job counts as paid, and on a public
one it is shown apart as not known. GitHub also prices larger runners by
size, which the board cannot see, so they count as a standard runner of
the same system would (macOS 10, Windows 2, Linux 1), a floor.

A repository's panel lists its runners that GitHub or a collector reports,
each online, busy or offline, with the job it is running. Runners that ran
the repository's jobs in the last day but that nothing reports, such as
runners made for a single job and gone since, are counted on one line with
the reason, and the column's runner count leaves them out.

Trends splits runner time into GitHub's and your own, and counts the paid
minutes your machines avoided: GitHub bills each job in whole minutes,
rounded up, and does not bill your own runners. Minutes on a public
repository are left out, since GitHub's standard runners are free there.
The board does not know your plan, so minutes inside your plan's allowance
are counted too, though GitHub would not have charged them.

A runner's state comes from GitHub when the board's GitHub login has admin
rights on the repository. Otherwise a collector on the runner's machine
reports it, for a runner that ran the repository's jobs in the last day:
only the runner's name and its state cross the network, never its folder,
its jobs or its logs. The collector finds the runner in the
machine's list of running programs and reads its name from the `.runner`
file in the runner's folder, so it can report a runner only when its user
may read that file. A runner set up under a user of its own, with a folder
other users cannot open, is left out, and the collector's log says so
once. When neither GitHub nor a collector can tell, the board says the
state is not known, and why; that is also what it says once the collector
disconnects.

VitalAIze only shows runners. It does not install, start or change one.
GitHub's own advice applies: self-hosted runners "should almost never be used
for public repositories", because anyone who opens a pull request could run
code on your machine.

## Questions and ideas

Read the [wiki](https://github.com/kyroco/vitalaize/wiki) first. Ask for
help in
[Q&A](https://github.com/kyroco/vitalaize/discussions/categories/q-a) and
suggest features in
[Ideas](https://github.com/kyroco/vitalaize/discussions/categories/ideas),
both in [Discussions](https://github.com/kyroco/vitalaize/discussions).
Report bugs in [Issues](https://github.com/kyroco/vitalaize/issues).

## License

Apache License 2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).

Claude is a trademark of Anthropic, and Codex of OpenAI. VitalAIze is not
made by or affiliated with either; it shows their icons only to mark which
tool ran a session.
