defmodule Wallboard.Sources.NewRelic do
  @moduledoc """
  Checks from New Relic, through its NerdGraph API.

  Checks come from settings (`new_relic.checks`). Two kinds:

    * a synthetic monitor: `%{name: "Heartbeat", monitor: "<monitor name>"}`.
      Shows up or down, uptime and median response over 24 hours, the result
      of every check in 20-minute slots, and response time per slot.
    * any NRQL query: `%{name: "Errors", nrql: "SELECT count(*) FROM ...", unit: ""}`.
      Shows the first number the query returns.

  The first monitor check is the big one at the top of page 2; the rest fill
  the "More checks" row, with empty slots after them.
  """

  require Logger
  alias Wallboard.Secrets

  # ---------------------------------------------------------------------------
  # Poller hooks (see Wallboard.Poller)

  def poll(settings, _prev, memory, _now) do
    case fetch(settings) do
      {:ok, facts} -> {:ok, facts, memory}
      {:error, reason} -> {:error, reason, memory}
    end
  end

  def fingerprint(facts), do: facts

  # ---------------------------------------------------------------------------
  # Fetching

  def fetch(settings) do
    nr = settings.new_relic

    with {:ok, key_fun} <- key(),
         {:ok, account} <- account(nr),
         {:ok, checks} <- checks(nr) do
      query = build_query(account, checks)

      case post(endpoint(nr.region), key_fun, query) do
        {:ok, body} -> parse(body, checks)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp key do
    case Secrets.new_relic() do
      {:ok, fun} -> {:ok, fun}
      {:missing, reason} -> {:error, reason}
    end
  end

  defp account(%{account_id: id}) when is_integer(id), do: {:ok, id}

  defp account(%{account_id: id}) when is_binary(id) do
    case Integer.parse(id) do
      {n, ""} -> {:ok, n}
      _ -> {:error, "new_relic.account_id must be a number"}
    end
  end

  defp account(_), do: {:error, "No New Relic account in settings (new_relic.account_id)."}

  defp checks(%{checks: [_ | _] = checks}),
    do: {:ok, checks |> Enum.with_index() |> Enum.map(fn {c, i} -> Map.put(c, :id, "c#{i}") end)}

  defp checks(_), do: {:error, "No checks in settings yet (new_relic.checks)."}

  def endpoint("eu"), do: ~c"https://api.eu.newrelic.com/graphql"
  def endpoint(_), do: ~c"https://api.newrelic.com/graphql"

  defp post(url, key_fun, query) do
    body = Jason.encode!(%{query: query})
    headers = [{~c"api-key", String.to_charlist(key_fun.())}]

    ssl = [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      depth: 4,
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]

    case :httpc.request(
           :post,
           {url, headers, ~c"application/json", body},
           [timeout: 30_000, ssl: ssl],
           body_format: :binary
         ) do
      {:ok, {{_, 200, _}, _headers, resp}} ->
        {:ok, resp}

      {:ok, {{_, 401, _}, _, _}} ->
        {:error, "New Relic refused the key (401). It needs a User API key (NRAK-...)."}

      {:ok, {{_, 403, _}, _, _}} ->
        {:error, "New Relic refused the key (403)."}

      {:ok, {{_, status, _}, _, _}} ->
        {:error, "New Relic answered #{status}"}

      # Only the error's kind, so nothing from the request can end up in a log.
      {:error, reason} ->
        {:error, "Could not reach New Relic (#{error_kind(reason)})"}
    end
  end

  defp error_kind({kind, _}) when is_atom(kind), do: kind
  defp error_kind(kind) when is_atom(kind), do: kind
  defp error_kind(_), do: "network error"

  @doc "One NerdGraph request that fetches every check at once."
  def build_query(account, checks) do
    parts =
      Enum.map(checks, fn
        %{monitor: monitor, id: id} ->
          where = "FROM SyntheticCheck WHERE monitorName = #{nrql_string(monitor)}"

          """
          #{id}_latest: nrql(query: #{gql_string("SELECT result, duration, timestamp #{where} SINCE 1 day ago ORDER BY timestamp DESC LIMIT 1")}) { results }
          #{id}_stats: nrql(query: #{gql_string("SELECT percentage(count(*), WHERE result = 'SUCCESS') AS uptime, percentile(duration, 50) AS median #{where} SINCE 1 day ago")}) { results }
          #{id}_slots: nrql(query: #{gql_string("SELECT count(*) AS total, filter(count(*), WHERE result != 'SUCCESS') AS failed, average(duration) AS avg #{where} SINCE 24 hours ago TIMESERIES 20 minutes")}) { results }
          """

        %{nrql: nrql, id: id} ->
          "#{id}_value: nrql(query: #{gql_string(nrql)}) { results }\n"

        _ ->
          ""
      end)

    monitors = for %{monitor: m} <- checks, do: m

    entity =
      if monitors == [] do
        ""
      else
        names = monitors |> Enum.map(&nrql_string/1) |> Enum.join(", ")

        """
        monitors: entitySearch(query: #{gql_string("domain = 'SYNTH' AND name IN (#{names})")}) {
          results { entities { name reporting ... on SyntheticMonitorEntityOutline { monitoredUrl monitorType } } }
        }
        """
      end

    "{ actor { account(id: #{account}) { #{Enum.join(parts)} } #{entity} } }"
  end

  defp nrql_string(s),
    do: "'" <> String.replace(to_string(s), ["\\", "'"], fn c -> "\\" <> c end) <> "'"

  defp gql_string(s), do: Jason.encode!(s)

  # ---------------------------------------------------------------------------
  # Parsing (pure)

  @doc "Turns the NerdGraph reply into one result per check."
  def parse(body, checks) do
    case Jason.decode(body) do
      {:ok, %{"data" => %{"actor" => actor}} = reply} when is_map(actor) ->
        account = actor["account"] || %{}
        urls = monitor_urls(actor)

        results =
          Enum.map(checks, fn
            %{monitor: monitor, id: id} = c ->
              latest = first(account, "#{id}_latest")
              stats = first(account, "#{id}_stats")
              slots = get_in(account, ["#{id}_slots", "results"]) || []

              %{
                kind: :monitor,
                name: c[:name] || monitor,
                monitor: monitor,
                url: c[:url] || urls[monitor],
                up: latest && latest["result"] == "SUCCESS",
                last_result: latest && latest["result"],
                last_at: latest && ms(latest["timestamp"]),
                uptime: stats && number(stats["uptime"]),
                median_ms: stats && number(stats["median"]),
                slots: Enum.map(slots, &slot/1)
              }

            %{nrql: _, id: id} = c ->
              row = first(account, "#{id}_value")

              %{
                kind: :nrql,
                name: c[:name] || "Check",
                unit: c[:unit] || "",
                value:
                  row && row |> Map.values() |> Enum.map(&number/1) |> Enum.find(&is_number/1)
              }
          end)

        errors = reply["errors"] || []

        # Only New Relic's own error text, so the key can never end up here.
        for e <- errors, do: Logger.warning("New Relic query problem: #{e["message"]}")

        if results != [] and Enum.all?(results, &empty_result?/1) and errors != [] do
          {:error, "New Relic: " <> (errors |> hd() |> Map.get("message", "query failed"))}
        else
          {:ok, %{checks: results}}
        end

      {:ok, %{"errors" => [%{"message" => msg} | _]}} ->
        {:error, "New Relic: " <> msg}

      _ ->
        {:error, "New Relic returned an unexpected reply"}
    end
  end

  defp empty_result?(%{kind: :monitor, last_result: nil, slots: []}), do: true
  defp empty_result?(%{kind: :nrql, value: nil}), do: true
  defp empty_result?(_), do: false

  defp monitor_urls(actor) do
    (get_in(actor, ["monitors", "results", "entities"]) || [])
    |> Map.new(&{&1["name"], &1["monitoredUrl"]})
  end

  defp first(account, alias_name) do
    case get_in(account, [alias_name, "results"]) do
      [row | _] when is_map(row) -> row
      _ -> nil
    end
  end

  defp slot(row) do
    total = number(row["total"]) || 0
    failed = number(row["failed"]) || 0

    %{
      start: row["beginTimeSeconds"],
      result:
        cond do
          total == 0 -> :none
          failed > 0 -> :fail
          true -> :pass
        end,
      avg_ms: number(row["avg"])
    }
  end

  # NRQL returns plain numbers for most functions and a map such as
  # %{"50" => 180.2} for percentile().
  defp number(n) when is_number(n), do: n
  defp number(%{} = m), do: m |> Map.values() |> Enum.find(&is_number/1)
  defp number(_), do: nil

  defp ms(n) when is_number(n), do: DateTime.from_unix!(trunc(n), :millisecond)
  defp ms(_), do: nil
end
