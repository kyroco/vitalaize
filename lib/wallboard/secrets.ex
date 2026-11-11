defmodule Wallboard.Secrets do
  @moduledoc """
  Holds the New Relic key and the Linear key in memory only.

  Each key comes from one of two places, in this order:

    1. a key typed in the VitalAIze app or `vitalaize setup`, kept in the
       keychain or a file only this user can read (`Wallboard.KeyStore`);
       the settings hold only a note that it is there
       (`new_relic.api_key`, `linear.api_key`)
    2. `op read "<api_key_ref>"`, through 1Password

  It is read when the board starts, and again when either setting changes
  under a running board (`Wallboard.Settings.Watch`). The key is kept
  inside a function, so even if something prints the stored value it shows
  `#Function<...>`, never the key. This module never writes it anywhere: not
  to a log, a page or the settings. Only the key store keeps it.
  """

  require Logger
  alias Wallboard.{Cmd, KeyStore}

  # Each key: its section in the settings, which is also its name in the
  # key store, and the name people know it by.
  @labels %{new_relic: "New Relic", linear: "Linear"}

  @doc """
  Reads the New Relic key the settings point to. Safe to call when none is
  set.

  Reads can overlap: one at the start may wait minutes for 1Password while
  a key typed since is read at once. Only the read started last may keep
  what it found, since it was started with the newest settings; an older
  one that ends later is dropped.
  """
  def load_new_relic(settings), do: load(:new_relic, settings)

  @doc "Reads the Linear key the settings point to, as `load_new_relic/1` does."
  def load_linear(settings), do: load(:linear, settings)

  defp load(name, settings) do
    ticket =
      locked(name, fn ->
        ticket = System.unique_integer([:monotonic])
        :persistent_term.put(latest(name), ticket)
        ticket
      end)

    section = Map.get(settings, name) || %{}

    status =
      case {section[:api_key], section[:api_key_ref]} do
        {%{}, _} -> from_store(name)
        {_, nil} -> {:missing, none_yet(name)}
        {_, ref} -> from_1password(name, ref)
      end

    locked(name, fn ->
      if :persistent_term.get(latest(name), nil) == ticket,
        do: :persistent_term.put(key(name), status)
    end)

    :ok
  end

  defp key(name), do: {__MODULE__, name}
  defp latest(name), do: {__MODULE__, :"#{name}_latest"}

  defp none_yet(name),
    do:
      "No #{@labels[name]} API key yet. Type it in the VitalAIze app's Settings or with vitalaize setup."

  # One read at a time takes its number or keeps its result, so a newer
  # read's result is never followed by an older one's.
  defp locked(name, fun), do: :global.trans({{__MODULE__, name}, self()}, fun)

  defp from_store(name) do
    label = @labels[name]
    place = KeyStore.place()

    case KeyStore.fetch(Atom.to_string(name)) do
      {:ok, key} ->
        Logger.info("#{label} key loaded into memory from #{place}")
        {:ok, fn -> key end}

      :none ->
        Logger.warning("The #{label} key saved in Settings is no longer in #{place}")

        {:missing,
         "The #{label} API key saved in Settings is no longer in #{place}. Type it in Settings again."}

      {:error, why} ->
        Logger.warning("Could not read the #{label} key from #{place}: #{why}")
        {:missing, "Could not read the #{label} API key from #{place}: #{why}"}
    end
  end

  defp from_1password(name, ref) do
    label = @labels[name]

    case Cmd.run("op", ["read", ref], timeout: 120_000) do
      {:ok, out} ->
        case String.trim(out) do
          "" ->
            {:missing, "1Password returned an empty value for #{name}.api_key_ref."}

          key ->
            Logger.info("#{label} key loaded into memory from 1Password")
            {:ok, fn -> key end}
        end

      {:error, reason} ->
        Logger.warning("Could not read the #{label} key from 1Password: #{reason}")
        {:missing, "Could not read the key from 1Password: #{reason}"}
    end
  end

  @doc "{:ok, key_fun} or {:missing, reason}."
  def new_relic do
    :persistent_term.get(
      key(:new_relic),
      {:missing, "The New Relic key has not been loaded yet."}
    )
  end

  @doc "{:ok, key_fun} or {:missing, reason}."
  def linear do
    :persistent_term.get(key(:linear), {:missing, "The Linear key has not been loaded yet."})
  end
end
