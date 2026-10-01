defmodule Wallboard.Sources.DevPower do
  @moduledoc """
  Whether the dev environment is awake or asleep, read from AWS.

  Dev sleeps at 8pm New York: its services drop to 0 tasks and its database
  stops. A wake (the reaper's button, or a deploy) starts the database, then
  the services. So two reads tell the whole story, the same two the
  korium-dev-reaper skill's status check uses:

    * the database's status (`aws rds describe-db-instances`)
    * each service's wanted and running task counts (`aws ecs describe-services`)

  Both run with a read-only AWS profile from settings (`dev_power.aws_profile`).
  With no profile set, this source is off and the Dev tile shows the last
  deploy instead.
  """

  alias Wallboard.Cmd

  # ---------------------------------------------------------------------------
  # Poller hooks (see Wallboard.Poller)

  def poll(settings, _prev, memory, _now) do
    dp = settings.dev_power

    # A profile alone is not enough to ask AWS anything.
    if dp.database in [nil, ""] or dp.cluster in [nil, ""] do
      {:error,
       "Dev needs its database and cluster named in settings.exs (dev_power: database and cluster)",
       memory}
    else
      case fetch(dp) do
        {:ok, facts} -> {:ok, facts, memory}
        {:error, reason} -> {:error, reason, memory}
      end
    end
  end

  def fingerprint(facts), do: facts

  def enabled?(settings), do: settings.dev_power.aws_profile not in [nil, ""]

  # ---------------------------------------------------------------------------
  # Fetching

  defp fetch(dp) do
    with {:ok, db_json} <- aws(dp, database_args(dp)),
         {:ok, list_json} <- aws(dp, ["ecs", "list-services", "--cluster", dp.cluster]),
         {:ok, arns} <- service_arns(list_json),
         {:ok, svc_json} <- describe(dp, arns) do
      parse(db_json, svc_json)
    end
  end

  defp database_args(dp) do
    ["rds", "describe-db-instances", "--db-instance-identifier", dp.database]
  end

  defp describe(_dp, []), do: {:ok, ~s({"services": []})}

  # describe-services takes at most 10 services a call; dev has 7.
  defp describe(dp, arns) do
    chunks = Enum.chunk_every(arns, 10)

    Enum.reduce_while(chunks, {:ok, []}, fn chunk, {:ok, acc} ->
      case aws(dp, ["ecs", "describe-services", "--cluster", dp.cluster, "--services" | chunk]) do
        {:ok, json} ->
          {:cont, {:ok, acc ++ (Jason.decode!(json)["services"] || [])}}

        err ->
          {:halt, err}
      end
    end)
    |> case do
      {:ok, services} -> {:ok, Jason.encode!(%{services: services})}
      err -> err
    end
  end

  defp service_arns(json) do
    case Jason.decode(json) do
      {:ok, %{"serviceArns" => arns}} when is_list(arns) -> {:ok, arns}
      _ -> {:error, "AWS returned an unexpected service list"}
    end
  end

  defp aws(dp, args) do
    region = if dp[:region], do: ["--region", dp.region], else: []

    case Cmd.run("aws", args ++ ["--profile", dp.aws_profile, "--output", "json"] ++ region,
           timeout: 30_000
         ) do
      {:ok, out} -> {:ok, out}
      {:error, reason} -> {:error, short_error(reason)}
    end
  end

  # An expired sign-in is the usual failure; say so plainly.
  defp short_error(reason) do
    if reason =~ ~r/token|expired|sso/i,
      do: "AWS sign-in expired: run aws sso login",
      else: reason
  end

  # ---------------------------------------------------------------------------
  # Parsing (pure)

  @doc "Turns the database and services replies into one dev state."
  def parse(db_json, svc_json) do
    with {:ok, %{"DBInstances" => [db | _]}} <- Jason.decode(db_json),
         {:ok, %{"services" => services}} <- Jason.decode(svc_json) do
      services =
        Enum.map(services, fn s ->
          %{
            name: s["serviceName"],
            desired: s["desiredCount"] || 0,
            running: s["runningCount"] || 0
          }
        end)

      {:ok, %{database: db["DBInstanceStatus"], services: services}}
    else
      _ -> {:error, "AWS returned an unexpected reply"}
    end
  end

  @doc """
  The state to show: :awake, :asleep, :waking, :falling_asleep or :mixed.

  Two in-between states are normal for a few minutes: services at 0 with the
  database still up right after 8pm (it stops at 8:05), and the database
  starting with services at 0 during a wake.
  """
  def state(%{database: db, services: services}) do
    wanted = Enum.filter(services, &(&1.desired > 0))
    all_zero? = wanted == [] and Enum.all?(services, &(&1.running == 0))
    all_up? = wanted != [] and Enum.all?(services, &(&1.running >= &1.desired))

    cond do
      db == "stopped" and all_zero? -> :asleep
      db == "available" and all_up? -> :awake
      db in ["starting", "configuring-enhanced-monitoring"] -> :waking
      db == "available" and wanted != [] -> :waking
      db == "stopping" -> :falling_asleep
      db == "available" and all_zero? -> :falling_asleep
      true -> :mixed
    end
  end
end
