defmodule Wallboard.Settings.Watch do
  @moduledoc """
  Takes up saved settings while the board or the collector runs.

  The VitalAIze app and `vitalaize setup` are programs of their own: they
  write settings.json (see `Wallboard.Settings`) and cannot reach into the
  one that is running. So the running one looks at that file every two
  seconds and, when it has changed, loads the settings again. Everything
  that reads its settings as it goes then uses the new ones, with no
  restart. The few settings that are only read at the start (the ports,
  the role, the board password) wait for the restart that whoever saved
  them asks for (see `Wallboard.Setup`).

  A file that cannot be read changes nothing: the settings in use stay.
  """

  use GenServer
  require Logger

  alias Wallboard.Settings

  @every_ms 2_000

  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @impl true
  def init(opts) do
    state = %{
      every_ms: Keyword.get(opts, :every_ms, @every_ms),
      listener: opts[:listener],
      stamp: stamp()
    }

    Process.send_after(self(), :look, state.every_ms)
    {:ok, state}
  end

  @impl true
  def handle_info(:look, state) do
    stamp = stamp()
    if stamp != state.stamp, do: reload(state)
    Process.send_after(self(), :look, state.every_ms)
    {:noreply, %{state | stamp: stamp}}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # Which file is there now. Saving replaces the file with a new one, so
  # its number on disk changes even when its size and time do not.
  defp stamp do
    case File.stat(Settings.saved_path(), time: :posix) do
      {:ok, stat} -> {stat.inode, stat.mtime, stat.size}
      {:error, reason} -> reason
    end
  end

  defp reload(state) do
    before = Settings.get()
    now = Settings.load!()

    # Names only: a value may be a password or a key.
    case Wallboard.Setup.plan(before, now).changed do
      [] ->
        :ok

      changed ->
        Logger.info("Saved settings taken up: #{Enum.map_join(changed, ", ", & &1.label)}")
    end

    if state.listener, do: send(state.listener, {:settings, :reloaded})
  rescue
    e ->
      Logger.warning(
        "The saved settings could not be read, so the earlier ones stay. " <>
          Exception.message(e)
      )

      if state.listener, do: send(state.listener, {:settings, :unreadable})
  end
end
