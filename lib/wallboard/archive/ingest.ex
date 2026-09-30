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

  Codex sessions come the same way, from a Codex Stop and SessionEnd hook
  (see `codex_upload_script/2`), with `tool=codex`: one session's
  rollout file, its helper agents' rollout files, and optionally its lines
  from Codex's session_index.jsonl. They are read with the same reader as
  this Mac's own Codex sessions.
  """

  alias Wallboard.Archive.{CodexTranscript, Collector}
  alias Wallboard.Sources.Claude
  alias Wallboard.Store

  @session ~r/\A([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.jsonl\z/
  @sub ~r/\A([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\/subagents\/([A-Za-z0-9._-]+\.(?:jsonl|meta\.json))\z/
  @rollout ~r/\Arollout-[0-9A-Za-z-]{1,40}-([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.jsonl\z/
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
  True for a machine or account name safe to use in a folder name. A name
  of only dots is not one: "." and ".." would reach outside the inbox.
  """
  def valid_name?(name) when is_binary(name),
    do: name =~ @name and String.trim(name, ".") != ""

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

  @doc """
  Saves one uploaded Codex session: its rollout file, the rollout files of
  the helper agents it started, and optionally its lines from Codex's
  session_index.jsonl (for its title). Returns {:ok, thread_id} or
  {:error, reason}.
  """
  def receive_codex(gzip_tar, machine, account, settings) do
    with true <- valid_name?(machine) || {:error, "bad machine name"},
         true <- valid_name?(account) || {:error, "bad account name"},
         {:ok, files} <- unpack(gzip_tar),
         {:ok, up} <- sort_codex_files(files) do
      dir = Path.join([Path.dirname(settings.archive.path), "inbox", machine, account])
      File.mkdir_p!(dir)
      {main_name, main} = up.main
      main_path = Path.join(dir, main_name)
      File.write!(main_path, main)

      helpers =
        for {name, body, nickname} <- up.helpers do
          path = Path.join(dir, name)
          File.write!(path, body)
          {path, nickname}
        end

      ctx = %{
        prices: settings.usage.prices,
        machine: machine,
        account: Collector.codex_account(account),
        # The id checked above, whatever later lines of the file say.
        session_id: up.id,
        title: up.title,
        size: byte_size(gzip_tar),
        mtime: System.os_time(:second),
        now: System.os_time(:second)
      }

      if Collector.save_codex(main_path, helpers, ctx),
        do: {:ok, up.id},
        else: {:ok, :empty}
    end
  end

  @doc false
  def sort_codex_files(files) do
    {index, rest} = Enum.split_with(files, fn {name, _} -> name == "session_index.jsonl" end)

    threads =
      for {name, body} <- rest,
          [_, id] <- [Regex.run(@rollout, name)],
          do: {name, id, body, CodexTranscript.head_of(body)}

    cond do
      length(threads) != length(rest) or length(index) > 1 ->
        {:error, "unexpected files in the upload"}

      # The id in a file's name is the one inside it.
      not Enum.all?(threads, fn {_, id, _, head} -> match?({^id, _, _}, head) end) ->
        {:error, "not a Codex session file"}

      true ->
        case Enum.split_with(threads, fn {_, _, _, {_, parent, _}} -> is_nil(parent) end) do
          {[{name, id, body, _}], helpers} ->
            if Enum.all?(helpers, fn {_, _, _, {_, parent, _}} -> parent == id end) do
              {:ok,
               %{
                 id: id,
                 main: {name, body},
                 helpers: for({n, _, b, {_, _, nick}} <- helpers, do: {n, b, nick}),
                 title: codex_title(index, id)
               }}
            else
              {:error, "helper threads from another session"}
            end

          _ ->
            {:error, "expected exactly one Codex session"}
        end
    end
  end

  # When a thread has more than one line, the last one wins, as in
  # Collector.codex_titles/1.
  defp codex_title([{_, text}], id) do
    for line <- String.split(text, "\n", trim: true),
        {:ok, %{"id" => ^id, "thread_name" => name}} <- [Jason.decode(line)],
        is_binary(name) and name != "",
        reduce: nil do
      _ -> name
    end
  end

  defp codex_title(_, _id), do: nil

  # ---------------------------------------------------------------------------
  # What the other Mac runs

  @doc """
  The script another Mac saves as ~/.claude/wallboard-upload.sh. Claude
  Code runs it (in the background) when a turn ends and when a session
  ends, with the hook's JSON on stdin. It sends at most once a minute per
  session while the session runs, and always at the end.
  """
  def upload_script(hub_url, token) do
    """
    #!/bin/sh
    # Sends this Claude session's transcript to the wallboard at #{hub_url}.
    # Claude Code runs this from a Stop and a SessionEnd hook. It never
    # blocks Claude: the hook runs in the background, and a failed send is
    # simply tried again at the next turn.
    HUB="#{hub_url}"
    KEY="#{token}"

    input=$(cat)
    path=$(printf '%s' "$input" | sed -n 's/.*"transcript_path":"\\([^"]*\\)".*/\\1/p')
    [ -f "$path" ] || exit 0

    session=$(basename "$path" .jsonl)
    marker="${TMPDIR:-/tmp}/wallboard-sent-$session"
    case "$input" in
      *'"hook_event_name":"SessionEnd"'*) ;;
      *) [ -n "$(find "$marker" -mmin -1 2>/dev/null)" ] && exit 0 ;;
    esac
    touch "$marker"

    machine=$(scutil --get LocalHostName 2>/dev/null || hostname -s)
    machine=$(printf '%s' "$machine" | tr -c 'A-Za-z0-9._-' '-' | cut -c1-64)
    account=$(basename "${CLAUDE_CONFIG_DIR:-$HOME/.claude}")
    account=$(printf '%s' "$account" | tr -c 'A-Za-z0-9._-' '-' | cut -c1-64)

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
  The script another machine saves as ~/.codex/wallboard-upload.sh. Codex
  runs it when a turn ends and when a session ends, with the hook's JSON on
  stdin. It sends the session's rollout file, the rollout files of the
  helper agents it started, and the session's lines from
  session_index.jsonl (its title).

  Checked against codex-cli 0.155.1 (2026-09-30):

    * Codex runs even an `async` hook in the foreground (it logs "running
      async ... hook synchronously"), so the script answers at once and
      sends from the background.
    * Codex reads a Stop hook's output as JSON, so it prints an empty
      object.
    * A Codex Desktop thread can stay open for days with no SessionEnd, so
      a Stop inside the one-minute window is not dropped: one send waits
      for the window to pass, so the last turn still arrives.
    * A helper agent's thread has its own rollout file whose first line
      names its parent, and the parent's file names each helper as
      `"agent_thread_id"`. Archived threads move to archived_sessions/.
  """
  def codex_upload_script(hub_url, token) do
    """
    #!/bin/sh
    # Sends this Codex session, with the helper agents it started, to the
    # wallboard at #{hub_url}. Codex runs this from a Stop and a SessionEnd
    # hook. It answers Codex at once and sends from the background, so
    # Codex never waits on it.
    HUB="#{hub_url}"
    KEY="#{token}"
    # How long a turn that ends within a minute of the last send waits
    # before it is sent. Tests shorten it.
    WAIT="${WALLBOARD_WAIT_SECONDS:-60}"

    # Codex reads a Stop hook's output as JSON.
    echo '{}'

    input=$(cat)
    path=$(printf '%s' "$input" | sed -n 's/.*"transcript_path"[[:space:]]*:[[:space:]]*"\\([^"]*\\)".*/\\1/p')
    [ -f "$path" ] || exit 0
    # A helper agent's thread goes up with the session that started it.
    head -n 1 "$path" | grep -q '"parent_thread_id":"' && exit 0

    id=$(basename "$path" .jsonl | sed -n 's/.*\\([0-9a-f]\\{8\\}-[0-9a-f]\\{4\\}-[0-9a-f]\\{4\\}-[0-9a-f]\\{4\\}-[0-9a-f]\\{12\\}\\)$/\\1/p')
    [ -n "$id" ] || exit 0
    event=$(printf '%s' "$input" | sed -n 's/.*"hook_event_name"[[:space:]]*:[[:space:]]*"\\([A-Za-z]*\\)".*/\\1/p')

    # The file is in <codex home>/sessions/YYYY/MM/DD/, or in
    # <codex home>/archived_sessions/ once the thread is archived.
    day=$(dirname "$path")
    case "$day" in
      */archived_sessions) home=$(dirname "$day") ;;
      */sessions/*/*/*) home=$(dirname "$(dirname "$(dirname "$(dirname "$day")")")") ;;
      *) exit 0 ;;
    esac

    marker="${TMPDIR:-/tmp}/wallboard-sent-$id"
    waiting="$marker.waiting"

    send() {
      touch "$marker"
      machine=$(scutil --get LocalHostName 2>/dev/null || hostname -s)
      machine=$(printf '%s' "$machine" | tr -c 'A-Za-z0-9._-' '-' | cut -c1-64)
      account=$(basename "$home")
      account=$(printf '%s' "$account" | tr -c 'A-Za-z0-9._-' '-' | cut -c1-64)

      set -- -C "$day" "$(basename "$path")"
      for kid in $(grep -o '"agent_thread_id":"[0-9a-f-]*"' "$path" | cut -d'"' -f4 | sort -u); do
        for f in "$home"/sessions/*/*/*/rollout-*-"$kid".jsonl "$home"/archived_sessions/rollout-*-"$kid".jsonl; do
          [ -f "$f" ] || continue
          head -n 1 "$f" | grep -q '"parent_thread_id":"'"$id"'"' || continue
          set -- "$@" -C "$(dirname "$f")" "$(basename "$f")"
        done
      done

      stage=$(mktemp -d "${TMPDIR:-/tmp}/wallboard.XXXXXX") || return
      if grep '"id":"'"$id"'"' "$home/session_index.jsonl" > "$stage/session_index.jsonl" 2>/dev/null; then
        set -- "$@" -C "$stage" session_index.jsonl
      fi
      # COPYFILE_DISABLE keeps macOS tar from adding "._" attribute files.
      # GNU tar exits 1 when a file grew while it was read (a helper still
      # at work); the archive is whole, so it is sent anyway.
      COPYFILE_DISABLE=1 tar -czf "$stage/up.tgz" "$@"
      if [ $? -le 1 ]; then
        curl -fsS --max-time 120 -X POST \\
          -H "Authorization: Bearer $KEY" \\
          -H "Content-Type: application/gzip" \\
          --data-binary @"$stage/up.tgz" \\
          "$HUB/ingest/transcript?tool=codex&machine=$machine&account=$account"
      fi
      rm -rf "$stage"
    }

    (
      if [ "$event" != "SessionEnd" ] && [ -n "$(find "$marker" -mmin -1 2>/dev/null)" ]; then
        # Sent less than a minute ago: send again once the minute is up.
        # One waiting send per session is enough.
        [ -e "$waiting" ] && exit 0
        touch "$waiting"
        sleep "$WAIT"
        rm -f "$waiting"
      fi
      send
    ) </dev/null >/dev/null 2>&1 &
    exit 0
    """
  end

  @doc """
  What another machine runs once to connect: saves the Claude upload script
  and adds its two hooks to Claude's settings, and when Codex is there,
  does the same for Codex's hooks.json. Each file is backed up first.

  Codex skips a new hook until the person trusts it with /hooks in Codex,
  so the script says to do that. It never marks the hooks trusted itself.
  """
  def install_script(hub_url, token) do
    """
    #!/bin/sh
    # Connects this machine's Claude Code and Codex to the wallboard at #{hub_url}.
    set -e

    # Adds a Stop and a SessionEnd hook running $2 to the hooks file $1
    # (Claude's settings.json or Codex's hooks.json), after backing it up.
    # The first backup is kept, so connecting again never replaces it.
    # On a Mac, osascript's JavaScript edits the file with no other tool.
    # Elsewhere (Linux), python3 does the same edit.
    add_hooks() {
      [ -f "$1" ] || echo '{}' > "$1"
      [ -f "$1.before-wallboard" ] || cp "$1" "$1.before-wallboard"
      if ! command -v osascript >/dev/null 2>&1; then
        command -v python3 >/dev/null 2>&1 || { echo "Needs python3 to edit $1." >&2; exit 1; }
        python3 - "$1" "$2" <<'WALLBOARD_PY'
    import json, os, sys
    path, script = sys.argv[1], sys.argv[2]
    raw = open(path).read().strip()
    s = json.loads(raw) if raw else {}
    hooks = s.setdefault("hooks", {})
    hook = {"type": "command", "command": script, "async": True, "timeout": 120}
    for ev in ("Stop", "SessionEnd"):
        lst = hooks.setdefault(ev, [])
        if not any(h.get("command") == script for m in lst for h in m.get("hooks", [])):
            lst.append({"hooks": [hook]})
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        f.write(json.dumps(s, indent=2) + "\\n")
    os.replace(tmp, path)
    WALLBOARD_PY
        return
      fi
      osascript -l JavaScript - "$1" "$2" <<'WALLBOARD_JS'
    ObjC.import("Foundation");
    function run(argv) {
      const file = argv[0], script = argv[1];
      const text = $.NSString.stringWithContentsOfFileEncodingError(file, $.NSUTF8StringEncoding, null);
      const raw = text.isNil() ? "" : text.js.trim();
      const s = raw === "" ? {} : JSON.parse(raw);
      s.hooks = s.hooks || {};
      const hook = { type: "command", command: script, async: true, timeout: 120 };
      for (const ev of ["Stop", "SessionEnd"]) {
        const list = s.hooks[ev] = s.hooks[ev] || [];
        const has = list.some(m => (m.hooks || []).some(h => h.command === script));
        if (!has) list.push({ hooks: [hook] });
      }
      const out = $(JSON.stringify(s, null, 2) + "\\n");
      if (!out.writeToFileAtomicallyEncodingError(file, true, $.NSUTF8StringEncoding, null)) {
        throw new Error("could not write " + file);
      }
    }
    WALLBOARD_JS
    }

    CONF="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
    mkdir -p "$CONF"
    SCRIPT="$CONF/wallboard-upload.sh"
    cat > "$SCRIPT" <<'WALLBOARD_UPLOAD'
    #{upload_script(hub_url, token)}WALLBOARD_UPLOAD
    chmod 700 "$SCRIPT"
    add_hooks "$CONF/settings.json" "$SCRIPT"
    echo "Connected. Claude sessions on this machine now go to #{hub_url}."
    echo "Your previous Claude settings are in $CONF/settings.json.before-wallboard."

    CODEX="${CODEX_HOME:-$HOME/.codex}"
    if [ -d "$CODEX" ]; then
      CODEX_SCRIPT="$CODEX/wallboard-upload.sh"
      cat > "$CODEX_SCRIPT" <<'WALLBOARD_CODEX_UPLOAD'
    #{codex_upload_script(hub_url, token)}WALLBOARD_CODEX_UPLOAD
      chmod 700 "$CODEX_SCRIPT"
      add_hooks "$CODEX/hooks.json" "$CODEX_SCRIPT"
      echo "Codex sessions on this machine go there too, once you trust the new hooks:"
      echo "type /hooks in Codex and trust the two wallboard-upload.sh hooks. Codex skips a new hook until then."
      echo "Your previous Codex hooks are in $CODEX/hooks.json.before-wallboard."
    fi
    """
  end
end
