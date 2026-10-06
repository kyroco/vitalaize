# Test guide: a hub and a collector on two machines

This is the walk through the streaming collector on real machines: install the
hub, install a collector on a second machine, pair them by code, watch a session
appear, and disconnect. Each step says what you should see, and where to look
when you do not.

These steps were run once on October 1, 2026, on one Mac, with a throwaway hub
and a throwaway collector built from main: the terminal path of steps 1 to 8,
31 checks, all passed. Two real machines on a real network, the Mac app's
screens on a second Mac, and a real Claude or Codex session were not part of
that run. That is what this guide is for.

It takes about 30 minutes. You need:

- **The hub Mac**, with Claude Code and `gh`, both signed in.
- **A second machine** on the same network, with Claude Code or Codex: another
  Mac, or a Linux machine.
- **A build of main.** On the Mac that has the signing certificates, run
  `macos/build.sh`. The package is `macos/dist/VitalAIze-0.3.0.pkg`. For a
  Linux collector, see step 3b.

Two names used below: the **board log** is `~/Library/Logs/VitalAIze/board.log`
on a Mac (the app's **Show the log** opens it). On Linux it is
`journalctl --user -u vitalaize -f` when VitalAIze runs as a service, or the
terminal you started it in. A collector writes to the same log as a board.

## 1. Install the hub

1. Close any Installer window left open from an earlier install. While one sits
   on its last page, opening a new package only brings that old window forward
   and installs nothing.
2. Open `VitalAIze-0.3.0.pkg` and go through its pages. VitalAIze opens.
3. On a Mac that already had VitalAIze (0.2.0, or an older install), the first
   screen says what it mended or restarted. It keeps a copy of every file it
   changed in `backups/(date and time)/` in the data folder
   (`~/Library/Application Support/VitalAIze`).
4. On a new Mac, pick **Hub and collector**, check what it found, and click
   **Install and start the board**.

**You should see:** "The board is running at http://localhost:4747". Click
**Open the board**: the board opens with this Mac's own sessions on the Agents
tab.

**If not:** the screen says why. When the setup itself stops, its button is
**Open the log**; on the first screen it is **Show the log**. Both open the
board log. "Port 4747 is already used by another program" means an older board is
still running: stop it, or pick another port on the setup's fourth step.

## 2. Let the hub take collectors

A hub refuses collectors until you turn this on.

1. In the VitalAIze app, click **Settings**.
2. Under **Collectors on other machines**, turn on **Take collectors**, and
   click **Save**.

**You should see:** the board restarts, and the app says it is answering again.
On the board, open **Settings**: there is now a **Connected machines** list,
with this Mac as the first row, marked "(this hub)".

**If not:** if the hub has a firewall, allow incoming connections on ports
4747 (the board, and the first step of pairing) and 4748 (the stream).

## 3a. Install the collector on a second Mac

1. Open the same package on the second Mac. VitalAIze opens.
2. Pick **Collector only**, then **Continue**.
3. Check the Claude folders it found, then **Continue**.
4. On **Your hub**, pick the hub from "Hubs on your network". If the list
   stays empty, type the hub's address, like `http://192.168.1.20:4747`. Then
   **Continue**.
5. On the last step, the review, click **Start the collector and pair**.

**You should see:** a six-digit code in large type, like `482-913`, and
"Waiting for the hub to approve…". Go to step 4.

**If not:**

| The app says | What it means |
| -- | -- |
| "Could not pair: nothing answers at …" | Wrong address, the hub's board is not running, or a firewall blocks port 4747 on the hub. |
| "That board does not take collectors." | Step 2 was not done on the hub. |
| The hub is not in the list | The network blocks the hub's announcements. Type its address. |

## 3b. Install the collector on a Linux machine

There is no Linux download of main until a release is tagged, so build it on
the Linux machine. It needs Elixir 1.18 or newer and a C compiler.

```
git clone https://github.com/kyroco/vitalaize.git
cd vitalaize
mix deps.get --only prod
MIX_ENV=prod mix release
cd _build/prod/rel/wallboard
bin/vitalaize setup
```

Answer `collector` to "What this machine does". Press Enter at the two folder
questions to let it find them. At "The hub's address", type the hub's address,
like `192.168.1.20`. Pressing Enter instead looks for a hub on the network,
which on Linux only works with `avahi-utils` installed on this machine.

**You should see:** a code, then "Open the mailbox on <the hub's name>'s board
and approve this code." and "Waiting for the hub to approve...". Go to step 4.

**If not:** "No hub found on this network." means this machine has no
`avahi-utils`, or the hub's announcements do not reach it. Run
`bin/vitalaize setup` again and type the address.

## 4. Approve the code in the mailbox

On the hub Mac itself (not on the iPad, unless the board has a password):

1. Open the board. The envelope by the clock now shows a 1. Tap it.
2. The mailbox holds "A new machine wants to connect", with the second
   machine's name and a code.
3. Check that the code is the one the second machine shows. Tap **Approve**.

**You should see:** on the second Mac, the code goes and the app's first screen
says "Connected to the hub at … as …". On Linux, setup prints "Approved. This
machine is connected as …". The mailbox is empty again.

**On Linux, one more question.** Only now does setup ask "Set it up as a
systemd user service and start it now?". Say yes, or start the collector
yourself with `bin/wallboard start`. Until one of those, the collector is not
running and the "connected" lines below do not appear.

**In the hub's log,** in this order:

```
Pairing: <name> asks to connect, code 482-913.
Pairing: <name> was approved.
Pairing: <name> has its certificate.
Link: <name> connected.
```

**In the collector's log:**

```
Collector: sending to the hub at "<address>", port 4748.
```

**If not:**

| What you see | What it means |
| -- | -- |
| The Approve button is greyed out | You are not on the hub's own machine, and the board has no password. Open `http://localhost:4747/` on the hub Mac. |
| No item in the mailbox, but the machine shows a code | The machine is talking to something that is not this hub. Stop, and give it this hub's address. |
| "Nobody approved the code in time." | The code ran out after 10 minutes. Pair again for a new one. |
| The hub's log has "was approved" but never "connected" | The stream cannot reach port 4748 on the hub. Check the hub's firewall. The collector's log says "Link: no connection to the hub (…). Trying again in … ms." |

## 5. See a session appear

1. On the second machine, start Claude Code in any folder and give it a prompt.
2. Watch the hub's board, on the Agents tab.

**You should see:** within a few seconds, a card for that session, with a pill
carrying the second machine's name, saying Working. When the session stops to
ask permission, the card turns to Needs you, the banner runs across the top,
and about 5 seconds later your alert arrives, named "<session> on <machine>".
Answer it on the second machine and the card goes back to Working.

Also check **Settings**, **Connected machines** on the board: the second
machine's row says "Seen now" and a number of sessions. On its first start a
collector reports its sessions from the last 14 days, so for the first 10
minutes that number can be much more than 1.

**If not:** in the collector's log, look for "Collector is up. Watching …". It
names the folders it watches. If your Claude folder is not there, add it:
**Settings** in the app, or `bin/vitalaize setup` on Linux.

## 6. Take the collector off the network and bring it back

1. Turn Wi-Fi off on the second machine and wait two minutes. The hub gives
   a silent machine 90 seconds before it calls the link closed.
2. On the hub's board, its card stays, with a dashed border and a red note:
   "stale: no word from <machine> since …".
3. Turn Wi-Fi back on.

**You should see:** within a minute the note goes and the card is live again.
Anything the session did meanwhile shows up: the collector kept it on disk.

## 7. Disconnect

1. On the hub's board, open **Settings**, **Connected machines**.
2. On the second machine's row, tap **Disconnect**, then **Tap again** within
   8 seconds.

**You should see:** "<machine> is disconnected. To connect it again, pair it
again." The hub's log says "Link: <machine> was removed." The collector's log
says "Collector: the hub removed this machine. Nothing more is sent." Its cards
on the board turn stale.

A machine disconnected while it is off is told too. Pair it again (below),
turn its Wi-Fi off, and disconnect it the same way: its row stays in the list
while it is away. Turn its Wi-Fi back on.

**You should see:** the collector's log says "Link: the hub says it removed this
machine while it was away. It will not connect again.", and the app shows the
machine as removed, not as down. It asks the hub on every third failed try, and
tries grow to a minute apart while it is away, so after a long time off this can
take up to about three minutes. The hub tells each collector the board's port
every time it connects, so a collector asks in the right place even after the
board's port was changed in Settings. A collector that has not connected since
the board moved asks on the port it last knew (4747 if an older VitalAIze
paired it); if it was removed meanwhile, it stays on down until it is paired
again.

To connect it again: **Pair again…** in the app. On Linux, run
`bin/vitalaize setup` and, at "A hub's address to pair again, or Enter to keep
this", type the hub's address. Enter alone keeps the pairing the hub just took
away, and shows no code. Then approve the new code.

## 8. A machine that was connected by 0.2.0

Skip this if no machine of yours ran 0.2.0's Connect command.

A machine connected the old way still has upload hooks in its Claude and Codex
settings. The 0.3.0 hub refuses their uploads with "This hub no longer takes
uploads from the old collector (VitalAIze 0.2.0)."

Install 0.3.0 on that machine as a collector (step 3a or 3b). Setup takes
VitalAIze's old hooks out and deletes the old upload script.

**You should see:** in `~/.claude/settings.json`, no entry that runs
`wallboard-upload.sh` any more, and every other hook as it was. Beside it is
`settings.json.before-collector`, the file as it was before. The same goes for
`~/.codex/hooks.json`.

## Going back

Nothing here deletes your sessions or your settings.

- **Take the collector off a machine.** On a Mac: **Remove VitalAIze…** in the
  app. On Linux: `bin/vitalaize remove`. It stops VitalAIze, takes it out of
  what starts at login and deletes the machine's certificate. Settings and
  saved sessions stay.
- **Put a machine's hooks back as they were.** Copy
  `settings.json.before-collector` over `settings.json` (and the same for
  Codex's `hooks.json`).
- **Go back to 0.2.0 on the hub.** Use **Remove VitalAIze…** with "Also delete
  the database and settings" left off, then install the 0.2.0 package from the
  [releases page](https://github.com/kyroco/vitalaize/releases). The settings
  as they were before 0.3.0 touched them are in the oldest folder under
  `backups/` in the data folder, the one made when you first opened 0.3.0.
  Every later setup or Save makes a newer folder. Not tried: whether 0.2.0 opens a database
  that 0.3.0 has written to. To be safe, copy `wallboard.db` somewhere before
  step 1.

## What to send back when a step fails

The step number, what the screen said, and the last 50 lines of the log on
both machines:

```
tail -50 ~/Library/Logs/VitalAIze/board.log
journalctl --user -u vitalaize -n 50
```
