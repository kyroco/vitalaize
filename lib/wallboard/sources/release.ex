defmodule Wallboard.Sources.Release do
  @moduledoc """
  Whether a newer VitalAIze is out, from the latest release on GitHub.

  The poller runs every minute, so the settings switch takes effect as fast
  as the rest of the page, but GitHub is asked at most once a day, whether
  that ask worked or not; the minutes between reuse the last answer. With
  `updates.check` off, nothing is asked and the note goes away.
  """

  @repo "kyroco/vitalaize"
  @day_seconds 24 * 60 * 60

  # ---------------------------------------------------------------------------
  # Poller hooks (see Wallboard.Poller)

  def poll(settings, _prev, memory, now) do
    cond do
      not check?(settings) ->
        {:ok, nil, nil}

      fresh?(memory, now) ->
        {:ok, memory.facts, memory}

      true ->
        case fetch() do
          {:ok, body} ->
            facts = newer(body, current())
            {:ok, facts, %{checked_at: now, facts: facts}}

          # Keep the last answer and wait a day, so a board with no internet
          # or over GitHub's limit does not ask again every minute.
          {:error, reason} ->
            {:error, reason, %{checked_at: now, facts: memory && memory.facts}}
        end
    end
  end

  def fingerprint(facts), do: facts

  # Anything but `true` in a hand-written settings file counts as off.
  defp check?(%{updates: %{check: true}}), do: true
  defp check?(_), do: false

  # A clock that moved backward makes the last check look from the future;
  # ask again rather than trust it.
  @doc false
  def fresh?(%{checked_at: at}, now), do: DateTime.diff(now, at) in 0..(@day_seconds - 1)
  def fresh?(_, _), do: false

  @doc "The version this board runs, like \"0.2.0\"."
  def current, do: :wallboard |> Application.spec(:vsn) |> to_string()

  @doc """
  From GitHub's answer for the latest release: `%{version:, url:}` when it is
  newer than `current`, otherwise nil. A test build like v0.3.0-rc.1 never
  counts. Tested directly.
  """
  def newer(body, current) do
    with {:ok, %{"tag_name" => tag, "html_url" => url}} when is_binary(tag) <- Jason.decode(body),
         true <- is_binary(url) and String.starts_with?(url, "https://github.com/"),
         {:ok, %Version{pre: []} = latest} <- tag |> String.trim_leading("v") |> Version.parse(),
         {:ok, running} <- Version.parse(current),
         :gt <- Version.compare(latest, running) do
      %{version: to_string(latest), url: url}
    else
      _ -> nil
    end
  end

  defp fetch do
    url = ~c"https://api.github.com/repos/#{@repo}/releases/latest"

    headers = [
      {~c"user-agent", ~c"VitalAIze/#{current()}"},
      {~c"accept", ~c"application/vnd.github+json"}
    ]

    ssl = [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      depth: 4,
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]

    case :httpc.request(:get, {url, headers}, [timeout: 30_000, ssl: ssl], body_format: :binary) do
      {:ok, {{_, 200, _}, _headers, body}} ->
        {:ok, body}

      {:ok, {{_, status, _}, _, _}} ->
        {:error, "GitHub answered #{status} for the latest release"}

      {:error, _} ->
        {:error, "Could not reach GitHub for the latest release"}
    end
  end
end
