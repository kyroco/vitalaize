defmodule Wallboard.Secrets do
  @moduledoc """
  Holds the New Relic key in memory only.

  The key comes from one of two places, in this order:

    1. a key typed in the VitalAIze app or `vitalaize setup`, kept in the
       keychain or a file only this user can read (`Wallboard.KeyStore`);
       the settings hold only a note that it is there
       (`new_relic.api_key`)
    2. `op read "<api_key_ref>"`, through 1Password

  It is read when the board starts, and again when either setting changes
  under a running board (`Wallboard.Settings.Watch`). The key is kept
  inside a function, so even if something prints the stored value it shows
  `#Function<...>`, never the key. It is never written to a file, a log or
  the settings.
  """

  require Logger
  alias Wallboard.{Cmd, KeyStore}

  @key {__MODULE__, :new_relic}
  @latest {__MODULE__, :new_relic_latest}

  @doc """
  Reads the key the settings point to. Safe to call when none is set.

  Reads can overlap: one at the start may wait minutes for 1Password while
  a key typed since is read at once. Only the read started last may keep
  what it found, since it was started with the newest settings; an older
  one that ends later is dropped.
  """
  def load_new_relic(settings) do
    ticket =
      locked(fn ->
        ticket = System.unique_integer([:monotonic])
        :persistent_term.put(@latest, ticket)
        ticket
      end)

    status =
      case {settings.new_relic[:api_key], settings.new_relic.api_key_ref} do
        {%{}, _} ->
          from_store()

        {_, nil} ->
          {:missing,
           "No New Relic API key yet. Type it in the VitalAIze app's Settings or with vitalaize setup."}

        {_, ref} ->
          from_1password(ref)
      end

    locked(fn ->
      if :persistent_term.get(@latest, nil) == ticket, do: :persistent_term.put(@key, status)
    end)

    :ok
  end

  # One read at a time takes its number or keeps its result, so a newer
  # read's result is never followed by an older one's.
  defp locked(fun), do: :global.trans({{__MODULE__, :new_relic}, self()}, fun)

  defp from_store do
    place = KeyStore.place()

    case KeyStore.fetch("new_relic") do
      {:ok, key} ->
        Logger.info("New Relic key loaded into memory from #{place}")
        {:ok, fn -> key end}

      :none ->
        Logger.warning("The New Relic key saved in Settings is no longer in #{place}")

        {:missing,
         "The New Relic API key saved in Settings is no longer in #{place}. Type it in Settings again."}

      {:error, why} ->
        Logger.warning("Could not read the New Relic key from #{place}: #{why}")
        {:missing, "Could not read the New Relic API key from #{place}: #{why}"}
    end
  end

  defp from_1password(ref) do
    case Cmd.run("op", ["read", ref], timeout: 120_000) do
      {:ok, out} ->
        case String.trim(out) do
          "" ->
            {:missing, "1Password returned an empty value for new_relic.api_key_ref."}

          key ->
            Logger.info("New Relic key loaded into memory from 1Password")
            {:ok, fn -> key end}
        end

      {:error, reason} ->
        Logger.warning("Could not read the New Relic key from 1Password: #{reason}")
        {:missing, "Could not read the key from 1Password: #{reason}"}
    end
  end

  @doc "{:ok, key_fun} or {:missing, reason}."
  def new_relic do
    :persistent_term.get(@key, {:missing, "The New Relic key has not been loaded yet."})
  end
end
