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

  So do they when the settings are no longer where they were at the
  start: the settings file is gone or another one is found, or the saved
  settings would now be looked for somewhere else (the folder the board
  was started in was removed, say). Loading then would fall back to the
  defaults, which have no board password. The earlier settings stay until
  the files are back or VitalAIze is restarted.
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
      place: place(),
      moved?: false
    }

    Process.send_after(self(), :look, state.every_ms)
    {:ok, Map.put(state, :stamp, stamp(state.place))}
  end

  @impl true
  def handle_info(:look, state) do
    state =
      if place() == state.place do
        stamp = stamp(state.place)
        if stamp != state.stamp, do: reload(state)
        %{state | stamp: stamp, moved?: false}
      else
        # The stamp stays, so a save made meanwhile is taken up once the
        # settings are back where they were.
        unless state.moved?, do: moved(state)
        %{state | moved?: true}
      end

    Process.send_after(self(), :look, state.every_ms)
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # Where the settings are: the settings file in use (nil with none) and
  # the file the saved settings are in.
  defp place do
    {Settings.path(), Settings.saved_path()}
  rescue
    # Looking must never stop the board or the collector.
    _ -> :unknown
  end

  # Which file is there now. Saving replaces the file with a new one, so
  # its number on disk changes even when its size and time do not.
  defp stamp({_file, saved}) do
    case File.stat(saved, time: :posix) do
      {:ok, stat} -> {stat.inode, stat.mtime, stat.size}
      {:error, reason} -> reason
    end
  rescue
    _ -> :unknown
  end

  defp stamp(_unknown), do: :unknown

  defp moved(state) do
    Logger.warning(
      "The settings are no longer where they were when VitalAIze started, so the " <>
        "earlier ones stay. Put them back, or restart VitalAIze to use the ones there now."
    )

    if state.listener, do: send(state.listener, {:settings, :moved})
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
      # Our own messages name the file and what is wrong with it. Any other
      # error may quote a line of the settings file, which can hold a
      # password, so only its kind is logged.
      why = if is_struct(e, ArgumentError), do: Exception.message(e), else: inspect(e.__struct__)
      Logger.warning("The settings could not be read, so the earlier ones stay. #{why}")

      if state.listener, do: send(state.listener, {:settings, :unreadable})
  end
end
