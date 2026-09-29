defmodule Wallboard.Secrets do
  @moduledoc """
  Holds the New Relic key in memory only.

  At startup it runs `op read "<api_key_ref>"` once. The key is kept inside a
  function, so even if something prints the stored value it shows
  `#Function<...>`, never the key. It is never written to a file, a log or
  the settings.
  """

  require Logger
  alias Wallboard.Cmd

  @key {__MODULE__, :new_relic}

  @doc "Reads the key named in settings. Safe to call when none is set."
  def load_new_relic(settings) do
    status =
      case settings.new_relic.api_key_ref do
        nil ->
          {:missing, "No New Relic key reference in settings (new_relic.api_key_ref)."}

        ref ->
          case Cmd.run("op", ["read", ref], timeout: 120_000) do
            {:ok, out} ->
              case String.trim(out) do
                "" ->
                  {:missing, "1Password returned an empty value for new_relic.api_key_ref."}

                key ->
                  Logger.info("New Relic key loaded into memory")
                  {:ok, fn -> key end}
              end

            {:error, reason} ->
              Logger.warning("Could not read the New Relic key from 1Password: #{reason}")
              {:missing, "Could not read the key from 1Password: #{reason}"}
          end
      end

    :persistent_term.put(@key, status)
    :ok
  end

  @doc "{:ok, key_fun} or {:missing, reason}."
  def new_relic do
    :persistent_term.get(@key, {:missing, "The New Relic key has not been loaded yet."})
  end
end
