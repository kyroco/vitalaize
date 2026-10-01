defmodule Wallboard.OldCollectors do
  @moduledoc """
  Machines that still run the upload hooks of VitalAIze 0.2.0.

  Until 0.3.0 another machine sent its sessions to the hub from hook
  scripts, over HTTP. A collector streams them now (see `Wallboard.Link`),
  and the hub takes no uploads. A machine nobody has moved across keeps
  calling the old address. Each call is refused
  (`WallboardWeb.OldCollectorController`), and the machine's name is kept
  here so the mailbox can say, once for each machine, that it needs the
  new collector (`Wallboard.Mailbox.OldCollector`).

  A machine leaves the list when it pairs: a machine of that name then
  holds a working certificate. Dismiss takes one off by hand, for a
  machine that is gone for good, and it is not listed again.

  This is for one release. The release after 0.3.0 takes this module, its
  mailbox item and the refusal out.

  ## Who is listed

  Every call to the old address is refused, whoever makes it. Only a call
  from a real old machine is listed: one that carries the key this hub
  gave its old collectors, which is still in the database of a hub that
  had any (`ingest_token`). The key opens nothing now. It is never made,
  shown or changed again, and is only compared, so that a stranger on the
  network, or a web page opened on it, cannot put names of their choosing
  in the owner's mailbox or crowd a real machine out. A hub that never had
  old collectors has no key and lists nothing.

  What is kept is small all the same: a name of letters, digits, dots,
  dashes and underscores, at most 64 of them; at most 20 machines waiting
  in the mailbox; and at most 200 names in all, the dismissed ones that
  were first seen longest ago going first. A name past the limit is
  dropped without a word.

  The list is kept in the database, so it is still there after a restart.
  """

  use GenServer

  alias Wallboard.Link.Authority
  alias Wallboard.{Mailbox, Settings, Store}

  @name ~r/\A[A-Za-z0-9._-]{1,64}\z/
  @max_waiting 20
  @max_kept 200
  @meta "old_collectors"

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Notes that `machine` made an old upload call, if `key` is the one this
  hub gave its old collectors. `:ok` whatever came of it: the caller
  refuses the call either way.
  """
  def seen(machine, key) do
    if valid_name?(machine) and is_binary(key),
      do: GenServer.call(__MODULE__, {:seen, machine, key}, 5_000),
      else: :ok
  catch
    :exit, _ -> :ok
  end

  @doc "The machines still to move across, first seen first: `[%{machine, at}]`."
  def waiting do
    GenServer.call(__MODULE__, :waiting, 5_000)
  catch
    :exit, _ -> []
  end

  @doc "Takes a machine off the list for good. `:ok`, or `{:error, :gone}`."
  def dismiss(machine) do
    GenServer.call(__MODULE__, {:dismiss, machine}, 5_000)
  catch
    :exit, _ -> {:error, :gone}
  end

  @doc """
  True for a machine name the old upload script could send: safe to keep
  and to show. A name of only dots is not one.
  """
  def valid_name?(name) when is_binary(name),
    do: name =~ @name and String.trim(name, ".") != ""

  def valid_name?(_), do: false

  # ---------------------------------------------------------------------------

  @impl true
  def init(opts) do
    state = %{
      # name => %{at: first seen, in seconds; dismissed: bool}
      machines: load(),
      # The key old collectors send, or nil on a hub that never had any.
      key: old_key(),
      paired: Keyword.get(opts, :paired, &paired/0)
    }

    {:ok, state}
  end

  # Never print the old key in a crash report.
  @impl true
  def format_status(status), do: Map.put(status, :state, :hidden)

  @impl true
  def handle_call({:seen, machine, key}, _from, state) do
    cond do
      not (is_binary(state.key) and Plug.Crypto.secure_compare(key, state.key)) ->
        {:reply, :ok, state}

      Map.has_key?(state.machines, machine) ->
        {:reply, :ok, state}

      length(waiting(state.machines)) >= @max_waiting ->
        {:reply, :ok, state}

      paired?(machine, state.paired.()) ->
        {:reply, :ok, state}

      true ->
        entry = %{at: System.os_time(:second), dismissed: false}
        machines = state.machines |> Map.put(machine, entry) |> trim()
        save(machines)
        Mailbox.changed()
        {:reply, :ok, %{state | machines: machines}}
    end
  end

  def handle_call(:waiting, _from, %{machines: machines} = state) when machines == %{},
    do: {:reply, [], state}

  # A machine that has paired since is forgotten here.
  def handle_call(:waiting, _from, state) do
    names = state.paired.()
    machines = Map.reject(state.machines, fn {machine, _} -> paired?(machine, names) end)
    if machines != state.machines, do: save(machines)

    list = for {machine, e} <- waiting(machines), do: %{machine: machine, at: e.at}
    {:reply, list, %{state | machines: machines}}
  end

  def handle_call({:dismiss, machine}, _from, state) do
    case state.machines[machine] do
      %{dismissed: false} = entry ->
        machines = Map.put(state.machines, machine, %{entry | dismissed: true})
        save(machines)
        Mailbox.changed()
        {:reply, :ok, %{state | machines: machines}}

      _ ->
        {:reply, {:error, :gone}, state}
    end
  end

  defp waiting(machines) do
    machines
    |> Enum.reject(fn {_, e} -> e.dismissed end)
    |> Enum.sort_by(fn {machine, e} -> {e.at, machine} end)
  end

  # At most @max_kept names: dismissed ones go first, oldest first.
  defp trim(machines) when map_size(machines) <= @max_kept, do: machines

  defp trim(machines) do
    over = map_size(machines) - @max_kept

    machines
    |> Enum.filter(fn {_, e} -> e.dismissed end)
    |> Enum.sort_by(fn {machine, e} -> {e.at, machine} end)
    |> Enum.take(over)
    |> Enum.reduce(machines, fn {machine, _}, acc -> Map.delete(acc, machine) end)
  end

  # The old script named a machine by `hostname -s`, with anything but
  # letters, digits, dots, dashes and underscores turned into a dash. A
  # certificate carries nearly the same name
  # (`Wallboard.Pairing.machine_name/0`), which may keep a space or drop a
  # ".local". So the two are compared by their letters and digits alone.
  defp paired?(machine, names), do: plain(machine) in names

  @doc false
  def plain(name) do
    name
    |> String.downcase()
    |> String.replace_suffix(".local", "")
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  # The names that hold a working certificate, made plain.
  defp paired do
    dir = Authority.dir(Settings.get())
    for %{machine: name, revoked_at: nil} <- Authority.machines(dir), do: plain(name)
  rescue
    _ -> []
  end

  defp old_key do
    case Store.get_meta("ingest_token") do
      key when is_binary(key) and key != "" -> key
      _ -> nil
    end
  catch
    :exit, _ -> nil
  end

  defp load do
    with text when is_binary(text) <- Store.get_meta(@meta),
         {:ok, %{} = saved} <- Jason.decode(text) do
      for {machine, %{"at" => at} = e} <- saved,
          valid_name?(machine),
          is_integer(at),
          into: %{},
          do: {machine, %{at: at, dismissed: e["dismissed"] == true}}
    else
      _ -> %{}
    end
  catch
    :exit, _ -> %{}
  end

  defp save(machines) do
    Store.put_meta(@meta, Jason.encode!(machines))
  catch
    :exit, _ -> :ok
  end
end
