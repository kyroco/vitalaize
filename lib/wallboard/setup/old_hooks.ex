defmodule Wallboard.Setup.OldHooks do
  @moduledoc """
  Takes out the upload hooks VitalAIze 0.2.0 added to a machine.

  Before the streaming collector, a machine sent its sessions to the hub
  from a script, `wallboard-upload.sh`, saved in each Claude folder and in
  the Codex folder, and run from hooks added to Claude's `settings.json`
  and Codex's `hooks.json`. The hub takes no uploads now, so setting a
  machine up (`vitalaize setup`, or the VitalAIze app) removes those hooks
  and the script, and so does removing VitalAIze.

  ## What is touched

  Only hooks whose command is a `wallboard-upload.sh`. Every other hook
  stays, VitalAIze's own Codex "Needs you" hook (`codex-hook.sh`) among
  them, and so does the rest of the file, byte for byte: the hooks are cut
  out of the text where they stand, and nothing is written out again from
  scratch. So the file keeps its order, its spacing and anything else its
  owner put there.

  A file is copied first, to `<file>.before-collector` (or
  `.before-collector-2` and so on, never over an earlier copy). What the
  edit leaves is checked before it is written: it must read as the same
  settings with those hooks gone, or the file is left alone and the
  report says so. A file that is not JSON is left alone too.

  The script itself holds the hub's old key, so it is deleted, always,
  and not kept. A hook this could not safely take out (its file was left
  alone, or its owner changed its command) then runs a script that is
  gone, and shows an error on each turn until its owner removes it. The
  report names each file that was left alone and says so.
  """

  alias Wallboard.Settings

  @script "wallboard-upload.sh"

  @doc """
  The folders to look in: `%{claude: [folder], codex: [folder]}`. Claude's
  are `~/.claude`, every `~/.claude-something`, `CLAUDE_CONFIG_DIR`, the
  folders in the settings, and the ones an earlier VitalAIze app recorded
  hooking (its install.json). Codex's are `~/.codex`, `CODEX_HOME`, the
  settings' and the app's. Only folders that exist are returned.

  Options: `home` and `env` (a function from a name to a value or nil) in
  place of this user's own, and `data`, the folder install.json is in.
  """
  def folders(settings, opts \\ []) do
    home = opts[:home] || System.user_home!()
    env = opts[:env] || (&System.get_env/1)
    app = recorded(opts[:data] || Path.dirname(Settings.file_place()))

    names =
      case File.ls(home) do
        {:ok, names} -> Enum.sort(names)
        _ -> []
      end

    claude =
      for(
        n <- names,
        n == ".claude" or String.starts_with?(n, ".claude-"),
        do: Path.join(home, n)
      ) ++
        [env.("CLAUDE_CONFIG_DIR")] ++
        list(get_in(settings, [:collector, :claude_dirs])) ++
        list(get_in(settings, [:claude, :config_dirs])) ++ app.claude

    codex =
      [Path.join(home, ".codex"), env.("CODEX_HOME")] ++
        list(get_in(settings, [:collector, :codex_dirs])) ++
        list(get_in(settings, [:codex, :dirs])) ++ app.codex

    %{claude: existing(claude), codex: existing(codex)}
  end

  defp list(dirs) when is_list(dirs), do: dirs
  defp list(_), do: []

  defp existing(dirs) do
    dirs
    |> Enum.filter(&(is_binary(&1) and &1 != "" and String.valid?(&1)))
    |> Enum.map(&Path.expand/1)
    |> Enum.uniq()
    |> Enum.filter(&File.dir?/1)
  end

  # The folders an earlier VitalAIze app hooked, from its record.
  defp recorded(data) do
    with {:ok, text} <- File.read(Path.join(data, "install.json")),
         {:ok, %{} = record} <- Jason.decode(text) do
      %{
        claude: list(record["hookedFolders"]),
        codex: List.wrap(record["hookedCodex"])
      }
    else
      _ -> %{claude: [], codex: []}
    end
  end

  @doc """
  Takes the old hooks and the old script out of every folder given (see
  `folders/2`). Returns what it did, one map for each thing:

    * `%{file: path, hooks: count, backup: path}`: hooks taken out
    * `%{script: path}`: the upload script deleted
    * `%{file: path, error: why}`: a file left as it was

  A folder with nothing of VitalAIze's adds nothing to the list.
  """
  def retire(%{claude: claude, codex: codex}) do
    folders =
      (for(dir <- claude, do: {dir, "settings.json"}) ++
         for(dir <- codex, do: {dir, "hooks.json"}))
      |> Enum.uniq()
      |> Enum.filter(fn {dir, file} -> allowed?(Path.join(dir, file)) end)

    scripts = folders |> Enum.map(fn {dir, _} -> Path.join(dir, @script) end) |> Enum.uniq()

    Enum.flat_map(folders, fn {dir, file} ->
      file(Path.join(dir, file), Path.join(dir, @script))
    end) ++ Enum.flat_map(scripts, &script/1)
  end

  # Tests name the one place they may change files (config/test.exs), so no
  # test can reach a real Claude or Codex folder, or a real certificate.
  @doc false
  def allowed?(path) do
    case Application.get_env(:wallboard, :old_hooks_within) do
      nil -> true
      root -> String.starts_with?(Path.expand(path), Path.expand(root) <> "/")
    end
  end

  defp file(path, script) do
    with {:ok, text} <- File.read(path),
         {:ok, new, count} <- strip(text, script) do
      backup = backup!(path, text)

      # A copy is kept only beside a file that was changed.
      try do
        # Claude or Codex may have saved the file in the meantime: then it
        # is theirs, and the next setup takes the hooks out.
        if File.read!(path) == text do
          write!(path, new)
          [%{file: path, hooks: count, backup: backup}]
        else
          File.rm(backup)
          [%{file: path, error: :changed}]
        end
      rescue
        e ->
          File.rm(backup)
          reraise e, __STACKTRACE__
      end
    else
      :unchanged -> []
      {:error, :unsafe} -> [%{file: path, error: :unsafe}]
      {:error, :not_json} -> if(mentions?(path), do: [%{file: path, error: :not_json}], else: [])
      # No file, or one that cannot be opened: nothing is known to be in it.
      {:error, _} -> []
    end
  rescue
    # A copy or a write that failed: the file is as it was, or whole and new.
    e -> [%{file: path, error: Map.get(e, :reason, :failed)}]
  end

  # A file this cannot read is worth a word only when it names the script.
  defp mentions?(path) do
    case File.read(path) do
      {:ok, text} -> String.contains?(text, @script)
      _ -> false
    end
  end

  # Copies the file's text to the first backup name nothing has yet, and
  # returns that name. The copy is made new or not at all, so it never
  # lands on an earlier copy or goes through a link, and it has the file's
  # own permissions before anything is in it.
  defp backup!(path, text) do
    mode = Bitwise.band(File.stat!(path).mode, 0o777)

    Enum.find_value(Stream.iterate(1, &(&1 + 1)), fn n ->
      candidate = path <> ".before-collector" <> if(n == 1, do: "", else: "-#{n}")

      case File.open(candidate, [:write, :exclusive, :binary]) do
        {:ok, io} ->
          try do
            File.chmod!(candidate, mode)
            :ok = IO.binwrite(io, text)
            :ok = File.close(io)
          rescue
            e ->
              File.close(io)
              File.rm(candidate)
              reraise e, __STACKTRACE__
          end

          candidate

        {:error, :eexist} ->
          nil

        {:error, reason} ->
          raise File.Error, reason: reason, action: "make a copy at", path: candidate
      end
    end)
  end

  # In one step, with the file's own permissions. A file that is a link
  # (a dotfiles folder, say) is written through the link, so it stays one.
  defp write!(path, text) do
    case File.lstat!(path) do
      %{type: :symlink} ->
        File.write!(path, text)

      %{mode: mode} ->
        tmp = "#{path}.#{System.unique_integer([:positive])}.tmp"

        try do
          File.write!(tmp, "")
          File.chmod!(tmp, Bitwise.band(mode, 0o777))
          File.write!(tmp, text)
          File.rename!(tmp, path)
        rescue
          e ->
            File.rm(tmp)
            reraise e, __STACKTRACE__
        end
    end
  end

  # Only a script that is the upload script: it names the hub's old
  # address. It always goes, whatever became of the hooks that ran it.
  defp script(path) do
    with {:ok, text} <- File.read(path),
         true <- String.contains?(text, "/ingest/"),
         :ok <- File.rm(path) do
      [%{script: path}]
    else
      _ -> []
    end
  end

  # ---------------------------------------------------------------------------
  # The edit (pure)

  @doc """
  The text of a hooks file with VitalAIze's upload hooks cut out:
  `{:ok, text, count}`, `:unchanged` when it holds none, or
  `{:error, :not_json}` / `{:error, :unsafe}` when it is left alone.

  A matcher group left with no hooks goes with them, then an event left
  with no groups, then a `hooks` left with no events. Everything else
  keeps its bytes; only a file that held nothing but those hooks loses
  the space inside its outer braces and is left as `{}`.
  """
  def strip(text, script) when is_binary(text) and is_binary(script) do
    case Jason.decode(text) do
      {:ok, %{} = data} ->
        {root, _} = scan(text, 0)

        case root_cuts({text, script}, root) do
          {[], 0} ->
            :unchanged

          {cuts, count} ->
            new = cut(text, cuts)

            cond do
              # A name given twice in one object: which one counts differs
              # from one JSON reader to the next, so the check below could
              # pass on settings Claude or Codex never saw.
              twice?(root) -> {:error, :unsafe}
              # What is left must be the same settings without those
              # hooks, worked out a second way.
              Jason.decode(new) == {:ok, without(data, script)} -> {:ok, new, count}
              true -> {:error, :unsafe}
            end
        end

      {:ok, _} ->
        :unchanged

      {:error, _} ->
        {:error, :not_json}
    end
  rescue
    _ -> {:error, :unsafe}
  end

  @doc """
  True for the command of a hook VitalAIze's old upload script ran from:
  the path of `script`, the upload script in the hooks file's own folder,
  and nothing else. That is what both old installers wrote. A command
  with anything more on its line, or that runs a script somewhere else,
  is its owner's, and stays.
  """
  def ours?(command, script) when is_binary(command) and is_binary(script) do
    path = command |> String.trim() |> unquote_whole()

    Path.basename(script) == @script and String.starts_with?(path, ["/", "~/"]) and
      Path.expand(path) == Path.expand(script)
  end

  def ours?(_, _), do: false

  defp unquote_whole(text) do
    case Regex.run(~r/\A(["'])(.*)\1\z/s, text) do
      [_, _, inner] -> inner
      _ -> text
    end
  end

  # A name given twice in one object, anywhere in the file.
  defp twice?({:object, _, _, members}) do
    keys = Enum.map(members, &elem(&1, 0))
    keys != Enum.uniq(keys) or Enum.any?(members, fn {_, _, value} -> twice?(value) end)
  end

  defp twice?({:array, _, _, items}), do: Enum.any?(items, &twice?/1)
  defp twice?(_), do: false

  # The same edit made on the decoded settings, to check the text against.
  defp without(%{"hooks" => %{} = hooks} = data, script) do
    events =
      hooks
      |> Enum.map(fn {event, groups} -> {event, without_groups(groups, script)} end)
      |> Enum.reject(fn {_, kept} -> kept == :gone end)
      |> Map.new()

    if events == %{} and hooks != %{},
      do: Map.delete(data, "hooks"),
      else: %{data | "hooks" => events}
  end

  defp without(data, _script), do: data

  defp without_groups([_ | _] = groups, script) do
    kept = groups |> Enum.map(&without_hooks(&1, script)) |> Enum.reject(&(&1 == :gone))
    if kept == [], do: :gone, else: kept
  end

  defp without_groups(other, _script), do: other

  defp without_hooks(%{"hooks" => [_ | _] = hooks} = group, script) do
    case Enum.reject(hooks, &our_hook?(&1, script)) do
      [] -> :gone
      kept -> %{group | "hooks" => kept}
    end
  end

  defp without_hooks(other, _script), do: other

  defp our_hook?(%{"command" => command}, script), do: ours?(command, script)
  defp our_hook?(_, _script), do: false

  # Each level answers :gone (cut me out whole) or {cuts inside me, hooks
  # counted}. A cut is {from, to}: bytes from `from` up to, not including,
  # `to`.

  defp root_cuts(text, {:object, _, _, members} = root) do
    results =
      for {key, _, node} = m <- members do
        if key == "hooks", do: hooks_cuts(text, node), else: keep(m)
      end

    merge(root, members, results)
  end

  defp hooks_cuts(text, {:object, _, _, members} = node) do
    results = for {_, _, groups} <- members, do: event_cuts(text, groups)
    gone_or(node, members, results)
  end

  defp hooks_cuts(_text, _other), do: {[], 0}

  defp event_cuts(text, {:array, _, _, groups} = node) do
    results = for group <- groups, do: group_cuts(text, group)
    gone_or(node, groups, results)
  end

  defp event_cuts(_text, _other), do: {[], 0}

  defp group_cuts(text, {:object, _, _, members}) do
    case Enum.find(members, fn {key, _, _} -> key == "hooks" end) do
      {_, _, {:array, _, _, hooks} = node} ->
        results = for hook <- hooks, do: if(hook_ours?(text, hook), do: {:gone, 1}, else: {[], 0})
        gone_or(node, hooks, results)

      _ ->
        {[], 0}
    end
  end

  defp group_cuts(_text, _other), do: {[], 0}

  # `text` here and above is {the file's text, the script's path}.
  defp hook_ours?({text, script}, {:object, _, _, members}) do
    Enum.any?(members, fn
      {"command", _, {:string, s, e}} ->
        ours?(Jason.decode!(binary_part(text, s, e - s)), script)

      _ ->
        false
    end)
  end

  defp hook_ours?(_text, _other), do: false

  defp keep(_member), do: {[], 0}

  # A container all of whose children go, goes itself.
  defp gone_or(node, children, results) do
    count = results |> Enum.map(&elem(&1, 1)) |> Enum.sum()

    if children != [] and Enum.all?(results, &match?({:gone, _}, &1)),
      do: {:gone, count},
      else: merge(node, children, results)
  end

  # The cuts for a container that stays: its children that go, and the
  # cuts inside those that stay.
  defp merge({_, open, close, _}, children, results) do
    spans = Enum.map(children, &span/1)
    count = results |> Enum.map(&elem(&1, 1)) |> Enum.sum()
    gone = for {{:gone, _}, i} <- Enum.with_index(results), do: i
    inner = for {cuts, _} when is_list(cuts) <- results, cut <- cuts, do: cut

    {children_cuts(open, close, spans, gone) ++ inner, count}
  end

  defp span({_key, start, {_, _, stop, _}}), do: {start, stop}
  defp span({_key, start, {_, _, stop}}), do: {start, stop}
  defp span({_, start, stop, _}), do: {start, stop}
  defp span({_, start, stop}), do: {start, stop}

  defp children_cuts(_open, _close, _spans, []), do: []

  # Every child goes: what is between the brackets goes.
  defp children_cuts(open, close, spans, gone) when length(gone) == length(spans),
    do: [{open + 1, close - 1}]

  # A child with one that stays after it is cut up to the start of the
  # next child, so the next takes its place. The children that go at the
  # end are cut from the end of the last one that stays, so the comma
  # before them goes too.
  defp children_cuts(_open, _close, spans, gone) do
    last = length(spans) - 1
    gone = MapSet.new(gone)
    last_kept = Enum.find(last..0//-1, &(not MapSet.member?(gone, &1)))

    middle =
      for i <- gone, i < last_kept do
        {from, _} = Enum.at(spans, i)
        {to, _} = Enum.at(spans, i + 1)
        {from, to}
      end

    tail =
      if last_kept < last do
        {_, from} = Enum.at(spans, last_kept)
        {_, to} = Enum.at(spans, last)
        [{from, to}]
      else
        []
      end

    middle ++ tail
  end

  defp cut(text, cuts) do
    cuts
    |> Enum.sort(:desc)
    |> Enum.reduce(text, fn {from, to}, acc ->
      binary_part(acc, 0, from) <> binary_part(acc, to, byte_size(acc) - to)
    end)
  end

  # ---------------------------------------------------------------------------
  # Where each value sits in the text. Only run on text Jason has read, so
  # it finds its way and checks nothing.
  #
  #   {:object, start, stop, [{key, key start, value}]}
  #   {:array, start, stop, [value]}
  #   {:string, start, stop}, {:other, start, stop}
  #
  # `stop` is the byte after the value's last.

  defp scan(text, pos) do
    pos = skip(text, pos)

    case :binary.at(text, pos) do
      ?{ -> object(text, pos, skip(text, pos + 1), [])
      ?[ -> array(text, pos, skip(text, pos + 1), [])
      ?" -> {{:string, pos, string_end(text, pos + 1)}, string_end(text, pos + 1)}
      _ -> other(text, pos, pos)
    end
  end

  defp object(text, start, pos, members) do
    case :binary.at(text, pos) do
      ?} ->
        {{:object, start, pos + 1, Enum.reverse(members)}, pos + 1}

      ?, ->
        object(text, start, skip(text, pos + 1), members)

      ?" ->
        key_end = string_end(text, pos + 1)
        key = Jason.decode!(binary_part(text, pos, key_end - pos))
        colon = skip(text, key_end)
        {value, after_value} = scan(text, colon + 1)
        object(text, start, skip(text, after_value), [{key, pos, value} | members])
    end
  end

  defp array(text, start, pos, items) do
    case :binary.at(text, pos) do
      ?] ->
        {{:array, start, pos + 1, Enum.reverse(items)}, pos + 1}

      ?, ->
        array(text, start, skip(text, pos + 1), items)

      _ ->
        {value, after_value} = scan(text, pos)
        array(text, start, skip(text, after_value), [value | items])
    end
  end

  # The byte after a string's closing quote; `pos` is just inside it.
  defp string_end(text, pos) do
    case :binary.at(text, pos) do
      ?\\ -> string_end(text, pos + 2)
      ?" -> pos + 1
      _ -> string_end(text, pos + 1)
    end
  end

  defp other(text, start, pos) do
    if pos < byte_size(text) and :binary.at(text, pos) not in [?,, ?], ?}, ?\s, ?\t, ?\n, ?\r],
      do: other(text, start, pos + 1),
      else: {{:other, start, pos}, pos}
  end

  defp skip(text, pos) do
    if pos < byte_size(text) and :binary.at(text, pos) in [?\s, ?\t, ?\n, ?\r],
      do: skip(text, pos + 1),
      else: pos
  end

  # ---------------------------------------------------------------------------
  # In words

  @doc "What `retire/1` did, as sentences for the person at the machine."
  def report(results) do
    for result <- results do
      case result do
        %{file: file, hooks: n, backup: backup} ->
          "Took #{n} old VitalAIze upload #{if n == 1, do: "hook", else: "hooks"} out of " <>
            "#{file}. Every other hook is as it was, and the file from before is #{backup}."

        %{script: script} ->
          "Deleted the old upload script #{script}."

        %{file: file, error: :changed} ->
          "#{file} was saved by something else just then, so it was left as it is. " <>
            "Run this again to take the old upload hooks out of it. Until then they " <>
            "show an error on each turn, since the script they run is deleted."

        %{file: file, error: _} ->
          "Could not take the old upload hooks out of #{file}, so it is as it was. " <>
            "Remove the hooks that run #{@script} from it by hand: that script is " <>
            "deleted, so they show an error on each turn until you do."
      end
    end
  end
end
