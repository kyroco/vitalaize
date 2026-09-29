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
  @name ~r/^[A-Za-z0-9._-]{1,64}$/

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

  @doc "True for a machine or account name safe to use in a folder name."
  def valid_name?(name) when is_binary(name), do: name =~ @name
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
  What another Mac runs once to connect: saves the upload script and adds
  the two hooks to that Mac's Claude settings (after backing them up).
  """
  def install_script(hub_url, token) do
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
    cp "$SETTINGS" "$SETTINGS.before-wallboard"
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
    for ev in ("Stop", "SessionEnd"):
        lst = hooks.setdefault(ev, [])
        if not any(h.get("command") == script for m in lst for h in m.get("hooks", [])):
            lst.append({"hooks": [hook]})
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
    echo "Connected. Claude sessions on this Mac now go to #{hub_url}."
    echo "Your previous settings are in $SETTINGS.before-wallboard."
    """
  end
end
