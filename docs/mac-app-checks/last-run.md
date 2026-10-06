# The Mac app's last full run

Written by `macos/uitest/record.py` from the run of `macos/uitest/run.sh --all` on October 5, 2026.
Do not edit it by hand: run the script again.

912 of 912 steps and checks passed. 85 pictures are in `pictures/`, one folder for each scenario.

A step is one line of a file in `macos/uitest/steps/`: `click`, `type`, `toggle` and `press` use a control,
`wait`, `expect`, `absent`, `value`, `enabled` and `disabled` look at the screen, `opened` checks what the app
asked macOS to open, and `snap` takes the picture of that name. The list of screens and controls these
belong to is in [../mac-app-checks.md](../mac-app-checks.md).

## by-hand

### byhand-wizard: 30 of 30 steps passed

```
ok    wait 90 "What this Mac does"
ok    click "Continue"
ok    wait "Claude folders to include"
ok    expect "A board you set up before"
ok    value "Carry over its settings from ~/projects/wallboard/settings.exs" "1"
ok    value "Stop that board and run this one instead" "1"
ok    snap b01-folders
ok    toggle "Carry over its settings from ~/projects/wallboard/settings.exs"
ok    value "Carry over its settings from ~/projects/wallboard/settings.exs" "0"
ok    toggle "Carry over its settings from ~/projects/wallboard/settings.exs"
ok    value "Carry over its settings from ~/projects/wallboard/settings.exs" "1"
ok    toggle "Stop that board and run this one instead"
ok    toggle "Stop that board and run this one instead"
ok    value "Stop that board and run this one instead" "1"
ok    click "Continue"
ok    wait "Main branch"
ok    value "Repository" "acme/rockets"
ok    click "Continue"
ok    wait "Name at the top"
ok    value "Name at the top" "Acme By Hand"
ok    type "Port" "4994"
ok    click "Continue"
ok    wait "This Mac"
ok    expect "Carried over"
ok    snap b02-review
ok    click "Install and start the board"
ok    wait 10 "Setting up…"
ok    wait 150 "The board is running"
ok    absent "That did not work"
ok    snap b03-status
```

### hub-remove-all: 11 of 11 steps passed

```
ok    wait 40 "The board is running"
ok    press "Remove VitalAIze…"
ok    wait 5 "Remove VitalAIze from this Mac?"
ok    toggle "Also delete the database and settings"
ok    snap 15-remove-sheet-delete
ok    press "Remove"
ok    wait 60 "VitalAIze was removed from this Mac"
ok    expect "Its database and settings were deleted too, and any key typed in Settings was taken out of the keychain."
ok    snap 15-removed-all
ok    click "Set up again"
ok    wait 90 "What this Mac does"
```

### Checked from outside the app

- ok: the board answers
- ok: what the earlier file held beyond the wizard is in use
- ok: and its page turning too
- ok: the by-hand login item is gone
- ok: a copy of it is in the backup folder
- ok: the earlier settings file is still where it was


## failures

### fail-port: 33 of 33 steps passed

```
ok    wait 90 "What this Mac does"
ok    click "Continue"
ok    wait "Claude folders to include"
ok    click "Continue"
ok    wait "Main branch"
ok    type "Repository" "acme/rockets"
ok    click "Continue"
ok    wait "Name at the top"
ok    type "Name at the top" "Acme"
ok    type "Port" "4988"
ok    click "Continue"
ok    wait "This Mac"
ok    click "Install and start the board"
ok    wait 30 "That did not work"
ok    expect "Port 4988 is already used by another program on this Mac"
ok    expect "Nothing was changed."
ok    expect "Nothing of VitalAIze is running on this Mac."
ok    snap f01-port-taken
ok    click "Open the log"
ok    opened "board.log"
ok    click "Back to the setup"
ok    wait 5 "This Mac"
ok    click "Back"
ok    wait "Name at the top"
ok    type "Port" "4989"
ok    click "Continue"
ok    wait "This Mac"
ok    expect "Acme at http://localhost:4989"
ok    click "Install and start the board"
ok    wait 10 "Setting up…"
ok    wait 150 "The board is running"
ok    absent "That did not work"
ok    snap f01-other-port
```

### fail-mend: 26 of 26 steps passed

```
ok    wait 10 "Kyroco VitalAIze"
ok    wait 200 "The board did not start. Its log is at"
ok    expect "which is gone."
ok    expect "Use Show the log to see why, then Reconfigure to set it up again. Your settings and database are where they were."
ok    wait 20 "The board is not answering"
ok    absent "Mended."
ok    snap f02-mend-failed
ok    click "Show the log"
ok    opened "board.log"
ok    click "Check again"
ok    wait 20 "The board is not answering"
ok    click "Reconfigure…"
ok    wait 90 "What this Mac does"
ok    click "Continue"
ok    wait "Claude folders to include"
ok    click "Continue"
ok    wait "Main branch"
ok    click "Continue"
ok    wait "Name at the top"
ok    click "Continue"
ok    wait "This Mac"
ok    click "Install and start the board"
ok    wait 10 "Setting up…"
ok    wait 150 "The board is running"
ok    absent "That did not work"
ok    snap f02-reconfigured
```

### Checked from outside the app

- ok: the stopped setup wrote no settings file for the taken port
- ok: with another port the board answers
- ok: after Reconfigure the board answers again
- ok: the settings file that could not be read is in the backup folder


## fresh-hub

### hub-wizard: 139 of 139 steps passed

```
ok    wait 90 "What this Mac does"
ok    expect "Step 1 of 5"
ok    expect "Found on this Mac"
ok    snap 01-role
ok    click "Hub only"
ok    expect "Step 1 of 5"
ok    click "Collector only"
ok    wait 5 "Step 1 of 4"
ok    snap 01-role-collector
ok    click "Hub and collector"
ok    wait 5 "Step 1 of 5"
ok    click "Continue"
ok    wait "Claude folders to include"
ok    expect "Step 2 of 5"
ok    snap 02-folders
ok    toggle "~/.claude"
ok    disabled "Continue"
ok    toggle "~/.claude"
ok    enabled "Continue"
ok    folder ""
ok    click "Add another Claude folder…"
ok    absent "~/OtherClaude"
ok    folder "~/OtherClaude"
ok    click "Add another Claude folder…"
ok    wait 5 "~/OtherClaude"
ok    toggle "~/OtherClaude"
ok    folder ""
ok    click "Change…"
ok    expect "~/Library/Application Support/VitalAIze"
ok    folder "~/BoardFiles"
ok    click "Change…"
ok    wait 5 "~/BoardFiles"
ok    folder "~/Library/Application Support/VitalAIze"
ok    click "Change…"
ok    wait 5 "~/Library/Application Support/VitalAIze"
ok    snap 02-folders-changed
ok    click "Back"
ok    wait 5 "What this Mac does"
ok    click "Continue"
ok    wait "Claude folders to include"
ok    click "Continue"
ok    wait "Main branch"
ok    expect "Step 3 of 5"
ok    snap 03-github-empty
ok    disabled "Continue"
ok    click "Look up"
ok    wait 5 "Type the repository as owner/name"
ok    type "Repository" "not a repo"
ok    click "Look up"
ok    wait 5 "is not a repository name"
ok    type "Repository" "kyroco/no-such-repository-vit47"
ok    click "Look up"
ok    wait 40 "GitHub has no repository named kyroco/no-such-repository-vit47"
ok    snap 03-github-not-found
ok    type "Repository" "kyroco/vitalaize"
ok    click "Look up"
ok    wait 40 "Found kyroco/vitalaize with"
ok    value "Gate workflow (checks each change)" "ci.yml"
ok    value "Main branch" "main"
ok    click "Look up"
ok    wait 40 "Found kyroco/vitalaize with"
ok    pick "Dev deploy workflow" "codeql"
ok    value "Dev deploy workflow" "codeql"
ok    pick "Dev deploy workflow" ""
ok    pick "Prod deploy workflow" "codeql"
ok    pick "Prod deploy workflow" ""
ok    pick "Gate workflow (checks each change)" "ci.yml"
ok    type "Main branch" "main"
ok    click "Add"
ok    wait 5 "Type a repository as owner/name in the box"
ok    type "Add another" "not a repo"
ok    click "Add"
ok    wait 5 "is not a repository name"
ok    value "Add another" "not a repo"
ok    snap 03-github-add-refused
ok    type "Add another" "kyroco/vitalaize"
ok    click "Add"
ok    wait 5 "is already the first repository"
ok    type "Add another" "acme/rockets"
ok    click "Add"
ok    wait 5 "Added acme/rockets."
ok    type "Add another" "acme/rockets"
ok    click "Add"
ok    wait 5 "is already in the list"
ok    type "Add another" "acme/boosters"
ok    click "Add"
ok    wait 5 "Added acme/boosters."
ok    click "Remove" 2
ok    wait 5 "Removed acme/boosters."
ok    snap 03-github-filled
ok    click "Back"
ok    wait "Claude folders to include"
ok    click "Continue"
ok    wait "Main branch"
ok    value "Repository" "kyroco/vitalaize"
ok    expect "acme/rockets"
ok    click "Continue"
ok    wait "Name at the top"
ok    expect "Step 4 of 5"
ok    snap 04-features
ok    type "Name at the top" "Acme"
ok    type "Port" "4981"
ok    toggle "Show Korium numbers (searches, saves, indexing)"
ok    toggle "Show and save Codex sessions"
ok    pick "Dev: awake or asleep" "acme-dev-read"
ok    pick "Prod: same build as dev?" "acme-prod-read"
ok    toggle "Show the New Relic page"
ok    wait 5 "Account ID"
ok    type "Account ID" "1234567"
ok    type "New Relic API key" "NRAK-UITEST0WIZARD0KEY00000001"
ok    type "Or where it is in 1Password" "op://Private/NewRelic/key"
ok    type "Phone number" "+15550100"
ok    pick "Send as" "SMS"
ok    scroll bottom
ok    snap 04-features-filled
ok    click "Continue"
ok    wait "This Mac"
ok    expect "Step 5 of 5"
ok    expect "Acme at http://localhost:4981"
ok    expect "kyroco/vitalaize (main)"
ok    expect "ci.yml"
ok    expect "dev acme-dev-read, prod acme-prod-read"
ok    expect "to +15550100 by SMS"
ok    snap 05-review
ok    click "Back"
ok    wait "Name at the top"
ok    type "Phone number" ""
ok    pick "Send as" "iMessage"
ok    pick "Prod: same build as dev?" ""
ok    click "Continue"
ok    wait "This Mac"
ok    expect "Texts"
ok    enabled "Install and start the board"
ok    click "Install and start the board"
ok    wait 10 "Setting up…"
ok    snap 06-working
ok    wait 150 "The board is running"
ok    absent "That did not work"
ok    snap 07-status
```

### hub-status: 48 of 48 steps passed

```
ok    wait 40 "The board is running"
ok    expect "Hub and collector"
ok    absent "Mended"
ok    absent "Restarting"
ok    snap 08-status
ok    click "Check again"
ok    wait 10 "The board is running"
ok    click "Open the board"
ok    opened "http://127.0.0.1:4981/"
ok    click "Show the log"
ok    opened "board.log"
ok    click "Restart the board"
ok    wait 5 "Restarting the board…"
ok    disabled "Restart the board"
ok    snap 09-restarting
ok    wait 90 "The board restarted and is answering."
ok    wait 20 "The board is running"
ok    enabled "Restart the board"
ok    snap 09-restarted
ok    click "Settings"
ok    wait 40 "Board name"
ok    snap 10-settings
ok    click "Save"
ok    wait 5 "Nothing changed."
ok    type "Board name" "Acme Two"
ok    type "Seconds between pages" "45"
ok    click "Save"
ok    wait 40 "Saved in"
ok    snap 10-settings-saved
ok    type "Board port (restarts)" "abc"
ok    click "Save"
ok    wait 40 "Nothing was saved"
ok    expect "Board port:"
ok    snap 10-settings-refused
ok    type "Board port (restarts)" "4991"
ok    toggle "Korium numbers"
ok    pick "Send as" "SMS"
ok    click "Save"
ok    wait 60 "Saved in"
ok    expect "Restarted the board to take up: Board port"
ok    wait 90 "The board is answering at http://localhost:4991."
ok    snap 10-settings-restarted
ok    scroll bottom
ok    snap 10-settings-bottom
ok    click "Back"
ok    wait 20 "The board is running"
ok    absent "Restarting the board"
ok    snap 10-status-after-settings
```

### hub-reconfigure: 31 of 31 steps passed

```
ok    wait 40 "The board is running"
ok    click "Reconfigure…"
ok    wait 60 "What this Mac does"
ok    expect "Step 1 of 5"
ok    click "Continue"
ok    wait "Claude folders to include"
ok    value "~/.claude" "1"
ok    click "Continue"
ok    wait "Main branch"
ok    value "Repository" "kyroco/vitalaize"
ok    expect "acme/rockets"
ok    value "Gate workflow (checks each change)" "ci.yml"
ok    value "Dev deploy workflow" "None"
ok    snap 11-reconfigure-github
ok    click "Continue"
ok    wait "Name at the top"
ok    value "Name at the top" "Acme Two"
ok    value "Port" "4991"
ok    value "Send as" "SMS"
ok    snap 11-reconfigure-features
ok    type "Name at the top" "Acme Three"
ok    pick "Send as" "iMessage"
ok    click "Continue"
ok    wait "This Mac"
ok    expect "Acme Three at http://localhost:4991"
ok    snap 11-reconfigure-review
ok    click "Install and start the board"
ok    wait 10 "Setting up…"
ok    wait 150 "The board is running"
ok    absent "That did not work"
ok    snap 12-reconfigured
```

### hub-settings-all: 50 of 50 steps passed

```
ok    wait 40 "The board is running"
ok    click "Settings"
ok    wait 40 "Board name"
ok    type "Time zone" "America/Chicago"
ok    type "Board password (restarts)" "acme-secret"
ok    toggle "Tell me when a new version is out"
ok    toggle "Korium numbers"
ok    type "Slack webhook" "https://localhost:9/acme-hook"
ok    type "ntfy topic" "acme-topic-x1"
ok    type "ntfy server" "http://localhost:9"
ok    type "Pushover user key" "acmeuser1"
ok    type "Pushover app token" "acmetoken1"
ok    type "Account number" "7654321"
ok    type "New Relic API key" "NRAK-UITEST0SETTINGS0KEY000001"
ok    type "Or where it is in 1Password" "op://Private/Acme/key"
ok    pick "Region" "eu"
ok    toggle "Take collectors (restarts)"
ok    type "Port they stream to (restarts)" "4761"
ok    type "Claude folders" "~/.claude"
ok    type "Long-running after (minutes)" "50"
ok    toggle "Codex sessions"
ok    type "Codex folders" "~/.codex"
ok    type "Keep an idle session on Live for (minutes)" "90"
ok    type "Repositories" "acme/rockets"
ok    type "Main branch" "trunk"
ok    type "Gate workflow file" "gate.yml"
ok    type "Dev deploy workflow file" "dev.yml"
ok    type "Prod deploy workflow file" "prod.yml"
ok    type "Dev profile (restarts)" "acme-dev-read"
ok    type "Prod profile (restarts)" "acme-prod-read"
ok    type "Days to save on first start" "7"
ok    type "Save a session after it is quiet for (seconds)" "60"
ok    type "Phone number (Messages)" "+15550100"
ok    type "Phone number (Messages)" ""
ok    toggle "New Relic page (restarts)"
ok    toggle "New Relic page (restarts)"
ok    toggle "Save this Mac's Claude sessions (restarts)"
ok    toggle "Save this Mac's Claude sessions (restarts)"
ok    click "Save"
ok    wait 60 "Saved in"
ok    absent "Nothing was saved"
ok    expect "The settings as they were before this save are in"
ok    expect "Restarted the board to take up"
ok    wait 90 "The board is answering at http://localhost:4991."
ok    scroll bottom
ok    snap 16-settings-all
ok    click "Back"
ok    wait 20 "The board is running"
ok    expect "This board has a password."
ok    snap 16-status-password
```

### hub-remove: 16 of 16 steps passed

```
ok    wait 40 "The board is running"
ok    press "Remove VitalAIze…"
ok    wait 5 "Remove VitalAIze from this Mac?"
ok    snap 13-remove-sheet
ok    click "Cancel"
ok    gone 5 "Remove VitalAIze from this Mac?"
ok    expect "The board is running"
ok    press "Remove VitalAIze…"
ok    wait 5 "Remove VitalAIze from this Mac?"
ok    press "Remove"
ok    wait 60 "VitalAIze was removed from this Mac"
ok    expect "Stopping the board"
ok    expect "Its database and settings are still in"
ok    snap 14-removed
ok    click "Set up again"
ok    wait 90 "What this Mac does"
```

### hub-again: 21 of 21 steps passed

```
ok    wait 90 "What this Mac does"
ok    expect "Step 1 of 5"
ok    click "Continue"
ok    wait "Claude folders to include"
ok    click "Continue"
ok    wait "Main branch"
ok    value "Repository" "acme/rockets"
ok    value "Main branch" "trunk"
ok    click "Continue"
ok    wait "Name at the top"
ok    value "Name at the top" "Acme Three"
ok    value "Port" "4991"
ok    type "Name at the top" "Acme Again"
ok    click "Continue"
ok    wait "This Mac"
ok    expect "Acme Again at http://localhost:4991"
ok    click "Install and start the board"
ok    wait 10 "Setting up…"
ok    wait 150 "The board is running"
ok    absent "That did not work"
ok    snap 14-set-up-again
```

### hub-remove-all: 11 of 11 steps passed

```
ok    wait 40 "The board is running"
ok    press "Remove VitalAIze…"
ok    wait 5 "Remove VitalAIze from this Mac?"
ok    toggle "Also delete the database and settings"
ok    snap 15-remove-sheet-delete
ok    press "Remove"
ok    wait 60 "VitalAIze was removed from this Mac"
ok    expect "Its database and settings were deleted too, and any key typed in Settings was taken out of the keychain."
ok    snap 15-removed-all
ok    click "Set up again"
ok    wait 90 "What this Mac does"
```

### Checked from outside the app

- ok: after the wizard the board answers on its port
- ok: after the wizard the login item runs
- ok: the wizard's board name is in use
- ok: the wizard's repositories are in use
- ok: a workflow left at None is none, not a made-up name
- ok: the New Relic key typed in the wizard is in the keychain
- ok: the board read it from there
- ok: and it is in no file, list or log of the run
- ok: a new port saved in Settings is where the board answers
- ok: the old port no longer answers
- ok: the name saved in Settings is in use
- ok: after Reconfigure the board answers
- ok: the name typed in Reconfigure is in use
- ok: a setting the wizard does not ask about is still as saved
- ok: Reconfigure's Send as is in use
- ok: Reconfigure with the key field left empty keeps the key
- ok: the time zone saved in Settings is in use
- ok: the ntfy server too
- ok: the region too
- ok: the New Relic key typed in Settings is in the keychain
- ok: and shows as set, not as itself
- ok: and is in no file, picture or list of the run
- ok: its 1Password address is saved beside it
- ok: the hub takes collectors
- ok: on the port typed
- ok: the repositories too
- ok: the main branch too
- ok: the board still answers
- ok: and asks for its password
- ok: and opens with it
- ok: the saved settings as they were are in the backup folder
- ok: after Remove the login item is gone
- ok: after Remove nothing answers on the port
- ok: Remove kept the database
- ok: Remove kept the settings
- ok: Remove took the setup record away
- ok: Remove kept a copy of the setup record
- ok: Remove kept a copy of the login item
- ok: set up again, the board answers
- ok: the name typed in the new setup is in use
- ok: a setting saved before Remove is still in use
- ok: the New Relic key saved before Remove is still kept
- ok: one the setup asks about and was left alone, too
- ok: the history from before Remove is still in the database
- ok: after Remove with delete the login item is gone
- ok: after Remove with delete the data folder is gone
- ok: and the New Relic key is out of the keychain


## hub-only

### hubonly-wizard: 25 of 25 steps passed

```
ok    wait 90 "What this Mac does"
ok    click "Hub only"
ok    expect "Step 1 of 5"
ok    click "Continue"
ok    wait "Claude folders to include"
ok    expect "Where the board keeps its files"
ok    click "Continue"
ok    wait "Main branch"
ok    type "Repository" "acme/rockets"
ok    enabled "Continue"
ok    click "Continue"
ok    wait "Name at the top"
ok    type "Name at the top" "Acme Hub Only"
ok    type "Port" "4987"
ok    click "Continue"
ok    wait "This Mac"
ok    expect "Hub only"
ok    expect "Acme Hub Only at http://localhost:4987"
ok    snap h01-review
ok    click "Install and start the board"
ok    wait 10 "Setting up…"
ok    wait 150 "The board is running"
ok    expect "Hub only"
ok    absent "That did not work"
ok    snap h02-status
```

### hub-remove-all: 11 of 11 steps passed

```
ok    wait 40 "The board is running"
ok    press "Remove VitalAIze…"
ok    wait 5 "Remove VitalAIze from this Mac?"
ok    toggle "Also delete the database and settings"
ok    snap 15-remove-sheet-delete
ok    press "Remove"
ok    wait 60 "VitalAIze was removed from this Mac"
ok    expect "Its database and settings were deleted too, and any key typed in Settings was taken out of the keychain."
ok    snap 15-removed-all
ok    click "Set up again"
ok    wait 90 "What this Mac does"
```

### Checked from outside the app

- ok: the board answers
- ok: a hub-only Mac saves none of its own sessions
- ok: its settings file says hub
- ok: after Remove with delete the login item is gone
- ok: after Remove with delete the data folder is gone


## kept-folder

### kept-wizard: 25 of 25 steps passed

```
ok    wait 90 "What this Mac does"
ok    click "Continue"
ok    wait "Claude folders to include"
ok    absent "This folder holds a board's settings."
ok    folder "~/BoardKept"
ok    click "Change…"
ok    wait 5 "~/BoardKept"
ok    wait 40 "This folder holds a board's settings."
ok    snap k01-folder
ok    click "Continue"
ok    wait "Main branch"
ok    value "Repository" "acme/rockets"
ok    click "Continue"
ok    wait "Name at the top"
ok    value "Name at the top" "Acme Page"
ok    value "Port" "4996"
ok    type "Name at the top" "Acme Typed"
ok    click "Continue"
ok    wait "This Mac"
ok    expect "Acme Typed at http://localhost:4996"
ok    click "Install and start the board"
ok    wait 10 "Setting up…"
ok    wait 150 "The board is running"
ok    absent "That did not work"
ok    snap k02-status
```

### hub-remove-all: 11 of 11 steps passed

```
ok    wait 40 "The board is running"
ok    press "Remove VitalAIze…"
ok    wait 5 "Remove VitalAIze from this Mac?"
ok    toggle "Also delete the database and settings"
ok    snap 15-remove-sheet-delete
ok    press "Remove"
ok    wait 60 "VitalAIze was removed from this Mac"
ok    expect "Its database and settings were deleted too, and any key typed in Settings was taken out of the keychain."
ok    snap 15-removed-all
ok    click "Set up again"
ok    wait 90 "What this Mac does"
```

### Checked from outside the app

- ok: the board answers on the port saved in Settings
- ok: nothing is set up any more
- ok: the board answers on the port that folder had saved
- ok: the name typed wins over the one the older page saved
- ok: a setting the setup does not ask about is still as saved
- ok: the history is still in the database


## over-0-2-0

### v020-open: 7 of 7 steps passed

```
ok    wait 10 "Kyroco VitalAIze"
ok    wait 60 "The board that was running was started before this version of the app was installed. Restarting it…"
ok    snap v01-restarting
ok    wait 120 "The board restarted and is answering."
ok    wait 40 "The board is running"
ok    absent "Mended"
ok    snap v01-restarted
```

### v020-again: 29 of 29 steps passed

```
ok    wait 40 "The board is running"
ok    sleep 8
ok    absent "Restarting"
ok    absent "was started before this version"
ok    click "Settings"
ok    wait 40 "Board name"
ok    value "Board name" "Acme Page"
ok    value "Seconds between pages" "45"
ok    snap v02-settings
ok    click "Back"
ok    wait 20 "The board is running"
ok    click "Reconfigure…"
ok    wait 60 "What this Mac does"
ok    click "Continue"
ok    wait "Claude folders to include"
ok    click "Continue"
ok    wait "Main branch"
ok    value "Repository" "acme/rockets"
ok    click "Continue"
ok    wait "Name at the top"
ok    value "Name at the top" "Acme Page"
ok    type "Name at the top" "Acme Wizard"
ok    click "Continue"
ok    wait "This Mac"
ok    click "Install and start the board"
ok    wait 10 "Setting up…"
ok    wait 150 "The board is running"
ok    absent "That did not work"
ok    snap v02-reconfigured
```

### Checked from outside the app

- ok: the 0.2.0 settings file starts the board
- ok: the board was restarted (a new process runs it)
- ok: after the restart the board answers
- ok: the history is still in the database
- ok: what was saved in Settings is still in use
- ok: the name 0.2.0's settings page saved is still in use
- ok: Reconfigure over the 0.2.0 files ends with the board answering
- ok: Reconfigure wrote the settings file in the new form
- ok: the name typed in Reconfigure wins over the one 0.2.0's page saved
- ok: the 0.2.0 settings file is in the backup folder
- ok: Reconfigure took 0.2.0's upload hook out of Claude's settings
- ok: the person's own hook is still in Claude's settings
- ok: Claude's settings from before are kept beside the file
- ok: 0.2.0's upload script is gone


## over-renamed

### aged-open: 10 of 10 steps passed

```
ok    wait 10 "Kyroco VitalAIze"
ok    wait 150 "Mended. Your settings and database are where they were."
ok    expect "which is gone."
ok    expect "Settings beyond the ones this setup asks about were not carried over."
ok    expect "Writing the settings file again from your setup answers"
ok    expect "Setting the login item to start VitalAIze from this app"
ok    expect "The files as they were are in"
ok    expect "The log is at"
ok    wait 40 "The board is running"
ok    snap a01-mended
```

### aged-reconfigure: 23 of 23 steps passed

```
ok    wait 40 "The board is running"
ok    absent "Mended"
ok    click "Reconfigure…"
ok    wait 60 "What this Mac does"
ok    click "Continue"
ok    wait "Claude folders to include"
ok    absent "A board you set up before"
ok    expect "Settings beyond the ones this setup asks about were not carried over."
ok    snap a02-reconfigure-folders
ok    click "Continue"
ok    wait "Main branch"
ok    value "Repository" "acme/rockets"
ok    click "Continue"
ok    wait "Name at the top"
ok    value "Name at the top" "Acme Saved"
ok    click "Continue"
ok    wait "This Mac"
ok    absent "Carried over"
ok    click "Install and start the board"
ok    wait 10 "Setting up…"
ok    wait 150 "The board is running"
ok    absent "That did not work"
ok    snap a02-reconfigured
```

### aged-write-fails: 32 of 32 steps passed

```
ok    wait 40 "The board is running"
ok    click "Settings"
ok    wait 40 "Board name"
ok    type "Board name" "Acme Unsaved"
ok    click "Save"
ok    wait 60 "Check that the folder can be written to. Nothing was saved."
ok    expect "Could not"
ok    snap a03-save-failed
ok    click "Back"
ok    wait 20 "The board is running"
ok    click "Reconfigure…"
ok    wait 60 "What this Mac does"
ok    click "Continue"
ok    wait "Claude folders to include"
ok    click "Continue"
ok    wait "Main branch"
ok    click "Continue"
ok    wait "Name at the top"
ok    type "Name at the top" "Acme Changed"
ok    click "Continue"
ok    wait "This Mac"
ok    click "Install and start the board"
ok    wait 60 "That did not work"
ok    expect "Could not write"
ok    expect "The file that was there is unchanged."
ok    expect "The board that was set up before is still running at http://localhost:4984."
ok    snap a03-write-failed
ok    click "Open the log"
ok    opened "board.log"
ok    click "Back to the setup"
ok    wait 5 "This Mac"
ok    expect "Acme Changed"
```

### aged-remove-fails: 11 of 11 steps passed

```
ok    wait 40 "The board is running"
ok    press "Remove VitalAIze…"
ok    wait 5 "Remove VitalAIze from this Mac?"
ok    press "Remove"
ok    wait 60 "That did not work"
ok    expect "Could not keep a copy of"
ok    expect "Nothing was removed."
ok    expect "The board that was set up before is still running at http://localhost:4984."
ok    snap a05-remove-failed
ok    click "Back"
ok    wait 20 "The board is running"
```

### aged-open-copy: 7 of 7 steps passed

```
ok    wait 10 "Kyroco VitalAIze"
ok    wait 150 "Mended. Your settings and database are where they were."
ok    expect "which is gone."
ok    absent "were not carried over"
ok    absent "Writing the settings file again"
ok    wait 40 "The board is running"
ok    snap a04-mended-copy-kept
```

### Checked from outside the app

- ok: before the app opens, launchd cannot start the board
- ok: before the app opens, nothing answers
- ok: after the app opened, the board answers
- ok: the login item runs the board from this app
- ok: the history is still in the database
- ok: what was saved in Settings is still in use
- ok: the settings file as it was is in the backup folder
- ok: the login item as it was is in the backup folder
- ok: after Reconfigure the board answers
- ok: the history is still there after Reconfigure
- ok: Reconfigure kept the name saved in Settings
- ok: a failed write left all four files as they were
- ok: the board still answers after the failed write
- ok: a Remove that could not keep its copies left all four files as they were
- ok: and the login item still runs
- ok: and the board still answers
- ok: with the copy kept, the board answers
- ok: what the earlier file held beyond the wizard is still in use
- ok: and its page turning too
- ok: the history is still in the database


## pair

### collector-closed-hub: 20 of 20 steps passed

```
ok    wait 90 "What this Mac does"
ok    click "Collector only"
ok    click "Continue"
ok    wait "Claude folders to include"
ok    click "Continue"
ok    wait "Hubs on your network"
ok    type "Hub address" "http://localhost:4982"
ok    click "Continue"
ok    wait "This Mac"
ok    click "Start the collector and pair"
ok    wait 120 "The collector is set up, but it did not pair."
ok    expect "That board does not take collectors. On the hub, open its settings, turn on Take collectors, and ask again."
ok    wait 30 "The collector is running"
ok    wait 30 "Not paired with a hub yet, so nothing is sent."
ok    snap c01-closed-hub
ok    click "Pair with a hub…"
ok    wait 5 "Pick the hub, or type its address."
ok    disabled "Pair"
ok    click "Close"
ok    gone 5 "Pick the hub, or type its address."
```

### collector-wizard: 40 of 40 steps passed

```
ok    wait 90 "What this Mac does"
ok    click "Collector only"
ok    wait 5 "Step 1 of 4"
ok    click "Continue"
ok    wait "Claude folders to include"
ok    expect "Step 2 of 4"
ok    absent "Where the board keeps its files"
ok    snap c02-folders
ok    click "Continue"
ok    wait "Hubs on your network"
ok    expect "Step 3 of 4"
ok    disabled "Continue"
ok    snap c03-hub
ok    wait 30 ":4982"
ok    click ":4982"
ok    value "Hub address" ":4982"
ok    enabled "Continue"
ok    type "Hub address" ""
ok    disabled "Continue"
ok    type "Hub address" "http://localhost:4982"
ok    enabled "Continue"
ok    click "Back"
ok    wait "Claude folders to include"
ok    click "Continue"
ok    wait "Hubs on your network"
ok    value "Hub address" "http://localhost:4982"
ok    click "Continue"
ok    wait "This Mac"
ok    expect "Step 4 of 4"
ok    expect "Collector only"
ok    expect "http://localhost:4982"
ok    snap c04-review
ok    click "Start the collector and pair"
ok    wait 90 "Waiting for the hub to approve…"
ok    expect "Open the mailbox on the board and approve this code."
ok    snap c05-code
ok    wait 120 "The collector is running"
ok    wait 60 "Connected to the hub at"
ok    absent "That did not work"
ok    snap c06-status
```

### collector-status: 55 of 55 steps passed

```
ok    wait 40 "The collector is running"
ok    expect "Collector only"
ok    wait 60 "Connected to the hub at"
ok    absent "Not paired with a hub yet"
ok    snap c07-status
ok    click "Check again"
ok    wait 10 "The collector is running"
ok    click "Show the log"
ok    opened "board.log"
ok    click "Restart the collector"
ok    wait 5 "Restarting the collector…"
ok    wait 60 "The collector restarted and is running."
ok    snap c08-restarted
ok    click "Settings"
ok    wait 40 "Claude folders to watch"
ok    snap c09-settings
ok    click "Save"
ok    wait 5 "Nothing changed."
ok    type "Claude folders to watch" "~/.claude"
ok    type "Codex folders to watch" "~/.codex"
ok    click "Save"
ok    wait 40 "Saved in"
ok    snap c09-settings-saved
ok    click "Back"
ok    wait 20 "The collector is running"
ok    click "Pair again…"
ok    wait 5 "Pick the hub, or type its address."
ok    snap c10-pair-sheet
ok    disabled "Pair"
ok    wait 30 ":4982"
ok    click ":4982"
ok    value "Hub address" ":4982"
ok    enabled "Pair"
ok    click "Pair"
ok    wait 60 "Waiting for the hub to approve…"
ok    snap c10-pair-code
ok    click "Hide"
ok    gone 5 "Waiting for the hub to approve…"
ok    click "Pair again…"
ok    wait 5 "Waiting for the hub to approve…"
ok    snap c10-pair-again
ok    wait 90 "The hub's owner refused this machine."
ok    snap c10-refused
ok    click "Close"
ok    gone 5 "Pick the hub, or type its address."
ok    expect "The hub's owner refused this machine."
ok    expect "Connected to the hub at"
ok    click "Pair again…"
ok    wait 5 "Pick the hub, or type its address."
ok    type "Hub address" "http://localhost:4999"
ok    click "Pair"
ok    wait 60 "Could not pair: nothing answers at http://localhost:4999."
ok    snap c11-no-hub
ok    click "Close"
ok    gone 5 "Pick the hub, or type its address."
```

### collector-pair-again: 14 of 14 steps passed

```
ok    wait 40 "The collector is running"
ok    wait 60 "Connected to the hub at"
ok    click "Pair again…"
ok    wait 5 "Pick the hub, or type its address."
ok    type "Hub address" "http://localhost:4982"
ok    click "Pair"
ok    wait 60 "Waiting for the hub to approve…"
ok    snap c11-again-code
ok    wait 120 "This Mac is connected as"
ok    snap c11-again-approved
ok    click "Close"
ok    gone 5 "Pick the hub, or type its address."
ok    wait 90 "Connected to the hub at"
ok    absent "removed"
```

### collector-reconfigure: 23 of 23 steps passed

```
ok    wait 40 "The collector is running"
ok    wait 60 "Connected to the hub at"
ok    click "Reconfigure…"
ok    wait 60 "What this Mac does"
ok    expect "Step 1 of 4"
ok    click "Continue"
ok    wait "Claude folders to include"
ok    click "Continue"
ok    wait "Hubs on your network"
ok    expect "This Mac is paired with the hub at"
ok    enabled "Continue"
ok    snap c12-reconfigure-hub
ok    click "Continue"
ok    wait "This Mac"
ok    expect "stays paired with"
ok    snap c12-reconfigure-review
ok    click "Start the collector"
ok    wait 10 "Setting up…"
ok    wait 120 "The collector is running"
ok    wait 60 "Connected to the hub at"
ok    absent "Waiting for the hub to approve"
ok    absent "did not pair"
ok    snap c12-reconfigured
```

### collector-remove: 10 of 10 steps passed

```
ok    wait 40 "The collector is running"
ok    press "Remove VitalAIze…"
ok    wait 5 "Remove VitalAIze from this Mac?"
ok    snap c13-remove-sheet
ok    press "Remove"
ok    wait 60 "VitalAIze was removed from this Mac"
ok    expect "Stopping the collector"
ok    snap c13-removed
ok    click "Set up again"
ok    wait 90 "What this Mac does"
```

### Checked from outside the app

- ok: the board answers
- ok: the collector runs although the board would not pair
- ok: the hub answers
- ok: the hub's mailbox gets the request
- ok: the code in the hub's mailbox is the one the app shows
- ok: Approve in the mailbox
- ok: the collector's login item runs
- ok: the collector opened no board
- ok: the collector says it is sending to the hub
- ok: the collector's link to the hub is up
- ok: the hub's mailbox gets the second request
- ok: the second code matches too
- ok: Refuse in the mailbox
- ok: the collector still runs after a refused pairing
- ok: the hub's mailbox gets the third request
- ok: Approve the third code in the mailbox
- ok: the collector took up the new certificate without a restart
- ok: and its link to the hub is up
- ok: after Reconfigure the collector still runs
- ok: and its link to the hub is up again
- ok: after Remove the collector's login item is gone


## pair-timeout

### collector-timeout: 17 of 17 steps passed

```
ok    wait 90 "What this Mac does"
ok    click "Collector only"
ok    click "Continue"
ok    wait "Claude folders to include"
ok    click "Continue"
ok    wait "Hubs on your network"
ok    type "Hub address" "http://localhost:4990"
ok    click "Continue"
ok    wait "This Mac"
ok    click "Start the collector and pair"
ok    wait 90 "Waiting for the hub to approve…"
ok    expect "expires in 10 minutes"
ok    snap t01-code
ok    wait 700 "The collector is set up, but it did not pair. Nobody approved the code in time."
ok    wait 30 "The collector is running"
ok    wait 30 "Not paired with a hub yet, so nothing is sent."
ok    snap t02-timed-out
```

### Checked from outside the app

- ok: the hub answers
- ok: the collector runs although it is not paired
- ok: nothing was saved as a pairing
