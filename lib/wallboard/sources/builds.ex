defmodule Wallboard.Sources.Builds do
  @moduledoc """
  Which build dev and prod are running, read from AWS, so the Prod tile can
  say whether prod runs the same build as dev.

  Comparing commits does not work: a deploy run records whatever commit was
  newest on main when it started, and prod deploys an image dev built earlier
  (promoted, never rebuilt). A commit with no app changes gets the old image
  under a new name. So the build is the image's digest, which is the same in
  both registries when promote copied it.

  For each environment, three reads, all read-only:

    * the services' current task definitions (`aws ecs describe-services`)
    * each task definition's images (`aws ecs describe-task-definition`)
    * each image's digest and the commit it was built from
      (`aws ecr describe-images`, the `src-<container>-<sha>` tag)

  None of these start anything, so a sleeping dev stays asleep: its services
  keep pointing at their last task definition while at 0 tasks. Task
  definitions and image tags never change once made, so both are remembered
  and a normal poll is one call per environment.
  """

  alias Wallboard.Cmd

  # ---------------------------------------------------------------------------
  # Poller hooks (see Wallboard.Poller)

  def poll(settings, _prev, memory, _now) do
    b = settings.builds
    memory = memory || %{}

    # The profiles alone are not enough to ask AWS anything.
    if Enum.any?([b.repository, b.dev.cluster, b.prod.cluster], &(&1 in [nil, ""])) do
      {:error,
       "Builds need the repository and both clusters named in settings.exs (builds: repository, dev and prod)",
       memory}
    else
      compare(settings, b, memory)
    end
  end

  defp compare(settings, b, memory) do
    with {:ok, dev, memory} <- env(b, :dev, dev_profile(settings), memory),
         {:ok, prod, memory} <- env(b, :prod, b.prod_profile, memory) do
      {:ok, %{dev: dev, prod: prod}, memory}
    else
      {:error, reason, memory} -> {:error, reason, memory}
    end
  end

  def fingerprint(facts), do: facts

  def enabled?(settings),
    do: present?(settings.builds.prod_profile) and present?(dev_profile(settings))

  # The dev profile defaults to the one the Dev tile already uses.
  defp dev_profile(settings), do: settings.builds.dev_profile || settings.dev_power.aws_profile

  defp present?(v), do: v not in [nil, ""]

  # ---------------------------------------------------------------------------
  # Fetching

  defp env(b, name, profile, memory) do
    %{cluster: cluster, services: services} = Map.fetch!(b, name)
    ctx = %{profile: profile, region: b.region, name: name}

    with {:ok, json} <-
           aws(ctx, ["ecs", "describe-services", "--cluster", cluster, "--services" | services]),
         {:ok, arns} <- task_definitions(json),
         {:ok, images, memory} <- images(ctx, arns, b.repository, memory),
         {:ok, details, memory} <- details(ctx, images, b.repository, memory) do
      {:ok, build(images, details), memory}
    else
      {:error, reason} -> {:error, "#{name}: #{reason}", memory}
      {:error, reason, memory} -> {:error, "#{name}: #{reason}", memory}
    end
  end

  defp images(ctx, arns, repository, memory) do
    Enum.reduce_while(arns, {:ok, [], memory}, fn arn, {:ok, acc, memory} ->
      key = {:td, arn}

      case memory do
        %{^key => imgs} ->
          {:cont, {:ok, acc ++ imgs, memory}}

        _ ->
          case aws(ctx, ["ecs", "describe-task-definition", "--task-definition", arn]) do
            {:ok, json} ->
              imgs = repo_images(json, repository)
              {:cont, {:ok, acc ++ imgs, Map.put(memory, key, imgs)}}

            {:error, reason} ->
              {:halt, {:error, reason, memory}}
          end
      end
    end)
  end

  defp details(ctx, images, repository, memory) do
    Enum.reduce_while(images, {:ok, %{}, memory}, fn %{tag: tag}, {:ok, acc, memory} ->
      key = {:image, ctx.name, tag}

      case memory do
        %{^key => d} ->
          {:cont, {:ok, Map.put(acc, tag, d), memory}}

        _ ->
          args = [
            "ecr",
            "describe-images",
            "--repository-name",
            repository,
            "--image-ids",
            "imageTag=" <> tag
          ]

          case aws(ctx, args) do
            {:ok, json} ->
              d = image_detail(json)
              {:cont, {:ok, Map.put(acc, tag, d), Map.put(memory, key, d)}}

            {:error, reason} ->
              {:halt, {:error, reason, memory}}
          end
      end
    end)
  end

  defp aws(ctx, args) do
    case Cmd.run(
           "aws",
           args ++ ["--profile", ctx.profile, "--region", ctx.region, "--output", "json"],
           timeout: 30_000
         ) do
      {:ok, out} -> {:ok, out}
      {:error, reason} -> {:error, short_error(reason)}
    end
  end

  defp short_error(reason) do
    if reason =~ ~r/token|expired|sso/i,
      do: "AWS sign-in expired",
      else: reason |> String.split("\n", trim: true) |> List.last() |> to_string()
  end

  # ---------------------------------------------------------------------------
  # Parsing (pure)

  @doc "The current task definition of each service in a describe-services reply."
  def task_definitions(json) do
    case Jason.decode(json) do
      {:ok, %{"services" => [_ | _] = services}} ->
        {:ok, services |> Enum.map(& &1["taskDefinition"]) |> Enum.reject(&is_nil/1)}

      _ ->
        {:error, "AWS returned no services"}
    end
  end

  @doc """
  The containers in a describe-task-definition reply whose image comes from
  our own registry, as `%{container: name, tag: tag}`. Other images (the
  telemetry collector) are not builds of ours.
  """
  def repo_images(json, repository) do
    case Jason.decode(json) do
      {:ok, %{"taskDefinition" => %{"containerDefinitions" => defs}}} ->
        for %{"name" => name, "image" => image} <- defs,
            [_, tag] <- [Regex.run(~r{\.amazonaws\.com/#{Regex.escape(repository)}:(.+)$}, image)],
            do: %{container: name, tag: tag}

      _ ->
        []
    end
  end

  @doc """
  An image's digest and the commit it was built from (its `src-<x>-<sha>`
  tag), from a describe-images reply.
  """
  def image_detail(json) do
    case Jason.decode(json) do
      {:ok, %{"imageDetails" => [d | _]}} ->
        built_from =
          Enum.find_value(d["imageTags"] || [], fn t ->
            case Regex.run(~r/^src-[a-z]+-([0-9a-f]{40})$/, t) do
              [_, sha] -> String.slice(sha, 0, 9)
              _ -> nil
            end
          end)

        %{digest: d["imageDigest"], built_from: built_from}

      _ ->
        %{digest: nil, built_from: nil}
    end
  end

  defp build(images, details) do
    Map.new(images, fn %{container: c, tag: tag} -> {c, Map.merge(%{tag: tag}, details[tag])} end)
  end

  @doc """
  :same when prod runs exactly the builds dev runs, :different when any
  container's digest differs, :unknown when there is nothing to compare.
  """
  def compare(%{dev: dev, prod: prod}) do
    cond do
      dev == %{} or prod == %{} -> :unknown
      Map.keys(dev) != Map.keys(prod) -> :different
      Enum.any?(Map.values(dev) ++ Map.values(prod), &is_nil(&1.digest)) -> :unknown
      Enum.all?(dev, fn {c, d} -> prod[c].digest == d.digest end) -> :same
      true -> :different
    end
  end

  def compare(_), do: :unknown
end
