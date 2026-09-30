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

  Every upload is signed with the sending machine's own key (see
  Wallboard.Archive.MachineKeys), and is refused when it would unpack to
  more than `max_unpacked/0`, before it takes that memory. It is unpacked
  into a file of its own in a folder only this user can open (`incoming/`
  beside the database), so only the files it holds are ever in memory, once;
  that file is removed straight after, and any left by a board that stopped
  mid-upload are removed at start. Uploaded files are checked by
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

  alias Wallboard.Archive.{CodexTranscript, Collector, MachineKeys, UploadGate}
  alias Wallboard.Sources.Claude

  @session ~r/\A([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.jsonl\z/
  @sub ~r/\A([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\/subagents\/([A-Za-z0-9._-]+\.(?:jsonl|meta\.json))\z/
  @rollout ~r/\Arollout-[0-9A-Za-z-]{1,40}-([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.jsonl\z/
  @name ~r/\A[A-Za-z0-9._-]{1,64}\z/

  # The largest session this Mac holds is about 75 MB (2026-09-30), so this
  # leaves room for a long session and its subagents, while a small upload
  # that would unpack to gigabytes is stopped here.
  @max_unpacked 512_000_000

  @doc "The most an upload may unpack to, in bytes."
  def max_unpacked, do: Application.get_env(:wallboard, :max_unpacked, @max_unpacked)

  # Transcripts pack about ten to one, so an upload this size already
  # unpacks past the limit above; a larger one is refused before it is read.
  @max_upload 128_000_000

  @doc "The most an upload may be as sent (packed), in bytes."
  def max_upload, do: Application.get_env(:wallboard, :max_upload, @max_upload)

  @doc """
  True for a machine or account name safe to use in a folder name. A name
  of only dots is not one: "." and ".." would reach outside the inbox.
  Nothing may follow the name, not even a newline.
  """
  def valid_name?(name) when is_binary(name),
    do: name =~ @name and String.trim(name, ".") != ""

  def valid_name?(_), do: false

  @doc """
  Saves one uploaded session, given as a binary or as the pieces it was read
  in. Returns {:ok, session_id} or {:error, reason}.
  """
  def receive(gzip_tar, machine, account, settings) do
    with true <- valid_name?(machine) || {:error, "bad machine name"},
         true <- valid_name?(account) || {:error, "bad account name"},
         {:ok, files} <- unpack(gzip_tar, incoming(settings)),
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
        size: IO.iodata_length(gzip_tar),
        mtime: System.os_time(:second),
        now: System.os_time(:second)
      }

      jsonl = Enum.filter(sub_paths, &String.ends_with?(&1, ".jsonl"))

      if Collector.save_session(main_path, jsonl, ctx),
        do: {:ok, sid},
        else: {:ok, :empty}
    end
  end

  @doc """
  The folder uploads are unpacked in: `incoming/` beside the database.
  """
  def incoming(settings), do: Path.join(Path.dirname(settings.archive.path), "incoming")

  @doc """
  Removes what uploads under way left in `folder` when the board stopped.
  Run once at start, before any upload comes in (UploadGate).
  """
  def clear_incoming(folder) do
    for file <- Path.wildcard(Path.join(folder, "up-*")), do: File.rm(file)
    :ok
  end

  # Unpacks the upload (a binary, or the pieces it was read in) into a tar
  # file of its own in `folder`, a piece at a time, and stops as soon as it
  # passes the limit. The files are then read out of it into memory, where
  # they are checked by name before any is written anywhere else. Unpacking
  # to one binary instead takes twice the memory, and reading files out of
  # it more again.
  @doc false
  def unpack(body, folder \\ nil)

  # Without a folder (tests), one of its own, removed after.
  def unpack(body, nil) do
    folder = Path.join(System.tmp_dir!(), "wallboard-unpack-#{token()}")

    try do
      unpack(body, folder)
    after
      File.rm_rf(folder)
    end
  end

  def unpack(body, folder) do
    with {:ok, tar} <- private_file(folder) do
      try do
        with :ok <- gunzip(body, tar, max_unpacked()), do: untar(tar)
      after
        File.rm(tar)
      end
    end
  end

  defp token, do: 12 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)

  # A new file, made here and nowhere else, in a folder only this user can
  # open: the folder is made if need be, and must be a real folder.
  defp private_file(folder) do
    with :ok <- File.mkdir_p(folder),
         {:ok, %File.Stat{type: :directory}} <- File.lstat(folder),
         :ok <- File.chmod(folder, 0o700) do
      {:ok, Path.join(folder, "up-#{token()}")}
    else
      _ -> {:error, "the hub could not unpack the upload"}
    end
  end

  defp gunzip(body, path, limit) do
    z = :zlib.open()

    try do
      {:ok, file} = :file.open(path, [:write, :exclusive, :raw, :binary])

      try do
        # 31: a gzip header, as tar -z writes.
        :ok = :zlib.inflateInit(z, 31)
        inflate(z, file, :zlib.safeInflate(z, body), 0, limit)
      after
        :file.close(file)
      end
    rescue
      _ -> {:error, "not a .tar.gz"}
    catch
      _, _ -> {:error, "not a .tar.gz"}
    after
      :zlib.close(z)
    end
  end

  defp inflate(z, file, {status, out}, size, limit) when status in [:continue, :finished] do
    got = IO.iodata_length(out)
    size = size + got

    cond do
      size > limit ->
        {:error, :too_big}

      true ->
        :ok = :file.write(file, out)

        cond do
          status == :finished -> :ok
          # All the input is in and nothing more comes out: it was cut short.
          got == 0 -> {:error, "not a .tar.gz"}
          true -> inflate(z, file, :zlib.safeInflate(z, []), size, limit)
        end
    end
  end

  defp inflate(_z, _file, _other, _size, _limit), do: {:error, "not a .tar.gz"}

  defp untar(tar) do
    case :erl_tar.extract(String.to_charlist(tar), [:memory]) do
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
         {:ok, files} <- unpack(gzip_tar, incoming(settings)),
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
        size: IO.iodata_length(gzip_tar),
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
  The Codex hooks its upload script runs from: it sends transcripts only.
  The Mac app adds the same pair (codexHooks in Setup.swift).
  """
  def codex_hooks do
    [%{"event" => "Stop", "matcher" => nil}, %{"event" => "SessionEnd", "matcher" => nil}]
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

  No hook fires when you approve or deny a prompt or press Esc, so a
  waiting hook also starts one detached loop per session (the script run
  as `--watch <session>`). Every few seconds it asks `claude agents --json`
  whether the session still waits, the same check the hub makes for its
  own sessions, and posts "done waiting" once it has seen the session
  waiting and then not. Each wait's marker carries a stamp of its own, and
  the loop ends only the wait it saw, so a new prompt that opens during a
  check is never taken for the one just answered. While the loop runs, a
  finished tool call after a permission prompt is left for the loop to
  judge, since it may be a tool that ran beside the prompt: the hook leaves
  a note, and the loop ends the wait once `claude agents` says the session
  is not waiting, even if it was answered too fast to be seen waiting. The loop stops
  when the marker is gone, when the session never shows as waiting (or the
  check keeps failing) for about a minute, and after 12 hours at most.
  Without `claude` on the PATH, or perl, there is no loop and the hooks
  alone end the wait.

  When a turn ends and when a session ends it sends the transcript: at most
  once a minute per session while the session runs, and always at the end.

  Every request is signed with this machine's key, from the wallboard-key
  file the connect command leaves beside the script (see `signing/0`).
  Without that file it sends nothing.
  """
  def upload_script(hub_url) do
    """
    #!/bin/sh
    # Sends this Claude session's transcript to the wallboard at #{hub_url},
    # and tells it the moment the session starts or stops waiting on you.
    # Claude Code runs this from its hooks in the background, so it never
    # blocks Claude, and a hub it cannot reach costs at most a few seconds
    # of this script's own time. A failed send is tried again next time.
    HUB='#{hub_url}'
    #{signing()}
    # Without this machine's key there is nothing to send with. The hook's
    # JSON is still read, so Claude never writes to a closed pipe.
    if ! load_key; then
      [ "$1" = --watch ] || cat >/dev/null
      exit 0
    fi

    # Milliseconds, so the hub can put "waiting" and "done waiting" back in
    # order when they arrive the other way round.
    now_ms() {
      t=$(perl -MTime::HiRes=time -e 'printf("%d", time() * 1000)' 2>/dev/null)
      [ -n "$t" ] || t=$(date +%s%3N 2>/dev/null)
      case "$t" in ''|*[!0-9]*) t="$(date +%s)000" ;; esac
      printf '%s' "$t"
    }
    names() {
      account=$(basename "${CLAUDE_CONFIG_DIR:-$HOME/.claude}")
      account=$(printf '%s' "$account" | tr -c 'A-Za-z0-9._-' '-' | cut -c1-64)
    }
    # Posts the JSON on stdin as a status.
    send_status() {
      body=$(mktemp "${TMPDIR:-/tmp}/wallboard-status.XXXXXX") || return 1
      cat > "$body"
      signed_post "/ingest/status?machine=$machine&account=$account&at=$at" application/json "$body" \\
        -fsS --connect-timeout 3 --max-time 10 >/dev/null 2>&1
      sent=$?
      rm -f "$body"
      return $sent
    }
    # Claims the marker and sends "done waiting". Given the marker's words,
    # it ends only that wait: a newer one is put back untouched. When the
    # hub does not take it, the marker goes back so the next try sends it
    # again, and this fails. Putting back never overwrites a newer marker.
    done_waiting() {
      claim="$waiting.$$"
      mv "$waiting" "$claim" 2>/dev/null || return 0
      if [ -n "$1" ] && [ "$(cat "$claim" 2>/dev/null)" != "$1" ]; then
        mv -n "$claim" "$waiting" 2>/dev/null
        rm -f "$claim"
        return 0
      fi
      if printf '{"hook_event_name":"%s","session_id":"%s"}' "$event" "$session" | send_status; then
        rm -f "$claim"
      else
        mv -n "$claim" "$waiting" 2>/dev/null
        rm -f "$claim"
        return 1
      fi
    }
    # Writes the marker in one step: the kind of wait, then a stamp that is
    # new for every wait, so the loop can tell one wait from the next.
    mark_waiting() {
      printf '%s %s-%s' "$1" "$at" "$$" > "$waiting.new.$$" && mv -f "$waiting.new.$$" "$waiting"
    }
    # This session in `claude agents --json`: waiting, moved (running or
    # idle), gone, or unknown when the check fails. The check gets 20
    # seconds at most.
    agent_state() {
      out=$(perl -e 'alarm 20; exec @ARGV' claude agents --json 2>/dev/null) || { echo unknown; return; }
      printf '%s' "$out" | perl -MJSON::PP -e '
        my $d = eval { decode_json(join("", <STDIN>)) };
        ref($d) eq "ARRAY" or do { print "unknown"; exit };
        for my $a (@$d) {
          next unless ref($a) eq "HASH" && ($a->{sessionId} // "") eq $ARGV[0];
          my $w = ($a->{status} // "") eq "waiting" || ($a->{state} // "") eq "blocked";
          print $w ? "waiting" : "moved";
          exit;
        }
        print "gone";' "$session" 2>/dev/null || echo unknown
    }

    # Packs the session's transcript and its subagents' into $1, as they
    # are now. Packed again for each try, so a try that is late never
    # carries less than one sent before it: transcripts only grow.
    pack() {
      [ -f "$dir/$session.jsonl" ] || return 1
      # COPYFILE_DISABLE keeps macOS tar from adding "._" attribute files.
      if [ -d "$dir/$session/subagents" ]; then
        COPYFILE_DISABLE=1 tar -czf "$1" -C "$dir" "$session.jsonl" "$session/subagents"
      else
        COPYFILE_DISABLE=1 tar -czf "$1" -C "$dir" "$session.jsonl"
      fi
    }

    # A transcript sent from its own run (see the end of this script):
    # --send <folder> <session> <path?query>.
    if [ "$1" = --send ]; then
      dir=$2 session=$3
      case "$session" in ''|*[!A-Za-z0-9-]*) exit 0 ;; esac
      tmp=$(mktemp "${TMPDIR:-/tmp}/wallboard.XXXXXX") || exit 0
      send_upload "$4" pack "$tmp"
      rm -f "$tmp"
      exit 0
    fi

    # The loop a waiting hook starts: one per session, checking every few
    # seconds until the wait is over.
    if [ "$1" = --watch ]; then
      session=$2
      case "$session" in ''|*[!A-Za-z0-9-]*) exit 0 ;; esac
      waiting="${TMPDIR:-/tmp}/wallboard-waiting-$session"
      lock="$waiting.watch"
      event=WaitEnded
      every=${WALLBOARD_WATCH_EVERY:-3}
      limit=${WALLBOARD_WATCH_LIMIT:-43200}
      patience=${WALLBOARD_WATCH_PATIENCE:-60}
      # The lock is a link to the loop's process id, made in one step, so
      # it never exists without the id. A lock whose loop died is taken
      # over, and a loop removes the lock only while it is still its own.
      if ! ln -s "$$" "$lock" 2>/dev/null; then
        old=$(readlink "$lock" 2>/dev/null)
        [ -n "$old" ] && kill -0 "$old" 2>/dev/null && exit 0
        rm -f "$lock"
        ln -s "$$" "$lock" 2>/dev/null || exit 0
      fi
      trap '[ "$(readlink "$lock" 2>/dev/null)" = "$$" ] && rm -f "$lock"' EXIT
      trap 'exit 0' HUP INT TERM
      names
      start=$(date +%s)
      seen=""
      last=""
      misses=0
      while [ -f "$waiting" ] && [ $(( $(date +%s) - start )) -lt "$limit" ]; do
        # Waited on in the background, so a request to stop is heard at once.
        sleep "$every" &
        wait $!
        # The wait as it stood before the check. Only a wait seen waiting,
        # and still the same wait after the check, is ended here.
        before=$(cat "$waiting" 2>/dev/null) || continue
        [ "$before" = "$last" ] || { last=$before; misses=0; }
        case "$(agent_state)" in
          waiting)
            seen=$before ;;
          moved|gone)
            # Seen waiting and now not, or answered too fast to be seen: a
            # tool call by the waiting agent has finished since it began.
            if [ "$seen" = "$before" ] || [ "$(cat "$waiting.ran" 2>/dev/null)" = "$before" ]; then
              at=$(now_ms)
              done_waiting "$before" && { seen=""; rm -f "$waiting.ran"; }
            else
              misses=$((misses + 1))
            fi ;;
          *)
            misses=$((misses + 1)) ;;
        esac
        # A wait never seen waiting, or a check that keeps failing: nothing
        # here to watch, so the hooks end it.
        [ "$seen" = "$before" ] || [ $((misses * every)) -lt "$patience" ] || exit 0
      done
      # A new wait that began as this loop ended found the lock taken. The
      # lock goes first and the marker is looked at after, so either its
      # hook starts a loop or this one hands over to a fresh loop for it.
      [ "$(readlink "$lock" 2>/dev/null)" = "$$" ] && rm -f "$lock"
      if [ -f "$waiting" ] && [ $(( $(date +%s) - start )) -lt "$limit" ]; then
        exec sh "$0" --watch "$session"
      fi
      exit 0
    fi

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

    event=$(field hook_event_name)
    session=$(field session_id)
    case "$session" in ''|*[!A-Za-z0-9-]*) exit 0 ;; esac
    waiting="${TMPDIR:-/tmp}/wallboard-waiting-$session"

    # Which wait this is. The time is taken before the marker is written,
    # and a "done waiting" takes its time after reading the marker, so the
    # end of a wait is always later than its start.
    expect=""
    case "$event" in
      Notification)
        at=$(now_ms)
        mark_waiting "notice:$(field agent_id)" ;;
      PreToolUse)
        [ "$(field tool_name)" = AskUserQuestion ] || exit 0
        at=$(now_ms)
        mark_waiting "tool:$(field tool_use_id)" ;;
      PostToolUse)
        # The end of the question's own tool call ends its wait. After a
        # permission prompt, a tool call by the same agent may be one that
        # ran beside the prompt, so while the loop is watching it decides
        # from `claude agents`; without the loop, this is the best sign
        # there is. A helper agent or another tool finishing never counts.
        [ -f "$waiting" ] || exit 0
        expect=$(cat "$waiting" 2>/dev/null)
        case "${expect%% *}" in
          "tool:$(field tool_use_id)") ;;
          "notice:$(field agent_id)")
            loop=$(readlink "$waiting.watch" 2>/dev/null)
            if [ -n "$loop" ] && kill -0 "$loop" 2>/dev/null; then
              # Tell the loop a tool call finished during this wait.
              printf '%s' "$expect" > "$waiting.ran"
              exit 0
            fi ;;
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

    names

    case "$event" in
      Notification|PreToolUse)
        # The loop is started in its own session, with nothing tied to this
        # hook, so the hook returns at once and Claude never waits on it.
        if command -v claude >/dev/null 2>&1; then
          perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV' sh "$0" --watch "$session" \\
            </dev/null >/dev/null 2>&1 &
        fi
        printf '%s' "$input" | send_status
        exit 0 ;;
      PostToolUse|UserPromptSubmit)
        done_waiting "$expect"
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
    # Sent from a run of its own, detached like the loop, since trying again
    # can take a while and Claude stops a hook after two minutes.
    target="/ingest/transcript?machine=$machine&account=$account"
    if perl -MPOSIX -e 1 >/dev/null 2>&1; then
      perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV' sh "$0" --send "$dir" "$session" "$target" \\
        </dev/null >/dev/null 2>&1 &
    else
      (
        trap '' HUP
        tmp=$(mktemp "${TMPDIR:-/tmp}/wallboard.XXXXXX") || exit 0
        send_upload "$target" pack "$tmp"
        rm -f "$tmp"
      ) </dev/null >/dev/null 2>&1 &
    fi
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

  Like the Claude script, it signs each upload with this machine's key from
  the wallboard-key file beside it, and sends nothing without one.
  """
  def codex_upload_script(hub_url) do
    """
    #!/bin/sh
    # Sends this Codex session, with the helper agents it started, to the
    # wallboard at #{hub_url}. Codex runs this from a Stop and a SessionEnd
    # hook. It answers Codex at once and sends from the background, so
    # Codex never waits on it.
    HUB='#{hub_url}'
    # How long a turn that ends within a minute of the last send waits
    # before it is sent. Tests shorten it.
    WAIT="${WALLBOARD_WAIT_SECONDS:-60}"
    #{signing()}
    # Codex reads a Stop hook's output as JSON.
    echo '{}'

    # Without this machine's key there is nothing to send with. The hook's
    # JSON is still read, so Codex never writes to a closed pipe.
    load_key || { cat >/dev/null; exit 0; }

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

    account=$(basename "$home")
    account=$(printf '%s' "$account" | tr -c 'A-Za-z0-9._-' '-' | cut -c1-64)

    # Packs the session, its helpers' files and its title into $stage/up.tgz,
    # as they are now. Packed again for each try, so a try that is late
    # never carries less than one sent before it.
    pack() {
      # The thread may have been archived while this waited: Codex moves
      # its file, under the same name, to archived_sessions/.
      if [ ! -f "$path" ]; then
        path="$home/archived_sessions/$(basename "$path")"
        day=$(dirname "$path")
        [ -f "$path" ] || return 1
      fi

      set -- -C "$day" "$(basename "$path")"
      for kid in $(grep -o '"agent_thread_id":"[0-9a-f-]*"' "$path" | cut -d'"' -f4 | sort -u); do
        for f in "$home"/sessions/*/*/*/rollout-*-"$kid".jsonl "$home"/archived_sessions/rollout-*-"$kid".jsonl; do
          [ -f "$f" ] || continue
          head -n 1 "$f" | grep -q '"parent_thread_id":"'"$id"'"' || continue
          set -- "$@" -C "$(dirname "$f")" "$(basename "$f")"
        done
      done

      if grep '"id":"'"$id"'"' "$home/session_index.jsonl" > "$stage/session_index.jsonl" 2>/dev/null; then
        set -- "$@" -C "$stage" session_index.jsonl
      fi
      # COPYFILE_DISABLE keeps macOS tar from adding "._" attribute files.
      # GNU tar exits 1 when a file grew while it was read (a helper still
      # at work); the archive is whole, so it is sent anyway. macOS tar
      # also exits 1 for a file it could not read, so the archive must
      # still hold the session's own file.
      COPYFILE_DISABLE=1 tar -czf "$stage/up.tgz" "$@"
      [ $? -le 1 ] && tar -tzf "$stage/up.tgz" 2>/dev/null | grep -qxF "$(basename "$path")"
    }

    send() {
      touch "$marker"
      stage=$(mktemp -d "${TMPDIR:-/tmp}/wallboard.XXXXXX") || return
      send_upload "/ingest/transcript?tool=codex&machine=$machine&account=$account" pack "$stage/up.tgz"
      rm -rf "$stage"
    }

    (
      # Keep going if the terminal Codex ran in closes.
      trap '' HUP
      if [ "$event" != "SessionEnd" ] && [ -n "$(find "$marker" -mmin -1 2>/dev/null)" ]; then
        # Sent less than a minute ago: send again once the minute is up.
        # One waiting send per session is enough. A waiting file older
        # than two minutes was left by a send that was stopped, so it
        # does not count.
        [ -n "$(find "$waiting" -mmin -2 2>/dev/null)" ] && exit 0
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
  The shell functions that sign a request to the hub, shared by the
  scripts: `load_key` reads this machine's key from the wallboard-key file
  beside the script, `signed_post <path?query> <type> <body file> [curl
  options]` posts the file signed with $KEY_ID and $KEY, as
  MachineKeys.authenticate/1 checks it, and `send_upload <path?query>
  <pack command> <file>` packs an upload into the file and posts it the
  same way, packing it again for each of a few tries when the hub is busy,
  out of reach, or fails. perl's Digest::SHA makes the signature,
  or python3 where perl lacks it (a Mac always has the first; Linux
  collectors need python3 anyway). Either is handed the key in its
  environment, which other users of the machine cannot see, never as an
  argument, which they can.
  """
  def signing do
    String.replace(signing_text(), "MAX_TIME", to_string(curl_max_time()))
  end

  @doc """
  How long a collector's curl waits for an upload's answer, in seconds:
  longer than the hub's queue wait and read time together, with a minute
  to spare for unpacking and saving, so the hub answers first.
  """
  def curl_max_time, do: UploadGate.wait_seconds() + MachineKeys.upload_deadline() + 60

  defp signing_text do
    ~S"""
    # The HMAC-SHA256 of $2 with the key $1, in hex.
    hmac() {
      _h=$(printf '%s' "$2" | WALLBOARD_HMAC_KEY="$1" perl -MDigest::SHA=hmac_sha256_hex \
        -e 'local $/; print hmac_sha256_hex(scalar(<STDIN>), $ENV{WALLBOARD_HMAC_KEY})' 2>/dev/null) || _h=""
      case "$_h" in ''|*[!0-9a-f]*)
        _h=$(printf '%s' "$2" | WALLBOARD_HMAC_KEY="$1" python3 -c 'import hashlib, hmac, os, sys
    sys.stdout.write(hmac.new(os.environ["WALLBOARD_HMAC_KEY"].encode(), sys.stdin.buffer.read(), hashlib.sha256).hexdigest())' 2>/dev/null) || _h="" ;;
      esac
      printf '%s' "$_h"
    }
    # The SHA-256 of the file $1, in hex.
    sha256_of() {
      _h=$(perl -MDigest::SHA -e 'print Digest::SHA->new(256)->addfile($ARGV[0])->hexdigest' "$1" 2>/dev/null) || _h=""
      case "$_h" in ''|*[!0-9a-f]*)
        _h=$( (sha256sum || openssl dgst -sha256 -r) < "$1" 2>/dev/null | cut -c1-64) || _h="" ;;
      esac
      printf '%s' "$_h"
    }
    # This machine's key id, the machine name it was made for, and the key,
    # from the wallboard-key file connecting left beside this script.
    load_key() {
      _keys="$(dirname "$0")/wallboard-key"
      [ -r "$_keys" ] || return 1
      { read -r KEY_ID; read -r machine; read -r KEY; } < "$_keys"
      [ -n "$KEY" ]
    }
    # Posts the file $3, of type $2, to $1 on the hub, signed. The key itself
    # is never sent: the hub checks the signature with its own copy. The
    # body's SHA-256 goes in a signed header, so the hub checks the
    # signature before it reads the body.
    signed_post() {
      _target=$1 _type=$2 _file=$3
      shift 3
      _path=${_target%%\?*}
      _query=${_target#"$_path"}
      _query=${_query#\?}
      _time=$(date +%s)
      _nonce=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
      _body=$(sha256_of "$_file")
      _sig=$(hmac "$KEY" "$(printf 'vitalaize-v1\nPOST\n%s\n%s\n%s\n%s\n%s' \
        "$_path" "$_query" "$_time" "$_nonce" "$_body")")
      curl "$@" -X POST -H "Content-Type: $_type" -H "X-Vitalaize-Key: $KEY_ID" \
        -H "X-Vitalaize-Time: $_time" -H "X-Vitalaize-Nonce: $_nonce" \
        -H "X-Vitalaize-Content-SHA256: $_body" \
        -H "X-Vitalaize-Signature: $_sig" --data-binary @"$_file" "$HUB$_target"
    }
    # Runs `$2 $3` to pack the upload into the file $3, and posts it to $1,
    # packed and signed afresh each time. It tries again when the hub is
    # busy (503), out of reach or too slow (000, 408), or failed (500, 502,
    # 504): after 10, 30 and 90 seconds, so a session's last send is not
    # lost to a busy moment. It stops when there is nothing to pack.
    # curl gets longer than the hub's queue wait and read time together,
    # so it is the hub, not curl, that gives up first.
    # WALLBOARD_RETRY_WAITS changes the waits (tests).
    send_upload() {
      for _wait in ${WALLBOARD_RETRY_WAITS:-10 30 90} last; do
        "$2" "$3" || return 1
        _code=$(signed_post "$1" application/gzip "$3" -sS -o /dev/null -w '%{http_code}' \
          --connect-timeout 5 --max-time MAX_TIME 2>/dev/null) || _code=000
        case "$_code" in 000|408|500|502|503|504) ;; *) return 0 ;; esac
        [ "$_wait" = last ] && return 1
        sleep "$_wait"
      done
    }
    """
  end

  @doc """
  What another machine runs once to connect: saves the Claude upload script
  and adds its hooks (`hooks/0`) to Claude's settings, and when Codex is
  there, saves the Codex one and adds its two (`codex_hooks/0`) to Codex's
  hooks.json. Each file is backed up first. Running it again on a machine
  connected before adds only the hooks it is missing.

  Codex skips a new hook until the person trusts it with /hooks in Codex,
  so the script says to do that. It never marks the hooks trusted itself.

  The script holds no key. It asks for the connect key at a prompt that
  does not show it (or takes it from WALLBOARD_KEY, for scripts and
  tests), so the key is not left in shell history. It connects before it
  changes anything: it makes a
  random key id, sends the hub a request naming this machine and that id,
  signed with the connect key, and on the hub's yes works out this
  machine's own key from the two (MachineKeys.derive/2) and saves it in
  wallboard-key beside each upload script, readable only by this user. Run
  again, it replaces the key it made before.
  """
  def install_script(hub_url) do
    hooks = Jason.encode!(hooks())
    codex_hooks = Jason.encode!(codex_hooks())

    """
    #!/bin/sh
    # Connects this machine's Claude Code and Codex to the wallboard at #{hub_url}.
    set -e
    HUB='#{hub_url}'
    #{signing()}
    CONNECT_KEY="${WALLBOARD_KEY:-}"
    if [ -z "$CONNECT_KEY" ] && (: < /dev/tty) 2>/dev/null; then
      printf "Paste the connect key from the hub's Settings page (it stays hidden): " > /dev/tty
      # Ctrl-C at the prompt must not leave the terminal hiding what is typed.
      trap 'stty echo < /dev/tty 2>/dev/null; exit 130' INT TERM
      stty -echo < /dev/tty 2>/dev/null || true
      read -r CONNECT_KEY < /dev/tty || CONNECT_KEY=""
      stty echo < /dev/tty 2>/dev/null || true
      trap - INT TERM
      printf '\\n' > /dev/tty
    fi
    # Spaces or a line end pasted with the key are not part of it.
    CONNECT_KEY=$(printf '%s' "$CONNECT_KEY" | tr -d ' \\t\\r\\n')
    if [ -z "$CONNECT_KEY" ]; then
      echo "No connect key. It is on the hub's Settings page, under Connect another machine." >&2
      exit 1
    fi
    command -v curl >/dev/null 2>&1 || { echo "Needs curl." >&2; exit 1; }
    # Checked before connecting, so the hub never lists a machine that
    # could not be hooked up (see add_hooks below).
    if ! command -v osascript >/dev/null 2>&1 && ! command -v python3 >/dev/null 2>&1; then
      echo "Needs python3, to add the hooks to Claude's settings." >&2
      exit 1
    fi
    # A known answer, to check this machine can sign at all.
    if [ "$(hmac k msg)" != bf1a0c1242929b6464a6c0a9ac6298a67e09bd1cd4ef1f182ce0141691fc17a0 ]; then
      echo "Needs perl (with Digest::SHA) or python3, to sign what it sends to the hub." >&2
      exit 1
    fi

    CONF="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
    CODEX="${CODEX_HOME:-$HOME/.codex}"
    machine=$(scutil --get LocalHostName 2>/dev/null || hostname -s)
    machine=$(printf '%s' "$machine" | tr -c 'A-Za-z0-9._-' '-' | cut -c1-64)

    # Connect first, so a wrong key or a hub out of reach changes nothing here.
    new_id=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \\n')
    old_id=""
    [ -r "$CONF/wallboard-key" ] && old_id=$(head -n 1 "$CONF/wallboard-key")
    case "$old_id" in *[!0-9a-f]*) old_id="" ;; esac
    work=$(mktemp -d "${TMPDIR:-/tmp}/wallboard-connect.XXXXXX")
    trap 'rm -rf "$work"' EXIT
    : > "$work/empty"
    KEY_ID=connect
    KEY="$CONNECT_KEY"
    code=$(signed_post "/ingest/connect?machine=$machine&key=$new_id${old_id:+&replaces=$old_id}" \\
      text/plain "$work/empty" -sS -o "$work/reply" -w '%{http_code}' --connect-timeout 5 --max-time 20) || code=000
    if [ "$code" != 200 ]; then
      echo "The hub at $HUB did not connect this machine ($code): $(cat "$work/reply" 2>/dev/null)" >&2
      exit 1
    fi
    KEY=$(hmac "$CONNECT_KEY" "$(printf 'vitalaize machine key\\n%s' "$new_id")")
    # Readable only by this user. One line each: key id, machine, key.
    save_key() {
      (umask 077 && printf '%s\\n%s\\n%s\\n' "$new_id" "$machine" "$KEY" > "$1.new") && mv -f "$1.new" "$1"
    }

    # Adds the hooks listed in $3 (JSON), each running $2, to the hooks file
    # $1 (Claude's settings.json or Codex's hooks.json), after backing it
    # up. The first backup is kept, so connecting again never replaces it,
    # and a hook already there is not added twice.
    # On a Mac, osascript's JavaScript edits the file with no other tool.
    # Elsewhere (Linux), python3 does the same edit.
    add_hooks() {
      [ -f "$1" ] || echo '{}' > "$1"
      [ -f "$1.before-wallboard" ] || cp "$1" "$1.before-wallboard"
      if ! command -v osascript >/dev/null 2>&1; then
        command -v python3 >/dev/null 2>&1 || { echo "Needs python3 to edit $1." >&2; exit 1; }
        python3 - "$1" "$2" "$3" <<'WALLBOARD_PY'
    import json, os, sys
    path, script, wanted = sys.argv[1], sys.argv[2], sys.argv[3]
    raw = open(path).read().strip()
    s = json.loads(raw) if raw else {}
    hooks = s.setdefault("hooks", {})
    hook = {"type": "command", "command": script, "async": True, "timeout": 120}
    for want in json.loads(wanted):
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
        return
      fi
      osascript -l JavaScript - "$1" "$2" "$3" <<'WALLBOARD_JS'
    ObjC.import("Foundation");
    function run(argv) {
      const file = argv[0], script = argv[1], wanted = JSON.parse(argv[2]);
      const text = $.NSString.stringWithContentsOfFileEncodingError(file, $.NSUTF8StringEncoding, null);
      const raw = text.isNil() ? "" : text.js.trim();
      const s = raw === "" ? {} : JSON.parse(raw);
      s.hooks = s.hooks || {};
      const hook = { type: "command", command: script, async: true, timeout: 120 };
      for (const want of wanted) {
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
    }

    mkdir -p "$CONF"
    save_key "$CONF/wallboard-key"
    SCRIPT="$CONF/wallboard-upload.sh"
    cat > "$SCRIPT" <<'WALLBOARD_UPLOAD'
    #{upload_script(hub_url)}WALLBOARD_UPLOAD
    chmod 700 "$SCRIPT"
    add_hooks "$CONF/settings.json" "$SCRIPT" '#{hooks}'
    echo "Connected as $machine. Claude sessions on this machine now go to $HUB."
    echo "Your previous Claude settings are in $CONF/settings.json.before-wallboard."

    if [ -d "$CODEX" ]; then
      save_key "$CODEX/wallboard-key"
      CODEX_SCRIPT="$CODEX/wallboard-upload.sh"
      cat > "$CODEX_SCRIPT" <<'WALLBOARD_CODEX_UPLOAD'
    #{codex_upload_script(hub_url)}WALLBOARD_CODEX_UPLOAD
      chmod 700 "$CODEX_SCRIPT"
      add_hooks "$CODEX/hooks.json" "$CODEX_SCRIPT" '#{codex_hooks}'
      echo "Codex sessions on this machine go there too, once you trust the new hooks:"
      echo "type /hooks in Codex and trust the two wallboard-upload.sh hooks. Codex skips a new hook until then."
      echo "Your previous Codex hooks are in $CODEX/hooks.json.before-wallboard."
    fi
    """
  end
end
