defmodule Wallboard.Link.Hub do
  @moduledoc """
  The hub's side of the link (see `Wallboard.Link`): the listening port and
  the list of machines connected right now.

  Start it with `{Wallboard.Link.Hub, dir: folder, port: port}`. It makes
  the certificate authority in `dir` when there is none, then listens.
  With `board_port`, the port the board itself is running on, each
  collector is told that port when it connects, so it asks the pairing
  door in the right place after the owner changes it.
  `Wallboard.Store` must already be running: that is where events go.

  Other parts of the board hear about the link on the `"link"` topic of
  `Wallboard.PubSub`:

    * `{:link, :up, machine}` and `{:link, :down, machine}`
    * `{:link, :hello, machine, info}`
    * `{:link, :events, machine, rows}` after rows are saved, each with
      `session_id`, `file`, `position`, `at` and the encoded `event`. The
      database sends this one itself, in the same step as the save, so a
      stream that is cut off right after its save cannot leave rows
      saved and unannounced.
  """

  use GenServer
  require Logger

  alias Wallboard.Collector.Proto
  alias Wallboard.Link
  alias Wallboard.Link.{Authority, Server}

  @topic "link"
  @buckets __MODULE__.Buckets
  # How long a machine gets to read "disconnected" or "back soon" before
  # its stream is closed.
  @close_after_ms 500

  @doc """
  The hub and its port, as one child for a supervisor. Options: `dir` (the
  authority's folder), `port` (0 picks a free one), `limits` (changes to
  `Wallboard.Link.limits/0`, for tests).
  """
  def child_spec(opts) do
    %{
      id: __MODULE__,
      type: :supervisor,
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  def start_link(opts) do
    dir = Keyword.fetch!(opts, :dir)
    :ok = Authority.ensure!(dir)
    limits = Map.merge(Link.limits(), Map.new(opts[:limits] || %{}))

    children = [
      %{
        id: :registry,
        start:
          {GenServer, :start_link,
           [__MODULE__, {dir, limits, opts[:board_port]}, [name: __MODULE__]]}
      },
      listener(Keyword.get(opts, :port, 0),
        cred: GRPC.Credential.new(ssl: Authority.hub_tls(dir)),
        ip: {0, 0, 0, 0},
        num_acceptors: 4,
        max_connections: limits.max_connections,
        # A connection that says nothing for this long is closed.
        idle_timeout: limits.idle_ms,
        # HTTP/2 only, whatever a client offers.
        alpn_default_protocol: :http2,
        # One stream is all a collector needs; a second replaces the first.
        max_concurrent_streams: 2,
        max_frame_size_received: 65_536
      )
    ]

    # If the list of machines dies the port goes with it, so every collector
    # connects again and is listed again.
    Supervisor.start_link(children, strategy: :rest_for_one)
  end

  # The gRPC library adds two TLS settings of its own after ours: an offer
  # of HTTP/1.1, and an older way to pick a protocol that TLS 1.3 does not
  # have (which logs a warning on every start). Both are taken out, so the
  # port offers HTTP/2 and nothing else.
  defp listener(port, adapter_opts) do
    spec =
      GRPC.Server.Supervisor.child_spec(Wallboard.Link.Endpoint, port, adapter_opts: adapter_opts)

    case spec do
      %{start: {m, f, [ref, transport, %{socket_opts: socket_opts} = trans, protocol, proto]}} ->
        {socket_opts, _} =
          Enum.flat_map_reduce(socket_opts, false, fn
            {:next_protocols_advertised, _}, seen? -> {[], seen?}
            {:alpn_preferred_protocols, _}, true -> {[], true}
            {:alpn_preferred_protocols, _} = first, false -> {[first], true}
            other, seen? -> {[other], seen?}
          end)

        # A connection gets three seconds to finish its handshake. Until it
        # has, it is a stranger holding one of the port's places.
        # One counter of connections, so the limit is the limit; left alone
        # there is one per acceptor and the port takes four times as many.
        trans =
          Map.merge(trans, %{
            socket_opts: socket_opts,
            handshake_timeout: 3_000,
            num_conns_sups: 1
          })

        %{spec | start: {m, f, [ref, transport, trans, protocol, proto]}}

      other ->
        other
    end
  end

  @doc "The port the hub listens on."
  def port, do: :ranch.get_port(inspect(Wallboard.Link.Endpoint))

  @doc "The folder the certificate authority lives in."
  def dir, do: GenServer.call(__MODULE__, :dir)

  @doc "The machines connected now: `%{machine => %{since, hello}}`."
  def connected, do: GenServer.call(__MODULE__, :connected)

  @doc """
  Revokes a machine's certificate and closes its stream. It is told
  "disconnected" first, so it stops instead of trying again.
  """
  def revoke(machine), do: GenServer.call(__MODULE__, {:revoke, machine})

  @doc """
  Tells every connected machine the hub is about to restart on purpose, so
  each waits a little before it tries again. Returns how many were told.
  """
  def back_soon do
    GenServer.call(__MODULE__, :back_soon)
  catch
    :exit, _ -> 0
  end

  @doc false
  # Called by a stream's process: whose certificate is this? A machine that
  # is already connected has its older stream closed.
  def attach(cert, stream, counter),
    do: GenServer.call(__MODULE__, {:attach, cert, stream, counter})

  @doc false
  def hello(machine, %{} = hello),
    do: GenServer.call(__MODULE__, {:hello, machine, hello})

  @doc false
  # A machine's rate buckets: messages left, bytes left, and when that was.
  # Full for a machine not seen since the hub started.
  def bucket(machine, limits, now) do
    case :ets.lookup(@buckets, machine) do
      [{_, bucket}] -> bucket
      [] -> {limits.message_burst * 1.0, limits.byte_burst * 1.0, now}
    end
  end

  @doc false
  def put_bucket(machine, bucket), do: :ets.insert(@buckets, {machine, bucket})

  # ---------------------------------------------------------------------------

  @impl true
  def init({dir, limits, board_port}) do
    # Each machine's rate buckets (see Wallboard.Link.Server). Kept here so
    # they outlive a stream; each stream's own process reads and writes
    # them without waiting on this one.
    :ets.new(@buckets, [:named_table, :public, :set])
    {:ok, %{dir: dir, limits: limits, board_port: board_port, streams: %{}}}
  end

  @impl true
  def handle_call(:dir, _from, s), do: {:reply, s.dir, s}

  def handle_call(:connected, _from, s) do
    {:reply, Map.new(s.streams, fn {m, c} -> {m, Map.take(c, [:since, :hello])} end), s}
  end

  def handle_call({:attach, cert, stream, counter}, {pid, _}, s) do
    case Authority.machine(s.dir, cert) do
      {:ok, machine} ->
        s = close(s, machine, :replaced)

        entry = %{
          pid: pid,
          ref: Process.monitor(pid),
          stream: stream,
          counter: counter,
          since: System.os_time(:second),
          hello: nil
        }

        Logger.info("Link: #{machine} connected.")
        broadcast({:link, :up, machine})
        {:reply, {:ok, machine, s.limits, s.dir, s.board_port}, put_in(s.streams[machine], entry)}

      {:error, reason} ->
        {:reply, {:error, reason}, s}
    end
  end

  # The stream's own process saved the hello already: nothing here waits
  # on the database, so one slow write never holds every machine up.
  def handle_call({:hello, machine, info}, {pid, _}, s) do
    broadcast({:link, :hello, machine, info})

    s =
      case s.streams[machine] do
        %{pid: ^pid} -> put_in(s.streams[machine].hello, info)
        _ -> s
      end

    {:reply, :ok, s}
  end

  def handle_call({:revoke, machine}, _from, s) do
    # A list of machines that is locked or cannot be read must not take
    # the port down with it.
    result =
      try do
        Authority.revoke(s.dir, machine)
      rescue
        e -> {:error, Exception.message(e)}
      end

    with {:ok, _} <- result,
         %{stream: stream, counter: counter, pid: pid} <- s.streams[machine] do
      Server.send_to(stream, counter, {:disconnected, %Proto.Disconnected{}})
      Process.send_after(self(), {:close, pid}, @close_after_ms)
    end

    if match?({:ok, _}, result), do: Logger.info("Link: #{machine} was removed.")
    {:reply, result, s}
  end

  def handle_call(:back_soon, _from, s) do
    for {_, %{stream: stream, counter: counter}} <- s.streams do
      Server.send_to(stream, counter, {:back_soon, %Proto.BackSoon{}})
    end

    {:reply, map_size(s.streams), s}
  end

  @impl true
  def handle_info({:close, pid}, s) do
    Process.exit(pid, :shutdown)
    {:noreply, s}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, s) do
    case Enum.find(s.streams, fn {_, c} -> c.ref == ref end) do
      {machine, _} ->
        Logger.info("Link: #{machine} disconnected.")
        broadcast({:link, :down, machine})
        {:noreply, %{s | streams: Map.delete(s.streams, machine)}}

      nil ->
        {:noreply, s}
    end
  end

  def handle_info(_, s), do: {:noreply, s}

  # An older stream of the same machine. Its monitor is dropped first, so
  # its end is not taken for the machine going away.
  defp close(s, machine, _why) do
    case s.streams[machine] do
      %{pid: pid, ref: ref} ->
        Process.demonitor(ref, [:flush])
        Process.exit(pid, :shutdown)
        %{s | streams: Map.delete(s.streams, machine)}

      nil ->
        s
    end
  end

  defp broadcast(message), do: Phoenix.PubSub.broadcast(Wallboard.PubSub, @topic, message)
end
