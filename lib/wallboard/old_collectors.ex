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

  ## Limits

  An old call carries no key any more, so anyone on the network can make
  one. What is kept is therefore small: a name of letters, digits, dots,
  dashes and underscores, at most 64 of them; at most 20 machines
  waiting in the mailbox; and at most 200 names in all, the dismissed ones
  that were first seen longest ago going first. A name past the limit is
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
  Notes that `machine` made an old upload call. `:ok` whatever came of it:
  the caller refuses the call either way.
  """
  def seen(machine) do
    if valid_name?(machine), do: GenServer.call(__MODULE__, {:seen, machine}, 5_000), else: :ok
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
      paired: Keyword.get(opts, :paired, &paired/0)
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:seen, machine}, _from, state) do
    cond do
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

  # The old script named a machine by `hostname -s`; a certificate carries
  # nearly the same name (`Wallboard.Pairing.machine_name/0`). Capitals
  # aside, they are the same machine.
  defp paired?(machine, names), do: String.downcase(machine) in names

  # The names that hold a working certificate, in small letters.
  defp paired do
    dir = Authority.dir(Settings.get())
    for %{machine: name, revoked_at: nil} <- Authority.machines(dir), do: String.downcase(name)
  rescue
    _ -> []
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
