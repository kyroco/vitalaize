defmodule Wallboard.KeyStore.Memory do
  @moduledoc """
  A stand-in for the keychain in tests: keys are held in memory, in this
  test run alone. config/test.exs makes it the store, so no test reaches
  a real keychain or writes a key file it did not ask for.
  """

  @behaviour Wallboard.KeyStore

  @key {__MODULE__, :keys}

  @impl true
  def place, do: "the test keychain"

  @impl true
  def where(_name, _opts), do: "the test keychain"

  @impl true
  def put(name, key, _opts) do
    case :persistent_term.get({__MODULE__, :refuse}, false) do
      true -> {:error, "the test keychain refuses"}
      false -> :persistent_term.put(@key, Map.put(all(), name, key))
    end
  end

  @impl true
  def fetch(name, _opts) do
    case {:persistent_term.get({__MODULE__, :unreadable}, false), Map.fetch(all(), name)} do
      {true, _} -> {:error, "the test keychain could not be read"}
      {false, {:ok, key}} -> {:ok, key}
      {false, :error} -> :none
    end
  end

  @impl true
  def delete(name, _opts) do
    case :persistent_term.get({__MODULE__, :refuse}, false) do
      true -> {:error, "the test keychain refuses"}
      false -> :persistent_term.put(@key, Map.delete(all(), name))
    end
  end

  @doc "Every key held, by name."
  def all, do: :persistent_term.get(@key, %{})

  @doc "Forgets every key, and takes writes and reads again."
  def clear do
    :persistent_term.put(@key, %{})
    :persistent_term.put({__MODULE__, :refuse}, false)
    :persistent_term.put({__MODULE__, :unreadable}, false)
  end

  @doc "Makes every write and delete fail from here on, until `clear/0`."
  def refuse, do: :persistent_term.put({__MODULE__, :refuse}, true)

  @doc "Makes every read fail from here on, until `clear/0`."
  def unreadable, do: :persistent_term.put({__MODULE__, :unreadable}, true)
end
