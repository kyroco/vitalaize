defmodule Wallboard.Sources.Usage do
  @moduledoc """
  Token use and cost, read from Claude Code's own transcripts.

  Every session writes a transcript at
  <config dir>/projects/<folder>/<session id>.jsonl, and each subagent writes
  one under <session id>/subagents/. Each model reply in them carries its
  request id, model, effort and token counts; each file edit carries a patch.

  The first poll reads the last few weeks of transcripts (a few gigabytes on
  a busy Mac, so it takes a little while); after that only the new lines at
  the end of each file are read.

  A reply split into several content blocks is written as several lines with
  the same request id, so requests are counted once by id, never by line.

  Costs are at API list prices from settings. A Claude subscription is billed
  differently, so treat them as a measure of use, not the bill.
  """

  # ---------------------------------------------------------------------------
  # Poller hooks (see Wallboard.Poller)

  def poll(settings, _prev, memory, now) do
    memory = memory || %{files: %{}}
    files = scan(settings, memory.files, now)
    {:ok, summarize(files, settings, now), %{files: files}}
  rescue
    e -> {:error, "could not read transcripts: " <> Exception.message(e), memory}
  end

  def fingerprint(facts), do: facts

  # ---------------------------------------------------------------------------
  # Finding and reading files

  defp scan(settings, known, now) do
    cutoff = DateTime.to_unix(now) - settings.usage.days_back * 86_400

    settings.claude.config_dirs
    |> Enum.flat_map(fn dir ->
      main = Path.wildcard(Path.join([dir, "projects", "*", "*.jsonl"]))
      subs = Path.wildcard(Path.join([dir, "projects", "*", "*", "subagents", "*.jsonl"]))
      Enum.map(main, &{&1, :main}) ++ Enum.map(subs, &{&1, :sub})
    end)
    |> Enum.reduce(%{}, fn {path, kind}, acc ->
      case File.stat(path, time: :posix) do
        {:ok, %{size: size, mtime: mtime}} when mtime >= cutoff ->
          state = Map.get(known, path) || new_file(path, kind)
          Map.put(acc, path, read_new(state, path, size, mtime))

        _ ->
          acc
      end
    end)
  end

  defp new_file(path, kind) do
    {session_id, meta} =
      case kind do
        :main ->
          {Path.basename(path, ".jsonl"), nil}

        :sub ->
          parent = path |> Path.dirname() |> Path.dirname() |> Path.basename()
          {parent, read_meta(String.replace_suffix(path, ".jsonl", ".meta.json"))}
      end

    %{kind: kind, session_id: session_id, meta: meta, offset: 0, mtime: 0}
    |> Map.merge(empty_stats())
  end

  defp read_meta(path) do
    with {:ok, text} <- File.read(path), {:ok, %{} = m} <- Jason.decode(text) do
      %{type: m["agentType"], description: m["description"]}
    else
      _ -> %{type: nil, description: nil}
    end
  end

  @doc "The part of a file's state that parsing lines builds up."
  def empty_stats do
    %{requests: %{}, added: 0, removed: 0, last: nil, first_at: nil, last_at: nil, ended: false}
  end

  # Reads from where we stopped to the last complete line.
  defp read_new(%{offset: offset} = state, _path, size, mtime) when size <= offset,
    do: %{state | mtime: mtime}

  defp read_new(state, path, size, mtime) do
    {:ok, io} = :file.open(path, [:read, :binary, :raw])

    try do
      {:ok, chunk} = :file.pread(io, state.offset, size - state.offset)

      case :binary.matches(chunk, "\n") do
        [] ->
          %{state | mtime: mtime}

        matches ->
          {last_nl, 1} = List.last(matches)
          complete = binary_part(chunk, 0, last_nl)
          state = parse_lines(state, complete)
          %{state | offset: state.offset + last_nl + 1, mtime: mtime}
      end
    after
      :file.close(io)
    end
  end

  # ---------------------------------------------------------------------------
  # Parsing (pure, tested against saved real lines)

  @doc "Adds the lines of one transcript chunk to a file's stats."
  def parse_lines(state, chunk) do
    chunk
    |> :binary.split("\n", [:global])
    |> Enum.reduce(state, &parse_line/2)
  end

  # Only lines that can matter are decoded: model replies with usage, and
  # tool results that carry a patch. The rest (often large) are skipped.
  defp parse_line(line, state) do
    cond do
      :binary.match(line, ~s("type":"assistant")) != :nomatch and
          :binary.match(line, ~s("usage")) != :nomatch ->
        case Jason.decode(line) do
          {:ok, entry} -> add_reply(state, entry)
          _ -> state
        end

      :binary.match(line, ~s("structuredPatch")) != :nomatch ->
        case Jason.decode(line) do
          {:ok, entry} -> add_patch(state, entry)
          _ -> state
        end

      true ->
        state
    end
  end

  defp add_reply(state, %{"message" => %{"usage" => %{} = u} = msg} = entry) do
    at = parse_time(entry["timestamp"])
    id = entry["requestId"] || msg["id"] || entry["uuid"]
    writes = u["cache_creation"] || %{}
    cw_total = int(u["cache_creation_input_tokens"])
    cw_1h = int(writes["ephemeral_1h_input_tokens"])
    cw_5m = if writes == %{}, do: cw_total, else: int(writes["ephemeral_5m_input_tokens"])

    request = %{
      day: at && local_day(at),
      model: msg["model"],
      input: int(u["input_tokens"]),
      cache_read: int(u["cache_read_input_tokens"]),
      cache_write_5m: cw_5m,
      cache_write_1h: cw_1h,
      output: int(u["output_tokens"])
    }

    context = request.input + request.cache_read + cw_total

    %{
      state
      | requests: Map.put(state.requests, id, request),
        last: %{model: msg["model"], effort: entry["effort"], context: context, at: at},
        first_at: state.first_at || at,
        last_at: at || state.last_at,
        ended: msg["stop_reason"] == "end_turn"
    }
  end

  defp add_reply(state, _), do: state

  defp add_patch(state, %{"toolUseResult" => %{} = r}) do
    {added, removed} = patch_lines(r)
    %{state | added: state.added + added, removed: state.removed + removed}
  end

  defp add_patch(state, _), do: state

  @doc "Lines added and removed by one edit or new file."
  def patch_lines(%{"structuredPatch" => [_ | _] = hunks}) do
    lines = Enum.flat_map(hunks, &(&1["lines"] || []))

    {Enum.count(lines, &String.starts_with?(&1, "+")),
     Enum.count(lines, &String.starts_with?(&1, "-"))}
  end

  def patch_lines(%{"type" => "create", "content" => content}) when is_binary(content) do
    {length(String.split(content, "\n", trim: true)), 0}
  end

  def patch_lines(_), do: {0, 0}

  # ---------------------------------------------------------------------------
  # Summaries (pure)

  @doc "Turns every file's stats into the trend and the per-session details."
  def summarize(files, settings, now) do
    prices = settings.usage.prices
    all = Map.values(files)

    %{
      trend: trend(all, prices, now),
      sessions: sessions(all, prices, now)
    }
  end

  @doc "The dollar cost of one request at the prices in settings."
  def cost(request, prices) do
    case price_for(request.model, prices) do
      nil ->
        0.0

      p ->
        (request.input * p.input + request.cache_read * p.cache_read +
           request.cache_write_5m * p.input * 1.25 + request.cache_write_1h * p.input * 2 +
           request.output * p.output) / 1_000_000
    end
  end

  @doc "Prices for a model id, matching the longest name in settings it starts with."
  def price_for(nil, _), do: nil

  def price_for(model, prices) do
    prices
    |> Enum.filter(fn {name, _} -> String.starts_with?(model, name) end)
    |> Enum.max_by(fn {name, _} -> String.length(name) end, fn -> nil end)
    |> case do
      nil -> nil
      {_, p} -> p
    end
  end

  defp sessions(files, prices, now) do
    recent = DateTime.to_unix(now) - 36 * 3600
    by_session = Enum.group_by(files, & &1.session_id)

    for {sid, group} <- by_session,
        main = Enum.find(group, &(&1.kind == :main)),
        main && main.mtime >= recent,
        into: %{} do
      subs = Enum.filter(group, &(&1.kind == :sub))
      model = main.last && main.last.model
      price = price_for(model, prices)
      window = (price && price.context) || nil

      {sid,
       %{
         cost: Enum.sum(Enum.map(group, &file_cost(&1, prices))),
         model: model,
         model_label: (price && price.label) || model,
         window: window,
         effort: main.last && main.last.effort,
         context: main.last && main.last.context,
         context_pct: main.last && window && round(main.last.context * 100 / window),
         added: Enum.sum(Enum.map(group, & &1.added)),
         removed: Enum.sum(Enum.map(group, & &1.removed)),
         subagents:
           subs
           |> Enum.sort_by(&unix(&1.first_at), :desc)
           |> Enum.map(fn s ->
             running = not s.ended and DateTime.to_unix(now) - s.mtime < 120

             %{
               name: (s.meta && (s.meta.type || s.meta.description)) || "subagent",
               description: s.meta && s.meta.description,
               running: running,
               seconds:
                 if(s.first_at && s.last_at, do: DateTime.diff(s.last_at, s.first_at), else: nil),
               started_at: s.first_at
             }
           end)
       }}
    end
  end

  defp file_cost(file, prices),
    do: file.requests |> Map.values() |> Enum.map(&cost(&1, prices)) |> Enum.sum()

  @metrics [:cost_per_request, :cache_hit, :mean_context, :spend_per_day, :requests_per_day]

  @doc """
  The token trend: each metric over the last 7 days with any requests,
  against the 7 active days before them, plus one value per calendar day for
  the last 14 days.
  """
  def trend(files, prices, now) do
    days =
      files
      |> Enum.flat_map(&Map.values(&1.requests))
      |> Enum.reject(&is_nil(&1.day))
      |> Enum.group_by(& &1.day)
      |> Map.new(fn {day, reqs} -> {day, day_totals(reqs, prices)} end)

    active = days |> Map.keys() |> Enum.sort({:desc, Date})
    last7 = Enum.take(active, 7)
    prev7 = active |> Enum.drop(7) |> Enum.take(7)
    today = local_day(now)
    calendar = for i <- 13..0//-1, do: Date.add(today, -i)

    %{
      rows:
        Enum.map(@metrics, fn m ->
          current = metric(m, Enum.map(last7, &days[&1]))
          previous = metric(m, Enum.map(prev7, &days[&1]))

          %{
            metric: m,
            current: current,
            previous: previous,
            change: change(current, previous),
            daily: Enum.map(calendar, fn d -> if days[d], do: metric(m, [days[d]]), else: nil end)
          }
        end),
      active_days: length(active),
      lifetime_cache_hit: metric(:cache_hit, Map.values(days))
    }
  end

  defp day_totals(reqs, prices) do
    %{
      requests: length(reqs),
      cost: reqs |> Enum.map(&cost(&1, prices)) |> Enum.sum(),
      prompt:
        Enum.sum(
          Enum.map(reqs, &(&1.input + &1.cache_read + &1.cache_write_5m + &1.cache_write_1h))
        ),
      cache_read: Enum.sum(Enum.map(reqs, & &1.cache_read))
    }
  end

  defp metric(_m, []), do: nil

  defp metric(m, days) do
    requests = Enum.sum(Enum.map(days, & &1.requests))
    cost = Enum.sum(Enum.map(days, & &1.cost))
    prompt = Enum.sum(Enum.map(days, & &1.prompt))
    cache = Enum.sum(Enum.map(days, & &1.cache_read))
    n = length(days)

    case m do
      _ when requests == 0 -> nil
      :cost_per_request -> cost / requests
      :cache_hit -> if prompt > 0, do: cache * 100 / prompt, else: nil
      :mean_context -> prompt / requests
      :spend_per_day -> cost / n
      :requests_per_day -> requests / n
    end
  end

  defp change(nil, _), do: nil
  defp change(_, nil), do: nil
  defp change(_, prev) when prev == 0, do: nil
  defp change(cur, prev), do: (cur - prev) * 100 / prev

  # ---------------------------------------------------------------------------

  # Days are this Mac's local days.
  defp local_day(%DateTime{} = dt) do
    {{y, m, d}, _} =
      :calendar.universal_time_to_local_time(NaiveDateTime.to_erl(DateTime.to_naive(dt)))

    Date.new!(y, m, d)
  end

  defp parse_time(s) when is_binary(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _} -> DateTime.truncate(dt, :second)
      _ -> nil
    end
  end

  defp parse_time(_), do: nil

  defp int(n) when is_integer(n), do: n
  defp int(_), do: 0

  defp unix(nil), do: 0
  defp unix(dt), do: DateTime.to_unix(dt)
end
