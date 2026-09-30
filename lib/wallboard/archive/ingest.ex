defmodule Wallboard.Archive.Ingest do
  @moduledoc """
  Sessions sent by other Macs. Each one runs a small hook script (see
  `upload_script/2`) that, when a Claude turn ends and when the session
  ends, sends that session's transcript and its subagents' as a .tar.gz.
  This board reads them with the same reader as its own transcripts, so
  every Mac's sessions carry the same numbers.

  Why transcripts and not Claude Code's own telemetry: telemetry has no
  tool replies (so no Korium hits or misses), and on the hub Mac it sent
  nothing at all when tried (2026-09-29). Hooks worked, and a transcript
  holds everything.

  Every upload needs this board's ingest key (made on first use, kept in
  the database, shown on the settings page). Uploaded files are checked by
  name before anything is written: one `<session id>.jsonl` and its
  `<session id>/subagents/` files, nothing else. They are kept under the
  database's folder, in inbox/<machine>/<account>/, so Refresh can read
  them again.
  """

  alias Wallboard.Archive.Collector
  alias Wallboard.Sources.Claude
  alias Wallboard.Store

  @session ~r/^([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.jsonl$/
  @sub ~r/^([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\/subagents\/([A-Za-z0-9._-]+\.(?:jsonl|meta\.json))$/
  @name ~r/\A[A-Za-z0-9._-]{1,64}\z/

  @doc "The key other Macs send with each upload. Made once, then kept."
  def token do
    case Store.get_meta("ingest_token") do
      t when is_binary(t) ->
        t

      _ ->
        t = 24 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
        Store.put_meta("ingest_token", t)
        t
    end
  end

  @doc "True when `given` is this board's ingest key."
  def valid_token?(given) when is_binary(given), do: Plug.Crypto.secure_compare(given, token())
  def valid_token?(_), do: false

  @doc """
  True for a machine or account name safe to use in a folder name: never
  "." or "..", and nothing after the name, not even a newline.
  """
  def valid_name?(name) when is_binary(name), do: name =~ @name and name not in [".", ".."]
  def valid_name?(_), do: false

  @doc """
  Saves one uploaded session. Returns {:ok, session_id} or {:error, reason}.
  """
  def receive(gzip_tar, machine, account, settings) do
    with true <- valid_name?(machine) || {:error, "bad machine name"},
         true <- valid_name?(account) || {:error, "bad account name"},
         {:ok, files} <- unpack(gzip_tar),
         {:ok, sid, main, subs} <- sort_files(files) do
      dir = Path.join([Path.dirname(settings.archive.path), "inbox", machine, account])
      main_path = Path.join(dir, sid <> ".jsonl")
      File.mkdir_p!(Path.join([dir, sid, "subagents"]))
      File.write!(main_path, main)

      sub_paths =
        for {file, body} <- subs do
          path = Path.join([dir, sid, "subagents", file])
          File.write!(path, body)
          path
        end

      ctx = %{
        prices: settings.usage.prices,
        machine: machine,
        account: Claude.account_label(account),
        size: byte_size(gzip_tar),
        mtime: System.os_time(:second),
        now: System.os_time(:second)
      }

      jsonl = Enum.filter(sub_paths, &String.ends_with?(&1, ".jsonl"))

      if Collector.save_session(main_path, jsonl, ctx),
        do: {:ok, sid},
        else: {:ok, :empty}
    end
  end

  # Reads the whole archive in memory, so no uploaded path ever touches disk
  # before it is checked.
  defp unpack(bin) do
    case :erl_tar.extract({:binary, bin}, [:compressed, :memory]) do
      {:ok, files} ->
        # macOS tar can add a "._" companion file holding each file's
        # extended attributes; those are not part of the session.
        kept =
          for {name, body} <- files,
              name = to_string(name),
              not String.starts_with?(Path.basename(name), "._"),
              do: {name, body}

        {:ok, kept}

      {:error, _} ->
        {:error, "not a .tar.gz"}
    end
  end

  @doc false
  def sort_files(files) do
    mains = for {name, body} <- files, [_, sid] <- [Regex.run(@session, name)], do: {sid, body}

    subs =
      for {name, body} <- files, [_, sid, file] <- [Regex.run(@sub, name)], do: {sid, file, body}

    other = length(files) - length(mains) - length(subs)

    case mains do
      [{sid, body}] when other == 0 ->
        if Enum.all?(subs, fn {s, _, _} -> s == sid end),
          do: {:ok, sid, body, Enum.map(subs, fn {_, f, b} -> {f, b} end)},
          else: {:error, "subagent files from another session"}

      [_] ->
        {:error, "unexpected files in the upload"}

      _ ->
        {:error, "expected exactly one session transcript"}
    end
  end

  # ---------------------------------------------------------------------------
  # What the other Mac runs

  @doc """
  The Claude Code hooks the upload script runs from, as
  [%{"event" => name, "matcher" => matcher or nil}]. Stop and SessionEnd
  send the transcript; the rest tell the hub the moment a session starts
  or stops waiting on you (see Wallboard.Remote). The Mac app adds the same
  list in macos/Wallboard/Setup.swift.
  """
  def hooks do
    [
      %{"event" => "Stop", "matcher" => nil},
      %{"event" => "SessionEnd", "matcher" => nil},
      %{
        "event" => "Notification",
        "matcher" =>
          "permission_prompt|elicitation_dialog|elicitation_url_dialog|agent_needs_input"
      },
      %{"event" => "PreToolUse", "matcher" => "AskUserQuestion"},
      %{"event" => "PostToolUse", "matcher" => nil},
      %{"event" => "UserPromptSubmit", "matcher" => nil}
    ]
  end

  @doc """
  The script another Mac saves as ~/.claude/wallboard-upload.sh. Claude
  Code runs it in the background from each hook in `hooks/0`, with the
  hook's JSON on stdin.

  When a session starts waiting on you (a permission prompt, a question, an
  MCP form), it posts that hook's JSON to /ingest/status right away and
  leaves a marker file saying which wait it is: the question's tool call,
  or a notice from the session or from one helper agent. When that wait
  ends (its tool finished, you typed, the turn or session ended) it posts a
  short "done waiting", and keeps the marker to try again if the hub did
  not take it. Every other tool call costs one file check and no network.

  When a turn ends and when a session ends it sends the transcript: at most
  once a minute per session while the session runs, and always at the end.
  """
  def upload_script(hub_url, token) do
    """
    #!/bin/sh
    # Sends this Claude session's transcript to the wallboard at #{hub_url},
    # and tells it the moment the session starts or stops waiting on you.
    # Claude Code runs this from its hooks in the background, so it never
    # blocks Claude, and a hub it cannot reach costs at most a few seconds
    # of this script's own time. A failed send is tried again next time.
    HUB="#{hub_url}"
    KEY="#{token}"

    input=$(cat)
    # The first "name":"value" in the hook's JSON, looked for in the first
    # 4 KB and then in the rest. Claude writes the hook's own fields before
    # any tool input or output, and quotes inside a value are escaped, so a
    # value cannot pose as a field.
    field() {
      v=$(printf '%s' "$input" | head -c 4096 | grep -o '"'"$1"'":"[^"]*"' | head -n 1)
      [ -n "$v" ] || v=$(printf '%s' "$input" | grep -o '"'"$1"'":"[^"]*"' | head -n 1)
      printf '%s' "$v" | sed 's/^"[^"]*":"//; s/"$//'
    }
    # Milliseconds, so the hub can put "waiting" and "done waiting" back in
    # order when they arrive the other way round.
    now_ms() {
      t=$(perl -MTime::HiRes=time -e 'printf("%d", time() * 1000)' 2>/dev/null)
      [ -n "$t" ] || t=$(date +%s%3N 2>/dev/null)
      case "$t" in ''|*[!0-9]*) t="$(date +%s)000" ;; esac
      printf '%s' "$t"
    }

    event=$(field hook_event_name)
    session=$(field session_id)
    case "$session" in ''|*[!A-Za-z0-9-]*) exit 0 ;; esac
    waiting="${TMPDIR:-/tmp}/wallboard-waiting-$session"

    # Which wait this is. The time is taken before the marker is written,
    # and a "done waiting" takes its time after reading the marker, so the
    # end of a wait is always later than its start.
    case "$event" in
      Notification)
        at=$(now_ms)
        printf 'notice:%s' "$(field agent_id)" > "$waiting" ;;
      PreToolUse)
        [ "$(field tool_name)" = AskUserQuestion ] || exit 0
        at=$(now_ms)
        printf 'tool:%s' "$(field tool_use_id)" > "$waiting" ;;
      PostToolUse)
        # Only the end of the wait's own tool call, or a tool call by the
        # same agent after a permission prompt: a helper agent or another
        # tool finishing meanwhile leaves the wait on.
        [ -f "$waiting" ] || exit 0
        case "$(cat "$waiting" 2>/dev/null)" in
          "notice:$(field agent_id)"|"tool:$(field tool_use_id)") ;;
          *) exit 0 ;;
        esac
        at=$(now_ms) ;;
      UserPromptSubmit)
        [ -f "$waiting" ] || exit 0
        at=$(now_ms) ;;
      Stop|SessionEnd)
        at=$(now_ms) ;;
      *)
        exit 0 ;;
    esac

    machine=$(scutil --get LocalHostName 2>/dev/null || hostname -s)
    machine=$(printf '%s' "$machine" | tr -c 'A-Za-z0-9._-' '-' | cut -c1-64)
    account=$(basename "${CLAUDE_CONFIG_DIR:-$HOME/.claude}")
    account=$(printf '%s' "$account" | tr -c 'A-Za-z0-9._-' '-' | cut -c1-64)

    send_status() {
      curl -fsS --connect-timeout 3 --max-time 10 -X POST \\
        -H "Authorization: Bearer $KEY" \\
        -H "Content-Type: application/json" \\
        --data-binary @- \\
        "$HUB/ingest/status?machine=$machine&account=$account&at=$at" >/dev/null 2>&1
    }
    # Claims the marker, sends "done waiting", and puts the marker back when
    # the hub did not take it (unless a new wait began meanwhile), so the
    # next hook tries again.
    done_waiting() {
      claim="$waiting.$$"
      mv "$waiting" "$claim" 2>/dev/null || return 0
      if printf '{"hook_event_name":"%s","session_id":"%s"}' "$event" "$session" | send_status; then
        rm -f "$claim"
      elif [ -f "$waiting" ]; then
        rm -f "$claim"
      else
        mv "$claim" "$waiting"
      fi
    }

    case "$event" in
      Notification|PreToolUse)
        printf '%s' "$input" | send_status
        exit 0 ;;
      PostToolUse|UserPromptSubmit)
        done_waiting
        exit 0 ;;
      Stop|SessionEnd)
        done_waiting ;;
    esac

    path=$(field transcript_path)
    [ -f "$path" ] || exit 0

    session=$(basename "$path" .jsonl)
    marker="${TMPDIR:-/tmp}/wallboard-sent-$session"
    case "$event" in
      SessionEnd) ;;
      *) [ -n "$(find "$marker" -mmin -1 2>/dev/null)" ] && exit 0 ;;
    esac
    touch "$marker"

    dir=$(dirname "$path")
    tmp=$(mktemp "${TMPDIR:-/tmp}/wallboard.XXXXXX") || exit 0
    # COPYFILE_DISABLE keeps macOS tar from adding "._" attribute files.
    if [ -d "$dir/$session/subagents" ]; then
      COPYFILE_DISABLE=1 tar -czf "$tmp" -C "$dir" "$session.jsonl" "$session/subagents"
    else
      COPYFILE_DISABLE=1 tar -czf "$tmp" -C "$dir" "$session.jsonl"
    fi
    curl -fsS --max-time 120 -X POST \\
      -H "Authorization: Bearer $KEY" \\
      -H "Content-Type: application/gzip" \\
      --data-binary @"$tmp" \\
      "$HUB/ingest/transcript?machine=$machine&account=$account" >/dev/null 2>&1
    rm -f "$tmp"
    exit 0
    """
  end

  @doc """
  What another Mac runs once to connect: saves the upload script and adds
  its hooks (`hooks/0`) to that Mac's Claude settings, after backing them
  up. Running it again on a Mac connected before adds only the hooks it is
  missing.
  """
  def install_script(hub_url, token) do
    hooks = Jason.encode!(hooks())

    """
    #!/bin/sh
    # Connects this Mac's Claude Code to the wallboard at #{hub_url}.
    set -e
    CONF="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
    mkdir -p "$CONF"
    SCRIPT="$CONF/wallboard-upload.sh"
    cat > "$SCRIPT" <<'WALLBOARD_UPLOAD'
    #{upload_script(hub_url, token)}WALLBOARD_UPLOAD
    chmod 700 "$SCRIPT"

    SETTINGS="$CONF/settings.json"
    [ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
    # The first connect's backup is the one worth keeping.
    [ -f "$SETTINGS.before-wallboard" ] || cp "$SETTINGS" "$SETTINGS.before-wallboard"
    # On a Mac, osascript's JavaScript edits the settings with no other tool.
    # Elsewhere (Linux), python3 does the same edit.
    if ! command -v osascript >/dev/null 2>&1; then
      command -v python3 >/dev/null 2>&1 || { echo "Needs python3 to edit $SETTINGS." >&2; exit 1; }
      python3 - "$SETTINGS" "$SCRIPT" <<'WALLBOARD_PY'
    import json, os, sys
    path, script = sys.argv[1], sys.argv[2]
    raw = open(path).read().strip()
    s = json.loads(raw) if raw else {}
    hooks = s.setdefault("hooks", {})
    hook = {"type": "command", "command": script, "async": True, "timeout": 120}
    for want in json.loads('#{hooks}'):
        lst = hooks.setdefault(want["event"], [])
        if not any(h.get("command") == script for m in lst for h in m.get("hooks", [])):
            entry = {"hooks": [hook]}
            if want["matcher"]:
                entry["matcher"] = want["matcher"]
            lst.append(entry)
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        f.write(json.dumps(s, indent=2) + "\\n")
    os.replace(tmp, path)
    WALLBOARD_PY
      echo "Connected. Claude sessions on this machine now go to #{hub_url}."
      echo "Your previous settings are in $SETTINGS.before-wallboard."
      exit 0
    fi
    osascript -l JavaScript - "$SETTINGS" "$SCRIPT" <<'WALLBOARD_JS'
    ObjC.import("Foundation");
    function run(argv) {
      const file = argv[0], script = argv[1];
      const text = $.NSString.stringWithContentsOfFileEncodingError(file, $.NSUTF8StringEncoding, null);
      const raw = text.isNil() ? "" : text.js.trim();
      const s = raw === "" ? {} : JSON.parse(raw);
      s.hooks = s.hooks || {};
      const hook = { type: "command", command: script, async: true, timeout: 120 };
      for (const want of #{hooks}) {
        const list = s.hooks[want.event] = s.hooks[want.event] || [];
        const has = list.some(m => (m.hooks || []).some(h => h.command === script));
        if (!has) list.push(want.matcher ? { matcher: want.matcher, hooks: [hook] } : { hooks: [hook] });
      }
      const out = $(JSON.stringify(s, null, 2) + "\\n");
      if (!out.writeToFileAtomicallyEncodingError(file, true, $.NSUTF8StringEncoding, null)) {
        throw new Error("could not write " + file);
      }
    }
    WALLBOARD_JS
    echo "Connected. Claude sessions on this Mac now go to #{hub_url}."
    echo "Your previous settings are in $SETTINGS.before-wallboard."
    """
  end
end
