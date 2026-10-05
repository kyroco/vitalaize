# Every screen and control of the Mac app

This is the list of every screen the Mac app shows and every button, switch,
picker, field and link on it, with what happened when each one was used in the
real app. A script uses them, so the whole list can be run again:

    macos/uitest/run.sh          every scenario but the slow one, about 10 minutes
    macos/uitest/run.sh --all    the slow one too (a pairing code that runs out), about 21 minutes
    macos/uitest/run.sh pair     only the scenarios named
    macos/uitest/record.py       write the last run down (see below)

The record of the last full run, step by step, is in
[mac-app-checks/last-run.md](mac-app-checks/last-run.md), and a picture of
every screen is in `mac-app-checks/pictures/`.

## How the run works

The run builds the board and a test copy of the app, the same code with one
more file (`macos/uitest/Driver.swift`) that reads the app's own windows and
clicks in them. Each scenario gets a throwaway home folder under
`macos/build/uitest/homes`, with made-up "acme" data, its own login item name
and its own port (4981 to 4996). Nothing in your own home, your login items,
`/Applications` or your board on 4747 is read or changed. While it runs, the
test boards show up on your network as "VitalAIze on (this Mac)", like any board.

A scenario is a shell file in `macos/uitest/scenarios/`. It sets up a starting
point, runs one or more step files from `macos/uitest/steps/`, and after each
one checks from outside the app what the screen claimed: that the board
answers on its port, that the login item runs, that a setting is in use, that
a file is where it should be.

One thing about the pictures: a switch the script clicked can still be drawn as
it was before the click, because the test window is not in front and the
switch never finishes sliding. The run reads each switch's real value, and the
record has it; the last section asks a person to look at one.

The run needs no permission from macOS (no Screen Recording, no Accessibility).
It needs `gh` signed in for the GitHub step, and `node` for the hub's mailbox.

## Starting points

| Starting point | Scenario | What it sets up | Result |
|---|---|---|---|
| Fresh Mac, hub and collector | `fresh-hub` | An empty home | Passed |
| Fresh Mac, hub only | `hub-only` | An empty home | Passed |
| Fresh Mac, collector only | `pair` | An empty home, and a hub in a second home | Passed |
| Fresh Mac with a board started by hand | `by-hand` | A `local.wallboard` login item and `~/projects/wallboard/settings.exs` | Passed |
| Fresh Mac, picking a folder an older board left | `kept-folder` | A folder with that board's settings, a port saved in them, and a name its own settings page kept in the database | Passed |
| Installing over 0.2.0 | `over-0-2-0` | 0.2.0's settings file and setup record, its board still running, and its upload hook in Claude's settings beside a hook of the person's own | Passed |
| Installing over an install from before the rename | `over-renamed` | Data in `Vitalize`, a login item that starts an app that is gone, a carried-over settings file that is gone | Passed |
| Reconfigure | `fresh-hub`, `pair`, `over-renamed`, `over-0-2-0`, `failures` | A Mac that is already set up | Passed |
| Uninstall, then set up again | `fresh-hub`, `pair`, `hub-only` | Remove with the data kept, Remove with the data deleted | Passed |
| Things going wrong | `failures`, `over-renamed`, `pair`, `pair-timeout` | See "Failure paths" below | Passed |

## The screens

"Script" says what the run does with the control. Where it says "set, not
opened" or "pressed, not clicked", the last section has the clicks for a person.

### 1. Looking at this Mac

Shown while the app looks for Claude folders, repositories and an earlier
board. It has no controls. On a Mac that is already set up it says "Reading the
settings in use now, so the setup starts from them."

### 2. Setup, step 1: What this Mac does

Roles: all. Picture: [fresh-hub/01-role](mac-app-checks/pictures/fresh-hub/01-role.jpg).

| Control | Script | What happened |
|---|---|---|
| Hub and collector | Clicked | The setup has 5 steps |
| Hub only | Clicked | The setup has 5 steps; the review and the first screen say "Hub only" |
| Collector only | Clicked | The setup has 4 steps ([picture](mac-app-checks/pictures/fresh-hub/01-role-collector.jpg)) |
| Continue | Clicked | Goes to step 2 |

### 3. Setup, step 2: Claude folders

Roles: all. A collector does not see "Where the board keeps its files".
Pictures: [hub](mac-app-checks/pictures/fresh-hub/02-folders.jpg),
[collector](mac-app-checks/pictures/pair/c02-folders.jpg),
[with a board started by hand](mac-app-checks/pictures/by-hand/b01-folders.jpg).

| Control | Script | What happened |
|---|---|---|
| A switch for each Claude folder found | Turned off and on | With none on, Continue is greyed out |
| Add another Claude folder… | Clicked twice: the folder panel cancelled, then a folder picked | Cancelled: nothing added. Picked: the folder is listed with its switch on |
| Change… (where the board keeps its files) | Clicked three times: cancelled, a folder picked, the first folder picked again | The folder shown changes each time a folder is picked |
| Change…, picking a folder that already holds a board's settings | Clicked | "This folder holds a board's settings. The setup is filled in from them…" ([picture](mac-app-checks/pictures/kept-folder/k01-folder.jpg)). The name and port shown are that board's; after the setup its other saved settings and its history are still there, and a changed answer wins |
| Carry over its settings from … | Turned off and on | Stays on the page when off, so it can be turned on again. The review says "Carried over" |
| Stop that board and run this one instead | Turned off and on | With it on, the setup takes the by-hand login item away and keeps a copy |
| Back, Continue | Clicked | Back keeps what was picked |

### 4. Setup, step 3: GitHub (a Mac that runs the board)

Pictures: [empty](mac-app-checks/pictures/fresh-hub/03-github-empty.jpg),
[not found](mac-app-checks/pictures/fresh-hub/03-github-not-found.jpg),
[Add refused](mac-app-checks/pictures/fresh-hub/03-github-add-refused.jpg),
[filled in](mac-app-checks/pictures/fresh-hub/03-github-filled.jpg).

| Control | Script | What happened |
|---|---|---|
| Repository | Typed | With it empty, Continue is greyed out |
| Look up | Clicked with the box empty, with "not a repo", with a repository GitHub does not have, and with kyroco/vitalaize (twice) | Each says what it did: "Type the repository as owner/name…", "… is not a repository name", "GitHub has no repository named …", "Found kyroco/vitalaize with …". A find fills in the gate workflow and the main branch |
| Main branch | Typed | Kept |
| Gate workflow, Dev deploy workflow, Prod deploy workflow | Set, not opened | The value shows in the picker; "None" is saved as none |
| Add another | Typed | Kept in the box when Add refuses it |
| Add | Clicked with the box empty, with "not a repo", with the first repository, with a new one, with the same one again | Each says what it did: "Type a repository…", "… is not a repository name", "… is already the first repository", "Added acme/rockets.", "… is already in the list" |
| Remove (beside an added repository) | Clicked | "Removed acme/boosters." |
| Back, Continue | Clicked | Back and forward keep everything typed |

### 5. Setup, step 4: What the board shows (a Mac that runs the board)

Pictures: [as found](mac-app-checks/pictures/fresh-hub/04-features.jpg),
[filled in](mac-app-checks/pictures/fresh-hub/04-features-filled.jpg).

| Control | Script | What happened |
|---|---|---|
| Name at the top | Typed | On the review, and in use after the setup |
| Port | Typed | On the review; the board answers there after the setup |
| Show Korium numbers | Turned on | Kept |
| Show and save Codex sessions | Turned on | Kept |
| Dev: awake or asleep; Prod: same build as dev? | Set, not opened | On the review |
| Show the New Relic page | Turned on, then off before the install | On: Account ID, New Relic API key and Or where it is in 1Password appear |
| Account ID, Or where it is in 1Password | Typed | Kept |
| New Relic API key | Typed, then the page turned off before the install | Shows dots as it is typed. With the page off it is not kept: the throwaway keychain has no key, and no file of the run holds it |
| Phone number | Typed, then emptied before the install | On the review as "to +15550100 by SMS"; empty, the review says texts are off |
| Send as | Set, not opened | On the review |
| Back, Continue | Clicked | Keeps everything typed |

### 6. Setup, step 3 for a collector: Your hub

Pictures: [the page](mac-app-checks/pictures/pair/c03-hub.jpg),
[already paired](mac-app-checks/pictures/pair/c12-reconfigure-hub.jpg).

| Control | Script | What happened |
|---|---|---|
| A row for each hub found on the network | Clicked | Fills in the hub's address |
| Hub address | Typed, emptied, typed again | Empty, Continue is greyed out, unless this Mac is already paired |
| Back, Continue | Clicked | Back keeps the address |

### 7. Setup, last step: This Mac (the review)

Pictures: [hub and collector](mac-app-checks/pictures/fresh-hub/05-review.jpg),
[hub only](mac-app-checks/pictures/hub-only/h01-review.jpg),
[collector](mac-app-checks/pictures/pair/c04-review.jpg),
[collector that stays paired](mac-app-checks/pictures/pair/c12-reconfigure-review.jpg).

| Control | Script | What happened |
|---|---|---|
| Back | Clicked | Goes back with everything kept |
| Install and start the board | Clicked | The setup runs; the board answers on its port and the login item runs |
| Start the collector and pair | Clicked | The collector starts and the screen shows a code |
| Start the collector (already paired, no hub picked) | Clicked | The collector restarts and stays paired; no code is asked for |

### 8. Setting up, and what it ends on

Pictures: [working](mac-app-checks/pictures/fresh-hub/06-working.jpg),
[the pairing code](mac-app-checks/pictures/pair/c05-code.jpg),
[stopped: port taken](mac-app-checks/pictures/failures/f01-port-taken.jpg),
[stopped: a file could not be written](mac-app-checks/pictures/over-renamed/a03-write-failed.jpg).

The screen lists each step as it is done. It has controls only when the setup
stops:

| Control | Script | What happened |
|---|---|---|
| Open the log | Clicked | The app asks macOS to open `board.log` |
| Back to the setup | Clicked | The review again, with every answer kept |
| Back (when it was Remove that stopped) | Clicked | The first screen, with the board still running |

### 9. The first screen of a Mac that runs the board

Pictures: [running](mac-app-checks/pictures/fresh-hub/08-status.jpg),
[restarting](mac-app-checks/pictures/fresh-hub/09-restarting.jpg),
[not answering](mac-app-checks/pictures/failures/f02-mend-failed.jpg),
[mended after an upgrade](mac-app-checks/pictures/over-renamed/a01-mended.jpg),
[restarted after an upgrade](mac-app-checks/pictures/over-0-2-0/v01-restarted.jpg).

| Control | Script | What happened |
|---|---|---|
| Check again | Clicked, with the board running and with it not answering | The screen says which it is |
| Open the board | Clicked | The app asks macOS to open `http://127.0.0.1:PORT/` |
| Settings | Clicked | The Settings screen |
| Restart the board | Clicked | "Restarting the board…", the button greys out, then "The board restarted and is answering." |
| Show the log | Clicked | The app asks macOS to open `board.log` |
| Reconfigure… | Clicked | The setup, starting from the settings in use now |
| Remove VitalAIze… | Pressed, not clicked | The Remove sheet |

### 10. The first screen of a collector

Pictures: [paired](mac-app-checks/pictures/pair/c07-status.jpg),
[not paired](mac-app-checks/pictures/pair/c01-closed-hub.jpg),
[restarted](mac-app-checks/pictures/pair/c08-restarted.jpg).

| Control | Script | What happened |
|---|---|---|
| Check again | Clicked | Still says the collector is running |
| Pair with a hub… (not paired) | Clicked | The Pair sheet |
| Pair again… (paired) | Clicked | The Pair sheet |
| Settings | Clicked | The collector's Settings |
| Restart the collector | Clicked | "Restarting the collector…", then "The collector restarted and is running." |
| Show the log | Clicked | The app asks macOS to open `board.log` |
| Reconfigure… | Clicked | The setup; it stays paired unless a hub is picked |
| Remove VitalAIze… | Pressed, not clicked | The Remove sheet |

The line under the title says whether this Mac is connected: "Connected to the
hub at …", or "Not paired with a hub yet, so nothing is sent."

### 11. The Pair sheet

Pictures: [empty](mac-app-checks/pictures/pair/c10-pair-sheet.jpg),
[the code](mac-app-checks/pictures/pair/c10-pair-code.jpg),
[refused](mac-app-checks/pictures/pair/c10-refused.jpg),
[no board at that address](mac-app-checks/pictures/pair/c11-no-hub.jpg).

| Control | Script | What happened |
|---|---|---|
| A row for each hub found on the network | Clicked | Fills in the hub's address |
| Hub address | Typed | Empty, Pair is greyed out |
| Pair | Clicked | A code shows; the same code is in the hub's mailbox |
| Hide (while waiting) | Clicked | The sheet goes; opened again, the same code is still there |
| Close | Clicked | The sheet goes; why the pairing failed stays on the first screen |
| Pair, on a collector that is already paired, and the hub approves | Clicked | "This Mac is connected as …" ([picture](mac-app-checks/pictures/pair/c11-again-approved.jpg)). The collector takes up the new certificate by itself, with no restart, and the first screen says "Connected to the hub at …" |

On the hub's side the script approves or refuses the code in the board's
mailbox page, the way a person does in a browser.

### 12. Settings on a Mac that runs the board

Pictures: [top](mac-app-checks/pictures/fresh-hub/10-settings.jpg),
[saved](mac-app-checks/pictures/fresh-hub/10-settings-saved.jpg),
[refused](mac-app-checks/pictures/fresh-hub/10-settings-refused.jpg),
[saved with a restart](mac-app-checks/pictures/fresh-hub/10-settings-restarted.jpg),
[every setting changed](mac-app-checks/pictures/fresh-hub/16-settings-all.jpg),
[could not be saved](mac-app-checks/pictures/over-renamed/a03-save-failed.jpg).

| Control | Script | What happened |
|---|---|---|
| Save | Clicked with nothing changed | "Nothing changed." |
| Board name, Seconds between pages | Typed, saved | "Saved in …"; in use with no restart |
| Board port | Typed "abc", saved; then a free port, saved | "abc": "Nothing was saved", and the setting is named. A port: the board restarts and "The board is answering at http://localhost:PORT." The old port no longer answers |
| Time zone | Typed, saved | In use |
| Board password | Typed, saved | The board restarts. It then answers "add ?token=" without the password and opens with it. The first screen still says it is running, and says the address needs the password once ([picture](mac-app-checks/pictures/fresh-hub/16-status-password.jpg)) |
| Tell me when a new version is out, Korium numbers, Codex sessions, Take collectors | Turned on or off, saved | In use; Take collectors restarts the board |
| New Relic page; Save this Mac's Claude sessions | Turned on and off again, not saved | The switch changes; see the last section |
| Phone number (Messages) | Typed and emptied, not saved | See the last section |
| Send as, Region | Set, not opened | In use |
| Slack webhook, ntfy topic, ntfy server, Pushover user key, Pushover app token | Typed, saved | In use |
| Account number, Or where it is in 1Password | Typed, saved | In use, with no restart |
| New Relic API key | Typed, saved | Kept in the run's throwaway keychain, never the login keychain of whoever runs it. The screen then shows dots; the key is in no file of the run's home, picture or list of a screen, and is still kept after Remove and a new setup |
| Port they stream to | Typed, saved | In use |
| Claude folders, Codex folders, Repositories | Typed, saved | In use |
| Long-running after, Keep an idle session on Live for, Days to save on first start, Save a session after it is quiet for | Typed, saved | In use |
| Main branch, Gate workflow file, Dev deploy workflow file, Prod deploy workflow file | Typed, saved | In use |
| Dev profile, Prod profile | Typed, saved | In use. With no database or cluster named in `settings.exs`, the board says that is what is missing |
| Back | Clicked | The first screen, with no "Restarting" left on it |

### 13. Settings on a collector

Picture: [the screen](mac-app-checks/pictures/pair/c09-settings.jpg).

| Control | Script | What happened |
|---|---|---|
| Claude folders to watch, Codex folders to watch | Typed, saved | "Saved in …" |
| Save | Clicked with nothing changed | "Nothing changed." |
| Back | Clicked | The first screen |

### 14. The Remove sheet, and "VitalAIze was removed"

Pictures: [the sheet](mac-app-checks/pictures/fresh-hub/13-remove-sheet.jpg),
[removed, data kept](mac-app-checks/pictures/fresh-hub/14-removed.jpg),
[the sheet with delete on](mac-app-checks/pictures/fresh-hub/15-remove-sheet-delete.jpg),
[removed, data deleted](mac-app-checks/pictures/fresh-hub/15-removed-all.jpg),
[a collector removed](mac-app-checks/pictures/pair/c13-removed.jpg).

| Control | Script | What happened |
|---|---|---|
| Also delete the database and settings | Turned on | The data folder is gone after Remove; left off, the database and settings stay |
| Cancel | Clicked | The sheet goes, the board still runs |
| Remove | Pressed, not clicked | The board stops, the login item is gone, and the screen says what was done and whether the data was kept |
| Set up again | Clicked | The setup from step 1, filled in from the settings that were kept. Run through, the board comes back with the kept database and settings ([picture](mac-app-checks/pictures/fresh-hub/14-set-up-again.jpg)) |

## Steps that write a file

The rule: a file a person has is never removed or overwritten until its
replacement is written, and a dated copy of it is kept first, in
`backups/(date and time)/` inside the folder the board keeps its files in.

| Step | Files it changes | How the old one is kept | Proven by |
|---|---|---|---|
| Install and start the board; Start the collector (first setup and Reconfigure) | `settings.exs`, `settings.json`, `install.json`, the login item, the copy of an earlier settings file | Each is copied to the backup folder, then the new one is written beside it and swapped in | `over-renamed`: with the folder made read-only, Reconfigure stops with "Could not write … The file that was there is unchanged.", all four files are byte for byte as before, and the board still answers. `over-0-2-0` and `over-renamed`: the old `settings.exs` is in the backup folder |
| Opening the app over an older install (the mend) | The login item, and `settings.exs` when it loads a file that is gone | Copied to the backup folder first; the screen says where | `over-renamed`: both copies are in the backup folder, the database and saved settings are untouched |
| Stop that board and run this one instead | The by-hand login item `local.wallboard.plist` (removed) | Copied to the backup folder first; the earlier settings file is not touched | `by-hand` |
| Save in Settings | `settings.json` | Copied to the backup folder first; the board's code writes the new one beside it and swaps it in. The screen says where the copy is | `fresh-hub`: the copy is there. `over-renamed`: with the folder read-only, "Could not write to file … Check that the folder can be written to. Nothing was saved." and the file is unchanged |
| Remove, data kept | The login item and `install.json` (removed) | Both are copied to the backup folder first. If a copy cannot be kept, nothing is removed and the screen says so | `fresh-hub`; `over-renamed` for the copy that cannot be kept: "Nothing was removed", all four files as before, the board still running |
| Taking out 0.2.0's upload hooks (first setup, Reconfigure and Remove) | Claude's `settings.json` and Codex's `hooks.json`; the script `wallboard-upload.sh` (deleted) | The file is copied beside itself first, as `settings.json.before-collector` (then `-2`, `-3`, never over an earlier copy), and the new one is written beside it and swapped in. The copy is beside the file and not in the backup folder, so it is still there after Remove with the data deleted. The script is not kept: it holds the hub's old key | `over-0-2-0`: after Reconfigure the upload hook is gone, the person's own hook is still there, the copy holds the file as it was, and the script is gone. Remove runs the same code; the board's own tests cover it (`test/wallboard/old_collector_test.exs`), no scenario does |
| Remove, data deleted | The whole folder | Nothing is kept: the switch says so and is off unless turned on | `fresh-hub`, `hub-only` |
| Pairing | The certificate in `collector/link/` | A new pairing replaces it only after the hub approves; a refused or unanswered one leaves the old pairing connected | `pair`: after a refusal the first screen still says "Connected to the hub at …" |

A setup that stops after the settings were written says so: "The settings from
this setup were already saved, and the copies from before are in the backups
folder."

When `settings.exs` is written again without the earlier file it used to carry
over, the screen names the missing file and says "Settings beyond the ones this
setup asks about were not carried over."

## Failure paths

Each says what went wrong and what to do, and whether the board is running.

| What goes wrong | What the screen says | Board or collector after | Scenario |
|---|---|---|---|
| The board's port is used by another program | "Port N is already used by another program on this Mac … pick another port on the fourth step … Nothing was changed." | "Nothing of VitalAIze is running on this Mac." | `failures` |
| The folder cannot be written to during Reconfigure | "Could not write … The file that was there is unchanged." | "The board that was set up before is still running at http://localhost:N." | `over-renamed` |
| The folder cannot be written to during Save | "Could not write to file … Check that the folder can be written to. Nothing was saved." | Still running | `over-renamed` |
| Remove cannot keep its copies | "Could not keep a copy of … Nothing was removed. Check that … can be written to and use Remove again, or turn on deleting the database and settings too." ([picture](mac-app-checks/pictures/over-renamed/a05-remove-failed.jpg)) | "The board that was set up before is still running at http://localhost:N." | `over-renamed` |
| The board has a password | The first screen: "This board has a password. The first time a browser opens it, add ?token= and the password to the end of the address." | Running | `fresh-hub` |
| The login item starts an app that is gone | The app mends it when opened and lists what it did | Running again | `over-renamed` |
| The carried-over settings file is gone, and so is its copy | Names the file; "Settings beyond the ones this setup asks about were not carried over." | Running again | `over-renamed` |
| The carried-over settings file is gone, its copy is there | The copy is used; nothing is lost | Running again | `over-renamed` |
| The board cannot start after the mend (its settings file cannot be read) | "The board did not start. Its log is at … Use Show the log to see why, then Reconfigure to set it up again. Your settings and database are where they were." | "The board is not answering"; Reconfigure brings it back | `failures` |
| The board still running is the one from before an upgrade | "The board that was running was started before this version of the app was installed. Restarting it…" | Restarted | `over-0-2-0` |
| A setting is refused on Save | "Nothing was saved. Fix these and save again:" with the setting's name | Still running | `fresh-hub` |
| Look up cannot find the repository | "GitHub has no repository named …"; the workflows picked before stay as they were | Not set up yet | `fresh-hub` |
| An older board's own settings page saved a value in the database | The setup's answer still wins: the screen says "Saving the answers that differ from what an earlier board saved" | Running | `over-0-2-0` |
| The app is opened from a download or a disk image | "This copy of VitalAIze runs from a place that will not be there after a restart … Move VitalAIze into the Applications folder and open it from there." | As it was | Not run: see the last section |
| Nothing answers at the hub's address | "Could not pair: nothing answers at …" | The collector runs | `pair` |
| The board at that address does not take collectors | "That board does not take collectors. On the hub, open its settings, turn on Take collectors, and ask again." | The collector runs, not paired | `pair` |
| The hub's owner refuses the code | "The hub's owner refused this machine." | The collector runs; an earlier pairing stays connected | `pair` |
| Nobody approves the code in ten minutes | "The collector is set up, but it did not pair. Nobody approved the code in time." | The collector runs, not paired | `pair-timeout` |

## What the script cannot do: clicks for a person

The script works from inside the app, so a few things only a person at the Mac
can do. Do these on a Mac where VitalAIze is set up, in this order.

1. **Open each picker's menu.** A menu runs outside the app's reach, so the
   script sets the value and checks the picker shows it. In Reconfigure, on
   "GitHub", click Gate workflow, Dev deploy workflow and Prod deploy workflow
   in turn and pick an entry in each. On "What the board shows", do the same for
   Dev, Prod and Send as. In Settings, do it for Send as and Region. Each should
   show what you picked.
2. **Click Remove with the mouse.** The script presses the two red buttons the
   way VoiceOver does. On the first screen click "Remove VitalAIze…", then
   Cancel. Click it again, then "Remove". The screen should say "VitalAIze was
   removed from this Mac" and that the database and settings are still there.
   Click "Set up again" and go through the setup.
3. **Use the folder panel.** In the setup's second step click "Add another
   Claude folder…", pick a folder in the panel and click Open; then click it
   again and press Cancel. Do the same with "Change…". The script answers for
   the panel.
4. **See what opens.** Click "Open the board" (your browser should open the
   board) and "Show the log" (the log should open). The script checks only what
   the app asked macOS to open.
5. **Look at a switch.** In Settings, turn "Korium numbers" off and on: the
   switch should slide and show the state you left it in.
6. **Press Return.** In the Pair sheet, type a hub's address and press Return:
   it should do what Pair does. On the first screen of a Mac that runs the
   board, Return should open the board.
7. **Open the app from a disk image.** With VitalAIze set up, open another
   copy of the app from a mounted disk image or straight from Downloads. It
   should leave the login item alone while the copy in Applications is there.
8. **Close the window.** The app quits and the board keeps running:
   `http://localhost:4747` should still answer.
9. **Install the package.** First close any Installer window left open from an
   earlier install: while one sits on its last page, opening a new package only
   brings that old window forward and nothing is installed. Then double-click
   `VitalAIze-(version).pkg`, go through the installer's pages, and open the
   app from Applications. Over an older
   install, the first screen should say what it mended or restarted, then "The
   board is running".
10. **Restart the Mac** and log in. Without opening the app, the board should
   answer.
11. **Things that reach outside this Mac**, which the run leaves off on purpose:
   a phone number (a text is sent when a session needs you), the New Relic page
   with a real key typed in Settings (it should be in Keychain Access under
   VitalAIze, the page should fill within a minute with no restart, and it
   should still fill after a restart), the board password
   from another device (it should ask for `?token=` once), and a board started
   by hand that is really running when "Stop that board" is on.
