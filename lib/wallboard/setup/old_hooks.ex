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

  The script itself holds the hub's old key, so it is deleted, not kept.
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
    Enum.flat_map(claude, &folder(&1, "settings.json")) ++
      Enum.flat_map(codex, &folder(&1, "hooks.json"))
  end

  defp folder(dir, file) do
    path = Path.join(dir, file)
    script = Path.join(dir, @script)

    if allowed?(path) do
      file(path) ++ script(script)
    else
      []
    end
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

  defp file(path) do
    with {:ok, text} <- File.read(path),
         {:ok, new, count} <- strip(text) do
      backup = backup_path(path)
      File.cp!(path, backup)
      write!(path, new)
      [%{file: path, hooks: count, backup: backup}]
    else
      :unchanged -> []
      {:error, :enoent} -> []
      {:error, :not_json} -> if(mentions?(path), do: [%{file: path, error: :not_json}], else: [])
      {:error, why} -> [%{file: path, error: why}]
    end
  rescue
    e in File.Error -> [%{file: path, error: e.reason}]
    e in File.CopyError -> [%{file: path, error: e.reason}]
  end

  # A file this cannot read is worth a word only when it names the script.
  defp mentions?(path) do
    case File.read(path) do
      {:ok, text} -> String.contains?(text, @script)
      _ -> false
    end
  end

  defp backup_path(path) do
    Enum.find_value(Stream.iterate(1, &(&1 + 1)), fn n ->
      candidate = path <> ".before-collector" <> if(n == 1, do: "", else: "-#{n}")
      if not File.exists?(candidate), do: candidate
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
        File.write!(tmp, "")
        File.chmod!(tmp, Bitwise.band(mode, 0o777))
        File.write!(tmp, text)
        File.rename!(tmp, path)
    end
  end

  # Only a script that is the upload script: it names the hub's old address.
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
  keeps its bytes.
  """
  def strip(text) when is_binary(text) do
    case Jason.decode(text) do
      {:ok, %{} = data} ->
        {root, _} = scan(text, 0)

        case root_cuts(text, root) do
          {[], 0} ->
            :unchanged

          {cuts, count} ->
            new = cut(text, cuts)

            # What is left must be the same settings without those hooks,
            # worked out a second way.
            if Jason.decode(new) == {:ok, without(data)},
              do: {:ok, new, count},
              else: {:error, :unsafe}
        end

      {:ok, _} ->
        :unchanged

      {:error, _} ->
        {:error, :not_json}
    end
  rescue
    _ -> {:error, :unsafe}
  end

  @doc "True for the command of a hook VitalAIze's old upload script ran from."
  def ours?(command) when is_binary(command) do
    command
    |> String.trim()
    |> String.trim("\"")
    |> String.trim("'")
    |> String.ends_with?("/" <> @script)
  end

  def ours?(_), do: false

  # The same edit made on the decoded settings, to check the text against.
  defp without(%{"hooks" => %{} = hooks} = data) do
    events =
      for {event, groups} <- hooks, kept = without_groups(groups), kept != :gone, into: %{} do
        {event, kept}
      end

    if events == %{} and hooks != %{},
      do: Map.delete(data, "hooks"),
      else: %{data | "hooks" => events}
  end

  defp without(data), do: data

  defp without_groups([_ | _] = groups) do
    kept = for group <- groups, g = without_hooks(group), g != :gone, do: g
    if kept == [], do: :gone, else: kept
  end

  defp without_groups(other), do: other

  defp without_hooks(%{"hooks" => [_ | _] = hooks} = group) do
    case Enum.reject(hooks, &our_hook?/1) do
      [] -> :gone
      kept -> %{group | "hooks" => kept}
    end
  end

  defp without_hooks(other), do: other

  defp our_hook?(%{"command" => command}), do: ours?(command)
  defp our_hook?(_), do: false

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

  defp hook_ours?(text, {:object, _, _, members}) do
    Enum.any?(members, fn
      {"command", _, {:string, s, e}} -> ours?(Jason.decode!(binary_part(text, s, e - s)))
      _ -> false
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

        %{file: file, error: _} ->
          "Could not take the old upload hooks out of #{file}, so it is as it was. " <>
            "Take out the hooks that run #{@script} there by hand."
      end
    end
  end
end
